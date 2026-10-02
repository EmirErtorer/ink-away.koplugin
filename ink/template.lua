--[[
Notebook rulings (lined, grid, dots, margin, Cornell, blank). Like the
rasterizer it emits horizontal spans through a `put(x, y, len)` callback, so the
page on screen and the export share the geometry; the caller's `put` picks the
colour.
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

-- Draw `style` ruling over a w x h page with spacing `size` (px) via `put`.
function Template.render(style, w, h, size, put)
    if not style or style == "blank" then return end
    if not size or size <= 0 then return end
    if style == "lines" then
        rules(put, 0, w, size, h)
    elseif style == "grid" then
        rules(put, 0, w, size, h)
        local cx = size
        while cx < w do
            for y = 0, h - 1 do put(cx, y, 1) end   -- 1px vertical rule
            cx = cx + size
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
