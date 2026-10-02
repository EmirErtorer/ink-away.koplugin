--[[
Pixel work on decoded pictures: RGBA conversion for export, background removal,
rotating and flipping, and fitting a picture onto a page.
]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")

local WHITE = Blitbuffer.COLOR_WHITE

local ImageProc = {}

-- Worked out once: are a BBRGB32 buffer's bytes laid out R,G,B,A (so they can be
-- copied straight into an RGBA export buffer) or B,G,R,A (so R and B must swap)?
local rgb32_is_rgba = nil
local function rgb32IsRGBA()
    if rgb32_is_rgba ~= nil then return rgb32_is_rgba end
    rgb32_is_rgba = true
    pcall(function()
        local probe = Blitbuffer.new(1, 1, Blitbuffer.TYPE_BBRGB32)
        probe:setPixel(0, 0, Blitbuffer.ColorRGB32(10, 20, 30, 40))
        local p = ffi.cast("uint8_t*", probe.data)
        rgb32_is_rgba = (p[0] == 10 and p[1] == 20 and p[2] == 30)
        probe:free()
    end)
    return rgb32_is_rgba
end

-- Convert a canvas-sized BBRGB32 into a packed RGBA FFI buffer (r,g,b,a), one
-- memcpy per row. Panels that store B,G,R,A get R/B swapped back. Returns buf or nil.
local function bbToRGBA(bb, W, H)
    if not bb then return nil end
    local buf = ffi.new("uint8_t[?]", W * H * 4)
    local ok = pcall(function()
        local src = ffi.cast("uint8_t*", bb.data)
        local stride = bb.stride or (W * 4)
        for y = 0, H - 1 do ffi.copy(buf + y * W * 4, src + y * stride, W * 4) end
    end)
    if not ok then return nil end
    if not rgb32IsRGBA() then
        for i = 0, W * H - 1 do local o = i * 4; buf[o], buf[o + 2] = buf[o + 2], buf[o] end
    end
    return buf
end

