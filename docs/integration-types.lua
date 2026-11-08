---@meta
-- LuaLS contracts for the integration PR. No runtime code or consumer adapters.
-- Host-owned objects stay opaque; these declarations describe Ink Away's boundary.

---@alias InkAnnotationEventName 'opened'|'closed'
---@alias InkReadingDirection 'ltr'|'rtl'
---@alias InkUnsubscribe fun()
---@alias InkSurfaceFactory fun(widget: table, context: { document: table }): InkSurface?
---@alias InkErrorHandler fun(err: unknown)

---@class InkRect
---@field x number
---@field y number
---@field w number
---@field h number

--- Screen-space pixels are absolute. Document-space units are original page units.
--- Missing mappings return nil. Zoom is positive; rotation is clockwise radians.
---@class InkCoordinateMap
---@field toPage fun(self: InkCoordinateMap, x: number, y: number): integer?, number?, number?, number?, number?
---@field toScreen fun(self: InkCoordinateMap, page: integer, x: number, y: number): number?, number?, number?, number?

--- The viewer methods Book uses for both KOReader's built-in viewer and an
--- external viewer. This is the shared display-facing part of the interface;
--- it does not describe how screen coordinates map to document coordinates.
---@class InkViewer
---@field pages fun(self: InkViewer): integer[] Visible native document pages, in display order.
---@field key fun(self: InkViewer): string Identity for the current page geometry and layout; changes when either changes.
---@field snapshot fun(self: InkViewer, bb: table) Paint the viewer background into bb, without Ink Away's annotation UI or overlay.
---@field repaint fun(self: InkViewer) Request a repaint of the viewer.
---@field readingDirection? fun(self: InkViewer): InkReadingDirection Return the document's reading direction when known.
---@field turn? fun(self: InkViewer, dir: integer, done: fun(surface: InkSurface?), frame: fun()?) Navigate and call done once the resulting layout is settled; frame may provide animation frames.

--- Full interface for an external viewer that wants Ink Away to render and save
--- annotations on it. It includes InkViewer's display methods, then adds the
--- coordinate mapping and other surface capabilities Ink Away needs for ink.
--- Implement the viewer's geometry and lifecycle; Ink Away handles its own
--- annotation drawing and storage.
---@class InkSurface: InkViewer, InkCoordinateMap
---@field version 1
---@field document table Exact open KOReader document identity.
---@field clip fun(self: InkSurface): InkRect? Content bounds excluding controls/letterboxing.
---@field begin? fun(self: InkSurface) Acquire annotation mode before opened event.
---@field finish? fun(self: InkSurface) Release after editor saves, before closed event.
---@field setViewport? fun(self: InkSurface, rect: InkRect, change: fun(reflow: fun())): boolean? Call change before replacing active geometry.
---@field mapPath? fun(self: InkSurface, points: number[], to_page: boolean, page: integer): number[] Map paths across folds.
---@field isAffine? fun(self: InkSurface): boolean False when one transform cannot map the whole view.
---@field regions? fun(self: InkSurface): InkSurface[] Separate clipped regions of the same document.

---@class InkAnnotationEvent
---@field document table Open KOReader document.
---@field surface InkSurface? Nil for native reader annotation sessions.

---@class InkIntegrationOptions
---@field on_open? fun(event: InkAnnotationEvent)
---@field on_close? fun(event: InkAnnotationEvent)
---@field on_error? InkErrorHandler

---@class InkRenderingProvider
---@field factory InkSurfaceFactory
---@field on_error InkErrorHandler?

---@class InkInstallation
---@field surface InkSurface
---@field closed boolean?
---@field cleanup fun(release_surface: boolean?) False disconnects without releasing an already-closing session.

--- Existing drawing schema: optional fields depend on kind; extensible by tools.
---@class InkOperation
---@field kind string
---@field pts number[]?
---@field shape string?
---@field angle number?
---@field closed boolean?
---@field width number?
---@field x number?
---@field y number?
---@field [string] unknown

---@class InkAnchor
---@field page integer?
---@field x number?
---@field y number?
---@field xp0 string?
---@field xp1 string?
---@field pxp string?
---@field dx number?
---@field dy number?
---@field dyb number?
---@field ml number?
---@field mr number?
---@field seg integer?

