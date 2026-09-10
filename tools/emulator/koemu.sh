#!/usr/bin/env bash
#
# koemu.sh - run Ink Away in KOReader's own desktop emulator, with a device
# picker (Kindle, Kobo, Scribe, and colour e-ink models).
#
# KOReader ships an SDL emulator that simulates an e-ink screen. This wraps it:
# it installs the build deps, clones and builds KOReader once, copies this
# plugin into it, and launches it at the exact screen size and DPI of the device
# you pick. Grey devices are shown in grey; colour devices show the colour picker.
#
#   ./tools/emulator/koemu.sh setup            # one time: deps + clone + build
#   ./tools/emulator/koemu.sh list             # show the devices
#   ./tools/emulator/koemu.sh run scribe       # launch on a Kindle Scribe
#   ./tools/emulator/koemu.sh run libra-colour # a colour Kobo
#   ./tools/emulator/koemu.sh build            # rebuild after a KOReader update
#   ./tools/emulator/koemu.sh update           # git pull KOReader + rebuild
#
# The KOReader checkout lives outside this repo (default ~/koreader-emulator),
# override with:  KOEMU_DIR=/some/path ./tools/emulator/koemu.sh ...

set -euo pipefail

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KO_DIR="${KOEMU_DIR:-$HOME/koreader-emulator}"
PLUGIN_NAME="ink-away.koplugin"

# --- device registry --------------------------------------------------------
# Returns: "WIDTH HEIGHT DPI MONO"   MONO=1 grey e-ink, MONO=0 colour e-ink.
device_spec() {
    case "$1" in
        kindle-basic)      echo "600 800 167 1" ;;   # entry Kindle
        paperwhite)        echo "1072 1448 300 1" ;;  # PW3/PW4 era
        paperwhite5)       echo "1236 1648 300 1" ;;  # PW 6.8in
        oasis)             echo "1264 1680 300 1" ;;
        scribe)            echo "1860 2480 300 1" ;;  # 10.2in, pen
        colorsoft)         echo "1264 1680 300 0" ;;  # Kindle Colorsoft (Kaleido)
        kobo-clara)        echo "1072 1448 300 1" ;;
        clara-colour)      echo "1072 1448 300 0" ;;  # Kobo Clara Colour
        kobo-libra)        echo "1264 1680 300 1" ;;
        libra-colour)      echo "1264 1680 300 0" ;;  # Kobo Libra Colour
        kobo-sage)         echo "1440 1920 300 1" ;;
        kobo-elipsa)       echo "1404 1872 227 1" ;;  # 10.3in
        kobo-forma)        echo "1440 1920 300 1" ;;
        kobo-aura-one)     echo "1404 1872 300 1" ;;
        hidpi)             echo "1500 2000 600 1" ;;  # DPI-scaling stress test
        *)                 return 1 ;;
    esac
}

DEVICES="kindle-basic paperwhite paperwhite5 oasis scribe colorsoft \
kobo-clara clara-colour kobo-libra libra-colour kobo-sage kobo-elipsa \
kobo-forma kobo-aura-one hidpi"

# --- helpers ----------------------------------------------------------------
say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

gnu_path() {
    # KOReader's build and kodev need the GNU coreutils / getopt on PATH.
    local p; p="$(brew --prefix 2>/dev/null || true)"
    [ -n "$p" ] || return 0
    export PATH="$p/opt/findutils/libexec/gnubin:$p/opt/gnu-getopt/bin:$p/opt/make/libexec/gnubin:$p/opt/util-linux/bin:$PATH"
}

list_devices() {
    printf '%-16s %-11s %-5s %s\n' DEVICE "SIZE" DPI SCREEN
    for d in $DEVICES; do
        read -r w h dpi mono <<<"$(device_spec "$d")"
        [ "$mono" = 1 ] && screen="grey e-ink" || screen="colour e-ink"
        printf '%-16s %-11s %-5s %s\n' "$d" "${w}x${h}" "$dpi" "$screen"
    done
}

ensure_ko() {
    [ -x "$KO_DIR/kodev" ] || die "KOReader not set up. Run: $0 setup"
}

# copy the plugin into the emulator (a real copy, not a symlink, so KOReader's
# source sync always sees the current files; excludes dev-only bulk)
sync_plugin() {
    local dest="$KO_DIR/plugins/$PLUGIN_NAME"
    mkdir -p "$dest"
    rsync -a --delete \
        --exclude '.git' --exclude 'dist' --exclude 'tools' \
        --exclude 'tests' --exclude 'assets' --exclude '.DS_Store' \
        "$PLUGIN_ROOT/" "$dest/"
}

# --- commands ---------------------------------------------------------------
cmd_deps() {
    command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
    say "Installing build dependencies with Homebrew..."
    # wget is not in KOReader's documented list but its build downloads
    # third-party sources with it, so it is required on macOS.
    brew install autoconf automake bash binutils cmake coreutils findutils \
        gettext gnu-getopt libtool make meson nasm ninja pkgconf sdl3 \
        util-linux wget
}

cmd_setup() {
    cmd_deps
    gnu_path
    if [ ! -d "$KO_DIR/.git" ]; then
        say "Cloning KOReader into $KO_DIR ..."
        git clone https://github.com/koreader/koreader.git "$KO_DIR"
    else
        say "KOReader already cloned at $KO_DIR"
    fi
    say "Fetching third-party sources (this is the long one)..."
    ( cd "$KO_DIR" && ./kodev fetch-thirdparty )
    cmd_build
    say "Done. Try:  $0 run paperwhite"
}

cmd_build() {
    ensure_ko; gnu_path
    say "Building the emulator (first build takes a while)..."
    ( cd "$KO_DIR" && ./kodev build )
}

cmd_update() {
    ensure_ko; gnu_path
    say "Updating KOReader..."
    ( cd "$KO_DIR" && git pull && ./kodev fetch-thirdparty && ./kodev build )
}

cmd_run() {
    local dev="${1:-paperwhite}"
    local spec; spec="$(device_spec "$dev")" || die "Unknown device '$dev'. Run: $0 list"
    ensure_ko; gnu_path
    read -r w h dpi mono <<<"$spec"
    say "Launching Ink Away on '$dev'  (${w}x${h} @ ${dpi} dpi, $([ "$mono" = 1 ] && echo grey || echo colour))"
    sync_plugin
    # Sandbox the file browser so the emulator never shows your real home/desktop:
    # XDG_DOCUMENTS_DIR sets its home folder, and passing the folder opens it there.
    local sandbox="$KO_DIR/sandbox"
    mkdir -p "$sandbox"
    [ -e "$sandbox/Welcome.txt" ] || printf 'Ink Away emulator sandbox.\n\nThe file browser opens here so the emulator never shows your real files.\nExported drawings save under the KOReader folder (ink away/drawings).\n' > "$sandbox/Welcome.txt"
    local mono_env=""
    [ "$mono" = 1 ] && mono_env="INKAWAY_FORCE_MONO=1"
    ( cd "$KO_DIR" && env XDG_DOCUMENTS_DIR="$sandbox" $mono_env ./kodev run -W "$w" -H "$h" -D "$dpi" "$sandbox" )
}

# --- dispatch ---------------------------------------------------------------
case "${1:-}" in
    deps)   cmd_deps ;;
    setup)  cmd_setup ;;
    build)  cmd_build ;;
    update) cmd_update ;;
    list)   list_devices ;;
    run)    shift; cmd_run "${1:-paperwhite}" ;;
    ""|-h|--help|help)
        sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "Unknown command '$1'. Run: $0 --help" ;;
esac
