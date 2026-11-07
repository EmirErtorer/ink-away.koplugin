# Tests

The test suite for Ink Away. It isn't part of the plugin and never ships with it:
`tools/build-release.sh` leaves this folder out of the release zip, and
`.gitattributes` keeps it out of GitHub's "Source code" downloads.

## Running

From the plugin folder:

    luajit tests/run.lua

This runs every suite, after first checking the plugin code for accidental
globals. You can also run one suite on its own, e.g. `luajit tests/view.lua`.

GitHub runs `luacheck` and every suite that needs no KOReader build on each push
(`.github/workflows/tests.yml`); the result is the Tests badge on the README.

Most suites only need LuaJIT. They run the plugin against small stand-ins for
KOReader's modules, which live in `tests/mock/`.

`luajit tests/bookexport.lua` checks fixed-page book export routing and native ink
placement. With a built runtime, `realbb/comicexport.lua` additionally tests real
CBZ/CBR decoding and PDF output. Run from a built KOReader runtime:

    ./luajit REPO/tests/realbb/comicexport.lua REPO

For the optional 144 MB synthetic-archive measurement, generate fixtures with
`python3 REPO/tests/realbb/comic_fixtures.py /tmp/inkaway-comics --large`, then
pass `/tmp/inkaway-comics` as the final argument to the native suite. This is a
desktop/native-library check, not physical-reader validation.

`luajit tests/delegate.lua` checks the reusable event delegate without KOReader:
ordered delivery, isolated payloads/errors, subscription mutation, idempotent
unsubscribe and disposal during dispatch. `tests/integration.lua` checks that
Book consumes a supplied surface directly and that registry disposal disconnects
observers/providers.

The PR's LuaLS interfaces are in `ink/contracts.lua`; public examples and runtime
boundaries reference those types. Run `lua-language-server --check=.` for editor
static diagnostics. The existing project is not globally type-clean: scope new
type diagnostics to the PR; do not suppress unrelated host/mock diagnostics.

`luajit tests/loading_order.lua` exercises the actual plugin init plus both
readiness orders, queue cancellation/failures and composite installation cleanup.
Host menus, pen/shelf attachment and UI are fixtures.

`luajit tests/integration.lua` exercises public provider registration, lifecycle
subscriptions, failures and cleanup through the actual Book/editor with host
fixtures. `annotation_surface.lua` and `surface_viewport.lua` cover real canvas
editing and toolbar reflow through a generic provider. The consumer contract is
in `docs/Plugin-integration.md`. Native `realbb/surface_toolbar.lua` and
`realbb/promptfocus.lua` check actual toolbar pixels and host focus behavior;
run them from a built runtime as `./luajit REPO/tests/realbb/NAME.lua REPO`.

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
- `performance/` times two versions of the plugin against each other (drawing,
  sheets, notebook files, export, library) and keeps the results of past runs.
  See `performance/README.md`.
- `rotverify.lua` checks the landscape rendering byte for byte. Run it from the
  emulator's `koreader` folder: `./luajit /path/to/ink-away.koplugin/tests/rotverify.lua`

## On a device

Some of the screen handling can only be checked on the reader itself.

- **Kobo Elipsa (2021):** the fast updates go to a helper process
  (`ink/elipsadrive.lua`, `ink/elipsaworker.lua`). `elipsadrive.lua` and
  `elipsaworker.lua` here check the ordering and the helper's channel (the
  second only on Linux), not the panel. On the reader:
  1. On a blank page, write quickly with the Fineliner, with the pen and then a
     finger: the line follows, and quick strokes stay apart.
  2. Write with the Ballpoint and the Pencil: the Pencil's black while drawing
     turns grey once the pen rests, and the end of every stroke shows.
  3. Turn the screen, undo, open and close a menu, turn a notebook page, close
     and open Ink Away: nothing is missing, stale or frozen.
  4. Put the reader to sleep with a drawing open, wake it, write, and go back to
     a book: page turns and full refreshes still work.

  If the helper fails, crash.log says "Elipsa refresh worker failed" and why.

## Experimental OCR API checks

`luajit tests/run.lua` includes `ocr_api.lua`, `ocr_job.lua`, `ocr_image.lua`,
and `ocr_view.lua`. With `KO_EMU` pointing to a built KOReader runtime, it also
runs native PNG/erase round trips and the real subprocess/IPC/cancellation test.

Run `KO_EMU=/absolute/path/to/koreader sh tests/ocr_tls_native.sh` separately for
real bundled LuaSocket/LuaSec HTTPS checks. It needs Python 3, OpenSSL, and permission
to bind localhost. It uses generated CA/certificates, synthetic image bytes and a
dummy key, and checks untrusted CA rejection, trusted SAN acceptance, and hostname
mismatch rejection. Only the device-dependent socketutil setup is substituted;
the transport uses the bundled socket/http, LuaSec and JSON. It sends no provider
requests and removes its fixture directory on exit.

Sandbox restrictions on Unix sockets or localhost listeners can make existing
Elipsa IPC/share tests fail; rerun with the appropriate local permissions rather
than treating those checks as passed or modifying their expectations.
