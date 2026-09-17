--[[
Shape assist (beautify): turn a rough freehand pen stroke into clean, straight,
connected segments.

`detect` looks at one finished stroke (a flat {x,y,...} point list in canvas
coordinates) and returns a NEW flat point path to draw in its place, or nil when
the stroke is not confidently a straight/piecewise-straight/round shape (a smooth
curve, a scribble, or handwriting is left exactly as drawn).

It returns a POINT PATH so an arbitrary many-segment stroke can be straightened as
one connected path. When the stroke reads as one of the toolbar primitives (a
straight line, rectangle, ellipse or triangle) it ALSO returns a second value: a
compact shape descriptor { shape = "line"|"rect"|"ellipse"|"poly", pts = {..},
closed = .. }. The caller turns those into a real shape op so they can be tapped,
moved and edited exactly like a shape drawn from the toolbar; the straightened
non-primitive paths (an L bend, a general polygon) have no descriptor and stay ink
ops, keeping the pen/brush the user drew with.

What it produces:
  * a nearly straight stroke                -> one straight line (snapped to
                                               horizontal/vertical within ~8 deg)
  * a right-angle bend drawn in one stroke  -> two clean perpendicular arms
                                               meeting at one corner (x/y axes)
  * a closed 4-corner box near its bounds   -> a crisp axis-aligned rectangle
  * a round closed loop                     -> a clean ellipse
  * anything else piecewise-straight        -> its corners joined by straight
                                               lines (open or closed), preserving
                                               orientation and proportions
Closed paths repeat the first point at the end so the loop is drawn closed.
]]

local Geom = require("ink/geom")

local sqrt, abs, deg, acos = math.sqrt, math.abs, math.deg, math.acos
local min, max, floor = math.min, math.max, math.floor

local Recognize = {}