-- Remove the background from a decoded picture (a first-pass "smart" cutout for
-- making transparent PNGs). It floods inward FROM THE BORDERS through pixels whose
-- colour is close to the sampled background colour, and only those connected-to-the-
-- edge pixels are made transparent -- so dark (or light) parts of the SUBJECT that
-- are not joined to the border stay solid. This is what a plain global threshold
-- cannot do: on a photo it would fade the whole subject wherever it matched the
-- background's brightness (a grey cat on a dark background went translucent). The
-- background colour is sampled from the four borders, the tolerance adapts to how
-- noisy that border is, and the mask edge is softened so it isn't jagged. One
-- scan-line flood over the raw bytes, so it stays fast on a slow reader. `src` is a
-- BBRGB32; returns a packed RGBA (r,g,b,a) FFI buffer for ffi/png.encodeToFile, or nil.
--
-- Works on any background colour (white paper, black, a solid colour), keeping the
-- subject's own colour. Limits: it needs a background that actually reaches the
-- edges and is reasonably distinct from the subject; a subject touching all four
-- borders, or one the same colour as the background, is where a lasso (planned
-- next) will bound the region.
local function bgRemovedRGBA(src)
    if not src then return nil end
    local w, h = src:getWidth(), src:getHeight()
    if w < 3 or h < 3 then return nil end
    local out = ffi.new("uint8_t[?]", w * h * 4)
    local ok = pcall(function()
        local rgba = rgb32IsRGBA()
        local ri = rgba and 0 or 2      -- byte offset of R (B when the panel is BGRA)
        local bi = rgba and 2 or 0      -- byte offset of B; G is always 1, alpha 3
        local sp = ffi.cast("uint8_t*", src.data)
        local ss = src.stride or (w * 4)
        -- background reference colour = mean of the four borders
        local sr, sg, sb, cnt = 0, 0, 0, 0
        local function accum(o) sr = sr + sp[o + ri]; sg = sg + sp[o + 1]; sb = sb + sp[o + bi]; cnt = cnt + 1 end
        for x = 0, w - 1 do accum(x * 4); accum((h - 1) * ss + x * 4) end
        for y = 0, h - 1 do accum(y * ss); accum(y * ss + (w - 1) * 4) end
        local br, bgc, bbc = sr / cnt, sg / cnt, sb / cnt
        -- colour distance (Manhattan) from that reference
        local function distO(o)
            local dr = sp[o + ri] - br; if dr < 0 then dr = -dr end
            local dg = sp[o + 1] - bgc; if dg < 0 then dg = -dg end
            local db = sp[o + bi] - bbc; if db < 0 then db = -db end
            return dr + dg + db
        end
        -- adapt the tolerance to how varied the border is (a clean border gets a
        -- tight tolerance so little of the subject is caught; a noisy one gets more)
        local mad, m2 = 0, 0
        for x = 0, w - 1 do mad = mad + distO(x * 4) + distO((h - 1) * ss + x * 4); m2 = m2 + 2 end
        for y = 0, h - 1 do mad = mad + distO(y * ss) + distO(y * ss + (w - 1) * 4); m2 = m2 + 2 end
        mad = mad / math.max(1, m2)
        local tol = math.max(80, math.min(260, 2.5 * mad + 60))
        local feather = tol * 0.5      -- reached pixels this close to the tol edge fade in
        local core = tol - feather
        -- scan-line flood from the borders through pixels within tol of the bg
        local seen = ffi.new("uint8_t[?]", w * h)   -- 0 unknown, 1 background
        local stack, sn = {}, 0
        local function push(x, y) sn = sn + 1; stack[sn] = x; sn = sn + 1; stack[sn] = y end
        local function free_at(x, y) return seen[y * w + x] == 0 and distO(y * ss + x * 4) <= tol end
        for x = 0, w - 1 do
            if free_at(x, 0) then push(x, 0) end
            if free_at(x, h - 1) then push(x, h - 1) end
        end
        for y = 0, h - 1 do
            if free_at(0, y) then push(0, y) end
            if free_at(w - 1, y) then push(w - 1, y) end
        end
        while sn > 0 do
            local y = stack[sn]; sn = sn - 1
            local x = stack[sn]; sn = sn - 1
            if free_at(x, y) then
                local row, so = y * w, y * ss
                local xl = x
                while xl > 0 and free_at(xl - 1, y) do xl = xl - 1 end
                local xr = x
                while xr < w - 1 and free_at(xr + 1, y) do xr = xr + 1 end
                for xx = xl, xr do seen[row + xx] = 1 end
                if y > 0 then
                    local xx = xl
                    while xx <= xr do
                        if free_at(xx, y - 1) then push(xx, y - 1)
                            while xx <= xr and free_at(xx, y - 1) do xx = xx + 1 end
                        else xx = xx + 1 end
                    end
                end
                if y < h - 1 then
                    local xx = xl
                    while xx <= xr do
                        if free_at(xx, y + 1) then push(xx, y + 1)
                            while xx <= xr and free_at(xx, y + 1) do xx = xx + 1 end
                        else xx = xx + 1 end
                    end
                end
            end
        end
        -- build RGBA: subject opaque; background transparent, fading in near the edge
        local i = 0
        for y = 0, h - 1 do
            local so, row = y * ss, y * w
            for x = 0, w - 1 do
                local o = so + x * 4
                local a
                if seen[row + x] == 1 then
                    local d = distO(o)
                    if d <= core then a = 0
                    else a = math.floor((d - core) / feather * 255 + 0.5); if a > 255 then a = 255 end end
                else
                    a = 255
                end
                out[i] = sp[o + ri]; out[i + 1] = sp[o + 1]; out[i + 2] = sp[o + bi]; out[i + 3] = a
                i = i + 4
            end
        end
    end)
    if not ok then return nil end
    return out
end

