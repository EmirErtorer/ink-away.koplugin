-- A notebook's Bookshelf cover (ink/notebookcover.lua) on KOReader's REAL
-- blitter, fonts and image scaler, in each of its six styles: the coloured
-- part takes the notebook's colour, the name stays inside its area however long
-- it is (the default "Notebook <date> <time>" on two lines) and reads on light
-- and dark colours, the styles that show the first page draw it on its own
-- paper (white ink on a dark one) and the others never draw it, the spiral's
-- holes and wire run off the edge, a view draws the page when one is given,
-- and what can't be drawn writes nothing.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/notebookcover.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
-- KOReader's own scaler, as RenderImage uses it on a device
local Mupdf = require("ffi/mupdf")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
dofile(REPO .. "/tests/realbb/realtext.lua").install()
package.loaded["ui/renderimage"] = {
    scaleBlitBuffer = function(_, bb, w, h, free_orig)
        if bb:getWidth() == w and bb:getHeight() == h then return bb end
        local out = Mupdf.scaleBlitBuffer(bb, w, h)
        if free_orig ~= false then bb:free() end
        return out
    end,
    renderImageFile = function(_, file) return Mupdf.renderImageFile(file) end,
}
local TestEnv = require("testenv")
local Storage = require("ink/storage")
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Cover = require("ink/notebookcover")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local function px(bb, x, y) return bb:getPixel(x, y):getColorRGB32() end
local function near(c, r, g, b, tol)
    tol = tol or 6
    return math.abs(c.r - r) <= tol and math.abs(c.g - g) <= tol and math.abs(c.b - b) <= tol
end
-- How many pixels in the rect pass `test`.
local function count(bb, x0, y0, x1, y1, test)
    local n = 0
    for y = y0, y1 - 1 do for x = x0, x1 - 1 do if test(px(bb, x, y)) then n = n + 1 end end end
    return n
end
-- Where two covers differ: the count, and whether all of it is inside `r`.
local function differ(a, b, r)
    local n, outside = 0, 0
    for y = 0, Cover.H - 1 do
        for x = 0, Cover.W - 1 do
            local p, q = px(a, x, y), px(b, x, y)
            if p.r ~= q.r or p.g ~= q.g or p.b ~= q.b then
                n = n + 1
                if x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h then outside = outside + 1 end
            end
        end
    end
    return n, outside
end

local DIR = TestEnv.libraryDir()
local PW, PH = 600, 800
-- A notebook with a thick line across page 1 at canvas row 400 and a red
-- stroke lower down, on `paper` ({r,g,b}, white when nil).
local function notebook(name, paper)
    local nb = Notebook.new(PW, PH, { style = "lines", size = 40, paper = paper })
    nb.pages[1].ops = {
        { kind = "ink", width = 24, alpha = 255, style = "solid", seed = 1, pts = { 60, 400, 540, 400 } },
        { kind = "ink", width = 24, alpha = 255, color = { 220, 30, 30 }, style = "solid", seed = 2,
          pts = { 100, 600, 500, 600 } },
    }
    local path = DIR .. "/" .. name .. ".inkaway"
    assert(Project.saveNotebook(nb, path))
    return path
end

local DEFAULT_NAME = "Notebook 2026-10-13 14.22"
-- A point in each style's coloured part.
local COLOURED = {
    page = { Cover.W - 6, Cover.H - 6 }, hardcover = { Cover.W - 20, 40 }, composition = { 30, 300 },
    reporter = { Cover.W - 30, 100 }, kraft = { Cover.W - 6, Cover.H - 6 }, legal = { Cover.W - 20, 60 },
}

