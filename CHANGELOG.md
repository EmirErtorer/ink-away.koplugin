# Changelog

All notable changes to Ink Away are listed here, newest first. Versions follow
[Semantic Versioning](https://semver.org), and the format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each version's download
is on its [GitHub release](https://github.com/EmirErtorer/ink-away.koplugin/releases);
versions marked *Prerelease* were test builds.

## [Unreleased]

### Fixed
- With palm rejection on (the default on pen readers), a text box's Done and
  Format buttons answered neither the pen nor a finger, so the keyboard could
  not be closed. Both work now, and a finger tapping away closes the box.
- Colour ink on colour e-ink settles to its true colour once the pen rests.
  Pale colours such as pink could stay invisible, and blue could stay cyan,
  until something else redrew the page.

## [4.0.0] - 2026-10-10

The biggest update yet: write on your books, a whole new set of pens, layers,
dark mode, paper colours, a guide and updates from inside Ink Away.

### Added

**Write on your books**
- Annotate any book KOReader opens (EPUB, MOBI, FB2, PDF, DjVu, CBZ and more):
  pen, eraser, shapes, text and pictures right on the page.
- Ink follows the text: on a reflowing book each stroke is anchored to the words
  it was written beside, so it stays with them when you change the font size,
  margins or orientation. On PDFs and comics it keeps its place on the page.
- Smart highlighter: a highlighter stroke over text becomes KOReader's own
  highlight, in the pen's colour, and shows in your highlights list. Strokes that
  run into the margin, wobble or cross lines still snap; over empty space it
  stays ink.
- Book notes: a notebook for each book, with a page per chapter, in a window
  over the page that expands to full screen.
- The annotation toolbar can sit on any side of the screen and folds away.
- Erasing over a book cuts strokes where you rub; "Erase whole strokes" brings
  the old eraser back.
- Annotations live beside the book's own KOReader data and follow the book when
  it is moved or renamed. KOReader's Reset keeps them; deleting a book, or
  "Delete all annotations on this book", puts them in the trash for 30 days.
- The book gestures are set up for you (swipe up or down the right edge, or
  two-finger swipes when those are taken), with a notice saying which you got.

**Pens**
- Pen pressure on pen readers (Kindle Scribe, Kobo stylus): the line follows
  how hard you press. Switch it in Pen and input.
- New pens: Ballpoint, Fountain and Calligraphy (with its own nib angle).
- See-through pens that blend with the page: Highlighter (text stays black on
  top), Marker and Watercolor.
- Smudge, which moves ink (and only ink) and mixes colours the way paint does.
- A compact pen case: up to 20 saved pens, each shown at its real size, "+" for
  a new pen of any kind, and hold to move, copy or remove one. New readers start
  with Fineliner, Ballpoint, Pencil, Calligraphy, Highlighter, Watercolor and
  Smudge.
- A floating pen strip with your first saved pens, and the pen's colour under
  the Pen button.

**Layers**
- Drawings can be drawn in layers, up to five. File, Layers turns them on, and
  what is drawn so far becomes the first layer.
- A small strip at the right, shown only while layers are on, adds a layer and
  picks the one to draw on; tap that one to show or hide it, rename, move,
  merge down or delete it. Turning layers off merges them into one drawing.
- Only the layer you draw on is touched: the lasso, both erasers and the paint
  bucket leave the others alone, and the eraser shows the layers under it as
  it goes. A stroke under other layers stays under them while it is drawn.
- Hidden layers are left out of exports and thumbnails.
- No layer is kept as a picture of its own, so drawing stays as fast as on a
  plain page.

**Gestures and pen buttons**
- Choose what each gesture and pen button does, from one list of actions, with
  a warning when two would clash.
- By default, holding the pen's side button turns it into a highlighter.

**Look**
- Dark mode for Ink Away's toolbars, menus and library: Light, Dark or
  following KOReader's night mode. Your page and colours are never changed.
- Paper colours: twelve papers on colour screens (cream, sandpaper, legal pad,
  kraft, blueprint, chalkboard and more) and white or black on grey ones. The
  ruling and grid take the paper's shade so they always show, black ink and text
  turn white on a dark paper, and exports come out on the same paper.

**Help**
- A guide: short cards on what a glance doesn't show, by topic, each with
  "Show me".
- A notice the first time Ink Away opens, with the book gestures you got.
- Test pen and touch, in Settings: shows how your pen, its buttons and your hand
  arrive, handy for bug reports.
- Check for updates: Settings, Updates shows the latest release and, apart from
  it, any newer prerelease, with their notes, and installs them after checking
  the download. Once a day, only on Wi-Fi that is already on, Ink Away looks by
  itself and puts a dot on the Settings button when there is something new. You
  can always go from a prerelease back to the latest release, never to an older
  one.

**Android and Boox**
- On a Boox, Ink Away asks the screen for its fast refresh while you draw.
- On Android readers whose pen KOReader still reports as a finger (before
  KOReader 2026.08), the pen draws again instead of scrolling the page, and a
  tip explains slow drawing on readers that need a setting changed.

### Changed
- Settings are tidier: pen settings live in Pen and input, every setting is in
  one place, and Settings fits a Paperwhite without scrolling.
- Watercolor is smoother and three times faster.
- See-through pens on grey e-ink refresh only what changed as you draw.

### Removed
- Acrylic and Stipple are no longer in the pen picker (drawings that use them
  still show them).

### Fixed
- A stroke ends exactly where the pen lifted (it could stop short).
- A quick drag on a slider no longer moves the whole menu.

### For developers
- The code passes luacheck, and the tests (about 3,800 checks, many on
  KOReader's real drawing, zip and network code) run on every push.

## [3.3.0] - 2026-10-05

Ink Away becomes a notebook app: a library, a binder-style browser, search, a
trash, links, a contents page, and handwriting you can turn into text.

### Added
- No more Save button: every drawing and notebook is its own file and saves
  itself. The File menu has rename, duplicate, export and new.
- A library with folders, thumbnails and + Drawing / + Notebook / + Folder.
- Browse: a folder's notebooks as coloured tabs beside their pages, like a
  binder. Star pages, filter by stars, move or copy pages between notebooks.
- Search by name, or inside pages for typed and converted text.
- A trash: deleted notebooks, drawings, folders and pages wait 30 days.
- Choose what Ink Away opens on: the last document, the library or your
  notebooks.
- Page titles, stars and per-page paper; new papers and planners (handwriting
  practice, checklist, storyboard, music, daily, weekly, monthly, meeting notes,
  habit tracker and more).
- Page templates, links between pages and notebooks, and a contents page built
  from your titled pages.
- PDF export with bookmarks and working links, and a whole folder as one PDF.
- Convert to text: lasso printed handwriting and it becomes a text box, read on
  the device. Nothing is sent anywhere.
- One selection for strokes, shapes, pictures and text: move, resize, rotate,
  flip, duplicate, recolour, cut, copy and paste across pages and notebooks.
- Hold to straighten a line, box, ellipse or triangle at the end of a stroke.
- An eraser mode that removes whole strokes.
- Gestures: two-finger tap to undo, double tap to redo, two-finger swipes to
  turn pages or open your notebooks; hold Prev or Next for the first or last
  page.
- A theme colour on colour screens, and colour ink while you draw.

### Changed
- Lasso has its own toolbar button; Pan is a round button above the zoom
  control.
- Saving big notebooks is about 90% faster, drawing 12-28% faster per point,
  with fewer flashes everywhere.
- Android: far fewer screen refreshes while drawing.

### Fixed
- Undo puts a moved selection back; erased shapes are no longer picked up.
- Long menus on small or landscape screens slide over the toolbar instead of
  scrolling.

## [3.2.0] - 2026-10-02

Everything since 3.1.0 in one release.

### Added
- Landscape mode, remembered between sessions, with landscape exports.
- Copy, cut and paste in text boxes, using KOReader's clipboard.
- A background remover for pictures.

### Changed
- Colour screens draw much faster: ink shows in black at once and settles to
  colour when you pause.
- Menus open about 40% faster, and landscape is as fast as portrait.

### Fixed
- Small handwriting no longer turns into straight lines, and quick writing no
  longer joins neighbouring letters. On Kindle Scribe, strokes no longer join
  when your hand rests on the screen.
- Exporting long PDFs no longer crashes: pages are written one at a time, with a
  progress bar you can stop.
- The eraser no longer removes notebook lines.
- Typing no longer zooms the page when you tap away, and toolbar taps no longer
  lag after closing a menu.

## [3.1.3] - 2026-09-28 *Prerelease*

### Changed
- Landscape rebuilt to be as fast as portrait on readers that turn the screen
  in software.
- Grid options moved to their own panel, so Settings fits without scrolling.

### Fixed
- Reopening Ink Away no longer stacks a second canvas over the old one.
- Online picture search: a tap-to-add crash and searching again.

## [3.1.2] - 2026-09-26 *Prerelease*

### Added
- A pen input test in Settings, for stylus users.

### Changed
- Faster landscape drawing, and the grid no longer slows drawing.

## [3.1.1] - 2026-09-26 *Prerelease*

### Added
- Landscape orientation.
- An early background remover for pictures.

### Fixed
- A crash when tapping a picture in the online picture browser, and editing the
  search term there.

## [3.1.0] - 2026-09-25

### Added
- Add pictures: pick a file or search Wikimedia Commons or Openverse without
  leaving Ink Away (online only when you search).
- The pen's side button switches to the lasso.
- Save a drawing as a Bookshelf plugin ornament.

### Fixed
- Smoother colour panel, more reliable palm rejection, menus that no longer
  stay after closing, and the notebook bar's font.

## [3.0.0] - 2026-09-22

### Added
- Palm rejection: rest your hand while you write. On by default on Kindle
  Scribe and reMarkable, a switch away on Kobo and other pen readers. The rear
  eraser and the side button keep working.
- Hide the toolbar for full-screen drawing.

### Changed
- Every tool menu redesigned, and the canvas now runs edge to edge.
- Zoom moved to a floating control that fades when the pen comes near.
- A cleaner Shapes menu with large icons and one Fill switch.
- The canvas no longer slows down as strokes pile up; lower memory, quicker
  undo, smoother panning and zooming.

## [2.3.0] - 2026-09-21

### Changed
- Faster tool menus, drawing and undo, and memory reclaimed without a restart.

### Fixed
- A consistent notebook interface, and a crash in Settings.

## [2.2.3] - 2026-09-20

### Changed
- Palm rejection is steadier and on by default on pen devices.
- A redesigned drawing interface: full-bleed canvas, floating zoom and a
  collapsible toolbar.

## [2.2.2] - 2026-09-18

### Added
- An on-device pen diagnostic.

## [2.2.1] - 2026-09-18

### Added
- Palm rejection for pen devices.

## [2.2.0] - 2026-09-17

### Added
- Pictures: as many as you like, with move, resize, rotate, flip, duplicate and
  bring to front.
- Shape assist turns rough strokes into clean, editable lines, rectangles,
  circles and triangles.
- Tap or hold any shape to move, rotate, flip, duplicate, recolour, resize or
  delete it.

### Changed
- The paint bucket's fill stays with its shape; faster shape and picture
  dragging.

## [2.1.2] - 2026-09-17

### Added
- First versions of pictures on the canvas, shape assist and fill-to-shape,
  finished in 2.2.0.

## [2.1.1] - 2026-09-14

### Fixed
- Toolbar icons showing as warning triangles on a first install on some devices
  (notably Kindle Scribe).

## [2.1.0] - 2026-09-13

### Added
- Text notes: text boxes with bold, italic, underline, strikethrough,
  highlight, sizes and lists, a font picker that previews each font, snapping to
  the ruling, word-by-word undo, and an option to keep text safe from the eraser.
- A redesigned toolbar with icons, and a Redo button.

### Changed
- Notebook ruling style, spacing and strength are remembered for the next
  notebook.

### Fixed
- Reopening a text box no longer shifts it; the eraser and text look the same
  on screen and in exports.

## [2.0.2] - 2026-09-13

### Added
- First versions of text notes and the icon toolbar, finished in 2.1.0.

## [2.0.1] - 2026-09-12

### Fixed
- Shapes no longer get dropped or changed when you switch tools quickly.
- A steadier lasso, without the extra popup after selecting.

## [2.0.0] - 2026-09-12

### Added
- Notebook mode: multi-page notebooks, or any PDF opened as a notebook to write
  on. Lined, grid, dotted, margin and Cornell paper.
- Page turning, a page jump and a thumbnail overview; duplicate, reorder and
  delete pages.
- Export a notebook as a real PDF: all pages, the written ones or a range, with
  optional page numbers.
- Lasso select: draw a loop around ink, shapes or fills, then move, duplicate or
  delete them.

### Changed
- Separate folders for drawings, notebooks and their projects; existing files
  are sorted into them once, with nothing deleted.
- Ink Away sits at the top of the Tools menu.

## [1.5.0] - 2026-09-11

### Added
- The first notebook mode, with PDF import and export (completed in 2.0.0).

## [1.4.0] - 2026-09-10

### Added
- Colour ink on colour screens, a colour wheel and saved colour swatches.

### Changed
- The eraser leaves a background picture alone by default, with a switch to
  erase it too.

## [1.3.3] - 2026-09-10

### Fixed
- The brush maker shows its title and buttons as soon as it opens.

## [1.3.2] - 2026-09-10

### Fixed
- Shapes vanishing when lifting the pen was taken for a swipe; arrows can be
  picked up by their heads.

## [1.3.1] - 2026-09-09

### Fixed
- Faster symmetry, background loading, crop dragging and custom brushes.

## [1.3.0] - 2026-09-09

### Added
- Symmetry (vertical, horizontal, four-way), a brush maker, a background
  picture to draw over, arrows, area export and an optional ghosting clean-up.

### Changed
- A tidier settings menu; the grid stays out of the eraser and the export.

## [1.2.2] - 2026-09-09

### Fixed
- The eraser ignores the pen style; grid and performance fixes, a default save
  folder and a cleaner exit.

## [1.2.1] - 2026-09-09

### Added
- Grid styles, and richer brush textures.

## [1.2.0] - 2026-09-09

### Added
- Shapes, colour, the paint bucket and shape editing.

## [1.1.3] - 2026-09-09

### Added
- The paint bucket's own colour and opacity.

## [1.1.2] - 2026-09-09

### Added
- Shape editing, rotation and a paint bucket.

## [1.1.1] - 2026-09-08

### Added
- The shapes tool and pen colour.

## [1.1.0] - 2026-09-08

### Added
- Pen colour and eraser size.

### Changed
- Much faster zoom and panning.

## [1.0.0] - 2026-09-08

First stable version.

## [0.0.1] - 2026-09-08

The first public release.

[Unreleased]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v4.0.0...HEAD
[4.0.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v3.3.0...v4.0.0
[3.3.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v3.2.0...v3.3.0
[3.2.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v3.1.3...v3.2.0
[3.1.3]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v3.1.2...v3.1.3
[3.1.2]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v3.1.1...v3.1.2
[3.1.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v3.1.0...v3.1.1
[3.1.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.3.0...v3.0.0
[2.3.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.2.3...v2.3.0
[2.2.3]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.2.2...v2.2.3
[2.2.2]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.2.1...v2.2.2
[2.2.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.1.2...v2.2.0
[2.1.2]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.0.2...v2.1.0
[2.0.2]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.5.0...v2.0.0
[1.5.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.3.3...v1.4.0
[1.3.3]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.1.3...v1.2.0
[1.1.3]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v0.0.1...v1.0.0
[0.0.1]: https://github.com/EmirErtorer/ink-away.koplugin/releases/tag/v0.0.1
