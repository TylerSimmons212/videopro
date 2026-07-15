#!/usr/bin/env bash
#
# Fetch the standalone binaries VideoProApp bundles so it runs WITHOUT Homebrew.
#
#   • yt-dlp  — official standalone build from github.com/yt-dlp/yt-dlp (trusted)
#   • ffmpeg  — static macOS build from evermeet.cx (the de-facto static ffmpeg)
#   • ffprobe — same source
#
# They're placed in VideoProApp/VideoProApp/bin/. To ship them inside the .app,
# add that `bin` folder to the Xcode target as a **folder reference** (blue
# folder → "Create folder references") so it copies to Contents/Resources/bin/.
# The app's DownloadManager already searches Resources/bin first.
#
# Usage:  bash scripts/fetch-binaries.sh
set -euo pipefail

ARCH="$(uname -m)"          # arm64 or x86_64
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HERE/VideoProApp/VideoProApp/bin"
mkdir -p "$BIN"

echo "→ target: $BIN  (arch: $ARCH)"

# ── yt-dlp (official standalone) ─────────────────────────────────────────────
if [ "$ARCH" = "arm64" ]; then
  YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
else
  YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
fi
echo "→ downloading yt-dlp…"
curl -L --fail --progress-bar "$YTDLP_URL" -o "$BIN/yt-dlp"
chmod +x "$BIN/yt-dlp"

# ── ffmpeg + ffprobe (static, arch-matched) ──────────────────────────────────
MR_ARCH="arm64"; [ "$ARCH" = "x86_64" ] && MR_ARCH="amd64"
fetch_ff () {
  local name="$1"
  echo "→ downloading $name ($MR_ARCH)…"
  local tmp; tmp="$(mktemp -d)"
  curl -L --fail --progress-bar \
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$MR_ARCH/release/$name.zip" -o "$tmp/$name.zip"
  ( cd "$tmp" && unzip -oq "$name.zip" )
  mv "$tmp/$name" "$BIN/$name"
  chmod +x "$BIN/$name"
  rm -rf "$tmp"
}
fetch_ff ffmpeg
fetch_ff ffprobe

# Strip quarantine so Gatekeeper doesn't block the bundled tools on first run.
xattr -dr com.apple.quarantine "$BIN" 2>/dev/null || true

echo
echo "✓ Done. Bundled binaries:"
for b in yt-dlp ffmpeg ffprobe; do
  printf "   %-8s %s\n" "$b" "$("$BIN/$b" -version 2>/dev/null | head -1 || echo '(run failed — check Gatekeeper)')"
done
echo
echo "Next: in Xcode, drag VideoProApp/VideoProApp/bin into the project as a"
echo "\"folder reference\" (blue folder) so it ships in Contents/Resources/bin/."
