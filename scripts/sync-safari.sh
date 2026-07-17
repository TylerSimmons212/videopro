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

# We don't copy the Safari manifest (its icon paths differ), but its VERSION must
# still track the app's — otherwise it drifts, which is exactly what happened:
# Safari said 1.0.1 while Chrome said 0.4.0 and the app said 1.0.8.
echo "→ stamping version…"
PBX="$ROOT/VideoProApp/VideoProApp.xcodeproj/project.pbxproj"
VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PBX" | sed 's/.*= *//; s/;//')"
[ -n "$VERSION" ] || { echo "✗ couldn't read MARKETING_VERSION"; exit 1; }
VP_VERSION="$VERSION" python3 - "$DST/manifest.json" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    manifest = json.load(f)
manifest["version"] = os.environ["VP_VERSION"]
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "✓ Safari extension synced at version $VERSION (manifest keys left intact — only version stamped)."
