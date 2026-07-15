#!/usr/bin/env bash
#
# Keep the Safari Web Extension in sync with the Chrome extension.
# The JS/CSS/HTML is identical (same MV3 + chrome.* code); only the manifest
# differs (Safari icon paths), so we DON'T overwrite the Safari manifest.
#
# Run after editing anything in extension/, then rebuild the app.
#
# Usage:  bash scripts/sync-safari.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/extension"
DST="$ROOT/VideoProApp/safari/Resources"

[ -d "$DST" ] || { echo "✗ Safari target not found at $DST"; exit 1; }

echo "→ syncing scripts…"
cp "$SRC/content.js" "$SRC/background.js" "$SRC/focus.js" \
   "$SRC/popup.js" "$SRC/popup.css" "$SRC/popup.html" "$DST/"

echo "→ syncing icons…"
mkdir -p "$DST/images"
for s in 16 32 48 128; do cp "$SRC/icons/icon$s.png" "$DST/images/icon$s.png"; done

echo "✓ Safari extension synced (manifest left untouched — edit it separately if needed)."
