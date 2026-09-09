--[[
Turns a stroke into pixels. The screen and the saved file both go through here,
so what you see on the canvas is what lands in the exported image.

A stroke is drawn by stamping filled discs along its path. Each disc comes out
as a few horizontal spans, handed to a `put(x, y, len)` callback. The caller
decides what a span means: paint black on the screen, write opaque pixels into
the export buffer, clear pixels back to transparent for the eraser, and so on.
Keeping the geometry here and the pixel writing in the callback means there is
one rasterizer and no way for the screen and the export to drift apart.

Stamping discs along a path is a common way to rasterize a brush stroke.
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

-- Give back the horizontal spans of a filled disc of radius r centred at
-- (cx, cy). Coordinates are rounded to the pixel grid so callers get whole
-- number spans.
function Raster.disc(cx, cy, r, put)
    if r < 0.5 then r = 0.5 end
    local r2 = r * r
    local icx = math.floor(cx + 0.5)
    local icy = math.floor(cy + 0.5)
    local ir = math.floor(r)
    for dy = -ir, ir do
        -- half the disc's width at this row
        local span = math.floor(math.sqrt(r2 - dy * dy) + 0.5)
        if span >= 0 then
            put(icx - span, icy + dy, 2 * span + 1)
        end
    end
end

-- Stamp a disc roughly every pixel along each segment so the path comes out as
-- a continuous line instead of a row of dots. `pts` is a flat array
-- {x1,y1,x2,y2,...}. A single point (one coordinate pair) stamps one dot.
function Raster.path(pts, r, put)
    local n = math.floor(#pts / 2)
    if n == 0 then return end
    local px, py = pts[1], pts[2]
    Raster.disc(px, py, r, put)
    for i = 2, n do
        local nx, ny = pts[2 * i - 1], pts[2 * i]
        local dx, dy = nx - px, ny - py
        local dist2 = dx * dx + dy * dy
        if dist2 >= 1 then
            local steps = math.ceil(math.sqrt(dist2))
            local inv = 1 / steps
            for s = 1, steps do
                Raster.disc(px + dx * (s * inv), py + dy * (s * inv), r, put)
            end
        else
            Raster.disc(nx, ny, r, put)
        end
        px, py = nx, ny
    end
end

-- Textured pen styles. Each is a per-pixel test: given the pixel, its distance
-- from the stamp centre (0 at centre, 1 at the rim) and the stable hash, decide
-- whether to ink it. This is how the styles get their distinct feel on grey
-- e-ink, where "lighter" is really "fewer black pixels among the white".
--   density : base fraction of pixels inked
--   edge    : how much thinner the ink gets toward the rim (0 = flat)
--   grow    : how far past the nominal radius the texture scatters (fraction)
--   pattern : nil | "hatch" (diagonal lines) | "stipple" (coarse dots) | "streak"
--   blotch  : uneven, cloudy coverage (for a washy look)
-- Per style:
--   density  : base fraction of pixels inked
--   cell     : grain clump size in px (grains this big read as pigment, not TV
--              static; 1 = finest)
--   edge     : fade toward the rim (soft, dry edge) 0..1
--   edgedark : build up toward the rim (wet pooling) 0..1
--   grow     : how far past the radius the texture scatters (fraction)
--   blotch   : cloudy, uneven coverage (a wash)
--   pattern  : nil | "hatch" | "stipple" | "streak"
Raster.STYLES = {
    solid      = { solid = true },
    pencil     = { density = 0.40, cell = 1, edge = 0.45, grow = 0.05 },
    charcoal   = { density = 0.95, cell = 2, edge = 0.30, grow = 0.35 },
    marker     = { density = 0.66, cell = 1, edge = 0.05, grow = 0.02 },
    watercolor = { density = 0.62, cell = 3, edgedark = 0.55, grow = 0.45, blotch = true },
    acrylic    = { density = 0.92, cell = 2, edge = 0.15, grow = 0.10, pattern = "streak" },
    hatch      = { density = 1.00, cell = 1, pattern = "hatch" },
    stipple    = { density = 0.55, cell = 3, edge = 0.15, grow = 0.10 },
}

local floor, sqrt = math.floor, math.sqrt

-- Whether pixel (x,y) at relative distance t (0..1+grow) is inked for this style.
local function inked(st, x, y, t, seed)
    local grow = st.grow or 0
    if t > 1 + grow then return false end
    local p = st.density or 1
    local tc = t > 1 and 1 or t
    if st.edge then p = p * (1 - st.edge * tc * tc) end          -- dry, fading edge
    if st.edgedark then p = p * (1 + st.edgedark * tc * tc) end  -- wet, pooling edge
    if t > 1 then p = p * 0.35 * (1 - (t - 1) / grow) end        -- soft fringe past rim
    local pat = st.pattern
    if pat == "hatch" then
        if ((x - y) % 7) >= 2 then return false end
    elseif pat == "streak" then
        if hash01(0, floor(y / 2), seed) > 0.85 then return false end
    end
    if st.blotch then
        p = p * (0.45 + 0.75 * hash01(floor(x / 7), floor(y / 7), seed + 9))
    end
    local cell = st.cell or 1
    local h = (cell > 1) and hash01(floor(x / cell), floor(y / cell), seed)
                          or hash01(x, y, seed)
    return h < p
end

-- A textured disc for style `st`.
function Raster.discTex(cx, cy, r, put, st, seed)
    if r < 0.5 then r = 0.5 end
    local rmax = r * (1 + (st.grow or 0))
    local icx, icy = floor(cx + 0.5), floor(cy + 0.5)
    local ir = floor(rmax)
    for dy = -ir, ir do
        local y = icy + dy
        for dx = -ir, ir do
            local d = sqrt(dx * dx + dy * dy) / r
            if d <= 1 + (st.grow or 0) then
                local x = icx + dx
                if inked(st, x, y, d, seed) then put(x, y, 1) end
            end
        end
    end
end

-- Like Raster.path but with a textured pen style.
function Raster.pathTex(pts, r, put, st, seed)
    local n = floor(#pts / 2)
    if n == 0 then return end
    local px, py = pts[1], pts[2]
    Raster.discTex(px, py, r, put, st, seed)
    for i = 2, n do
        local nx, ny = pts[2 * i - 1], pts[2 * i]
        local dx, dy = nx - px, ny - py
        local dist2 = dx * dx + dy * dy
        if dist2 >= 1 then
            local steps = math.ceil(sqrt(dist2))
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
