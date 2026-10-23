# Changelog

All notable changes to Ink Away are listed here, newest first. Versions follow
[Semantic Versioning](https://semver.org), and the format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each version's download
is on its [GitHub release](https://github.com/EmirErtorer/ink-away.koplugin/releases);
versions marked *Prerelease* were test builds.

## [Unreleased]

### Added
- Phone or computer (Wi-Fi): get your notebooks and drawings onto a phone or
  computer, or add PDFs and pictures from one, with nothing to install. Open
  it from the library's menu, Export, or Add image; the reader shows a QR code
  and an address, and any phone or computer on the same Wi-Fi opens a page in
  its browser. The page lists your folders, documents and pictures, and gives
  each document as a PDF, a PNG (drawings) or its Ink Away file. PDFs and PNGs
  are made when you ask for them, a page at a time so the reader stays
  responsive, with progress and Cancel on both sides. The reader serves the
  page itself: nothing goes over the internet or through anyone's server. The
  address holds a secret that changes each time, and sharing stops when you
  close it, when the reader sleeps, when Wi-Fi goes, or after 15 minutes of
  nothing happening. The page takes Ink Away's theme colour (green on a reader
  without a colour screen).
- Adding files from the page, with "Allow adding files" on (on when opened
  from Add image, off otherwise, and switchable either way). Everything sent
  arrives in Library › Imported, each kind in its own folder: PDFs become
  notebooks you can write on in Imported › PDFs (the PDF itself is kept once),
  pictures go to Imported › Pictures, and Ink Away files to Imported ›
  Notebooks and drawings. The reader asks whether to open notebooks that
  arrive, saying where they are (notebooks arriving together share one
  question, and "Don't ask again" leaves a note). Pictures can be made smaller
  on the phone first (Original, Large, Medium or Small, showing how much
  smaller). Every file is checked by what it is, against size limits and the
  space left, and only kept once whole; an Ink Away file is read as data only
  and loses any reference to files elsewhere on the reader.
- Pictures in the library: JPEGs and PNGs in a library folder (Imported ›
  Pictures, for one) show as picture cards. Tap one to see it full screen;
  hold it to rename, move or delete it (deleted pictures wait in the trash).
- Add image has clearer choices: From this reader, Sent from your phone (the
  pictures in Imported › Pictures, as a grid), Get from your phone or computer
  (the QR code, ready to receive), Search online and Background.

### Changed
- The library's ⋯ menu is a sheet like the others, each option with a line
  saying what it does: Phone or computer (Wi-Fi), Write on a PDF from this
  reader, the order, and Trash.
- The cover style new notebooks get on Bookshelf is now set from a notebook's
  long press sheet ("Use for new notebooks", which was "Use for all") rather
  than in Settings.

### Fixed
- Erasing was slow and left trails of circles on e-ink (#47): the eraser's outline
  under the pen is now off unless turned on in the Eraser sheet (Show the eraser
  while erasing).
- Kobo Elipsa (the 2021 model): drawing keeps up with the pen and a finger. It
  trailed well behind, as each screen update held up the reader until the
  screen had taken it; now a helper makes the updates, with the screen's own
  handwriting mode on, as in Kobo's notebooks. Thanks to maks (#45, #48).
- The page turn buttons turn the pages of grids and sheets as well as the
  page: the library, folder icons, sent pictures, the guide, search, the trash
  and lists (#53). They did nothing there.
- Book notes after the Book notes folder (or a notes notebook) was renamed or
  moved in the library (#54): each book opens its own notes where they are now,
  instead of starting new ones in a new Book notes folder, and new books' notes
  go into the renamed folder. Notes left behind this way before are found again
  the next time their book opens them. Nothing in the notes themselves changes.
- Kobo Elipsa, Elipsa 2E and Sage: the eraser keeps up over a notebook's lines,
  a book or a picture (#47, #50). Each point asked the screen for its slower grey
  update, which held the eraser up; it now erases with the fast one, and the
  lines or picture under it show again as it lifts.
- Kobo Elipsa (the 2021 model): the highlighter and other see-through pens keep
  up with the pen too (#50). The helper that makes the screen updates now also
  makes the grey ones a stroke needs, so they no longer hold up the reader. A
  helper busy with a slow update is waited for instead of being given up, and
  after a failure the next stroke tries it again, so drawing no longer stays slow
  until Ink Away is reopened.

## [4.2.0] - 2026-10-17

Everything from the 4.1.0 and 4.1.1 prereleases, now tested on readers, plus
coloured library folders, typing on a physical keyboard and fixes for the
book toolbar and the Kindle Scribe's pen. Kobo Libra Colour and Kindle Scribe
testers confirmed the pen, colour and highlight fixes.

### Added
- Library folders in colour: hold a folder for Colour and icon, then pick one
  of twelve colours and, if you like, an icon for its front. The icons are
  the ones in your KOReader: its own, Ink Away's, and any SVG or PNG you put
  in the koreader/icons folder. The look is kept in the library, so updates
  leave it alone, and each folder is drawn once, so the library opens as fast
  as before. Renamed and moved folders keep their look.
- Typing on a physical keyboard: a Bluetooth or USB keyboard that KOReader has
  set up types into text boxes, with Shift, Caps Lock, Backspace, Delete, the
  arrows, Home and End, Enter for a new line and Esc to finish the box. Ctrl+Z
  and Ctrl+Y undo and redo, Ctrl+A selects all and Ctrl+C, Ctrl+X and Ctrl+V
  copy, cut and paste. When KOReader counts the keyboard, the on-screen one
  stays away, as in KOReader's own text fields.

### Fixed
- Over a book with the toolbar along the bottom, a tool's settings opened at
  the top of the screen. They now open just above the toolbar, as they open
  beside it on the other sides.
- On the Kindle Scribe a resting palm took the pen again once a book had been
  opened, until KOReader was restarted: the pen stopped being recognised near
  the hand and drew stray lines. Opening a book, the reader sleeping or some
  popups pause KOReader's input, and after that Ink Away no longer kept the pen
  and the palm apart. It now does, whatever came before.
- On KOReader 2026.07.1 and later, a touch panel that also reports a resting
  hand as a single point can no longer move or lift the pen.

## [4.1.1] - 2026-10-16 *Prerelease*

Notebooks and drawings on Bookshelf shelves with drawings in twelve frames,
pen pressure as a setting that starts off and a round of pen and page fixes.
A prerelease, as the pen and colour fixes could only be tested in the
emulator: reports from pen and colour readers are very welcome.

### Added
- Go to the contents page: in the page menu of a notebook that has one, and
  as an action for any gesture or page turn button, with Back to return.
  The guide now says how links are followed: a tap with Pan, or with a
  finger while palm rejection is on, on ink, shapes and pictures alike.
- On colour screens ink keeps its colour in KOReader's night mode: blue
  stays blue instead of turning yellow, and dark ink turns light so it reads
  on the dark page. Keep colours in night mode in Settings turns it off.
- In annotation mode the eraser takes away the highlights it crosses, as it
  does ink, in one undo step with whatever ink it cut. A long press on a
  highlight (with a finger while palm rejection is on, or with the lasso)
  offers to remove it. Until now a highlight could only go from KOReader's
  own menu once Ink Away was closed.
- The reader's page turn buttons work in Ink Away: they turn a notebook's
  pages, and the book's in annotation mode, where they did nothing before.
  Gestures and pen buttons can give them another action.
- Refresh the screen by hand: a long two-finger swipe down redraws the whole
  screen with a full refresh, so anything a quick refresh missed shows and
  the faint marks of fast drawing go. Any gesture can be set to it in
  Gestures and pen buttons, and Settings has a Refresh the screen button,
  in annotation mode too.
- The first time a finger drags on the page with palm rejection on, a note
  says why it doesn't draw: the pen draws and a finger moves the page, and
  palm rejection is in the pen menu, Pen and input. It shows once.
- Notebooks on a Bookshelf shelf. With the Bookshelf plugin installed, a
  shelf can show "Ink Away notebooks": a new shelf shows every notebook's
  cover front facing, and a tap opens it in Ink Away. Without Bookshelf
  nothing changes.
- Six cover styles for the shelf: Front page (the notebook's first page, with
  a spiral and its name on a coloured band), Hardcover, Composition book,
  Reporter pad, Kraft with window and Legal pad. The first time, your
  notebooks get a mix of all six, so you see what there is. A long press on a
  notebook on the shelf picks its style and colour, which follows its tab
  colour until you pick another; "Cover on the shelf" in a notebook's menu in
  the library does the same, and "Covers on Bookshelf" in Ink Away's settings
  sets the style new notebooks start with. A notebook keeps its cover through
  renames, moves and the trash.
- Covers are quick and never draw your strokes again. The first page on a
  cover is a picture Ink Away keeps of it as you close the notebook or turn
  from that page, only when it changed; writing on any other page leaves the
  cover alone. A notebook not opened since has its first page drawn once in
  the background, small and only while no notebook or book is open. The long
  press sheet opens at once, also for a notebook with smudges.
- Drawings on a Bookshelf shelf. A shelf can show "Ink Away drawings": each
  drawing hangs face out in a frame, and a tap opens it in Ink Away. There
  are twelve frames, from old to modern: Gilded Baroque, Louis XVI, Dutch
  Ripple, Carved Victorian, Arts and Crafts, Art Deco, Museum Mat, Floating
  Frame, Minimal Metal, Painted Box, Canvas Wrap and Instant Photo, each in a
  few finishes (gold, antique gold or silver gilt, oak or walnut, and so on).
  A new drawing gets a frame and finish at random, all twelve before any
  comes again. A long press on a drawing on the shelf picks its frame and
  finish, as does "Frame on the shelf" in a drawing's menu in the library.
  A drawing keeps its frame through renames and moves.
- The frames are as quick as the notebooks' covers: each was carved and lit
  once ahead of time and comes as small pieces that are fitted round the
  drawing, so a cover takes moments and the frame fits any drawing's shape.
  The drawing on a cover is a picture Ink Away keeps as you close it, only
  when it changed. With Bookshelf's "True cover aspect" on, the frame hugs
  the drawing in its own shape; with it off (Bookshelf's default, which shows
  every cover 2:3) the drawing fills a 2:3 frame, trimmed a little at its
  sides, so it is never stretched.

### Changed
- Pen pressure is now "Pen pressure (Beta)" in Pen and input, and starts off,
  also on readers that had it on. It shows on readers with a pen: the Kindle
  Scribe and the Kobo Elipsa, Sage, Elipsa 2E and Libra Colour. Another reader
  shows it once Ink Away has seen a pen on it. It works with Palm rejection
  on. While it is off the pen's pressure is not read at all: Pencil and
  Calligraphy keep an even width, and Ballpoint and Fountain follow your
  writing speed, as they do with a finger.

### Fixed
- A page with smudges could take ten times longer to open after an export or
  after Bookshelf covers were drawn: the smudge's drawing was left running
  slowly. It now runs at full speed whatever was drawn before.
- With "Fit the toolbar in the margin" on, the book's toolbar ended right
  where the text began. It now leaves a little space before the text.
- With the screen turned upside down (a Kobo Libra Colour held with its
  buttons on the left, for one) the page under Ink Away was dark: strokes
  showed as white boxes and the eraser drew white, over a book and in
  drawings alike. The page shows as it does the right way up.
- A page added to a book's notes named the notebook in the strip above it
  instead of its chapter, so it looked like another notebook had opened. It
  names the chapter it belongs to now.
- Opening a book's notes in a new chapter, adding a page and writing only on
  that one moved the notes to the chapter before when the notes closed, and
  the chapter opened on an empty page the next time. The chapter's page now
  stays when a page after it has notes, and goes with the empty pages after
  it when they are all left empty.
- On a pen reader a tap with the lasso did nothing (or said "Nothing inside
  the loop"), so what was cut or copied could not be pasted and a picture,
  shape or text box could not be picked out with a tap. A tap with the pen
  now does what a finger's tap does.
- A tool menu dragged out of the way went back to where it opens as soon as
  an option was picked in it, and a menu opened from it (Pen type, the colour
  wheel, a font) opened in the usual place too. Both now stay where the menu
  was dragged, kept whole on the screen; a menu opened later starts in its
  usual place.
- Over a book, Pen after the highlighter and another tool (the eraser, say)
  gave the highlighter back. It gives back the pen you had before the
  highlighter.
- On Android readers (a Boox, for one) "Nothing to undo" could start showing
  on every tap, with a finger or the pen, until Ink Away was closed. When the
  system took a touch away in the middle of a stroke, Ink Away later handed
  KOReader a finger that was no longer there, so every tap after it read as a
  two finger tap, which is Undo. A touch the system takes away now goes for
  Ink Away too.
- A shape being dragged out with a lowered opacity, or in a pale colour,
  showed a broken outline or none at all until a menu opened: the quick
  refresh that keeps the outline up with the pen shows only black and white.
  The outline is now drawn in the page's ink while it is dragged, and the
  shape takes its colour and opacity when it is placed.
- On colour e-ink a grey pen did not show while writing: the quick refresh
  used for live ink shows only black and white, and a grey has no colour to
  show. It now writes in the page's ink and turns grey when the pen lifts, as
  every pen does with "Colour while drawing" off, which on a dark paper now
  writes in white instead of black.
- Ballpoint and Fountain lines no longer turn thin when the pen lifts. A
  straight stroke is kept as its two ends, and its tapered ends' thinness was
  drawn all along it on the page, in thumbnails and in exports, so the width
  you pressed disappeared. Notes written before show at their proper width.
- Each lift of the pen drew the whole stroke again from its saved copy with
  the Ballpoint, Fountain and Calligraphy, and with the Pencil when pressure
  was on, which could make writing lag on a Kindle Scribe (with the Pencil it
  took about twenty times the rest of the lift). A lift now draws only what it
  changes: the thinning end of a Ballpoint or Fountain stroke, and nothing for
  the others. That end now shows on the screen at once; it often waited for
  the page's next full redraw before. A page full of Ballpoint or Fountain
  writing draws faster too.
- On a Kindle Scribe the ink could fall seconds behind the pen, and letters
  written quickly came out straightened. Ink Away asked the screen for a
  refresh at every point the pen reported, more than the Scribe's display can
  show, so the requests queued up. The live ink is now shown at a steady pace
  of up to fifty refreshes a second, as on colour readers.
- On a Kobo Sage or Elipsa the ink showed as scattered dots and dashes while
  writing, and the whole strokes only appeared when the screen was redrawn
  (closing the toolbar, say). Their display drops many of the tiny updates
  sent at every point of the pen. The live ink is now shown at a steady pace
  there too, and each stroke is shown whole once more as the pen lifts. Black
  ink is shown then in the same quick mode it was drawn with, so the screen is
  free sooner for the next letter.
- Closing Ink Away took the pen away from whatever had it before: another
  plugin that draws with the pen lost it until it was opened again, and with
  two Ink Away windows open (a book's notes and its annotation), closing one
  left the other without palm rejection, so the hand drew lines. Closing a
  window now gives the pen back to the one under it, or to the plugin that
  had it.
- On a Kobo the pen's eraser end highlighted and its side button did nothing,
  whatever Gestures and pen buttons said: Ink Away read a Kobo pen's buttons
  as a Kindle Scribe's. The eraser end now erases and the side button
  highlights, each as set in Gestures and pen buttons, also with
  pencil.koplugin's input.lua installed. The setting for a second side
  button is gone, as no Kobo or Kindle pen has one.
- On a Kindle Scribe with pencil.koplugin's input.lua installed, the pen's
  side button did nothing. It does what Gestures and pen buttons says again.
- On Android readers (a Boox, for one) the pen's eraser end was ignored until
  the pen had drawn once, taken for a resting hand. It erases from the first
  touch now, with KOReader 2026.08 or later. The pen's side button still
  can't work there: KOReader doesn't pass it on to plugins on Android.

## [4.1.0] - 2026-10-11 *Prerelease*

A text tool update, with fixes for colour readers and the Kindle Scribe. A
prerelease, as most of it could only be tested in the emulator: reports from
colour and pen readers are very welcome.

### Added
- Text boxes turn to any angle. While a box is open, drag the ring on the stem
  above it round its middle; it snaps to quarter turns. A box picked out with
  a hold or the lasso turns with the selection's handle and its quarter turn
  button too. A turned box is edited turned, with the caret, selection and
  grips following its lines, and pages, thumbnails and exports show it the
  same. The eraser and taps find it where it is drawn.
- Text colours. On a colour screen a word or a selection can be coloured
  (black, two greys, red, orange, green, blue, purple and up to three colours
  of your own from the colour wheel); a grey screen offers the greys.
- Highlight colours. Text highlights come in yellow (the default, which
  highlights made before take too), orange, blue, green and pink, plus up to
  three of your own; hold one you added to remove it. A grey screen keeps
  its grey, and on a dark paper a highlight is toned down so white letters
  read on it. Exports show the colours as the screen does.
- The Format sheet has tabs: Text (styles, size, colour, highlight and Plain
  to clear them), Paragraph (alignment, lists, line spacing, direction and the
  font) and Edit (copy, cut, paste, select all and today's date).
- Alignment: left, centre or right, for each box.
- Line spacing: tight, normal or loose, for each box.
- Reads down and Reads up turn a box on end, for a book's margins: a new box
  stands where it was tapped, an older one where it shows, and a line too
  long for the page there is shortened.
- The book annotation toolbar can fit in the book's margin: "Fit the toolbar
  in the margin" in Book ink settings (off by default) makes it as wide as
  the margin on its side, with its icons sized to it, so it stays clear of the
  text. It stays thick enough to tap, so a narrow margin needs widening in the
  reader's settings; PDFs and comics keep the usual toolbar.
- Checklists: a list with a box before each line. Tap a box to tick it, with
  the text open or closed (one undo step); a ticked item greys out.
- A second tap on a word in the text being written selects it, and the
  keyboard stays to type over it.

### Changed
- The Format sheet stays open while you pick options, so several can follow
  one another; Done, Format or a tap outside brings the keyboard back. The
  font can be changed there too, so it is at hand over a book while writing.
- A text box's grips are sized for a finger: about 9 mm to hit on any reader,
  just outside its corners so a tap near a letter still places the caret, and
  always whole on the screen. Dragging the band around the frame moves the box
  too.
- A tap away from a text box only closes it. It used to start a new box where
  you tapped and bring the keyboard straight back; a tap on another box still
  opens that one.

### Fixed
- On colour e-ink (Kobo Libra Colour and others) a shape being dragged out no
  longer falls behind the pen. Each move asked the screen to redraw the whole
  shape's box, and the screen queued every one of them; now each new outline
  waits for the last to show, so it stays with the pen at any size.
- On a Kindle Scribe a hand resting on the screen could draw lines, or keep the
  pen from drawing, until a stroke or two were written with the hand lifted.
  When the touch screen took the edge of the hand for a pen, Ink Away took it
  for the real pen. Only the pen's own digitizer is the pen now, and a hand on
  the screen while the side button is held is never taken for it either.
- A pen stroke that starts on a floating button (zoom, Pan, the toolbar's
  chevron, the pen or layer strip) is drawn instead of lost. A pen that lifts
  within about 1.3 mm of where it landed, and within KOReader's hold time,
  still presses the button.
- On colour e-ink, moving, resizing or turning a text box and dragging out the
  export area keep up with the finger, as shapes now do: each refresh waits
  for the panel to show the last.
- With "Erase whole strokes" on, the eraser takes a text box it touches unless
  text is protected, and a picture when "Erase pictures" is on. It used to
  leave both alone whatever the settings said. As with a filled shape, rubbing
  out writing on top of one keeps it. "Protect text from eraser" is in the
  Eraser's sheet now as well as the Text sheet.

## [4.0.1] - 2026-10-10

Two fixes for pen and colour readers.

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

[Unreleased]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v4.2.0...HEAD
[4.2.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v4.1.1...v4.2.0
[4.1.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v4.1.0...v4.1.1
[4.1.0]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v4.0.1...v4.1.0
[4.0.1]: https://github.com/EmirErtorer/ink-away.koplugin/compare/v4.0.0...v4.0.1
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
