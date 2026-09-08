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
local Shapes = require("ink/shapes")
local Fill = require("ink/fill")

local Export = {}

-- Draw an op's geometry through `put` (shapes, fills and strokes all share this).
local function paintGeom(op, put)
    if op.kind == "shape" then
        Shapes.render(op, put)
    elseif op.kind == "fill" then
        Fill.render(op, put)
    else
        Raster.path(op.pts, op.width / 2, put)
    end
end
Export.paintGeom = paintGeom

-- An op's ink colour as r,g,b (0-255). Missing colour means black.
local function opRGB(op)
    local c = op.color
    if not c then return 0, 0, 0 end
    return c[1] or 0, c[2] or 0, c[3] or 0
end

-- Replay every committed op into `buf`. `ink_put(r,g,b,alpha)` gives back the
-- span writer for an ink stroke of that colour and opacity; `erase_put` clears.
-- The RGBA and RGB builders share this so both match the rasterizer pixel for
-- pixel.
local function replay(canvas, ink_put, erase_put)
    for _, op in ipairs(canvas.ops) do
        local put
        if op.kind == "erase" then
            put = erase_put
        else
            local r, g, b = opRGB(op)
            put = ink_put(r, g, b, op.alpha or 255)
        end
        paintGeom(op, put)
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
    local function ink_put(r, g, b, alpha)
        return function(x, y, len)
            local cx, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (y * w + cx) * 4
            for i = 0, clen - 1 do
                local o = base + i * 4
                buf[o] = r; buf[o + 1] = g; buf[o + 2] = b; buf[o + 3] = alpha
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
    -- JPEG has no alpha, so lay the ink over white. Each channel becomes
    -- 255 - alpha*(255-c)/255, which is exactly how the ink looks on the white
    -- canvas (a partly transparent black pen turns into the matching grey).
    local function ink_put(r, g, b, alpha)
        local function over(c) return math.floor(255 - alpha * (255 - c) / 255 + 0.5) end
        local orr, og, ob = over(r), over(g), over(b)
        return function(x, y, len)
            local cx, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (y * w + cx) * 3
            for i = 0, clen - 1 do
                local o = base + i * 3
                buf[o] = orr; buf[o + 1] = og; buf[o + 2] = ob
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

-- Build a tightly packed 8-bit grey buffer of the drawing over white (ink dark,
-- untouched areas white). Used by the flood fill to find an enclosed area.
function Export.buildGray(canvas)
    local w, h = canvas.w, canvas.h
    local n = w * h
    local buf = ffi.new("uint8_t[?]", n)
    ffi.fill(buf, n, 0xFF)
    local function clamp_run(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        return x, len
    end
    local function ink_put(r, g, b, alpha)
        local lum = 0.299 * r + 0.587 * g + 0.114 * b
        local g8 = math.floor(255 - alpha * (255 - lum) / 255 + 0.5)
        return function(x, y, len)
            local cx, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = y * w + cx
            for i = 0, clen - 1 do buf[base + i] = g8 end
        end
    end
    local function erase_put(x, y, len)
        local cx, clen = clamp_run(x, y, len)
        if not cx then return end
        local base = y * w + cx
        for i = 0, clen - 1 do buf[base + i] = 0xFF end
    end
    replay(canvas, ink_put, erase_put)
    return buf
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
