--[[
Pen types and how wide they draw. A pen's look comes from its style in
Raster.STYLES; the styles here add an `engine` for pens whose width changes:

    var    a round tip whose radius follows the pen's pressure (Ballpoint), and
           for a fountain pen also the stroke's direction against a 45 degree nib
    nib    a flat calligraphy nib swept along the path (Raster.pathNib)

A stroke keeps one pressure per point (op.pr, 0-255), from the pen or, on a pen
without pressure or a finger, simulated from the drawing speed when the stroke
is made. Everything that draws an ink op goes through Pens.paint, and live
drawing through Pens.segment, so the screen, thumbnails and exports agree.
Plain Lua, so the headless tests drive it directly.
]]

local Raster = require("ink/raster")

local Pens = {}

local floor, sqrt, abs, sin, atan2, exp = math.floor, math.sqrt, math.abs, math.sin, math.atan2, math.exp
local NIB = -math.pi / 4   -- a right-handed nib's edge, lower left to upper right ("/")

-- The new pens' styles, registered with the rasterizer so ops find them.
-- minf: the width at no pressure, as a share of the full width
-- sim:  without real pressure, thin the stroke when drawn fast
Pens.STYLES = {
    ballpoint   = { engine = "var", solid = true, pressure = true, minf = 0.6, sim = true },
    fountain    = { engine = "var", solid = true, pressure = true, minf = 0.3, sim = true, nib45 = true },
    calligraphy = { engine = "nib", solid = true, pressure = true, minf = 0.5, thin = 0.16 },
}
-- The smudge is chosen like a pen but draws nothing of its own: it moves the ink
-- under it (ink/smudge.lua, op kind "smudge").
Pens.STYLES.smudge = { engine = "smudge", solid = true }
for k, st in pairs(Pens.STYLES) do Raster.STYLES[k] = st end
-- Pencil keeps its grain; pressed harder it draws wider.
Raster.STYLES.pencil.pressure = true
Raster.STYLES.pencil.minf = 0.55

-- Does a stroke in this style keep a pressure per point?
function Pens.usesPressure(style)
    local st = style and Raster.STYLES[style]
    return st ~= nil and st.pressure == true
end

-- Width factor at pressure p (0-255, nil = full).
local function factor(st, p)
    if not p then return 1 end
    local minf = st.minf or 1
    return minf + (1 - minf) * p / 255
end
Pens.factor = factor

-- A fountain nib's width along direction (dx, dy): broad across the nib, a
-- hairline (35%) along it.
local function nibFactor(dx, dy)
    if dx == 0 and dy == 0 then return 0.7 end
    return 0.35 + 0.65 * abs(sin(atan2(dy, dx) - NIB))
end

-- The radii of one segment from pressure p0 to p1, moving (dx, dy), for a pen of
-- full radius r. Both ends of a fountain segment share its direction.
function Pens.segRadii(st, r, p0, p1, dx, dy)
    local d = st.nib45 and nibFactor(dx, dy) or 1
    return r * factor(st, p0) * d, r * factor(st, p1) * d
end