------------------------------------------------------------------------------
-- Every style
------------------------------------------------------------------------------
do
    local path = notebook("Physics")
    local purple = { 0x80, 0x00, 0xB0 }
    for _, style in ipairs(Cover.STYLES) do
        local pages = {}
        local bb = Cover.render(path, { style = style, colour = purple, pages = pages })
        ok(bb and bb:getWidth() == Cover.W and bb:getHeight() == Cover.H, style .. ": a cover at the cover's size")
        if bb then
            local at = COLOURED[style]
            ok(near(px(bb, at[1], at[2]), purple[1], purple[2], purple[3]), style .. ": its coloured part in the colour")
            ok((next(pages) ~= nil) == (Cover.SHOWS_PAGE[style] == true),
                style .. (Cover.SHOWS_PAGE[style] and ": draws the first page" or ": never draws the page"))
            -- the name: inside its area, written, on two lines when long
            local blank = Cover.render(path, { style = style, colour = purple, name = "", pages = pages })
            local long = Cover.render(path, { style = style, colour = purple, name = DEFAULT_NAME, pages = pages })
            local r = Cover.LAYOUT[style].name
            local n, outside = differ(blank, long, r)
            ok(n > 300, style .. ": the default name is written")
            ok(outside == 0, style .. ": the default name stays inside its area (" .. outside .. " outside)")
            local word = Cover.render(path, { style = style, colour = purple, pages = pages,
                name = "Supercalifragilisticexpialidociousnotebookofeverything" })
            n, outside = differ(blank, word, r)
            ok(n > 200 and outside == 0, style .. ": one very long word is cut short inside its area")
            local many = Cover.render(path, { style = style, colour = purple, pages = pages,
                name = "A notebook with a name far too long for any cover anyone would ever make at all" })
            n, outside = differ(blank, many, r)
            ok(n > 200 and outside == 0, style .. ": a very long name is cut short inside its area")
            blank:free(); long:free(); word:free(); many:free()
            bb:free()
        end
        Cover.freePages(pages)
        ok(next(pages) == nil, style .. ": its kept pages are freed")
    end
end

------------------------------------------------------------------------------
-- Names on light and dark colours
------------------------------------------------------------------------------
do
    local path = notebook("Contrast")
    local function nameInk(style, colour)
        local blank = Cover.render(path, { style = style, colour = colour, name = "" })
        local named = Cover.render(path, { style = style, colour = colour, name = "Physics" })
        local r = Cover.LAYOUT[style].name
        local dark, light = 0, 0
        for y = r.y, r.y + r.h - 1 do
            for x = r.x, r.x + r.w - 1 do
                local p, q = px(blank, x, y), px(named, x, y)
                if p.r ~= q.r or p.g ~= q.g or p.b ~= q.b then
                    if q.r < 80 and q.g < 80 and q.b < 80 then dark = dark + 1 end
                    if q.r > 220 and q.g > 220 and q.b > 220 then light = light + 1 end
                end
            end
        end
        blank:free(); named:free()
        return dark, light
    end
    local d, l = nameInk("page", { 0x2E, 0x4A, 0x7A })
    ok(l > 100 and d == 0, "name: white on a dark band")
    d, l = nameInk("page", { 0xE8, 0xC0, 0x00 })
    ok(d > 100 and l == 0, "name: near black on a light band")
    d, l = nameInk("hardcover", { 0xE8, 0xC0, 0x00 })
    ok(d > 100, "name: near black on the cream label")
    d, l = nameInk("legal", { 0xBB, 0xBB, 0xBB })
    ok(d > 100, "name: near black on a light grey binding")
end

------------------------------------------------------------------------------
-- The first page: from its snapshot, else its paper and ruling without ink
------------------------------------------------------------------------------
-- What Ink Away's view keeps as it shows a notebook's first page (see
-- Shelf.takeSnapshot): the page drawn, at the cover's width.
local function snapshotOf(path)
    local nb = Cover.load(path)
    local page = Cover.pageImage(nb, Cover.W, math.floor(Cover.W * nb.h / nb.w + 0.5))
    local file = path .. ".snap.png"
    page:writePNG(file)
    page:free()
    return file
