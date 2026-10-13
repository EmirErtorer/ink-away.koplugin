-- A notebook's Bookshelf cover (ink/notebookcover.lua) on KOReader's REAL
-- blitter, fonts and image scaler: the first page fills the cover with its
-- ruling and ink, the spiral's holes and wire run down the left edge, the
-- name is white on the notebook's colour band, a view draws the page when one
-- is given, and what can't be drawn writes nothing.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/notebookcover.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
dofile(REPO .. "/tests/realbb/realtext.lua").install()
-- KOReader's own scaler, as RenderImage uses it on a device
local Mupdf = require("ffi/mupdf")
package.loaded["ui/renderimage"] = {
    scaleBlitBuffer = function(_, bb, w, h, free_orig)
        if bb:getWidth() == w and bb:getHeight() == h then return bb end
        local out = Mupdf.scaleBlitBuffer(bb, w, h)
        if free_orig ~= false then bb:free() end
        return out
    end,
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

local DIR = TestEnv.libraryDir()
local PW, PH = 600, 800
-- A notebook with a thick black line across page 1 at canvas row 400 and a
-- red stroke lower down.
local function notebook(name)
    local nb = Notebook.new(PW, PH, { style = "lines", size = 40 })
    nb.pages[1].ops = {
        { kind = "ink", width = 24, alpha = 255, style = "solid", seed = 1, pts = { 60, 400, 540, 400 } },
        { kind = "ink", width = 24, alpha = 255, color = { 220, 30, 30 }, style = "solid", seed = 2,
          pts = { 100, 600, 500, 600 } },
    }
    local path = DIR .. "/" .. name .. ".inkaway"
    assert(Project.saveNotebook(nb, path))
    return path
end

------------------------------------------------------------------------------
-- Layout and colours
------------------------------------------------------------------------------
do
    local page, band = Cover.layout()
    ok(page.x == 0 and page.y == 0 and page.w == Cover.W, "layout: the page runs edge to edge")
    ok(page.h + band.h == Cover.H and band.y == page.h and band.w == Cover.W, "layout: the band below it")
    local p = DIR .. "/a.inkaway"
    ok(Cover.boardOf(p) == Cover.boardOf(p), "boardOf: a notebook keeps its colour")
    local inPalette = false
    for _, c in ipairs(Cover.BOARDS) do if c == Cover.boardOf(p) then inPalette = true end end
    ok(inPalette, "boardOf: one of the band colours")
end

------------------------------------------------------------------------------
-- The cover
------------------------------------------------------------------------------
do
    local path = notebook("Physics")
    local bb = Cover.render(path)
    ok(bb ~= nil, "render: a notebook has a cover")
    ok(bb and bb:getWidth() == Cover.W and bb:getHeight() == Cover.H, "render: at the cover's size")
    if bb then
        local page, band = Cover.layout()
        local s = Cover.W / PW   -- the page at the cover's width
        -- ink: the black line, at its row scaled to the cover
        local ly = math.floor(400 * s)
        ok(count(bb, 120, ly - 3, 400, ly + 3, function(c) return c.r < 60 and c.g < 60 and c.b < 60 end) > 600,
            "render: the page's ink is on the cover")
        local ry = math.floor(600 * s)
        ok(ry < page.h, "render: (the red stroke is above the band)")
        ok(count(bb, 120, ry - 3, 380, ry + 3, function(c) return c.r > 170 and c.g < 90 and c.b < 90 end) > 300,
            "render: in its colours")
        -- paper and ruling between the strokes
        ok(count(bb, 120, 60, 460, 300, function(c) return c.r > 240 and c.g > 240 and c.b > 240 end) > 40000,
            "render: the page's paper")
        ok(count(bb, 120, 60, 460, 300, function(c) return c.r < 235 and c.r > 120 end) > 200,
            "render: and its ruling")
        -- the band in the notebook's colour, the name white on it
        local col = Cover.boardOf(path)
        ok(near(px(bb, Cover.W - 6, Cover.H - 6), col[1], col[2], col[3]), "render: the band in the notebook's colour")
        ok(count(bb, 40, band.y, Cover.W, Cover.H, function(c) return c.r > 230 and c.g > 230 and c.b > 230 end) > 150,
            "render: the name in white on it")
        -- the spiral: a dark hole by the edge, and wire running off the edge
        local function hole(c) return near(c, 0x3A, 0x3A, 0x3A, 10) end
        ok(count(bb, 12, 10, 24, 26, hole) > 6, "render: a punched hole near the left edge, the wire through it")
        ok(count(bb, 0, 15, 14, 22, function(c) return c.r > 240 end) > 20, "render: the page shows inside the loop")
        ok(count(bb, 0, 8, 4, 30, function(c) return c.r > 180 and c.r < 230 and near(c, c.r, c.r, c.r, 12) end) > 4,
            "render: wire at the very edge, wrapping round it")
        ok(count(bb, 12, band.y, 24, Cover.H, hole) > 20, "render: the spiral runs through the band too")
        bb:free()
    end

    -- a long name is shrunk and cut short, never past the band
    local long = notebook("A notebook with a name far too long for any cover at all")
    local lb = Cover.render(long)
    ok(lb ~= nil, "render: a long name still has a cover")
    if lb then
        local _, band = Cover.layout()
        ok(count(lb, Cover.W - 10, band.y, Cover.W, Cover.H, function(c) return c.r > 230 and c.g > 230 end) == 0,
            "render: a long name stays clear of the band's edge")
        ok(count(lb, 40, band.y, Cover.W, Cover.H, function(c) return c.r > 230 and c.g > 230 and c.b > 230 end) > 150,
            "render: and is still written")
        lb:free()
    end

    -- with a view, the view draws the page (text and pictures included)
    local asked
    local view = { renderDocThumb = function(_, p, w, h)
        asked = { p = p, w = w, h = h }
        local t = BB.new(w, h, BB.TYPE_BBRGB32)
        t:paintRectRGB32(0, 0, w, h, BB.ColorRGB32(0, 200, 0, 0xFF))
        return t
    end }
    local vb = Cover.render(path, view)
    ok(asked and asked.p == path and asked.w == Cover.W, "render: a view is asked for the page at the cover's width")
    ok(vb and near(px(vb, 240, 200), 0, 200, 0), "render: and its page is the one shown")
    if vb then vb:free() end
    -- a view that can't draw it: the export engine does
    local fb = Cover.render(path, { renderDocThumb = function() return nil end })
    ok(fb and near(px(fb, 240, 100), 255, 255, 255, 20), "render: without the view's page, the export engine's")
    if fb then fb:free() end
end

------------------------------------------------------------------------------
-- Writing it
------------------------------------------------------------------------------
do
    local path = notebook("Written")
    local file = DIR .. "/cover.png"
    ok(Cover.write(path, file) == true, "write: the cover is written")
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
