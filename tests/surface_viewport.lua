-- Generic provider reflows to the space offered by the editor. Tests the real
-- book/canvas/toolbar lifecycle; host rendering, widgets and persistence are fixtures.
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
local function check(c, message) checks = checks + 1; assert(c, message) end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local surface = { version = 1, document = { file = env.libraryDir() .. "/viewport.cbz" }, ready = true }
function surface:pages() return { 1 } end
function surface:key()
    local r = self.viewport or { x = 0, y = 0, w = 600, h = 800 }
    return table.concat({ r.x, r.y, r.w, r.h, tostring(self.full) }, ":")
end
function surface:geom()
    local r = not self.full and self.viewport or nil
    r = r or { x = 0, y = 0, w = 600, h = 800 }
    local z = math.min(r.w / 600, r.h / 800)
    return r.x + (r.w - 600 * z) / 2, r.y + (r.h - 800 * z) / 2, z
end
function surface:toPage(x, y)
    local ox, oy, z = self:geom()
    return 1, (x - ox) / z, (y - oy) / z, z, 0
end
function surface:toScreen(page, x, y)
    if page ~= 1 then return nil end
    local ox, oy, z = self:geom()
    return ox + x * z, oy + y * z, z, 0
end
function surface:snapshot(bb) self.ready = true; bb:fill(BB.COLOR_WHITE) end
function surface:clip()
    assert(self.ready, "a newly reflowed widget must be painted before reading its clip")
    local x, y, z = self:geom()
    return { x = x, y = y, w = 600 * z, h = 800 * z }
end
function surface:setViewport(r, refresh)
    self.refresh = refresh
    local old = self.viewport
    if old and r.x == old.x and r.y == old.y and r.w == old.w and r.h == old.h then return false end
    self.viewport = r
    self.ready = false
    return true
end
function surface:finish() self.viewport, self.refresh = nil, nil end
function surface:repaint() end
local ui = { document = surface.document, paging = {}, view = {
    state = { page = 1, zoom = 1, offset = { x = 0, y = 0 } }, visible_area = { x = 0, y = 0 },
} }
local book = Book.new(ui, require("ink/integration").new())
book._data = BookInk.new()
local original = { a = { page = 1, x = 100, y = 200 }, op = { kind = "ink", width = 4, pts = { 0, 0, 20, 30 } } }
book._data.items = { original }
book.sidecar, book.dirs = env.libraryDir(), { env.libraryDir() }
local viewer_widget = {}
book.integration:registerRenderingView(viewer_widget, function() return surface end)
UIManager._window_stack = { { widget = viewer_widget } }
book:annotate()
local view = assert(book._view)
local function aligned()
    local x, y, z = surface:toScreen(1, 100, 200)
    local op = view.canvas.ops[1]
    check(near(op.pts[1], x) and near(op.pts[2], y) and near(op.width, 4 * z), "editable ink follows the new viewport")
    check(book:data().items[1] == original and original.a.x == 100 and original.a.y == 200,
        "untouched native annotations retain their item and coordinates")
    check(not view._surface_layout_changed and surface.ready, "reflow is snapshotted and committed before editing")
end
aligned()
-- A panel handoff replaces the widget without changing toolbar dimensions.
-- The provider deliberately rejects clip access until its new snapshot paints.
local offered = surface.viewport
surface.ready = false
view:loadBookPage()
aligned()
check(surface.viewport == offered, "a replaced widget is primed even when the offered viewport is unchanged")
check(surface.viewport.x > 0 and surface.viewport.w < 600, "default left toolbar reports the remaining screen")
for _, side in ipairs({ "right", "top", "bottom", "left" }) do
    view:setToolbarSide(side)
    local r = surface.viewport
    check((side == "left" and r.x > 0) or (side == "right" and r.x == 0 and r.w < 600)
        or (side == "top" and r.y > 0) or (side == "bottom" and r.y == 0 and r.h < 800),
        "provider receives toolbar-free space for " .. side)
    aligned()
end
local function pos(x, y) return { pos = { x = x, y = y } } end
local sx, sy = surface:toScreen(1, 300, 400)
view:onIaTouch(nil, pos(sx, sy))
for i = 1, 6 do view:onIaPan(nil, pos(sx + i * 3, sy + i)) end
view:onIaPanRelease(nil, pos(sx + 18, sy + 6))
view:flushPending()
check(#book:data().items == 2, "a new stroke is anchored before reflow")
local drawn = book:data().items[2]
check(near(drawn.a.x + drawn.op.pts[1], 300) and near(drawn.a.y + drawn.op.pts[2], 400), "new stroke uses native coordinates")
view:setToolbarHidden(true)
check(surface.viewport.x == 0 and surface.viewport.y == 0 and surface.viewport.w == 600 and surface.viewport.h == 800,
    "collapsing the toolbar restores the full screen")
aligned()
view:setToolbarHidden(false)
aligned()
check(book:data().items[2] == drawn and near(drawn.a.x + drawn.op.pts[1], 300), "toolbar changes do not relocate the saved stroke")
surface.refresh(function() surface.full = true; surface.ready = false end)
aligned()
check(near(view.canvas.ops[1].pts[1], 100) and near(view.canvas.ops[1].pts[2], 200), "provider preference can restore full-size mapping")
surface.refresh(function() surface.full = false; surface.ready = false end)
aligned()
local late_refresh = surface.refresh
view:closeCanvas()
local late_reflow = false
late_refresh(function() late_reflow = true end)
check(not late_reflow, "a late viewport refresh cannot touch a closed editor")
check(surface.viewport == nil and surface.refresh == nil, "closing releases viewport and layout callback")
env.cleanup()
print(("surface_viewport: %d checks, 0 failures"):format(checks))
