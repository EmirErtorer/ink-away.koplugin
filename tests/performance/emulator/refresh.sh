#!/usr/bin/env bash
# E-ink refresh audit of versions of the plugin in the KOReader emulator: for
# each action, the refreshes that reach the panel (and which flash), the screen
# share they cover, and the CPU time of the repaint.
#
#   tests/performance/emulator/refresh.sh [rounds] label=ref [label=ref ...]
#
# e.g. refresh.sh 3 main=main new=HEAD. Grey and colour 758x1024, each label in
# turn per round. Results go to tests/performance/out/refresh (or $OUT), then:
#
#   python3 tests/performance/refresh_compare.py tests/performance/out/refresh main new
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
R=${1:-3}; shift
KO_SRC=${KO_SRC:-$HOME/koreader-emulator}
OUT=${OUT:-$HERE/../out/refresh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"
labels=()
for pair in "$@"; do
    label=${pair%%=*}; ref=${pair#*=}
    mkdir -p "$WORK/$label"
    git -C "$ROOT" archive "$ref" | tar -x -C "$WORK/$label"
    labels+=("$label")
done
for r in $(seq 1 "$R"); do
    for label in "${labels[@]}"; do
        for prof in grey:1 colour:0; do
            IFS=: read -r name mono <<<"$prof"
            d="$WORK/run_${label}_${name}_r${r}"
            SCENARIO="$HERE/refreshaudit.lua" MONO="$mono" bash "$HERE/run.sh" "$WORK/$label" "$d" 758 1024 212 > /dev/null 2>&1
            if [ -s "$d/refresh.txt" ]; then cp "$d/refresh.txt" "$OUT/${label}_${name}_r${r}.txt"; echo "round $r $label $name: ok"
            else echo "round $r $label $name: no results (see $d/emulator.log)"; fi
        done
    done
done
rsync -a --delete --exclude '.git' --exclude 'dist' --exclude 'tools' --exclude 'tests' \
    --exclude 'assets' --exclude '.DS_Store' "$ROOT/" "$KO_SRC/plugins/ink-away.koplugin/"
echo "Done. Results in $OUT"
