#!/usr/bin/env bash
#
# Cut a Sparkle-updatable release.
#
# What this does:
#   1. verify the version matches the built app
#   2. re-sign the app with your Developer ID + hardened runtime
#   3. wait for YOU to notarize (see below) — we can't, it needs your password
#   4. generate/refresh appcast.xml (EdDSA-signed with your Keychain key)
#   5. publish the GitHub release with the DMG attached
#
# Existing users get the update automatically once appcast.xml lands on `main`.
#
# Usage:
#   bash scripts/package-app.sh            # build first
#   bash scripts/release.sh 1.0.7
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: bash scripts/release.sh <version>   e.g. 1.0.7"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/VideoPro.app"
DMG="$DIST/VideoPro.dmg"
DEVID="Developer ID Application: Tyler Simmons (7MGPA96634)"
FEED_BRANCH="main"

[ -d "$APP" ] || { echo "✗ no $APP — run: bash scripts/package-app.sh"; exit 1; }

BUILT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
if [ "$BUILT" != "$VERSION" ]; then
  echo "✗ version mismatch: you asked for $VERSION but dist/VideoPro.app is $BUILT"
  echo "  bump MARKETING_VERSION in the Xcode project, then re-run package-app.sh"
  exit 1
fi

# ── Sparkle tools (ship inside the resolved package) ─────────────────────────
# Prefer THIS project's resolved copy, and never match old_dsa_scripts/ — that
# holds the legacy DSA signer, which would produce signatures Sparkle 2 rejects.
find_tool () {
  find "$HOME/Library/Developer/Xcode/DerivedData" \
       -type f -name "$1" -path "*sparkle*" -not -path "*old_dsa_scripts*" 2>/dev/null \
    | sort -r | grep -m1 "VideoProApp" \
    || find "$HOME/Library/Developer/Xcode/DerivedData" \
         -type f -name "$1" -path "*sparkle*" -not -path "*old_dsa_scripts*" 2>/dev/null | head -1
}
GENERATE_APPCAST="$(find_tool generate_appcast)"
[ -n "$GENERATE_APPCAST" ] || { echo "✗ generate_appcast not found — open the project in Xcode once to resolve Sparkle"; exit 1; }
echo "→ using $GENERATE_APPCAST"

# ── 1. Developer ID sign (Sparkle updates must pass Gatekeeper) ──────────────
#
# Skip entirely if we already have a notarized+stapled DMG for this version.
# Re-signing rebuilds the DMG, which INVALIDATES the notarization ticket — so
# re-running the script after notarizing used to throw the ticket away and demand
# notarization again, forever.
if [ -f "$DMG" ] && xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  echo "✓ dist/VideoPro.dmg is already notarized + stapled — skipping sign/rebuild"
else

echo "→ signing with Developer ID + hardened runtime…"
sign () { codesign --force --options runtime --timestamp -s "$DEVID" "$@"; }

# Bundled tools. These need disable-library-validation: yt-dlp is a PyInstaller
# binary that dlopen()s its own Python framework, which Hardened Runtime's library
# validation rejects once we re-sign with our Team ID — yt-dlp then exits 255 on
# every download. (This shipped broken in 1.0.8; local ad-hoc builds don't hit it
# because they aren't hardened.) See scripts/tool-entitlements.plist.
TOOL_ENTS="$ROOT/scripts/tool-entitlements.plist"
find "$APP/Contents/Resources/bin" -type f -perm +111 -exec \
  codesign --force --options runtime --timestamp \
    --entitlements "$TOOL_ENTS" -s "$DEVID" {} \;

# Sparkle must be signed INSIDE-OUT. `codesign` on a framework does NOT recurse
# into nested bundles, so signing only the framework left Autoupdate, Updater.app
# and the XPC services ad-hoc — which Apple rejects, producing an Invalid
# notarization and a "staple and validate failed! Error 65".
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  SPV="$SPARKLE/Versions/Current"
  for x in "$SPV/XPCServices/"*.xpc; do [ -e "$x" ] && sign "$x"; done
  [ -e "$SPV/Updater.app" ] && sign "$SPV/Updater.app"
  [ -e "$SPV/Autoupdate" ] && sign "$SPV/Autoupdate"
  sign "$SPARKLE"
fi

# Any other frameworks, then plug-ins, then the app itself (outermost last).
for f in "$APP/Contents/Frameworks/"*; do
  [ "$f" = "$SPARKLE" ] && continue
  [ -e "$f" ] && sign "$f"
done
for p in "$APP/Contents/PlugIns/"*; do [ -e "$p" ] && sign "$p"; done
sign "$APP"

# Fail loudly here rather than 20 minutes later at Apple: every executable must
# carry a Developer ID, not adhoc.
echo "→ verifying no ad-hoc signatures remain…"
ADHOC=0
while IFS= read -r m; do
  if codesign -dvv "$m" 2>&1 | grep -q "Signature=adhoc"; then
    echo "  ✗ still ad-hoc: ${m#"$APP/"}"; ADHOC=1
  fi
