--[[
Shape rasterization: line, curve, rectangle, ellipse and triangle, each either
outlined or filled, and each optionally rotated about its centre.

Every shape is reduced to a boundary polyline (its outline, with rotation already
applied). Outlines are then stamped as discs along that polyline via the freehand
rasterizer, so a shape's edge has the same rounded, even thickness as a pen
stroke. Fills are a scanline fill of the same polygon. Working from one polyline
is what lets any shape rotate freely.

Everything is emitted through a `put(x, y, len)` span callback, so the same code
paints the on-screen preview, the 1:1 master bitmap, and the exported image.

A shape op looks like:
    { kind = "shape", shape = "line"|"curve"|"rect"|"ellipse"|"triangle",
      fill = true|false, angle = <radians>, width = <px>, alpha = .., color = {r,g,b},
      pts = { x0,y0, x1,y1 [, cx,cy] } }   -- cx,cy is the curve control point
]]

local Raster = require("ink/raster")

local Shapes = {}

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local sin, cos = math.sin, math.cos

-- Build the boundary polyline of a shape (flat {x,y,...}), with any rotation
-- applied about the shape's centre. `closed` (second return) says whether the
-- last point should join the first for a fill.
local function boundary(op)
    local p = op.pts
    local x0, y0, x1, y1 = p[1], p[2], p[3], p[4]
    local s = op.shape
    local poly, closed = {}, true

    if s == "line" then
        poly = { x0, y0, x1, y1 }
        closed = false
    elseif s == "curve" then
        local cx = p[5] or (x0 + x1) / 2
        local cy = p[6] or (y0 + y1) / 2
        for i = 0, 28 do
            local t = i / 28
            local mt = 1 - t
            local a, b, c = mt * mt, 2 * mt * t, t * t
            poly[#poly + 1] = a * x0 + b * cx + c * x1
            poly[#poly + 1] = a * y0 + b * cy + c * y1
        end
        closed = false
    elseif s == "rect" then
        local ax0, ay0 = min(x0, x1), min(y0, y1)
        local ax1, ay1 = max(x0, x1), max(y0, y1)
        poly = { ax0, ay0, ax1, ay0, ax1, ay1, ax0, ay1 }
    elseif s == "triangle" then
        local ax0, ay0 = min(x0, x1), min(y0, y1)
        local ax1, ay1 = max(x0, x1), max(y0, y1)
        poly = { (ax0 + ax1) / 2, ay0, ax0, ay1, ax1, ay1 }
    elseif s == "ellipse" then
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        local rx, ry = math.abs(x1 - x0) / 2, math.abs(y1 - y0) / 2
        local steps = max(24, floor(rx + ry))
        for i = 0, steps - 1 do
            local a = (i / steps) * 2 * math.pi
            poly[#poly + 1] = cx + rx * cos(a)
            poly[#poly + 1] = cy + ry * sin(a)
        end
    end

    -- rotate about the centre of the defining box / endpoints
    local ang = op.angle
    if ang and ang ~= 0 then
        local cx = (x0 + x1) / 2
        local cy = (y0 + y1) / 2
        local ca, sa = cos(ang), sin(ang)
        for i = 1, #poly, 2 do
            local dx, dy = poly[i] - cx, poly[i + 1] - cy
            poly[i]     = cx + dx * ca - dy * sa
            poly[i + 1] = cy + dx * sa + dy * ca
        end
    end
    return poly, closed
end

-- Even-odd scanline fill of a closed polygon given as flat {x,y,...}.
local function fillPolygon(poly, put)
    local n = floor(#poly / 2)
    if n < 3 then return end
    local ymin, ymax = poly[2], poly[2]
    for i = 2, n do
        local y = poly[2 * i]
        if y < ymin then ymin = y elseif y > ymax then ymax = y end
    end
    for y = floor(ymin + 0.5), floor(ymax + 0.5) do
        local yc = y + 0.5
        local xs = {}
        local jx, jy = poly[2 * n - 1], poly[2 * n]   -- previous vertex
        for i = 1, n do
            local ix, iy = poly[2 * i - 1], poly[2 * i]
            if (iy <= yc and jy > yc) or (jy <= yc and iy > yc) then
                xs[#xs + 1] = ix + (yc - iy) / (jy - iy) * (jx - ix)
            end
            jx, jy = ix, iy
        end
        if #xs >= 2 then
            table.sort(xs)
            for k = 1, #xs - 1, 2 do
                local xl = floor(xs[k] + 0.5)
                local xr = floor(xs[k + 1] + 0.5)
                if xr >= xl then put(xl, y, xr - xl + 1) end
            end
        end
    end
end

-- Render a shape op with the given span writer.
function Shapes.render(op, put)
    local poly, closed = boundary(op)
    local r = (op.width or 2) / 2
    if op.fill and closed then
        fillPolygon(poly, put)
    else
        -- outline: stamp discs along the polyline, closing area shapes
        local line = poly
        if closed then
            line = {}
            for i = 1, #poly do line[i] = poly[i] end
            line[#line + 1] = poly[1]
            line[#line + 1] = poly[2]
        end
        Raster.path(line, r, put)
    end
end

-- Bounding box {x0,y0,x1,y1} of the shape as actually drawn (rotation included).
function Shapes.bounds(op)
    local poly = boundary(op)
    local x0, y0 = poly[1], poly[2]
    local x1, y1 = x0, y0
    for i = 3, #poly, 2 do
        local x, y = poly[i], poly[i + 1]
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- Is point (px,py) on or inside the shape? Used to pick a shape by touch. For
-- filled/area shapes this is inside-the-polygon; for line/curve/outlines it is
-- within `tol` of the boundary polyline.
function Shapes.hit(op, px, py, tol)
    local poly, closed = boundary(op)
    local n = floor(#poly / 2)
    if op.fill and closed then
        -- point in polygon (even-odd), plus a tolerance band on the edges
        local inside = false
        local jx, jy = poly[2 * n - 1], poly[2 * n]
        for i = 1, n do
            local ix, iy = poly[2 * i - 1], poly[2 * i]
            if ((iy > py) ~= (jy > py)) and
               (px < (jx - ix) * (py - iy) / (jy - iy) + ix) then
                inside = not inside
            end
            jx, jy = ix, iy
        end
        if inside then return true end
    end
    -- distance to the boundary segments
    local last = closed and n or (n - 1)
    local t2 = tol * tol
    for i = 1, last do
        local ax, ay = poly[2 * i - 1], poly[2 * i]
        local ni = (i % n) + 1
        local bx, by = poly[2 * ni - 1], poly[2 * ni]
        local dx, dy = bx - ax, by - ay
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and ((px - ax) * dx + (py - ay) * dy) / len2 or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local ex, ey = ax + t * dx - px, ay + t * dy - py
        if ex * ex + ey * ey <= t2 then return true end
    end
    return false
end

return Shapes
