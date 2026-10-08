--[[
The smudge: drag ink as a finger drags wet paint or graphite. Only ink moves.
The paper, its ruling or grid, a background picture, placed pictures and text
are never picked up, though smudged ink can be laid over them.

The brush carries a small patch of colour, the size of the brush. At each step
along the path it first picks up some of what lies under it (only ink: a pixel
that differs from the page without ink), then lays the patch back down, so what
it picked up a step earlier lands a little further on. Colours mix as they
meet; red pushed into blue turns purple.

A smudge is an op ({ kind = "smudge", pts, width, alpha = strength }) replayed in
order like every other, by this one function on every surface: the screen's
master and the export buffers, so files match the screen. Its points are kept
as drawn (not simplified), so the replay retraces the live stroke exactly.

A surface is { ptr = uint8_t*, stride = bytes per row, bpp = 1 (grey), 3 (RGB)
or 4 (RGB32, or RGBA with `alpha`), w, h }.
]]

local ffi = require("ffi")
local Symmetry = require("ink/symmetry")

local Smudge = {}

local floor, ceil, sqrt, max, min = math.floor, math.ceil, math.sqrt, math.max, math.min

local PICKUP = 0.45      -- how much of what lies under the brush it takes each step

-- A surface over a KOReader Blitbuffer: 8-bit grey or RGB32 (as the canvas
-- always is), not rotated. nil for anything else.
function Smudge.surfaceOf(bb)
    if not bb then return nil end
    local ok, t = pcall(function() return bb:getType() end)
    if not ok then return nil end
    if (bb.getRotation and bb:getRotation() ~= 0) or (bb.getInverse and bb:getInverse() ~= 0) then return nil end
    local BB = require("ffi/blitbuffer")
    local bpp = (t == BB.TYPE_BB8 and 1) or (t == BB.TYPE_BBRGB32 and 4) or nil
    if not bpp then return nil end
    return { ptr = ffi.cast("uint8_t*", bb.data), stride = tonumber(bb.stride), bpp = bpp,
             w = bb:getWidth(), h = bb:getHeight() }
end

-- A surface over a packed export buffer (RGB or RGBA).
function Smudge.surfaceOfBuffer(buf, w, h, bpp, alpha)
    return { ptr = ffi.cast("uint8_t*", buf), stride = w * bpp, bpp = bpp, w = w, h = h, alpha = alpha }
end

-- A fresh brush for a stroke of radius r: its patch and how far it has come.
function Smudge.newState(r)
    local R = max(1, ceil(r))
    local side = 2 * R + 1
    return { r = r, R = R, side = side, acc = ffi.new("double[?]", side * side * 4),
             started = false, left = 0 }
end