done < <(find "$APP" \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.appex" \) -print; \
         find "$APP/Contents/Resources/bin" -type f -perm +111 -print 2>/dev/null; \
         find "$APP/Contents/Frameworks" -maxdepth 3 -type f -perm +111 -print 2>/dev/null)
[ "$ADHOC" -eq 0 ] || { echo "✗ ad-hoc code would fail notarization — aborting"; exit 1; }
codesign --verify --strict --deep "$APP" && echo "  ✓ signed, no ad-hoc code"

# RUNTIME smoke test — the check that would have caught 1.0.8 shipping broken.
# `codesign --verify` and notarization both PASS on a yt-dlp that can't actually
# launch (library validation only bites at dlopen time). So actually run the
# signed tools and fail if they can't start.
echo "→ smoke-testing the signed tools (they must actually run)…"
YTDLP="$APP/Contents/Resources/bin/yt-dlp"
if ! "$YTDLP" --version >/dev/null 2>&1; then
  echo "✗ bundled yt-dlp fails to run after signing:"
  "$YTDLP" --version 2>&1 | head -3 | sed 's/^/    /'
  echo "  (usually a Hardened Runtime / library-validation issue — see tool-entitlements.plist)"
  exit 1
fi
for t in ffmpeg ffprobe; do
  "$APP/Contents/Resources/bin/$t" -version >/dev/null 2>&1 \
    || { echo "✗ bundled $t fails to run after signing"; exit 1; }
done
echo "  ✓ yt-dlp $("$YTDLP" --version 2>/dev/null) + ffmpeg/ffprobe run"

# Rebuild the DMG from the now-properly-signed app.
echo "→ rebuilding DMG from the signed app…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "VideoPro" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force -s "$DEVID" "$DMG"

fi  # end sign/build

# ── 2. Notarize — YOU must run this ──────────────────────────────────────────
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  cat <<EOF

┌────────────────────────────────────────────────────────────────────────┐
│  NOTARIZE NOW, THEN RE-RUN THIS SCRIPT                                  │
│                                                                        │
│  Updates that aren't notarized will download and then fail to launch.   │
│  This step needs your app-specific password, so you run it, not me:     │
│                                                                        │
│    xcrun notarytool submit "$DMG" \\
│      --keychain-profile VIDEOPRO --wait                                │
│    xcrun stapler staple "$DMG"                                         │
│                                                                        │
│  If submit says "Invalid" (and stapler then fails with Error 65),      │
│  ask Apple exactly why — don't guess:                                  │
│    xcrun notarytool log <submission-id> --keychain-profile VIDEOPRO    │
│                                                                        │
│  (one-time, if you haven't stored the profile:)                        │
│    xcrun notarytool store-credentials VIDEOPRO \\
│      --apple-id "<you@example.com>" --team-id 7MGPA96634               │
│                                                                        │
│  Then re-run this script — it will detect the stapled DMG and skip     │
│  straight to publishing (it will NOT re-sign and invalidate it).       │
└────────────────────────────────────────────────────────────────────────┘
EOF
  exit 2
fi
echo "  ✓ notarized + stapled"

# ── 3. Appcast ───────────────────────────────────────────────────────────────
# generate_appcast wants a directory of archives; it signs each with the EdDSA
# key from your Keychain and emits appcast.xml.
echo "→ generating appcast…"
FEEDDIR="$DIST/feed"
rm -rf "$FEEDDIR"; mkdir -p "$FEEDDIR"
cp "$DMG" "$FEEDDIR/VideoPro-$VERSION.dmg"

DL_BASE="https://github.com/TylerSimmons212/videopro/releases/download/v$VERSION"
"$GENERATE_APPCAST" --download-url-prefix "$DL_BASE/" \
                    --link "https://github.com/TylerSimmons212/videopro" \
                    -o "$ROOT/appcast.xml" "$FEEDDIR"
echo "  ✓ wrote appcast.xml"
grep -o 'sparkle:edSignature="[^"]\{0,18\}' "$ROOT/appcast.xml" | head -3 | sed 's/^/    /'

# ── 4. Publish ───────────────────────────────────────────────────────────────
# NB: braces are load-bearing. `$VERSION…` let bash absorb the UTF-8 ellipsis
# into the variable name, so it looked up `VERSION…`, found nothing, and `set -u`
# aborted the release right after notarization had already succeeded.
echo "→ publishing GitHub release v${VERSION}…"
gh release create "v$VERSION" "$FEEDDIR/VideoPro-$VERSION.dmg" \
  --title "VideoPro $VERSION" \
  --notes "See the changelog. Existing users get this automatically via Sparkle." \
  || gh release upload "v$VERSION" "$FEEDDIR/VideoPro-$VERSION.dmg" --clobber

# The feed is served from the repo, so it must be committed for anyone to see it.
git add "$ROOT/appcast.xml"
git commit -m "Release $VERSION: update appcast" >/dev/null 2>&1 || true
git push origin "$FEED_BRANCH"

echo
echo "✓ Released $VERSION"
echo "  feed:  https://raw.githubusercontent.com/TylerSimmons212/videopro/$FEED_BRANCH/appcast.xml"
echo "  Users on an earlier Sparkle-enabled build will be offered this within 24h."
