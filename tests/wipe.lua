-- Tests for ink/wipe.lua: what the whole-stroke eraser touches.
-- Run from the plugin root with:  luajit tests/wipe.lua

package.path = "./?.lua;" .. package.path

local Geom = require("ink/geom")
local Wipe = require("ink/wipe")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local W, H = 400, 300
local R = 10   -- eraser radius
local function hits(op, seg) return Wipe.hits(op, seg, R, W, H, {}) end

-- segment distance
ok(Geom.segSegDist2(0, 0, 10, 10, 0, 10, 10, 0) == 0, "segSegDist2: crossing segments touch")
ok(Geom.segSegDist2(0, 0, 10, 0, 0, 5, 10, 5) == 25, "segSegDist2: parallel segments 5 apart")
ok(Geom.segSegDist2(0, 0, 10, 0, 13, 4, 20, 4) == 25, "segSegDist2: nearest endpoints")

-- strokes are lines
local stroke = { kind = "ink", width = 6, pts = { 50, 100, 150, 100 } }
ok(hits(stroke, { 100, 80, 100, 120 }) == true, "ink: an eraser crossing it takes it")
ok(hits(stroke, { 160, 100, 170, 100 }) == true, "ink: reaching its end takes it")
ok(hits(stroke, { 100, 115, 120, 115 }) == false, "ink: passing 15 px away does not")
ok(hits(stroke, { 100, 112, 100, 112 }) == true, "ink: a dab within reach takes it")
local dot = { kind = "ink", width = 6, pts = { 200, 200 } }
ok(hits(dot, { 190, 205, 210, 205 }) == true, "ink: a single dot is taken")

-- an outline shape is a line; its inside is empty
local box = { kind = "shape", shape = "rect", fill = false, width = 4, pts = { 100, 100, 200, 200 } }
local line, area = hits(box, { 150, 150, 160, 150 })
ok(not line and not area, "shape: the inside of an outline is empty")
ok(hits(box, { 90, 150, 110, 150 }) == true, "shape: its outline is a line")
-- a bucket-filled outline: the outline is a line, the inside an area
local tinted = { kind = "shape", shape = "rect", fill = false, width = 4, pts = { 100, 100, 200, 200 },
    fill_color = { 200, 200, 200 } }
line, area = hits(tinted, { 150, 150, 160, 150 })
ok(not line and area, "shape: the inside of a filled outline is an area")
-- a solid shape is all area
local solid = { kind = "shape", shape = "ellipse", fill = true, width = 4, pts = { 100, 100, 200, 200 } }
line, area = hits(solid, { 150, 150, 150, 150 })
ok(not line and area, "shape: a solid shape is an area")
line, area = hits(solid, { 300, 150, 300, 150 })
ok(not line and not area, "shape: well outside a solid shape is nothing")

-- a fill is an area, by its runs
local fill = { kind = "fill", runs = { 10, 20, 30, 10, 21, 30 } }
line, area = hits(fill, { 0, 0, 25, 20 })
ok(not line and area, "fill: the eraser on a run")
line, area = hits(fill, { 25, 23, 25, 23 })
ok(not line and not area, "fill: off its rows")

-- a symmetric stroke is taken by its mirror copy
local sym = { kind = "ink", width = 6, sym = "vert", pts = { 50, 100, 150, 100 } }
ok(hits(sym, { W - 1 - 100, 80, W - 1 - 100, 120 }) == true, "symmetry: the mirror copy counts")
ok(hits(stroke, { W - 1 - 100, 80, W - 1 - 100, 120 }) == false, "symmetry: not without it")

-- what the eraser may take
local boxes = Wipe.boxes({ stroke, box, fill, sym,
    { kind = "erase", width = 20, pts = { 0, 0, 10, 10 } },
    { kind = "text", x = 0, y = 0, w = 50, h = 20 },
    { kind = "image", x = 0, y = 0, w = 50, h = 20 } }, W, H)
local n = 0
for _ in pairs(boxes) do n = n + 1 end
ok(n == 4, "boxes: strokes, shapes and fills only")
local sb = boxes[sym]
ok(sb[1] == 0 and sb[3] == W, "boxes: a symmetric op gets the whole page")

print(("wipe: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