end
do
    local s = Cover.W / PW   -- the page at the cover's width (page style)
    local path = notebook("Ink")
    local ly, ry = math.floor(400 * s), math.floor(600 * s)
    local function dark(c) return c.r < 60 and c.g < 60 and c.b < 60 end
    -- no snapshot yet: the paper and its ruling, and no stroke drawn
    local pb = Cover.render(path, { style = "page" })
    ok(count(pb, 120, ly - 3, 400, ly + 3, dark) == 0, "page: without a snapshot no ink is drawn")
    ok(count(pb, 120, 60, 460, 300, function(c) return c.r > 240 and c.g > 240 and c.b > 240 end) > 40000,
        "page: without a snapshot, white paper")
    ok(count(pb, 120, 60, 460, 300, function(c) return c.r < 235 and c.r > 120 end) > 200,
        "page: without a snapshot, its ruling")
    pb:free()
    -- with one, the page as Ink Away drew it
    local snap = snapshotOf(path)
    local bb = Cover.render(path, { style = "page", snapshot = snap })
    ok(count(bb, 120, ly - 3, 400, ly + 3, dark) > 600, "page: the snapshot's ink is on the cover")
    ok(count(bb, 120, ry - 3, 380, ry + 3, function(c) return c.r > 170 and c.g < 90 and c.b < 90 end) > 300,
        "page: in its colours")
    ok(count(bb, 120, 60, 460, 300, function(c) return c.r > 240 and c.g > 240 and c.b > 240 end) > 40000,
        "page: on white paper")
    ok(count(bb, 120, 60, 460, 300, function(c) return c.r < 235 and c.r > 120 end) > 200, "page: and its ruling")
    -- the spiral: a dark hole by the edge, wire running off the edge and
    -- the page showing inside each ring
    local function hole(c) return near(c, 0x3A, 0x3A, 0x3A, 10) end
    ok(count(bb, 12, 10, 24, 26, hole) > 6, "page: a punched hole near the left edge, the wire through it")
    ok(count(bb, 0, 15, 14, 22, function(c) return c.r > 240 end) > 20, "page: the page shows inside the ring")
    ok(count(bb, 0, 8, 4, 30, function(c) return c.r > 180 and c.r < 230 and near(c, c.r, c.r, c.r, 12) end) > 4,
        "page: wire at the very edge, wrapping round it")
    local band = Cover.LAYOUT.page.band
    ok(count(bb, 12, band.y, 24, Cover.H, hole) > 20, "page: the spiral runs through the band too")
    bb:free()
    -- a snapshot gone missing: the paper again
    os.remove(snap)
    local gb = Cover.render(path, { style = "page", snapshot = snap })
    ok(gb and count(gb, 120, ly - 3, 400, ly + 3, dark) == 0, "page: a missing snapshot gives the paper")
    if gb then gb:free() end

    -- a cream paper shows as cream in every style that shows the page, with
    -- a snapshot and without
    local cream = { 0xF3, 0xE9, 0xD2 }
    local cp = notebook("Cream", cream)
    local csnap = snapshotOf(cp)
    for _, style in ipairs({ "page", "reporter", "kraft" }) do
        for _, sn in ipairs({ csnap, false }) do
            local cb = Cover.render(cp, { style = style, snapshot = sn or nil })
            local r = style == "kraft" and Cover.LAYOUT.kraft.window or Cover.LAYOUT[style].page
            ok(count(cb, r.x + 40, r.y + 4, r.x + r.w - 10, r.y + 60, function(c) return near(c, 0xF3, 0xE9, 0xD2, 4) end) > 2000,
                style .. ": the page's own paper colour" .. (sn and "" or ", without a snapshot"))
            cb:free()
        end
    end
    -- on a dark paper the ink shows white, as in Ink Away
    local dp = notebook("Dark", { 0x22, 0x22, 0x22 })
    local db = Cover.render(dp, { style = "page", snapshot = snapshotOf(dp) })
    ok(count(db, 120, ly - 3, 400, ly + 3, function(c) return c.r > 220 and c.g > 220 and c.b > 220 end) > 600,
        "page: black ink shows white on a dark paper")
    ok(count(db, 120, 60, 460, 300, function(c) return near(c, 0x22, 0x22, 0x22, 6) end) > 30000,
        "page: on its dark paper")
    db:free()
    local pdb = Cover.render(dp, { style = "page" })
    ok(count(pdb, 120, 60, 460, 300, function(c) return near(c, 0x22, 0x22, 0x22, 6) end) > 30000,
        "page: on its dark paper without a snapshot too")
    pdb:free()
end

