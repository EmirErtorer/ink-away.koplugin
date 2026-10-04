--[[
Turning printed handwriting into text, the parts that need no model: splitting
a selection of strokes into lines, words and characters, and choosing capitals.
Pure Lua, so the headless tests drive it; ink/hwrnet.lua reads each character
and ink/hwrwords.lua each word.

  * Hwr.segment(strokes)   lines of words of characters
  * Hwr.lineMetrics(chars, classes, best)   a line's x-height and baseline
  * Hwr.cased(text, ...)   a word's text with its capitals

`strokes` is a list of flat {x, y, x, y, ...} lists in the order they were
written, y down.

Characters. Strokes are taken in writing order, and each joins the character
it touches, or the one it overlaps most from side to side when that overlap is
a good part of the narrower of the two; otherwise it starts a new one. Two
characters that a later stroke makes overlap become one (the crossbar of an
H). A thin stroke counts as about a third of the writing's height wide. Dots
and other specks (an i's dot, a small t cross) come last and join the nearest
character; one with no character near is dropped (punctuation is not read).
]]

local Hwr = {}

local function median(t)
    if #t == 0 then return nil end
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    return s[math.ceil(#s / 2)]
end

local function bbox(pts)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #pts - 1, 2 do
        local x, y = pts[i], pts[i + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- How much of the narrower of two boxes their side-to-side overlap covers, each
-- box counted at least `minw` wide (around its centre).
local function overlapRatio(a, b, minw)
    local function span(o)
        local w = o.x1 - o.x0
        if w >= minw then return o.x0, o.x1, w end
        local c = (o.x0 + o.x1) / 2
        return c - minw / 2, c + minw / 2, minw
    end
    local a0, a1, aw = span(a)
    local b0, b1, bw = span(b)
    local ov = math.min(a1, b1) - math.max(a0, b0)
    if ov <= 0 then return 0 end
    return ov / math.min(aw, bw)
end

-- Does stroke `s` come within sqrt(d2) of character `c`? Boxes first, then the
-- points (sampled on long strokes).
local function touches(s, c, d2)
    local d = math.sqrt(d2)
    if s.x0 > c.x1 + d or c.x0 > s.x1 + d or s.y0 > c.y1 + d or c.y0 > s.y1 + d then return false end
    local function step(n) return math.max(1, math.floor(n / 80)) * 2 end
    local pa = s.pts
    local sa = step(#pa)
    for _, pb in ipairs(c.strokes) do
        local sb = step(#pb)
        for i = 1, #pa - 1, sa do
            local x, y = pa[i], pa[i + 1]
            for j = 1, #pb - 1, sb do
                local dx, dy = x - pb[j], y - pb[j + 1]
                if dx * dx + dy * dy <= d2 then return true end
            end
        end
    end
    return false
end

local function grow(c, s)
    c.strokes[#c.strokes + 1] = s.pts
    if s.x0 < c.x0 then c.x0 = s.x0 end
    if s.y0 < c.y0 then c.y0 = s.y0 end
    if s.x1 > c.x1 then c.x1 = s.x1 end
    if s.y1 > c.y1 then c.y1 = s.y1 end
    if s.order < c.order then c.order = s.order end
end

local JOIN = 0.4    -- a stroke joins a character it overlaps this much
local MERGE = 0.5   -- two characters overlapping this much are one
local SPACE = 0.5   -- a gap wider than this share of the letters' height is a space

-- Split strokes into lines (top to bottom) of words (left to right) of
-- characters. Returns { { words = { { chars = { c, ... } }, ... },
-- height = typical letter height }, ... }; each character is
-- { strokes = { pts, ... }, x0, y0, x1, y1 }, its strokes in writing order.
function Hwr.segment(strokes)
    local S = {}
    for i, pts in ipairs(strokes) do
        if #pts >= 2 then
            local x0, y0, x1, y1 = bbox(pts)
            S[#S + 1] = { pts = pts, order = i, x0 = x0, y0 = y0, x1 = x1, y1 = y1,
                cy = (y0 + y1) / 2, size = math.max(x1 - x0, y1 - y0) }
        end
    end
    if #S == 0 then return {} end
    local sizes = {}
    for i, s in ipairs(S) do sizes[i] = s.size end
    local all = math.max(median(sizes), 1)
    -- dots and other specks are placed after the lines are found
    local body, specks, hs = {}, {}, {}
    for _, s in ipairs(S) do
        if s.size < 0.3 * all then specks[#specks + 1] = s
        else body[#body + 1] = s; hs[#hs + 1] = s.y1 - s.y0 end
    end
    if #body == 0 then body, specks = specks, {} ; for _, s in ipairs(body) do hs[#hs + 1] = s.y1 - s.y0 end end
    local H = math.max(median(hs) or 1, 1)

    -- lines: strokes by height on the page, a new line where the centres jump
    table.sort(body, function(a, b) return a.cy < b.cy end)
    local lines = {}
    for _, s in ipairs(body) do
        local line = lines[#lines]
        if line and s.cy - line.cy_max <= 0.7 * H then
            line.strokes[#line.strokes + 1] = s
            line.cy_max = math.max(line.cy_max, s.cy)
            line.y0, line.y1 = math.min(line.y0, s.y0), math.max(line.y1, s.y1)
        else
            lines[#lines + 1] = { strokes = { s }, cy_max = s.cy, y0 = s.y0, y1 = s.y1 }
        end
    end
    for _, s in ipairs(specks) do
        local best, bd = lines[1], math.huge
        for _, line in ipairs(lines) do
            local d = (s.cy < line.y0) and (line.y0 - s.cy) or (s.cy > line.y1 and s.cy - line.y1 or 0)
            if d < bd then best, bd = line, d end
        end
        best.specks = best.specks or {}
        best.specks[#best.specks + 1] = s
    end

    local out = {}
    local minw = 0.35 * H
    local touch2 = (0.08 * H) ^ 2
    for _, line in ipairs(lines) do
        table.sort(line.strokes, function(a, b) return a.order < b.order end)
        local chars = {}
        for _, s in ipairs(line.strokes) do
            local best, br = nil, 0
            for _, c in ipairs(chars) do
                local r = overlapRatio(s, c, minw)
                -- strokes of one letter usually touch, those of two letters rarely
                if r > 0.05 and touches(s, c, touch2) then r = r + 1 end
                if r > br then best, br = c, r end
            end
            if best and br >= JOIN then
                grow(best, s)
                -- the grown character may now cover another one: merge them
                local merged = true
                while merged do
                    merged = false
                    for k = #chars, 1, -1 do
                        local d = chars[k]
                        if d ~= best and overlapRatio(best, d, minw) >= MERGE then
                            for _, pts in ipairs(d.strokes) do best.strokes[#best.strokes + 1] = pts end
                            best.x0, best.y0 = math.min(best.x0, d.x0), math.min(best.y0, d.y0)
                            best.x1, best.y1 = math.max(best.x1, d.x1), math.max(best.y1, d.y1)
                            best.order = math.min(best.order, d.order)
                            table.remove(chars, k)
                            merged = true
                        end
                    end
                end
            else
                local c = { strokes = {}, x0 = s.x0, y0 = s.y0, x1 = s.x1, y1 = s.y1, order = s.order }
                grow(c, s)
                chars[#chars + 1] = c
            end
        end
        -- dots and specks: to the nearest character, within half the height
        for _, sp in ipairs(line.specks or {}) do
            local cx = (sp.x0 + sp.x1) / 2
            local best, bd = nil, 0.5 * H
            for _, c in ipairs(chars) do
                local d = (cx < c.x0) and (c.x0 - cx) or (cx > c.x1 and cx - c.x1 or 0)
                if d <= bd then best, bd = c, d end
            end
            if best then grow(best, sp); best.specks = (best.specks or 0) + 1 end
        end
        table.sort(chars, function(a, b) return (a.x0 + a.x1) < (b.x0 + b.x1) end)
        local ch = {}
        for i, c in ipairs(chars) do ch[i] = c.y1 - c.y0 end
        local lh = math.max(median(ch) or H, 1)
        local words, word = {}, nil
        for i, c in ipairs(chars) do
            if not word or c.x0 - chars[i - 1].x1 > SPACE * lh then
                word = { chars = {} }
                words[#words + 1] = word
            end
            word.chars[#word.chars + 1] = c
        end
        out[#out + 1] = { words = words, height = lh }
    end
    return out
end

-- Small letters whose own class says they are small and that have no ascender
-- or descender: their height is the line's x-height.
local XHEIGHT_CLASSES = { a = true, e = true, n = true, r = true }

-- A line's x-height, the median height of its characters read as a, e, n or r
-- (nil when there are none), and its baseline, the median bottom of all its
-- characters (most sit on it). `best[i]` is character i's best class index into
-- `classes`.
function Hwr.lineMetrics(chars, classes, best)
    local hs, bottoms = {}, {}
    for i, c in ipairs(chars) do
        if XHEIGHT_CLASSES[classes[best[i]]] then hs[#hs + 1] = c.y1 - c.y0 end
        bottoms[#bottoms + 1] = c.y1
    end
    return median(hs), median(bottoms)
end

-- Capitals for a word. `text` is the decoded word (lower case from the word
-- list, or the classes as read), `chars` its characters, `lps` their class log
-- probabilities, `classes` the class names, `xh` and `base` the line's x-height
-- and baseline (see lineMetrics; xh may be nil). A letter whose small and
-- capital forms differ (a/A, b/B ...) is a capital when the model says so; one
-- whose forms look alike (c/C, o/O ...) when it reaches at least 1.35 x-heights
-- above the baseline, unless it hangs below it (p, y) or carries a dot (i, j).
-- Most letters capital: the word in capitals; a capital first letter: just
-- that one.
function Hwr.cased(text, chars, lps, classes, xh, base)
    local index = {}
    for i, ch in ipairs(classes) do index[ch] = i end
    local verdict, n_letters = {}, 0
    local model_caps, model_known, height_caps, height_known = 0, 0, 0, 0
    for p = 1, #text do
        local ch = text:sub(p, p)
        if ch:match("%a") then
            n_letters = n_letters + 1
            local up, lo = index[ch:upper()], index[ch:lower()]
            local lp = lps[p]
            local c = chars[p]
            local lc = ch:lower()
            if up and lo and up ~= lo and lp then
                verdict[p] = lp[up] > lp[lo]
                model_known = model_known + 1
                if verdict[p] then model_caps = model_caps + 1 end
            elseif c and (lc == "i" or lc == "j") and (c.specks or 0) > 0 then
                verdict[p] = false                                 -- dotted: small
            elseif c and lc == "l" then
                -- l and L are one class and both tall: only a foot makes it L
                verdict[p] = (c.x1 - c.x0) >= 0.55 * (c.y1 - c.y0)
            elseif c and lc == "k" then
                verdict[p] = nil                                   -- k and K are both tall
            elseif xh and c and base and c.y1 > base + 0.3 * xh then
                verdict[p] = false                                 -- hangs below the line: p, y
            elseif xh and c then
                verdict[p] = ((base or c.y1) - c.y0) >= 1.35 * xh
                height_known = height_known + 1
                if verdict[p] then height_caps = height_caps + 1 end
            end
        end
    end
    local lower = text:lower()
    if n_letters == 0 then return text end
    local all_caps
    if model_known > 0 then
        all_caps = n_letters >= 2 and model_caps >= 0.75 * model_known
            and (height_known == 0 or height_caps >= 0.5 * height_known)
    else
        all_caps = n_letters >= 2 and height_known == n_letters and height_caps == height_known
    end
    if all_caps then return text:upper() end
    -- the first letter decides a leading capital
    for p = 1, #text do
        if text:sub(p, p):match("%a") then
            if verdict[p] then return lower:sub(1, p - 1) .. lower:sub(p, p):upper() .. lower:sub(p + 1) end
            break
        end
    end
    return lower
end

return Hwr
