-- Headless tests for the pure core (geom, raster, canvas, export buffers).
-- Run from the plugin root with:  luajit tests/core.lua
-- Needs only LuaJIT + FFI; no KOReader, no native image libraries.

package.path = "./?.lua;" .. package.path

local Geom = require("ink/geom")
local Raster = require("ink/raster")
local Canvas = require("ink/canvas")
local Export = require("ink/export")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function near(a, b, what, eps)
    eps = eps or 1e-6
    ok(math.abs(a - b) <= eps, ("%s (got %s, want %s)"):format(what, tostring(a), tostring(b)))
end

------------------------------------------------------------------------------
-- geom: viewport transforms
------------------------------------------------------------------------------
do
    local view = { area_x = 0, area_y = 100, area_w = 600, area_h = 700,
                   zoom = 2, pan_x = 50, pan_y = 30, canvas_w = 600, canvas_h = 800 }
    local cx, cy = Geom.toCanvas(view, 0 + 0, 100 + 0)
    near(cx, 50, "toCanvas x at area origin -> pan_x")
    near(cy, 30, "toCanvas y at area origin -> pan_y")
    -- there and back
    local sx, sy = Geom.toScreen(view, 123, 210)
    local rx, ry = Geom.toCanvas(view, sx, sy)
    near(rx, 123, "screen<->canvas there and back, x")
    near(ry, 210, "screen<->canvas there and back, y")
    -- fit zoom: area 600x700 into canvas 600x800 -> limited by height
    near(Geom.fitZoom(view), 700 / 800, "fitZoom limited by height")
end

------------------------------------------------------------------------------
-- geom: clampPan centres when canvas smaller than visible window
------------------------------------------------------------------------------
do
    local view = { area_x = 0, area_y = 0, area_w = 600, area_h = 800,
                   zoom = 0.5, pan_x = 999, pan_y = -999, canvas_w = 600, canvas_h = 800 }
    -- visible window = 1200x1600 canvas px, larger than canvas -> centred (negative)
    Geom.clampPan(view)
    near(view.pan_x, (600 - 1200) / 2, "clampPan centres x when zoomed out")
    near(view.pan_y, (800 - 1600) / 2, "clampPan centres y when zoomed out")

    local v2 = { area_x = 0, area_y = 0, area_w = 600, area_h = 800,
                 zoom = 2, pan_x = 999, pan_y = -50, canvas_w = 600, canvas_h = 800 }
    -- visible window = 300x400; pan clamped into [0, canvas - vis]
    Geom.clampPan(v2)
    near(v2.pan_x, 600 - 300, "clampPan clamps x to right edge")
    near(v2.pan_y, 0, "clampPan clamps y to top edge")
end

------------------------------------------------------------------------------
-- geom: bounds / mergeRect / clipRect
------------------------------------------------------------------------------
do
    local x0, y0, x1, y1 = Geom.bounds({ 10, 20, 5, 40, 30, 15 })
    ok(x0 == 5 and y0 == 15 and x1 == 30 and y1 == 40, "bounds min/max")
    ok(Geom.bounds({}) == nil, "bounds of empty is nil")

    local r = Geom.mergeRect({ x = 0, y = 0, w = 10, h = 10 }, { x = 5, y = 5, w = 10, h = 10 })
    ok(r.x == 0 and r.y == 0 and r.w == 15 and r.h == 15, "mergeRect union")
    ok(Geom.mergeRect(nil, r) == r, "mergeRect nil passthrough")

    local cx, cy, cw, ch = Geom.clipRect(-5, -5, 20, 20, 10, 10)
    ok(cx == 0 and cy == 0 and cw == 10 and ch == 10, "clipRect clamps to bounds")
    ok(Geom.clipRect(100, 100, 5, 5, 10, 10) == nil, "clipRect fully outside is nil")
end

