Refresh audit (emulator/refreshaudit.lua), 758x1024 at 212 dpi, 3 rounds each, KOReader emulator on an Apple M3.
main = main cf9949f, before = notebook-library cce10a2, after = notebook-library 4dcea86 (this round).
Each cell: whether the refreshes that reached the panel included a flash (full / flashui / flashpartial),
the screen share they covered (summed), and the median CPU ms of the action and its repaint.

## grey

| action | main | before | after |
|---|---|---|---|
| tool: tap Eraser | no flash, 0.06 scr, 2.5 ms | no flash, 0.06 scr, 2.4 ms | no flash, 0.06 scr, 3.0 ms |
| tool: back to Pen | no flash, 0.06 scr, 1.7 ms | no flash, 0.06 scr, 1.7 ms | no flash, 0.06 scr, 1.5 ms |
| undo | no flash, 0.94 scr, 3.1 ms | no flash, 0.94 scr, 3.4 ms | no flash, 0.94 scr, 4.4 ms |
| redo | no flash, 0.94 scr, 3.2 ms | no flash, 0.94 scr, 3.1 ms | no flash, 0.94 scr, 2.7 ms |
| pen sheet: open | 1 flash, 0.61 scr, 22.0 ms | 1 flash, 0.66 scr, 25.7 ms | 1 flash, 0.66 scr, 21.7 ms |
| pen sheet: flip a switch | no flash, 0.01 scr, 4.0 ms | no flash, 0.01 scr, 4.0 ms | no flash, 0.01 scr, 4.0 ms |
| pen sheet: pick a brush (rebuild) | no flash, 0.61 scr, 10.5 ms | no flash, 0.66 scr, 11.6 ms | no flash, 0.66 scr, 11.8 ms |
| pen sheet: close | no flash, 0.61 scr, 1.4 ms | no flash, 0.66 scr, 1.2 ms | no flash, 0.66 scr, 2.2 ms |
| settings: open | 1 flash, 0.86 scr, 9.4 ms | 1 flash, 0.82 scr, 7.4 ms | 1 flash, 0.82 scr, 8.4 ms |
| settings: pick Symmetry (rebuild) | no flash, 0.86 scr, 9.7 ms | no flash, 0.82 scr, 7.1 ms | no flash, 0.82 scr, 6.0 ms |
| settings: close | no flash, 0.86 scr, 1.3 ms | no flash, 0.82 scr, 2.0 ms | no flash, 0.82 scr, 1.8 ms |
| shapes sheet: open | 1 flash, 0.47 scr, 6.3 ms | 1 flash, 0.47 scr, 7.0 ms | 1 flash, 0.47 scr, 6.8 ms |
| shapes sheet: close | no flash, 0.47 scr, 1.4 ms | no flash, 0.47 scr, 2.0 ms | no flash, 0.47 scr, 1.1 ms |
| File sheet: open | - | 1 flash, 0.44 scr, 6.4 ms | 1 flash, 0.44 scr, 5.7 ms |
| File sheet: close | - | no flash, 0.44 scr, 1.6 ms | no flash, 0.44 scr, 1.2 ms |
| Export sheet: open | - | 1 flash, 0.51 scr, 2.2 ms | 1 flash, 0.51 scr, 2.5 ms |
| Export sheet: close | - | no flash, 0.51 scr, 0.7 ms | no flash, 0.51 scr, 1.6 ms |
| notebook: start | no flash, 1.00 scr, 10.5 ms | no flash, 1.00 scr, 11.3 ms | no flash, 1.00 scr, 11.3 ms |
| notebook: add page | no flash, 1.00 scr, 2.9 ms | no flash, 1.00 scr, 3.3 ms | no flash, 1.00 scr, 3.1 ms |
| notebook: page turn | no flash, 1.00 scr, 3.2 ms | no flash, 1.00 scr, 3.4 ms | no flash, 1.00 scr, 3.0 ms |
| notebook: page turn #2 | no flash, 1.00 scr, 3.1 ms | no flash, 1.00 scr, 2.6 ms | no flash, 1.00 scr, 3.2 ms |
| notebook: page turn #3 | 1 flash, 1.00 scr, 2.8 ms | 1 flash, 1.00 scr, 3.0 ms | 1 flash, 1.00 scr, 3.6 ms |
| page menu: open | 1 flash, 0.43 scr, 3.4 ms | 1 flash, 0.58 scr, 3.7 ms | 1 flash, 0.58 scr, 3.0 ms |
| page menu: close | no flash, 0.43 scr, 0.9 ms | no flash, 0.58 scr, 1.1 ms | no flash, 0.58 scr, 1.8 ms |
| pages view: open | 1 flash, 1.00 scr, 27.6 ms | 1 flash, 1.00 scr, 51.0 ms | 1 flash, 1.00 scr, 50.2 ms |
| pages view: next page of thumbnails | no flash, 0.00 scr, 0.0 ms | no flash, 0.00 scr, 0.0 ms | no flash, 0.00 scr, 0.0 ms |
| pages view: previous page | 1 flash, 1.00 scr, 73.0 ms | 1 flash, 1.00 scr, 47.5 ms | no flash, 1.00 scr, 48.1 ms |
| overview: Star filter | - | no flash, 1.00 scr, 3.0 ms | no flash, 1.00 scr, 2.2 ms |
| overview: Star filter off | - | no flash, 1.00 scr, 48.1 ms | no flash, 1.00 scr, 2.3 ms |
| pages view: close | 1 flash, 1.00 scr, 0.8 ms | 1 flash, 1.00 scr, 1.5 ms | no flash, 1.00 scr, 1.7 ms |
| pages view: open again | 1 flash, 1.00 scr, 25.5 ms | 1 flash, 1.00 scr, 47.8 ms | 1 flash, 1.00 scr, 2.7 ms |
| pages view: close again | 1 flash, 1.00 scr, 0.6 ms | 1 flash, 1.00 scr, 0.7 ms | no flash, 1.00 scr, 1.2 ms |
| pages view: open again #2 | 1 flash, 1.00 scr, 25.0 ms | 1 flash, 1.00 scr, 48.8 ms | 1 flash, 1.00 scr, 3.7 ms |
| pages view: close again #2 | 1 flash, 1.00 scr, 1.2 ms | 1 flash, 1.00 scr, 1.4 ms | no flash, 1.00 scr, 1.6 ms |
| library: open (toolbar) | - | 1 flash, 1.00 scr, 78.3 ms | 1 flash, 1.00 scr, 78.2 ms |
| library: next page | - | no flash, 0.00 scr, 0.0 ms | no flash, 0.00 scr, 0.0 ms |
| library: previous page | - | 1 flash, 1.00 scr, 76.7 ms | no flash, 1.00 scr, 77.8 ms |
| library: into a folder | - | no flash, 1.00 scr, 2.6 ms | no flash, 1.00 scr, 3.4 ms |
| library: back up | - | no flash, 1.00 scr, 6.3 ms | no flash, 1.00 scr, 5.4 ms |
| library: close | - | 1 flash, 1.00 scr, 1.9 ms | no flash, 1.00 scr, 1.9 ms |
| library: open again | - | 1 flash, 1.00 scr, 5.5 ms | 1 flash, 1.00 scr, 5.7 ms |
| library: tap a document (opens it) | - | 1 flash, 1.00 scr, 8.1 ms | 1 flash, 1.00 scr, 8.4 ms |
| overview: open | - | 1 flash, 1.00 scr, 61.3 ms | 1 flash, 1.00 scr, 61.1 ms |
| overview: tap another tab | - | no flash, 1.00 scr, 12.5 ms | no flash, 1.00 scr, 11.9 ms |
| overview: tap a folder tab | - | no flash, 1.00 scr, 1.9 ms | no flash, 1.00 scr, 1.8 ms |
| overview: back arrow | - | no flash, 1.00 scr, 3.0 ms | no flash, 1.00 scr, 2.4 ms |
| overview: Library button | - | 1 flash, 1.00 scr, 7.7 ms | no flash, 1.00 scr, 7.4 ms |
| library: close #2 | - | 1 flash, 1.00 scr, 0.8 ms | no flash, 1.00 scr, 0.7 ms |
| new notebook: paper sheet open | - | 1 flash, 0.72 scr, 5.0 ms | 1 flash, 0.72 scr, 4.7 ms |
| new notebook: tap a paper | - | no flash, 1.00 scr, 7.9 ms | no flash, 1.00 scr, 8.3 ms |
| Save sheet: open | 1 flash, 0.45 scr, 2.5 ms | - | - |
| Save sheet: close | no flash, 0.45 scr, 1.3 ms | - | - |

