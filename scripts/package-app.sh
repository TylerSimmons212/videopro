#!/usr/bin/env bash
#
# Build a self-contained, distributable VideoPro.app + DMG.
#
#   1. fetch the pinned yt-dlp, static ffmpeg/ffprobe and Deno (scripts/binaries.lock),
#      each verified against its SHA-256
#   2. build the Release app
#   3. embed the binaries in Contents/Resources/bin
#   4. ad-hoc sign (so it runs locally / with a one-time right-click→Open)
#   5. package as VideoPro.dmg
#
# For frictionless distribution to anyone, follow the notarization steps this
# script prints at the end (needs your Apple Developer ID).
#
# Usage:  bash scripts/package-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/VideoProApp/VideoProApp.xcodeproj"
DIST="$ROOT/dist"
BIN="$DIST/bin"
BUILD="$DIST/build"
APP="$DIST/VideoPro.app"

rm -rf "$DIST"
mkdir -p "$BIN" "$BUILD"

# ── 1. binaries (pinned + verified; cached in .cache/downloads) ──────────────
# Downloads live OUTSIDE dist/, which is wiped on every run: a flaky mirror
# (martin-riedl 522s) once destroyed the ability to build at all, right after
# the old build had been replaced. Cached files are re-hashed before use.
# shellcheck source=tools.sh
source "$ROOT/scripts/tools.sh"
fetch_tools "$BIN"

# A stale yt-dlp is the likeliest way for a release to ship broken: YouTube
# starts refusing versions a few months old.
AGE="$(ytdlp_pin_age_days)"
if [ "$AGE" -gt 60 ]; then
  echo "⚠ the pinned yt-dlp ($YTDLP_VERSION) is $AGE days old — run scripts/pin-binaries.sh before releasing"
fi

# ── 2. build Release ─────────────────────────────────────────────────────────
# Sparkle decides "is this newer?" from CFBundleVersion (sparkle:version), NOT
# from the marketing version. The project hard-codes CURRENT_PROJECT_VERSION = 1,
# so without this every release would look like version "1" to Sparkle and no
# update would EVER be offered. Derive a monotonic build number instead.
MV="$(grep -m1 'MARKETING_VERSION = ' "$PROJ/project.pbxproj" | sed 's/.*= *//; s/;//')"
IFS=. read -r _MA _MI _PA <<< "$MV"
BUILD_NUM=$(( ${_MA:-0} * 10000 + ${_MI:-0} * 100 + ${_PA:-0} ))
echo "→ building Release ($MV, CFBundleVersion $BUILD_NUM)…"
xcodebuild -project "$PROJ" -scheme VideoProApp -configuration Release \
  -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$BUILD" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  build >/dev/null
rm -rf "$APP"
cp -R "$BUILD/VideoProApp.app" "$APP"

# ── 3. embed binaries ────────────────────────────────────────────────────────
echo "→ embedding binaries…"
mkdir -p "$APP/Contents/Resources/bin"
cp "$BIN/yt-dlp" "$BIN/ffmpeg" "$BIN/ffprobe" "$BIN/deno" "$APP/Contents/Resources/bin/"
chmod +x "$APP/Contents/Resources/bin/"*

# ── 4. ad-hoc sign (nested first, then the app) ──────────────────────────────
echo "→ signing (ad-hoc)…"
for b in yt-dlp ffmpeg ffprobe deno; do
  codesign --force -s - "$APP/Contents/Resources/bin/$b"
done
codesign --force -s - "$APP"
codesign --verify --strict "$APP" && echo "  signature ok"

# ── 5. DMG ───────────────────────────────────────────────────────────────────
echo "→ building DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "VideoPro" -srcfolder "$STAGE" -ov -format UDZO "$DIST/VideoPro.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "✓ Built:"
echo "   $APP"
echo "   $DIST/VideoPro.dmg  ($(du -h "$DIST/VideoPro.dmg" | cut -f1))"
echo
echo "Bundled tool versions (from inside the .app):"
"$APP/Contents/Resources/bin/yt-dlp" --version 2>/dev/null | sed 's/^/   yt-dlp /'
"$APP/Contents/Resources/bin/ffmpeg" -version 2>/dev/null | head -1 | sed 's/^/   /'
"$APP/Contents/Resources/bin/deno" --version 2>/dev/null | head -1 | sed 's/^/   /'
# yt-dlp has to actually find the bundled runtime, not merely have it nearby.
# Captured first: with no URL yt-dlp exits 2, which pipefail would turn into a
# failed build.
YT_DEBUG="$("$APP/Contents/Resources/bin/yt-dlp" -v --js-runtimes "deno:$APP/Contents/Resources/bin/deno" 2>&1 || true)"
echo "$YT_DEBUG" | grep "JS runtimes" | head -1 | sed 's/^\[debug\] /   yt-dlp sees /'
echo
echo "── To distribute to ANYONE (frictionless), notarize with your Apple ID: ──"
cat <<'NOTARIZE'
   # one-time: store credentials
   xcrun notarytool store-credentials VIDEOPRO \
     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"

   # sign with Developer ID + hardened runtime, then notarize the DMG
   codesign --force --options runtime --deep \
     --sign "Developer ID Application: Your Name (TEAMID)" dist/VideoPro.app
   xcrun notarytool submit dist/VideoPro.dmg --keychain-profile VIDEOPRO --wait
   xcrun stapler staple dist/VideoPro.dmg
NOTARIZE