------------------------------------------------------------------------------
-- geom: rdp keeps a corner, drops collinear midpoints
------------------------------------------------------------------------------
do
    -- straight horizontal line with a redundant midpoint -> collapses to 2 pts
    local line = Geom.rdp({ 0, 0, 5, 0, 10, 0 }, 0.75)
    ok(#line == 4, "rdp collapses collinear points")
    -- an L shape keeps the corner
    local corner = Geom.rdp({ 0, 0, 10, 0.1, 10, 10 }, 0.75)
    ok(#corner == 6, "rdp keeps a real corner")
    -- dropClose removes samples that sit almost on top of each other
    local dc = Geom.dropClose({ 0, 0, 0.1, 0, 5, 0 }, 1.5)
    ok(#dc == 4, "dropClose removes tightly spaced midpoint")
end

------------------------------------------------------------------------------
-- raster: disc spans are symmetric and cover the centre row
------------------------------------------------------------------------------
do
    local rows = {}
    Raster.disc(10, 10, 3, function(x, y, len) rows[y] = { x = x, len = len } end)
    ok(rows[10] ~= nil, "disc covers centre row")
    ok(rows[10].len >= rows[7].len, "disc centre row is widest")
    -- centre span symmetric about cx=10
    local c = rows[10]
    near(c.x + (c.len - 1) / 2, 10, "disc centre span symmetric")

    -- a path of one point stamps a dot (>=1 span)
    local count = 0
    Raster.path({ 4, 4 }, 1, function() count = count + 1 end)
    ok(count >= 1, "a path of one point stamps a dot")
end

------------------------------------------------------------------------------
-- canvas: stroke lifecycle + undo
------------------------------------------------------------------------------
do
    local c = Canvas.new(600, 800)
    ok(c:isEmpty(), "new canvas is empty")
    c:startStroke("ink", 4)
    c:addPoint(10, 10); c:addPoint(10, 10)  -- duplicate dropped
    c:addPoint(50, 10); c:addPoint(90, 10)
    local op = c:finishStroke()
    ok(op ~= nil and op.kind == "ink", "finishStroke commits an ink op")
    ok(c:opCount() == 1, "one op committed")
    local r = c:opRect(op)
    ok(r.x < 10 and r.w > 80, "opRect covers the stroke plus half its width")

    c:startStroke("erase", 20)
    c:addPoint(50, 10)
    c:finishStroke()
    ok(c:opCount() == 2, "erase committed as its own op")

    ok(c:undo() == true and c:opCount() == 1, "undo removes the last op (the erase)")
    ok(c.ops[1].kind == "ink", "the ink op remains after undo")
    ok(c:redo() == true and c:opCount() == 2, "redo brings the erase back")
    ok(c.ops[2].kind == "erase", "redone op is the erase")
    c:undo(); c:undo()
    ok(c:isEmpty(), "undo back to empty")
    ok(c:undo() == false, "undo on empty returns false")

    -- a new op after an undo clears the redo stack
    c:redo()                              -- back to one ink op
    ok(c:opCount() == 1, "redo restores one op")
    c:undo()                              -- empty again, redo available
    c:startStroke("ink", 4); c:addPoint(1, 1); c:addPoint(9, 9); c:finishStroke()
    ok(not c:canRedo(), "a fresh op forks history and clears redo")

    -- empty stroke commits nothing and does not touch history
    c:startStroke("ink", 4)
    ok(c:finishStroke() == nil, "empty stroke commits nothing")
end

------------------------------------------------------------------------------
-- canvas: mixed history -- O(1) append entries interleaved with a snapshot edit
------------------------------------------------------------------------------
do
    local c = Canvas.new(400, 400)
    local function ink(tag)
        c:startStroke("ink", 4); c:addPoint(1, 1); c:addPoint(20, 20)
        local o = c:finishStroke(); o.tag = tag; return o
    end
    local A = ink("A"); ink("B")
    ok(c:opCount() == 2, "two appended ops")
    -- an in-place edit (colour/size/move) checkpoints with a snapshot, then swaps
    c:pushHistory()
    local A2 = c:cloneOp(A); A2.tag = "A*"; c:replaceOp(1, A2)
    ok(c.ops[1].tag == "A*" and c.ops[2].tag == "B", "edit replaced A in place")
    ok(c:undo() and c.ops[1].tag == "A" and c.ops[2].tag == "B", "undo reverts the in-place edit")
    ok(c:undo() and c:opCount() == 1 and c.ops[1].tag == "A", "undo removes appended B")
    ok(c:undo() and c:opCount() == 0, "undo removes appended A")
    ok(c:undo() == false, "nothing left to undo")
    ok(c:redo() and c.ops[1].tag == "A", "redo re-appends A")
    ok(c:redo() and c.ops[2].tag == "B", "redo re-appends B")
    ok(c:redo() and c.ops[1].tag == "A*", "redo re-applies the in-place edit")
    ok(not c:canRedo(), "redo exhausted")
    c:undo()                              -- undo the edit; a redo is now available
    ok(c:canRedo(), "an undone edit leaves a redo")
    ink("C")                              -- a fresh op forks history
    ok(not c:canRedo(), "a fresh append clears redo after a snapshot undo")
    -- clear() is a snapshot checkpoint and is undoable
    local before = c:opCount()
    c:clear()
    ok(c:opCount() == 0, "clear empties the ops")
    ok(c:undo() and c:opCount() == before, "undo restores a cleared canvas")
end

------------------------------------------------------------------------------
-- export: TRUE transparency + exact dimensions (the critical requirement)
------------------------------------------------------------------------------
do
    local W, H = 40, 30
    local c = Canvas.new(W, H)
    c:startStroke("ink", 6)
    c:addPoint(5, 15); c:addPoint(35, 15)  -- horizontal line across the middle
    c:finishStroke()

    local buf, n = Export.buildRGBA(c)
    ok(n == W * H * 4, "RGBA buffer is exactly W*H*4 bytes")

    -- a corner far from the ink must be fully transparent
    local function px(x, y) local o = (y * W + x) * 4; return buf[o], buf[o+1], buf[o+2], buf[o+3] end
    local _, _, _, a_corner = px(0, 0)
    ok(a_corner == 0, "untouched corner has alpha = 0 (transparent)")
    local _, _, _, a_corner2 = px(W-1, 0)
    ok(a_corner2 == 0, "untouched top right has alpha = 0")

    -- the centre of the line must be opaque black
    local r, g, b, a = px(20, 15)
    ok(a == 255 and r == 0 and g == 0 and b == 0, "ink pixel is opaque black")

    -- count transparent vs opaque: most of a 40x30 canvas with a thin line is clear
    local clear, opaque = 0, 0
    for y = 0, H - 1 do for x = 0, W - 1 do
        local _, _, _, aa = px(x, y)
        if aa == 0 then clear = clear + 1 else opaque = opaque + 1 end
    end end
    ok(clear > opaque, "most of the canvas is transparent")
    ok(opaque > 0, "some ink was drawn")
end

------------------------------------------------------------------------------
-- export: erase truly clears alpha, and undo (op removal) restores ink
------------------------------------------------------------------------------
do
    local W, H = 40, 30
    local c = Canvas.new(W, H)
    c:startStroke("ink", 10)
    c:addPoint(5, 15); c:addPoint(35, 15)
    c:finishStroke()
    c:startStroke("erase", 12)
    c:addPoint(20, 15)  -- erase a bite out of the middle
    c:finishStroke()

    local buf = Export.buildRGBA(c)
    local function alpha(x, y) return buf[(y * W + x) * 4 + 3] end
    ok(alpha(20, 15) == 0, "erased pixel is transparent again (alpha 0)")
    ok(alpha(6, 15) == 255, "ink outside the erase remains opaque")

    -- simulate undo of the erase: drop last op and rebuild
    c:undo()
    local buf2 = Export.buildRGBA(c)
    ok(buf2[(15 * W + 20) * 4 + 3] == 255, "undoing the erase restores the ink")
end

------------------------------------------------------------------------------
-- export: the eraser reveals the notebook ruling, not blank paper (matches
-- the on-screen behaviour, where the ruling lives in the erase-reveal buffer)
------------------------------------------------------------------------------
do
    local W, H = 40, 30
    local tmpl = { style = "lines", size = 10 }   -- rulings at y = 10, 20
    local c = Canvas.new(W, H)
    c:startStroke("ink", 6)
    c:addPoint(5, 10); c:addPoint(35, 10)         -- ink laid over the y=10 ruling
    c:finishStroke()
    c:startStroke("erase", 8)
    c:addPoint(20, 10)                            -- erase a bite over the ruling
    c:finishStroke()

    -- a plain (non-sparing) erase: ink gone, but the ruling underneath survives
    local rgb = Export.buildRGB(c, nil, tmpl)
    local function g(x, y) return rgb[(y * W + x) * 3] end
    ok(g(20, 10) >= 190 and g(20, 10) <= 225, "erased spot on a ruling shows the grey ruling, not blank paper")
    ok(g(6, 10) < 80, "ink outside the erase is still there")

    -- an erase drawn while text was protected keeps its flag; the ruling still
    -- survives (spare vs non-spare only differs for text, which needs no fonts here)
    c.ops[2].spare_text = true
    local rgb2 = Export.buildRGB(c, nil, tmpl)
    ok(rgb2[(10 * W + 20) * 3] >= 190 and rgb2[(10 * W + 20) * 3] <= 225,
        "a text-sparing erase also reveals the ruling in export")
end

------------------------------------------------------------------------------
-- export: JPEG buffer is white background + black ink, exact size
------------------------------------------------------------------------------
do
    local W, H = 20, 20
    local c = Canvas.new(W, H)
    c:startStroke("ink", 4)
    c:addPoint(2, 10); c:addPoint(18, 10)
    c:finishStroke()
    local buf, n = Export.buildRGB(c)
    ok(n == W * H * 3, "RGB buffer is exactly W*H*3 bytes")
    local function rgb(x, y) local o = (y * W + x) * 3; return buf[o], buf[o+1], buf[o+2] end
    local r0, g0, b0 = rgb(0, 0)
    ok(r0 == 255 and g0 == 255 and b0 == 255, "JPEG background is white")
    local r1, g1, b1 = rgb(10, 10)
    ok(r1 == 0 and g1 == 0 and b1 == 0, "JPEG ink is black")
end

------------------------------------------------------------------------------
-- export: pen opacity carries into the alpha channel (PNG) and to a matching
-- grey composited over white (JPEG); default stroke is fully opaque
------------------------------------------------------------------------------
do
    local W, H = 20, 20
    local c = Canvas.new(W, H)
    c:startStroke("ink", 8, 128)          -- ink at half opacity
    c:addPoint(2, 10); c:addPoint(18, 10)
    c:finishStroke()
    local rgba = Export.buildRGBA(c)
    ok(rgba[(10 * W + 10) * 4 + 3] == 128, "part transparent pen -> alpha 128 in PNG")
    ok(rgba[(10 * W + 10) * 4] == 0, "part transparent pen stays black rgb in PNG")
    local rgb = Export.buildRGB(c)
    ok(rgb[(10 * W + 10) * 3] == 255 - 128, "part transparent pen -> grey 127 over white in JPEG")

    local c2 = Canvas.new(W, H)
    c2:startStroke("ink", 8)              -- no alpha given
    c2:addPoint(2, 10); c2:addPoint(18, 10)
    local op = c2:finishStroke()
    ok(op.alpha == 255, "default stroke is fully opaque")
    ok(Export.buildRGBA(c2)[(10 * W + 10) * 4 + 3] == 255, "default pen -> alpha 255 in PNG")
end

------------------------------------------------------------------------------
-- export: a coloured pen carries its rgb into the PNG, and over white in JPEG
------------------------------------------------------------------------------
do
    local W, H = 20, 20
    local c = Canvas.new(W, H)
    c:startStroke("ink", 8, 255, { 0xD0, 0x00, 0x00 })   -- opaque red
    c:addPoint(2, 10); c:addPoint(18, 10)
    c:finishStroke()
    local rgba = Export.buildRGBA(c)
    local o = (10 * W + 10) * 4
    ok(rgba[o] == 0xD0 and rgba[o+1] == 0 and rgba[o+2] == 0 and rgba[o+3] == 255,
        "opaque red pen -> red opaque pixel in PNG")

    local c2 = Canvas.new(W, H)
    c2:startStroke("ink", 8, 128, { 0x00, 0x00, 0xFF })  -- half-opacity blue
    c2:addPoint(2, 10); c2:addPoint(18, 10)
    c2:finishStroke()
    local rgb = Export.buildRGB(c2)
    local p = (10 * W + 10) * 3
    -- blue over white at 50%: R,G -> ~255-128 = 127; B stays 255
    ok(rgb[p] == 255 - 128 and rgb[p+1] == 255 - 128 and rgb[p+2] == 255,
        "half-opacity blue over white -> light blue in JPEG")
end

------------------------------------------------------------------------------
-- shapes: filled vs outline, and they export like any other op
------------------------------------------------------------------------------
do
    local W, H = 40, 30
    local c = Canvas.new(W, H)
    local op = c:addShape("rect", true, { 10, 8, 30, 22 }, 4, 255, { 0, 0, 0 })
    ok(op.kind == "shape" and op.shape == "rect", "addShape commits a shape op")
    ok(c:opCount() == 1, "shape counts as one op")
    local buf = Export.buildRGBA(c)
    local function a(x, y) return buf[(y * W + x) * 4 + 3] end
    ok(a(20, 15) == 255, "filled rectangle interior is opaque")
    ok(a(2, 2) == 0, "outside the rectangle is transparent")

    local c2 = Canvas.new(W, H)
    c2:addShape("rect", false, { 10, 8, 30, 22 }, 3, 255, { 0, 0, 0 })
    local buf2 = Export.buildRGBA(c2)
    local function a2(x, y) return buf2[(y * W + x) * 4 + 3] end
    ok(a2(20, 15) == 0, "unfilled rectangle centre is empty")
    ok(a2(10, 15) > 0, "unfilled rectangle has a drawn edge")

    -- ellipse fill stays inside its box corners
    local c3 = Canvas.new(W, H)
    c3:addShape("ellipse", true, { 10, 5, 30, 25 }, 3, 255, { 0, 0, 0 })
    local buf3 = Export.buildRGBA(c3)
    ok(buf3[(15 * W + 20) * 4 + 3] == 255, "filled ellipse centre is opaque")
    ok(buf3[(6 * W + 11) * 4 + 3] == 0, "ellipse leaves its bounding corner clear")

    -- a curve carries its control point and draws something
    local c4 = Canvas.new(W, H)
    c4:addShape("curve", false, { 4, 25, 36, 25, 20, 4 }, 4, 255, { 0, 0, 0 })
    local drawn = 0
    local b4 = Export.buildRGBA(c4)
    for i = 0, W * H - 1 do if b4[i * 4 + 3] > 0 then drawn = drawn + 1 end end
    ok(drawn > 0, "curve draws ink")
end

------------------------------------------------------------------------------
-- flood fill: fills an enclosed area and does not leak outside it
------------------------------------------------------------------------------
do
    local Fill = require("ink/fill")
    local W, H = 40, 30
    local c = Canvas.new(W, H)
    c:addShape("rect", false, { 8, 6, 32, 24 }, 3, 255, { 0, 0, 0 })  -- hollow box
    local gray = Export.buildGray(c)
    ok(gray[15 * W + 20] == 255, "inside the box is white before filling")
    local runs = Fill.compute(gray, W, H, 20, 15, 40)
    ok(runs ~= nil and #runs > 0, "fill finds the enclosed region")
    c:addFillOp(runs, { 0x88, 0x88, 0x88 }, 255)
    local rgba = Export.buildRGBA(c)
    ok(rgba[(15 * W + 20) * 4 + 3] == 255, "interior is opaque after fill")
    ok(rgba[(15 * W + 20) * 4] == 0x88, "interior takes the fill colour")
    ok(rgba[(1 * W + 1) * 4 + 3] == 0, "outside the box stays transparent (no leak)")
end

------------------------------------------------------------------------------
-- project: serialize / deserialize round-trip keeps the ops
------------------------------------------------------------------------------
do
    local Project = require("ink/project")
    local c = Canvas.new(300, 400)
    c:startStroke("ink", 8, 200, { 0xD0, 0, 0 }, "charcoal", 12345)
    c:addPoint(10, 10); c:addPoint(60, 40); c:finishStroke()
    c:addShape("rect", true, { 20, 20, 80, 90 }, 6, 255, { 0, 0, 0 })
    c:addFillOp({ 5, 5, 10 }, { 0x88, 0x88, 0x88 }, 128)

    local str = Project.serialize(c)
    ok(type(str) == "string" and #str > 0, "serialize produces a string")
    local data = Project.deserialize(str)
    ok(data and data.w == 300 and data.h == 400, "deserialize keeps dimensions")
    ok(#data.ops == 3, "all ops round-trip")
    ok(data.ops[1].style == "charcoal" and data.ops[1].seed == 12345, "stroke style/seed kept")
    ok(data.ops[1].color[1] == 0xD0, "stroke colour kept")
    ok(data.ops[2].shape == "rect" and data.ops[2].fill == true, "shape kept")
    ok(data.ops[3].kind == "fill" and #data.ops[3].runs == 3, "fill runs kept")
    -- a tampered/garbage string fails cleanly
    ok(Project.deserialize("os.exit()") == nil, "non-project string rejected")
end

------------------------------------------------------------------------------
-- geom: stabilizer and snapping
------------------------------------------------------------------------------
do
    ok(Geom.stabilizerAlpha(0) == 1, "stabilizer 0 = no smoothing")
    ok(Geom.stabilizerAlpha(100) < 0.15, "stabilizer 100 = heavy smoothing")
    local sx, sy = Geom.ema(0, 0, 10, 0, 0.5)
    near(sx, 5, "ema moves halfway at alpha 0.5"); near(sy, 0, "ema y stays")
    local gx, gy = Geom.snapToGrid(70, 41, 32)
    ok(gx == 64 and gy == 32, "snapToGrid rounds to nearest intersection")
    local ax, ay = Geom.snapAngle(0, 0, 10, 1)   -- nearly horizontal -> snaps to 0deg
    near(ay, 0, "snapAngle flattens a near-horizontal segment")
    near(ax, math.sqrt(101), "snapAngle keeps the length", 1e-3)
end

------------------------------------------------------------------------------
-- raster: grain is deterministic (same pixels every render)
------------------------------------------------------------------------------
do
    local st = { density = 0.5, edge = 0.2 }
    local a, b = {}, {}
    local function collect(t) return function(x, y, l) t[#t + 1] = x .. "," .. y end end
    Raster.discTex(20, 20, 6, collect(a), st, 777)
    Raster.discTex(20, 20, 6, collect(b), st, 777)
    ok(#a > 0 and #a == #b, "grain produces the same count with the same seed")
    local same = true
    for i = 1, #a do if a[i] ~= b[i] then same = false break end end
    ok(same, "grain is stable across renders (no flicker, export matches screen)")
    local d = {}
    Raster.discTex(20, 20, 6, collect(d), st, 778)   -- different seed
    ok(#d ~= #a or d[1] ~= a[1], "a different seed gives different grain")
    -- a textured brush inks a fraction of a solid disc: some gaps, but dark
    local pcn, sn = 0, 0
    Raster.discTex(30, 30, 10, function(_, _, l) pcn = pcn + (l or 1) end, Raster.STYLES.pencil, 5)
    Raster.disc(30, 30, 10, function(_, _, l) sn = sn + (l or 1) end)
    ok(pcn > 0 and pcn < sn, "pencil is textured (fewer pixels than a solid disc)")
    ok(pcn > sn * 0.5, "pencil is still dark (covers most of the disc)")
end

------------------------------------------------------------------------------
-- symmetry: the span wrapper mirrors exactly, and an op's sym replays mirrored
------------------------------------------------------------------------------
do
    local Symmetry = require("ink/symmetry")
    local refx, refy = Symmetry.canvasRefs(40, 30)
    local got
    local function put(x, y, len) got[#got + 1] = { x, y, len } end

    got = {}
    Symmetry.wrap(put, "vert", refx, refy)(0, 5, 4)
    ok(#got == 2, "vertical wrap emits the original plus one mirror")
    ok(got[2][1] == 36 and got[2][2] == 5 and got[2][3] == 4, "vertical mirror reflects the x span exactly")

    got = {}
    Symmetry.wrap(put, "horiz", refx, refy)(2, 0, 3)
    ok(got[2][1] == 2 and got[2][2] == 29, "horizontal mirror reflects the row to H-1-y")

    got = {}
    Symmetry.wrap(put, "quad", refx, refy)(1, 1, 2)
    ok(#got == 4, "four way wrap emits four spans")
    ok(Symmetry.wrap(put, "off", refx, refy) == put, "off is a no-op wrapper (no cost)")

    -- end to end: an ink op tagged sym="vert" comes out mirrored in the export
    local W, H = 40, 30
    local c = Canvas.new(W, H)
    c:startStroke("ink", 6); c:addPoint(5, 15); c:addPoint(6, 15)
    local op = c:finishStroke(); op.sym = "vert"
    local buf = Export.buildRGBA(c)
    local function A(x, y) return buf[(y * W + x) * 4 + 3] end
    ok(A(5, 15) > 0, "symmetric stroke draws the drawn side")
    ok(A(34, 15) > 0, "symmetric stroke mirrors to the far side (40-1-5)")
end

------------------------------------------------------------------------------
-- arrows: a line with an arrowhead draws more than a plain line
------------------------------------------------------------------------------
do
    local Shapes = require("ink/shapes")
    local function count(op)
        local n = 0
        Shapes.render(op, function(_, _, l) n = n + (l or 1) end)
        return n
    end
    local plain = { kind = "shape", shape = "line", fill = false, width = 4, pts = { 5, 15, 35, 15 } }
    local arrow = { kind = "shape", shape = "line", fill = false, width = 4,
                    arrow = "end", head = 10, pts = { 5, 15, 35, 15 } }
    ok(count(arrow) > count(plain), "an arrow draws more ink than a plain line (the head)")
    local dbl = { kind = "shape", shape = "line", fill = false, width = 4,
                  arrow = "both", head = 10, pts = { 5, 15, 35, 15 } }
    ok(count(dbl) > count(arrow), "a double arrow draws more than a single arrow")
    local x0, y0, x1, y1 = Shapes.bounds(arrow)
    ok(y0 < 15 or y1 > 15, "the arrowhead pushes the bounds off the line")
end

------------------------------------------------------------------------------
-- export: a crop rectangle yields a smaller image with the right pixels
------------------------------------------------------------------------------
do
    local W, H = 40, 30
    local c = Canvas.new(W, H)
    c:startStroke("ink", 4); c:addPoint(5, 15); c:addPoint(35, 15); c:finishStroke()
    local rect = { x = 10, y = 10, w = 12, h = 8 }
    local buf, n, ow, oh = Export.buildRGBA(c, rect)
    ok(ow == 12 and oh == 8 and n == 12 * 8 * 4, "cropped export is exactly the crop size")
    -- canvas (16,15) maps to crop local (6,5); the line at y=15 is inside -> inked
    ok(buf[((15 - 10) * 12 + (16 - 10)) * 4 + 3] > 0, "crop keeps the ink inside it")
end

------------------------------------------------------------------------------
-- brushes: making, listing, persisting, reloading and removing a user brush
------------------------------------------------------------------------------
do
    local Brushes = require("ink/brushes")
    local store = {}
    local function get(k) return store[k] end
    local function set(k, v) store[k] = v end
    local key = Brushes.save(get, set, "My Pen", { density = 0.6, cell = 2 })
    ok(key == "user:My Pen", "save returns the style key")
    ok(Raster.STYLES["user:My Pen"] ~= nil, "a saved brush is registered in the rasterizer")
    local found = false
    for _, m in ipairs(Brushes.menu(get)) do if m.key == key then found = true end end
    ok(found, "a saved brush appears in the pen menu")
    ok(#Brushes.userList(get) == 1, "the brush is stored in settings")
    -- a fresh session: loadAll re-registers from the stored settings
    Raster.STYLES["user:My Pen"] = nil
    Brushes.loadAll(get)
    ok(Raster.STYLES["user:My Pen"] ~= nil, "loadAll re-registers saved brushes on startup")
    ok(Brushes.remove(get, set, "My Pen") and #Brushes.userList(get) == 0, "remove deletes the brush")
end

------------------------------------------------------------------------------
-- export: a hard erase (op.ebg) marks the clear mask; a soft erase does not
------------------------------------------------------------------------------
do
    local ffi = require("ffi")
    local W, H = 20, 20
    -- soft erase (default): leaves the mask clear, so a background would show
    local c = Canvas.new(W, H)
    c:startStroke("ink", 8); c:addPoint(2, 10); c:addPoint(18, 10); c:finishStroke()
    c:startStroke("erase", 8); c:addPoint(10, 10); c:finishStroke()
    local mask = ffi.new("uint8_t[?]", W * H)
    Export.buildRGBA(c, nil, mask)
    ok(mask[10 * W + 10] == 0, "a soft erase does not mark the clear mask (background is kept)")

    -- hard erase: marks the mask, so the background is punched through
    local c2 = Canvas.new(W, H)
    c2:startStroke("ink", 8); c2:addPoint(2, 10); c2:addPoint(18, 10); c2:finishStroke()
    c2:startStroke("erase", 8); c2:addPoint(10, 10)
    local e2 = c2:finishStroke(); e2.ebg = true
    local mask2 = ffi.new("uint8_t[?]", W * H)
    Export.buildRGBA(c2, nil, mask2)
    ok(mask2[10 * W + 10] == 1, "a hard erase marks the clear mask (background removed)")
end

------------------------------------------------------------------------------
-- pdf: the writer produces a structurally valid, multi-page, JPEG-embedding PDF
------------------------------------------------------------------------------
do
    local Pdf = require("ink/pdf")
    local tmpdir = os.getenv("TMPDIR") or "/tmp"
    local out = tmpdir .. "/inkaway_pdf_test.pdf"
    local doc = assert(Pdf.openStream(out))
    for _, data in ipairs({ "JPEGDATA1", "JPEGDATA22" }) do   -- 9 and 10 bytes
        local jp = tmpdir .. "/inkaway_pdf_page.jpg"
        local f = io.open(jp, "wb"); f:write(data); f:close()
        doc:addJPEGFile(jp, 100, 200)
        os.remove(jp)
    end
    ok(doc:finish(), "pdf: the document is written")
    local f = io.open(out, "rb"); local s = f:read("*a"); f:close(); os.remove(out)
    ok(s:sub(1, 8) == "%PDF-1.4", "pdf has a header")
    ok(s:find("%%EOF") ~= nil, "pdf ends with EOF")
    ok(s:find("/Count 2", 1, true) ~= nil, "page tree counts two pages")
    ok(s:find("/Root 1 0 R", 1, true) ~= nil, "trailer points at the catalog")
    ok(s:find("/Size 9", 1, true) ~= nil, "xref size is 2 + 3*pages + 1")
    ok(select(2, s:gsub("/DCTDecode", "")) == 2, "each page embeds a JPEG (DCTDecode)")
    ok(s:find("/Length 9", 1, true) and s:find("/Length 10", 1, true),
        "image stream lengths match the JPEG bytes")
    ok(s:find("MediaBox %[0 0 100 200%]") ~= nil, "fixed page box matches the image size")
end

------------------------------------------------------------------------------
-- pdf: bookmarks, and titles in any language
------------------------------------------------------------------------------
do
    local Pdf = require("ink/pdf")
    ok(Pdf.text("Plain (one) \\ two") == "(Plain \\(one\\) \\\\ two)", "pdf text: ASCII is a literal, escaped")
    ok(Pdf.text("Şekil") == "<FEFF015E0065006B0069006C>", "pdf text: other letters become UTF-16")
    ok(Pdf.text("a\u{1F600}") == "<FEFF0061D83DDE00>", "pdf text: beyond the basic plane as a surrogate pair")

    local tmpdir = os.getenv("TMPDIR") or "/tmp"
    local out = tmpdir .. "/inkaway_outline_test.pdf"
    local doc = assert(Pdf.openStream(out))
    for i = 1, 3 do
        local jp = tmpdir .. "/inkaway_outline_page.jpg"
        local f = io.open(jp, "wb"); f:write("JPEG" .. i); f:close()
        doc:addJPEGFile(jp, 100, 200)
        os.remove(jp)
    end
    ok(doc:finish({ { title = "Mechanics", page = 1, kids = { { title = "Forces", page = 2 } } },
                    { title = "Dalgalar", page = 3 } }), "pdf: a document with bookmarks is written")
    local f = io.open(out, "rb"); local s = f:read("*a"); f:close(); os.remove(out)
    ok(s:find("/Outlines", 1, true) and s:find("/PageMode /UseOutlines", 1, true),
        "pdf: the catalog points at the bookmarks and opens them")
    ok(s:find("/Title (Forces)", 1, true) and s:find("/Title (Dalgalar)", 1, true), "pdf: every bookmark is there")
    ok(s:find("/Dest [8 0 R /Fit]", 1, true) ~= nil, "pdf: a bookmark goes to its page")
    ok(s:find("/Type /Outlines /First %d+ 0 R /Last %d+ 0 R /Count 3") ~= nil, "pdf: three bookmarks show, all open")
    -- every object sits exactly where the cross-reference table says
    local size = tonumber(s:match("/Size (%d+)"))
    local xref = s:find("xref\n", 1, true)
    local good = size ~= nil and xref ~= nil
    local i = 0
    for off in s:sub(xref):gmatch("(%d%d%d%d%d%d%d%d%d%d) 00000 n") do
        i = i + 1
        local at = tonumber(off) + 1
        if s:sub(at, at + #tostring(i) + 5) ~= i .. " 0 obj" then good = false end
    end
    ok(good and i == size - 1, ("pdf: all %d objects are where the xref says"):format(i))
end

-- The streaming writer (used by notebook export) writes pages straight to disk:
-- every object must sit exactly where the xref says, and the page tree (written
-- last) must list every page.
do
    local Pdf = require("ink/pdf")
    local tmpdir = os.getenv("TMPDIR") or "/tmp"
    local out = tmpdir .. "/inkaway_stream_test.pdf"
    local st = assert(Pdf.openStream(out))
    for i = 1, 3 do
        local jp = tmpdir .. "/inkaway_stream_page.jpg"
        local f = io.open(jp, "wb"); f:write(string.rep(string.char(i), 1000 + i)); f:close()
        ok(st:addJPEGFile(jp, 100, 200, 150, 300), "stream: page " .. i .. " added")
        os.remove(jp)
    end
    ok(st:finish(), "stream: document finished")
    local f = io.open(out, "rb"); local s = f:read("*a"); f:close()
    ok(s:sub(1, 8) == "%PDF-1.4" and s:find("%%EOF", 1, true), "stream: header and EOF")
    ok(s:find("/Count 3", 1, true) and s:find("/Kids [5 0 R 8 0 R 11 0 R]", 1, true), "stream: page tree lists all pages")
    ok(s:find("/Length 1001", 1, true) and s:find("/Length 1003", 1, true), "stream: image lengths match the files")
    local xref = s:match("startxref\n(%d+)")
    local body = s:sub(tonumber(xref) + 1)
    local good, total = true, 0
    local num = -1
    for line in body:gmatch("(%d%d%d%d%d%d%d%d%d%d) %d%d%d%d%d [nf]") do
        num = num + 1
        if num > 0 then
            total = total + 1
            local off = tonumber(line)
            if s:sub(off + 1, off + #(num .. " 0 obj")) ~= num .. " 0 obj" then good = false end
        end
    end
    ok(total == 11 and good, "stream: every xref offset points at its object")
    os.remove(out)
end

-- Empty notebook pages take a shortcut (background flattened straight onto white);
-- it must give exactly the bytes the full compositing path gives.
do
    local ffi = require("ffi")
    pcall(ffi.cdef, "int memcmp(const void *, const void *, size_t);")
    local W2, H2 = 37, 23
    local c = Canvas.new(W2, H2)
    local bg = ffi.new("uint8_t[?]", W2 * H2 * 4)
    for i = 0, W2 * H2 - 1 do
        local o = i * 4
        bg[o], bg[o + 1], bg[o + 2] = (i * 7) % 256, (i * 13) % 256, (i * 29) % 256
        bg[o + 3] = (i % 5 == 0) and 0 or ((i % 5 == 1) and (i * 3) % 256 or 255)
    end
    local fast, fw, fh = Export.buildJPEGRGB(c, { bg = bg })
    local full, uw, uh = Export.buildJPEGRGB(c, { bg = bg, no_fast = true })
    ok(fw == uw and fh == uh and ffi.C.memcmp(fast, full, fw * fh * 3) == 0,
        "empty page shortcut gives exactly the full path's pixels")
    c:startStroke("ink", 4, 255, { 0, 0, 0 }); c:addPoint(5, 5); c:addPoint(20, 12); c:finishStroke()
    local inked = Export.buildJPEGRGB(c, { bg = bg })
    local inked_full = Export.buildJPEGRGB(c, { bg = bg, no_fast = true })
    ok(ffi.C.memcmp(inked, inked_full, W2 * H2 * 3) == 0, "a page with ink takes the full path")
end

------------------------------------------------------------------------------
-- template: ruling emits the expected spans
------------------------------------------------------------------------------
do
    local Template = require("ink/template")
    local n = 0
    Template.render("lines", 100, 100, 25, function() n = n + 1 end)
    ok(n == 3, "lined template draws one span per rule (y=25,50,75)")
    local m = 0
    Template.render("blank", 100, 100, 25, function() m = m + 1 end)
    ok(m == 0, "blank template draws nothing")
    local d = 0
    Template.render("dots", 100, 100, 25, function() d = d + 1 end)
    ok(d > 0, "dot template draws dots")
    -- margin: horizontal rules + a vertical rule near the left (x ~ 0.12w)
    local vertical_at = {}
    Template.render("margin", 200, 100, 25, function(x, _y, len) if len == 1 then vertical_at[x] = true end end)
    ok(vertical_at[math.floor(200 * 0.12)], "margin template draws a left vertical rule")
    -- cornell: a cue divider and a summary divider both present
    local full_w, cue_divider = 0, false
    Template.render("cornell", 200, 100, 25, function(x, _y, len)
        if x == 0 and len == 200 then full_w = full_w + 1 end          -- summary divider (full width)
        if len == 1 and x == math.floor(200 * 0.28) then cue_divider = true end
    end)
    ok(cue_divider, "cornell template draws the cue-column divider")
    ok(full_w >= 1, "cornell template draws the summary divider across the page")
end

------------------------------------------------------------------------------
-- notebook: page model (add / navigate / delete) and project round-trip
------------------------------------------------------------------------------
do
    local Notebook = require("ink/notebook")
    local Project = require("ink/project")
    local nb = Notebook.new(600, 800)
    ok(nb:count() == 1 and nb.index == 1, "new notebook has one page")
    nb:setCurrentOps({ 1, 2, 3 })
    ok(#nb:currentOps() == 3, "current-page ops set and read back")
    local idx = nb:addPage()
    ok(nb:count() == 2 and idx == 2 and nb.index == 2, "addPage inserts after current and moves to it")
    ok(#nb:currentOps() == 0, "the added page starts blank")
    ok(nb:gotoPage(1) and nb.index == 1, "gotoPage moves")
    ok(not nb:gotoPage(9), "gotoPage rejects an out-of-range page")
    nb:gotoPage(2); nb:deletePage()
    ok(nb:count() == 1, "deletePage removes a page")

    -- duplicate makes an independent deep copy
    nb:setCurrentOps({ { kind = "ink", pts = { 1, 2 } } })
    local dj = nb:duplicatePage()
    ok(nb:count() == 2 and dj == 2, "duplicatePage inserts a copy after and moves to it")
    nb:currentOps()[1].pts[1] = 99
    nb:gotoPage(1)
    ok(nb:currentOps()[1].pts[1] == 1, "the duplicate is a deep copy, not an alias")

    -- move reorders the current page and follows it
    local a, b = nb.pages[1], nb.pages[2]
    nb:gotoPage(1); nb:movePage(1)
    ok(nb.index == 2 and nb.pages[2] == a and nb.pages[1] == b, "movePage swaps and follows the page")
    ok(nb:movePage(1) == nb.index, "movePage past the end is a no-op")

    -- per-page src (PDF page mapping) survives insert/reorder and the round-trip
    local nb2 = Notebook.new(300, 400, { style = "grid", size = 32, pdf_path = "x.pdf" })
    nb2.pages = { { ops = { { kind = "ink", width = 6, pts = { 1, 1, 2, 2 } } }, src = 1 },
                  { ops = {}, src = 2 } }
    nb2.index = 1
    ok(nb2:srcOf(1) == 1 and nb2:currentSrc() == 1, "src reads back per page")
    local data = Project.deserialize(Project.serializeNotebook(nb2))
    ok(data and Project.isNotebook(data), "notebook serializes and reloads as v2")
    ok(#data.pages == 2 and data.template.pdf_path == "x.pdf", "pages and pdf template survive the round-trip")
    local nb3 = Notebook.fromData(data)
    ok(nb3.pages[1].ops[1].kind == "ink" and nb3.pages[1].src == 1, "ops and src survive fromData")
    ok(nb3.pages[2].src == 2, "second page keeps its source page")

    -- back-compat: an old bare-ops-array page still loads
    local old = Notebook.fromData({ w = 10, h = 10, pages = { { { kind = "ink", pts = { 0, 0 } } } } })
    ok(old.pages[1].ops[1].kind == "ink" and old.pages[1].src == nil, "old bare-array page format still loads")
end

------------------------------------------------------------------------------
-- export: a template draws its ruling under the ink (grey on the rule, white between)
------------------------------------------------------------------------------
do
    local W, H = 40, 40
    local c = Canvas.new(W, H)
    local buf = Export.buildRGB(c, nil, { style = "lines", size = 10, gray = 200 })
    local function r(x, y) return buf[(y * W + x) * 3] end
    ok(r(20, 10) == 200, "template paints a grey rule")
    ok(r(20, 5) == 255, "the paper between rules stays white")
end

------------------------------------------------------------------------------
-- export: a sandpaper paper colour tints the whole page and the eraser reveals
-- that tint (not white), so a colour device sees the warm background
------------------------------------------------------------------------------
do
    local W, H = 30, 30
    local c = Canvas.new(W, H)
    -- an erase op should reveal the paper, not force white
    c:setOps({ { kind = "erase", pts = { 15, 15 }, width = 6, ebg = true } })
    local buf = Export.buildRGB(c, nil, { style = "blank", paper = { 240, 230, 200 } })
    local function rgb(x, y) local o = (y * W + x) * 3; return buf[o], buf[o + 1], buf[o + 2] end
    local pr, pg, pb = rgb(2, 2)
    ok(pr == 240 and pg == 230 and pb == 200, "sandpaper tint fills the page")
    local er, eg, eb = rgb(15, 15)
    ok(er == 240 and eg == 230 and eb == 200, "eraser reveals the paper tint, not white")
end

------------------------------------------------------------------------------
-- export: buildRGBA draws the notebook ruling as OPAQUE grey, so when a page is
-- composited over a background (a PDF page or a photo) the ruling still shows
------------------------------------------------------------------------------
do
    local W, H = 40, 40
    local c = Canvas.new(W, H)
    local buf = Export.buildRGBA(c, nil, nil, { style = "lines", size = 10, gray = 180 })
    local function px(x, y) local o = (y * W + x) * 4; return buf[o], buf[o + 3] end
    local rgrey, ralpha = px(20, 10)
    ok(rgrey == 180 and ralpha == 255, "buildRGBA rule is opaque grey (survives bg composite)")
    local _, palpha = px(20, 5)
    ok(palpha == 0, "between the rules stays transparent so the background shows")
end

------------------------------------------------------------------------------
-- export: the page-number footer stamps dark pixels near the bottom centre
------------------------------------------------------------------------------
do
    local ffi = require("ffi")
    local W, H = 400, 500
    local buf = ffi.new("uint8_t[?]", W * H * 3)
    ffi.fill(buf, W * H * 3, 0xFF)            -- white page
    Export.drawFooter(buf, W, H, "3 / 9", 80)
    local function dark_in(y0, y1)
        local n = 0
        for y = y0, y1 do for x = 0, W - 1 do if buf[(y * W + x) * 3] < 200 then n = n + 1 end end end
        return n
    end
    ok(dark_in(H - 40, H - 1) > 0, "footer stamps dark pixels in the bottom band")
    ok(dark_in(0, math.floor(H / 2)) == 0, "footer leaves the top of the page clean")
end

------------------------------------------------------------------------------
-- export: a placed image composites into the PNG (keeping its alpha) and over
-- white in the JPEG; a hidden image contributes nothing.
------------------------------------------------------------------------------
do
    local ffi = require("ffi")
    local W, H = 20, 20
    local c = Canvas.new(W, H)
    -- a 4x4 picture: opaque red on the left half, half-opacity blue on the right
    local iw, ih = 4, 4
    local pic = ffi.new("uint8_t[?]", iw * ih * 4)
    for py = 0, ih - 1 do
        for px = 0, iw - 1 do
            local o = (py * iw + px) * 4
            if px < 2 then
                pic[o], pic[o+1], pic[o+2], pic[o+3] = 0xD0, 0, 0, 255      -- opaque red
            else
                pic[o], pic[o+1], pic[o+2], pic[o+3] = 0, 0, 0xFF, 128      -- half blue
            end
        end
    end
    Export.image_raster = function(op) return pic, iw, ih end
    c.ops[#c.ops + 1] = { kind = "image", x = 5, y = 5, w = iw, h = ih }

    local rgba = Export.buildRGBA(c)
    local red = (7 * W + 6) * 4       -- canvas (6,7): inside the opaque-red half
    ok(rgba[red] == 0xD0 and rgba[red+1] == 0 and rgba[red+2] == 0 and rgba[red+3] == 255,
        "image: opaque red pixel composites into PNG")
    local blue = (7 * W + 8) * 4      -- canvas (8,7): inside the half-blue half
    ok(rgba[blue+2] == 0xFF and rgba[blue+3] == 128,
        "image: half-opacity blue keeps its alpha over transparency in PNG")
    ok(rgba[(0 * W + 0) * 4 + 3] == 0, "image: uncovered canvas stays transparent in PNG")

    local rgb = Export.buildRGB(c)
    local rp = (7 * W + 6) * 3
    ok(rgb[rp] == 0xD0 and rgb[rp+1] == 0 and rgb[rp+2] == 0,
        "image: opaque red composites over white in JPEG")
    local bp = (7 * W + 8) * 3
    ok(rgb[bp] == 127 and rgb[bp+1] == 127 and rgb[bp+2] == 255,
        "image: half blue blends over white in JPEG")

    c.ops[1].hidden = true
    ok(Export.buildRGBA(c)[red + 3] == 0, "image: a hidden image is skipped in export")
    c.ops[1].hidden = nil

    -- a SOFT erase over the image keeps it (reveals the picture, not white);
    -- a HARD erase (op.ebg) removes it. Erase runs across the red half at y=7.
    local cs = Canvas.new(W, H)
    cs.ops[#cs.ops + 1] = { kind = "image", x = 5, y = 5, w = iw, h = ih }
    cs.ops[#cs.ops + 1] = { kind = "erase", width = 6, alpha = 255, pts = { 4, 7, 16, 7 } }
    local sr = Export.buildRGBA(cs)
    ok(sr[red] == 0xD0 and sr[red + 3] == 255, "image: a soft erase leaves the image intact")

    local ch = Canvas.new(W, H)
    ch.ops[#ch.ops + 1] = { kind = "image", x = 5, y = 5, w = iw, h = ih }
    ch.ops[#ch.ops + 1] = { kind = "erase", width = 6, alpha = 255, ebg = true, pts = { 4, 7, 16, 7 } }
    ok(Export.buildRGBA(ch)[red + 3] == 0, "image: a hard erase (ebg) removes the image")

    Export.image_raster = nil
end

------------------------------------------------------------------------------
-- shapes: picking a shape by touch. A CLOSED shape is grabbable anywhere inside
-- it, filled or not (an unfilled outline is otherwise a thread-thin target); an
-- OPEN shape is only grabbable near its line.
------------------------------------------------------------------------------
do
    local Shapes = require("ink/shapes")
    local rect = { kind = "shape", shape = "rect", fill = false, width = 2, pts = { 100, 100, 300, 200 } }
    ok(Shapes.hit(rect, 200, 150, 5), "unfilled rectangle grabbable from its interior")
    ok(Shapes.hit(rect, 100, 150, 5), "unfilled rectangle grabbable on its edge")
    ok(not Shapes.hit(rect, 400, 400, 5), "unfilled rectangle not grabbable well outside it")

    local filled = { kind = "shape", shape = "rect", fill = true, width = 2, pts = { 100, 100, 300, 200 } }
    ok(Shapes.hit(filled, 200, 150, 5), "filled rectangle still grabbable inside")

    local ell = { kind = "shape", shape = "ellipse", fill = false, width = 2, pts = { 100, 100, 300, 300 } }
    ok(Shapes.hit(ell, 200, 200, 5), "unfilled ellipse grabbable from its centre")
    ok(not Shapes.hit(ell, 105, 105, 5), "unfilled ellipse not grabbable in an empty corner")

    local line = { kind = "shape", shape = "line", fill = false, width = 2, pts = { 100, 100, 300, 100 } }
    ok(Shapes.hit(line, 200, 100, 5), "open line grabbable on the line")
    ok(not Shapes.hit(line, 200, 180, 5), "open line not grabbable off to the side")

    -- a poly shape (a beautified triangle): grabbable inside, and rotated about the
    -- centre of its own bounding box (180 deg keeps the same bounds)
    local tri = { kind = "shape", shape = "poly", closed = true, fill = false, width = 3,
                  pts = { 250, 100, 100, 300, 400, 300 } }
    ok(Shapes.hit(tri, 250, 250, 5), "poly triangle grabbable from its interior")
    ok(not Shapes.hit(tri, 110, 110, 5), "poly triangle not grabbable in an empty corner")
    local bx0, by0, bx1, by1 = Shapes.bounds(tri)
    tri.angle = math.pi
    local rx0, ry0, rx1, ry1 = Shapes.bounds(tri)
    ok(math.abs(bx0 - rx0) < 1 and math.abs(by0 - ry0) < 1 and
       math.abs(bx1 - rx1) < 1 and math.abs(by1 - ry1) < 1,
        "poly rotates about its own bbox centre (180 deg preserves bounds)")

    -- Shapes.contains: strictly inside a closed shape, never inside an open one.
    ok(Shapes.contains(rect, 200, 150), "contains: inside a closed rectangle")
    ok(not Shapes.contains(rect, 400, 400), "contains: outside a rectangle")
    ok(not Shapes.contains(line, 200, 100), "contains: an open line has no interior")
end

------------------------------------------------------------------------------
-- A bucket fill that joins a shape is stored ON the shape (op.fill_color) and
-- painted under its outline, so it renders like a solid fill of that colour,
-- moves with the shape's points, and is absent without fill_color.
------------------------------------------------------------------------------
do
    local W, H = 60, 40
    local function centre(buf, x, y) local i = (y * W + x) * 4; return buf[i + 1], buf[i + 2], buf[i + 3], buf[i + 4] end
    local function samePix(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4] end

    -- reference: a normal SOLID red shape
    local ref = Canvas.new(W, H)
    ref.ops[1] = { kind = "shape", shape = "rect", fill = true, width = 2, color = { 220, 0, 0 }, alpha = 255, pts = { 10, 8, 40, 30 } }
    local rr = { centre(Export.buildRGBA(ref), 25, 19) }

    -- our interior fill: black outline + a red fill_color interior
    local ch = Canvas.new(W, H)
    ch.ops[1] = { kind = "shape", shape = "rect", fill = false, width = 2, color = { 0, 0, 0 }, alpha = 255,
                  pts = { 10, 8, 40, 30 }, fill_color = { 220, 0, 0 }, fill_alpha = 255 }
    ok(samePix({ centre(Export.buildRGBA(ch), 25, 19) }, rr),
        "shape fill_color paints the interior the same as a solid fill of that colour")

    -- the fill follows the shape's points when it moves
    for i = 1, #ch.ops[1].pts, 2 do ch.ops[1].pts[i] = ch.ops[1].pts[i] + 12; ch.ops[1].pts[i + 1] = ch.ops[1].pts[i + 1] + 6 end
    local moved = Export.buildRGBA(ch)
    ok(samePix({ centre(moved, 37, 25) }, rr), "the interior fill moves with the shape")
    -- (14,11) was inside the original rect but is left of the moved one (22..52)
    local _, _, _, a_old = centre(moved, 14, 11)
    ok(a_old == 0, "the shape's old position is empty after it moves")

    -- no fill_color -> transparent interior (a plain outlined shape)
    local plain = Canvas.new(W, H)
    plain.ops[1] = { kind = "shape", shape = "rect", fill = false, width = 2, color = { 0, 0, 0 }, alpha = 255, pts = { 10, 8, 40, 30 } }
    local _, _, _, a_plain = centre(Export.buildRGBA(plain), 25, 19)
    ok(a_plain == 0, "an unfilled shape has a transparent interior")
end

------------------------------------------------------------------------------
-- export: a PNG can carry the notebook ruling and be laid on white
------------------------------------------------------------------------------
do
    local W, H = 120, 160
    local c = Canvas.new(W, H)
    c:startStroke("ink", 6, 255, { 0, 0, 0 }); c:addPoint(20, 20); c:addPoint(100, 20); c:finishStroke()
    local function px(buf, w, x, y)
        local o = (y * w + x) * 4
        return buf[o], buf[o + 1], buf[o + 2], buf[o + 3]
    end
    local clear, w = Export.buildPNGRGBA(c)
    local _, _, _, a0 = px(clear, w, 60, 120)
    ok(a0 == 0, "a PNG is transparent where nothing is drawn")
    local white, ww, wh = Export.buildPNGRGBA(c, { white = true })
    local r, g, b, a = px(white, ww, 60, 120)
    ok(ww == W and wh == H and r == 255 and g == 255 and b == 255 and a == 255, "laid on white, the empty page is white")
    local ir, _, _, ia = px(white, ww, 60, 20)
    ok(ir < 40 and ia == 255, "and the ink stays dark")
    local ruled = Export.buildPNGRGBA(c, { template = { style = "lines", size = 20, gray = 100 } })
    local lines = 0
    for y = 0, H - 1 do
        local lr, _, _, la = px(ruled, W, 5, y)
        if la == 255 and lr == 100 then lines = lines + 1 end
    end
    ok(lines >= 4, ("a page with a template carries its ruling (%d rows)"):format(lines))
    local crop, cw, ch = Export.buildPNGRGBA(c, { rect = { x = 10, y = 10, w = 50, h = 30 }, white = true })
    local cr = px(crop, cw, 15, 10)
    ok(cw == 50 and ch == 30 and cr < 40, "a crop keeps its own size and offset")
end

------------------------------------------------------------------------------
-- clipboard: copies that outlive the page they came from
------------------------------------------------------------------------------
do
    local Clipboard = require("ink/clipboard")
    Clipboard.clear()
    ok(Clipboard.count() == 0 and #Clipboard.take(1, 1) == 0, "an empty clipboard pastes nothing")
    local ops = { { kind = "ink", width = 4, pts = { 10, 10, 30, 20 } },
                  { kind = "fill", runs = { 12, 14, 5 } },
                  { kind = "image", x = 20, y = 18, w = 10, h = 10, path = "/a.png" } }
    Clipboard.put(ops, { x0 = 10, y0 = 10, x1 = 30, y1 = 30 })
    ops[1].pts[1] = 999
    ok(Clipboard.count() == 3, "it holds what was put")
    local same = Clipboard.take()
    ok(same[1].pts[1] == 10, "it holds copies, not the ops themselves")
    ok(same[3].x == 20 and same[2].runs[1] == 12, "without a point they paste where they were")
    local moved = Clipboard.take(120, 220)
    ok(moved[1].pts[1] == 110 and moved[1].pts[2] == 210, "with a point the box is centred on it")
    ok(moved[2].runs[1] == 112 and moved[3].x == 120 and moved[3].y == 218, "fills and pictures move with it")
    ok(Clipboard.take()[1].pts[1] == 10, "pasting leaves the clipboard as it was")
    local half = Clipboard.take(20.4, 20.6)
    ok(half[2].runs[1] == math.floor(half[2].runs[1]), "pasted fills stay on whole pixels")
    Clipboard.clear()
end

-- A loop that closes exactly on its start must keep its shape when simplified.
do
    local loop = {}
    for k = 0, 100 do
        local a = 2 * math.pi * k / 100
        loop[#loop + 1] = math.floor(200 + 60 * math.cos(a) + 0.5)
        loop[#loop + 1] = math.floor(200 + 60 * math.sin(a) + 0.5)
    end
    local kept = math.floor(#Geom.rdp(loop, 1.0) / 2)
    ok(kept > 10, ("a closed loop survives simplification (%d points kept)"):format(kept))
end

print(("core: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