## colour

| action | main | before | after |
|---|---|---|---|
| tool: tap Eraser | no flash, 0.06 scr, 3.0 ms | no flash, 0.06 scr, 2.7 ms | no flash, 0.06 scr, 3.0 ms |
| tool: back to Pen | no flash, 0.06 scr, 1.9 ms | no flash, 0.06 scr, 2.0 ms | no flash, 0.06 scr, 1.3 ms |
| undo | no flash, 0.94 scr, 5.0 ms | no flash, 0.94 scr, 3.3 ms | no flash, 0.94 scr, 3.3 ms |
| redo | no flash, 0.94 scr, 3.1 ms | no flash, 0.94 scr, 2.6 ms | no flash, 0.94 scr, 3.0 ms |
| pen sheet: open | 1 flash, 0.72 scr, 28.3 ms | 1 flash, 0.77 scr, 26.4 ms | no flash, 0.77 scr, 27.3 ms |
| pen sheet: flip a switch | no flash, 0.01 scr, 4.5 ms | no flash, 0.01 scr, 5.5 ms | no flash, 0.01 scr, 4.7 ms |
| pen sheet: pick a brush (rebuild) | no flash, 0.72 scr, 12.4 ms | no flash, 0.77 scr, 14.0 ms | no flash, 0.77 scr, 12.9 ms |
| pen sheet: close | no flash, 0.72 scr, 1.4 ms | no flash, 0.77 scr, 1.1 ms | no flash, 0.77 scr, 2.0 ms |
| settings: open | 1 flash, 0.86 scr, 8.8 ms | 1 flash, 0.93 scr, 13.4 ms | no flash, 0.93 scr, 14.6 ms |
| settings: pick Symmetry (rebuild) | no flash, 0.86 scr, 10.0 ms | no flash, 0.93 scr, 12.1 ms | no flash, 0.93 scr, 11.8 ms |
| settings: tap a theme colour (rebuild) | - | no flash, 1.00 scr, 16.1 ms | no flash, 0.99 scr, 15.8 ms |
| settings: back to black (rebuild) | - | no flash, 1.00 scr, 12.0 ms | no flash, 0.99 scr, 12.8 ms |
| settings: close | no flash, 0.86 scr, 1.5 ms | no flash, 0.93 scr, 0.9 ms | no flash, 0.93 scr, 1.1 ms |
| shapes sheet: open | 1 flash, 0.47 scr, 7.2 ms | 1 flash, 0.47 scr, 6.5 ms | no flash, 0.47 scr, 6.7 ms |
| shapes sheet: close | no flash, 0.47 scr, 1.2 ms | no flash, 0.47 scr, 1.3 ms | no flash, 0.47 scr, 1.3 ms |
| File sheet: open | - | 1 flash, 0.44 scr, 6.3 ms | no flash, 0.44 scr, 4.5 ms |
| File sheet: close | - | no flash, 0.44 scr, 1.7 ms | no flash, 0.44 scr, 0.9 ms |
| Export sheet: open | - | 1 flash, 0.51 scr, 3.5 ms | no flash, 0.51 scr, 2.7 ms |
| Export sheet: close | - | no flash, 0.51 scr, 1.4 ms | no flash, 0.51 scr, 1.3 ms |
| notebook: start | no flash, 1.00 scr, 10.9 ms | no flash, 1.00 scr, 11.0 ms | no flash, 1.00 scr, 10.5 ms |
| notebook: add page | no flash, 1.00 scr, 3.9 ms | no flash, 1.00 scr, 3.2 ms | no flash, 1.00 scr, 2.9 ms |
| notebook: page turn | no flash, 1.00 scr, 3.1 ms | no flash, 1.00 scr, 3.1 ms | no flash, 1.00 scr, 3.2 ms |
| notebook: page turn #2 | no flash, 1.00 scr, 3.3 ms | no flash, 1.00 scr, 2.7 ms | no flash, 1.00 scr, 3.0 ms |
| notebook: page turn #3 | no flash, 1.00 scr, 3.3 ms | no flash, 1.00 scr, 2.9 ms | no flash, 1.00 scr, 3.2 ms |
| page menu: open | 1 flash, 0.43 scr, 2.6 ms | 1 flash, 0.58 scr, 3.7 ms | no flash, 0.58 scr, 4.5 ms |
| page menu: close | no flash, 0.43 scr, 0.9 ms | no flash, 0.58 scr, 1.6 ms | no flash, 0.58 scr, 1.2 ms |
| pages view: open | 1 flash, 1.00 scr, 27.4 ms | 1 flash, 1.00 scr, 49.9 ms | no flash, 1.00 scr, 50.4 ms |
| pages view: next page of thumbnails | no flash, 0.00 scr, 0.0 ms | no flash, 0.00 scr, 0.0 ms | no flash, 0.00 scr, 0.0 ms |
| pages view: previous page | 1 flash, 1.00 scr, 72.7 ms | 1 flash, 1.00 scr, 47.7 ms | no flash, 1.00 scr, 48.7 ms |
| overview: Star filter | - | no flash, 1.00 scr, 2.4 ms | no flash, 1.00 scr, 2.9 ms |
| overview: Star filter off | - | no flash, 1.00 scr, 48.1 ms | no flash, 1.00 scr, 3.2 ms |
| pages view: close | 1 flash, 1.00 scr, 1.2 ms | 1 flash, 1.00 scr, 1.7 ms | no flash, 1.00 scr, 1.0 ms |
| pages view: open again | 1 flash, 1.00 scr, 24.8 ms | 1 flash, 1.00 scr, 47.6 ms | no flash, 1.00 scr, 3.2 ms |
| pages view: close again | 1 flash, 1.00 scr, 1.0 ms | 1 flash, 1.00 scr, 1.4 ms | no flash, 1.00 scr, 1.4 ms |
| pages view: open again #2 | 1 flash, 1.00 scr, 25.1 ms | 1 flash, 1.00 scr, 47.0 ms | no flash, 1.00 scr, 3.2 ms |
| pages view: close again #2 | 1 flash, 1.00 scr, 1.4 ms | 1 flash, 1.00 scr, 1.4 ms | no flash, 1.00 scr, 1.4 ms |
| library: open (toolbar) | - | 1 flash, 1.00 scr, 79.0 ms | no flash, 1.00 scr, 78.1 ms |
| library: next page | - | no flash, 0.00 scr, 0.0 ms | no flash, 0.00 scr, 0.0 ms |
| library: previous page | - | 1 flash, 1.00 scr, 77.0 ms | no flash, 1.00 scr, 76.4 ms |
| library: into a folder | - | no flash, 1.00 scr, 2.1 ms | no flash, 1.00 scr, 2.7 ms |
| library: back up | - | no flash, 1.00 scr, 6.4 ms | no flash, 1.00 scr, 6.0 ms |
| library: close | - | 1 flash, 1.00 scr, 1.8 ms | no flash, 1.00 scr, 1.9 ms |
| library: open again | - | 1 flash, 1.00 scr, 5.6 ms | no flash, 1.00 scr, 5.3 ms |
| library: tap a document (opens it) | - | 1 flash, 1.00 scr, 8.3 ms | 1 flash, 1.00 scr, 7.8 ms |
| overview: open | - | 1 flash, 1.00 scr, 60.7 ms | no flash, 1.00 scr, 61.1 ms |
| overview: tap another tab | - | no flash, 1.00 scr, 11.8 ms | no flash, 1.00 scr, 12.0 ms |
| overview: tap a folder tab | - | no flash, 1.00 scr, 1.4 ms | no flash, 1.00 scr, 1.6 ms |
| overview: back arrow | - | no flash, 1.00 scr, 2.4 ms | no flash, 1.00 scr, 3.0 ms |
| overview: Library button | - | 1 flash, 1.00 scr, 7.7 ms | no flash, 1.00 scr, 7.6 ms |
| library: close #2 | - | 1 flash, 1.00 scr, 1.0 ms | no flash, 1.00 scr, 0.6 ms |
| new notebook: paper sheet open | - | 1 flash, 0.72 scr, 4.9 ms | no flash, 0.72 scr, 5.2 ms |
| new notebook: tap a paper | - | no flash, 1.00 scr, 9.2 ms | no flash, 1.00 scr, 8.4 ms |
| Save sheet: open | 1 flash, 0.45 scr, 2.5 ms | - | - |
| Save sheet: close | no flash, 0.45 scr, 0.8 ms | - | - |
