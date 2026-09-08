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
    local stack = { sx, sy }

    local function match(i)
        return seen[i] == 0 and buf[i] >= lo and buf[i] <= hi
    end

    while #stack > 0 do
        local y = stack[#stack]; stack[#stack] = nil
        local x = stack[#stack]; stack[#stack] = nil
        local base = y * w
        if match(base + x) then
            local xl = x
            while xl > 0 and match(base + xl - 1) do xl = xl - 1 end
            local xr = x
            while xr < w - 1 and match(base + xr + 1) do xr = xr + 1 end
            for xx = xl, xr do seen[base + xx] = 1 end
            runs[#runs + 1] = xl
            runs[#runs + 1] = y
            runs[#runs + 1] = xr - xl + 1
            -- seed the rows above and below, once per connected segment
            if y > 0 then
                local nb = (y - 1) * w
                local xx = xl
                while xx <= xr do
                    if match(nb + xx) then
                        stack[#stack + 1] = xx
                        stack[#stack + 1] = y - 1
                        while xx <= xr and match(nb + xx) do xx = xx + 1 end
                    else
                        xx = xx + 1
                    end
                end
            end
            if y < h - 1 then
                local nb = (y + 1) * w
                local xx = xl
                while xx <= xr do
                    if match(nb + xx) then
                        stack[#stack + 1] = xx
                        stack[#stack + 1] = y + 1
                        while xx <= xr and match(nb + xx) do xx = xx + 1 end
                    else
                        xx = xx + 1
                    end
                end
            end
        end
    end
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
