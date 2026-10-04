--[[
Notebook rulings (lined, grid, dots, margin, Cornell, blank) and planner pages
(checklist, two columns, weekly, monthly, storyboard, music). Like the
rasterizer it emits horizontal spans through a `put(x, y, len)` callback, so the
page on screen and the export share the geometry; the caller's `put` picks the
colour. Every page follows the spacing `size` (the reader's line spacing), so
the planners grow and shrink with it like the plain rulings.
]]

local Template = {}

-- Horizontal rules at y = size, 2 * size, ... up to `y_end`, each `len` long from `x`.
local function rules(put, x, len, size, y_end)
    local cy = size
    while cy < y_end do
        put(x, cy, len)
        cy = cy + size
    end
end

-- A vertical rule at x from y0 to y1 (exclusive), `t` pixels thick.
local function vrule(put, x, y0, y1, t)
    for y = math.max(0, math.floor(y0)), math.floor(y1) - 1 do put(x, y, t or 1) end
end

-- A rectangle's outline, `t` pixels thick.
local function box(put, x, y, w, h, t)
    t = t or 1
    for k = 0, t - 1 do
        put(x, y + k, w)
        put(x, y + h - 1 - k, w)
    end
    vrule(put, x, y, y + h, t)
    vrule(put, x + w - t, y, y + h, t)
end

-- Rules every `size` from y0 + size up to y1, between x0 and x1.
local function rulesIn(put, x0, x1, y0, y1, size)
    local cy = y0 + size
    while cy < y1 do
        put(x0, math.floor(cy), x1 - x0)
        cy = cy + size
    end
end

-- The planner pages, keyed by style.
local PAGES = {}

-- A checkbox at the start of every line.
function PAGES.checklist(w, h, size, put)
    local m = math.floor(size * 0.6)
    local b = math.max(6, math.floor(size * 0.55))
    local cy = size
    while cy < h do
        local by = math.floor(cy - size * 0.2) - b
        if by > 0 then box(put, m, by, b, b, 1) end
        local lx = m + b + math.floor(size * 0.35)
        put(lx, cy, w - lx - m)
        cy = cy + size
    end
end

-- Two columns of lines with a gutter between them.
function PAGES.twocol(w, h, size, put)
    local m = math.floor(size * 0.5)
    local half = math.floor(w / 2)
    local g = math.floor(size * 0.5)
    local cy = size
    while cy < h do
        put(m, cy, half - g - m)
        put(half + g, cy, w - half - g - m)
        cy = cy + size
    end
end

-- A week: two columns of four boxes (seven days and notes), lined inside, under
-- a band for the dates.
function PAGES.weekly(w, h, size, put)
    local m = math.floor(size * 0.5)
    local top = m + math.floor(size * 1.5)
    local cw = math.floor((w - 2 * m) / 2)
    local ch = math.floor((h - top - m) / 4)
    for r = 0, 3 do
        for c = 0, 1 do
            local x, y = m + c * cw, top + r * ch
            box(put, x, y, cw, ch, 2)
            rulesIn(put, x + 2, x + cw - 2, y, y + ch - 2, size)
        end
    end
end

-- A month: a band for its name, seven columns by six weeks of boxes, and lines
-- for notes under it.
function PAGES.monthly(w, h, size, put)
    local m = math.floor(size * 0.5)
    local top = m + math.floor(size * 1.5)
    local gw = w - 2 * m
    local cw = math.floor(gw / 7)
    gw = cw * 7
    local gh = math.floor((h - top) * 0.62)
    local rh = math.floor(gh / 6)
    gh = rh * 6
    box(put, m, top, gw, gh, 2)
    for r = 1, 5 do put(m, top + r * rh, gw) end
    for c = 1, 6 do vrule(put, m + c * cw, top, top + gh, 1) end
    rulesIn(put, m, m + gw, top + gh, h - m, size)
end

-- Frames down the left, each with lines beside it for notes.
function PAGES.storyboard(w, h, size, put)
    local m = math.floor(size * 0.5)
    local row = size * 5
    local fh = size * 4
    local fw = math.floor((w - 2 * m) * 0.45)
    local lx = m + fw + math.floor(size * 0.5)
    local y = m
    while y + fh <= h - m do
        box(put, m, math.floor(y), fw, math.floor(fh), 2)
        rulesIn(put, lx, w - m, y - size * 0.5, y + fh, size)
        y = y + row
    end
end

-- Music staves: five lines a quarter of the spacing apart, a staff every two
-- and a half spacings.
function PAGES.music(w, h, size, put)
    local m = math.floor(w * 0.05)
    local gap = math.max(3, size / 4)
    local pitch = size * 2.5
    local y = size
    while y + 4 * gap < h - m do
        for k = 0, 4 do put(m, math.floor(y + k * gap), w - 2 * m) end
        vrule(put, m, y, y + 4 * gap + 1, 1)
        vrule(put, w - m - 1, y, y + 4 * gap + 1, 1)
        y = y + pitch
    end
end

-- Is `style` one of the planner pages (rather than a plain ruling)?
function Template.isPlanner(style)
    return PAGES[style] ~= nil
end

-- Draw `style` ruling over a w x h page with spacing `size` (px) via `put`.
function Template.render(style, w, h, size, put)
    if not style or style == "blank" then return end
    if not size or size <= 0 then return end
    if PAGES[style] then
        PAGES[style](w, h, size, put)
    elseif style == "lines" then
        rules(put, 0, w, size, h)
    elseif style == "grid" then
        rules(put, 0, w, size, h)
        local cx = size
        while cx < w do
            for y = 0, h - 1 do put(cx, y, 1) end   -- 1px vertical rule
            cx = cx + size
        end
    elseif style == "iso" then
        -- isometric: vertical rules and two families of 30-degree diagonals, so
        -- the lines meet in equilateral triangles
        local cx = size
        while cx < w do
            vrule(put, cx, 0, h, 1)
            cx = cx + size
        end
        local slope = math.tan(math.rad(30))
        local step = size / math.cos(math.rad(30))
        local reach = h * slope
        local b = -math.ceil(reach / step) * step
        while b < w + reach do
            for y = 0, h - 1 do
                local x1 = math.floor(b + y * slope)
                if x1 >= 0 and x1 < w then put(x1, y, 1) end
                local x2 = math.floor(b + reach - y * slope)
                if x2 >= 0 and x2 < w then put(x2, y, 1) end
            end
            b = b + step
        end
    elseif style == "dots" then
        -- a small filled square at each intersection, scaled with the spacing so
        -- the dots stay visible
        local r = math.max(3, math.floor(size / 12))
        local cy = size
        while cy < h do
            local cx = size
            while cx < w do
                for yy = 0, r - 1 do
                    if cy + yy < h then put(cx, cy + yy, r) end
                end
                cx = cx + size
            end
            cy = cy + size
        end
    elseif style == "margin" then
        -- ruled lines with one vertical margin rule down the left, like a legal
        -- pad
        local mx = math.floor(w * 0.12)
        rules(put, 0, w, size, h)
        for y = 0, h - 1 do put(mx, y, 1) end
    elseif style == "cornell" then
        -- Cornell notes: a left cue column, a bottom summary band and ruled lines
        -- only in the notes area
        local cue = math.floor(w * 0.28)
        local summary_y = math.floor(h * 0.80)
        rules(put, cue, w - cue, size, summary_y)
        for y = 0, summary_y - 1 do put(cue, y, 1) end      -- cue divider
        put(0, summary_y, w)                                -- summary divider
    end
end

return Template
