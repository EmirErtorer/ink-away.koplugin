#!/usr/bin/env bash
# Real-widget benchmark of two versions in the KOReader emulator:
#
#   tests/performance/emulator/compare.sh [old_ref] [new_ref] [rounds]
#
# Defaults: main, HEAD, 5 rounds, each on a grey and a colour 758x1024 screen,
# old and new alternating which goes first. Results go to
# tests/performance/out/emulator (or $OUT), then:
#
#   python3 tests/performance/analyze.py B tests/performance/out/emulator
#
# The emulator's own copy of the plugin is replaced while it runs and the
# checkout is installed again at the end.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OLD_REF=${1:-main}
NEW_REF=${2:-HEAD}
R=${3:-5}
KO_SRC=${KO_SRC:-$HOME/koreader-emulator}
OUT=${OUT:-$HERE/../out/emulator}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/old" "$WORK/new"
git -C "$ROOT" archive "$OLD_REF" | tar -x -C "$WORK/old"
git -C "$ROOT" archive "$NEW_REF" | tar -x -C "$WORK/new"
rm -rf "$OUT"; mkdir -p "$OUT"
for r in $(seq 1 "$R"); do
    if (( r % 2 )); then order="old new"; else order="new old"; fi
    for prof in grey:1 colour:0; do
        IFS=: read -r name mono <<<"$prof"
        for ver in $order; do
            d="$WORK/run_${ver}_${name}_r${r}"
            MONO="$mono" bash "$HERE/run.sh" "$WORK/$ver" "$d" 758 1024 212 > /dev/null 2>&1
            if [ -s "$d/perf.txt" ]; then
                cp "$d/perf.txt" "$OUT/${ver}_${name}_r${r}.txt"; echo "round $r $ver $name: ok"
            else
                echo "round $r $ver $name: no results (see $d/emulator.log)"
            fi
        done
    done
done
rsync -a --delete --exclude '.git' --exclude 'dist' --exclude 'tools' --exclude 'tests' \
    --exclude 'assets' --exclude '.DS_Store' "$ROOT/" "$KO_SRC/plugins/ink-away.koplugin/"
echo "Done. Results in $OUT"
