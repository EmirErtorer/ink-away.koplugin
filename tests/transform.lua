-- Tests for moving, resizing, turning and mirroring ops (ink/transform.lua):
-- each kind lands exactly where the whole selection's change puts it.
-- Run from the plugin root with:  luajit tests/transform.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local Transform = require("ink/transform")
local Shapes = require("ink/shapes")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function rot(x, y, cx, cy, a)
    local dx, dy = x - cx, y - cy
    return cx + dx * math.cos(a) - dy * math.sin(a), cy + dx * math.sin(a) + dy * math.cos(a)
end
local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = type(v) == "table" and copy(v) or v end
    return c
end
-- do two outlines match point for point?
local function sameOutline(a, b, eps)
    if #a ~= #b then return false end
    for i = 1, #a do if not near(a[i], b[i], eps or 1e-6) then return false end end
    return true
end

-- pen strokes
do
    local op = { kind = "ink", width = 4, pts = { 10, 10, 20, 30 } }
    Transform.scale(op, 0, 0, 2)
    ok(op.pts[3] == 40 and op.pts[4] == 60 and op.width == 8, "a stroke grows about the anchor, thicker with it")
    Transform.rotate(op, 0, 0, math.pi / 2)
    ok(near(op.pts[1], -20) and near(op.pts[2], 20), "a stroke turns clockwise on the page")
    Transform.flip(op, "h", 0)
    ok(near(op.pts[1], 20), "a stroke mirrors")
end

-- shapes: the outline after the change is the outline changed
for _, shape in ipairs({ "rect", "ellipse", "triangle", "line", "curve" }) do
    local op = { kind = "shape", shape = shape, width = 3, pts = { 100, 50, 180, 90, 150, 20 }, angle = 0.3 }
    if shape ~= "curve" then op.pts = { 100, 50, 180, 90 } end
    local before = Shapes.outline(op)
    local a, cx, cy = 0.7, 30, 200
    local turned = Transform.rotate(copy(op), cx, cy, a)
    local want = {}
    for i = 1, #before, 2 do want[i], want[i + 1] = rot(before[i], before[i + 1], cx, cy, a) end
    ok(sameOutline(Shapes.outline(turned), want, 1e-6), shape .. ": turning about any point is exact")
    -- the same points (in any order) as the original's, each changed by fn
    local function samePoints(got, fn)
        if #got ~= #before then return false end
        for i = 1, #before, 2 do
            local wx, wy = fn(before[i], before[i + 1])
            local found = false
            for j = 1, #got, 2 do
                if near(got[j], wx, 1e-6) and near(got[j + 1], wy, 1e-6) then found = true; break end
            end
            if not found then return false end
        end
        return true
    end
    local flipped = Transform.flip(copy(op), "h", 60)
    ok(samePoints(Shapes.outline(flipped), function(x, y) return 120 - x, y end),
        shape .. ": mirroring is exact at any angle")
    local grown = Transform.scale(copy(op), 10, 10, 1.5)
    local bx0, by0, bx1, by1 = Shapes.bounds(op)
    local gx0, gy0, gx1, gy1 = Shapes.bounds(grown)
    ok(near(gx0, 10 + (bx0 - 10) * 1.5, 0.5) and near(gy1, 10 + (by1 - 10) * 1.5, 0.5)
        and near(gx1, 10 + (bx1 - 10) * 1.5, 0.5) and near(gy0, 10 + (by0 - 10) * 1.5, 0.5)
        and grown.width == 4.5, shape .. ": resizing is exact, line width too")
    if shape ~= "ellipse" then   -- (an ellipse is drawn with more points when bigger)
        ok(samePoints(Shapes.outline(grown), function(x, y) return 10 + (x - 10) * 1.5, 10 + (y - 10) * 1.5 end),
            shape .. ": every point of it")
    end
end
do
    local arrow = { kind = "shape", shape = "line", width = 2, head = 12, pts = { 0, 0, 10, 0 } }
    Transform.scale(arrow, 0, 0, 2)
    ok(arrow.head == 24, "an arrowhead grows with its line")
    local poly = { kind = "shape", shape = "poly", closed = true, width = 2, pts = { 0, 0, 40, 0, 20, 30 } }
    local before = Shapes.outline(poly)
    local turned = Transform.rotate(copy(poly), 100, 100, 1.1)
    local want = {}
    for i = 1, #before, 2 do want[i], want[i + 1] = rot(before[i], before[i + 1], 100, 100, 1.1) end
    ok(sameOutline(Shapes.outline(turned), want, 1e-6), "a point path turns exactly too")
