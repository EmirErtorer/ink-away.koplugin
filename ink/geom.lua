--[[
Plain coordinate and geometry helpers: moving points between screen space and
the fixed canvas, bounding boxes, joining rectangles, and thinning out strokes.

Nothing here touches KOReader, so the headless tests can call it directly.

Two well known methods do the stroke thinning: the Ramer Douglas Peucker line
simplification and a filter that drops points too close together.
]]

local Geom = {}

-- Shallow copy of a flat point list.
local function copyList(pts)
    local out = {}
    for i = 1, #pts do out[i] = pts[i] end
    return out
end

------------------------------------------------------------------------------
-- Viewport
--
-- The canvas is a fixed W x H image (the size of the device screen). It shows
-- inside a rectangular "area" of the screen (below the toolbar) at some `zoom`,
-- scrolled so that canvas point (pan_x, pan_y) sits at the top left corner of
-- that area. A view table is:
--   { area_x, area_y, area_w, area_h,  -- area rect in screen coords
--     zoom, pan_x, pan_y,              -- canvas point shown at the area corner
--     canvas_w, canvas_h }
------------------------------------------------------------------------------

-- screen -> canvas
function Geom.toCanvas(view, sx, sy)
    return view.pan_x + (sx - view.area_x) / view.zoom,
           view.pan_y + (sy - view.area_y) / view.zoom
end

-- canvas -> screen
function Geom.toScreen(view, cx, cy)
    return view.area_x + (cx - view.pan_x) * view.zoom,
           view.area_y + (cy - view.pan_y) * view.zoom
end

-- Smallest zoom that fits the whole canvas inside the area (used as the default
-- "see the whole page" view). May be < 1 when the canvas is larger than the area.
function Geom.fitZoom(view)
    return math.min(view.area_w / view.canvas_w, view.area_h / view.canvas_h)
end

-- Clamp pan so the visible window stays over the canvas. When the canvas is
-- smaller than the area in a dimension, it is centred in that dimension.
function Geom.clampPan(view)
    local vis_w = view.area_w / view.zoom
    local vis_h = view.area_h / view.zoom
    if vis_w >= view.canvas_w then
        view.pan_x = (view.canvas_w - vis_w) / 2
    else
        view.pan_x = math.max(0, math.min(view.canvas_w - vis_w, view.pan_x))
    end
    if vis_h >= view.canvas_h then
        view.pan_y = (view.canvas_h - vis_h) / 2
    else
        view.pan_y = math.max(0, math.min(view.canvas_h - vis_h, view.pan_y))
    end
end

------------------------------------------------------------------------------
-- Bounds and rectangles
------------------------------------------------------------------------------

