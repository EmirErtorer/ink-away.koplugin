# Ink Away integration API (experimental)

A KOReader plugin that shows a book's pages its own way (PanelsPlus, for comics read panel by panel) can let Ink Away's annotation mode draw on its view. The viewer tells Ink Away where the page is on the screen. Ink Away keeps its tools, saving and syncing, and stores the ink exactly as if it had been drawn in KOReader's own view. The ink shows in both and syncs like any other.

**Experimental:** this may change before Ink Away 5.0. Check the version numbers, and do nothing if they are not the ones you know.

Designed by Kristan Laimon (PR #80). The type declarations for the Lua language server are in [`integration-types.lua`](integration-types.lua), and there are two example consumers in [`examples/`](examples/).

## What the reader sees

- The viewer gets an "annotate" action (or the reader uses Ink Away's own gesture or menu). Annotation mode opens **over the viewer**, on the page it shows, with Ink Away's toolbar. The drawing area is the page's part of the screen; the viewer's controls and margins stay out of it.
- Page turns in annotation mode ask the viewer to turn (it may animate). Drawing waits until it is done. On a right-to-left page (manga), the toolbar's left arrow goes forward.
- Closing annotation mode keeps the ink, and the viewer paints it in its own view from then on.
- On a viewer's page, the highlighter draws see-through ink. KOReader's own highlights are drawn by KOReader's view, and the eraser does not reach them there.

## Getting the API

When a book opens and Ink Away is ready, it publishes `ui.inkAwayIntegrationAPI`, a small table with only the public functions:

| Member | |
|---|---|
| `integration_api_version` | `1` |
| `document_surface_version` | `1` |
| `ui` | the reader it belongs to |
| `installPluginIntegration(widget, surface, options)` | connect your widget's surface; returns `cleanup(release_surface)` |
| `paintDocumentSurface(surface, bb)` | paint the book's ink on your page, in your own `paintTo` |
| `releaseDocumentSurface(surface)` | your surface is going: annotation mode on it closes, its ink kept |
| `onAnnotationOpened(cb)` / `onAnnotationClosed(cb)` | events, `{ document, surface }` (`surface` is nil on KOReader's own page); return an unsubscribe |
| `onInkAwayAnnotate()` | open annotation mode (on the topmost connected viewer, else on KOReader's page) |

If your plugin starts before Ink Away is ready, queue yourself instead. Ink Away calls `configureInkAway(api)` on each queued consumer once it publishes:

```lua
if ui.inkAwayIntegrationAPI then
    self:configureInkAway(ui.inkAwayIntegrationAPI)
else
    ui.inkAwayPendingIntegrations = ui.inkAwayPendingIntegrations or {}
    ui.inkAwayPendingIntegrations[self] = true   -- don't replace other plugins' entries
end
```

There is one way to connect, `installPluginIntegration`. When the book closes, the API is withdrawn: `ui.inkAwayIntegrationAPI` becomes nil, and the old table refuses new installations.

## Connecting

```lua
function MyViewer:configureInkAway(ink)
    if ink.integration_api_version ~= 1 or ink.document_surface_version ~= 1 then return end
    self.ink = ink
    self.ink_cleanup = ink:installPluginIntegration(self, self.surface, {
        on_open = function(event) --[[ hide your controls ]] end,
        on_close = function(event) --[[ show them again ]] end,
        on_error = function(err) --[[ a call to your surface failed; Ink Away logged it ]] end,
    })
end

function MyViewer:paintTo(bb, x, y)
    self:paintPage(bb, x, y)
    if self.ink and self.ui.inkAwayIntegrationAPI == self.ink then
        self.ink:paintDocumentSurface(self.surface, bb)
    end
end

function MyViewer:onCloseWidget()
    if self.ink_cleanup then self.ink_cleanup() end   -- before your widget or surface goes
end
```

- `widget` is your viewer's widget, the one in KOReader's window stack. When annotation mode opens, Ink Away takes the topmost connected widget that is shown (anything else covering the whole screen above it hides it).
- One surface per widget. Installing again with the same surface returns the same cleanup.
- `cleanup()` closes annotation mode if it is on your surface (keeping the ink), and unsubscribes your callbacks. `cleanup(false)` only unsubscribes.

## The surface

A table with `version = 1`, `document = ui.document` (the open document itself) and these methods. Screen coordinates are absolute pixels; page coordinates are the document page's own units.

| Method | Required | What it does |
|---|---|---|
| `pages()` | yes | The document pages shown, in display order. |
| `key()` | yes | A string that changes whenever where a page is on the screen changes. Ink Away caches the placed ink by it, so make it exact and cheap. |
| `toPage(x, y)` | yes | Screen point → `page, x, y, zoom, rotation` (zoom = screen pixels per page unit; rotation in radians, clockwise), or nil. |
| `toScreen(page, x, y)` | yes | Page point → `x, y, zoom, rotation`, or nil when that page is not shown. |
| `clip()` | yes | The page's part of the screen, `{ x, y, w, h }` (no controls or margins). Ink is drawn and painted only there. |
| `snapshot(bb)` | yes | Paint your view into `bb` **without** the ink (don't call `paintDocumentSurface` in it). Annotation mode shows this under the canvas. |
| `repaint()` | yes | Ask for your view to be painted again. |
| `begin()` / `finish()` | no | Annotation mode opens / has closed on it (hide and show your controls here). |
| `turn(dir, done, frame)` | no | Turn (1 forward, -1 back). Call `done(next_surface)` once settled (`next_surface` when the page's surface changes, else nothing), and `frame()` for each animation step. Without it, page turns stay on the page. |
| `readingDirection()` | no | `"ltr"` or `"rtl"`. |
| `setViewport(rect, change)` | no | The room annotation mode leaves beside its toolbar. Before you move or resize the page, call `change(reflow)`: Ink Away keeps what is in hand, then calls `reflow()`, where you move it. Return true when it moved. |
| `regions()` | no | The parts of the page, each a surface of its own with its own `clip` (the halves of a two-page spread with the gutter removed). |
| `mapPath(points, to_page, page)`, `isAffine()` | no | For a page one transform cannot map (a spread with the gutter removed): map a path point by point; `isAffine()` false. A shape that crosses the fold is kept as a polygon. |

## Rules Ink Away keeps

- **Nothing changes for anyone not using a viewer.** KOReader's own page works exactly as before: the same refreshes, pen, keys and exports.
- **Your failures stay yours.** Every call to your surface is guarded. A failure is logged and passed to your `on_error`; annotation mode falls back to KOReader's page, or closes, keeping the ink.
- **No copies of the screen.** Painting on your page draws only the ink, and only inside each clip.
- **Same ink format.** Ink is kept per page, in page units, like any fixed-page book's. A book annotated on your view opens with its ink in KOReader's view, on another reader and in exports.

## Known limits

- KOReader's highlights aren't drawn on a viewer's page (KOReader's view draws them), and the eraser and the highlight colour sheet don't reach them there.
- Reflowing books (EPUB and so on) aren't supported: a surface maps fixed pages.
- While your page animates, annotation mode shows its picture and takes no input.
