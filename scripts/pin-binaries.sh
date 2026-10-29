#!/usr/bin/env bash
#
# Bump scripts/binaries.lock to the latest yt-dlp, ffmpeg/ffprobe and Deno.
#
# Each file is downloaded and checked against the checksum its publisher posts
# (yt-dlp's SHA2-256SUMS, Deno's .sha256sum, Martin Riedl's .sha256); only then
# is its hash written to the lock. Run this before every release — yt-dlp most
# of all, since YouTube starts refusing versions a few months old — then commit
# the updated lock.
#
# Usage:  bash scripts/pin-binaries.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/binaries.lock"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sha256_of () { shasum -a 256 "$1" | cut -d' ' -f1; }

# The tag a GitHub "latest release" redirect points at.
latest_tag () {
  curl -sIL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'
}

# verify <url> <published-sha256> → the verified sha256, or fail.
verify () {
  local url="$1" published="$2" file="$WORK/$(basename "$1")-$RANDOM"
  [[ "$published" =~ ^[0-9a-f]{64}$ ]] || { echo "✗ no published checksum for $url" >&2; return 1; }
  curl -sL --fail --max-time 300 "$url" -o "$file" || { echo "✗ download failed: $url" >&2; return 1; }
  local got; got="$(sha256_of "$file")"
  [ "$got" = "$published" ] || { echo "✗ $url doesn't match its published checksum" >&2; return 1; }
  echo "  ✓ $(basename "$url")" >&2
  echo "$got"
}

first_hash () { grep -o -E '[0-9a-f]{64}' | head -1; }

# ── yt-dlp ───────────────────────────────────────────────────────────────────
YT="$(latest_tag yt-dlp/yt-dlp)"
echo "→ yt-dlp $YT"
YT_URL="https://github.com/yt-dlp/yt-dlp/releases/download/$YT/yt-dlp_macos"
YT_PUB="$(curl -sL --fail "https://github.com/yt-dlp/yt-dlp/releases/download/$YT/SHA2-256SUMS" \
  | awk '$2 == "yt-dlp_macos" { print $1 }')"
YT_SHA="$(verify "$YT_URL" "$YT_PUB")"

# ── ffmpeg / ffprobe (Martin Riedl's static builds) ──────────────────────────
# "latest" is a redirect to a versioned folder; pin the folder, not the redirect.
# Plain variables (FF_ffmpeg_arm64_URL, …) rather than an associative array:
# macOS ships bash 3.2, which has none.
for arch in arm64 amd64; do
  for name in ffmpeg ffprobe; do
    url="$(curl -sL -o /dev/null -w '%{url_effective}' \
      "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$arch/release/$name.zip")"
    [[ "$url" == *"/download/"* ]] || { echo "✗ couldn't resolve the latest $name for $arch" >&2; exit 1; }
    echo "→ $name $arch: $url"
    sha="$(verify "$url" "$(curl -sL --fail "$url.sha256" | first_hash)")"
    printf -v "FF_${name}_${arch}_URL" '%s' "$url"
    printf -v "FF_${name}_${arch}_SHA" '%s' "$sha"
  done
done
FF_VERSION="$(basename "$(dirname "$FF_ffmpeg_arm64_URL")" | sed 's/^[0-9]*_//')"

# ── Deno ─────────────────────────────────────────────────────────────────────
DENO_TAG="$(latest_tag denoland/deno)"
echo "→ deno $DENO_TAG"
DENO_BASE="https://github.com/denoland/deno/releases/download/$DENO_TAG"
DENO_ARM="$DENO_BASE/deno-aarch64-apple-darwin.zip"
DENO_X86="$DENO_BASE/deno-x86_64-apple-darwin.zip"
DENO_ARM_SHA="$(verify "$DENO_ARM" "$(curl -sL --fail "$DENO_ARM.sha256sum" | first_hash)")"
DENO_X86_SHA="$(verify "$DENO_X86" "$(curl -sL --fail "$DENO_X86.sha256sum" | first_hash)")"

# ── write the lock (header kept, values replaced) ────────────────────────────
HEADER="$(sed -n '/^YTDLP_VERSION=/q;p' "$LOCK")"
# $(…) strips trailing newlines, so the blank line before the values is re-added.
cat > "$LOCK" <<EOF
$HEADER

YTDLP_VERSION="$YT"
YTDLP_URL="$YT_URL"
YTDLP_SHA256="$YT_SHA"

FFMPEG_VERSION="$FF_VERSION"
FFMPEG_arm64_URL="$FF_ffmpeg_arm64_URL"
FFMPEG_arm64_SHA256="$FF_ffmpeg_arm64_SHA"
FFPROBE_arm64_URL="$FF_ffprobe_arm64_URL"
FFPROBE_arm64_SHA256="$FF_ffprobe_arm64_SHA"
FFMPEG_amd64_URL="$FF_ffmpeg_amd64_URL"
FFMPEG_amd64_SHA256="$FF_ffmpeg_amd64_SHA"
FFPROBE_amd64_URL="$FF_ffprobe_amd64_URL"
FFPROBE_amd64_SHA256="$FF_ffprobe_amd64_SHA"

DENO_VERSION="${DENO_TAG#v}"
DENO_arm64_URL="$DENO_ARM"
DENO_arm64_SHA256="$DENO_ARM_SHA"
DENO_amd64_URL="$DENO_X86"
DENO_amd64_SHA256="$DENO_X86_SHA"
EOF

echo
echo "✓ Updated scripts/binaries.lock — yt-dlp $YT, ffmpeg $FF_VERSION, deno ${DENO_TAG#v}."
echo "  Review with: git diff scripts/binaries.lock"
