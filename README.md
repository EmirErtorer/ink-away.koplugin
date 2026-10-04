# Ink Away

A **drawing** & **note-taking** app for KOReader, with **palm rejection** for stylus users. Draw or write with finger or stylus, take notes across a notebook, or annotate any PDF. You can export a transparent or white PNG, or a paged PDF, at your exact screen size. 

## Screenshots

<table>
  <tr>
    <td width="33%" valign="top"><a href="assets/screenshots/pen-settings.png"><img src="assets/screenshots/pen-settings.png" alt="Pen settings"></a><br><sub>The pen: size, opacity, brush style and shade, with palm rejection.</sub></td>
    <td width="33%" valign="top"><a href="assets/screenshots/brush-maker.png"><img src="assets/screenshots/brush-maker.png" alt="Brush maker"></a><br><sub>Design your own brush while a sample stroke redraws live.</sub></td>
    <td width="33%" valign="top"><a href="assets/screenshots/shapes-menu.png"><img src="assets/screenshots/shapes-menu.png" alt="Shapes menu"></a><br><sub>Shapes and arrows, a fill toggle, snapping, paint bucket and lasso.</sub></td>
  </tr>
  <tr>
    <td width="33%" valign="top"><a href="assets/screenshots/text-settings.png"><img src="assets/screenshots/text-settings.png" alt="Text settings"></a><br><sub>Typed text with any installed font, sizing and ruling snap.</sub></td>
    <td width="33%" valign="top"><a href="assets/screenshots/settings-menu.png"><img src="assets/screenshots/settings-menu.png" alt="Settings"></a><br><sub>Notebooks, open a PDF to annotate, grid, symmetry and autosave.</sub></td>
    <td width="33%" valign="top"><a href="assets/screenshots/notebook.png"><img src="assets/screenshots/notebook.png" alt="Notebook page"></a><br><sub>A notebook page with handwritten notes, an image and shapes.</sub></td>
  </tr>
</table>


## Features

- **Pen**: size, opacity, color (greys everywhere, full color + a wheel on color screens) and brush styles (you can make your own brushes too).
- **Shapes & arrows** (line, curve, rectangle, ellipse, triangle, filled or outline): hold one in Pan mode to edit; plus a **paint bucket** for one-tap fills.
- **Eraser** that removes ink (back to transparent) instead of painting white, or whole strokes at a time.
- **Text boxes**: any installed font, bold/italic/underline/highlight, sizes and lists.
- **Lasso select**: move, duplicate, or cut and copy, then paste on any page of any notebook or drawing. Four-way **symmetry**, and a **background image** to draw over.
- **Palm rejection**: rest your hand, only the pen draws (on by default on Kindle Scribe / reMarkable). The pen can still tap the toolbar and menus.
- **Gestures**: tap with two fingers to undo; swipe sideways with two fingers to turn a notebook's page; pinch to zoom and drag with two fingers to move around; hold Prev or Next in the bottom bar to jump to the first or last page. With palm rejection on, "Finger on the page" in the pen settings decides what a finger does while the pen writes: Navigate (drag to scroll, swipe to turn pages, hold a picture or shape for its menu), Draw, or Nothing.
- **Notebook mode**: Keep a notebook with as many pages (lined/grid/dotted/Cornell) as you want, or open any PDF and write on it; export to a paged PDF, where titled pages become bookmarks. A whole folder can be exported as one PDF too, subfolders included, bookmarked by folder, notebook and titled page. Pages can have titles and stars, their own paper, and be moved, inserted or duplicated; save a page as a template (a planner, a meeting sheet) and start new pages from it. The overview (one tap away in the bottom bar) shows a folder like a binder: its subfolders and notebooks as coloured tabs (a folder tab goes into it, the back arrow goes up), the pages of the chosen notebook, a starred-only filter, and moving or copying pages to any notebook in any folder.
- **Library**: every drawing and notebook is a file that saves itself as you go. Browse them by thumbnail, sort them into folders, rename, move, duplicate or delete them, all without a computer.
- **Theme color** (color screens): pick a color on the same wheel as the pen, and the buttons, selected tiles, switches and active tool take it instead of black. Text on them turns black or white, whichever reads better.
- Undo/redo, zoom & pan, and an optional grid.
- And more!

Toolbar: Pen, Eraser, Shapes, Text, Image, Pan, Undo/Redo, Settings, Library, File (rename, duplicate, export, new drawing, new notebook) and Exit. Zoom is the floating +/− control in the corner.


## Installation

Copy the whole `ink-away.koplugin` folder into KOReader's `plugins` directory:

- Kindle: `koreader/plugins/ink-away.koplugin/`
- Kobo: `.adds/koreader/plugins/ink-away.koplugin/`
- Android: `koreader/plugins/ink-away.koplugin/` in app storage

Then restart KOReader. Open from Top menu → **Tools** tab → "Ink Away (drawing canvas)" near the top. You can also map it to a gesture in KOReader's gesture manager; the actions are "Open Ink Away" and "Ink Away library". 


## Notes

- Palm rejection needs KOReader 2026.07+.
- Drawings and notebooks are kept in an "ink away" folder and saved automatically; exported PNGs and PDFs go to "ink away/exports" unless you pick another folder. Work from older versions' "drawing projects" and "notebook projects" folders moves into the "ink away" folder on the first start.
- Settings → "When Ink Away opens" picks what you see first: the last document, the library, or Notebooks (the notebook browser on your last notebook, for note-taking).
- On e-ink, black ink refreshes faster than greys/white and a white pen is invisible on the white canvas, exports are unaffected.

## License

MIT (see [`LICENSE`](LICENSE)). PNG/JPEG use KOReader's bundled lodepng and libjpeg-turbo.