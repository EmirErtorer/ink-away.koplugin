--[[
Turns a stroke into pixels by stamping filled discs along its path. Each disc
comes out as horizontal spans handed to a `put(x, y, len)` callback, and the
caller decides what a span means (ink on screen, opaque pixels in an export,
cleared pixels for the eraser). The screen and the export share this one
rasterizer, so they cannot drift apart.
]]

local Raster = {}

local bit = require("bit")
local band, bxor, rshift, tobit = bit.band, bit.bxor, bit.rshift, bit.tobit

-- A stable pseudo-random value in [0,1) for pixel (x,y) of a stroke `seed`. Used
-- for grain: the same pixels are chosen every redraw, so texture never flickers
-- and the export matches the screen.
local function hash01(x, y, seed)
    local h = tobit(x * 374761393)
    h = tobit(h + tobit(y * 668265263))
    h = tobit(h + tobit((seed or 0) * 2246822519))
    h = bxor(h, rshift(h, 13))
    h = tobit(h * 1274126177)
    h = bxor(h, rshift(h, 16))
    return band(h, 0xffff) / 65535
end
Raster.hash01 = hash01

local floor, sqrt, ceil, max = math.floor, math.sqrt, math.ceil, math.max
local huge = math.huge

-- Half-widths of each row of a disc of radius r (row dy -> span), cached for the
-- last few radii: a stroke draws thousands of discs with one or two radii (the
-- master and the on-screen copy), so the square roots are worked out once.
local SPAN_CACHE_N = 4
local span_keys, span_vals, span_next = {}, {}, 1
local function discSpans(r)
    for i = 1, SPAN_CACHE_N do
        if span_keys[i] == r then return span_vals[i] end
    end
    local r2 = r * r
    local ir = floor(r)
    local t = { ir = ir }
    for dy = 0, ir do t[dy] = floor(sqrt(r2 - dy * dy) + 0.5) end
    span_keys[span_next], span_vals[span_next] = r, t
    span_next = span_next % SPAN_CACHE_N + 1
    return t
end

-- Give back the horizontal spans of a filled disc of radius r centred at
-- (cx, cy). Coordinates are rounded to the pixel grid so callers get whole
-- number spans.
function Raster.disc(cx, cy, r, put)
    if r < 0.5 then r = 0.5 end
    local t = discSpans(r)
    local ir = t.ir
    local icx = floor(cx + 0.5)
    local icy = floor(cy + 0.5)
    for dy = -ir, ir do
        local span = t[dy < 0 and -dy or dy]   -- half the disc's width at this row
        put(icx - span, icy + dy, 2 * span + 1)
    end
end

