--[[
On-device handwriting recognition, kept pure so it unit-tests without a KOReader
environment. It recognises hand-PRINTED characters (one at a time, after the
caller has segmented a word into characters) using the $P point-cloud recogniser
(Vatavu, Anthony & Wobbrock, 2012).

Why $P: a drawn character is a small set of strokes whose points, taken together,
form a cloud. $P matches two clouds by summing nearest-neighbour distances, so it
is naturally multi-stroke and independent of stroke order and direction -- exactly
the freedom a person needs when printing a letter (crossbars first or last, an
'X' either way). It needs no training run and no floating-point model, just a set
of template clouds to compare against; those templates can be produced from any
font's glyphs (see ink/view.lua), which is what lets this cover more than Latin.

Everything here is plain Lua and side-effect free:

  * Recognizer.normalize(strokes)      -> a normalized point cloud
  * Recognizer.makeTemplate(label, strokes)
  * rec:recognize(strokes)             -> label, score, ranked[]

`strokes` is a list of strokes, each a list of {x=, y=} points (screen or canvas
coordinates -- normalisation removes position and scale).
]]

local Hwr = {}

local N = 32          -- points every cloud is resampled to
local ORIGIN = { x = 0, y = 0 }

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function pathLength(pts)
    local d = 0
    for i = 2, #pts do d = d + dist(pts[i - 1], pts[i]) end
    return d
end

