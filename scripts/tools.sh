#!/usr/bin/env bash
#
# Shared by package-app.sh and fetch-binaries.sh: download the pinned tools in
# scripts/binaries.lock, verify each against its SHA-256, and install them into
# a folder.
#
#   source scripts/tools.sh
#   fetch_tools <dest-dir>        # yt-dlp, ffmpeg, ffprobe, deno for this Mac's arch
#   ytdlp_pin_age_days            # days since the pinned yt-dlp release
#
# Verified downloads are cached in .cache/downloads/<sha256>, so a rebuild needs
# no network, and a cached file is re-hashed before every use.

TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=binaries.lock
source "$TOOLS_ROOT/scripts/binaries.lock"
TOOLS_CACHE="$TOOLS_ROOT/.cache/downloads"

# Martin Riedl and Deno name the architectures differently from uname.
tools_arch () {
  case "$(uname -m)" in
    arm64)  echo arm64 ;;
    x86_64) echo amd64 ;;
    *) echo "✗ unsupported architecture $(uname -m)" >&2; return 1 ;;
  esac
}

sha256_of () { shasum -a 256 "$1" | cut -d' ' -f1; }

# fetch_verified <url> <sha256> → prints the path of a verified local copy.
fetch_verified () {
  local url="$1" want="$2"
  local cached="$TOOLS_CACHE/$want"
  mkdir -p "$TOOLS_CACHE"
  if [ -f "$cached" ] && [ "$(sha256_of "$cached")" = "$want" ]; then
    echo "$cached"; return 0
  fi
  rm -f "$cached"
  local tmp; tmp="$(mktemp "$TOOLS_CACHE/.partial.XXXXXX")"
  local attempt
  for attempt in 1 2 3; do
    if curl -L --fail --silent --show-error --max-time 300 "$url" -o "$tmp"; then break; fi
    echo "  ⚠ download attempt $attempt failed: $url" >&2
    [ "$attempt" = 3 ] && { rm -f "$tmp"; return 1; }
    sleep 3
  done
  local got; got="$(sha256_of "$tmp")"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    echo "✗ checksum mismatch for $url" >&2
    echo "    expected $want" >&2
    echo "    got      $got" >&2
    echo "  Refusing to use it. If the pin is simply out of date, run scripts/pin-binaries.sh." >&2
    return 1
  fi
  mv "$tmp" "$cached"
  echo "$cached"
}

# install_from_zip <zip> <name> <dest-dir>
install_from_zip () {
  local tmp; tmp="$(mktemp -d)"
  unzip -oq "$1" -d "$tmp"
  [ -f "$tmp/$2" ] || { echo "✗ $2 not found inside $(basename "$1")" >&2; rm -rf "$tmp"; return 1; }
  mv -f "$tmp/$2" "$3/$2"
  rm -rf "$tmp"
}

fetch_tools () {
  local dest="$1" arch file
  arch="$(tools_arch)" || return 1
  mkdir -p "$dest"

  echo "→ yt-dlp $YTDLP_VERSION"
  file="$(fetch_verified "$YTDLP_URL" "$YTDLP_SHA256")" || return 1
  cp -f "$file" "$dest/yt-dlp"

  local ff_url ff_sha fp_url fp_sha deno_url deno_sha
  eval "ff_url=\$FFMPEG_${arch}_URL ff_sha=\$FFMPEG_${arch}_SHA256"
  eval "fp_url=\$FFPROBE_${arch}_URL fp_sha=\$FFPROBE_${arch}_SHA256"
  eval "deno_url=\$DENO_${arch}_URL deno_sha=\$DENO_${arch}_SHA256"

  echo "→ ffmpeg + ffprobe $FFMPEG_VERSION ($arch)"
  file="$(fetch_verified "$ff_url" "$ff_sha")" || return 1
  install_from_zip "$file" ffmpeg "$dest" || return 1
  file="$(fetch_verified "$fp_url" "$fp_sha")" || return 1
  install_from_zip "$file" ffprobe "$dest" || return 1

  # yt-dlp needs a JavaScript runtime for YouTube's challenges; without one it
  # sees fewer formats and the fallback is deprecated. The app passes this path
  # to yt-dlp with --js-runtimes.
  echo "→ deno $DENO_VERSION ($arch)"
  file="$(fetch_verified "$deno_url" "$deno_sha")" || return 1
  install_from_zip "$file" deno "$dest" || return 1

  chmod +x "$dest/yt-dlp" "$dest/ffmpeg" "$dest/ffprobe" "$dest/deno"
  xattr -cr "$dest" 2>/dev/null || true
  echo "✓ tools verified and installed in $dest"
}

# Days since the pinned yt-dlp was released (its version is its date).
ytdlp_pin_age_days () {
  local released now
  released="$(date -j -f "%Y.%m.%d" "$YTDLP_VERSION" "+%s" 2>/dev/null)" || { echo 0; return; }
  now="$(date "+%s")"
  echo $(( (now - released) / 86400 ))
}
