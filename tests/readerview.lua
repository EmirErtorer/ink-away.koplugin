-- The annotation mode (ink/reader/inkview.lua) headless, against a stand-in
-- book: its layout beside the book toolbar, loading and saving a page's ink
-- (unchanged ink keeps its anchor), hiding the toolbar, the smart highlighter
-- and its undo, both erasers, its sheets, and nothing painted out of bounds.
--   luajit tests/readerview.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local BB = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

_G.G_reader_settings = {
    data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function pos(x, y) return { pos = { x = x, y = y } } end

-- Is `text` anywhere in a widget tree?
local function hasText(w, text)
    local seen = {}
    local function walk(t)
        if type(t) ~= "table" or seen[t] then return false end
        seen[t] = true
        if t.text == text or t.label == text then return true end
        for k, v in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" and walk(v) then return true end
        end
        return false
    end
    return walk(w)
end

-- A stand-in book: one page with two strokes, recording what it is asked.
local function standInBook()
    local s1 = { kind = "ink", style = "solid", width = 4, alpha = 255, color = { 0, 0, 0 }, pts = { 200, 200, 400, 200 } }
    local s2 = { kind = "ink", style = "solid", width = 4, alpha = 255, color = { 0, 0, 0 }, pts = { 200, 300, 400, 300 } }
    local items = { { id = "i1" }, { id = "i2" } }
    local book = { saved = 0, highlights = {}, removed = 0, restored = 0, last = nil }
    function book:snapshot(bb) bb:fill(BB.COLOR_WHITE) end
    function book:pageOps() return { ops = { s1, s2 }, items = items } end
    function book:setPageOps(ops, came_from, shown)
        self.last = { ops = ops, came_from = came_from, shown = shown }
        local map, keep = {}, {}
        for _, op in ipairs(ops) do
            local it = came_from and came_from[op] or { id = "new" }
            map[op] = it; keep[#keep + 1] = it
        end
        return map, keep
    end
    function book:save() self.saved = self.saved + 1 end
    function book:turn() end
    function book:repaint() self.repainted = true end
    function book:highlight(op) local it = { hl = #self.highlights + 1 }; self.highlights[#self.highlights + 1] = it; return it end
    function book:removeHighlight() self.removed = self.removed + 1; return true end
    function book:restoreHighlight(it) self.restored = self.restored + 1; return it end
    return book, s1, s2, items
end

for _, wh in ipairs({ { 1072, 1448 }, { 600, 800 }, { 800, 600 } }) do
    local W, H = wh[1], wh[2]
    Screen:setSize(W, H)
    BB.out_of_bounds = 0
    UIManager.reset()
    package.loaded["ink/view"] = nil
    package.loaded["ink/reader/inkview"] = nil
    local ReaderInkView = require("ink/reader/inkview")
    local book, s1, s2, items = standInBook()
    local view = ReaderInkView:new{ book = book }
    local v = view.view
    local tag = ("%dx%d"):format(W, H)
    local tw = view.toolbar:getSize().w

    -- layout: the toolbar down the left, the page at 1:1 under it
    ok(v.area_x == tw and v.area_w == W - tw and v.area_y == 0 and v.area_h == H, tag .. ": area beside the book toolbar")
    ok(v.canvas_w == W and v.canvas_h == H and v.zoom == 1 and v.pan_x == tw, tag .. ": a canvas point is the screen point")
    ok(#view.canvas.ops == 2, tag .. ": the page's ink is loaded")

    -- a new stroke; saving keeps the two old strokes' anchors
    local y = 500
    view:onIaTouch(nil, pos(tw + 50, y))
    for i = 1, 6 do view:onIaPan(nil, pos(tw + 50 + i * 20, y + i)) end
    view:onIaPanRelease(nil, pos(tw + 170, y + 6))
    view:flushPending()
    ok(#view.canvas.ops == 3 and view.canvas.ops[3].pts[1] == tw + 50, tag .. ": a stroke lands where it is drawn")
    view:saveDocument()
    local last = book.last
    ok(last and #last.ops == 3 and book.saved == 1, tag .. ": saved into the book")
    ok(last.came_from[view.canvas.ops[1]] == items[1] and last.shown[2] == items[2],
        tag .. ": unchanged ink keeps its item, only shown ink is replaced")

    -- hiding the toolbar: the page fills the width, points stay where they are
    view:setToolbarHidden(true)
    ok(v.area_x == 0 and v.area_w == W and v.pan_x == 0, tag .. ": hidden, the page fills the width")
    view:setToolbarHidden(false)
    ok(v.area_x == tw, tag .. ": and the toolbar comes back")

    -- the smart highlighter: the stroke becomes the book's highlight; undo, redo
    view:choosePenType("highlighter"); view:setTool("pen")
    local n = #view.canvas.ops
    view:onIaTouch(nil, pos(tw + 40, 250))
    for i = 1, 5 do view:onIaPan(nil, pos(tw + 40 + i * 30, 251)) end
    view:onIaPanRelease(nil, pos(tw + 190, 251))
    view:flushPending()
    ok(#book.highlights == 1 and #view.canvas.ops == n, tag .. ": highlighter along a line is a highlight, not ink")
    view:undo()
    ok(book.removed == 1, tag .. ": undo takes the highlight away")
    view:redo()
    ok(book.restored == 1, tag .. ": redo puts it back")

    -- the eraser that cuts: across the first stroke's middle
    view:choosePenType("solid")
    view:setTool("erase"); view.erase_whole = false
    view:onIaTouch(nil, pos(300, 180))
    for i = 1, 4 do view:onIaPan(nil, pos(300, 180 + i * 10)) end
    view:onIaPanRelease(nil, pos(300, 220))
    view:flushPending()
    local pieces, erase = 0, false
    for _, op in ipairs(view.canvas.ops) do
        if op.kind == "erase" then erase = true end
        if op.kind == "ink" and op.pts[2] == 200 then pieces = pieces + 1 end
    end
    ok(pieces == 2 and not erase, tag .. ": the eraser cuts the stroke in two, and leaves no eraser stroke")
    -- the whole-stroke eraser takes the second stroke away
    view.erase_whole = true
    local before = #view.canvas.ops
    view:onIaTouch(nil, pos(300, 290))
    for i = 1, 4 do view:onIaPan(nil, pos(300, 290 + i * 5)) end
    view:onIaPanRelease(nil, pos(300, 310))
    view:flushPending()
    ok(#view.canvas.ops == before - 1, tag .. ": the whole-stroke eraser takes a stroke away")

    -- sheets made for a book
    view:openPenInput()
    ok(view._peninput_dialog and not hasText(view._peninput_dialog, "Test pen and touch"), tag .. ": no pen test over a book")
    view:closeSheet("_peninput_dialog")
    view:openEraserSettings()
    ok(view._eraser_dialog and hasText(view._eraser_dialog, "Erase whole strokes"), tag .. ": the eraser's whole-stroke switch is there")
    view:closeSheet("_eraser_dialog")
    view:openShapePicker()
    ok(view._shape_dialog and not hasText(view._shape_dialog, "Paint bucket"), tag .. ": no paint bucket over a book")
    view:closeSheet("_shape_dialog")

    -- the toolbar on each side: the area makes room for it, the tab sits at its
    -- inner edge (or at the screen's edge once hidden), and all of it on screen
    local function inside(r) return r.x >= 0 and r.y >= 0 and r.x + r.w <= W and r.y + r.h <= H end
    for _, side in ipairs({ "right", "top", "bottom", "left" }) do
        view:setToolbarSide(side)
        local t = view._vb_thick
        local want = {
            left = { t, 0, W - t, H }, right = { 0, 0, W - t, H },
            top = { 0, t, W, H - t }, bottom = { 0, 0, W, H - t },
        }
        local e = want[side]
        ok(v.area_x == e[1] and v.area_y == e[2] and v.area_w == e[3] and v.area_h == e[4]
            and v.pan_x == v.area_x and v.pan_y == v.area_y, tag .. " " .. side .. ": the area beside the toolbar, 1:1")
        local r = view:fabRect("bar")
        local touching = (side == "left" and r.x >= t and r.x < t + 8) or (side == "right" and r.x + r.w <= W - t and r.x + r.w > W - t - 8)
            or (side == "top" and r.y >= t and r.y < t + 8) or (side == "bottom" and r.y + r.h <= H - t and r.y + r.h > H - t - 8)
        ok(inside(r) and touching, tag .. " " .. side .. ": the tab sits at the toolbar's inner edge")
        view:setToolbarHidden(true)
        local h = view:fabRect("bar")
        ok(v.area_w == W and v.area_h == H and inside(h), tag .. " " .. side .. ": hidden, the page fills the screen, the tab at its edge")
        view:setToolbarHidden(false)
        BB.out_of_bounds = 0
        view._paint_all = true
        view:paintTo(Screen.bb, 0, 0)
        ok(BB.out_of_bounds == 0, tag .. " " .. side .. ": painted within the screen")
    end
    ok(view:sheetLeftX() == view._vb_thick, tag .. ": sheets open right of a left toolbar")

    -- painting stays on the screen, and closing saves and repaints the book
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, tag .. ": nothing painted out of bounds")
    local saved = book.saved
    view:closeCanvas()
    ok(book.saved > saved and book.repainted, tag .. ": closing saves the page and repaints the book")
end

print(("readerview: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
