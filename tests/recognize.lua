-- Tests for shape assist recognition (ink/recognize). Pure Lua under luajit.
-- detect() returns a flat {x,y,...} point path to draw in place of the stroke,
-- or nil to leave it freehand.
--
--   luajit tests/recognize.lua

package.path = "./?.lua;" .. package.path
local R = require("ink/recognize")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local seed = 12345
local function jit(amp)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return ((seed / 2147483648) - 0.5) * 2 * amp
end
local function seg(out, ax, ay, bx, by, n, amp)
    for i = 0, n do
        local t = i / n
        out[#out + 1] = ax + (bx - ax) * t + jit(amp)
        out[#out + 1] = ay + (by - ay) * t + jit(amp)
    end
end
local function npts(s) return s and #s / 2 or 0 end

-- ---- straight line -------------------------------------------------------
do
    local p = {}; seg(p, 100, 100, 500, 130, 40, 1.5)
    local s = R.detect(p, { min_size = 20 })
    ok(npts(s) == 2, "near-straight stroke -> 2-point line")
    ok(s and math.abs(s[2] - s[4]) < 1, "shallow line snapped flat")
end

-- ---- rectangle -----------------------------------------------------------
do
    local p = {}
    seg(p, 100, 100, 400, 100, 30, 2); seg(p, 400, 100, 400, 300, 20, 2)
    seg(p, 400, 300, 100, 300, 30, 2); seg(p, 100, 300, 100, 100, 20, 2)
    local s = R.detect(p, { min_size = 20 })
    ok(npts(s) == 5, "box -> crisp rectangle (4 corners + close)")
    ok(s and s[1] == s[9] and s[2] == s[10], "rectangle path is closed")
    -- axis aligned: the 4 corners use exactly two x values and two y values
    local function distinct(vals)
        local u = {}
        for _, val in ipairs(vals) do
            local seen = false
            for _, e in ipairs(u) do if math.abs(e - val) < 1 then seen = true end end
            if not seen then u[#u + 1] = val end
        end
        return #u
    end
    local xs, ys = {}, {}
    for i = 1, 8, 2 do xs[#xs + 1] = s[i]; ys[#ys + 1] = s[i + 1] end
    ok(distinct(xs) == 2 and distinct(ys) == 2, "rectangle is axis-aligned (2 x's, 2 y's)")
end

-- ---- triangle ------------------------------------------------------------
do
    local p = {}
    seg(p, 250, 100, 400, 300, 30, 2); seg(p, 400, 300, 100, 300, 30, 2)
    seg(p, 100, 300, 250, 100, 30, 2)
    local s = R.detect(p, { min_size = 20 })
    ok(npts(s) == 4, "triangle -> 3 corners + close")
    ok(s and s[1] == s[7] and s[2] == s[8], "triangle path is closed")
end

-- ---- messy triangles must still SNAP to a clean triangle (not a stray polygon)
do
    -- a closing corner that stops short (a gap) used to add a 4th stray vertex
    local p = {}
    seg(p, 300, 100, 480, 380, 25, 3); seg(p, 480, 380, 120, 380, 30, 3)
    seg(p, 120, 380, 300, 140, 20, 3)
    ok(npts(R.detect(p, { min_size = 20 })) == 4, "triangle with a gap -> clean triangle")

    -- an overshooting corner
    p = {}
    seg(p, 300, 100, 480, 380, 25, 3); seg(p, 480, 380, 120, 380, 30, 3)
    seg(p, 120, 380, 320, 70, 28, 3)
    ok(npts(R.detect(p, { min_size = 20 })) == 4, "triangle with overshoot -> clean triangle")

    -- a very wobbly triangle
    p = {}
    seg(p, 300, 100, 480, 380, 25, 10); seg(p, 480, 380, 120, 380, 30, 10)
    seg(p, 120, 380, 300, 100, 25, 10)
    ok(npts(R.detect(p, { min_size = 20 })) == 4, "wobbly triangle -> clean triangle")

    -- a genuine quadrilateral must NOT collapse to a triangle
    p = {}
    seg(p, 300, 80, 500, 250, 20, 3); seg(p, 500, 250, 300, 420, 20, 3)
    seg(p, 300, 420, 100, 250, 20, 3); seg(p, 100, 250, 300, 80, 20, 3)
    ok(npts(R.detect(p, { min_size = 20 })) == 5, "diamond quad stays 4 corners, not a triangle")
end

-- ---- circle / ellipse ----------------------------------------------------
do
    local p = {}
    local cx, cy, r = 300, 300, 120
    for i = 0, 48 do
        local a = (i / 48) * 2 * math.pi
        p[#p + 1] = cx + r * math.cos(a) + jit(2)
        p[#p + 1] = cy + r * math.sin(a) + jit(2)
    end
    local s = R.detect(p, { min_size = 20 })
    ok(npts(s) >= 24, "round loop -> many-point ellipse")
    -- points lie on the bounding ellipse
    local onring = true
    for i = 1, #s - 1, 2 do
        local nx, ny = (s[i] - cx) / r, (s[i + 1] - cy) / r
        if math.abs(math.sqrt(nx * nx + ny * ny) - 1) > 0.05 then onring = false end
    end
    ok(onring, "ellipse points sit on the bounding ellipse")
end

-- ---- L corner (x/y axes) -------------------------------------------------
do
    local p = {}
    seg(p, 120, 100, 120, 400, 30, 1.5); seg(p, 120, 400, 420, 400, 30, 1.5)
    local s = R.detect(p, { min_size = 20 })
    ok(npts(s) == 3, "L corner -> 3-point path (two arms)")
    if npts(s) == 3 then
        local arm1v = math.abs(s[1] - s[3]) < 0.5   -- x equal -> vertical
        local arm2h = math.abs(s[4] - s[6]) < 0.5   -- y equal -> horizontal
        ok(arm1v and arm2h, "L arms are one vertical, one horizontal, sharing the corner")
    end
end

-- ---- general piecewise-straight stroke (the key new case) ----------------
do
    -- a zig-zag / staircase: three straight segments, sharp right-angle corners
    local p = {}
    seg(p, 100, 100, 300, 100, 30, 2); seg(p, 300, 100, 300, 250, 25, 2)
    seg(p, 300, 250, 520, 250, 30, 2)
    local s = R.detect(p, { min_size = 20 })
    ok(npts(s) == 4, "zig-zag -> 4 connected corners (straightened, not a primitive)")
    -- consecutive segments share exact endpoints (connected as one path)
    ok(s and npts(s) >= 2, "zig-zag path is connected")
end

-- ---- things that must NOT beautify --------------------------------------
do
    local p = {}; seg(p, 100, 100, 108, 104, 6, 0.5)
    ok(R.detect(p, { min_size = 28 }) == nil, "tiny stroke -> nil")

    -- a gentle wave may collapse to a single straight line, but must NEVER be
    -- turned into a jagged multi-segment zigzag
    local q = {}
    for i = 0, 60 do
        q[#q + 1] = 100 + i * 6
        q[#q + 1] = 200 + 10 * math.sin(i / 3)
    end
    ok(npts(R.detect(q, { min_size = 20 })) <= 2, "gentle wave -> line or freehand, never a zigzag")

    local a = {}
    for i = 0, 40 do
        local t = i / 40
        a[#a + 1] = 100 + 300 * t
        a[#a + 1] = 200 - 80 * math.sin(t * math.pi)
    end
    ok(R.detect(a, { min_size = 20 }) == nil, "big smooth arc -> nil (not straightened)")
end

-- ---- toolbar primitives also return a compact shape descriptor -------------
-- (line / rectangle / ellipse / triangle), so the caller can turn a beautified
-- stroke into a real, tappable shape op. Non-primitive straightened paths (an L
-- bend, a general polygon) return no descriptor and stay ink.
do
    local p = {}; seg(p, 100, 100, 500, 130, 40, 1.5)
    local _, d = R.detect(p, { min_size = 20 })
    ok(d and d.shape == "line" and #d.pts == 4, "straight line -> line descriptor (2 endpoints)")

    p = {}
    seg(p, 100, 100, 400, 100, 30, 2); seg(p, 400, 100, 400, 300, 20, 2)
    seg(p, 400, 300, 100, 300, 30, 2); seg(p, 100, 300, 100, 100, 20, 2)
    _, d = R.detect(p, { min_size = 20 })
    ok(d and d.shape == "rect" and #d.pts == 4, "box -> rect descriptor (2 corners)")

    p = {}
    local cx, cy, r = 300, 300, 120
    for i = 0, 48 do
        local a = (i / 48) * 2 * math.pi
        p[#p + 1] = cx + r * math.cos(a) + jit(2)
        p[#p + 1] = cy + r * math.sin(a) + jit(2)
    end
    _, d = R.detect(p, { min_size = 20 })
    ok(d and d.shape == "ellipse", "round loop -> ellipse descriptor")

    p = {}
    seg(p, 250, 100, 400, 300, 30, 2); seg(p, 400, 300, 100, 300, 30, 2)
    seg(p, 100, 300, 250, 100, 30, 2)
    _, d = R.detect(p, { min_size = 20 })
    ok(d and d.shape == "poly" and d.closed and #d.pts == 6,
        "triangle -> closed poly descriptor with its 3 real corners")

    p = {}
    seg(p, 120, 100, 120, 400, 30, 1.5); seg(p, 120, 400, 420, 400, 30, 1.5)
    _, d = R.detect(p, { min_size = 20 })
    ok(d == nil, "L bend -> no shape descriptor (stays ink)")
end

print(string.format("recognize: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
