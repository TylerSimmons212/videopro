#!/usr/bin/env bash
#
# Fetch the tools VideoProApp bundles, so a development build runs WITHOUT
# Homebrew: yt-dlp, ffmpeg, ffprobe and Deno (yt-dlp's JavaScript runtime for
# YouTube). Exactly the versions pinned in scripts/binaries.lock, each verified
# against its SHA-256 — the same files package-app.sh ships.
#
# They're placed in VideoProApp/VideoProApp/bin/ (git-ignored). The app's
# DownloadManager searches its own Resources/bin first, then Homebrew.
#
# Usage:  bash scripts/fetch-binaries.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools.sh
source "$HERE/scripts/tools.sh"

BIN="$HERE/VideoProApp/VideoProApp/bin"
fetch_tools "$BIN"

echo
echo "Bundled versions:"
printf "   %-8s %s\n" yt-dlp  "$("$BIN/yt-dlp" --version 2>/dev/null || echo '(run failed)')"
printf "   %-8s %s\n" ffmpeg  "$("$BIN/ffmpeg" -version 2>/dev/null | head -1 || echo '(run failed)')"
printf "   %-8s %s\n" ffprobe "$("$BIN/ffprobe" -version 2>/dev/null | head -1 || echo '(run failed)')"
printf "   %-8s %s\n" deno    "$("$BIN/deno" --version 2>/dev/null | head -1 || echo '(run failed)')"
