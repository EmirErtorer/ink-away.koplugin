-- Book ink on two pages shown side by side, with a stand-in for what a two-page
-- plugin makes of KOReader's view (MuPDFtwoPages' transforms: crop, gutter and a
-- scale per page). Ink on the right page must come back there; a book showing one
-- page must get the same answers as ever. Also the pairing of ink/reader/twopage.lua.
--   luajit tests/spread.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local env = require("testenv")
G_reader_settings = { data = env.settings(), readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end, isTrue = function(self, k) return self.data[k] == true end }
local Book = require("ink/reader/book")
local BookInk = require("ink/reader/bookink")
local TwoPage = require("ink/reader/twopage")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function near(a, b) return a and b and math.abs(a - b) < 1.01 end

-- The view as MuPDFtwoPages leaves it, pages 20 and 21 shown.
local function spreadUi(left, right, zoom)
    local view = { state = { page = 20, zoom = zoom, offset = { x = 30, y = 12 }, rotation = 0 },
        visible_area = { x = 0, y = 0, w = 1400, h = 1000,
            intersectWith = function() return true end } }
    local seam = left.box.w * left.scale
    function view:screenToPageTransform(p)
        local x, y = (p.x - self.state.offset.x + self.visible_area.x) / zoom, (p.y - self.state.offset.y + self.visible_area.y) / zoom
        if x >= seam then
            return { page = right.page, x = (x - seam) / right.scale + right.box.x, y = y / right.scale + right.box.y, zoom = zoom * right.scale }
        end
        return { page = left.page, x = x / left.scale + left.box.x, y = y / left.scale + left.box.y, zoom = zoom * left.scale }
    end
    function view:getCurrentPageList() return { 20, 21 } end
    function view:pageToScreenTransform(page, rect)
        local side, origin = left, 0
        if page == right.page then side, origin = right, seam * zoom elseif page ~= left.page then return nil end
        local z = zoom * side.scale
        return { x = self.state.offset.x + origin + (rect.x - side.box.x) * z - self.visible_area.x,
            y = self.state.offset.y + (rect.y - side.box.y) * z - self.visible_area.y, w = rect.w * z, h = rect.h * z }
    end
    local ui = { paging = {}, view = view, document = { file = env.libraryDir() .. "/s.pdf",
        getNativePageDimensions = function() return { w = 600, h = 800 } end } }
    local book = Book.new(ui)
    book._data = BookInk.new()
    book.sidecar, book.dirs = env.libraryDir(), { env.libraryDir() }
    return ui, book
end

local function stroke(x, y)
    return { kind = "ink", pts = { x, y, x + 40, y + 10, x + 80, y }, width = 4, color = { 0, 0, 0 } }
end

