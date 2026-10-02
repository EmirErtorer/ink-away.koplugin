# Tests

The test suite for Ink Away. It isn't part of the plugin and never ships with it:
`tools/build-release.sh` leaves this folder out of the release zip, and
`.gitattributes` keeps it out of GitHub's "Source code" downloads.

## Running

From the plugin folder:

    luajit tests/run.lua

This runs every suite, after first checking the plugin code for accidental
globals. You can also run one suite on its own, e.g. `luajit tests/view.lua`.

Most suites only need LuaJIT. They run the plugin against small stand-ins for
KOReader's modules, which live in `tests/mock/`.

## Suites that need the KOReader emulator

A few suites use KOReader's own code, so they need a KOReader checkout with the
emulator built in it:

- `scribe/replay.lua` feeds Kindle Scribe style pen and palm input through
  KOReader's real input and gesture code.
- `realbb/*.lua` check real pixels with KOReader's C blitter, using the
  emulator's LuaJIT.

`run.lua` looks for the checkout in `~/koreader-emulator` and finds the emulator
folder inside it. If yours are somewhere else, set `KO_SRC` to the checkout, or
`KO_EMU` to the emulator's `koreader` folder. Without either, these suites are
skipped.

## Other scripts

- `preview.lua [out_dir]` writes sample PNGs from the export code, so you can
  look at the transparent output on a computer.
- `rotverify.lua` checks the landscape rendering byte for byte. Run it from the
  emulator's `koreader` folder: `./luajit /path/to/ink-away.koplugin/tests/rotverify.lua`
