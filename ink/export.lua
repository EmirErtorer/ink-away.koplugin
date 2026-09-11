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
local bit = require("bit")
local Raster = require("ink/raster")
local Shapes = require("ink/shapes")
local Fill = require("ink/fill")
local Symmetry = require("ink/symmetry")

local Export = {}

-- A tiny 5x7 bitmap font (digits, slash, space) so the exporter can stamp a
-- page-number footer without any font/text dependency (keeps this file usable
-- headlessly and identical on every device). Each glyph is 7 rows of 5 bits.
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

-- Stamp `text` (digits / slash / space) centred near the bottom of an ow x oh
-- RGB buffer, at grey level `lvl`. Used for the optional page-number footer.
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
-- `erase_put_for(op)` is a factory returning the span writer for an erase op, so
-- a "hard" erase (one that also removes the background) can behave differently
-- from an ordinary one.
local function replay(canvas, ink_put, erase_put_for)
    local W, H = canvas.w, canvas.h
    local refx, refy = Symmetry.canvasRefs(W, H)
    for _, op in ipairs(canvas.ops) do
        local put
        if op.kind == "erase" then
            put = erase_put_for(op)
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
-- `rect` optionally crops to {x,y,w,h}. `clear_mask` (optional, ow*oh bytes) is
-- set to 1 wherever a "hard" erase (op.ebg) clears, so the background composite
-- can leave those pixels transparent. Returns buf, byte_count, ow, oh.
function Export.buildRGBA(canvas, rect, clear_mask, template)
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
    -- notebook ruling, opaque grey, so it prints on top of any background too
    if template and template.style and template.style ~= "blank" then
        local Template = require("ink/template")
        local g = template.gray or 210
        local tput = function(x, y, len)
            local cx, cy, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (cy * ow + cx) * 4
            for i = 0, clen - 1 do
                local o = base + i * 4
                buf[o] = g; buf[o + 1] = g; buf[o + 2] = g; buf[o + 3] = 255
            end
        end
        Template.render(template.style, canvas.w, canvas.h, template.size or 40, tput)
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
    local function make_erase(hard)
        return function(x, y, len)
            local cx, cy, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (cy * ow + cx) * 4
            for i = 0, clen - 1 do
                local o = base + i * 4
                buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
            end
            if hard and clear_mask then
                local mb = cy * ow + cx
                for i = 0, clen - 1 do clear_mask[mb + i] = 1 end
            end
        end
    end
    local soft_erase, hard_erase = make_erase(false), make_erase(true)
    replay(canvas, ink_put, function(op) return op.ebg and hard_erase or soft_erase end)
    return buf, n, ow, oh
end

-- Build a tightly packed RGB buffer (ow*oh*3 bytes) with ink composited over a
-- solid white background (for JPEG, which has no transparency). `rect` optional.
-- `template` (optional {style,size}) draws a light grey notebook ruling under
-- the ink, so a lined/grid/dotted page prints its paper too.
function Export.buildRGB(canvas, rect, template)
    local ow, oh, offx, offy = dims(canvas, rect)
    local n = ow * oh * 3
    local buf = ffi.new("uint8_t[?]", n)
    -- paper colour: white unless the template asks for a tint (e.g. sandpaper)
    local pr, pg, pb = 255, 255, 255
    if template and template.paper then
        pr, pg, pb = template.paper[1], template.paper[2], template.paper[3]
    end
    if pr == pg and pg == pb then
        ffi.fill(buf, n, pr)
    else
        for i = 0, ow * oh - 1 do local o = i * 3; buf[o] = pr; buf[o + 1] = pg; buf[o + 2] = pb end
    end
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
            buf[o] = pr; buf[o + 1] = pg; buf[o + 2] = pb
        end
    end
    -- notebook ruling first, so ink and erase sit on top of the paper
    if template and template.style and template.style ~= "blank" then
        local Template = require("ink/template")
        local g = template.gray or 210
        local tput = function(x, y, len)
            local cx, cy, clen = clamp_run(x, y, len)
            if not cx then return end
            local base = (cy * ow + cx) * 3
            for i = 0, clen - 1 do
                local o = base + i * 3
                buf[o] = g; buf[o + 1] = g; buf[o + 2] = g
            end
        end
        Template.render(template.style, canvas.w, canvas.h, template.size or 40, tput)
    end
    replay(canvas, ink_put, function() return erase_put end)
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
    replay(canvas, ink_put, function() return erase_put end)
    return buf
