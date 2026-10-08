#!/usr/bin/env bash
# What each pen costs (tests/performance/pens.lua) on three screens: Kindle size
# grey, Kobo colour, Scribe size grey. Needs the KOReader emulator built (see
# tests/README.md). Results go to $OUT (tests/performance/out/pens by default).
#   tests/performance/pens.sh [repeats]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
KO_SRC=${KO_SRC:-$HOME/koreader-emulator}
KO=${KO_EMU:-$(ls -d "$KO_SRC"/koreader-emulator-*/koreader 2>/dev/null | head -1)}
if [ ! -x "$KO/luajit" ]; then echo "No emulator found; set KO_SRC or KO_EMU." >&2; exit 1; fi
OUT=${OUT:-$HERE/out/pens}
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
export PEN_REPEAT=${1:-5}
for cfg in "grey:0 1072x1448 grey-1072x1448" "colour:0 1264x1680 colour-1264x1680" "grey:0 1860x2480 grey-1860x2480"; do
    set -- $cfg
    ( cd "$KO" && BENCH_JITOPT="sizemcode=4096,maxmcode=4096,maxtrace=8000" \
        ./luajit "$HERE/pens.lua" "$ROOT" "$ROOT/tests/mock" "$1" "$OUT/$3.txt" "$2" >/dev/null 2>&1 )
    echo "== $3"; cat "$OUT/$3.txt"
done
