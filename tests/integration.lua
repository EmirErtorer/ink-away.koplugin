-- Public extension contracts with the real Book/editor; host widgets are fixtures.
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Integration = require("ink/integration")
local UIManager = require("ui/uimanager")
local Book = require("ink/reader/book")
local BookInk = require("ink/reader/bookink")
local env = require("testenv")
local checks = 0
local function check(c, message) checks = checks + 1; assert(c, message) end
G_reader_settings = {
    data = env.settings(),
    readSetting = function(self, key) return self.data[key] end,
    saveSetting = function(self, key, value) self.data[key] = value end,
}
local document = { file = env.libraryDir() .. "/integration.cbz" }
local ui = { document = document, paging = {}, view = {
    state = { page = 1, zoom = 1, offset = { x = 0, y = 0 } },
    visible_area = { x = 0, y = 0 }, paintTo = function() end,
} }
function ui.view:screenToPageTransform(p) return { page = 1, x = p.x, y = p.y } end
function ui:handleEvent(event) self.last_event = event end
local function surface()
    local s = { version = 1, document = document }
    function s:pages() return { 7 } end
    function s:key() return "7" end
    function s:toPage(x, y) return 7, x, y, 1, 0 end
    function s:toScreen(page, x, y) if page == 7 then return x, y, 1, 0 end end
    function s:clip() return { x = 0, y = 0, w = 600, h = 800 } end
    function s:snapshot() end
    function s:repaint() end
    function s:begin() self.begins = (self.begins or 0) + 1 end
    function s:finish() self.finishes = (self.finishes or 0) + 1 end
    return s