-- Bounding box of a flat point list {x1,y1,x2,y2,...}, aligned to the axes.
-- Returns nil for an empty list.
function Geom.bounds(pts)
    local n = math.floor(#pts / 2)
    if n == 0 then return nil end
    local x0, y0 = pts[1], pts[2]
    local x1, y1 = x0, y0
    for i = 2, n do
        local x, y = pts[2 * i - 1], pts[2 * i]
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- Union of two rects given as {x,y,w,h}; either may be nil.
function Geom.mergeRect(a, b)
    if not a then return b end
    if not b then return a end
    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Clip a rect to [0,w) x [0,h), rounding outward. Returns nil if empty.
function Geom.clipRect(x, y, w, h, width, height)
    local x0 = math.max(0, math.floor(x))
    local y0 = math.max(0, math.floor(y))
    local x1 = math.min(width, math.ceil(x + w))
    local y1 = math.min(height, math.ceil(y + h))
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1 - x0, y1 - y0
end

-- Intersection test between rect {x,y,w,h} and (x,y,w,h), with optional padding.
function Geom.rectsOverlap(r, x, y, w, h, pad)
    pad = pad or 0
    return r.x - pad < x + w and x < r.x + r.w + pad
       and r.y - pad < y + h and y < r.y + r.h + pad
end

------------------------------------------------------------------------------
-- Stroke simplification
------------------------------------------------------------------------------

-- Drop points closer than `min_spacing` to the previously kept point. Keeps the
-- first and last. Input/output are flat {x,y,...} lists.
function Geom.dropClose(pts, min_spacing)
    local n = math.floor(#pts / 2)
    if n <= 2 then return copyList(pts) end
    local ms2 = min_spacing * min_spacing
    local out = { pts[1], pts[2] }
    local lx, ly = pts[1], pts[2]
    for i = 2, n - 1 do
        local x, y = pts[2 * i - 1], pts[2 * i]
        local dx, dy = x - lx, y - ly
        if dx * dx + dy * dy >= ms2 then
            out[#out + 1] = x
            out[#out + 1] = y
            lx, ly = x, y
        end
    end
    out[#out + 1] = pts[2 * n - 1]
    out[#out + 1] = pts[2 * n]
    return out
end

-- Ramer Douglas Peucker on a flat point list. Returns a flat list of the points
-- it keeps. `tol` is how far a point may sit from the line before it is kept,
-- in the same units as pts.
function Geom.rdp(pts, tol)
    local n = math.floor(#pts / 2)
    if n <= 2 then return copyList(pts) end
    local keep = {}
    for i = 1, n do keep[i] = false end
    keep[1], keep[n] = true, true
    local stack = { { 1, n } }
    while #stack > 0 do
        local seg = table.remove(stack)
        local a, b = seg[1], seg[2]
        if b > a + 1 then
            local ax, ay = pts[2 * a - 1], pts[2 * a]
            local bx, by = pts[2 * b - 1], pts[2 * b]
            local vx, vy = bx - ax, by - ay
            local len = math.sqrt(vx * vx + vy * vy)
            local inv = len > 0 and (1 / len) or 0
            local split, maxd = -1, tol
            for j = a + 1, b - 1 do
                local px, py = pts[2 * j - 1], pts[2 * j]
                -- how far point j sits from the line through a and b
                local d = math.abs((py - ay) * vx - (px - ax) * vy) * inv
                if d > maxd then maxd, split = d, j end
            end
            if split > 0 then
                keep[split] = true
                stack[#stack + 1] = { a, split }
                stack[#stack + 1] = { split, b }
            end
        end
    end
    local out = {}
    for i = 1, n do
        if keep[i] then
            out[#out + 1] = pts[2 * i - 1]
            out[#out + 1] = pts[2 * i]
        end
    end
    return out
end

------------------------------------------------------------------------------
-- Input aids: stabilizer, grid snap, angle snap
------------------------------------------------------------------------------

-- Exponential smoothing (the stabilizer). Moves the smoothed point a fraction
-- `alpha` of the way to the raw point; alpha 1 = no smoothing, small = heavy.
function Geom.ema(px, py, x, y, alpha)
    return px + (x - px) * alpha, py + (y - py) * alpha
end

-- Map a 0..100 stabilizer strength to an EMA alpha. 0 -> 1 (off); 100 -> ~0.08.
function Geom.stabilizerAlpha(strength)
    local s = math.max(0, math.min(100, strength or 0)) / 100
    return 1 - s * 0.92
end

-- Snap a point to the nearest grid intersection of the given spacing.
function Geom.snapToGrid(x, y, spacing)
    if not spacing or spacing <= 0 then return x, y end
    return math.floor(x / spacing + 0.5) * spacing,
           math.floor(y / spacing + 0.5) * spacing
end

-- Snap the segment from (x0,y0) to (x1,y1) to the nearest 45-degree direction,
-- keeping its length. Returns the adjusted end point.
function Geom.snapAngle(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return x1, y1 end
    local step = math.pi / 4
    local a = math.floor(math.atan2(dy, dx) / step + 0.5) * step
    return x0 + math.cos(a) * len, y0 + math.sin(a) * len
end

return Geom
