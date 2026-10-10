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

-- The button in a widget tree labelled `text`.
local function findButton(w, text)
    local seen = {}
    local function walk(t)
        if type(t) ~= "table" or seen[t] then return nil end
        seen[t] = true
        if type(t.callback) == "function" and hasText(t, text) then
            for k, v in pairs(t) do
                if k ~= "show_parent" and k ~= "parent" and k ~= "callback" then
                    local inner = walk(v)
                    if inner then return inner end
                end
            end
            return t
        end
        for k, v in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" then
                local f = walk(v)
                if f then return f end
            end
        end
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
    function book:hasInk() return not self.trashed end
    function book:trashInk(root)
        self.trashed, self.trash_root = true, root
        self.pageOps = function() return { ops = {}, items = {} } end
        return { id = "t1", kind = "bookink" }
    end
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

    -- with the stabilizer on, a stroke still ends where the pen lifted
    view:choosePenType("solid"); view:setTool("pen")
    view.stabilizer = 60
    local n0 = #view.canvas.ops
    view:onIaTouch(nil, pos(tw + 40, H / 2))
    view:onIaPan(nil, pos(tw + 200, H / 2))
    view:onIaPanRelease(nil, pos(tw + 200, H / 2))
    view:flushPending()
    local made = view.canvas.ops[#view.canvas.ops]
    local lx = require("ink/geom").toCanvas(view.view, tw + 200, H / 2)
    ok(#view.canvas.ops == n0 + 1 and math.abs(made.pts[#made.pts - 1] - lx) < 0.01,
        tag .. ": the stroke ends where the pen lifted (" .. tostring(made and made.pts[#made.pts - 1]) .. " of " .. lx .. ")")
    view:undo()
    view.stabilizer = 40

    -- with the lasso, a tap on a picture or a shape's line picks it out (over a
    -- book there is no Pan to do it), and a hold does too
    view:dropSelection()
    local pic = { kind = "image", path = "x.png", x = tw + 300, y = 380, w = 120, h = 90 }
    local rect = { kind = "shape", shape = "rect", width = 4, alpha = 255, color = { 0, 0, 0 },
        pts = { tw + 60, 420, tw + 200, 520 } }
    view.canvas.ops[#view.canvas.ops + 1] = pic
    view.canvas.ops[#view.canvas.ops + 1] = rect
    view:setTool("lasso")
    view:onIaTouch(nil, pos(tw + 360, 420))
    view:onIaTap(nil, pos(tw + 360, 420))
    ok(view.selection and view.canvas.ops[view.selection.idxs[1]] == pic, tag .. ": a lasso tap picks the picture")
    view:dropSelection(); view:closeSheet("_sel_dialog")
    view:onIaTouch(nil, pos(tw + 130, 423))
    view:onIaTap(nil, pos(tw + 130, 423))
    ok(view.selection and view.canvas.ops[view.selection.idxs[1]] == rect, tag .. ": a tap near the rectangle's line picks it")
    view:dropSelection(); view:closeSheet("_sel_dialog")
    view:onIaTouch(nil, pos(tw + 330, 440))
    view:onIaHold(nil, pos(tw + 330, 440))
    view:onIaHoldRel(nil, pos(tw + 330, 440))
    ok(view.selection and view.canvas.ops[view.selection.idxs[1]] == pic, tag .. ": a lasso hold picks it too")
    view:dropSelection(); view:closeSheet("_sel_dialog")
    view:onIaTouch(nil, pos(tw + 40, 650))
    view:onIaTap(nil, pos(tw + 40, 650))
    ok(view.selection == nil, tag .. ": a tap on nothing picks nothing")
    table.remove(view.canvas.ops); table.remove(view.canvas.ops)
    view:setTool("pen")

    -- with palm rejection on (a pen reader's default) an open text box still takes
    -- the pen and a finger: Format and Done answer both, and a finger tapping away
    -- closes the box without starting another
    do
        local Text = require("ink/text")
        local formats = 0
        local openFormat = view.openTextFormatMenu
        view.openTextFormatMenu = function() formats = formats + 1 end
        view.palm_reject = true
        view:setTool("text")
        local kb = { dimen = { x = 0, y = H - 300, w = W, h = 300 } }
        local function open()
            view.editing_text = Text.new{ x = tw + 40, y = 60, w = 400, size = 20 }
            view.editing_text.h = 40
            view.editing_is_new, view.text_cur = true, { p = 1, o = 0 }
            view._text_kb = kb
            UIManager:show(kb)
        end
        local function tap(x, y) view:onIaTouch(nil, pos(x, y)); view:onIaTap(nil, pos(x, y)) end
        local function mid(r) return r.x + r.w / 2, r.y + r.h / 2 end
        open()
        local b = view:textEditButtons()
        ok(view:penOnUI(mid(b.done)), tag .. ": with the keyboard up, the pen on the box is a UI contact")
        tap(mid(b.format))
        ok(formats == 1 and view.editing_text ~= nil, tag .. ": a finger opens Format")
        tap(mid(b.done))
        ok(view.editing_text == nil and view._text_kb == nil, tag .. ": a finger taps Done")
        open()
        local dx, dy = mid(b.done)
        view._pen_ui = { x = dx, y = dy, x0 = dx, y0 = dy }
        tap(dx, dy)
        ok(view.editing_text == nil and view._text_kb == nil, tag .. ": so does the pen")
        view._pen_ui = nil
        open()
        tap(tw + 300, H / 2 - 40)
        ok(view.editing_text == nil and view._text_kb == nil and view._finger_nav == nil,
            tag .. ": a finger tapping away closes the box, and opens no other")
        view.openTextFormatMenu = openFormat
        view.palm_reject = false
        view:setTool("pen")
    end

    -- deleting every annotation on the book: two confirmations, then gone at
    -- once into the trash, with nothing left to undo
    view:openReaderSettings()
    local del = findButton(view._settings_dialog, "Delete all annotations on this book\u{2026}")
    ok(del ~= nil, tag .. ": Book ink offers to delete the book's annotations")
    del.callback()
    ok(view._delete_ink and hasText(view._delete_ink, "Delete all annotations?"), tag .. ": first it asks")
    findButton(view._delete_ink, "Continue").callback()
    ok(view._delete_ink and hasText(view._delete_ink, "Are you sure?") and not book.trashed, tag .. ": then asks again")
    findButton(view._delete_ink, "Delete").callback()
    ok(book.trashed and book.trash_root == view:libraryDir(), tag .. ": then the annotations go to the trash")
    ok(#view.canvas.ops == 0 and not view.canvas:canUndo(), tag .. ": gone from the page at once, nothing to undo")
    ok(view._delete_ink and hasText(view._delete_ink, "Moved to the trash"), tag .. ": and it says where they are")
    view:closeSheet("_delete_ink")
    view:openReaderSettings()
    ok(findButton(view._settings_dialog, "Delete all annotations on this book\u{2026}") == nil,
        tag .. ": with no annotations left, nothing to delete")
    view:closeSheet("_settings_dialog")
    -- and the page takes new ink after it
    view:setTool("pen")
    view:onIaTouch(nil, pos(tw + 60, H - 120))
    for i = 1, 4 do view:onIaPan(nil, pos(tw + 60 + i * 20, H - 120)) end
    view:onIaPanRelease(nil, pos(tw + 140, H - 120))
    view:flushPending()
    ok(#view.canvas.ops == 1, tag .. ": new ink after the delete")

    -- painting stays on the screen, and closing saves and repaints the book
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, tag .. ": nothing painted out of bounds")
    local saved = book.saved
    view:closeCanvas()
    ok(book.saved > saved and book.repainted, tag .. ": closing saves the page and repaints the book")
end

print(("readerview: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
