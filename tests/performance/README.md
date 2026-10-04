# Performance tests

Scripts that time two versions of the plugin against each other
(`run.sh`, `bench.lua`), the newer features on their own (`features.lua`), and
the results of past runs. Like the rest of `tests/`, none of this ships with the
plugin.

## Results, 4 October 2026: search, trash, selection, links, straightening

Two runs. `run.sh 00030d8 HEAD 4` compared the branch before these features
with after them, on the same four screen setups (tables in
[`results/2026-10-04/`](results/2026-10-04/)). `features.lua` timed the new
features themselves on a grey and a colour Kindle-size screen and a grey
Scribe-size one (8 rounds; text is not drawn, the stand-ins have no fonts).
Apple M3 again: expect about ten times as long on a Paperwhite.

### What the comparison found, and what was done

| | before | first try | now |
|---|---|---|---|
| Pen stroke start, colour | 101 us | 254–535 us | back to before |
| Shape assist commit | 0.5 ms | 3–6 ms | 0.4–0.6 ms |
| Lasso drag frame, landscape | 69 us | 961 us | 121 us |

- **Stroke starts.** Hold to straighten is on by default and needed the copy of
  the page shape assist takes at every stroke start (1.5 MB, 6 MB in colour).
  The swap after a hold now composes just the stroke's footprint again, which
  gives the same pixels (checked on the real blitter), so nothing is copied.
- **Shape assist.** Composing a big shape's footprint again cost more than
  restoring it from the copy, so with shape assist on the copy is kept, as
  before.
- **Landscape drags.** A lifted selection is drawn on a card that follows the
  finger; on a screen turned in software each frame was a turned per-pixel
  blit. The card is now kept in the screen's pixel order, so a frame is a row
  copy (byte-identical, checked).
- Unchanged everywhere else: drawing per point, erasers, page turns, notebook
  open and save, PDF and PNG export, library and overview.
- Slower by design: closing a lasso loop (+0.5–0.7 ms) opens the selection's
  menu; grabbing it draws the handles. Loading the plugin's code at first open
  is about 1.5 ms longer (61 modules instead of 52).

### The new features, grey / colour / Scribe size

| | grey | colour | Scribe |
|---|---|---|---|
| Full redraw of a dense page, for scale | 2.1 ms | 2.5 ms | 3.2 ms |
| Lasso 72 strokes and open the menu | 0.8 ms | 1.3 ms | 1.2 ms |
| Lift them (drag start) | 0.9 ms | 2.0 ms | 1.6 ms |
| A drag frame (card) | 47 us | 183 us | 123 us |
| Drop (compose the two boxes again) | 1.5 ms | 2.0 ms | 1.7 ms |
| A resize frame (the card scaled) | 1.3 ms | 2.7 ms | 3.5 ms |
| A turn frame (the frame only) | 68 us | 162 us | 153 us |
| Colour, size, flip, a quarter turn, delete | 1.8–2.3 ms | 2.3–3.1 ms | 2.2–3.2 ms |
| Duplicate | 3.5 ms | 4.0 ms | 4.6 ms |
| A picture: lift / drop (full page, pictures feed the eraser) | 2.7 / 2.8 ms | 4.7 / 4.3 ms | 5.6 / 5.4 ms |
| Straightening a held stroke | 0.4 ms | 0.8 ms | 0.8 ms |
| Paint with 40 links on the page (none: 35 us) | 91 us | 227 us | 354 us |
| Contents page for 40 titled pages | 0.7 ms | 1.9 ms | 1.2 ms |
| Search 30 notebooks of 40 pages, names, first / cached | 1.6 / 0.5 ms | 1.8 / 0.5 ms | 2.2 / 0.7 ms |
| Same, inside pages, first / cached | 40 / 1.3 ms | 43 / 1.4 ms | 43 / 1.6 ms |
| Trash a 40-page notebook / put it back | 0.4 / 0.3 ms | 0.4 / 0.3 ms | 0.4 / 0.4 ms |
| Trash a page / put it back into its file | 0.3 / 2.4 ms | 0.3 / 2.4 ms | 0.3 / 2.5 ms |

