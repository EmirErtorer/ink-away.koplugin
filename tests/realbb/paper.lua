-- Paper colours on KOReader's REAL blitter: every paper's ruling stands out
-- from it, in colour and in grey; a drawing or notebook on a paper shows it,
-- the eraser (live, saved, hard) reveals it rather than white, the grid and the
-- ruling take its shade, a dark paper turns the pen and the text white, and
-- the exports (PNG on the page or transparent, PDF pages, the fill's grey
-- map, thumbnails) lay the page on the same paper.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/paper.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
local Device = require("device")
local UIManager = require("ui/uimanager")
local Export = require("ink/export")
local Fill = require("ink/fill")
local Paint = require("ink/paint")
local Palette = require("ink/palette")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local function paperOf(key)
    for _i, p in ipairs(Palette.PAPERS) do if p.key == key then return p.rgb end end
end
local function lum(c) return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b end
local function near(a, b, tol)
    tol = tol or 2
    return math.abs(a.r - b.r) <= tol and math.abs(a.g - b.g) <= tol and math.abs(a.b - b.b) <= tol
end
local function px(bb, x, y) return bb:getPixel(x, y):getColorRGB32() end
-- paper `rgb` as a buffer of type `typ` shows it (grey on a grey screen)
local function shown(typ, rgb)
    local b = BB.new(4, 4, typ)
    Paint.paintPaper(b, 4, 4, { style = "blank", paper = Palette.paperRGB(rgb) }, nil)
    local c = px(b, 1, 1)
    b:free()
    return c
end
local function rgbOf(t) return { r = t[1], g = t[2], b = t[3] } end