-- Per-segment radii for a whole op at `scale` (1 for the page, the zoom on
-- screen), as Raster.pathVar takes them.
function Pens.radii(op, st, scale)
    local pts, pr = op.pts, op.pr
    local r = (op.width or 1) / 2 * (scale or 1)
    local n = floor(#pts / 2)
    local rs = {}
    if n == 1 then rs[1] = r * factor(st, pr and pr[1]); return rs end
    for i = 2, n do
        local r0, r1 = Pens.segRadii(st, r, pr and pr[i - 1], pr and pr[i],
            pts[2 * i - 1] - pts[2 * i - 3], pts[2 * i] - pts[2 * i - 2])
        rs[2 * i - 3], rs[2 * i - 2] = r0, r1
    end
    return rs
end

-- Draw an ink op's path through `put`, whatever its pen.
function Pens.paint(op, put)
    local st = op.style and Raster.STYLES[op.style]
    if not st or (st.solid and not st.engine) then
        return Raster.path(op.pts, op.width / 2, put)
    end
    if st.engine == "var" then
        return Raster.pathVar(op.pts, Pens.radii(op, st, 1), put)
    elseif st.engine == "nib" then
        return Pens.nib(op.pts, op.pr, op.width, st, put)
    elseif st.engine == "wash" then
        -- see-through pens blend in ink/wash.lua; here only their footprint, for
        -- the hit tests that ask what a stroke covers
        if st.tip == "chisel" then
            return Raster.pathNib(op.pts, op.width, math.max(1, op.width * 0.35), math.pi / 2, put)
        end
        return Raster.path(op.pts, op.width / 2, put)
    end
    if op.pr and st.pressure then
        return Raster.pathTexVar(op.pts, Pens.radii(op, st, 1), put, st, op.seed or 0)
    end
    return Raster.pathTex(op.pts, op.width / 2, put, st, op.seed or 0)
end

-- The calligraphy nib along pts, `width` long at full pressure.
function Pens.nib(pts, pr, width, st, put)
    local lens
    if pr then
        lens = {}
        for i = 1, #pr do lens[i] = width * factor(st, pr[i]) end
    end
    local thick = width * (st.thin or 0.16)
    if thick < 1 then thick = 1 end
    Raster.pathNib(pts, width, thick, NIB, put, lens)
end

-- One live segment from (x0, y0, p0) to (x1, y1, p1) at full radius r (already
-- scaled to the target), or a dot when x0 is nil. Draws exactly what Pens.paint
-- draws for that piece of the stroke.
function Pens.segment(st, seg, r, p0, p1, put, seed)
    local single = #seg == 2
    if st.engine == "nib" then
        local w = 2 * r
        return Pens.nib(seg, single and { p1 } or { p0, p1 }, w, st, put)
    end
    local rs
    if single then
        rs = { r * factor(st, p1) }
    else
        local a, b = Pens.segRadii(st, r, p0, p1, seg[3] - seg[1], seg[4] - seg[2])
        rs = { a, b }
    end
    if st.engine == "var" then return Raster.pathVar(seg, rs, put) end
    return Raster.pathTexVar(seg, rs, put, st, seed or 0)
end

------------------------------------------------------------------------------
-- Pressure: from the pen, or simulated from speed
------------------------------------------------------------------------------

-- A raw pen pressure in [0, max] to 0-255 through the reader's curve: "soft"
-- reaches full width with a light touch, "firm" needs a harder press.
local GAMMA = { soft = 0.6, medium = 1.0, firm = 1.6 }
function Pens.fromRaw(raw, max, curve)
    if not raw or not max or max <= 0 then return nil end
    local p = raw / max
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    p = p ^ (GAMMA[curve or "medium"] or 1)
    return floor(p * 255 + 0.5)
end

-- Ease the pressure from `prev` towards `p` over the distance moved (mm), so a
-- noisy sensor or a jump between samples never leaves a blob.
function Pens.smooth(prev, p, dist_mm)
    if not prev then return p end
    local k = 1 - exp(-(dist_mm or 0) / 1.2)
    return floor(prev + (p - prev) * k + 0.5)
end

-- Pressure from speed, for a pen without a sensor or a finger: slow is full,
-- fast thins to 35%. `speed` is in mm per millisecond.
function Pens.fromSpeed(speed)
    local p = 1.05 - (speed or 0) * 2.3
    if p < 0.35 then p = 0.35 elseif p > 1 then p = 1 end
    return floor(p * 255 + 0.5)
end

-- The distance between two points in mm, at `dpi` screen pixels per inch.
function Pens.mm(dx, dy, dpi)
    return sqrt(dx * dx + dy * dy) * 25.4 / (dpi or 300)
end

return Pens
