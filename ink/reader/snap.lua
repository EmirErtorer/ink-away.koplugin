--[[
The smart highlighter: is a highlighter stroke drawn along a line of text, so
that it can become the reader's own highlight of that text? Plain Lua (the
book is asked by ink/reader/book.lua), so the headless tests drive it.

A stroke is taken for a line when its centre line runs across rather than up
and down, the text the reader finds between its two ends lies on one line
through the stroke's middle, the stroke stays within that line's height, and
the words cover at least half of its length. Anything else stays ink.
]]

local Snap = {}

local MIN_LEN = 12       -- px: shorter is a dab, not a line

-- The centre line of a stroke: { x0, x1, y, h } (its ends, its middle height,
-- how far it wanders up and down), or nil for a stroke that is not across.
function Snap.lineOf(op)
    if not (op and op.kind == "ink" and op.pts and #op.pts >= 4) then return nil end
    local pts = op.pts
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #pts - 1, 2 do
        local x, y = pts[i], pts[i + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    local w, h = x1 - x0, y1 - y0
    if w < MIN_LEN or h > w then return nil end
    return { x0 = x0, x1 = x1, y = (y0 + y1) / 2, h = h }
end

-- Do the text's boxes (in the same units as `line`) cover the stroke?
function Snap.covers(boxes, line)
    if not (boxes and #boxes > 0) then return false end
    local bx0, bx1, bh = math.huge, -math.huge, 0
    for _i, b in ipairs(boxes) do
        -- every box on the one line through the stroke's middle
        if line.y < b.y - 2 or line.y > b.y + b.h + 2 then return false end
        if b.x < bx0 then bx0 = b.x end
        if b.x + b.w > bx1 then bx1 = b.x + b.w end
        if b.h > bh then bh = b.h end
    end
    if line.h > bh * 1.25 then return false end
    local over = math.min(bx1, line.x1) - math.max(bx0, line.x0)
    return over >= 0.5 * (line.x1 - line.x0)
end

-- KOReader's highlight colours (Blitbuffer.HIGHLIGHT_COLORS), for a reader
-- that does not have them.
local NAMED = {
    red = "#FF3300", orange = "#FF8800", yellow = "#FFFF33", green = "#00AA66",
    olive = "#88FF77", cyan = "#00FFEE", blue = "#0066FF", purple = "#EE00FF",
}

local function rgbOf(hex)
    local r, g, b = hex:match("#(%x%x)(%x%x)(%x%x)")
    if r then return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) end
end

-- The reader's highlight colour nearest the pen's: a grey pen (as on a grey
-- screen) gives `fallback`, the colour the reader highlights in by default.
function Snap.colourName(color, fallback, named)
    if type(color) ~= "table" then return fallback end
    local r, g, b = color[1] or 0, color[2] or 0, color[3] or 0
    local hi, lo = math.max(r, g, b), math.min(r, g, b)
    if hi == 0 or (hi - lo) / hi < 0.2 then return fallback end
    local best, bd
    for name, hex in pairs(named or NAMED) do
        local nr, ng, nb = rgbOf(hex)
        if nr then
            local d = (r - nr) ^ 2 + (g - ng) ^ 2 + (b - nb) ^ 2
            if not bd or d < bd or (d == bd and name < best) then best, bd = name, d end
        end
    end
    return best or fallback
end

return Snap
