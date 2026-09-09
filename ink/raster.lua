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

-- A grainy disc: instead of a solid fill, each pixel is kept with probability
-- `density` (via the stable hash), giving a pencil/charcoal texture. Emitted as
-- single-pixel spans through `put`.
function Raster.discGrain(cx, cy, r, put, density, seed)
    if r < 0.5 then r = 0.5 end
    local r2 = r * r
    local icx, icy, ir = math.floor(cx + 0.5), math.floor(cy + 0.5), math.floor(r)
    for dy = -ir, ir do
        local span = math.floor(math.sqrt(r2 - dy * dy) + 0.5)
        local y = icy + dy
        for dx = -span, span do
            local x = icx + dx
            if hash01(x, y, seed) < density then put(x, y, 1) end
        end
    end
end

-- Like Raster.path but grainy, for pencil/charcoal styles.
function Raster.pathGrain(pts, r, put, density, seed)
    local n = math.floor(#pts / 2)
    if n == 0 then return end
    local px, py = pts[1], pts[2]
    Raster.discGrain(px, py, r, put, density, seed)
    for i = 2, n do
        local nx, ny = pts[2 * i - 1], pts[2 * i]
        local dx, dy = nx - px, ny - py
        local dist2 = dx * dx + dy * dy
        if dist2 >= 1 then
            local steps = math.ceil(math.sqrt(dist2))
            local inv = 1 / steps
            for s = 1, steps do
                Raster.discGrain(px + dx * (s * inv), py + dy * (s * inv), r, put, density, seed)
            end
        else
            Raster.discGrain(nx, ny, r, put, density, seed)
        end
        px, py = nx, ny
    end
end

-- Grain density for each pen style (nil = solid, no grain).
Raster.STYLE_DENSITY = { pencil = 0.5, charcoal = 0.72 }

return Raster
