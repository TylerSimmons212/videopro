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

# ── Stamp the version from the app ───────────────────────────────────────────
# The extension only ever ships inside the app, so it should report the app's
# version. Left to drift by hand it went stale immediately: the Chrome manifest
# still said 0.4.0 (untouched since the first commit) while the Safari one said
# 1.0.1 and the app said 1.0.8 — three answers to "what version are you on?",
# and no way to tell from the browser whether you had current code.
PBX="$HERE/VideoProApp/VideoProApp.xcodeproj/project.pbxproj"
VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PBX" | sed 's/.*= *//; s/;//')"
[ -n "$VERSION" ] || { echo "✗ couldn't read MARKETING_VERSION from $PBX"; exit 1; }

stamp_version () {  # $1 = manifest path
  VP_VERSION="$VERSION" python3 - "$1" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    manifest = json.load(f)
manifest["version"] = os.environ["VP_VERSION"]
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
}
stamp_version "$SRC/manifest.json"
echo "✓ stamped extension version $VERSION"

rm -f "$OUT"
( cd "$SRC" && zip -r -X -q "$OUT" . -x '*.DS_Store' -x '__MACOSX*' )

echo "✓ wrote $OUT"
unzip -l "$OUT" | awk 'NR>3 && NF>=4 {print "   " $4}' | grep -v '^   $' | head -20