end

-- Composite the ink RGBA layer `ink` over the background RGBA `bg` (both packed
-- ow*oh*4). `bg` is canvas sized; `offx,offy` place the crop within it. Writes
-- the result back into `ink`. Standard "source over" alpha compositing.
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

-- Save the canvas as a PNG with a transparent background. `opts` may carry
-- `rect` (crop) and `bg` (a canvas sized RGBA FFI buffer to composite under the
-- ink). Returns ok, err.
function Export.savePNG(canvas, path, opts)
    opts = opts or {}
    local Png = require("ffi/png")
    local ow, oh = dims(canvas, opts.rect)
    local mask = opts.bg and ffi.new("uint8_t[?]", ow * oh) or nil
    local buf = Export.buildRGBA(canvas, opts.rect, mask)
    if opts.bg then
        local offx = opts.rect and opts.rect.x or 0
        local offy = opts.rect and opts.rect.y or 0
        compositeOverBg(buf, ow, oh, opts.bg, canvas.w, offx, offy, mask)
    end
    return Png.encodeToFile(path, buf, ow, oh, 4)
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

-- Save the canvas as a JPEG on a white background. `opts` may carry `rect`,
-- `template`, `bg`, `footer`, and `scale` (integer >1 renders the page at a
-- higher pixel resolution: the background is expected pre-rendered at that
-- size, the ink layer is upscaled to match, so text-heavy PDF pages stay crisp).
-- Returns ok, err, pixel_w, pixel_h.
function Export.saveJPEG(canvas, path, quality, opts)
    opts = opts or {}
    local Jpeg = require("ffi/jpeg")
    local ow, oh, rgb
    if opts.bg then
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
    local ok, err = Jpeg.encodeToFile(path, rgb, ow, oh, 3, quality or 90, ow * 3)
    return ok, err, ow, oh
end

-- Assemble a notebook (a list of per-page ops lists) into a single PDF at
-- `path`, one fixed-size page each, with the shared `template` ruling. Pages
-- are rendered to JPEG one at a time through a scratch file in `tmp_dir`, so
-- memory stays flat no matter how many pages. `bg` is an optional background:
-- either one RGBA buffer shared by every page, or a function(i) -> RGBA buffer
-- that renders each page's own background on demand (used for PDF import).
-- Returns ok, err.
-- `opts` (optional): { footer = bool (stamp "i / n" page numbers),
-- scale = integer (render pages at this pixel multiplier for crisp PDF text) }.
function Export.notebookToPDF(pages, w, h, template, path, quality, tmp_dir, bg, opts)
    opts = opts or {}
    local scale = opts.scale or 1
    local Pdf = require("ink/pdf")
    local Canvas = require("ink/canvas")
    local doc = Pdf.new()
    tmp_dir = tmp_dir or "/tmp"
    for i, ops in ipairs(pages) do
        local c = Canvas.new(w, h)
        c:setOps(ops)
        local page_bg = (type(bg) == "function") and bg(i, scale) or bg
        local jopts = { template = template, bg = page_bg,
            scale = (page_bg and scale) or 1,
            footer = opts.footer and (tostring(i) .. " / " .. #pages) or nil }
        local tmp = tmp_dir .. "/inkaway_page_" .. i .. ".jpg"
        local ok, err, pxw, pxh = Export.saveJPEG(c, tmp, quality or 85, jopts)
        if not ok then return false, err end
        local f = io.open(tmp, "rb")
        if not f then return false, "could not read rendered page" end
        local bytes = f:read("*a")
        f:close()
        os.remove(tmp)
        doc:addJPEGPage(bytes, w, h, pxw, pxh)
    end
    return doc:save(path)
end

return Export