local function dist(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return sqrt(dx * dx + dy * dy)
end

local function pathLen(p)
    local L = 0
    for i = 1, #p - 3, 2 do L = L + dist(p[i], p[i + 1], p[i + 2], p[i + 3]) end
    return L
end

local function maxPerp(p, ax, ay, bx, by)
    local vx, vy = bx - ax, by - ay
    local len = sqrt(vx * vx + vy * vy)
    if len < 1e-6 then return 0 end
    local inv, m = 1 / len, 0
    for i = 1, #p - 1, 2 do
        local d = abs((p[i + 1] - ay) * vx - (p[i] - ax) * vy) * inv
        if d > m then m = d end
    end
    return m
end

local function snapLine(x0, y0, x1, y1)
    local adx, ady = abs(x1 - x0), abs(y1 - y0)
    if ady <= 0.14 * adx then
        local my = (y0 + y1) / 2; y0, y1 = my, my
    elseif adx <= 0.14 * ady then
        local mx = (x0 + x1) / 2; x0, x1 = mx, mx
    end
    return x0, y0, x1, y1
end

local function nearBoxCorners(verts, x0, y0, x1, y1, tol)
    local corners = { { x0, y0 }, { x1, y0 }, { x1, y1 }, { x0, y1 } }
    for i = 1, #verts, 2 do
        local best = math.huge
        for _, c in ipairs(corners) do
            local d = dist(verts[i], verts[i + 1], c[1], c[2])
            if d < best then best = d end
        end
        if best > tol then return false end
    end
    return true
end

local function ellipseError(p, cx, cy, rx, ry)
    if rx < 1 or ry < 1 then return math.huge end
    local err, cnt = 0, 0
    for i = 1, #p - 1, 2 do
        local nx = (p[i] - cx) / rx
        local ny = (p[i + 1] - cy) / ry
        err = err + abs(sqrt(nx * nx + ny * ny) - 1)
        cnt = cnt + 1
    end
    if cnt == 0 then return math.huge end
    return err / cnt
end

-- Corner vertices of a closed loop. RDP cannot run on the loop directly (its
-- first and last points coincide, so the baseline is degenerate and it collapses
-- to nothing), so split it at its two farthest-apart points and RDP each arc.
local function closedVertices(p, tol)
    local n = floor(#p / 2)
    if n < 3 then return {} end
    local function P(k) k = ((k - 1) % n) + 1; return p[2 * k - 1], p[2 * k] end

    local cx, cy = 0, 0
    for k = 1, n do cx = cx + p[2 * k - 1]; cy = cy + p[2 * k] end
    cx, cy = cx / n, cy / n

    local A, bd = 1, -1
    for k = 1, n do
        local x, y = P(k); local d = (x - cx) ^ 2 + (y - cy) ^ 2
        if d > bd then bd, A = d, k end
    end
    local ax, ay = P(A)
    local B, bd2 = A, -1
    for k = 1, n do
        local x, y = P(k); local d = (x - ax) ^ 2 + (y - ay) ^ 2
        if d > bd2 then bd2, B = d, k end
    end

    local function arc(from, to)
        local out, k = {}, from
        while true do
            local x, y = P(k); out[#out + 1] = x; out[#out + 1] = y
            if k == to then break end
            k = (k % n) + 1
        end
        return out
    end
    local a1 = Geom.rdp(arc(A, B), tol)
    local a2 = Geom.rdp(arc(B, A), tol)
    local verts = {}
    for i = 1, #a1 do verts[i] = a1[i] end
    for i = 3, #a2 - 2, 2 do verts[#verts + 1] = a2[i]; verts[#verts + 1] = a2[i + 1] end
    return verts
end

-- Straight-line deviation (0 = straight through, 90 = right angle) at vertex k
-- of a vertex list, using neighbours (wrapping when closed).
local function cornerDev(v, k, closed)
    local n = #v
    local pk, nk
    if closed then
        pk, nk = ((k - 2) % n) + 1, (k % n) + 1
    else
        if k == 1 or k == n then return 180 end
        pk, nk = k - 1, k + 1
    end
    local px, py = v[pk][1], v[pk][2]
    local qx, qy = v[k][1], v[k][2]
    local rx, ry = v[nk][1], v[nk][2]
    local v1x, v1y = px - qx, py - qy
    local v2x, v2y = rx - qx, ry - qy
    local m1 = sqrt(v1x * v1x + v1y * v1y)
    local m2 = sqrt(v2x * v2x + v2y * v2y)
    if m1 < 1e-6 or m2 < 1e-6 then return 0 end
    local c = (v1x * v2x + v1y * v2y) / (m1 * m2)
    return 180 - deg(acos(max(-1, min(1, c))))
end

local function segLen(v, k, closed)
    local n = #v
    local nk = (k % n) + 1
    if not closed and k == n then return math.huge end
    return dist(v[k][1], v[k][2], v[nk][1], v[nk][2])
end

-- Drop vertices that are not real corners: nearly straight (small deviation) or
-- that make a too-short segment. Endpoints of an open path are always kept.
local function pruneCorners(v, closed, dev_min, min_seg)
    while true do
        local n = #v
        if (closed and n <= 3) or (not closed and n <= 2) then break end
        local wi, wcost
        local lo, hi = (closed and 1 or 2), (closed and n or n - 1)
        for k = lo, hi do
            local dev = cornerDev(v, k, closed)
            local short = segLen(v, k, closed) < min_seg or
                          segLen(v, ((k - 2) % n) + 1, closed) < min_seg
            if dev < dev_min or short then
                local cost = dev
                if not wi or cost < wcost then wi, wcost = k, cost end
            end
        end
        if not wi then break end
        table.remove(v, wi)
    end
    return v
end

-- Distance from a point to a segment (clamped to the segment).
local function ptSeg(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local L2 = dx * dx + dy * dy
    if L2 < 1e-9 then return dist(px, py, ax, ay) end
    local t = ((px - ax) * dx + (py - ay) * dy) / L2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return dist(px, py, ax + t * dx, ay + t * dy)
end

-- Largest distance from any original point to the vertex polyline.
local function polyFaithful(pts, v, closed)
    local n = #v
    local segs = closed and n or (n - 1)
    local worst = 0
    for i = 1, #pts - 1, 2 do
        local px, py = pts[i], pts[i + 1]
        local best = math.huge
        for k = 1, segs do
            local nk = (k % n) + 1
            local d = ptSeg(px, py, v[k][1], v[k][2], v[nk][1], v[nk][2])
            if d < best then best = d end
        end
        if best > worst then worst = best end
    end
    return worst
end

-- flat {x,y,...} -> list of {x,y}
local function toVerts(flat)
    local v = {}
    for i = 1, #flat - 1, 2 do v[#v + 1] = { flat[i], flat[i + 1] } end
    return v
end

-- {x,y} list -> flat, appending the first point when closed to draw the loop shut
local function toFlat(v, closed)
    local out = {}
    for i = 1, #v do out[#out + 1] = v[i][1]; out[#out + 1] = v[i][2] end
    if closed and #v > 0 then out[#out + 1] = v[1][1]; out[#out + 1] = v[1][2] end
    return out
end

-- Try to straighten a stroke into connected corner-to-corner segments. Returns a
-- flat path or nil when the corners do not faithfully capture the stroke (i.e. it
-- was a smooth curve, not a set of straight pieces).
local function cornerPath(pts, diag, closed)
    local raw = closed and closedVertices(pts, max(2, 0.03 * diag))
                        or Geom.rdp(pts, max(2, 0.03 * diag))
    local v = toVerts(raw)
    v = pruneCorners(v, closed, 22, 0.05 * diag)
    if #v < 3 or #v > 16 then return nil end
    -- The straightened polyline must still hug the stroke closely. A genuine
    -- piecewise-straight stroke does (nothing worth pruning was pruned); a smooth
    -- curve does NOT -- pruning its gentle vertices pulls the polyline off the
    -- arc -- so this is what keeps arcs and gentle waves freehand.
    if polyFaithful(pts, v, closed) > 0.045 * diag then return nil end
    return toFlat(v, closed)
end

-- Twice the (unsigned) area of triangle a-b-c.
local function triArea2(a, b, c)
    return abs((b[1] - a[1]) * (c[2] - a[2]) - (c[1] - a[1]) * (b[2] - a[2]))
end

-- Snap a closed stroke to a clean triangle by keeping the 3 corners that enclose
-- the most area (which are the real corners even when a wobbly or overshooting
-- corner adds stray vertices), then verifying those 3 straight edges still hug the
-- whole stroke. Returns a closed 3-corner path, or nil when it is not a triangle.
local function triangleSnap(pts, diag)
    local v = toVerts(closedVertices(pts, max(2, 0.03 * diag)))
    local n = #v
    if n < 3 then return nil end
    -- the 3 corners forming the largest-area triangle, kept in loop order (i<j<k)
    local bi, bj, bk, barea = nil, nil, nil, -1
    for i = 1, n - 2 do
        for j = i + 1, n - 1 do
            for k = j + 1, n do
                local a = triArea2(v[i], v[j], v[k])
                if a > barea then barea, bi, bj, bk = a, i, j, k end
            end
        end
    end
    if not bi then return nil end
    local tv = { v[bi], v[bj], v[bk] }
    -- a real triangle, not a near-straight degenerate one (a line handles that)...
    if barea < 0.05 * diag * diag then return nil end
    -- ...and its 3 edges must still capture the whole stroke (else it is a quad,
    -- pentagon, curve, etc., where a 4th corner would stick out).
    if polyFaithful(pts, tv, true) > 0.075 * diag then return nil end
    return toFlat(tv, true)
end

-- pts: flat {x,y,...} canvas coordinates of a finished stroke.
-- opts.min_size: ignore strokes smaller than this (canvas px). Defaults to 28.
function Recognize.detect(pts, opts)
    opts = opts or {}
    local min_size = opts.min_size or 28
    if not pts or #pts < 4 then return nil end

    local x0b, y0b, x1b, y1b = Geom.bounds(pts)
    if not x0b then return nil end
    local w, h = x1b - x0b, y1b - y0b
    local diag = sqrt(w * w + h * h)
    if diag < min_size then return nil end

    local fx, fy = pts[1], pts[2]
    local lx, ly = pts[#pts - 1], pts[#pts]
    local gap = dist(fx, fy, lx, ly)
    local L = pathLen(pts)
    if L < min_size then return nil end

    -- 1) STRAIGHT LINE
    if gap >= 0.80 * L and maxPerp(pts, fx, fy, lx, ly) <= max(2, 0.08 * gap) then
        local a, b, c, d = snapLine(fx, fy, lx, ly)
        return { a, b, c, d }, { shape = "line", pts = { a, b, c, d } }
    end

    -- 2) CLOSED SHAPES: returns near its start and encloses area.
    if gap <= 0.30 * diag and L >= 1.4 * diag then
        local cv = closedVertices(pts, max(2, 0.07 * diag))
        local V = #cv / 2
        if V == 4 and nearBoxCorners(cv, x0b, y0b, x1b, y1b, 0.24 * diag) then
            return { x0b, y0b, x1b, y0b, x1b, y1b, x0b, y1b, x0b, y0b },  -- crisp rectangle
                   { shape = "rect", pts = { x0b, y0b, x1b, y1b } }
        end
        local cx, cy = (x0b + x1b) / 2, (y0b + y1b) / 2
        if ellipseError(pts, cx, cy, w / 2, h / 2) <= 0.16 then          -- clean ellipse
            local rx, ry = w / 2, h / 2
            local steps = max(24, floor((w + h) / 6))
            local out = {}
            for i = 0, steps do
                local a = (i / steps) * 2 * math.pi
                out[#out + 1] = cx + rx * math.cos(a)
                out[#out + 1] = cy + ry * math.sin(a)
            end
            return out, { shape = "ellipse", pts = { x0b, y0b, x1b, y1b } }
        end
        local tri = triangleSnap(pts, diag)                              -- crisp triangle
        if tri then
            -- an arbitrary (possibly scalene) triangle: carry its 3 real corners as
            -- a closed poly shape, so it is not distorted into the toolbar's
            -- isosceles bounding-box triangle.
            return tri, { shape = "poly", closed = true,
                          pts = { tri[1], tri[2], tri[3], tri[4], tri[5], tri[6] } }
        end
        return cornerPath(pts, diag, true)                               -- general polygon
    end

    -- 3) RIGHT-ANGLE BEND ("L", i.e. x/y axes): two straight arms about one corner.
    local simp = Geom.rdp(pts, max(2, 0.06 * diag))
    if #simp / 2 == 3 then
        local ax, ay = simp[1], simp[2]
        local bx, by = simp[3], simp[4]
        local cx, cy = simp[5], simp[6]
        local v1x, v1y = ax - bx, ay - by
        local v2x, v2y = cx - bx, cy - by
        local m1 = sqrt(v1x * v1x + v1y * v1y)
        local m2 = sqrt(v2x * v2x + v2y * v2y)
        if m1 > 0.4 * min_size and m2 > 0.4 * min_size then
            local cosang = (v1x * v2x + v1y * v2y) / (m1 * m2)
            local ang = deg(acos(max(-1, min(1, cosang))))
            if abs(ang - 90) <= 18 then
                local a1h = abs(v1x) >= abs(v1y)
                local a2h = abs(v2x) >= abs(v2y)
                if a1h ~= a2h then
                    local e1x, e1y = (a1h and ax or bx), (a1h and by or ay)
                    local e2x, e2y = (a2h and cx or bx), (a2h and by or cy)
                    return { e1x, e1y, bx, by, e2x, e2y }
                end
                return { ax, ay, bx, by, cx, cy }
            end
        end
    end

    -- 4) GENERAL PIECEWISE-STRAIGHT open stroke -> connected straight segments.
    return cornerPath(pts, diag, false)
end

return Recognize
