#!/usr/bin/env bash
#
# Build the downloadable plugin zip.
#
# It ships ONLY what the plugin needs to run: _meta.lua, main.lua, the ink/ code,
# and the licence/readme. It deliberately leaves out the screenshots (assets/),
# the tests, and the dev tooling, so the download people install stays tiny
# (~70 KB) instead of pulling megabytes of images they will never use.
#
#   ./tools/build-release.sh          # -> dist/ink-away.koplugin-vX.Y.Z.zip

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="ink-away.koplugin"
VER="$(grep -oE 'version = "[0-9]+\.[0-9]+\.[0-9]+"' _meta.lua | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
OUT="dist"
ZIP="$OUT/$NAME-v$VER.zip"

rm -rf "$OUT"
mkdir -p "$OUT/$NAME"

# Only the runtime files. No assets/, tests/, tools/, dist/, .git.
cp -R _meta.lua main.lua ink README.md NOTICE.md LICENSE "$OUT/$NAME/"

# Belt and suspenders: make sure nothing heavy or dev-only slipped in.
rm -rf "$OUT/$NAME/assets" "$OUT/$NAME/tests" "$OUT/$NAME/tools" "$OUT/$NAME/dist"
find "$OUT/$NAME" -name '.DS_Store' -delete 2>/dev/null || true

( cd "$OUT" && zip -rq "$NAME-v$VER.zip" "$NAME" )

echo "Built $ZIP"
du -h "$ZIP"
echo "Contents:"
unzip -l "$ZIP" | awk '{print $4}' | grep -E '\.(lua|md|txt)$|LICENSE' | sed 's#^#  #'
