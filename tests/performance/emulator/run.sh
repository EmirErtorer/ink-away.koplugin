#!/usr/bin/env bash
# One run of perfemu.lua in the KOReader emulator:
#
#   emulator/run.sh <plugin_dir> <out_dir> [W H DPI]
#
# Installs <plugin_dir> as the emulator's ink-away.koplugin (replacing what is
# there; compare.sh puts the checkout back afterwards), starts KOReader with a
# throwaway home in <out_dir> that has the driver plugin, and leaves perf.txt
# there. MONO=0 gives a colour screen.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$1"; OUT="$2"; shift 2
W="${1:-758}"; H="${2:-1024}"; DPI="${3:-212}"
KO_SRC=${KO_SRC:-$HOME/koreader-emulator}
EMU=${KO_EMU:-$(ls -d "$KO_SRC"/koreader-emulator-*/koreader | head -1)}
TIMEOUT_CMD=$(command -v gtimeout || command -v timeout)
rm -rf "$OUT"; mkdir -p "$OUT/home/plugins" "$OUT/home/settings" "$OUT/home/docs"
OUT="$(cd "$OUT" && pwd)"
rsync -a --delete --exclude '.git' --exclude 'dist' --exclude 'tools' --exclude 'tests' \
    --exclude 'assets' --exclude '.DS_Store' "$PLUGIN/" "$KO_SRC/plugins/ink-away.koplugin/"
cp -R "$HERE/drive.koplugin" "$OUT/home/plugins/"
luajit "$HERE/mkhome.lua" "$EMU/settings.reader.lua" "$OUT/home/settings.reader.lua" "$OUT/home"
cd "$EMU"
# the plugin treats the variable being set at all as "grey screen", so a colour
# run (MONO=0) leaves it out
MONOENV=(env); [ "${MONO-1}" = "1" ] && MONOENV=(env INKAWAY_FORCE_MONO=1)
set +e
KO_HOME="$OUT/home" XDG_DOCUMENTS_DIR="$OUT/home/docs" "${MONOENV[@]}" \
    INKAWAY_DRIVE_SCRIPT="$HERE/perfemu.lua" INKAWAY_DRIVE_OUT="$OUT" \
    EMULATE_READER_W="$W" EMULATE_READER_H="$H" EMULATE_READER_DPI="$DPI" \
    $TIMEOUT_CMD "${TIMEOUT:-240}" ./luajit reader.lua "$OUT/home/docs" > "$OUT/emulator.log" 2>&1
echo "emulator exit: $?"