end
local api, a, b = Integration.new(), {}, {}
local sa, sb = surface(), surface()
local errors = 0
local remove_a = api:registerRenderingView(a, function(owner, context)
    check(owner == a and context.document == document, "factory gets public context")
    return sa
end, function() errors = errors + 1 end)
local remove_b = api:registerRenderingView(b, function() return sb end)
UIManager._window_stack = { { widget = a }, { widget = b } }
check(api:select(ui) == sb, "top visible provider wins")
UIManager._window_stack[3] = { widget = { covers_fullscreen = true } }
check(api:select(ui) == nil, "unrelated fullscreen widget blocks providers below it")
UIManager._window_stack[3] = nil
check(not pcall(api.registerRenderingView, api, a, function() return sb end), "duplicate owner is rejected")
remove_b(); remove_b()
check(api:select(ui) == sa, "unregister is idempotent and exposes the remaining provider")
local copy = surface()
check(api:handoff(sa, copy, document) == copy, "navigation adopts a valid replacement")
api:report(copy, "failure after handoff")
check(errors == 1, "replacement retains the provider error callback")
copy.document = {}
check(api:handoff(sa, copy, document) == sa and errors == 2, "wrong-document handoff retains current mapping")
remove_a()
check(api:select(ui) == nil, "unregister removes selection")
local bad = api:registerRenderingView(a, function() error("broken factory") end, function() errors = errors + 1 end)
check(api:select(ui) == nil and errors == 3, "factory failure reports and falls back")
bad()
bad = api:registerRenderingView(a, function() return { version = 1 } end, function() errors = errors + 1 end)
check(api:select(ui) == nil and errors == 4, "invalid contract reports and falls back")
bad()
-- Listener mutation and failures must not prevent other observers.
local called, unsubscribe_second = {}, nil
local off_first = api:onAnnotationOpened(function(payload)
    called[#called + 1] = 1
    payload.document = nil
    unsubscribe_second()
    error("listener failure")
end)
unsubscribe_second = api:onAnnotationOpened(function() called[#called + 1] = 2 end)
local off_third = api:onAnnotationOpened(function(payload)
    called[#called + 1] = 3
    check(payload.document == document, "listeners receive separate payloads")
end)
api:emit("opened", document, nil)
check(#called == 2 and called[1] == 1 and called[2] == 3, "unsubscribe and listener failure are isolated")
off_first(); off_third()

-- Disposal inside a callback must cancel the rest of the same dispatch snapshot.
local disposing = Integration.new()
local delivered = false
local disposed_owner = {}
disposing:registerRenderingView(disposed_owner, function() return sa end)
disposing:onAnnotationOpened(function() disposing:dispose() end)
local stop_disposed = disposing:onAnnotationOpened(function() delivered = true end)
disposing:emit("opened", document, sa)
stop_disposed(); disposing:dispose()
check(not delivered and disposing:select(ui) == nil, "dispose disconnects events and providers during dispatch")
check(not pcall(disposing.onAnnotationOpened, disposing, function() end), "disposed registry rejects new observers")

-- Public facade can be used before plugin init or after Book creation.
package.loaded["dispatcher"] = {} -- registration/UI dispatch is outside this contract test
local Ink = require("main")
local ink = setmetatable({ ui = ui }, { __index = Ink })
local opened, closed = {}, {}
local off_open = ink:onAnnotationOpened(function(payload) opened[#opened + 1] = payload end)
local off_close = ink:onAnnotationClosed(function(payload) closed[#closed + 1] = payload end)
local book = Book.new(ui, ink:_integrationAPI())
ink.book = book
book._data = BookInk.new()
book.sidecar, book.dirs = env.libraryDir(), { env.libraryDir() }
UIManager._window_stack = {}
book:annotate()
check(book._view ~= nil and #opened == 1 and opened[1].surface == nil, "pre-init native listener survives initialization")
book:annotate()
check(#opened == 1, "repeated open does not notify twice")
book._view:closeCanvas()
book:finishAnnotation()
check(#closed == 1 and closed[1].document == document, "native close notifies exactly once")
local external = surface()
local widget = {} -- intentionally has no getAnnotationSurface discovery method
local release = ink:registerRenderingView(widget, function() return external end)
UIManager._window_stack = { { widget = widget } }
book:annotate()
local editor = book._view
check(book.surface == external and #opened == 2, "explicit provider works without discovery")
check(external.begins == 1 and opened[2].surface == external, "open occurs after provider activation")
release()
check(book.surface == external, "unregister does not replace an active session")
local late, frames
function external:turn(_, done, frame) late, frames = done, frame end
editor:turnPage(1)
check(editor._surface_navigating, "external navigation waits for callback")
editor:closeCanvas()
check(external.finishes == 1 and #closed == 2, "external cleanup and close event occur once")
late(external)
frames(external)
check(book.surface == nil and book._view == nil and #opened == 2, "late callbacks cannot reopen a closed session")
-- Failed activation falls back to native and reports once.
local broken = surface()
function broken:begin() error("cannot acquire") end
local activation_errors = 0
local unreg = ink:registerRenderingView(widget, function() return broken end, function() activation_errors = activation_errors + 1 end)
book:annotate()
check(book._view ~= nil and book.surface == nil and activation_errors == 1, "activation failure uses default viewer")
check(broken.finishes == 1 and #opened == 3 and opened[3].surface == nil, "failed provider releases before native open")
book._view:closeCanvas()
unreg(); off_open(); off_close()
book:annotate(); book._view:closeCanvas()
check(#opened == 3 and #closed == 3, "public unsubscription removes observers")
-- A delayed close notification from the old editor cannot release a new one.
local register_again = ink:registerRenderingView(widget, function() return external end)
UIManager._window_stack = { { widget = widget } }
book:annotate()
local current = book._view
pcall(editor.onCloseWidget, editor)
check(book._view == current and book.surface == external, "an old editor cannot close the current session")
current:closeCanvas()
register_again()

-- Failed editor construction/show must clean up without emitting a session.
local construction_errors = 0
local healthy = surface()
local unregister_healthy = ink:registerRenderingView(widget, function() return healthy end, function() construction_errors = construction_errors + 1 end)
UIManager._window_stack = { { widget = widget } }
local real_editor = package.loaded["ink/reader/inkview"]
package.loaded["ink/reader/inkview"] = { new = function() error("constructor failed") end }
book:annotate()
check(book._view == nil and book.surface == nil and healthy.finishes == 1, "constructor failure releases the provider")
check(construction_errors == 1 and #opened == 3 and #closed == 3, "constructor error reports without lifecycle notifications")
package.loaded["ink/reader/inkview"] = real_editor
local real_show = UIManager.show
UIManager.show = function() error("cannot show") end
book:annotate()
UIManager.show = real_show
check(book._view == nil and book.surface == nil and healthy.finishes == 2, "show failure releases resources once")
check(construction_errors == 2 and #opened == 3 and #closed == 3, "show error does not invent a session")
unregister_healthy()
env.cleanup()
print(("integration: %d checks, 0 failures"):format(checks))
