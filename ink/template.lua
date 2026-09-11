--[[
Notebook page templates: the ruling printed on a page (lined, grid, dots or
blank). Like the rasterizer it emits horizontal spans through a `put(x, y, len)`
callback, so the same ruling is drawn into the on-screen page and into the
exported image with identical geometry. The caller's `put` decides the colour
(a light grey, so ink sits clearly on top).
]]

local Template = {}

-- Draw `style` ruling over a w x h page with spacing `size` (px) via `put`.
function Template.render(style, w, h, size, put)
    if not style or style == "blank" then return end
    if not size or size <= 0 then return end
    if style == "lines" then
        local cy = size
        while cy < h do
            put(0, cy, w)
            cy = cy + size
        end
    elseif style == "grid" then
        local cy = size
        while cy < h do
            put(0, cy, w)
            cy = cy + size
        end
        local cx = size
        while cx < w do
            for y = 0, h - 1 do put(cx, y, 1) end   -- 1px vertical rule
            cx = cx + size
        end
    elseif style == "dots" then
        -- a small filled square at each intersection; scale it with the spacing
        -- (and the screen) so the dots are actually visible, not a faint speck
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
        -- ruled lines with a single vertical margin rule down the left, like a
        -- legal pad: write in the wide area, keep notes/dates in the margin
        local mx = math.floor(w * 0.12)
        local cy = size
        while cy < h do put(0, cy, w); cy = cy + size end
        for y = 0, h - 1 do put(mx, y, 1) end
    elseif style == "cornell" then
        -- Cornell notes: a left cue column, a bottom summary band, and ruled
        -- lines only in the notes area between them
        local cue = math.floor(w * 0.28)
        local summary_y = math.floor(h * 0.80)
        local cy = size
        while cy < summary_y do
            if cy > 0 then put(cue, cy, w - cue) end
            cy = cy + size
        end
        for y = 0, summary_y - 1 do put(cue, y, 1) end      -- cue divider
        put(0, summary_y, w)                                -- summary divider
    end
end

return Template
