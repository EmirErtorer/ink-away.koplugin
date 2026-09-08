--[[
Saves the canvas to a real image file at the fixed W x H canvas size.

PNG is written as true RGBA: pixels you never touched have alpha 0, so they are
genuinely transparent and good for sleep screen overlays, while ink pixels are
opaque. JPEG has no alpha, so there the ink is laid over a solid white
background instead.

The pixel buffers are plain FFI byte arrays (uint8_t[w*h*n]), packed tightly in
exactly the layout the encoders want. They are built when you save and thrown
away afterwards, so the big image buffer is never sitting in memory while you
draw. FFI cdata is also invisible to the Lua garbage collector.

Encoding goes through KOReader's own FFI wrappers:
    ffi/png.encodeToFile(path, mem, w, h, 4)              -> LCT_RGBA
    ffi/jpeg.encodeToFile(path, mem, w, h, 3, q, stride)  -> TJPF_RGB
They are required lazily so the buffer building logic can be tested on a
computer, where the native libraries are not present.
]]

local ffi = require("ffi")
local Raster = require("ink/raster")

local Export = {}

-- Ink is plain black. There is no colour picker, on purpose (see README).
local INK_R, INK_G, INK_B = 0, 0, 0

-- Replay every committed op into `buf`. `ink_put(alpha)` gives back the span
-- writer for an ink stroke at that opacity; `erase_put` clears. The RGBA and RGB
-- builders share this so both match the rasterizer pixel for pixel.
local function replay(canvas, ink_put, erase_put)
    for _, op in ipairs(canvas.ops) do
        local put = (op.kind == "erase") and erase_put or ink_put(op.alpha or 255)
        Raster.path(op.pts, op.width / 2, put)
    end
end

-- Build a tightly packed RGBA buffer (w*h*4 bytes), transparent where no ink.
-- Returns buf, byte_count.
function Export.buildRGBA(canvas)
    local w, h = canvas.w, canvas.h
    local n = w * h * 4
    local buf = ffi.new("uint8_t[?]", n)  -- starts all zero, so fully transparent
    local function clamp_run(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        return x, len
    end
    local function ink_put(alpha)
        return function(x, y, len)
            local cx, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (y * w + cx) * 4
            for i = 0, clen - 1 do
                local o = base + i * 4
                buf[o] = INK_R; buf[o + 1] = INK_G; buf[o + 2] = INK_B; buf[o + 3] = alpha
            end
        end
    end
    local function erase_put(x, y, len)
        local cx, clen = clamp_run(x, y, len)
        if not cx then return end
        local base = (y * w + cx) * 4
        for i = 0, clen - 1 do
            local o = base + i * 4
            buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
        end
    end
    replay(canvas, ink_put, erase_put)
    return buf, n
end

-- Build a tightly packed RGB buffer (w*h*3 bytes) with ink composited over a
-- solid white background (for JPEG, which has no transparency).
function Export.buildRGB(canvas)
    local w, h = canvas.w, canvas.h
    local n = w * h * 3
    local buf = ffi.new("uint8_t[?]", n)
    ffi.fill(buf, n, 0xFF)  -- white background
    local function clamp_run(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        return x, len
    end
    -- JPEG has no alpha, so lay the ink over white. A partly transparent pen
    -- turns into a matching grey (value 255 - alpha), which is how it looks on
    -- the white canvas anyway.
    local function ink_put(alpha)
        local g = 255 - alpha
        return function(x, y, len)
            local cx, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (y * w + cx) * 3
            for i = 0, clen - 1 do
                local o = base + i * 3
                buf[o] = g; buf[o + 1] = g; buf[o + 2] = g
            end
        end
    end
    local function erase_put(x, y, len)
        local cx, clen = clamp_run(x, y, len)
        if not cx then return end
        local base = (y * w + cx) * 3
        for i = 0, clen - 1 do
            local o = base + i * 3
            buf[o] = 0xFF; buf[o + 1] = 0xFF; buf[o + 2] = 0xFF
        end
    end
    replay(canvas, ink_put, erase_put)
    return buf, n
end

-- Save the canvas as a PNG with a transparent background. Returns ok, err.
function Export.savePNG(canvas, path)
    local Png = require("ffi/png")
    local buf = Export.buildRGBA(canvas)
    local ok, err = Png.encodeToFile(path, buf, canvas.w, canvas.h, 4)
    return ok, err
end

-- Save the canvas as a JPEG on a white background. Returns ok, err.
function Export.saveJPEG(canvas, path, quality)
    local Jpeg = require("ffi/jpeg")
    local buf = Export.buildRGB(canvas)
    local ok, err = Jpeg.encodeToFile(path, buf, canvas.w, canvas.h, 3,
        quality or 90, canvas.w * 3)
    return ok, err
end

return Export
