-- Pens whose width changes (ink/pens.lua, Raster.pathVar / pathNib) and pen
-- pressure on strokes: simplification keeps pressure with its point, a constant
-- radius draws exactly what plain ink draws, live drawing segment by segment
-- matches the saved stroke, and the nibs thin the way a real nib does.
--   luajit tests/pens.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Geom = require("ink/geom")
local Canvas = require("ink/canvas")
local Raster = require("ink/raster")
local Pens = require("ink/pens")
local Project = require("ink/project")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- the set of pixels a draw call covers, and its size
local function cover(fn)
    local set, n = {}, 0
    fn(function(x, y, len)
        for i = 0, len - 1 do
            local k = y * 100000 + x + i
            if not set[k] then set[k] = true; n = n + 1 end
        end
    end)
    return set, n
end
local function same(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end
-- rows covered at column x (the stroke's thickness there)
local function thickness(set, x)
    local n = 0
    for k in pairs(set) do if k % 100000 == x then n = n + 1 end end
    return n
end

-- ---- simplification keeps each pressure with its point ----------------------
do
    local pts, aux = {}, {}
    for i = 0, 40 do pts[#pts + 1] = i * 3; pts[#pts + 1] = 100; aux[#aux + 1] = (i < 20) and 40 or 240 end
    local p2, a2 = Geom.dropClose(pts, 1.5, aux)
    ok(#a2 * 2 == #p2, "dropClose: one pressure per kept point")
    local p3, a3 = Geom.rdp(p2, 0.75)
    ok(#p3 == 4 and a3 == nil, "rdp: a straight line keeps its ends; no aux in, none out")
    local p4, a4 = Geom.rdp(p2, 0.75, a2, 20 * 0.5 / 255)
    ok(#a4 * 2 == #p4, "rdp: one pressure per kept point")
    ok(#p4 > 4, "rdp: a pressure step on a straight line keeps the points around it")
    local lo, hi = false, false
    for _i, v in ipairs(a4) do if v == 40 then lo = true end if v == 240 then hi = true end end
    ok(lo and hi, "rdp: both pressures survive")
end

-- ---- a pressured stroke on the canvas ----------------------------------------
do
    local c = Canvas.new(400, 300)
    c:startStroke("ink", 12, 255, nil, "ballpoint", 7, true)
    for i = 0, 30 do c:addPoint(10 + i * 5, 50 + (i % 3), 50 + i * 6) end
    c:addPoint(160, 50, 250)              -- a repeat of the last point: pressure only
    local op = c:finishStroke()
    ok(op.pr ~= nil and #op.pr * 2 == #op.pts, "canvas: a pressured stroke keeps one pressure per point")
    ok(op.pr[#op.pr] == 250, "canvas: pressing harder in place updates the last pressure")
    local plain = Canvas.new(400, 300)
    plain:startStroke("ink", 12, 255, nil, "solid", 7)
    plain:addPoint(10, 10, 99); plain:addPoint(50, 10, 99)
    ok(plain:finishStroke().pr == nil, "canvas: a plain stroke keeps none")
    local cl = c:cloneOp(op)
    ok(cl.pr ~= op.pr and cl.pr[1] == op.pr[1], "canvas: cloneOp copies the pressures")
    -- saved and read back
    local data = Project.decode(Project.serialize(c))
    local back = data.ops[1]
    ok(back.pr and #back.pr == #op.pr and back.pr[3] == op.pr[3], "project: pressures round-trip")
end

-- ---- pathVar: a constant radius is exactly plain ink ---------------------------
do
    local pts = { 20, 30, 80, 55, 140, 40, 160, 90 }
    for _i, r in ipairs({ 2, 4, 7 }) do
        local a = cover(function(put) Raster.path(pts, r, put) end)
        local rs = {}
        for i = 1, 2 * (#pts / 2 - 1) do rs[i] = r end
        local b = cover(function(put) Raster.pathVar(pts, rs, put) end)
        ok(same(a, b), "pathVar: constant radius " .. r .. " covers exactly Raster.path's pixels")
    end
    local dot = cover(function(put) Raster.pathVar({ 50, 50 }, { 3 }, put) end)
    local dot2 = cover(function(put) Raster.disc(50, 50, 3, put) end)
    ok(same(dot, dot2), "pathVar: a single point is the disc")
    -- a swell: thin at the start, wide at the end
    local s = cover(function(put) Raster.pathVar({ 10, 100, 210, 100 }, { 1, 9 }, put) end)
    ok(thickness(s, 20) < thickness(s, 200), "pathVar: the radius grows along the segment")
end

-- ---- convexFill and the nib ---------------------------------------------------
do
    local _s, n = cover(function(put) Raster.convexFill({ 0, 0, 10, 0, 10, 10, 0, 10 }, put) end)
    ok(n == 100, "convexFill: a 10 x 10 square is 100 pixels")
    local _t, nt = cover(function(put) Raster.convexFill({ 0, 0, 10, 0, 0, 10 }, put) end)
    ok(nt >= 45 and nt <= 55, "convexFill: a right triangle is about half the square (" .. nt .. ")")
    -- a right-handed nib: "/" strokes are hairlines, "\" strokes are broad
    local st = Pens.STYLES.calligraphy
    local _a, along = cover(function(put) Pens.nib({ 100, 200, 200, 100 }, nil, 30, st, put) end)
    local _b, across = cover(function(put) Pens.nib({ 100, 100, 200, 200 }, nil, 30, st, put) end)
    ok(across > 3 * along, ("nib: across the nib is broad (%d px) and along it thin (%d px)"):format(across, along))
end

-- ---- the fountain pen thins along its nib -------------------------------------
do
    local st = Pens.STYLES.fountain
    local a1 = Pens.segRadii(st, 10, 255, 255, 1, -1)    -- "/"
    local a2 = Pens.segRadii(st, 10, 255, 255, 1, 1)     -- "\"
    ok(a1 < a2 * 0.5 and a1 >= 3.4, "fountain: along the nib is a hairline, not gone")
    local lo = Pens.segRadii(st, 10, 0, 0, 1, 1)
    ok(math.abs(lo - 10 * 0.3) < 1e-6, "fountain: no pressure gives minf of the width")
end

-- ---- live drawing segment by segment matches the saved stroke ---------------
do
    for _i, style in ipairs({ "ballpoint", "fountain", "calligraphy" }) do
        local st = Raster.STYLES[style]
        local op = { kind = "ink", style = style, width = 14, pts = {}, pr = {} }
        for i = 0, 20 do
            op.pts[#op.pts + 1] = 30 + i * 9 + (i % 4) * 2
            op.pts[#op.pts + 1] = 80 + math.floor(math.sin(i / 3) * 30)
            op.pr[#op.pr + 1] = 60 + (i * 37) % 190
        end
        local full = cover(function(put) Pens.paint(op, put) end)
        local live = cover(function(put)
            local p = op.pts
            Pens.segment(st, { p[1], p[2] }, 7, op.pr[1], op.pr[1], put, 0)
            for i = 2, #p / 2 do
                Pens.segment(st, { p[2 * i - 3], p[2 * i - 2], p[2 * i - 1], p[2 * i] }, 7,
                    op.pr[i - 1], op.pr[i], put, 0)
            end
        end)
        local missing = 0
        for k in pairs(full) do if not live[k] then missing = missing + 1 end end
        ok(missing == 0, style .. ": every saved pixel was drawn live (" .. missing .. " missing)")
    end
end

-- ---- pressure from the pen, and simulated from speed -------------------------
do
    ok(Pens.fromRaw(4095, 4095) == 255 and Pens.fromRaw(0, 4095) == 0, "fromRaw: ends of the range")
    local soft, firm = Pens.fromRaw(1000, 4095, "soft"), Pens.fromRaw(1000, 4095, "firm")
    ok(soft > Pens.fromRaw(1000, 4095) and firm < Pens.fromRaw(1000, 4095), "fromRaw: soft is fuller, firm thinner")
    ok(Pens.fromRaw(nil, 4095) == nil, "fromRaw: no reading, no pressure")
    ok(Pens.fromSpeed(0) == 255 and Pens.fromSpeed(1) == math.floor(0.35 * 255 + 0.5), "fromSpeed: slow full, fast 35%")
    ok(Pens.smooth(100, 200, 0) == 100 and Pens.smooth(100, 200, 50) >= 199, "smooth: eases over distance")
    ok(Pens.usesPressure("ballpoint") and Pens.usesPressure("pencil") and not Pens.usesPressure("solid"),
        "usesPressure: by pen")
end

-- ---- a pencil with pressure keeps its grain and widens -------------------------
do
    local op = { kind = "ink", style = "pencil", width = 16, seed = 3, pts = { 20, 50, 220, 50 }, pr = { 0, 255 } }
    local s = cover(function(put) Pens.paint(op, put) end)
    ok(thickness(s, 40) < thickness(s, 200), "pencil: thinner where lighter")
    local s2 = cover(function(put) Pens.paint({ kind = "ink", style = "pencil", width = 16, seed = 3,
        pts = { 20, 50, 220, 50 } }, put) end)
    ok(next(s2) ~= nil, "pencil: without pressure as before")
end

print(("pens: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
