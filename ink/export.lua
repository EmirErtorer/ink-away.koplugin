--[[
Saves the canvas to a real image file. Normally that is the whole W x H canvas,
but an optional crop rectangle lets you export just a part (say a signature in
the middle of the page) at its own size.

PNG is written as true RGBA: pixels you never touched have alpha 0, so they are
genuinely transparent and good for sleep screen overlays, while ink pixels are
opaque. JPEG has no alpha, so there the ink is laid over a solid white
background instead.

If a background image is loaded, the save can either include it (your ink
composited on top of the picture) or leave it out (just the ink). A grid is
never part of the export; it is only ever a guide on screen.

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
local Symmetry = require("ink/symmetry")

local Export = {}

-- Draw an op's geometry through `put` (shapes, fills and strokes all share this).
local function paintGeom(op, put)
    if op.kind == "shape" then
        Shapes.render(op, put)
    elseif op.kind == "fill" then
        Fill.render(op, put)
    else
        local st = op.kind == "ink" and op.style and Raster.STYLES[op.style]
        if st and not st.solid then
            Raster.pathTex(op.pts, op.width / 2, put, st, op.seed or 0)
        else
            Raster.path(op.pts, op.width / 2, put)
        end
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
-- Each op's put is wrapped for its own symmetry mode, so mirrored copies come
-- out of the same replay with no extra bookkeeping. Everything (the RGBA and RGB
-- builders, and the fill's grey buffer) shares this, so all stay pixel for pixel
-- identical to the rasterizer.
local function replay(canvas, ink_put, erase_put)
    local W, H = canvas.w, canvas.h
    local refx, refy = Symmetry.canvasRefs(W, H)
    for _, op in ipairs(canvas.ops) do
        local put
        if op.kind == "erase" then
            put = erase_put
        else
            local r, g, b = opRGB(op)
            put = ink_put(r, g, b, op.alpha or 255)
        end
        paintGeom(op, Symmetry.wrap(put, op.sym, refx, refy))
    end
end

-- The output size and coordinate offset for an optional crop rect. With no rect
-- the whole canvas is used.
local function dims(canvas, rect)
    if rect then return rect.w, rect.h, rect.x, rect.y end
    return canvas.w, canvas.h, 0, 0
end

-- Build a tightly packed RGBA buffer (ow*oh*4 bytes), transparent where no ink.
-- `rect` optionally crops to {x,y,w,h}. Returns buf, byte_count, ow, oh.
function Export.buildRGBA(canvas, rect)
    local ow, oh, offx, offy = dims(canvas, rect)
    local n = ow * oh * 4
    local buf = ffi.new("uint8_t[?]", n)  -- starts all zero, so fully transparent
    -- returns the crop-local x, y and clipped length, or nil when fully outside
    local function clamp_run(x, y, len)
        x = x - offx; y = y - offy
        if y < 0 or y >= oh then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > ow then len = ow - x end
        if len <= 0 then return end
        return x, y, len
    end
    local function ink_put(r, g, b, alpha)
        return function(x, y, len)
            local cx, cy, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (cy * ow + cx) * 4
            for i = 0, clen - 1 do
                local o = base + i * 4
                buf[o] = r; buf[o + 1] = g; buf[o + 2] = b; buf[o + 3] = alpha
            end
        end
    end
    local function erase_put(x, y, len)
        local cx, cy, clen = clamp_run(x, y, len)
        if not cx then return end
        local base = (cy * ow + cx) * 4
        for i = 0, clen - 1 do
            local o = base + i * 4
            buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
        end
    end
    replay(canvas, ink_put, erase_put)
    return buf, n, ow, oh
end

-- Build a tightly packed RGB buffer (ow*oh*3 bytes) with ink composited over a
-- solid white background (for JPEG, which has no transparency). `rect` optional.
function Export.buildRGB(canvas, rect)
    local ow, oh, offx, offy = dims(canvas, rect)
    local n = ow * oh * 3
    local buf = ffi.new("uint8_t[?]", n)
    ffi.fill(buf, n, 0xFF)  -- white background
    local function clamp_run(x, y, len)
        x = x - offx; y = y - offy
        if y < 0 or y >= oh then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > ow then len = ow - x end
        if len <= 0 then return end
        return x, y, len
    end
    -- JPEG has no alpha, so lay the ink over white. Each channel becomes
    -- 255 - alpha*(255-c)/255, which is exactly how the ink looks on the white
    -- canvas (a partly transparent black pen turns into the matching grey).
    local function ink_put(r, g, b, alpha)
        local function over(c) return math.floor(255 - alpha * (255 - c) / 255 + 0.5) end
        local orr, og, ob = over(r), over(g), over(b)
        return function(x, y, len)
            local cx, cy, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (cy * ow + cx) * 3
            for i = 0, clen - 1 do
                local o = base + i * 3
                buf[o] = orr; buf[o + 1] = og; buf[o + 2] = ob
            end
        end
    end
    local function erase_put(x, y, len)
        local cx, cy, clen = clamp_run(x, y, len)
        if not cx then return end
        local base = (cy * ow + cx) * 3
        for i = 0, clen - 1 do
            local o = base + i * 3
            buf[o] = 0xFF; buf[o + 1] = 0xFF; buf[o + 2] = 0xFF
        end
    end
    replay(canvas, ink_put, erase_put)
    return buf, n, ow, oh
end

-- Build a tightly packed 8-bit grey buffer of the drawing over white (ink dark,
-- untouched areas white). Used by the flood fill to find an enclosed area, so it
-- sees the mirrored ink too when symmetry is on.
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

-- Composite the ink RGBA layer `ink` over the background RGBA `bg` (both packed
-- ow*oh*4). `bg` is canvas sized; `offx,offy` place the crop within it. Writes
-- the result back into `ink`. Standard "source over" alpha compositing.
local function compositeOverBg(ink, ow, oh, bg, bgw, offx, offy)
    for y = 0, oh - 1 do
        local by = (y + offy)
        for x = 0, ow - 1 do
            local io = (y * ow + x) * 4
            local ai = ink[io + 3]
            if ai < 255 then
                local bo = (by * bgw + (x + offx)) * 4
                local ab = bg[bo + 3]
                if ab > 0 then
                    local fa = ai / 255
                    local fb = (ab / 255) * (1 - fa)
                    local ao = fa + fb
                    if ao > 0 then
                        local inv = 1 / ao
                        ink[io]     = math.floor((ink[io]     * fa + bg[bo]     * fb) * inv + 0.5)
                        ink[io + 1] = math.floor((ink[io + 1] * fa + bg[bo + 1] * fb) * inv + 0.5)
                        ink[io + 2] = math.floor((ink[io + 2] * fa + bg[bo + 2] * fb) * inv + 0.5)
                        ink[io + 3] = math.floor(ao * 255 + 0.5)
                    end
                end
            end
        end
    end
end

-- Save the canvas as a PNG with a transparent background. `opts` may carry
-- `rect` (crop) and `bg` (a canvas sized RGBA FFI buffer to composite under the
-- ink). Returns ok, err.
function Export.savePNG(canvas, path, opts)
    opts = opts or {}
    local Png = require("ffi/png")
    local buf, _, ow, oh = Export.buildRGBA(canvas, opts.rect)
    if opts.bg then
        local offx = opts.rect and opts.rect.x or 0
        local offy = opts.rect and opts.rect.y or 0
        compositeOverBg(buf, ow, oh, opts.bg, canvas.w, offx, offy)
    end
    return Png.encodeToFile(path, buf, ow, oh, 4)
end

-- Save the canvas as a JPEG on a white background. `opts` as for savePNG.
-- Returns ok, err.
function Export.saveJPEG(canvas, path, quality, opts)
    opts = opts or {}
    local Jpeg = require("ffi/jpeg")
    local ow, oh, rgb
    if opts.bg then
        -- composite ink over the background, then flatten the result onto white
        local rgba
        rgba, _, ow, oh = Export.buildRGBA(canvas, opts.rect)
        local offx = opts.rect and opts.rect.x or 0
        local offy = opts.rect and opts.rect.y or 0
        compositeOverBg(rgba, ow, oh, opts.bg, canvas.w, offx, offy)
        rgb = ffi.new("uint8_t[?]", ow * oh * 3)
        for i = 0, ow * oh - 1 do
            local a = rgba[i * 4 + 3] / 255
            for c = 0, 2 do
                rgb[i * 3 + c] = math.floor(rgba[i * 4 + c] * a + 255 * (1 - a) + 0.5)
            end
        end
    else
        rgb, _, ow, oh = Export.buildRGB(canvas, opts.rect)
    end
    return Jpeg.encodeToFile(path, rgb, ow, oh, 3, quality or 90, ow * 3)
end

return Export