---@class InkAnchoredItem
---@field op InkOperation
---@field a InkAnchor

---@class InkWord
---@field xp0 string
---@field xp1 string
---@field box InkRect
---@field seg integer?

--- Ink Away's placement contract, kept internal to avoid consumer-side ink logic.
---@class InkPlacementDocument
---@field kind 'paging'|'rolling'
---@field toPage? fun(self: InkPlacementDocument, x: number, y: number): integer?, number?, number?, number?, number?
---@field toScreen? fun(self: InkPlacementDocument, page: integer, x: number, y: number): number?, number?, number?, number?
---@field anchorOp? fun(self: InkPlacementDocument, op: InkOperation): InkAnchoredItem?
---@field placeOp? fun(self: InkPlacementDocument, item: InkAnchoredItem): InkOperation?
---@field width? fun(self: InkPlacementDocument): number
---@field wordAt? fun(self: InkPlacementDocument, x: number, y: number): InkWord?
---@field nearestWord? fun(self: InkPlacementDocument, x: number, y: number): InkWord?
---@field partOf? fun(self: InkPlacementDocument, word: InkWord, x: number, y: number): InkWord?
---@field boxOf? fun(self: InkPlacementDocument, xp0: string, xp1: string, seg: integer?): InkRect?
---@field pageTop? fun(self: InkPlacementDocument): string
---@field pageOf? fun(self: InkPlacementDocument, xp: string): integer?

---@class InkIntegrationHost
---@field ui table
---@field releaseDocumentSurface fun(self: InkIntegrationHost, surface: InkSurface)

---@class InkExportOptions
---@field scope 'page'|'all'|'ink'|'range'
---@field fmt 'pdf'|'png'
---@field pdf_type 'editable'|'pictures'
---@field transparent boolean?
---@field on_paper string?
---@field ruled boolean?
---@field name string?
---@field dir string?
---@field range? { from: number?, to: number? }
---@field page_quality? 'compact'|'detailed'
---@field include_bg boolean?
---@field numbers boolean?
---@field [string] unknown

---@class InkExportSpec
---@field n integer
---@field quality integer?
---@field numbers boolean?
---@field template table|fun(i: integer): table
---@field w number?
---@field h number?
---@field size? fun(i: integer): integer, integer Per-page raster dimensions instead of w/h.
---@field box? fun(i: integer): number, number Physical PDF page dimensions.
---@field pages InkOperation[][]|fun(i: integer): InkOperation[]
---@field bg? fun(i: integer, scale: number?): unknown RGBA buffer.
---@field bg_opaque boolean?
---@field done? fun() Release source document even on cancellation/failure.
---@field prepare? fun(i: integer)

--- Public facade supplied to consumer:configureInkAway(ink).
---@class InkIntegrationAPI: InkIntegrationHost
---@field integration_api_version 1
---@field document_surface_version 1
---@field installPluginIntegration fun(self: InkIntegrationAPI, widget: table, surface: InkSurface, options: InkIntegrationOptions?): fun(release_surface: boolean?)
---@field registerRenderingView fun(self: InkIntegrationAPI, widget: table, factory: InkSurfaceFactory, on_error: InkErrorHandler?): InkUnsubscribe
---@field onAnnotationOpened fun(self: InkIntegrationAPI, callback: fun(event: InkAnnotationEvent)): InkUnsubscribe
---@field onAnnotationClosed fun(self: InkIntegrationAPI, callback: fun(event: InkAnnotationEvent)): InkUnsubscribe
---@field paintDocumentSurface fun(self: InkIntegrationAPI, surface: InkSurface, bb: table)
---@field onInkAwayAnnotate fun(self: InkIntegrationAPI): boolean?

---@class InkTextPromptOptions
---@field title string
---@field input string?
---@field hint string?
---@field description string?
---@field lines integer?
---@field on_ok fun(text: string?, on: boolean)
---@field on_cancel? fun()
---@field default string?
---@field field string?
---@field input_type string?
---@field text_type string?
---@field ok_text string?
---@field extra? { text: string, callback: fun(text: string) }
---@field toggle? { label: string, is_on: boolean? }
---@field [string] unknown