end

-- pictures
do
    local img = { kind = "image", x = 100, y = 100, w = 40, h = 20, angle = 0 }
    Transform.scale(img, 100, 100, 2)
    ok(img.x == 100 and img.y == 100 and img.w == 80 and img.h == 40, "a picture grows from the anchor")
    Transform.rotate(img, 0, 0, math.pi / 2)
    ok(near(img.angle, 90) and near(img.x + img.w / 2, -120) and near(img.y + img.h / 2, 140),
        "a picture turns: its angle and its centre")
    Transform.flip(img, "h", 0)
    ok(img.flip_h == true and near(img.angle, 270) and near(img.x + img.w / 2, 120),
        "a mirrored picture flips and its angle reverses, so it mirrors on the page")
    Transform.flip(img, "v", 0)
    ok(img.flip_v == true and near(img.angle, 90), "and the same up and down")
end

-- text boxes turn about their corner, and mirror without their letters
do
    local Text = require("ink/text")
    local t = { kind = "text", x = 0, y = 0, w = 100, h = 40, size = 20 }
    Transform.rotate(t, 0, 0, math.pi)
    local x0, y0, x1, y1 = Text.bounds(t)
    ok(near(t.x, 0) and near(t.y, 0) and t.angle == 180, "a half turn about its corner turns it upside down there")
    ok(near(x0, -100) and near(y0, -40) and near(x1, 0) and near(y1, 0), "and it covers the turned box")
    Transform.flip(t, "h", 0)
    local cx, cy = Text.centre(t)
    ok(near(cx, 50) and near(cy, -20) and t.angle == 180 and t.flip_h == nil,
        "a mirror moves its centre across and keeps its letters readable")
    Transform.scale(t, 0, 0, 1.5)
    ok(t.w == 150 and t.h == 60 and t.size == 30, "its letters scale with it")
    -- a quarter turn about its middle stays there, reading down
    local q = { kind = "text", x = 100, y = 100, w = 200, h = 50, size = 20 }
    local mx, my = Text.centre(q)
    Transform.rotate(q, mx, my, math.pi / 2)
    local nx, ny = Text.centre(q)
    x0, y0, x1, y1 = Text.bounds(q)
    ok(q.angle == 90 and near(nx, mx) and near(ny, my), "a quarter turn about the middle stays put")
    ok(near(x1 - x0, 50) and near(y1 - y0, 200), "and stands it on end")
    -- an angle that adds up to a whole turn is upright again
    Transform.rotate(q, mx, my, -math.pi / 2)
    ok(q.angle == nil and near(q.x, 100) and near(q.y, 100), "turning it back leaves it as it was")
    -- a mirror of a turned box mirrors its angle
    local m = { kind = "text", x = 0, y = 0, w = 100, h = 40, angle = 30 }
    Transform.flip(m, "h", 200)
    ok(near(m.angle, 330), "a mirror turns a 30 degree box to -30 degrees")
end

-- fills
do
    local function area(runs) local n = 0; for i = 3, #runs, 3 do n = n + runs[i] end; return n end
    local fill = { kind = "fill", runs = {} }
    for y = 10, 29 do fill.runs[#fill.runs + 1] = 10; fill.runs[#fill.runs + 1] = y; fill.runs[#fill.runs + 1] = 30 end
    local a0 = area(fill.runs)
    local f = Transform.flip(copy(fill), "h", 50)
    ok(f.runs[1] == 60 and area(f.runs) == a0, "a fill mirrors run by run")
    f = Transform.flip(f, "h", 50)
    ok(f.runs[1] == 10, "and back")
    f = Transform.scale(copy(fill), 10, 10, 2)
    ok(math.abs(area(f.runs) - 4 * a0) <= 0.05 * 4 * a0, "a fill twice the size has four times the area")
    f = Transform.rotate(copy(fill), 25, 20, math.pi / 2)
    ok(math.abs(area(f.runs) - a0) <= 0.05 * a0, "a turned fill keeps its area")
end

print(("transform: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