-- ---- the papers ----------------------------------------------------------------
do
    local grey = Palette.papers(false)
    ok(#grey == 2 and grey[1].key == "white" and grey[2].key == "black", "papers: a grey screen offers white and black")
    local all = Palette.papers(true)
    ok(#all >= 10 and #all <= 12, "papers: a colour screen offers ten to twelve (" .. #all .. ")")
    ok(paperOf("sand") ~= nil, "papers: sandpaper is one")
    ok(Palette.paperRGB({ 255, 255, 255 }) == nil and Palette.paperRGB(nil) == nil and Palette.paperRGB("x") == nil
        and Palette.paperRGB({ 1, 2 }) == nil and Palette.paperRGB({ 300, 0, 0 }) == nil,
        "papers: white, nothing and what is not a colour are white")
    ok(Palette.paperName(nil) == "White" and Palette.paperName(paperOf("sand")) == "Sandpaper"
        and Palette.paperName({ 1, 2, 3 }) == "Custom", "papers: their names")
    -- every paper's ruling shows on it, at a faint, the default and a full strength,
    -- in colour and once a grey screen has turned both to greys
    for _i, p in ipairs(all) do
        for _j, s in ipairs({ 5, 45, 100 }) do
            local lvl = Paint.strengthToLevel(s)
            local want = 255 - lvl
            local rule = rgbOf(Paint.rulingRGB(Palette.paperRGB(p.rgb), s))
            local paper = rgbOf(p.rgb)
            local d = math.abs(lum(rule) - lum(paper))
            ok(d >= 0.6 * want, ("ruling: on %s at strength %d it stands out (%d of %d)"):format(p.key, s, d, want))
            local g = BB.new(2, 1, BB.TYPE_BB8)
            g:paintRect(0, 0, 1, 1, BB.ColorRGB32(p.rgb[1], p.rgb[2], p.rgb[3], 0xFF))
            g:paintRect(1, 0, 1, 1, BB.ColorRGB32(rule.r, rule.g, rule.b, 0xFF))
            local gd = math.abs(px(g, 0, 0).r - px(g, 1, 0).r)
            ok(gd >= 0.55 * want, ("ruling: on %s at %d, in grey too (%d of %d)"):format(p.key, s, gd, want))
            g:free()
        end
        local dark = Paint.darkPaper(Palette.paperRGB(p.rgb))
        ok((Paint.inkOn(Palette.paperRGB(p.rgb)) == BB.COLOR_WHITE) == dark,
            "text: white on " .. p.key .. " exactly when it is dark")
    end
    local r = Paint.rulingRGB(nil, 45)
    local lvl = Paint.strengthToLevel(45)
    ok(r[1] == lvl and r[2] == lvl and r[3] == lvl, "ruling: on white, the grey it always was")
end

-- ---- on the page ---------------------------------------------------------------
local function newView(typ, nb)
    local W, H = 1072, 1448
    Device.screen.bb = BB.new(W, H, typ)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    view._instant_colour = false
    if nb then view:startNotebook({ style = "lines", size = 40, strength = 45 }) end
    return view
end

for _i, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    local colour = typ == BB.TYPE_BBRGB32
    local papers = colour and { "sand", "kraft", "blueprint", "black" } or { "black" }
    for _j, nb in ipairs({ false, true }) do
        for _k, key in ipairs(papers) do
            local tag = ("%s %s %s"):format(colour and "colour" or "grey", nb and "notebook" or "drawing", key)
            local view = newView(typ, nb)
            local v = view.view
            local p = paperOf(key)
            local want = shown(typ, p)
            view.pen_color = { 0, 0, 0 }
            view:setPaper(p)
            ok(Palette.sameColor(view:paperRGB(), p), tag .. ": the document is on it")
            ok(Palette.sameColor(G_reader_settings.data.inkaway_paper, p), tag .. ": and new documents start on it")
            -- a spot between ruled lines (lines every 40 px)
            local cx, cy = 500, 1000 + 20
            ok(near(px(view.canvas_bb, cx, cy), want), tag .. ": the page shows the paper")
            local dark = Paint.darkPaper(p)
            ok(Palette.sameColor(view.pen_color, { 0, 0, 0 }), tag .. ": the pen stays black")
            ok((view:textInk() == BB.COLOR_WHITE) == dark, tag .. ": the text colour")
            -- the ruling of a notebook in the paper's shade
            if nb then
                local rule = Paint.rulingRGB(p, 45)
                local found
                for y = 990, 1060 do
                    local c = px(view.canvas_bb, cx, y)
                    if not near(c, want, 3) then found = c; break end
                end
                ok(found and near(found, shown(typ, rule), 3), tag .. ": the ruling is in the paper's shade")
            end
            -- ink, then a saved erase over it, and a hard one: the paper comes back
            view.canvas:setOps({
                { kind = "ink", width = 30, alpha = 255, pts = { 200, 520, 900, 520 } },
                { kind = "erase", width = 40, pts = { 300, 520, 400, 520 } },
                { kind = "erase", width = 40, ebg = true, pts = { 600, 520, 700, 520 } },
            })
            view:composeCanvas()
            local ink_at = px(view.canvas_bb, 250, 520)
            ok(not near(ink_at, want, 20), tag .. ": the ink shows on it")
            ok(near(ink_at, dark and { r = 255, g = 255, b = 255 } or { r = 0, g = 0, b = 0 }),
                tag .. (dark and ": black ink shows white on it" or ": black ink is black"))
            -- a stroke drawn now with the black pen too
            view:setTool("pen"); view.pen_width = 10
            local function at0(x, y) return { pos = { x = v.area_x + (x - v.pan_x) * v.zoom, y = v.area_y + (y - v.pan_y) * v.zoom } } end
            view:onIaTouch(nil, at0(200, 760))
            for x = 220, 400, 20 do view:onIaPan(nil, at0(x, 760)) end
            view:onIaPanRelease(nil, at0(400, 760)); view:flushPending()
            ok(near(px(view.canvas_bb, 300, 760), dark and { r = 255, g = 255, b = 255 } or { r = 0, g = 0, b = 0 }),
                tag .. ": the black pen writes " .. (dark and "white" or "black") .. " on it")
            ok(near(px(view.canvas_bb, 350, 521), nb and px(view._paper_bb, 350, 521) or want),
                tag .. ": a saved erase reveals the paper")
            ok(near(px(view.canvas_bb, 650, 521), nb and px(view._paper_bb, 650, 521) or want),
                tag .. ": a hard erase reveals the paper")
            -- the live eraser
            view:renderView()
            view:setTool("erase")
            view.erase_whole, view.erase_bg = false, false
            view.eraser_width = 30
            local function at(x, y) return { pos = { x = v.area_x + (x - v.pan_x) * v.zoom, y = v.area_y + (y - v.pan_y) * v.zoom } } end
            view:onIaTouch(nil, at(780, 520))
            for x = 790, 860, 10 do view:onIaPan(nil, at(x, 520)) end
            view:onIaPanRelease(nil, at(860, 520)); view:flushPending()
            ok(near(px(view.canvas_bb, 820, 521), nb and px(view._paper_bb, 820, 521) or want),
                tag .. ": the eraser reveals the paper as it goes")
            -- the drawing grid in the paper's shade
            if not nb then
                view.grid_on, view.grid_style, view.grid_size, view.grid_strength = true, "lines", 40, 45
                local sb = Device.screen.bb
                sb:fill(BB.COLOR_WHITE)
                view:drawGrid(sb, 0, 0)
                local gy = math.floor((40 - v.pan_y) * v.zoom)
                local c = px(sb, 300, gy)
                ok(near(c, shown(typ, Paint.rulingRGB(p, 45)), 3), tag .. ": the grid is in the paper's shade")
                view.grid_on = false
            end
            -- exports lay the page on the paper
            local eo = view:exportOptions()
            eo.transparent = false
            local buf = Export.buildPNGRGBA(view.canvas, view:pngOptions())
            local W = view.canvas.w
            local function at4(b, x, y) local o = (y * W + x) * 4; return { r = b[o], g = b[o + 1], b = b[o + 2], a = b[o + 3] } end
            local c = at4(buf, 20, 20)
            ok(near(c, rgbOf(p)) and c.a == 255, tag .. ": a PNG on the page is on the paper")
            ok(near(at4(buf, 350, 521), nb and at4(buf, 350, 521) or rgbOf(p)), tag .. ": an erase in it shows the paper")
            eo.transparent = true
            buf = Export.buildPNGRGBA(view.canvas, view:pngOptions())
            ok(at4(buf, 20, 20).a == 0, tag .. ": a transparent PNG is clear")
            eo.transparent = false
            local t = nb and view:exportTemplate(1) or view:drawingPaperTemplate()
            local rgb = Export.buildJPEGRGB(view.canvas, { template = t })
            local function at3(x, y) local o = (y * W + x) * 3; return { r = rgb[o], g = rgb[o + 1], b = rgb[o + 2] } end
            ok(near(at3(20, cy), rgbOf(p)), tag .. ": a PDF page is on the paper")
            ok(near(at3(250, 520), dark and { r = 255, g = 255, b = 255 } or { r = 0, g = 0, b = 0 }),
                tag .. ": black ink in it is " .. (dark and "white" or "black") .. ", as on the screen")
            ok(near(at3(350, 521), nb and at3(350, 521) or rgbOf(p)), tag .. ": with the erase showing it")
            if nb then
                local found
                for y = 990, 1060 do
                    local q = at3(cx, y)
                    if not near(q, rgbOf(p), 3) then found = q; break end
                end
                ok(found and near(found, rgbOf(Paint.rulingRGB(p, 45)), 2), tag .. ": the PDF's ruling is in the paper's shade")
            end
            -- White for the export: a light paper prints on white, a dark one never
            eo.on_paper = "white"
            t = nb and view:exportTemplate(1) or view:drawingPaperTemplate()
            rgb = Export.buildJPEGRGB(view.canvas, { template = t })
            ok(near(at3(20, cy), dark and rgbOf(p) or { r = 255, g = 255, b = 255 }),
                tag .. (dark and ": a dark paper prints as it is, even set to White" or ": set to White it prints on white"))
            eo.on_paper = "page"
            -- text in an export: its ink over the paper
            Export.text_raster = function(op)
                local w, h = op.w, op.h
                local b = ffi.new("uint8_t[?]", w * h)
                ffi.fill(b, w * h, 0)
                return b, w, h
            end
            view.canvas:setOps({ { kind = "text", x = 100, y = 1200, w = 50, h = 20, text = "x" } })
            rgb = Export.buildJPEGRGB(view.canvas, { template = nb and view:exportTemplate(1) or view:drawingPaperTemplate() })
            local tp = at3(110, 1205)
            ok(near(tp, dark and { r = 255, g = 255, b = 255 } or { r = 0, g = 0, b = 0 }),
                tag .. ": exported text is " .. (dark and "white" or "black"))
            Export.text_raster = function(op) return view:exportTextRaster(op) end
            view.canvas:setOps({})   -- (no fonts here to draw the text on the page)
            -- a thumbnail of a drawing is on its paper
            if not nb then
                local scratch = BB.new(W, view.canvas.h, typ)
                view:composeInto(scratch, { { kind = "ink", width = 10, alpha = 255, pts = { 100, 100, 500, 100 } },
                    { kind = "erase", width = 30, pts = { 200, 100, 300, 100 } } }, nil, { style = "blank", paper = p })
                ok(near(px(scratch, 20, 20), want) and near(px(scratch, 250, 101), want),
                    tag .. ": a thumbnail is on the paper, an erase too")
                scratch:free()
            end
            -- back to white: the pen turns back, the paper goes
            view:setPaper(nil)
            ok(view:paperRGB() == nil and near(px(view.canvas_bb, 20, 20), { r = 255, g = 255, b = 255 }),
                tag .. ": back on white")
            ok(Palette.sameColor(view.pen_color, { 0, 0, 0 }), tag .. ": with a black pen")
            view:onCloseWidget()
        end
    end
end

-- the fill sees white ink on a black paper
do
    local Canvas = require("ink/canvas")
    local c = Canvas.new(400, 400)
    c:setOps({ { kind = "shape", shape = "rect", fill = false, width = 6, alpha = 255, color = { 255, 255, 255 },
        pts = { 100, 100, 300, 300 } } })
    local g = Export.buildGray(c, 0)
    local runs = Fill.compute(g, 400, 400, 200, 200, 40)
    local n = 0
    for i = 3, #runs, 3 do n = n + runs[i] end
    ok(runs and n > 0 and n < 200 * 200, ("fill: white ink bounds an area on black paper (%d px)"):format(n))
    ok(g[0] == 0, "fill: the paper is black in its map")
end

print(("realbb paper: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