-- One step of the brush at (cx, cy) on surface s, with base b (the page without
-- ink, the same layout). k is the strength, 0-255.
local function step(st, s, b, cx, cy, k)
    local R, side, acc, r = st.R, st.side, st.acc, st.r
    local ptr, stride, bpp, w, h = s.ptr, s.stride, s.bpp, s.w, s.h
    local bptr = b.ptr
    local alpha_ch = s.alpha
    local icx, icy = floor(cx + 0.5), floor(cy + 0.5)
    local first = not st.started
    st.started = true
    local inv_r2 = 1 / (r * r)
    local strength = k / 255
    for dy = -R, R do
        local y = icy + dy
        if y >= 0 and y < h then
            local row = y * stride
            for dx = -R, R do
                local d2 = (dx * dx + dy * dy) * inv_r2
                local x = icx + dx
                if d2 <= 1 and x >= 0 and x < w then
                    local o = row + x * bpp
                    local ai = ((dy + R) * side + (dx + R)) * 4
                    -- is this pixel ink? (it differs from the page without ink)
                    local ink
                    if bpp == 1 then
                        ink = ptr[o] ~= bptr[o]
                    elseif alpha_ch then
                        ink = ptr[o + 3] > 0 and (ptr[o] ~= bptr[o] or ptr[o + 1] ~= bptr[o + 1]
                            or ptr[o + 2] ~= bptr[o + 2] or ptr[o + 3] ~= bptr[o + 3])
                    else
                        ink = ptr[o] ~= bptr[o] or ptr[o + 1] ~= bptr[o + 1] or ptr[o + 2] ~= bptr[o + 2]
                    end
                    local c1 = ptr[o]
                    local c2 = bpp > 1 and ptr[o + 1] or c1
                    local c3 = bpp > 1 and ptr[o + 2] or c1
                    -- how much ink the pixel holds: all of it on an opaque page, its
                    -- alpha in a transparent PNG
                    local load = ink and (alpha_ch and ptr[o + 3] or 255) or 0
                    if first then
                        acc[ai], acc[ai + 1], acc[ai + 2] = c1, c2, c3
                        acc[ai + 3] = load
                    else
                        -- pick up: ink brings its colour; paper only thins the load
                        if ink then
                            acc[ai] = acc[ai] + (c1 - acc[ai]) * PICKUP
                            acc[ai + 1] = acc[ai + 1] + (c2 - acc[ai + 1]) * PICKUP
                            acc[ai + 2] = acc[ai + 2] + (c3 - acc[ai + 2]) * PICKUP
                            acc[ai + 3] = acc[ai + 3] + (load - acc[ai + 3]) * PICKUP
                        else
                            acc[ai + 3] = acc[ai + 3] * (1 - PICKUP)
                        end
                        -- lay down, strongest at the centre
                        local t = acc[ai + 3] / 255 * strength * (1 - d2)
                        if t > 0.002 then
                            if alpha_ch and ptr[o + 3] == 0 then
                                ptr[o], ptr[o + 1], ptr[o + 2] = floor(acc[ai] + 0.5),
                                    floor(acc[ai + 1] + 0.5), floor(acc[ai + 2] + 0.5)
                                ptr[o + 3] = floor(255 * t + 0.5)
                            else
                                ptr[o] = floor(c1 + (acc[ai] - c1) * t + 0.5)
                                if bpp > 1 then
                                    ptr[o + 1] = floor(c2 + (acc[ai + 1] - c2) * t + 0.5)
                                    ptr[o + 2] = floor(c3 + (acc[ai + 2] - c3) * t + 0.5)
                                    if alpha_ch then
                                        ptr[o + 3] = floor(ptr[o + 3] + (255 - ptr[o + 3]) * t + 0.5)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Move the brush from (x0, y0) to (x1, y1), stepping every quarter radius;
-- leftover distance carries over to the next segment. A nil x0 places it.
function Smudge.segment(st, s, b, x0, y0, x1, y1, k)
    if not x0 then return step(st, s, b, x1, y1, k) end
    local spacing = max(1, st.r * 0.25)
    local dx, dy = x1 - x0, y1 - y0
    local dist = sqrt(dx * dx + dy * dy)
    if dist <= 0 then return end
    local d = spacing - st.left
    while d <= dist do
        local f = d / dist
        step(st, s, b, x0 + dx * f, y0 + dy * f, k)
        d = d + spacing
    end
    st.left = dist - (d - spacing)
end

-- Replay a whole smudge op on surface s with base b, with its symmetry copies
-- (each its own brush) on a W x H page. A cropped export's surface starts at
-- canvas (offx, offy).
function Smudge.apply(s, b, op, W, H, offx, offy)
    local pts = op.pts
    local n = floor(#pts / 2)
    if n == 0 or not (s and b) then return end
    local r = max(1, (op.width or 1) / 2)
    local k = op.alpha or 255
    offx, offy = offx or 0, offy or 0
    for _i, f in ipairs(Symmetry.flips(op.sym)) do
        local p = Symmetry.flipPoints(pts, f, W or s.w, H or s.h)
        if offx ~= 0 or offy ~= 0 then
            local q = {}
            for i = 1, #p - 1, 2 do q[i], q[i + 1] = p[i] - offx, p[i + 1] - offy end
            p = q
        end
        local st = Smudge.newState(r)
        Smudge.segment(st, s, b, nil, nil, p[1], p[2], k)
        for i = 2, n do
            Smudge.segment(st, s, b, p[2 * i - 3], p[2 * i - 2], p[2 * i - 1], p[2 * i], k)
        end
    end
end

-- The canvas rect a segment from (x0, y0) to (x1, y1) of radius r touches.
function Smudge.rect(x0, y0, x1, y1, r)
    local R = ceil(r) + 1
    return { x0 = floor(min(x0 or x1, x1)) - R, y0 = floor(min(y0 or y1, y1)) - R,
             x1 = ceil(max(x0 or x1, x1)) + R + 1, y1 = ceil(max(y0 or y1, y1)) + R + 1 }
end

return Smudge