A resize frame is the heaviest, but the screen takes one at most about six
times a second while dragging. The first search inside pages of a big library
reads every file once (about half a second on a reader, behind its progress
bar); after that only changed files are read again.

### Real widgets (emulator, 600x800), opening each new sheet

Selection menu 2.3 ms (2.5 in colour), its colour panel 1.1 ms (2.0), link
chooser 4.0 ms (4.7), page menu 2.7 ms (3.1), search results 4.8 ms (4.1),
trash 5.1 ms (6.2): the same range as the older sheets.

## Results, 3 October 2026: main vs notebook-library

Compared `main` at `cf9949f` (the modular refactor) with `notebook-library` at
`997ed2b` (autosave, library, folders, overview tabs, unified export). The full
tables are in [`results/2026-10-03/`](results/2026-10-03/).

All times are from an Apple M3 running the KOReader emulator build. An e-reader
is several times slower, often around ten times for Lua code. Read the
percentages, not the milliseconds, when thinking about a device.

### How it was measured

- **Headless** (`bench.lua`): KOReader's real blitter and the real plugin, with
  the test stand-ins for KOReader's widgets. Four screen setups: Kindle size
  grey portrait, grey landscape, colour, and Scribe size (1860x2480). Ten rounds
  each, old and new back to back with the order swapped every round. A second
  pass used a 120-page notebook. A third used LuaJIT's default settings to count
  how often compiled code gets thrown away.
- **Real widgets** (`emulator/perfemu.lua`): the full emulator with KOReader's
  own dialogs and menus, grey and colour, five rounds each.
- A change only counts when its 95% confidence interval is clear of ±5% in at
  least three of the four screen setups. With a few hundred metrics, some
  single-setup results will look like changes and are not.

### Unchanged

Drawing (pen, pencil, colour, translucent, symmetry, raw finger input, eraser),
shapes, lasso, images, fill, zoom and pan, undo and redo, tool switching, page
turns, adding pages, reading a notebook file, opening a notebook, and reopening
Ink Away straight into one. Both versions also ask the e-ink screen for the same
refreshes: a stroke is 123 small updates covering 7% of the screen, with no
flashing.

| Kindle size, grey | old | new |
|---|---|---|
| Pen, per point | 2.6 µs | 2.8 µs |
| Undo | 13.2 ms | 13.4 ms |
| Page turn, 40-page notebook | 2.13 ms | 2.15 ms |
| Open a 40-page notebook | 8.7 ms | 8.5 ms |
| PDF export, per page | 5.40 ms | 5.48 ms |

### Faster

| | old | new |
|---|---|---|
| Save after an edit, 40 pages | 3.33 ms | 0.44 ms (−87%) |
| Save after an edit, 120 pages | 10.6 ms | 0.76 ms (−93%) |
| Close with a 120-page notebook open | 11.4 ms | 0.8 ms |
| Page thumbnails of a 40-page notebook (page grid → overview) | 33 ms | 21 ms (−35%) |
| Same, Scribe size | 76 ms | 50 ms |
| Settings sheet, real widgets, grey / colour | 9.4 / 7.9 ms | 7.5 / 6.3 ms |

The new save rewrites only the page that changed into the file's text, then
writes through a temporary file and syncs it to disk. The old version writes
its whole session file without syncing, and by default only on exit.

### Slower

| | old | new | Why |
|---|---|---|---|
| Loading the plugin's code at first open | 9.2 ms | 11.2 ms | 50 modules instead of 41 |
| First save of a notebook | 3.7 ms | 4.3 ms | Adds it to its folder's order and syncs to disk |
| Starting a notebook, real widgets, grey | 9.8 ms | 11.9 ms | Saves the open drawing first |
| PNG of a notebook page | 22.7 ms | 26.7 ms | Paper and ruling are now included by default. With the old settings it takes 22.6 ms. |
| Eraser sheet, real widgets, grey | 1.8 ms | 2.3 ms | Has the new "Erase whole strokes" row |
| Grid sheet, real widgets, grey | 2.4 ms | 2.8 ms | |

