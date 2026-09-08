--[[
Shape rasterization: line, curve, rectangle, ellipse and triangle, each either
outlined or filled. Like the freehand rasterizer, everything is emitted through
a `put(x, y, len)` span callback, so the same code paints the on-screen preview,
the 1:1 master bitmap, and the exported image, and they always match.

Outlines are stamped as discs along the edges (via the freehand rasterizer), so
a shape's outline has the same rounded, even thickness as a pen stroke. Fills are
solid horizontal spans.

A shape op looks like:
    { kind = "shape", shape = "line"|"curve"|"rect"|"ellipse"|"triangle",
      fill = true|false, width = <px>, alpha = .., color = {r,g,b},
      pts = { x0,y0, x1,y1 [, cx,cy] } }   -- cx,cy is the curve control point
]]

local Raster = require("ink/raster")

local Shapes = {}

local floor, ceil, min, max, sqrt = math.floor, math.ceil, math.min, math.max, math.sqrt

-- Fill rows y0..y1, asking `rowspan(y)` for the left/right x of the run.
local function fillRows(y0, y1, rowspan, put)
    for y = floor(y0 + 0.5), floor(y1 + 0.5) do
        local xl, xr = rowspan(y)
        if xl and xr then
            xl = floor(xl + 0.5)
            xr = floor(xr + 0.5)
            if xr >= xl then put(xl, y, xr - xl + 1) end
        end
    end
end

-- Sample a quadratic Bezier (p0, control c, p1) into a flat polyline.
local function bezier(x0, y0, cx, cy, x1, y1, steps)
    local poly = {}
    for i = 0, steps do
        local t = i / steps
        local mt = 1 - t
        local a, b, c = mt * mt, 2 * mt * t, t * t
        poly[#poly + 1] = a * x0 + b * cx + c * x1
        poly[#poly + 1] = a * y0 + b * cy + c * y1
    end
    return poly
end

-- Render a shape op with the given span writer. `put` is already coloured and
-- clips to its target, so this only has to produce the geometry.
function Shapes.render(op, put)
    local p = op.pts
    local x0, y0, x1, y1 = p[1], p[2], p[3], p[4]
    local r = (op.width or 2) / 2
    local s = op.shape

    if s == "line" then
        Raster.path({ x0, y0, x1, y1 }, r, put)

    elseif s == "curve" then
        local cx = p[5] or (x0 + x1) / 2
        local cy = p[6] or (y0 + y1) / 2
        Raster.path(bezier(x0, y0, cx, cy, x1, y1, 28), r, put)

    elseif s == "rect" then
        local ax0, ay0 = min(x0, x1), min(y0, y1)
        local ax1, ay1 = max(x0, x1), max(y0, y1)
        if op.fill then
            fillRows(ay0, ay1, function() return ax0, ax1 end, put)
        else
            Raster.path({ ax0, ay0, ax1, ay0, ax1, ay1, ax0, ay1, ax0, ay0 }, r, put)
        end

    elseif s == "ellipse" then
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        local rx, ry = math.abs(x1 - x0) / 2, math.abs(y1 - y0) / 2
        if rx < 0.5 or ry < 0.5 then
            Raster.path({ x0, y0, x1, y1 }, r, put)
            return
        end
        if op.fill then
            fillRows(cy - ry, cy + ry, function(y)
                local dy = (y - cy) / ry
                if dy < -1 or dy > 1 then return end
                local dx = rx * sqrt(max(0, 1 - dy * dy))
                return cx - dx, cx + dx
            end, put)
        else
            local steps = max(24, floor(rx + ry))
            local poly = {}
            for i = 0, steps do
                local a = (i / steps) * 2 * math.pi
                poly[#poly + 1] = cx + rx * math.cos(a)
                poly[#poly + 1] = cy + ry * math.sin(a)
            end
            Raster.path(poly, r, put)
        end

    elseif s == "triangle" then
        -- apex at the top-centre of the box, base along the bottom
        local ax0, ay0 = min(x0, x1), min(y0, y1)
        local ax1, ay1 = max(x0, x1), max(y0, y1)
        local vx = { (ax0 + ax1) / 2, ax0, ax1 }
        local vy = { ay0, ay1, ay1 }
        if op.fill then
            fillRows(ay0, ay1, function(y)
                local xs = {}
                local function edge(i, j)
                    local yi, yj = vy[i], vy[j]
                    if yi ~= yj and ((y >= yi and y <= yj) or (y >= yj and y <= yi)) then
                        local t = (y - yi) / (yj - yi)
                        xs[#xs + 1] = vx[i] + t * (vx[j] - vx[i])
                    end
                end
                edge(1, 2); edge(2, 3); edge(3, 1)
                if #xs >= 2 then return min(xs[1], xs[2]), max(xs[1], xs[2]) end
            end, put)
        else
            Raster.path({ vx[1], vy[1], vx[2], vy[2], vx[3], vy[3], vx[1], vy[1] }, r, put)
        end
    end
end

-- Bounding box {x0,y0,x1,y1} of a shape's control points (endpoints and, for a
-- curve, the control point). Callers pad by the width.
function Shapes.bounds(op)
    local p = op.pts
    local x0, y0 = min(p[1], p[3]), min(p[2], p[4])
    local x1, y1 = max(p[1], p[3]), max(p[2], p[4])
    if p[5] then
        x0, y0 = min(x0, p[5]), min(y0, p[6])
        x1, y1 = max(x1, p[5]), max(y1, p[6])
    end
    return x0, y0, x1, y1
end

return Shapes