------------------------------------------------------------------------------
-- The snapshot Ink Away's view keeps of a notebook's first page
------------------------------------------------------------------------------
do
    local Shelf = require("ink/bookshelf")
    local Notebook = require("ink/notebook")
    local cache = DIR .. "/snapcache"
    Storage.ensureDir(cache)
    local path = notebook("Snapped")
    local was_reg, was_covers = Shelf.registered, Shelf.covers
    Shelf.registered = true
    Shelf.covers = Shelf.newCovers{ cacheDir = function() return cache end, render = function() return true end,
        schedule = function() end, unschedule = function() end, changed = function() end }
    local file = Shelf.snapshotFile(Shelf.covers.dir(), path)
    local nb = Notebook.fromData(Project.load(path))
    local canvas = BB.new(PW, PH, BB.TYPE_BB8)
    canvas:paintRect(0, 0, PW, PH, BB.Color8(0x40))
    local function newView()
        return { notebook = nb, canvas_bb = canvas, doc_written = true, doc_path = path,
            nightInk = function(v) return v.night == true end }
    end
    local view = newView()
    ok(Shelf.takeSnapshot(view) == true and Storage.exists(file), "snapshot: taken from the page the view drew")
    local img = Mupdf.renderImageFile(file)
    ok(img:getWidth() == Cover.W and math.abs(img:getHeight() - math.floor(Cover.W * PH / PW)) <= 1,
        "snapshot: at the cover's width, the page's shape")
    ok(near(px(img, 100, 100), 0x40, 0x40, 0x40, 3), "snapshot: the page as drawn")
    img:free()
    ok(Shelf.takeSnapshot(view) == false, "snapshot: not again while the page is unchanged")
    view._p1_changed = true
    ok(Shelf.takeSnapshot(view) == true, "snapshot: again once the first page changed")
    nb.template.style = "dots"
    ok(Shelf.takeSnapshot(view) == true, "snapshot: or its paper")
    nb.index = 2
    view._p1_changed = true
    ok(Shelf.takeSnapshot(view) == false, "snapshot: never of another page")
    nb.index = 1
    view.night = true
    view._p1_changed = true
    ok(Shelf.takeSnapshot(view) == false, "snapshot: never in night colours")
    view.night = nil
    -- a view opening the notebook later: taken again only if the file was
    -- written since (on another page, or elsewhere)
    os.execute("touch -t 202601010000 '" .. path .. "'")
    ok(Shelf.takeSnapshot(newView()) == false, "snapshot: a new view keeps one newer than the file")
    os.execute("touch -t 202601010000 '" .. file .. "'")
    os.execute("touch '" .. path .. "'")
    ok(Shelf.takeSnapshot(newView()) == true, "snapshot: and takes it again when the file is newer")
    Shelf.registered = false
    os.remove(file)
    ok(Shelf.takeSnapshot(newView()) == false and not Storage.exists(file), "snapshot: nothing without Bookshelf")
    Shelf.registered, Shelf.covers = was_reg, was_covers
    canvas:free()
end

------------------------------------------------------------------------------
-- Colours, marbling and the same cover twice
------------------------------------------------------------------------------
do
    local a, b = notebook("Same"), notebook("Other")
    ok(Cover.boardOf(a) == Cover.boardOf(a), "boardOf: a notebook keeps its colour")
    local inPalette = false
    for _, c in ipairs(Cover.BOARDS) do if c == Cover.boardOf(a) then inPalette = true end end
    ok(inPalette, "boardOf: one of the cover colours")
    local auto = Cover.render(a, { style = "page" })
    local col = Cover.boardOf(a)
    ok(near(px(auto, Cover.W - 6, Cover.H - 6), col[1], col[2], col[3]), "colour: without one, the picked colour")
    auto:free()
    local m1 = Cover.render(a, { style = "composition", name = "" })
    local m2 = Cover.render(a, { style = "composition", name = "" })
    local m3 = Cover.render(b, { style = "composition", name = "" })
    local full = { x = 0, y = 0, w = Cover.W, h = Cover.H }
    ok(differ(m1, m2, full) == 0, "composition: a notebook's marbling is the same every time")
    ok(differ(m1, m3, full) > 1000, "composition: another notebook's is its own")
    m1:free(); m2:free(); m3:free()
    ok(Cover.styleOf("legal") == "legal" and Cover.styleOf("nope") == Cover.DEFAULT and Cover.styleOf(nil) == Cover.DEFAULT,
        "styleOf: a style, or the default")
    local names = Cover.names()
    for _, s in ipairs(Cover.STYLES) do ok(type(names[s]) == "string" and names[s] ~= "", "names: " .. s) end
end

------------------------------------------------------------------------------
-- Writing it
------------------------------------------------------------------------------
do
    local path = notebook("Written")
    local file = DIR .. "/cover.png"
    ok(Cover.write(path, file, { style = "kraft" }) == true, "write: the cover is written")
    ok(Storage.exists(file) and not Storage.exists(file .. ".tmp"), "write: as a PNG, nothing left over")
    local f = io.open(file, "rb")
    local sig = f and f:read(8)
    if f then f:close() end
    ok(sig == "\137PNG\r\n\26\n", "write: a real PNG")

    local drawing = DIR .. "/Drawing.inkaway"
    assert(Project.save({ w = 10, h = 10, ops = {} }, drawing))
    ok(Cover.render(drawing) == nil, "render: a drawing has no notebook cover")
    ok(Cover.write(drawing, DIR .. "/none.png") == false and not Storage.exists(DIR .. "/none.png"),
        "write: nothing for a drawing")
    ok(Cover.write(DIR .. "/missing.inkaway", DIR .. "/none.png") == false, "write: nothing for a missing file")
end

TestEnv.cleanup()
print(string.format("realbb notebookcover: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