-- Resample one stroke to exactly `n` evenly-spaced points along its length.
local function resampleStroke(pts, n)
    if #pts == 0 then return {} end
    if #pts == 1 or n <= 1 then
        local out = {}
        for i = 1, n do out[i] = { x = pts[1].x, y = pts[1].y } end
        return out
    end
    local I = pathLength(pts) / (n - 1)
    if I == 0 then
        local out = {}
        for i = 1, n do out[i] = { x = pts[1].x, y = pts[1].y } end
        return out
    end
    local out = { { x = pts[1].x, y = pts[1].y } }
    local D = 0
    local i = 2
    local src = {}
    for k = 1, #pts do src[k] = { x = pts[k].x, y = pts[k].y } end
    while i <= #src do
        local d = dist(src[i - 1], src[i])
        if D + d >= I and d > 0 then
            local t = (I - D) / d
            local q = { x = src[i - 1].x + t * (src[i].x - src[i - 1].x),
                        y = src[i - 1].y + t * (src[i].y - src[i - 1].y) }
            out[#out + 1] = q
            table.insert(src, i, q)   -- continue interpolation from the new point
            D = 0
        else
            D = D + d
        end
        i = i + 1
    end
    while #out < n do out[#out + 1] = { x = src[#src].x, y = src[#src].y } end
    while #out > n do out[#out] = nil end
    return out
end

-- Resample a multi-stroke gesture to N points, splitting N across strokes in
-- proportion to their length so pen-up gaps are never interpolated across (that
-- would draw a phantom line between, say, an 'i' and its dot).
local function resample(strokes)
    local lens, total = {}, 0
    for s = 1, #strokes do
        local l = pathLength(strokes[s])
        -- give a zero-length stroke (a dot) a small nominal share
        if l <= 0 then l = 0.0001 end
        lens[s] = l; total = total + l
    end
    if total <= 0 then return {} end
    local cloud = {}
    local assigned = 0
    for s = 1, #strokes do
        local n_s
        if s == #strokes then
            n_s = N - assigned
        else
            n_s = math.floor(N * lens[s] / total + 0.5)
            n_s = math.max(1, math.min(n_s, N - assigned - (#strokes - s)))
        end
        if n_s > 0 then
            local rs = resampleStroke(strokes[s], n_s)
            for k = 1, #rs do cloud[#cloud + 1] = rs[k] end
            assigned = assigned + n_s
        end
    end
    return cloud
end

-- Scale a cloud uniformly into a unit square (aspect ratio kept), then move its
-- centroid to the origin.
local function scaleAndTranslate(cloud)
    if #cloud == 0 then return cloud end
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #cloud do
        local p = cloud[i]
        if p.x < minX then minX = p.x end
        if p.y < minY then minY = p.y end
        if p.x > maxX then maxX = p.x end
        if p.y > maxY then maxY = p.y end
    end
    local size = math.max(maxX - minX, maxY - minY)
    if size <= 0 then size = 1 end
    local cx, cy = 0, 0
    for i = 1, #cloud do
        cloud[i] = { x = (cloud[i].x - minX) / size, y = (cloud[i].y - minY) / size }
        cx = cx + cloud[i].x; cy = cy + cloud[i].y
    end
    cx, cy = cx / #cloud, cy / #cloud
    for i = 1, #cloud do
        cloud[i].x = cloud[i].x - cx + ORIGIN.x
        cloud[i].y = cloud[i].y - cy + ORIGIN.y
    end
    return cloud
end

-- Normalise a multi-stroke gesture to a comparable N-point cloud.
function Hwr.normalize(strokes)
    return scaleAndTranslate(resample(strokes))
end

-- Normalise a RAW point cloud (not strokes) -- e.g. the inked pixels sampled from
-- a font glyph -- to a comparable N-point cloud. Downsamples (or pads) to exactly
-- N points, then scales + translates like a gesture, so a glyph template and a
-- handwritten gesture live in the same space.
function Hwr.normalizeCloud(points)
    local n = #points
    if n == 0 then return {} end
    local out = {}
    if n <= N then
        for i = 1, n do out[i] = { x = points[i].x, y = points[i].y } end
        while #out < N do out[#out + 1] = { x = points[n].x, y = points[n].y } end
    else
        for i = 1, N do
            local idx = math.floor((i - 1) * (n - 1) / (N - 1) + 0.5) + 1
            if idx > n then idx = n end
            out[i] = { x = points[idx].x, y = points[idx].y }
        end
    end
    return scaleAndTranslate(out)
end

-- $P cloud distance: sum of weighted nearest-neighbour distances, walking the
-- points from `start` and weighting earlier matches more (an approximation that
-- makes the greedy match order-robust).
local function cloudDistance(pts, tmpl, start)
    local n = #pts
    local matched = {}
    local sum = 0
    local i = start
    repeat
        local best, index = math.huge, -1
        for j = 1, n do
            if not matched[j] then
                local d = dist(pts[i], tmpl[j])
                if d < best then best = d; index = j end
            end
        end
        if index == -1 then break end
        matched[index] = true
        local weight = 1 - ((i - start + n) % n) / n
        sum = sum + weight * best
        i = (i % n) + 1
    until i == start
    return sum
end

-- Greedy cloud match: try a few start indices in both directions, keep the least.
local function greedyMatch(pts, tmpl)
    local n = #pts
    if n == 0 or #tmpl ~= n then return math.huge end
    local step = math.max(1, math.floor(n ^ 0.5))
    local best = math.huge
    for i = 1, n, step do
        local d1 = cloudDistance(pts, tmpl, i)
        local d2 = cloudDistance(tmpl, pts, i)
        if d1 < best then best = d1 end
        if d2 < best then best = d2 end
    end
    return best
end

-- Split a page of loose strokes into reading order: group them into lines (by
-- vertical position), then within each line into characters (by horizontal gaps),
-- emitting spaces for wide gaps and a newline between lines. Returns a flat token
-- list: { {kind="char", strokes={...}}, {kind="space"}, {kind="newline"} ... }.
-- Pure; thresholds are relative to the median stroke height so it scales with the
-- writing. The caller recognises each "char" token's strokes.
local function strokeBBox(s)
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #s do
        local p = s[i]
        if p.x < minx then minx = p.x end
        if p.x > maxx then maxx = p.x end
        if p.y < miny then miny = p.y end
        if p.y > maxy then maxy = p.y end
    end
    return minx, miny, maxx, maxy
end

function Hwr.segment(strokes, tune)
    tune = tune or {}
    local S = {}
    for i = 1, #strokes do
        if #strokes[i] > 0 then
            local minx, miny, maxx, maxy = strokeBBox(strokes[i])
            S[#S + 1] = { s = strokes[i], minx = minx, maxx = maxx, miny = miny, maxy = maxy,
                          cx = (minx + maxx) / 2, cy = (miny + maxy) / 2, h = maxy - miny }
        end
    end
    if #S == 0 then return {} end
    local hs = {}
    for i = 1, #S do hs[i] = math.max(S[i].h, 1) end
    table.sort(hs)
    local H = hs[math.ceil(#hs / 2)]
    if H <= 0 then H = 1 end
    local char_gap = (tune.char_gap or 0.35) * H
    local space_gap = (tune.space_gap or 1.1) * H
    local line_gap = (tune.line_gap or 0.8) * H

    -- cluster into lines by vertical centre (greedy over strokes sorted top-down)
    table.sort(S, function(a, b) return a.cy < b.cy end)
    local lines = {}
    for _, st in ipairs(S) do
        local line = lines[#lines]
        if line and (st.cy - line.cy_max) <= line_gap then
            line[#line + 1] = st
            line.cy_max = math.max(line.cy_max, st.cy)
        else
            local nl = { st, cy_max = st.cy }
            lines[#lines + 1] = nl
        end
    end

    local tokens = {}
    for li, line in ipairs(lines) do
        if li > 1 then tokens[#tokens + 1] = { kind = "newline" } end
        table.sort(line, function(a, b) return a.cx < b.cx end)
        -- group strokes into characters by horizontal gaps
        local group, group_maxx
        local function flush()
            if group then tokens[#tokens + 1] = { kind = "char", strokes = group } end
            group, group_maxx = nil, nil
        end
        for _, st in ipairs(line) do
            if not group then
                group = { st.s }; group_maxx = st.maxx
            else
                local gap = st.minx - group_maxx
                if gap > space_gap then
                    flush(); tokens[#tokens + 1] = { kind = "space" }
                    group = { st.s }; group_maxx = st.maxx
                elseif gap > char_gap then
                    flush(); group = { st.s }; group_maxx = st.maxx
                else
                    group[#group + 1] = st.s          -- same character (overlapping strokes)
                    group_maxx = math.max(group_maxx, st.maxx)
                end
            end
        end
        flush()
    end
    return tokens
end

local Recognizer = {}
Recognizer.__index = Recognizer
Hwr.Recognizer = Recognizer

-- templates: optional list of { label=, cloud= } (already normalised).
function Recognizer.new(templates)
    return setmetatable({ templates = templates or {} }, Recognizer)
end

function Recognizer:add(label, strokes_or_cloud, is_cloud)
    self.templates[#self.templates + 1] = {
        label = label,
        cloud = is_cloud and strokes_or_cloud or Hwr.normalize(strokes_or_cloud),
    }
end

function Recognizer:count() return #self.templates end

-- Recognise a gesture. Returns best_label, score (0..1, higher is better), and a
-- ranked list { {label, score} ... }. Returns nil when there is nothing to match.
function Recognizer:recognize(strokes)
    if #self.templates == 0 then return nil end
    local cloud = Hwr.normalize(strokes)
    if #cloud == 0 then return nil end
    -- half the diagonal of the unit square is the worst plausible mean distance;
    -- use it to turn a raw distance into a 0..1 score.
    local maxDist = 0.5 * math.sqrt(2)
    local ranked = {}
    for _, t in ipairs(self.templates) do
        local d = greedyMatch(cloud, t.cloud)
        local score = 1 - (d / #cloud) / maxDist
        if score < 0 then score = 0 end
        ranked[#ranked + 1] = { label = t.label, score = score, dist = d }
    end
    table.sort(ranked, function(a, b) return a.dist < b.dist end)
    return ranked[1].label, ranked[1].score, ranked
end

Hwr.N = N
return Hwr
