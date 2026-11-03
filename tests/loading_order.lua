-- Real Ink Away init, public facade, registry and editor. Host menus, shelf and
-- pen attachment are fixtures; no plugin-loader or physical-device claim.
local root = arg[1] or "."
package.path = root .. "/?.lua;./?.lua;./tests/mock/?.lua;" .. package.path
local UI = require("ui/uimanager")
local BB = require("ffi/blitbuffer")
local env = require("testenv")
local BookInk = require("ink/reader/bookink")
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["ink/bookshelf"] = { register = function() return true end }
package.loaded["ink/drawingshelf"] = { register = function() return true end }
package.loaded["ink/reader/penhighlight"] = { new = function()
    return { attach = function() end, detach = function() end }
end }
BookInk.installFollow = function() end -- host filesystem follow hooks are outside this test
G_reader_settings = {
    data = env.settings({ inkaway_gestures_setup = 2 }),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local Ink = require("main")
Ink._autoopened = true
local checks = 0
local function check(c, message) checks = checks + 1; assert(c, message) end
local serial = 0
local function reader()
    UI.reset()
    serial = serial + 1
    local ui = { document = { file = env.libraryDir() .. "/load-" .. serial .. ".cbz" },
        paging = {}, active_widgets = {}, menu = { registerToMainMenu = function() end },
        view = { state = { page = 1, zoom = 1, offset = { x = 0, y = 0 } },
            visible_area = { x = 0, y = 0 }, registerViewModule = function() end,
            paintTo = function(_, bb) bb:fill(BB.COLOR_WHITE) end,
            screenToPageTransform = function(_, p) return { page = 1, x = p.x, y = p.y } end },
    }
    function ui:handleEvent() end
    return ui
end
local function surface(ui)
    local s = { version = 1, document = ui.document }
    function s:pages() return { 7 } end
    function s:key() return "7" end
    function s:toPage(x, y) return 7, x, y, 1, 0 end
    function s:toScreen(page, x, y) if page == 7 then return x, y, 1, 0 end end
    function s:clip() return { x = 0, y = 0, w = 600, h = 800 } end
    function s:snapshot(bb) bb:fill(BB.COLOR_WHITE) end
    function s:repaint() end
    function s:finish() self.finished = (self.finished or 0) + 1 end
    return s
end
local function boot(ui)
    -- Exactly as ReaderUI does: initialization precedes directory-key assignment.
    local ink = Ink:new({ ui = ui })
    ui["ink-away"] = ink
    ink.book._data = BookInk.new()
    return ink
end
local function request(ui, widget, configure)
    function widget:configureInkAway(ink)
        -- Verify Ink Away supplies the consumer as self in the deferred path too.
        assert(self == widget, "configureInkAway lost its consumer instance")
        configure(ink)
    end
    if ui.inkAwayIntegrationAPI then widget:configureInkAway(ui.inkAwayIntegrationAPI)
    else
        ui.inkAwayPendingIntegrations = ui.inkAwayPendingIntegrations or {}
        ui.inkAwayPendingIntegrations[widget] = true
    end
end
for _, order in ipairs({ "consumer-first", "ink-first" }) do
    local ui, widget = reader(), {}
    local s, cleanup, opened, closed = surface(ui), nil, 0, 0
    local ink
    if order == "ink-first" then ink = boot(ui) end
    local function configure(api)
        check(ui.inkAwayIntegrationAPI == api, order .. ": ready instance passed directly")
        check(api.book ~= nil, order .. ": default reader exists before publication")
        if order == "consumer-first" and not ink then
            check(ui["ink-away"] == nil, "deferred configure does not depend on directory-key publication")
        end
        cleanup = api:installPluginIntegration(widget, s, {
            on_open = function(event) check(event.surface == s, "open scoped to installed surface"); opened = opened + 1 end,
            on_close = function(event) check(event.surface == s, "close scoped to installed surface"); closed = closed + 1 end,
        })
    end
    request(ui, widget, configure)
    if not ink then
        check(cleanup == nil, "consumer queues without importing Ink Away")
        ink = boot(ui)
    end
    check(type(cleanup) == "function", order .. ": hookup completed")
    check(ui.inkAwayPendingIntegrations == nil, order .. ": queue drained")
    local original_cleanup = cleanup
    request(ui, widget, configure)
    check(cleanup == original_cleanup, "repeat configuration reuses cleanup and original subscriptions")
    UI._window_stack = { { widget = widget } } -- no legacy discovery method
    ink:onInkAwayAnnotate()
    check(ink.book.surface == s and opened == 1, "installed provider selected once")
    cleanup(); cleanup()
    check(ink.book._view == nil and ink.book.surface == nil and closed == 1, "composite cleanup releases once")
    check(ink.book.extensions:select(ui) == nil, "composite cleanup unregisters")
    ink:onCloseDocument()
    check(ui.inkAwayIntegrationAPI == nil, "reader closure clears ready instance")
    check(not pcall(ink.installPluginIntegration, ink, widget, s), "closed instance rejects new installation")
end

-- Event-only consumers have a method, but no viewer, surface or provider.
for _, consumer_first in ipairs({ true, false }) do
    local ui, consumer = reader(), { opened = 0, closed = 0 }
    local ink
    function consumer:configureInkAway(api)
        check(self == consumer and api == ui.inkAwayIntegrationAPI, "event-only method receives self and ready instance")
        self.stop_open = api:onAnnotationOpened(function(event)
            check(event.document == ui.document and event.surface == nil, "event-only receives native session payload")
            self.opened = self.opened + 1
        end)
        self.stop_close = api:onAnnotationClosed(function() self.closed = self.closed + 1 end)
    end
    if not consumer_first then ink = boot(ui) end
    if ui.inkAwayIntegrationAPI then consumer:configureInkAway(ui.inkAwayIntegrationAPI)
    else ui.inkAwayPendingIntegrations = { [consumer] = true } end
    if not ink then ink = boot(ui) end
    check(next(ink.book.extensions._providers) == nil, "event-only configuration registers no rendering provider")
    ink.book.extensions:emit("opened", ui.document, nil)
    ink.book.extensions:emit("closed", ui.document, nil)
    check(consumer.opened == 1 and consumer.closed == 1, "event-only observes lifecycle with either loading order")
    consumer.stop_open(); consumer.stop_close()
    ink.book.extensions:emit("closed", ui.document, nil)
    check(consumer.closed == 1, "event-only disposal unsubscribes")
    ink:onCloseDocument()
end

-- Multiple consumers, cancellation and failure isolation (including rollback).
do
    local ui = reader()
    local a, b, cancelled, broken, partial = {}, {}, {}, {}, {}
    local sa, sb = surface(ui), surface(ui)
    local calls = 0
    request(ui, a, function(ink) calls = calls + 1; ink:installPluginIntegration(a, sa) end)
    request(ui, b, function(ink) calls = calls + 1; ink:installPluginIntegration(b, sb) end)
    request(ui, cancelled, function() error("cancelled request ran") end)
    ui.inkAwayPendingIntegrations[cancelled] = nil
    request(ui, broken, function() error("broken consumer") end)
    request(ui, partial, function(ink)
        ink:installPluginIntegration(partial, surface(ui))
        error("consumer failed after installation")
    end)
    local ink = boot(ui)
    check(calls == 2 and ui.inkAwayPendingIntegrations == nil, "multiple consumers survive another consumer's failure")
    for _, pair in ipairs({ {a,sa}, {b,sb} }) do
        UI._window_stack = { {widget = pair[1]} }
        check(ink.book.extensions:select(ui) == pair[2], "independent providers remain registered")
    end
    for _, owner in ipairs({cancelled,broken,partial}) do
        UI._window_stack = {{widget = owner}}
        check(ink.book.extensions:select(ui) == nil, "cancelled/failed configuration has no provider")
    end
    ink:onCloseDocument()
    check(next(ink.book.extensions._installations) == nil, "reader closure removes installed consumer state")
end

-- Cancellation stays effective while the queue is being drained.
do
    local ui, a, b, calls = reader(), {}, {}, 0
    local function cancel_other()
        calls = calls + 1
        ui.inkAwayPendingIntegrations[a] = nil
        ui.inkAwayPendingIntegrations[b] = nil
    end
    request(ui, a, cancel_other); request(ui, b, cancel_other)
    local ink = boot(ui)
    check(calls == 1, "queue cancellation during drain suppresses the other callback")
    ink:onCloseDocument()
end

-- A shutdown from one configure callback prevents remaining callbacks running.
do
    local ui, a, b, calls = reader(), {}, {}, 0
    local function close_reader(ink) calls = calls + 1; ink:onCloseDocument() end
    request(ui, a, close_reader); request(ui, b, close_reader)
    boot(ui)
    check(calls == 1 and ui.inkAwayIntegrationAPI == nil, "shutdown stops the pending drain")
end

-- Readiness is not published when initialization fails before completion.
do
    local ui, widget, calls = reader(), {}, 0
    request(ui, widget, function() calls = calls + 1 end)
    ui.view.registerViewModule = function() error("default viewer registration failed") end
    check(not pcall(boot, ui), "initialization failure is observable")
    check(ui.inkAwayIntegrationAPI == nil and calls == 0, "failed init does not publish readiness or drain consumers")
    ui.view.registerViewModule = function() end
    local ink = boot(ui)
    check(calls == 1, "successful initialization later drains the retained request")
    ink:onCloseDocument()
end

-- Idempotence, mismatched replacement, callback removal and handoff cleanup.
do
    local ui, widget = reader(), {}
    local ink = boot(ui)
    local s, other = surface(ui), surface(ui)
    check(not pcall(ink.installPluginIntegration, ink, widget, s, false), "invalid options fail before registration")
    local closed = 0
    local cleanup = ink:installPluginIntegration(widget, s, { on_close = function() closed = closed + 1 end })
    check(not pcall(ink.installPluginIntegration, ink, widget, other), "different surface requires disposing the old install")
    UI._window_stack = {{widget = widget}}
    ink:onInkAwayAnnotate()
    cleanup(false)
    check(ink.book.surface == s and ink.book._view ~= nil, "unregister-only cleanup preserves a handoff session")
    ink:releaseDocumentSurface(s)
    check(closed == 0, "cleanup removed the scoped observer")
    local second = ink:installPluginIntegration(widget, s)
    check(second ~= cleanup, "disposed owner can be installed again")
    second(); ink:onCloseDocument()
end

env.cleanup()
print(("loading_order: %d checks, 0 failures"):format(checks))
