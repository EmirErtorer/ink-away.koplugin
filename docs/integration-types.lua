---@meta
--[[
Type declarations for Ink Away's integration API (see docs/INTEGRATION.md), for
the Lua language server (LuaLS / sumneko). Never loaded and not shipped with the
plugin. The public part is what a viewer plugin implements or calls; the last
section names a few of Ink Away's own types its code refers to.

From Kristan Laimon's PR #80, trimmed to the API as merged.
]]

------------------------------------------------------------------------------
-- Public: what a viewer plugin implements and calls
------------------------------------------------------------------------------

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

--- Screen pixels are absolute; page units are the document page's own. A point
--- with no mapping gives nil. Zoom is positive; rotation is in radians, clockwise.
---@class InkCoordinateMap
---@field toPage fun(self: InkCoordinateMap, x: number, y: number): integer?, number?, number?, number?, number? page, x, y, zoom, rotation
---@field toScreen fun(self: InkCoordinateMap, page: integer, x: number, y: number): number?, number?, number?, number? x, y, zoom, rotation

--- What a viewer shows.
---@class InkViewer
---@field pages fun(self: InkViewer): integer[] The document pages visible, in display order.
---@field key fun(self: InkViewer): string Changes whenever where a page is on the screen changes.
---@field snapshot fun(self: InkViewer, bb: table) Paint the viewer into bb without Ink Away's ink (no paintDocumentSurface in it).
---@field repaint fun(self: InkViewer) Ask for the viewer to be painted again.
---@field readingDirection? fun(self: InkViewer): InkReadingDirection
---@field turn? fun(self: InkViewer, dir: integer, done: fun(surface: InkSurface?), frame: fun()?) Turn (1 forward, -1 back); call done once settled (with the next page's surface, if it changes), frame for each animation step.

--- A viewer's page as Ink Away draws on it.
---@class InkSurface: InkViewer, InkCoordinateMap
---@field version 1
---@field document table The open KOReader document itself.
---@field clip fun(self: InkSurface): InkRect? The page's part of the screen (no controls or margins).
---@field begin? fun(self: InkSurface) Annotation mode is opening on it (before the opened event).
---@field finish? fun(self: InkSurface) Annotation mode closed, its ink kept (before the closed event).
---@field setViewport? fun(self: InkSurface, rect: InkRect, change: fun(reflow: fun())): boolean? The room annotation mode leaves; call change(reflow) before moving the page, return true when it moved.
---@field mapPath? fun(self: InkSurface, points: number[], to_page: boolean, page: integer): number[] Map a path point by point (a folded spread).
---@field isAffine? fun(self: InkSurface): boolean False when one transform does not map the whole page.
---@field regions? fun(self: InkSurface): InkSurface[] The parts of the page, each with its own clip (the halves of a folded spread).

---@class InkAnnotationEvent
---@field document table
---@field surface InkSurface? nil for annotation mode on the reader's own page

---@class InkIntegrationOptions
---@field on_open? fun(event: InkAnnotationEvent)
---@field on_close? fun(event: InkAnnotationEvent)
---@field on_error? InkErrorHandler

--- Published as ui.inkAwayIntegrationAPI (or passed to consumer:configureInkAway).
---@class InkIntegrationAPI
---@field integration_api_version 1
---@field document_surface_version 1
---@field ui table
---@field installPluginIntegration fun(self: InkIntegrationAPI, widget: table, surface: InkSurface, options: InkIntegrationOptions?): fun(release_surface: boolean?)
---@field paintDocumentSurface fun(self: InkIntegrationAPI, surface: InkSurface, bb: table)
---@field releaseDocumentSurface fun(self: InkIntegrationAPI, surface: InkSurface)
---@field onAnnotationOpened fun(self: InkIntegrationAPI, callback: fun(event: InkAnnotationEvent)): InkUnsubscribe
---@field onAnnotationClosed fun(self: InkIntegrationAPI, callback: fun(event: InkAnnotationEvent)): InkUnsubscribe
---@field onInkAwayAnnotate fun(self: InkIntegrationAPI): boolean?

------------------------------------------------------------------------------
-- Internal: Ink Away's own types the integration code refers to (may change)
------------------------------------------------------------------------------

---@alias InkIntegrationHost InkIntegrationAPI

---@class InkRenderingProvider
---@field factory InkSurfaceFactory
---@field on_error InkErrorHandler?

---@class InkInstallation
---@field surface InkSurface
---@field closed boolean?
---@field cleanup fun(release_surface: boolean?)

---@class InkOperation
---@field kind string
---@field pts number[]?
---@field [string] unknown

---@class InkAnchoredItem
---@field op InkOperation
---@field a { page: integer?, x: number?, y: number?, [string]: unknown }

---@class InkPlacementDocument
---@field kind 'paging'|'rolling'
---@field [string] unknown