### New features (no old equivalent)

Kindle size unless noted. "Cold" means no cached thumbnails yet.

| | |
|---|---|
| Library, first open, 8 to 9 thumbnails drawn from their files | 44–58 ms (Scribe size 137 ms) |
| Library, reopened with cached thumbnails | 3–4.5 ms |
| Library, into a folder, cold | 40 ms |
| Overview with 18 tabs | 21 ms (36 ms with real widgets) |
| Overview, switch to another notebook | 31 ms cold, 2.3 ms after |
| Overview, into a subfolder | 31 ms cold, 2 ms after. Going up: 0.3 ms |
| Telling notebooks from drawings in a folder of 24 files | 0.4 ms |
| Folder PDF, 38 pages over two subfolders | 219 ms, 5.8 ms per page |
| Lasso copy / paste | 0.3 ms / 5 ms |
| Save page as template / new page from template | 0.5 ms / 2.3 ms |
| File sheet, real widgets | 6.5 ms first, about 3 ms after |
| Paper chooser, real widgets | 4.9 ms first, 2.6 ms after |
| Export sheet, real widgets | 2.8 ms first, 2.4 ms after |

### Memory and disk

- Lua heap is 0.2 MB higher at open and 0.4–0.5 MB higher with a big notebook
  open. Most of that is the per-page save cache, which holds about as much as
  the notebook file.
- Whole process, while open: the library adds about 2.4 MB, mostly the visible
  thumbnails, and the overview about 0.2 MB. On the 40-page notebook the old
  page grid added about 4 MB and the new overview about 1.8 MB. Nothing extra
  stays behind after closing. See `memory.txt`.
- Notebook files are 0.4% bigger (page ids and dates). Exported PDFs are the
  same size.
- Every autosave writes the whole file: 321 KB for 40 pages, 974 KB for 120.
  Autosave runs at most once per 8 seconds of idle after a change, and at least
  once a minute during non-stop writing. Steady writing in a 40 to 120-page
  notebook comes to roughly 20–60 MB written per hour.

### To check on a device

1. **Autosave pauses on big notebooks.** Each save syncs a file of up to about
   1 MB to flash. This takes under a millisecond on the Mac, but a slow eMMC
   could make it noticeable when a stroke starts during a save.
2. **LuaJIT flushes.** The new version compiles about 5–20% more traces while
   drawing. With LuaJIT's default limits it flushed its compiled code two to six
   times as often on the Mac (`jit-flushes.txt`), though median timings stayed the same.
   KOReader leaves those limits at their defaults, so long sessions might show
   it as occasional short stalls.
3. **First library open.** 44–58 ms here could be half a second or more on a
   Kindle. After that the thumbnails are cached.

### Notes on the method

- The first trial runs showed PDF export at 9 ms per page against 5 ms. That
  was LuaJIT throwing away its machine code: macOS on arm64 fails to place it
  at random. The tuned JIT settings (`sizemcode`, `maxmcode`, `maxtrace`) avoid
  this, and both versions then export at about 5.4 ms per page.
- The old version's `newNotebook()` asks before starting, so `bench.lua` calls
  `startNotebook()` on it, with the same paper the new version uses by default.
- The emulator window waits for the Mac's display refresh on every update,
  which rounds each timing up to 16.6 ms. `perfemu.lua` skips that step. On a
  device it would be the e-ink refresh, which is hardware time and the same for
  both versions.
- The colour pen sheet can't be built with the test stand-in widgets, in either
  version. Only the real-widget run covers it.
