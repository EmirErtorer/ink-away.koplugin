#!/usr/bin/env bash
# Headless benchmark of two versions of the plugin on KOReader's real blitter.
# Run from anywhere in the repo:
#
#   tests/performance/run.sh [old_ref] [new_ref] [rounds]
#
# Defaults: main, HEAD, 10 rounds. Both refs are exported with git archive, so
# uncommitted changes are not measured. Needs the KOReader emulator built (see
# tests/README.md; KO_SRC / KO_EMU work the same way). Results go to
# tests/performance/out/ (or $OUT), then:
#
#   python3 tests/performance/analyze.py A tests/performance/out/main
#
# Three passes, each with old and new interleaved and their order alternating:
#   main      4 screen setups, `rounds` rounds, JIT tuned so LuaJIT never drops
#             its machine code (the macOS mcode allocation failures make default
#             runs bimodal)
#   big       a 120-page notebook, 5 rounds (BIG_ROUNDS), grey portrait
#   jit       LuaJIT defaults, 6 rounds (JIT_ROUNDS), grey and colour portrait:
#             how often compiled code gets flushed
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OLD_REF=${1:-main}
NEW_REF=${2:-HEAD}
R=${3:-10}
KO_SRC=${KO_SRC:-$HOME/koreader-emulator}
KO=${KO_EMU:-$(ls -d "$KO_SRC"/koreader-emulator-*/koreader 2>/dev/null | head -1)}
if [ ! -x "$KO/luajit" ]; then echo "No emulator found; set KO_SRC or KO_EMU." >&2; exit 1; fi
OUT=${OUT:-$HERE/out}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/old" "$WORK/new"
git -C "$ROOT" archive "$OLD_REF" | tar -x -C "$WORK/old"
git -C "$ROOT" archive "$NEW_REF" | tar -x -C "$WORK/new"
cp -R "$ROOT/tests/mock" "$WORK/mock"   # the stand-ins of this checkout, for both
echo "old: $OLD_REF ($(git -C "$ROOT" rev-parse --short "$OLD_REF"))  new: $NEW_REF ($(git -C "$ROOT" rev-parse --short "$NEW_REF"))"

CFGS=("grey:0 1072x1448" "grey:1 1072x1448" "colour:0 1072x1448" "grey:0 1860x2480")
pass() {  # name rounds jitopt pages cfgs...
    local name=$1 dir="$OUT/$1" rounds=$2 jo=$3 pages=$4
    shift 4
    rm -rf "$dir"; mkdir -p "$dir"
    for r in $(seq 1 "$rounds"); do
        if (( r % 2 )); then order="old new"; else order="new old"; fi
        for c in "$@"; do
            read -r cfg size <<<"$c"
            for part in ui io; do
                for ver in $order; do
                    f="$dir/${ver}_${part}_${cfg/:/-}_${size}_r${r}.txt"
                    ( cd "$KO" && BENCH_JITOPT="$jo" BENCH_PAGES="$pages" ./luajit "$HERE/bench.lua" \
                        "$WORK/$ver" "$WORK/mock" "$cfg" "$f" "$size" "$part" ) \
                        >/dev/null 2>>"$dir/stderr.log" || echo "FAIL $ver $part $c r$r" >> "$dir/fail.log"
                done
            done
        done
        echo "$name: round $r of $rounds done"
    done
}
TUNED="sizemcode=4096,maxmcode=4096,maxtrace=8000"
pass main "$R" "$TUNED" 40 "${CFGS[@]}"
pass big "${BIG_ROUNDS:-5}" "$TUNED" 120 "grey:0 1072x1448"
pass jit "${JIT_ROUNDS:-6}" "" 40 "grey:0 1072x1448" "colour:0 1072x1448"
echo "Done. Results in $OUT"
