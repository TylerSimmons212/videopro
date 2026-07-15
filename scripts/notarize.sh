#!/usr/bin/env bash
#
# Sign (Developer ID + Hardened Runtime) and notarize VideoPro.app + DMG.
#
# ── One-time setup (run this YOURSELF so you type the password) ───────────────
#   Generate a FRESH app-specific password at appleid.apple.com, then:
#
#     xcrun notarytool store-credentials VIDEOPRO \
#       --apple-id "tylersimmons212@gmail.com" \
#       --team-id  "7MGPA96634" \
#       --password "<your-fresh-app-specific-password>"
#
#   (This stores it in your login keychain under the profile name "VIDEOPRO".
#    The password never appears in this script or the repo.)
#
# ── Then just run ─────────────────────────────────────────────────────────────
#     bash scripts/package-app.sh     # if you haven't built dist/VideoPro.app
#     bash scripts/notarize.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/VideoPro.app"
DMG="$DIST/VideoPro.dmg"
DEV_ID="Developer ID Application: Tyler Simmons (7MGPA96634)"
PROFILE="VIDEOPRO"

[ -d "$APP" ] || { echo "✗ $APP not found — run: bash scripts/package-app.sh"; exit 1; }

# yt-dlp is a PyInstaller binary; it needs these to run under Hardened Runtime.
ENT="$(mktemp).plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.cs.allow-jit</key><true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
	<key>com.apple.security.cs.disable-library-validation</key><true/>
	<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
</dict></plist>
PLIST

echo "→ signing bundled binaries (Developer ID + hardened runtime)…"
codesign --force --timestamp --options runtime --entitlements "$ENT" -s "$DEV_ID" "$APP/Contents/Resources/bin/yt-dlp"
codesign --force --timestamp --options runtime                        -s "$DEV_ID" "$APP/Contents/Resources/bin/ffmpeg"
codesign --force --timestamp --options runtime                        -s "$DEV_ID" "$APP/Contents/Resources/bin/ffprobe"

# Sign the embedded Safari extension (nested code must be signed before the app).
APPEX="$APP/Contents/PlugIns/safari.appex"
if [ -d "$APPEX" ]; then
  echo "→ signing the Safari extension…"
  codesign --force --timestamp --options runtime --preserve-metadata=entitlements -s "$DEV_ID" "$APPEX"
fi

echo "→ signing the app…"
codesign --force --timestamp --options runtime -s "$DEV_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "→ rebuilding DMG…"
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname VideoPro -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "→ submitting to Apple notary (uses your stored '$PROFILE' credentials)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "→ stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo "✓ Notarized & stapled: $DMG"
