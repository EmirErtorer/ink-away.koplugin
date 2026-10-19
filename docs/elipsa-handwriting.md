# First-generation Elipsa handwriting experiment

This branch enables the new path only for KOReader's `Kobo_europa` model with
the sunxi/ION framebuffer. It does not enable it on Sage or Elipsa 2E.

Ink Away enables the Allwinner handwriting ioctl,
`DISP_EINK_SET_NTX_HANDWRITE_ONOFF` (`0x4015`), and sends live rectangle
refreshes to a Lua subprocess. This keeps blocking display updates out of
KOReader's input loop without an additional native library.

The worker inherits KOReader's shared ION pixel mapping. Only rectangles pass
over a Unix socket. There is at most one submitted update and one pending union
of everything drawn since then; old pen positions cannot form an unbounded
queue. Completed driver markers return to the parent so later normal refreshes
retain KOReader's ordering. The worker stops before other waveforms, rotation,
framebuffer reinitialisation/close, sleep, or the last drawing view closing.
It starts again lazily on the next fast refresh. A worker startup or transport
failure falls back to normal synchronous refreshes and logs a warning.

Opaque grey pens draw a black preview and settle to grey after the pen rests.
Translucent pens and erasing over a ruled/image background still use the
grey-capable waveform and can remain slower.

## Manual check on the device

1. Back up the installed `plugins/ink-away.koplugin` folder, then replace it
   with the test build and restart KOReader.
2. On a blank page, write quickly with a solid black Fineliner using the stylus
   and then a finger. Check that the line follows your movement and that quick
   separate strokes remain separate.
3. Repeat with Ballpoint and Pencil. Pencil's black preview should settle to
   its original grey; the last part of every stroke should remain visible.
4. Rotate, undo, open/close a menu, switch pages, then close and reopen Ink Away.
   Check for missing regions, stale updates, or a frozen screen.
5. Sleep and wake with a drawing open; write again, then close back to a book.
   Normal page turns and full refreshes should work afterwards.

For a comparison, restore the backed-up plugin and repeat step 2 on the same
page size and orientation. No on-device latency measurement has been made yet.
If the experiment falls back, `crash.log` contains `Elipsa refresh worker failed`
and the startup reason when available.

## Automated checks

`tests/elipsadrive.lua` models a slow driver, rectangle coalescing, marker
handoff, nested views, rotation, shutdown, and failure recovery.
`tests/elipsaworker.lua` exercises actual Linux fork/socket communication and a
shared memory framebuffer, substituting the hardware ioctl. These verify the
implementation; they do not substitute for testing the Elipsa's kernel driver.
