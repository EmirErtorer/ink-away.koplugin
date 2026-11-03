# Plugin integration API

## Connection examples: YourPlugin

Choose the role you need. Both mock Lua files live beside this document and
handle registration **before or after Ink Away becomes ready**.

| Consumer role | Example | What it provides |
| --- | --- | --- |
| Event-only | [main-event-only.lua](main-event-only.lua) | Subscribes to annotation-open/close events, without a viewer or surface. |
| Rendering consumer | [main-rendering-consumer.lua](main-rendering-consumer.lua) | Injects a viewer/surface rendering dependency, with optional surface-scoped event callbacks. |

A plugin can be **both**. These roles are shown separately to make each guide
easy to follow. Event subscriptions do not require rendering registration.
The rendering example already includes callbacks for its own surface; add
independent subscriptions only if you also need reader-wide events.

These are nonfunctional **YourPlugin documentation mocks**, not installable
plugins or runtime modules. Their `init`, `configureInkAway` and cleanup methods are
illustrative consumer methods, not a required KOReader plugin signature or
additional Ink Away API methods.

### Event-only consumer

[main-event-only.lua](main-event-only.lua) takes only `ui`, the reader UI.
It uses the plugin instance as a stable queue key. If Ink Away is ready it
configures immediately; otherwise Ink Away calls the queued consumer’s `configureInkAway(ink)`
after initialization. Neither path needs a viewer, surface or renderer.

`configureInkAway` checks the event API version and subscribes with
`onAnnotationOpened()` and `onAnnotationClosed()`. These observe this reader's
sessions, including the native viewer, where `event.surface` is `nil`.
`dispose()` cancels its own pending request or unsubscribes both listeners.
It does not close the annotation session it observes.

### Rendering consumer