-- Fit a source BlitBuffer inside a W x H page keeping its aspect, centre it on a
-- white RGB32 page, and free the source. Returns the new page BlitBuffer.
local function fitIntoCanvasBB(img, W, H)
    local iw, ih = img:getWidth(), img:getHeight()
    local scale = math.min(W / iw, H / ih)
    local dw = math.max(1, math.floor(iw * scale + 0.5))
    local dh = math.max(1, math.floor(ih * scale + 0.5))
    local fitted = img
    if dw ~= iw or dh ~= ih then fitted = RenderImage:scaleBlitBuffer(img, dw, dh, false) end
    local bg = Blitbuffer.new(W, H, Blitbuffer.TYPE_BBRGB32)
    bg:fill(WHITE)
    bg:blitFrom(fitted, math.floor((W - dw) / 2), math.floor((H - dh) / 2), 0, 0, dw, dh)
    if fitted ~= img and fitted.free then fitted:free() end
    if img.free then img:free() end
    return bg
end

-- Build a copy of `src` with the flips and an arbitrary rotation baked in. A
-- quarter turn is an exact pixel permutation (lossless, swaps the dimensions);
-- any other angle is a nearest-neighbour resample into the rotated bounding box
-- (transparent corners). Returns the new buffer, or nil if pixels can't be read.
local function resampleOriented(src, angleDeg, fh, fv)
    local sw, sh = src:getWidth(), src:getHeight()
    local a = angleDeg % 360
    if a == 0 or a == 90 or a == 180 or a == 270 then
        local quarter = (a == 90 or a == 270)
        local dw = quarter and sh or sw
        local dh = quarter and sw or sh
        local dst = Blitbuffer.new(dw, dh, Blitbuffer.TYPE_BBRGB32)
        pcall(function() ffi.fill(dst.data, dst.stride * dst:getHeight(), 0) end)   -- true transparent (colour fill sets alpha opaque)
        local ok = pcall(function()
            for sy = 0, sh - 1 do
                local yy = fv and (sh - 1 - sy) or sy
                for sx = 0, sw - 1 do
                    local xx = fh and (sw - 1 - sx) or sx
                    local dx, dy
                    if a == 90 then dx, dy = sh - 1 - yy, xx
                    elseif a == 180 then dx, dy = sw - 1 - xx, sh - 1 - yy
                    elseif a == 270 then dx, dy = yy, sw - 1 - xx
                    else dx, dy = xx, yy end
                    dst:setPixel(dx, dy, src:getPixel(sx, sy))
                end
            end
        end)
        if not ok then if dst.free then dst:free() end; return nil end
        return dst
    end
    local ar = math.rad(a)
    local cosA, sinA = math.cos(ar), math.sin(ar)
    local bw = math.max(1, math.ceil(math.abs(sw * cosA) + math.abs(sh * sinA)))
    local bh = math.max(1, math.ceil(math.abs(sw * sinA) + math.abs(sh * cosA)))
    local dst = Blitbuffer.new(bw, bh, Blitbuffer.TYPE_BBRGB32)
    pcall(function() ffi.fill(dst.data, dst.stride * dst:getHeight(), 0) end)   -- true transparent (colour fill sets alpha opaque)
    local cxs, cys, cxd, cyd = sw / 2, sh / 2, bw / 2, bh / 2
    local ok = pcall(function()
        for dy = 0, bh - 1 do
            local ry = dy + 0.5 - cyd
            for dx = 0, bw - 1 do
                local rx = dx + 0.5 - cxd
                local ux = rx * cosA + ry * sinA + cxs   -- inverse rotate to source
                local uy = -rx * sinA + ry * cosA + cys
                if fh then ux = sw - ux end
                if fv then uy = sh - uy end
                local sxi = math.floor(ux)
                local syi = math.floor(uy)
                if sxi >= 0 and sxi < sw and syi >= 0 and syi < sh then
                    dst:setPixel(dx, dy, src:getPixel(sxi, syi))
                end
            end
        end
    end)
    if not ok then if dst.free then dst:free() end; return nil end
    return dst
end

ImageProc.bbToRGBA = bbToRGBA
ImageProc.bgRemovedRGBA = bgRemovedRGBA
ImageProc.fitIntoCanvasBB = fitIntoCanvasBB
ImageProc.resampleOriented = resampleOriented

return ImageProc
