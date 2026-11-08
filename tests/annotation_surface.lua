-- Generic external viewer with the real annotation canvas and gesture handlers.
-- Run with: luajit tests/annotation_surface.lua
-- (from Kristan Laimon's PR #80, registered as a viewer plugin does)
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Book = require("ink/reader/book")
local BookInk = require("ink/reader/bookink")
local env = require("testenv")
G_reader_settings = {
    data = env.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
Device.screen:setSize(600, 800)
local checks = 0
local function check(condition, message)
    checks = checks + 1
    assert(condition, message)
end
local surface = { version = 1, document = { file = env.libraryDir() .. "/surface.cbz" }, finished = false }
function surface:pages() return {7} end
function surface:key() return "surface-7-" .. (self.offset or 0) end
function surface:toPage(x, y) return 7, 100 + (x + (self.offset or 0)) / 2, 200 + y / 2, 2, 0 end
function surface:toScreen(page, x, y)
    if page == 7 then return (x - 100) * 2 - (self.offset or 0), (y - 200) * 2, 2, 0 end
end
function surface:snapshot(bb) self.snapshots = (self.snapshots or 0) + 1; bb:fill(BB.COLOR_WHITE) end
function surface:repaint() end
function surface:clip() return {x = 0, y = 0, w = 600, h = 800} end
function surface:finish() self.finished = true end
local ui = { document = surface.document, paging = {}, view = {
    state = { page = 1, zoom = 1, offset = {x = 0, y = 0} }, visible_area = {x = 0, y = 0},
} }
local book = Book.new(ui, require("ink/integration").new())
book._data = BookInk.new()
book.sidecar, book.dirs = env.libraryDir(), {env.libraryDir()}
local viewer_widget = {}
book.integration:registerRenderingView(viewer_widget, function() return surface end)
UIManager._window_stack = { { widget = viewer_widget } }
book:annotate()
local view = book._view
check(view ~= nil and book.surface == surface, "annotation action adopts the generic surface")
check(view.modal == true, "the active drawing canvas stays above its external viewer")
local function pos(x, y) return {pos = {x = x, y = y}} end
local x, y = view.view.area_x + 40, 350
view:onIaTouch(nil, pos(x, y))
for i = 1, 6 do view:onIaPan(nil, pos(x + i * 12, y + i)) end
view:onIaPanRelease(nil, pos(x + 72, y + 6))
view:flushPending()
check(#view.canvas.ops == 1, "the real canvas accepts a stroke")
check(#book:data().items == 1, "the stroke is anchored in the real book model")
local item = book:data().items[1]
check(item.a.page == 7, "the stroke belongs to the external page, not reader page 1")
check(math.abs(item.a.x + item.op.pts[1] - (100 + x / 2)) < 1e-6, "stroke x uses document coordinates")
check(math.abs(item.a.y + item.op.pts[2] - (200 + y / 2)) < 1e-6, "stroke y uses document coordinates")
view:saveDocument()
check(BookInk.exists(book.sidecar), "annotations save through the existing sidecar format")
function surface:readingDirection() return self.flow or "ltr" end
function surface:turn(dir, done, frame)
    self.turns = (self.turns or 0) + 1
    self.last_turn, self.pending = dir, {done = done, frame = frame}
end
local function arrow(id)
    for _, button in ipairs(view._toolbar_icons) do
        if button.id == id then return button.button.callback end
    end
    error("missing arrow " .. id)
end
for _, direction in ipairs({"ltr", "rtl"}) do
    surface.flow = direction
    for _, id in ipairs({"prev", "next"}) do
        arrow(id)()
        local wanted = id == "prev" and -1 or 1
        if direction == "rtl" then wanted = -wanted end
        check(surface.last_turn == wanted, "physical toolbar arrow follows " .. direction)
        check(view._surface_navigating == true, "the canvas waits for asynchronous handoff")
        local turns, rev, snapshots = surface.turns, view.canvas.rev, surface.snapshots
        arrow(id)()
        check(surface.turns == turns, "repeated turns are blocked during navigation")
        check(not view:inArea(x, y), "raw input cannot draw against a moving layout")
        check(view:handleEvent({handler = "onGesture"}) == true, "gesture editing is blocked while moving")
        view:onIaTouch(nil, pos(x, y))
        check(view.canvas.rev == rev, "a moving surface does not change editable ink")
        G_reader_settings:saveSetting("inkaway_book_ink", false)
        for frame = 1, 3 do
            surface.offset = frame * 10
            surface.pending.frame(surface)
            local target = BB.new(600, 800, BB.TYPE_BB8)
            view:paintTo(target, 0, 0)
            target:free()
        end
        check(surface.snapshots == snapshots + 3, "the real canvas paints every live surface frame")
        check(view.canvas.rev == rev, "animation painting preserves editable operations")
        surface.pending.done(surface)
        check(view._surface_navigating == nil and book.surface == surface, "editing resumes at handoff")
        G_reader_settings:saveSetting("inkaway_book_ink", true)
    end
end
view:runAction("next_page")
check(surface.last_turn == 1, "semantic next remains forward in RTL")
surface.pending.done(surface)
view:runAction("prev_page")
check(surface.last_turn == -1, "semantic previous remains backward in RTL")
surface.pending.done(surface)
view:turnPage(1)
local late_done = surface.pending.done
view:closeCanvas()
late_done(surface)
check(book.surface == nil and book._view == nil and surface.finished, "closing releases the surface")
check(UIManager.stackCount() == 1, "the external viewer stays open")
local overlay = BB.new(600, 800, BB.TYPE_BB8)
book:paintSurface(surface, overlay)
check(not overlay.freed and book.surface == nil, "the real ink painter renders without retaining the surface")
overlay:free()
print(("annotation_surface: %d checks, 0 failures"):format(checks))
