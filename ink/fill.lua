--[[
Flood fill (the paint-bucket). Given a tightly packed 8-bit grey buffer of the
current drawing (transparent areas are white, ink is dark), it finds the region
of connected pixels whose grey is close to the tapped pixel's and stops at the
darker ink around it -- exactly like a paint program filling an enclosed area.

The result is returned as run-length data: a flat list { x, y, len, x, y, len, ... }
of horizontal runs. That is stored on a "fill" op, so a fill undoes and exports
like any other op, and it is compact even for a large area (about one run per row).

The scan-line flood fill visits each pixel of the region once, over a raw FFI
byte buffer, so LuaJIT keeps it fast even for a full screen.
]]

local ffi = require("ffi")

local Fill = {}

-- Scan-line flood fill over a w x h grid, from the seed points left on `stack`
-- (a flat x, y list that is consumed). A pixel joins when free(x, y) is true;
-- take(xl, xr, y) receives each filled run and must make free() false for it.
-- Shared with the background remover (ink/imageproc.lua).
local function scan(w, h, stack, free, take)
    local sn = #stack
    -- seed one point per connected stretch of free pixels on row y, xl..xr
    local function seedRow(xl, xr, y)
        local xx = xl
        while xx <= xr do
            if free(xx, y) then
                stack[sn + 1], stack[sn + 2] = xx, y
                sn = sn + 2
                while xx <= xr and free(xx, y) do xx = xx + 1 end
            else
                xx = xx + 1
            end
        end
    end
    while sn > 0 do
        local y = stack[sn]
        local x = stack[sn - 1]
        stack[sn], stack[sn - 1] = nil, nil
        sn = sn - 2
        if free(x, y) then
            local xl = x
            while xl > 0 and free(xl - 1, y) do xl = xl - 1 end
            local xr = x
            while xr < w - 1 and free(xr + 1, y) do xr = xr + 1 end
            take(xl, xr, y)
            -- seed the rows above and below, once per connected segment
            if y > 0 then seedRow(xl, xr, y - 1) end
            if y < h - 1 then seedRow(xl, xr, y + 1) end
        end
    end
end

Fill.scan = scan

-- buf: uint8_t[w*h] grey. Returns the flat run list, or nil if the seed is out
-- of bounds. `tol` is how far a pixel's grey may differ from the seed's.
function Fill.compute(buf, w, h, sx, sy, tol)
    sx, sy = math.floor(sx), math.floor(sy)
    if sx < 0 or sy < 0 or sx >= w or sy >= h then return nil end
    local seed = buf[sy * w + sx]
    local lo = seed - tol
    local hi = seed + tol
    local seen = ffi.new("uint8_t[?]", w * h)   -- zeroed
    local runs = {}
    scan(w, h, { sx, sy },
        function(x, y)
            local i = y * w + x
            return seen[i] == 0 and buf[i] >= lo and buf[i] <= hi
        end,
        function(xl, xr, y)
            local base = y * w
            for xx = xl, xr do seen[base + xx] = 1 end
            runs[#runs + 1] = xl
            runs[#runs + 1] = y
            runs[#runs + 1] = xr - xl + 1
        end)
    return runs
end

-- Paint a fill op's runs through the span writer `put`.
function Fill.render(op, put)
    local r = op.runs
    for i = 1, #r, 3 do
        put(r[i], r[i + 1], r[i + 2])
    end
end

return Fill
