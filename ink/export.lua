--[[
Export: the canvas (or a crop of it) as PNG or JPEG, and a notebook as PDF.

PNG is true RGBA: untouched pixels are fully transparent (good for sleep screen
overlays). JPEG has no alpha, so the ink is laid over white. A loaded background
can be included or left out; the on-screen grid is never exported.

Pixels are built from the ops into tightly packed FFI byte arrays at save time
and dropped afterwards, so no export-sized buffer lives on while drawing.
Encoding goes through KOReader's FFI wrappers:
    ffi/png.encodeToFile(path, mem, w, h, 4)              -> LCT_RGBA
    ffi/jpeg.encodeToFile(path, mem, w, h, 3, q, stride)  -> TJPF_RGB
They are required lazily, so the buffer building is testable without them.
]]

local ffi = require("ffi")
local bit = require("bit")
local Canvas = require("ink/canvas")
local Fill = require("ink/fill")
local Pdf = require("ink/pdf")
local Raster = require("ink/raster")
local Shapes = require("ink/shapes")
local Symmetry = require("ink/symmetry")
local Template = require("ink/template")

local Export = {}

-- A tiny 5x7 bitmap font (digits, slash, space) for the page-number footer, so
-- the exporter needs no fonts. Each glyph is 7 rows of 5 bits.
local GLYPHS = {
    ["0"] = { 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
    ["1"] = { 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
    ["2"] = { 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
    ["3"] = { 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E },
    ["4"] = { 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
    ["5"] = { 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
    ["6"] = { 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
    ["7"] = { 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
    ["8"] = { 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
    ["9"] = { 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
    ["/"] = { 0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10 },
    [" "] = { 0, 0, 0, 0, 0, 0, 0 },
}

-- Stamp `text` (digits, slash, space) centred near the bottom of an ow x oh RGB
-- buffer at grey level `lvl`: the optional page-number footer.
function Export.drawFooter(buf, ow, oh, text, lvl)
    if not text or text == "" then return end
    lvl = lvl or 90
    local gs = math.max(2, math.floor(oh / 320))     -- pixel size of one font dot
    local cw = 6 * gs                                 -- glyph cell width (5 + 1 gap)
    local total = #text * cw - gs
    local x0 = math.floor((ow - total) / 2)
    local y0 = oh - 7 * gs - math.max(gs * 2, math.floor(oh * 0.02))
    if x0 < 0 or y0 < 0 then return end
    for ci = 1, #text do
        local g = GLYPHS[text:sub(ci, ci)] or GLYPHS[" "]
        local gx = x0 + (ci - 1) * cw
        for row = 1, 7 do
            local bits = g[row]
            for col = 0, 4 do
                if bit.band(bits, bit.lshift(1, 4 - col)) ~= 0 then
                    for dy = 0, gs - 1 do
                        local py = y0 + (row - 1) * gs + dy
                        local base = (py * ow + gx + col * gs) * 3
                        for dx = 0, gs - 1 do
                            local o = base + dx * 3
                            buf[o] = lvl; buf[o + 1] = lvl; buf[o + 2] = lvl
                        end
                    end
                end
            end
        end
    end
end

-- Draw an op's geometry through `put` (shapes, fills and strokes all share this).
local function paintGeom(op, put, fill_put)
    if op.kind == "shape" then
        -- a bucket-filled interior (its own colour), painted under the outline
        if fill_put and op.fill_color and not op.fill then Shapes.fill(op, fill_put) end
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

-- Replay every committed op. `ink_put(r,g,b,alpha)` returns the span writer for
-- ink of that colour and opacity, and `erase_put_for(op)` the writer for an erase
-- (a hard erase, which also removes the background, differs from a soft one).
-- Each op's writer is wrapped for its own symmetry mode. The RGBA and RGB
-- builders and the fill's grey buffer all replay through here, so they match the
-- rasterizer pixel for pixel.
local function replay(canvas, ink_put, erase_put_for, text_put, image_put)
    local W, H = canvas.w, canvas.h
    local refx, refy = Symmetry.canvasRefs(W, H)
    for _, op in ipairs(canvas.ops) do
        if op.kind == "text" then
            -- text comes from a rasteriser the view injects (Export.text_raster),
            -- in z-order; a text-sparing erase reveals a copy with the text, so
            -- the file matches the screen
            if text_put and not op.hidden then text_put(op) end
        elseif op.kind == "image" then
            -- a placed picture, from the RGBA buffer the view injects
            -- (Export.image_raster), in z-order
            if image_put and not op.hidden then image_put(op) end
        else
            local put, fill_put
            if op.kind == "erase" then
                put = erase_put_for(op)
            else
                local r, g, b = opRGB(op)
                put = ink_put(r, g, b, op.alpha or 255)
                if op.kind == "shape" and op.fill_color and not op.fill then
                    local fc = op.fill_color
                    fill_put = Symmetry.wrap(
                        ink_put(fc[1] or 0, fc[2] or 0, fc[3] or 0, op.fill_alpha or 255),
                        op.sym, refx, refy)
                end
            end
            paintGeom(op, Symmetry.wrap(put, op.sym, refx, refy), fill_put)
        end
    end
end

-- Walk the glyph pixels of a text op. The view sets Export.text_raster to a
-- function(op) returning (uint8 level buffer, w, h), where 255 is untouched white
-- and lower values are ink and highlight shades. `cb(x, y, level)` gets each
-- non-white pixel in canvas coordinates. Without a rasteriser (the headless
-- tests have no fonts) text is skipped.
function Export.eachTextPixel(op, cb)
    if not Export.text_raster then return end
    local raster, w, h = Export.text_raster(op)
    if not raster then return end
    local ox, oy = math.floor(op.x + 0.5), math.floor(op.y + 0.5)
    for py = 0, h - 1 do
        local row = py * w
        for px = 0, w - 1 do
            local L = raster[row + px]
            if L < 255 then cb(ox + px, oy + py, L) end
        end
    end
end

-- Walk the pixels of an image op. The view sets Export.image_raster to a
-- function(op) returning (rgba buffer, w, h, ox, oy): the picture flipped,
-- rotated and scaled to its on-page size, with (ox, oy) its top-left in canvas
-- coordinates (not op.x, op.y once rotated). `cb(x, y, r, g, b, a)` gets each
-- pixel with non-zero alpha, in canvas coordinates. Without a rasteriser (the
-- headless tests have no decoder) images are skipped.
function Export.eachImagePixel(op, cb)
    if not Export.image_raster then return end
    local buf, w, h, rx, ry = Export.image_raster(op)
    if not buf then return end
    local ox = math.floor((rx or op.x) + 0.5)
    local oy = math.floor((ry or op.y) + 0.5)
    for py = 0, h - 1 do
        local row = py * w * 4
        for px = 0, w - 1 do
            local o = row + px * 4
            local a = buf[o + 3]
            if a > 0 then cb(ox + px, oy + py, buf[o], buf[o + 1], buf[o + 2], a) end
        end
    end
end

-- The output size and coordinate offset for an optional crop rect. With no rect
-- the whole canvas is used.
local function dims(canvas, rect)
    if rect then return rect.w, rect.h, rect.x, rect.y end
    return canvas.w, canvas.h, 0, 0
end

-- Does this notebook template draw a ruling?
local function ruled(template)
    return template and template.style and template.style ~= "blank"
end

-- A function mapping a canvas run (x, y, len) into an ow x oh output offset by
-- (offx, offy). Returns the output x, y and clipped length, or nil when outside.
local function clipper(ow, oh, offx, offy)
    return function(x, y, len)
        x = x - offx; y = y - offy
        if y < 0 or y >= oh then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > ow then len = ow - x end
        if len <= 0 then return end
        return x, y, len
    end
end

-- A span writer that fills runs with one colour, in an RGBA (bpp 4) or RGB
-- (bpp 3) buffer.
local function fillRun(buf, ow, bpp, clip, r, g, b, a)
    if bpp == 4 then
        return function(x, y, len)
            local cx, cy, clen = clip(x, y, len)
            if not cx then return end
            local base = (cy * ow + cx) * 4
            for i = 0, clen - 1 do
                local o = base + i * 4
                buf[o] = r; buf[o + 1] = g; buf[o + 2] = b; buf[o + 3] = a
            end
        end
    end
    return function(x, y, len)
        local cx, cy, clen = clip(x, y, len)
        if not cx then return end
        local base = (cy * ow + cx) * 3
        for i = 0, clen - 1 do
            local o = base + i * 3
            buf[o] = r; buf[o + 1] = g; buf[o + 2] = b
        end
    end
end

-- A span writer that copies runs from `src`, a buffer of the same layout: how an
-- erase reveals the page underneath.
local function copyRun(buf, src, ow, bpp, clip)
    return function(x, y, len)
        local cx, cy, clen = clip(x, y, len)
        if not cx then return end
        local o = (cy * ow + cx) * bpp   -- the clip keeps the run inside both buffers
        ffi.copy(buf + o, src + o, clen * bpp)
    end
end

-- A pixel writer for text: grey level L, opaque.
local function textPixel(buf, ow, bpp, clip)
    return function(x, y, L)
        local cx, cy = clip(x, y, 1)
        if not cx then return end
        local o = (cy * ow + cx) * bpp
        buf[o] = L; buf[o + 1] = L; buf[o + 2] = L
        if bpp == 4 then buf[o + 3] = 255 end
    end
end

-- What an erase reveals, as on screen: a copy of the page so far (paper and
-- ruling) with the placed images on it, and for a text-sparing erase a second
-- copy with the text on top. Both nil when nothing is erased.
local function revealSources(canvas, buf, n, ow, bpp, clip, putImage)
    local flags = Canvas.scanOps(canvas.ops)
    if not flags.erase then return nil, nil end
    local base = ffi.new("uint8_t[?]", n)
    ffi.copy(base, buf, n)
    if flags.image then
        for _, op in ipairs(canvas.ops) do
            if not op.hidden and op.kind == "image" then putImage(base, op) end
        end
    end
    local text
    if flags.spare_text and flags.text then
        text = ffi.new("uint8_t[?]", n)
        ffi.copy(text, base, n)
        local px = textPixel(text, ow, bpp, clip)
        for _, op in ipairs(canvas.ops) do
            if not op.hidden and op.kind == "text" then Export.eachTextPixel(op, px) end
        end
    end
    return base, text
end

-- Build a packed RGBA buffer (ow*oh*4 bytes), transparent where there is no ink.
-- `rect` optionally crops to {x,y,w,h}. The optional `clear_mask` (ow*oh bytes)
-- gets 1 wherever a hard erase (op.ebg) clears, so the background composite
-- leaves those pixels transparent. Returns buf, byte_count, ow, oh.
function Export.buildRGBA(canvas, rect, clear_mask, template)
    local ow, oh, offx, offy = dims(canvas, rect)
    local n = ow * oh * 4
    local buf = ffi.new("uint8_t[?]", n)  -- starts all zero, so fully transparent
    local clip = clipper(ow, oh, offx, offy)
    -- notebook ruling, opaque grey, so it prints on top of any background too
    if ruled(template) then
        local g = template.gray or 210
        Template.render(template.style, canvas.w, canvas.h, template.size or 40,
            fillRun(buf, ow, 4, clip, g, g, g, 255))
    end
    -- a placed image, source-over onto what is there (a transparent PNG shows the
    -- ink beneath, and the page stays transparent where the PNG is)
    local function putImage(dst, op)
        Export.eachImagePixel(op, function(x, y, r, g, b, a)
            local cx, cy = clip(x, y, 1)
            if not cx then return end
            local o = (cy * ow + cx) * 4
            if a >= 255 then
                dst[o] = r; dst[o + 1] = g; dst[o + 2] = b; dst[o + 3] = 255
                return
            end
            local sa = a / 255
            local da = dst[o + 3] / 255
            local outa = sa + da * (1 - sa)
            if outa <= 0 then
                dst[o] = 0; dst[o + 1] = 0; dst[o + 2] = 0; dst[o + 3] = 0
                return
            end
            local function ov(sc, dc) return math.floor((sc * sa + dc * da * (1 - sa)) / outa + 0.5) end
            dst[o]     = ov(r, dst[o])
            dst[o + 1] = ov(g, dst[o + 1])
            dst[o + 2] = ov(b, dst[o + 2])
            dst[o + 3] = math.floor(outa * 255 + 0.5)
        end)
    end
    -- a soft erase reveals the page so far; a hard one (op.ebg) clears to fully
    -- transparent and marks the background to be dropped too
    local base_buf, text_buf = revealSources(canvas, buf, n, ow, 4, clip, putImage)
    local function hard_erase(x, y, len)
        local cx, cy, clen = clip(x, y, len)
        if not cx then return end
        local base = (cy * ow + cx) * 4
        for i = 0, clen - 1 do
            local o = base + i * 4
            buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
        end
        if clear_mask then
            local mb = cy * ow + cx
            for i = 0, clen - 1 do clear_mask[mb + i] = 1 end
        end
    end
    local plain_erase = base_buf and copyRun(buf, base_buf, ow, 4, clip)
    local spare_erase = text_buf and copyRun(buf, text_buf, ow, 4, clip) or plain_erase
    local text_px = textPixel(buf, ow, 4, clip)
    replay(canvas,
        function(r, g, b, alpha) return fillRun(buf, ow, 4, clip, r, g, b, alpha) end,
        function(op)
            if op.ebg then return hard_erase end
            if op.spare_text and spare_erase then return spare_erase end
            return plain_erase or hard_erase
        end,
        function(op) Export.eachTextPixel(op, text_px) end,
        function(op) putImage(buf, op) end)
    return buf, n, ow, oh
end

-- Build a packed RGB buffer (ow*oh*3 bytes) with the ink over white, for JPEG.
-- `rect` optionally crops; `template` (optional {style,size}) draws the notebook
-- ruling under the ink, so a ruled page prints its paper too.
function Export.buildRGB(canvas, rect, template)
    local ow, oh, offx, offy = dims(canvas, rect)
    local n = ow * oh * 3
    local buf = ffi.new("uint8_t[?]", n)
    -- paper colour: white unless the template asks for a tint
    local pr, pg, pb = 255, 255, 255
    if template and template.paper then
        pr, pg, pb = template.paper[1], template.paper[2], template.paper[3]
    end
    if pr == pg and pg == pb then
        ffi.fill(buf, n, pr)
    else
        for i = 0, ow * oh - 1 do local o = i * 3; buf[o] = pr; buf[o + 1] = pg; buf[o + 2] = pb end
    end
    local clip = clipper(ow, oh, offx, offy)
    -- a placed image over the (opaque) buffer, blended by its alpha
    local function putImage(dst, op)
        Export.eachImagePixel(op, function(x, y, r, g, b, a)
            local cx, cy = clip(x, y, 1)
            if not cx then return end
            local o = (cy * ow + cx) * 3
            if a >= 255 then
                dst[o] = r; dst[o + 1] = g; dst[o + 2] = b
                return
            end
            local sa = a / 255
            dst[o]     = math.floor(r * sa + dst[o] * (1 - sa) + 0.5)
            dst[o + 1] = math.floor(g * sa + dst[o + 1] * (1 - sa) + 0.5)
            dst[o + 2] = math.floor(b * sa + dst[o + 2] * (1 - sa) + 0.5)
        end)
    end
    -- notebook ruling first, so ink and erase sit on top of the paper
    if ruled(template) then
        local g = template.gray or 210
        Template.render(template.style, canvas.w, canvas.h, template.size or 40,
            fillRun(buf, ow, 3, clip, g, g, g))
    end
    local base_buf, text_buf = revealSources(canvas, buf, n, ow, 3, clip, putImage)
    local plain_erase = base_buf and copyRun(buf, base_buf, ow, 3, clip)
    local spare_erase = text_buf and copyRun(buf, text_buf, ow, 3, clip) or plain_erase
    local paper_erase = fillRun(buf, ow, 3, clip, pr, pg, pb)
    local text_px = textPixel(buf, ow, 3, clip)
    -- JPEG has no alpha, so ink is laid over white: each channel becomes
    -- 255 - alpha * (255 - c) / 255, which is how the ink looks on the white canvas.
    replay(canvas,
        function(r, g, b, alpha)
            local function over(c) return math.floor(255 - alpha * (255 - c) / 255 + 0.5) end
            return fillRun(buf, ow, 3, clip, over(r), over(g), over(b))
        end,
        function(op)
            if op.spare_text and spare_erase then return spare_erase end
            return plain_erase or paper_erase
        end,
        function(op) Export.eachTextPixel(op, text_px) end,
        function(op) putImage(buf, op) end)
    return buf, n, ow, oh
end

-- Build a packed 8-bit grey buffer of the drawing over white, for the flood fill
-- to find an enclosed area (mirrored ink included).
function Export.buildGray(canvas)
    local w, h = canvas.w, canvas.h
    local n = w * h
    local buf = ffi.new("uint8_t[?]", n)
    ffi.fill(buf, n, 0xFF)
    local clip = clipper(w, h, 0, 0)
    local function ink_put(r, g, b, alpha)
        local lum = 0.299 * r + 0.587 * g + 0.114 * b
        local g8 = math.floor(255 - alpha * (255 - lum) / 255 + 0.5)
        return function(x, y, len)
            local cx, cy, clen = clip(x, y, len)
            if not cx then return end
            local base = cy * w + cx
            for i = 0, clen - 1 do buf[base + i] = g8 end
        end
    end
    local function erase_put(x, y, len)
        local cx, cy, clen = clip(x, y, len)
        if not cx then return end
        local base = cy * w + cx
        for i = 0, clen - 1 do buf[base + i] = 0xFF end
    end
    replay(canvas, ink_put, function() return erase_put end)
    return buf
end

-- Composite the RGBA ink layer `ink` over the RGBA background `bg` (source over),
-- writing the result into `ink`. `bg` is canvas sized and (offx, offy) place the
-- crop within it.
local function compositeOverBg(ink, ow, oh, bg, bgw, offx, offy, clear_mask)
    for y = 0, oh - 1 do
        local by = (y + offy)
        for x = 0, ow - 1 do
            local i = y * ow + x
            local io = i * 4
            local ai = ink[io + 3]
            if ai < 255 and not (clear_mask and clear_mask[i] == 1) then
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

-- Lay a packed RGBA buffer onto opaque white.
local function flattenOnWhite(buf, ow, oh)
    for i = 0, ow * oh - 1 do
        local o = i * 4
        local a = buf[o + 3]
        if a < 255 then
            local k = a / 255
            buf[o]     = math.floor(buf[o] * k + 255 * (1 - k) + 0.5)
            buf[o + 1] = math.floor(buf[o + 1] * k + 255 * (1 - k) + 0.5)
            buf[o + 2] = math.floor(buf[o + 2] * k + 255 * (1 - k) + 0.5)
            buf[o + 3] = 255
        end
    end
end

-- The RGBA pixels a PNG export encodes. `opts` may carry `rect` (crop), `bg` (a
-- canvas sized RGBA FFI buffer to composite under the ink), `template` (a
-- notebook ruling under the ink) and `white` (lay it all on white instead of
-- leaving the page transparent). Returns buf, w, h.
function Export.buildPNGRGBA(canvas, opts)
    opts = opts or {}
    local ow, oh = dims(canvas, opts.rect)
    local mask = opts.bg and ffi.new("uint8_t[?]", ow * oh) or nil
    local buf = Export.buildRGBA(canvas, opts.rect, mask, opts.template)
    if opts.bg then
        local offx = opts.rect and opts.rect.x or 0
        local offy = opts.rect and opts.rect.y or 0
        compositeOverBg(buf, ow, oh, opts.bg, canvas.w, offx, offy, mask)
    end
    if opts.white then flattenOnWhite(buf, ow, oh) end
    return buf, ow, oh
end

-- Save the canvas as a PNG (see buildPNGRGBA for `opts`). Returns ok, err.
function Export.savePNG(canvas, path, opts)
    local buf, ow, oh = Export.buildPNGRGBA(canvas, opts)
    return require("ffi/png").encodeToFile(path, buf, ow, oh, 4)
end

-- Nearest-neighbour upscale of a packed RGBA buffer by integer factor s.
local function upscaleRGBA(src, ow, oh, s)
    local dw, dh = ow * s, oh * s
    local dst = ffi.new("uint8_t[?]", dw * dh * 4)
    for y = 0, dh - 1 do
        local sy = math.floor(y / s)
        for x = 0, dw - 1 do
            local so = (sy * ow + math.floor(x / s)) * 4
            local d = (y * dw + x) * 4
            dst[d] = src[so]; dst[d + 1] = src[so + 1]; dst[d + 2] = src[so + 2]; dst[d + 3] = src[so + 3]
        end
    end
    return dst, dw, dh
end

local function upscaleMask(src, ow, oh, s)
    local dw, dh = ow * s, oh * s
    local dst = ffi.new("uint8_t[?]", dw * dh)
    for y = 0, dh - 1 do
        local sy = math.floor(y / s)
        for x = 0, dw - 1 do dst[y * dw + x] = src[sy * ow + math.floor(x / s)] end
    end
    return dst
end

-- The RGB pixels a JPEG export encodes (see saveJPEG for `opts`). Returns rgb, w, h.
function Export.buildJPEGRGB(canvas, opts)
    opts = opts or {}
    local ow, oh, rgb, _
    if opts.bg and not opts.rect and not ruled(opts.template) and not opts.no_fast
            and not Export.hasVisibleOps(canvas) then
        -- nothing drawn on this page (most pages of an imported PDF): the result
        -- is the background flattened onto white, as the general path would give
        local s = opts.scale or 1
        ow, oh = canvas.w * s, canvas.h * s
        local bg = opts.bg
        rgb = ffi.new("uint8_t[?]", ow * oh * 3)
        for i = 0, ow * oh - 1 do
            local bo, o = i * 4, i * 3
            local a = bg[bo + 3]
            if a == 255 then
                rgb[o], rgb[o + 1], rgb[o + 2] = bg[bo], bg[bo + 1], bg[bo + 2]
            elseif a == 0 then
                rgb[o], rgb[o + 1], rgb[o + 2] = 255, 255, 255
            else
                local fa = a / 255
                for c = 0, 2 do rgb[o + c] = math.floor(bg[bo + c] * fa + 255 * (1 - fa) + 0.5) end
            end
        end
    elseif opts.bg then
        -- composite ink over the background, then flatten the result onto white
        ow, oh = dims(canvas, opts.rect)
        local mask = ffi.new("uint8_t[?]", ow * oh)
        local rgba = Export.buildRGBA(canvas, opts.rect, mask, opts.template)
        local offx = opts.rect and opts.rect.x or 0
        local offy = opts.rect and opts.rect.y or 0
        local bgw = canvas.w
        local s = opts.scale or 1
        if s > 1 then      -- match the ink layer to the high-res background
            rgba, ow, oh = upscaleRGBA(rgba, ow, oh, s)
            mask = upscaleMask(mask, ow / s, oh / s, s)
            offx, offy, bgw = 0, 0, ow
        end
        compositeOverBg(rgba, ow, oh, opts.bg, bgw, offx, offy, mask)
        rgb = ffi.new("uint8_t[?]", ow * oh * 3)
        for i = 0, ow * oh - 1 do
            local a = rgba[i * 4 + 3] / 255
            for c = 0, 2 do
                rgb[i * 3 + c] = math.floor(rgba[i * 4 + c] * a + 255 * (1 - a) + 0.5)
            end
        end
    else
        rgb, _, ow, oh = Export.buildRGB(canvas, opts.rect, opts.template)
    end
    if opts.footer then Export.drawFooter(rgb, ow, oh, opts.footer) end
    return rgb, ow, oh
end

-- Is anything drawn on this canvas?
function Export.hasVisibleOps(canvas)
    for _, op in ipairs(canvas.ops or {}) do
        if not op.hidden then return true end
    end
    return false
end

-- Save the canvas as a JPEG on white. `opts` may carry `rect`, `template`, `bg`,
-- `footer` and `scale`: an integer above 1 renders at that pixel multiple (the
-- background comes rendered at that size and the ink is upscaled to match), so
-- text in an imported PDF stays crisp. Returns ok, err, pixel_w, pixel_h.
function Export.saveJPEG(canvas, path, quality, opts)
    local Jpeg = require("ffi/jpeg")
    opts = opts or {}
    if opts.bg and opts.bg_opaque and not opts.footer and not opts.rect and not ruled(opts.template)
            and not opts.no_fast and not Export.hasVisibleOps(canvas) then
        -- an empty page over an opaque background (an imported PDF page with no
        -- ink) is the background itself, encoded as it is
        local s = opts.scale or 1
        local ow, oh = canvas.w * s, canvas.h * s
        local ok, err = Jpeg.encodeToFile(path, opts.bg, ow, oh, 4, quality or 90, ow * 4)
        return ok, err, ow, oh
    end
    local rgb, ow, oh = Export.buildJPEGRGB(canvas, opts)
    local ok, err = Jpeg.encodeToFile(path, rgb, ow, oh, 3, quality or 90, ow * 3)
    return ok, err, ow, oh
end

-- Export a notebook (a list of per-page op lists) to a PDF at `path`: one page
-- each with the shared `template` ruling, as a job that does one page per step()
-- so the UI can show progress and stop it. Each page goes through a JPEG scratch
-- file in `tmp_dir` straight into the PDF, so memory stays flat.
--   bg:   optional background, one RGBA buffer for every page or a
--         function(i, scale) -> RGBA buffer rendering each page's own
--   opts: { footer = stamp "i / n" page numbers, scale = pixel multiplier,
--           bg_opaque = the background has no transparency }
-- step() returns "page", i, n while working, "done" when the file is complete,
-- or nil, err (the partial file is removed). cancel() stops and deletes it.
function Export.notebookPDFJob(pages, w, h, template, path, quality, tmp_dir, bg, opts)
    opts = opts or {}
    local scale = opts.scale or 1
    tmp_dir = tmp_dir or "/tmp"
    local stream, err = Pdf.openStream(path)
    if not stream then return nil, err end
    local job = { i = 0, n = #pages }
    local tmp = tmp_dir .. "/inkaway_page.jpg"
    local function fail(e)
        stream:abort(); os.remove(tmp); job.over = true
        return nil, e
    end
    function job.step()
        if job.over then return nil, "finished" end
        if job.i >= job.n then
            local ok, e = stream:finish()
            job.over = true
            if not ok then return nil, e end
            return "done"
        end
        job.i = job.i + 1
        local i = job.i
        local c = Canvas.new(w, h)
        c:setOps(pages[i])
        local page_bg = (type(bg) == "function") and bg(i, scale) or bg
        local jopts = { template = template, bg = page_bg, bg_opaque = opts.bg_opaque,
            scale = (page_bg and scale) or 1,
            footer = opts.footer and (tostring(i) .. " / " .. job.n) or nil }
        local ok, e, pxw, pxh = Export.saveJPEG(c, tmp, quality or 85, jopts)
        if not ok then return fail(e or "could not render a page") end
        ok, e = stream:addJPEGFile(tmp, w, h, pxw, pxh)
        os.remove(tmp)
        if not ok then return fail(e) end
        -- release this page's buffers now (several MB each), not whenever the GC
        -- gets round to it, so a long export never piles them up
        page_bg, c, jopts = nil, nil, nil
        collectgarbage("collect")
        return "page", i, job.n
    end
    function job.cancel()
        if job.over then return end
        stream:abort(); os.remove(tmp); job.over = true
    end
    return job
end

return Export
