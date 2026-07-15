#!/usr/bin/env bash
#
# Package the browser extension into a single zip that ships inside the .app,
# so the app's "Get the extension…" button can hand it to users to load
# unpacked. Re-run this whenever the extension changes, then rebuild the app.
#
# Output: VideoProApp/VideoProApp/extension.zip  (files at the zip root, so
# unpacking yields a folder with manifest.json at the top — ready for
# "Load unpacked").
#
# Usage:  bash scripts/bundle-extension.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/extension"
OUT="$HERE/VideoProApp/VideoProApp/extension.zip"

[ -f "$SRC/manifest.json" ] || { echo "✗ no extension/manifest.json at $SRC"; exit 1; }

rm -f "$OUT"
( cd "$SRC" && zip -r -X -q "$OUT" . -x '*.DS_Store' -x '__MACOSX*' )

echo "✓ wrote $OUT"
unzip -l "$OUT" | awk 'NR>3 && NF>=4 {print "   " $4}' | grep -v '^   $' | head -20