for _i, c in ipairs({
    { name = "plain", left = { page = 20, box = { x = 0, y = 0, w = 600, h = 800 }, scale = 1 }, right = { page = 21, box = { x = 0, y = 0, w = 600, h = 800 }, scale = 1 }, zoom = 1.1 },
    { name = "cropped", left = { page = 20, box = { x = 40, y = 30, w = 520, h = 740 }, scale = 1 }, right = { page = 21, box = { x = 25, y = 30, w = 540, h = 740 }, scale = 1 }, zoom = 1.25 },
    { name = "gutter", left = { page = 20, box = { x = 40, y = 30, w = 560, h = 740 }, scale = 1 }, right = { page = 21, box = { x = 0, y = 30, w = 565, h = 740 }, scale = 1 }, zoom = 1.2 },
    { name = "scaled", left = { page = 20, box = { x = 0, y = 0, w = 600, h = 800 }, scale = 1 }, right = { page = 21, box = { x = 0, y = 0, w = 500, h = 600 }, scale = 1.33 }, zoom = 1 },
}) do
    local ui, book = spreadUi(c.left, c.right, c.zoom)
    local pages = book:visiblePages()
    ok(#pages == 2 and pages[1] == 20 and pages[2] == 21, c.name .. ": both pages are shown")
    local spots = { { 100, 150 }, { 120, 760 }, { 900, 150 }, { 950, 760 } }
    local ops = {}
    for i, s in ipairs(spots) do ops[i] = stroke(s[1], s[2]) end
    book:setPageOps(ops, nil, nil)
    local items = book:data().items
    ok(#items == 4, c.name .. ": all four kept")
    local by = {}
    for _k, it in ipairs(items) do by[it.a.page] = (by[it.a.page] or 0) + 1 end
    ok(by[20] == 2 and by[21] == 2, c.name .. ": two strokes on each page")
    local placed = book:pageOps()
    ok(placed and #placed.ops == 4, c.name .. ": all four come back, right page too")
    for i, s in ipairs(spots) do
        local op
        for k, it in ipairs(placed.items) do if it == items[i] then op = placed.ops[k] end end
        ok(op and near(op.pts[1], s[1]) and near(op.pts[2], s[2]), c.name .. ": stroke " .. i .. " where it was drawn")
    end
    -- the crop or the gutter changes: the cached place isn't used
    local before = book:pageOps()
    c.right.box.x = c.right.box.x + 5
    ok(book:pageOps() ~= before, c.name .. ": a changed layout places the ink again")
    c.right.box.x = c.right.box.x - 5
    -- turned to another spread: this one's ink isn't there
    ui.view.getCurrentPageList = function() return { 22, 23 } end
    ui.view.state.page = 22
    local other = book:pageOps()
    ok(not other or #other.ops == 0, c.name .. ": the next spread has none of it")
end

-- one page: the view's list has one page, and a view without the list still works
do
    local view = { state = { page = 3, zoom = 2, offset = { x = 7, y = 9 } }, visible_area = { x = 0, y = 4 } }
    function view:screenToPageTransform(p) return { page = 3, x = p.x / 2, y = p.y / 2, zoom = 2 } end
    local ui = { paging = {}, view = view, document = { file = env.libraryDir() .. "/o.pdf" } }
    local book = Book.new(ui)
    ok(#book:visiblePages() == 1 and book:spreadPages() == nil, "one page: no spread (no page list)")
    local x, y, z = book:doc():toScreen(3, 10, 20)
    ok(x == 7 + 20 and y == 9 + 40 - 4 and z == 2, "one page: placed as ever")
    ok(book:doc():toScreen(4, 10, 20) == nil, "one page: another page isn't on the screen")
    function view:getCurrentPageList() return { 3 } end
    ok(book:spreadPages() == nil and #book:visiblePages() == 1, "one page: no spread (a list of one)")
    view.page_scroll = true
    function view:getCurrentPageList() return { 3, 4 } end
    ok(book:spreadPages() == nil, "continuous view isn't a spread")
end

-- The pairing
local function unit(n, count, first, wide)
    local u = TwoPage.unit(n, count, first, wide)
    return u and (u.a .. "+" .. tostring(u.b)) or "nil"
end
ok(unit(1, 8) == "1+2" and unit(2, 8) == "1+2" and unit(3, 8) == "3+4", "pairs from page 1")
ok(unit(1, 8, true) == "1+nil" and unit(2, 8, true) == "2+3" and unit(3, 8, true) == "2+3", "first page on its own")
ok(unit(7, 7) == "7+nil", "an odd last page is alone")
ok(unit(8, 8, true) == "8+nil" and unit(9, 8) == "nil" and unit(0, 8) == "nil", "ends")
local function w4(p) return p == 4 end
ok(unit(4, 8, false, w4) == "4+nil" and unit(3, 8, false, w4) == "3+nil" and unit(5, 8, false, w4) == "5+6", "a wide page and its partner are alone; the next pair is as before")

print(("spread: %d checks, %d failures"):format(checks, failures))
env.cleanup()
os.exit(failures == 0 and 0 or 1)