-- Stamp a disc roughly every pixel along each segment, so the path is a
-- continuous line rather than a row of dots. `pts` is a flat {x1,y1,x2,y2,...}
-- array; a single point stamps one dot. The discs of one straight segment are
-- merged first, so each row gets one span instead of a disc of spans per pixel
-- step; the pixels covered are exactly the same.
local rowL, rowR = {}, {}
function Raster.path(pts, r, put)
    local n = floor(#pts / 2)
    if n == 0 then return end
    if r < 0.5 then r = 0.5 end
    local px, py = pts[1], pts[2]
    if n == 1 then return Raster.disc(px, py, r, put) end
    local t = discSpans(r)
    local ir = t.ir
    for i = 2, n do
        local nx, ny = pts[2 * i - 1], pts[2 * i]
        local dx, dy = nx - px, ny - py
        local dist2 = dx * dx + dy * dy
        if dist2 >= 1 then
            local steps = ceil(sqrt(dist2))
            local inv = 1 / steps
            -- rows this segment can touch (a row of margin for float rounding)
            local ya, yb = floor(py + 0.5), floor(ny + 0.5)
            if ya > yb then ya, yb = yb, ya end
            local y0 = ya - ir - 1
            local rows = (yb + ir + 1) - y0
            for k = 0, rows do rowL[k] = huge; rowR[k] = -huge end
            -- the first point's disc goes in with the first segment
            for s = (i == 2) and 0 or 1, steps do
                local cx, cy
                if s == 0 then cx, cy = px, py
                else cx, cy = px + dx * (s * inv), py + dy * (s * inv) end
                local icx = floor(cx + 0.5)
                local base = floor(cy + 0.5) - y0
                for ddy = -ir, ir do
                    local span = t[ddy < 0 and -ddy or ddy]
                    local k = base + ddy
                    local a, b = icx - span, icx + span
                    if a < rowL[k] then rowL[k] = a end
                    if b > rowR[k] then rowR[k] = b end
                end
            end
            for k = 0, rows do
                local a = rowL[k]
                if a ~= huge then put(a, y0 + k, rowR[k] - a + 1) end
            end
        else
            if i == 2 then Raster.disc(px, py, r, put) end
            Raster.disc(nx, ny, r, put)
        end
        px, py = nx, ny
    end
end

-- Textured pen styles. Each is a per-pixel test on the pixel, its distance from
-- the stamp centre and the stable hash, deciding whether to ink it: on e-ink a
-- lighter texture is fewer inked pixels. Fields:
--   density  base fraction of pixels inked
--   cell     grain clump size in px (1 is finest; larger reads as pigment)
--   edge     fade toward the rim, a soft dry edge (0..1)
--   edgedark build-up toward the rim, wet pooling (0..1)
--   grow     how far past the radius the texture scatters (fraction)
--   tooth    paper tooth: patches of this size (px) catch more or less grain
--   blotch   cloudy, uneven coverage (a wash)
--   pattern  nil, "hatch" (diagonal lines) or "streak"
Raster.STYLES = {
    solid      = { solid = true },
    -- pencil: fine, even grain; dark enough that black reads black, still textured
    pencil     = { density = 0.74, cell = 1, edge = 0.35, grow = 0.06 },
    charcoal   = { density = 0.82, cell = 2, edge = 0.55, grow = 0.45, tooth = 4 },
    marker     = { density = 0.66, cell = 1, edge = 0.05, grow = 0.02 },
    watercolor = { density = 0.62, cell = 3, edgedark = 0.55, grow = 0.45, blotch = true },
    acrylic    = { density = 0.92, cell = 2, edge = 0.15, grow = 0.10, pattern = "streak" },
    hatch      = { density = 1.00, cell = 1, pattern = "hatch" },
    stipple    = { density = 0.55, cell = 3, edge = 0.15, grow = 0.10 },
}

-- Register a custom brush under `key`, so ops that name it resolve like a
-- built-in style. Every saved brush is registered at startup, so a project or an
-- export always finds the style it was drawn with.
function Raster.registerStyle(key, params)
    if type(key) ~= "string" or type(params) ~= "table" then return end
    local st = {}
    for k, v in pairs(params) do st[k] = v end
    Raster.STYLES[key] = st
end

-- Is pixel (x, y) inked for this style, given d2 = (distance / r)^2? A square
-- root is taken only for the fringe beyond the rim, keeping textured brushes fast.
local function inked(st, x, y, d2, seed, outer)
    if d2 > outer then return false end
    local p = st.density or 1
    local tc2 = d2 < 1 and d2 or 1               -- min(t,1)^2
    if st.edge then p = p * (1 - st.edge * tc2) end
    if st.edgedark then p = p * (1 + st.edgedark * tc2) end
    if d2 > 1 then p = p * 0.35 * (1 - (sqrt(d2) - 1) / (st.grow or 1)) end
    local pat = st.pattern
    if pat == "hatch" then
        if ((x - y) % 6) >= 3 then return false end   -- thick diagonal hatching
    elseif pat == "streak" then
        if hash01(0, floor(y / 2), seed) > 0.85 then return false end
    end
    if st.blotch then
        p = p * (0.45 + 0.75 * hash01(floor(x / 7), floor(y / 7), seed + 9))
    end
    if st.tooth and st.tooth > 0 then   -- paper tooth: some patches catch more grain
        local tc = st.tooth
        p = p * (0.5 + 1.0 * hash01(floor(x / tc), floor(y / tc), seed + 7))
    end
    local cell = st.cell or 1
    local h = (cell > 1) and hash01(floor(x / cell), floor(y / cell), seed)
                          or hash01(x, y, seed)
    return h < p
end

-- A textured disc for style `st`. Neighbouring inked pixels on a row go out as
-- one run, and each row scans only the columns its circle can reach.
function Raster.discTex(cx, cy, r, put, st, seed)
    if r < 0.5 then r = 0.5 end
    local grow = st.grow or 0
    local outer = (1 + grow) * (1 + grow)
    local inv_r2 = 1 / (r * r)
    local icx, icy = floor(cx + 0.5), floor(cy + 0.5)
    local ir = floor(r * (1 + grow))
    local reach2 = outer * r * r
    for dy = -ir, ir do
        local y = icy + dy
        local dy2 = dy * dy
        -- a column bound that is never tighter than the d2 test below
        local w = reach2 - dy2
        local xr = (w > 0) and floor(sqrt(w)) + 1 or 1
        if xr > ir then xr = ir end
        local run
        for dx = -xr, xr do
            local d2 = (dx * dx + dy2) * inv_r2
            if d2 <= outer and inked(st, icx + dx, y, d2, seed, outer) then
                if not run then run = icx + dx end
            elseif run then
                put(run, y, icx + dx - run)
                run = nil
            end
        end
        if run then put(run, y, icx + xr + 1 - run) end
    end
end

-- Raster.path with a textured pen style. Discs are spaced wider than on the solid
-- path (the texture hides it), so textured strokes are about as fast as plain ink.
function Raster.pathTex(pts, r, put, st, seed)
    local n = floor(#pts / 2)
    if n == 0 then return end
    local step = max(1, r * 0.4)
    local px, py = pts[1], pts[2]
    Raster.discTex(px, py, r, put, st, seed)
    for i = 2, n do
        local nx, ny = pts[2 * i - 1], pts[2 * i]
        local dx, dy = nx - px, ny - py
        local dist = sqrt(dx * dx + dy * dy)
        if dist >= step then
            local steps = ceil(dist / step)
            local inv = 1 / steps
            for s = 1, steps do
                Raster.discTex(px + dx * (s * inv), py + dy * (s * inv), r, put, st, seed)
            end
        else
            Raster.discTex(nx, ny, r, put, st, seed)
        end
        px, py = nx, ny
    end
end

return Raster