[main-rendering-consumer.lua](main-rendering-consumer.lua) takes `ui`,
`viewer_widget` and `surface`. The latter two are created by your plugin:
`viewer_widget` is its actual KOReader viewer object; `surface` is its
[annotation adapter](#surface-contract). They are required for rendering
injection, not for event-only consumers. The renderer is an empty mock;
see the [minimal surface example](#minimal-surface-example) for geometry.

Both loading orders lead to `installPluginIntegration()`, which registers the
rendering provider and optional callbacks scoped to this surface. The viewer
paints saved ink after its own background and can request annotation from its
own action. Before destroying the viewer, it cancels its pending request or
calls the returned cleanup, which releases the surface and removes registrations.

### Shared lifecycle rules

- Queue each consumer instance with a `true` entry. Disposal removes only
  that instance's request.
- Repeat the hookup for each new reader and dispose the old consumer's state.
- Event-only listeners receive future events; subscription does not replay an
  annotation session that is already open.
- A close event does not confirm a successful disk save.
- For rendering consumers, registration does not display the viewer: it must be
  on KOReader's window stack before Ink Away can select it for annotation.
- Rendering snapshots must exclude ink overlays to avoid recursive painting.
  Replacement viewers must also follow the [handoff rules](#surfaceturndirection-done-frame).

## API conventions

Calls are in-process Lua methods. This reference uses API-reference sections for
parameters, results and errors; there are no HTTP requests or status codes.

- Use `ui.inkAwayIntegrationAPI` for readiness. `ui["ink-away"]` is the normal
  directory key after KOReader registers the instance; it is not the bootstrap
  signal. `ui.inkaway` is a legacy alias some consumers use.
- Use colon calls: `ink:method(...)` and `surface:method(...)`.
- Call on KOReader's normal UI/event flow. This API does not introduce threads.
- The public extension API is the facade below. Book, editor, registry and
  adapter objects are private implementation; consumers do not access them.
- A method documented as returning `nil` has no success result. It must not be
  treated as returning an acknowledgement or proof of persistence.

### Version fields

| Field | Current value | Meaning |
| --- | --- | --- |
| `ink.integration_api_version` | `1` | Provider registration and lifecycle subscriptions. |
| `ink.document_surface_version` | `1` | External surface painting/release and the surface contract. |

These are interface versions, independent of the plugin release number. The
unmodified upstream 4.4.0 reference does not expose these interfaces. Check the
fields and the methods you need rather than assuming a metadata version is enough.
Existing consumers using surface discovery can coexist with registered providers.

### Reader UI handshake fields

| Field | Type | Meaning |
| --- | --- | --- |
| `ui.inkAwayIntegrationAPI` | Ink Away instance or `nil` | Ready instance, published after reader initialization; cleared at reader close. |
| `ui.inkAwayPendingIntegrations` | table or `nil` | Pending `consumer -> true` requests, shared by consumers before readiness. |

Queue an object with `ui.inkAwayPendingIntegrations[consumer] = true`.
The consumer must be a table exposing `consumer:configureInkAway(ink)`.
Ink Away supplies both the consumer as `self` and its ready instance as `ink`;
the method's return value is ignored. No callback wrapper is required.
A consumer can be a plugin instance or a viewer object with this method.
It does not need to be a UI widget. Do not overwrite another consumer's entry
or the whole table, and do not set the ready reference yourself.

The queue has no ordering guarantee. Ink Away removes each request before
calling the method and isolates failures. Cancelling an entry still works while
the queue is being drained. A failed method's newly created composite
installation is rolled back when the installation owner is the consumer itself;
other consumer side effects need their own cleanup. Entries other than `true`
or objects without the method are rejected and logged. Once ready, call
`consumer:configureInkAway(ready)` directly instead of queueing.

When your consumer is disposed before readiness, remove only its own entry, as in
[main-event-only.lua](main-event-only.lua). At reader close, readiness and pending requests are cleared;
installed providers/subscriptions are disposed. A closed instance rejects new
registrations. `nil` can mean not yet ready or already closed, so dispose your
consumer state rather than queueing new requests during reader teardown.

### Method index

| Method | Purpose | Returns |
| --- | --- | --- |
| [`installPluginIntegration`](#inkinstallpluginintegrationwidget-surface-options) | Install a provider and optional scoped listeners together. | `cleanup(release_surface)` function. |
| [`registerRenderingView`](#inkregisterrenderingviewwidget-factory-on_error) | Register a widget's surface factory. | `unregister()` function. |
| [`onAnnotationOpened`](#inkonannotationopenedcallback) | Observe a successfully opened annotation session. | `unsubscribe()` function. |
| [`onAnnotationClosed`](#inkonannotationclosedcallback) | Observe session cleanup. | `unsubscribe()` function. |
| [`paintDocumentSurface`](#inkpaintdocumentsurfacesurface-bb) | Draw saved ink over your background. | `nil`. |
| [`releaseDocumentSurface`](#inkreleasedocumentsurfacesurface) | Close annotation using your current surface. | `nil`. |
| [`onInkAwayAnnotate`](#inkoninkawayannotate) | Invoke the existing KOReader annotation action. | `true`; not a success indicator. |

## Registration and initialization order

1. Define `consumer:configureInkAway(ink)` on your consumer object.
2. If `ui.inkAwayIntegrationAPI` exists, configure immediately. Otherwise store
   `ui.inkAwayPendingIntegrations[consumer] = true`. Use the Ink Away
   instance passed to the method; its directory key may not exist yet.
3. Event-only consumers subscribe directly to the lifecycle events and retain
   the unsubscribe functions. No viewer or surface is required.
4. Rendering consumers create their viewer and surface before registering, call
   `installPluginIntegration(viewer_widget, surface, options)` and retain cleanup.
   Show the viewer normally; surface selection happens when annotation opens.
5. On consumer disposal, cancel its queued request or clean up its registrations.
   Only rendering consumers release their owned surface.

Low-level provider registration and event subscriptions remain available for
consumers that need factories or independent observers. They can be called before
initialization if the caller already has the instance; this is not necessary for
the handshake. Registering/unregistering never switches an active session's viewer.

## Public method reference

### `ink:installPluginIntegration(widget, surface, options)`

Install one widget's rendering provider and optional surface-scoped lifecycle
listeners together. Call from your `configureInkAway(ink)` method. The method uses
its own reader UI; do not pass `ui` again as an argument.

**Parameters**

| Name | Type | Required | Description |
| --- | --- | --- | --- |
| `widget` | table | Yes | The owning viewer widget. |
| `surface` | valid surface table | Yes | A version-1 surface for exactly this reader's document. |
| `options` | table | No | Optional callbacks below. |
| `options.on_open` | function | No | Receives the open event only when `event.surface` is this installed surface. |
| `options.on_close` | function | No | Receives the close event only when its final surface is this installed surface. |
| `options.on_error` | function | No | Provider error callback, as in `registerRenderingView`. |

**Returns**

An idempotent `cleanup(release_surface)` function. It returns `nil`. With no
argument, or any value other than `false`, cleanup attempts to release/save/close
this surface's active editor, then unregisters the provider and unsubscribes both
listeners. Close listeners remain connected during release. If release throws,
cleanup still removes registrations/listeners and reports the error.

`cleanup(false)` unregisters and unsubscribes without releasing the active
surface. Use this for an outgoing viewer during an intentional navigation
handoff, not for ordinary destruction. Calling cleanup again does not later
release a surface skipped by the first call; the landing owner must release it.
Pending queue cancellation is the consumer's responsibility, as shown in
[main-rendering-consumer.lua](main-rendering-consumer.lua).

**Behavior and edge cases**

- Installing again for the same widget and exact surface returns the **same
  cleanup function**. The first installation's callbacks remain in force; new
  options do not add or replace listeners.
- A different surface for an already-installed widget raises an assertion.
  Complete the old cleanup before installing a replacement.
- Do not combine a low-level registration and a composite installation for the
  same widget. Both own the same provider slot; duplicate ownership is rejected.
- Surface validation occurs immediately, before a provider/listener is added.
- Invalid types, optional callback types, wrong-document/invalid surfaces,
  installation during disposal, and installation on a closed reader raise
  synchronous assertions. No setup-success event is emitted.
- Installation does not show a widget or open annotation. Surface selection and
  provider errors during a later opening follow the low-level registration rules.
- Scoped listeners match exact surface identity. A navigation handoff to a new
  surface does not cause the outgoing installation to receive the final close
  event. Use independent instance-level subscriptions if you need all sessions.
- Reader closure disposes composite installations. Explicit widget cleanup is
  still required when a widget closes sooner.

**Example**

```lua
local cleanup = ink:installPluginIntegration(widget, surface, {
    on_open = function(event) logger.dbg("Opened", event.document) end,
    on_close = function(event) logger.dbg("Closed", event.document) end,
    on_error = function(err) logger.warn("Provider failure", err) end,
})
-- Before destroying the widget:
cleanup()
```

### `ink:registerRenderingView(widget, factory, on_error)`

Register one rendering provider for an owning widget. Ink Away evaluates its
factory when it selects a viewer for a new annotation session.

**Parameters**

| Name | Type | Required | Description |
| --- | --- | --- | --- |
| `widget` | table | Yes | Your actual viewer widget, present on KOReader's window stack when eligible. |
| `factory` | function | Yes | Called as `factory(widget, context)`; returns a surface or `nil`. |
| `on_error` | function | No | Called as `on_error(err)` for reported provider failures. |

Factory input:

```lua
context = {
    document = ui.document, -- the actual currently open document object
}
```

Factory output: a [surface](#surface-contract) whose `document` is that same
object, or `nil` to decline. Matching filenames are insufficient: object identity
must match. Keep returned geometry current throughout the session.

**Returns**

An `unregister()` function. It accepts no arguments, returns `nil`, and is safe
to call repeatedly. It removes this registration only; it does not close an
active editor or remove event subscriptions.

**Selection rules and edge cases**

- Widgets are examined from the top of the current window stack downward.
- A registered factory takes precedence over that widget's legacy
  `getAnnotationSurface()` method. Returning `nil` does not call that legacy
  method on the same widget.
- The first valid returned surface is selected. A declining widget allows the
  search to continue unless it blocks the search as described below.
- A fullscreen widget blocks the search below it when `covers_fullscreen` is
  true and neither `toast` nor `invisible` is true. Its own provider is checked
  before that blocking rule.
- Registrations for widgets outside the stack are not considered. If a widget
  stays in the stack while logically hidden, its factory should decline.
- Different widgets may register independently. A second registration for the
  **same widget** raises an assertion; unregister first before replacing it.
- Factory exceptions or an invalid returned surface stop selection and use the
  native reader. A failed selected provider is not replaced by a lower provider.
- Unregister does not disable legacy discovery. If the widget still exposes
  `getAnnotationSurface()`, it may remain discoverable until removed or disabled
  by that consumer.
- A registration belongs to this Ink Away instance. Create a new hookup for a
  new reader/document lifecycle and release the old one.

**Errors**

Wrong argument types and duplicate registration raise synchronous Lua assertions.
They are caller errors and do not call `on_error`. Factory/contract failures are
reported to `on_error`, if supplied. The error value is not guaranteed to be a
string; use `tostring(err)` for display. See [error handling](#error-handling).

**Example**

```lua
local unregister = ink:registerRenderingView(widget, function(_, context)
    if context.document ~= surface.document then return nil end
    return surface
end, function(err)
    logger.warn("Viewer provider:", tostring(err))
end)

-- Later, before destroying the widget:
ink:releaseDocumentSurface(surface)
unregister()
```

### `ink:onAnnotationOpened(callback)`

Subscribe to successful annotation-session opening for this reader, including
sessions using the native KOReader viewer.

**Parameters**

| Name | Type | Required | Description |
| --- | --- | --- | --- |
| `callback` | function | Yes | Receives one [event payload](#event-payload). Its return value is ignored. |

**Returns**

An idempotent `unsubscribe()` function with no parameters or result.

**Behavior and edge cases**

- Fires once after the annotation editor has been created and shown.
- Repeating an open request while that editor is shown does not emit another
  event. Navigation and toolbar reflow do not open a new session.
- If the editor cannot be created/shown, or annotation cannot open, no open
  event is emitted. A request alone is not a session.
- There is no replay: subscribing after opening observes future openings only.
- This event observes an opening; returning `false` does not cancel it.
- Non-function callbacks raise a synchronous assertion. Listener exceptions are
  logged and do not prevent the other listeners from running.

**Example**

```lua
local unsubscribe = ink:onAnnotationOpened(function(event)
    if event.surface then
        logger.dbg("External-viewer annotation opened")
    else
        logger.dbg("Native-reader annotation opened")
    end
end)
```

### `ink:onAnnotationClosed(callback)`

Subscribe to cleanup of an annotation session that successfully opened.

**Parameters**

| Name | Type | Required | Description |
| --- | --- | --- | --- |
| `callback` | function | Yes | Receives one [event payload](#event-payload). Its return value is ignored. |

**Returns**

An idempotent `unsubscribe()` function with no parameters or result.

**Behavior and edge cases**

- Fires once after the normal save/cleanup path has been attempted and the
  selected surface's `finish()` has been attempted, if supplied.
- A close event is **not proof of a successful disk write**.
- The payload contains the final surface after any navigation handoffs. It may
  differ from the surface in the opening event.
- Constructor/show failures do not invent a close event for a session that never
  opened. Repeated cleanup does not produce repeated close notifications.
- Native-reader sessions use `surface = nil`.
- There is no replay or cancellation. Wrong callback types assert; callback
  exceptions are logged and isolated.

**Example**

```lua
local unsubscribe = ink:onAnnotationClosed(function(event)
    if event.document == ui.document then
        logger.dbg("Annotation session closed")
    end
end)
```

### Event payload

Both lifecycle methods pass a table with these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `document` | document object | The actual reader document for this session. |
| `surface` | surface table or `nil` | The consumer-owned surface, or `nil` for the native reader. |

Callbacks run synchronously in registration order. Each receives a separate
payload table; document and surface references are shared objects, not copies.
No editor, canvas, storage model or registry object is included.

Unsubscribing takes effect immediately, including during notification. Listeners
added during notification wait until the next event. Keep callbacks brief and
unsubscribe when disposing of your plugin's reader/viewer state.

### `ink:paintDocumentSurface(surface, bb)`

Paint saved Ink Away annotations over your viewer's already-painted background.
Call it in the reading paint path, after painting the content.

**Parameters**

| Name | Type | Required | Description |
| --- | --- | --- | --- |
| `surface` | valid surface table | Yes | Describes the document/view currently being painted. |
| `bb` | KOReader blitbuffer | Yes | Screen-sized destination; surface geometry uses absolute screen coordinates. |

**Returns**

`nil`. The destination is painted in place; no result object is allocated for the
consumer. Ink Away does not free your destination buffer.

**Behavior and edge cases**

- Does nothing when Ink Away has no book, the document object does not match,
  there is no saved ink, or the reading-ink visibility preference is disabled.
- Uses `regions()` when provided, otherwise the surface itself. Output is clipped
  to the content rectangles. Missing or empty clips draw no ink for that region.
- Does not open annotation or change the active session's selected surface.
- Ink Away suppresses its surface ink paint while capturing a background
  snapshot. Your `snapshot()` should paint the background without calling this
  method; this avoids a recursive background/annotation paint loop.
- Caught painting failures are logged/reported, with no success/failure return.
  Some drawing may already have happened. Supply valid objects: this method is
  not an argument-validation endpoint for arbitrary values such as `nil`.

**Example**

```lua
-- Inside your screen-coordinate paint path:
paintBackgroundWithoutInk(bb) -- your own drawing function
ink:paintDocumentSurface(surface, bb)
```

### `ink:releaseDocumentSurface(surface)`

Save/close an active annotation editor using this exact surface before its
owning viewer or surface resources are destroyed.

**Parameters**

| Name | Type | Required | Description |
| --- | --- | --- | --- |
| `surface` | valid external surface table | Yes | The exact surface object being released. Do not pass `nil`. |

**Returns**

`nil`. It does not return a persistence acknowledgement.

**Behavior and edge cases**

- Acts only when the active surface is the same Lua object. Equal fields on a
  different table do not match. An unrelated or previously released surface
  does not close the current session.
- Uses Ink Away's normal close/save path and clears that surface selection.
  This path also closes book notes if open.
- Does not unregister your widget or unsubscribe your listeners. Do those
  separately after release.
- During navigation, keep the surface being handed to `done(surface)` alive.
  Disposing of the outgoing widget must not close the session being transferred.
  After handoff, release the final active surface when its viewer closes.
- Provider `finish()` must tolerate the owning viewer already being closed.

**Example**

```lua
-- For a manually managed low-level registration:
ink:releaseDocumentSurface(surface)
unregister()
stop_open()
stop_close()
-- Now dispose of the widget's rendering resources.
```

### `ink:onInkAwayAnnotate()`

Invoke Ink Away's existing KOReader annotation action. This is the same entry
point used by its configured action/gesture; provider registration is separate.

**Parameters:** none.

**Returns:** `true`, including when no book is open. This is an action-handled
result, not confirmation that an editor opened. Observe `onAnnotationOpened`
when you need notification of a successful opening.

**Edge cases:** no book means no editor; a currently shown editor is not opened
twice; read-only annotation data or editor initialization errors can prevent
opening. The factory is evaluated as part of a new opening, not during
registration.

```lua
ink:onInkAwayAnnotate()
```

## Surface contract

Consumers implement these methods; Ink Away calls them. This is the other side
of the public integration contract, not a list of methods on the Ink Away instance.

### Object fields and shared types

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `version` | number | Yes | Exactly `1`. |
| `document` | document object | Yes | Exactly the current `ui.document` object. |

| Type | Shape / units |
| --- | --- |
| `Rect` | `{ x = number, y = number, w = number, h = number }`, in absolute screen pixels. |
| `Page` | Native, 1-based document page number, not a panel index. |
| `Points` | Flat number array `{x1, y1, x2, y2, ...}`. |
| `zoom` | Positive scale from native document units to screen pixels. |
| `angle` | Document-to-screen rotation in radians, clockwise under the surface contract. |

External surfaces support fixed-page documents. Native Ink Away keeps its
existing word-anchor behavior for reflowing documents. A valid factory result
must contain all required functions. Any optional method supplied must also be a
function. Registration validates these fields and method types, not every return
value or the mathematical correctness of the implementation.

### Required method index

| Method | Accepts | Returns |
| --- | --- | --- |
| `pages()` | Nothing. | Array of visible native pages. |
| `key()` | Nothing. | Layout identity string. |
| `toPage(x, y)` | Screen point. | `page, px, py, zoom, angle`, or `nil`. |
| `toScreen(page, px, py)` | Native page point. | `x, y, zoom, angle`, or `nil`. |
| `snapshot(bb)` | Screen-sized destination. | No value used. |
| `repaint()` | Nothing. | No value used. |
| `clip()` | Nothing. | `Rect`, or `nil` when unavailable. |

### `surface:pages()`

**Accepts:** no arguments. **Returns:** an array of currently visible native
page numbers, for example `{7}` or `{7, 8}`. The first entry is the current page.
Return actual document pages even when your viewer displays one panel or a
combined spread. Keep it consistent with both coordinate mappings.

### `surface:key()`

**Accepts:** no arguments. **Returns:** a string that changes whenever page,
crop, zoom, pan, rotation or layout changes alter annotation placement.

Ink Away uses it to invalidate placement caches. Reusing a key after a geometry
change can leave saved ink in the wrong position. Include the geometry values
that affect your mappings; an unchanged layout should have a stable key.

### `surface:toPage(x, y)`

| Input | Type | Meaning |
| --- | --- | --- |
| `x`, `y` | numbers | Absolute screen coordinates. |

**Returns:** `page, px, py, zoom, angle` as multiple Lua values, or `nil` when
no mapping exists. `px` and `py` are native document coordinates. Keep `zoom`
positive and provide the correct rotation.

Extend mappings beyond the content clip: a stroke's bounding-box origin can
sit just outside the viewport while part of the stroke remains visible.
Clipping belongs to `clip()`, not to rejecting every off-viewport point.

```lua
local page, px, py, zoom, angle = surface:toPage(120, 240)
if page then
    -- px/py identify the original document point.
end
```

### `surface:toScreen(page, px, py)`

| Input | Type | Meaning |
| --- | --- | --- |
| `page` | Page | Original document page. |
| `px`, `py` | numbers | Native document coordinates. |

**Returns:** `x, y, zoom, angle`, or `nil` for a page that the surface does not
map. It must agree with `toPage()` and extend beyond the clip. Both directions
must report the same document-to-screen scale/rotation convention.

```lua
local x, y, zoom, angle = surface:toScreen(7, 100, 200)
```

### `surface:snapshot(bb)`

**Accepts:** the screen-sized KOReader blitbuffer to paint. **Returns:** ignored.

Paint your current background in screen coordinates without Ink Away ink. Do
not retain or free the supplied buffer. Paint newly created content widgets
before their screen bounds are needed by `clip()`. Snapshot can be called during
opening, reflow or every animation frame; it must reflect the current geometry.

### `surface:repaint()`

**Accepts:** no arguments. **Returns:** ignored.

Request repainting of your viewer after annotations change, typically using
KOReader's dirty-region mechanism. Make it safe after your viewer closes.
It should schedule/invalidate painting rather than recursively paint immediately.

### `surface:clip()`

**Accepts:** no arguments. **Returns:** a content `Rect`, excluding controls and
letterboxing, or `nil` when no clip is available. An empty rectangle paints no
reading ink. Keep it inside the screen and consistent with the snapshot.

Ink Away intersects this area with toolbar-free editing space. Widget bounds
may exist only after painting: when replacing content widgets, initialize them
through the snapshot before returning a clip based on those bounds.

### Minimal surface example

This example is a single, unrotated fixed-page view with uniform scale. Your
renderer supplies `paint_background(bb)` and `request_repaint()` functions.
`rect` is the actual displayed page rectangle in screen coordinates; `zoom`
relates its size to native page units. The whole displayed page rectangle fits
on screen; this is not a cropped/folded-view example.

```lua
local function makeSurface(document, page, rect, zoom,
        paint_background, request_repaint)
    assert(zoom > 0)
    local surface = { version = 1, document = document }

    function surface:pages()
        return { page }
    end
    function surface:key()
        return table.concat({page, rect.x, rect.y, rect.w, rect.h, zoom}, ":")
    end
    function surface:toPage(x, y)
        return page, (x - rect.x) / zoom, (y - rect.y) / zoom, zoom, 0
    end
    function surface:toScreen(p, px, py)
        if p ~= page then return nil end
        return rect.x + px * zoom, rect.y + py * zoom, zoom, 0
    end
    function surface:snapshot(bb)
        paint_background(bb) -- background only; no Ink Away overlay
    end
    function surface:repaint()
        request_repaint()
    end
    function surface:clip()
        return { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end

    return surface
end
```

Pass the result as `surface` in the rendering-consumer example. This surface has no `turn()` method:
annotation navigation stays on it. To support page changes, implement the
navigation contract below; do not silently change native page identity while
pending edits still use the old geometry.

## Optional surface methods

| Method | Default when omitted |
| --- | --- |
| `begin()` / `finish()` | No consumer-specific acquisition/cleanup. |
| `turn(direction, done, frame)` | Stay on the same external surface; completion is immediate. |
| `setViewport(rect, refresh)` | Existing overlay layout; no automatic consumer refit. |
| `readingDirection()` | Native reader's inverse-reading-order setting. |
| `mapPath(points, to_page, page)` | Affine placement only. |
| `isAffine()` | No non-affine primitive-outline conversion. |
| `regions()` | Paint through the original surface and its clip. |

### `surface:begin()` / `surface:finish()`

**Accept:** no arguments. **Return:** ignored.

Use `begin()` to acquire annotation-specific presentation/resources. Ink Away
calls it before constructing the editor, and again after navigation handoff,
including when the same surface is returned. Make repeated acquisition safe.

Use `finish()` to restore normal viewer layout and release annotation resources,
including any retained viewport refresh callback. It is attempted on closure and
after failed initial activation/construction. It must remain safe if the owning
widget has already closed. Navigation does not automatically call `finish()` on
every outgoing surface: arrange resource ownership correctly for your handoff.

```lua
function surface:begin()
    -- Apply your annotation-specific presentation, if not already active.
end
function surface:finish()
    self.refresh_layout = nil
    -- Restore normal presentation; tolerate an already-disposed viewer.
end
```

### `surface:turn(direction, done, frame)`

| Input | Type | Meaning |
| --- | --- | --- |
| `direction` | number | `1` means logical forward; `-1` means logical backward. |
| `done` | function | Call `done(landing_surface)` once navigation is complete. |
| `frame` | function or absent | Call after updating animation geometry to request a live editor repaint. |

**Returns:** ignored. Completion is communicated by `done`, not a return value.

Ink Away saves/anchors the old edits before navigation. While waiting, the
editor blocks further editing/turns and paints live background/ink snapshots.
At completion it adopts the landing surface, calls its `begin()` when supplied,
and reloads editable operations. Local editing history is replaced as on a
page load; saved native annotations remain preserved.

**Handoff rules**

- Call `done(surface)` exactly once, including at a navigation boundary where
  no movement is possible. Never leaving a turn pending keeps editing blocked.
- Return the same surface for an in-place change, or a new valid surface for a
  replacement viewer. The landing surface must belong to the same document.
- Keep the current surface's mappings, snapshot and reading regions usable
  during movement. `frame(surface)` requests repaint; it does not itself replace
  the selected surface. Replacement happens through `done(landing_surface)`.
- Finish any reflow/widget creation needed for the landing snapshot. Ink Away
  snapshots before querying newly painted widget clips.
- A wrong-document/invalid handoff is reported and the previous surface retained.
  Passing `nil` selects the native adapter; use this only for an intentional
  transfer back to the native reader, not to mean "no movement".
- Late/duplicate completion callbacks cannot reactivate a closed/replaced editor.
- The drawing editor remains modal over the consumer during an external session.
  Do not release/dispose the surface being transferred to its completion.

```lua
function surface:turn(direction, done, frame)
    -- navigate is your renderer's function. It calls on_complete even at an edge.
    navigate(direction, function()
        if frame then frame(self) end
    end, function(landing_surface)
        done(landing_surface or self)
    end)
end
```

### `surface:setViewport(rect, refresh)`

| Input | Type | Meaning |
| --- | --- | --- |
| `rect` | Rect | Screen space left by the toolbar, before intersection with your content clip. |
| `refresh` | function | Later call `refresh(reflow)` for a consumer-initiated layout change. |

**Returns:** `true` when your content widgets changed and need a snapshot before
clip lookup; otherwise `false` or `nil`.

Called on open, toolbar placement/size/visibility changes and navigation. Reports
may repeat an unchanged rectangle; avoid rebuilding unnecessarily. A page handoff
can replace the widget without changing the rectangle: Ink Away still snapshots
the replacement before reading its bounds.

Ink Away anchors edits before editor-driven layout changes, then snapshots and
reloads. For your own preference change, call the supplied `refresh` with a
**synchronous** `reflow()` function: Ink Away saves against old geometry, runs
that function, then snapshots/reloads in the new geometry. Do not change the
mapping first and ask it to save afterward.

Store the latest refresh callback for later use rather than invoking it from
inside `setViewport()`. Release it and restore your normal viewport in `finish()`.
Late refresh calls after the editor closes are ignored, but consumers should
still release their references.

```lua
function surface:setViewport(rect, refresh)
    self.refresh_layout = refresh
    return fitContentInto(rect) -- your renderer returns true if widgets changed
end

-- Later, while the session is active:
if surface.refresh_layout then
    surface.refresh_layout(function()
        applyViewerPreference() -- your synchronous reflow implementation
    end)
end
```

### `surface:readingDirection()`

**Accepts:** no arguments. **Returns:** `"ltr"` or `"rtl"`.

Controls physical arrow direction and unbound navigation swipes. Logical
next/previous actions keep their forward/backward meanings. If omitted, Ink Away
uses the native reader's inverse-reading-order setting.

```lua
function surface:readingDirection() return "rtl" end
```

### `surface:mapPath(points, to_page, page)`

| Input | Type | Meaning |
| --- | --- | --- |
| `points` | Points | Input path in the source coordinate system. |
| `to_page` | boolean | `true`: screen to native page; `false`: native page to screen. |
| `page` | Page | Native page associated with the operation. |

**Returns:** a mapped flat `Points` array. Insert vertices at layout
discontinuities, such as a removed strip, so paths stay attached to both sides.
Keep the input path unchanged. This method handles path strokes; paired with
`isAffine() == false`, it also maps primitive outlines into polygons.

### `surface:isAffine()`

**Accepts:** no arguments. **Returns:** `false` when one affine mapping cannot
represent your geometry, otherwise `true`.

When `mapPath()` is supplied, `false` requests primitive-outline mapping through
that method. It does not warp text, pictures or pixel fills across a discontinuity.
For a normal uniform zoom/rotation view, omit both methods.

### `surface:regions()`

**Accepts:** no arguments. **Returns:** an array of retained affine sub-surfaces
used to paint reading ink. Each describes its own native pages, key, clip and
point mappings. Without this method, Ink Away paints through the original surface.

Use separate regions when a view joins discontinuous portions of a document.
Text, pictures and fills are placed through each affine region and clipped to it.
Keep clips disjoint where double-compositing translucent ink would be wrong.
Returning an empty array draws no reading ink. This does not change the editable
canvas's local-affine limitation for non-path objects.

## Error handling

There is no structured error response object. `on_error(err)` receives the
reported Lua error value; the API currently supplies no error code or phase field.

| Situation | Result |
| --- | --- |
| Invalid installation/registration/listener argument or conflicting widget owner | Synchronous assertion; caller may use `pcall`. |
| Pending `configureInkAway` method throws | Log; continue other consumers; roll back a new composite install owned by that consumer. |
| Factory throws or returns invalid surface | Log/report; choose the native reader for this opening. |
| Initial `begin()` throws | Log/report; attempt provider cleanup, then use the native reader. |
| Editor construction/show fails | Log/report; attempt cleanup; no successful-session events. |
| Invalid navigation handoff | Report; keep previous surface. |
| Caught navigation/snapshot/ink-paint failure | Log/report; existing recovery applies, with no automatic mid-session switch. |
| Active surface `finish()` throws | Log/report; close notification still proceeds through normal cleanup. |
| Lifecycle listener throws | Log; continue other listeners. It is not sent to a provider's `on_error`. |
| `on_error` itself throws | Log; do not call it recursively. |

For example, invalid contract validation reports
`"invalid annotation surface or different document"`; invalid handoff reports
`"invalid annotation surface handoff"`. Treat them as diagnostic text rather than
stable machine-readable codes.

Do not assume every error from arbitrary consumer code is intercepted. In
particular, code running later in your own timer/animation callback is outside
the original protected call. Handle asynchronous errors in your consumer and
ensure the navigation completion/cleanup contract is fulfilled.

## Compatibility, persistence and practical limits

- Legacy `widget:getAnnotationSurface()` discovery remains supported for
  version-1 consumers without registration. It has no provider error callback.
- The readiness handshake uses only the current reader UI, a per-consumer method queue
  and the ready instance. It neither loads another plugin's code nor changes
  KOReader's plugin loading order.
- Registration, provider callbacks and subscriptions require no runtime method
  replacement. Keep your implementation inside your plugin.
- Saved ink uses unchanged native document coordinates and sidecar schema.
  Viewer-specific page positions, zoom values or metadata are not persisted.
  Untouched annotations retain their existing item identities.
- Export renders original document pages independently of viewer crop/zoom.
- Paths and primitive outlines can cross discontinuities. Text boxes, pictures
  and pixel-run fills in the editable canvas use a local affine transform;
  offer an original/affine view for editing objects across removed regions.
  `regions()` improves reading overlays, not non-path editing geometry.
- Navigation and reflow reload the editable canvas's local history while keeping
  saved annotations. Do not advertise history continuity across those reloads.

For responsibilities and the public/private boundary, see
[Arquitecture.md](Arquitecture.md).
