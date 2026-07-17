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
echo "→ signing with Developer ID + hardened runtime…"
# Nested code first, then the app. --deep is deprecated/unreliable for this.
find "$APP/Contents/Resources/bin" -type f -perm +111 -exec \
  codesign --force --options runtime --timestamp -s "$DEVID" {} \;
if [ -d "$APP/Contents/Frameworks" ]; then
  for f in "$APP/Contents/Frameworks/"*; do
    codesign --force --options runtime --timestamp -s "$DEVID" "$f"
  done
fi
if [ -d "$APP/Contents/PlugIns" ]; then
  for p in "$APP/Contents/PlugIns/"*; do
    codesign --force --options runtime --timestamp -s "$DEVID" "$p"
  done
fi
codesign --force --options runtime --timestamp -s "$DEVID" "$APP"
codesign --verify --strict --verbose=1 "$APP" && echo "  ✓ signed"

# Rebuild the DMG from the now-properly-signed app.
echo "→ rebuilding DMG from the signed app…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "VideoPro" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force -s "$DEVID" "$DMG"

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
│  (one-time, if you haven't stored the profile:)                        │
│    xcrun notarytool store-credentials VIDEOPRO \\
│      --apple-id "<you@example.com>" --team-id 7MGPA96634               │
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
echo "→ publishing GitHub release v$VERSION…"
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