- A few short memory runs overlapped the real-widget run, which may add a
  little noise to one or two of its rounds.
- The real-widget run's colour profile was not really colour for the plugin.
  The run script set `INKAWAY_FORCE_MONO=0`, and the plugin treats the
  variable being set at all as a grey screen. So both profiles ran the plugin
  in grey mode, the second on a colour framebuffer. `emulator/run.sh` now
  leaves the variable out for colour. The headless colour setup was not
  affected.

## Results, 3 October 2026: e-ink refreshes

What each action asks the e-ink panel to do, measured in the emulator by hooking
the panel's refresh calls (so after KOReader merges requests), on main, on the
branch before this round (`cce10a2`) and after it (`4dcea86`). The full table is
[`results/2026-10-03-refresh/refresh.md`](results/2026-10-03-refresh/refresh.md).
On a device the flashes matter most: about half a second to a second each on
grey, and a second or two on colour, where Kobo's controller makes the reader
wait for it to finish.

Unchanged and already following the rules from earlier work: tool switches,
undo and redo, page turns (a cleaning flash every sixth on grey, none on
colour), and the sheets on grey (a flash over the sheet as it opens over ink,
plain refreshes for everything inside it and for closing).

What changed:

| | before | after |
|---|---|---|
| Library or overview, page of thumbnails turned | flash | no flash |
| Library or overview closed | flash | no flash |
| Library opened from the overview | flash | no flash |
| Library or overview opened on colour | flash | no flash |
| Any sheet opened on colour | flash | no flash |
| Opening Ink Away on the library | two flashes on grey | one |
| Overview opened again, same notebook | 47 ms | 3 ms |
| Overview star filter turned off | 48 ms | 3 ms |

So a visit to the overview (open, turn a page, close) went from three flashes
to one on grey and to none on colour, and browsing the library to a document
from four to two on grey and one on colour.

Kept as they were, on purpose:

- Opening the library or overview over the drawing still flashes on grey, as a
  sheet does: without it the ink shows faintly through.
- Opening a document flashes (a page-wide content swap, as in 3.2.0).
- The brush maker still flashes as it closes (older, rarely used).

The emulator does not show ghosting, so whether the plain refreshes on page
turns and closing leave visible traces is for a device to tell.

## Running it

Both scripts need the KOReader emulator built, as described in
`tests/README.md`.

Headless, about 10 minutes for 10 rounds:

    tests/performance/run.sh main HEAD 10
    python3 tests/performance/analyze.py A tests/performance/out/main
    python3 tests/performance/analyze.py A tests/performance/out/big
    python3 tests/performance/analyze.py S tests/performance/out/main '^io\.'

`S` prints one line per screen setup for the metrics that match. Both refs are
exported with `git archive`, so uncommitted changes are not included.

Real widgets, about 15 minutes for 5 rounds:

    tests/performance/emulator/compare.sh main HEAD 5
    python3 tests/performance/analyze.py B tests/performance/out/emulator

This replaces the emulator's copy of the plugin while it runs and installs the
checkout again at the end. Each run uses a throwaway KOReader home with a small
driver plugin (`emulator/drive.koplugin`), so your emulator settings are not
touched.

The e-ink refresh audit, about 15 minutes for 3 rounds of three versions:

    tests/performance/emulator/refresh.sh 3 main=main before=cce10a2 after=HEAD
    python3 tests/performance/refresh_compare.py tests/performance/out/refresh main before after

Metric names in the results:

- `*.move`, `*.down`, `*.commit`: one input event plus the paint that follows it.
- `sheet.<name>.open_first` / `.open`: building a sheet, the first time and
  later. With real widgets this includes painting it.
- `io.*`: notebook files.
- `lib.*` / `ov.*`: the library and overview.
- `mem.*`: Lua heap in KB.
- `refresh.*`: e-ink refresh requests. `area` is the share of the screen
  covered (2.0 means two full screens); `flashes` counts full or flashing
  refreshes.
