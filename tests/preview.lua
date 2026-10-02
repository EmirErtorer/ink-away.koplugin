-- A preview for development. It builds a sample drawing, runs it through the
-- real export buffer builders in ink/export, and writes actual PNG files so you
-- can look at the transparent output on a computer. It has its own tiny PNG
-- encoder (zlib stored blocks) so it needs no native libraries, and it feeds
-- that encoder the very same RGBA byte buffer the lodepng path uses on a device.
--
--   luajit tests/preview.lua [out_dir]

package.path = "./?.lua;" .. package.path
local ffi = require("ffi")
local Canvas = require("ink/canvas")
local Export = require("ink/export")

local out_dir = arg[1] or "."

------------------------------------------------------------------------------
-- Minimal PNG encoder (RGBA n=4 or RGB n=3), zlib "stored" (uncompressed).
------------------------------------------------------------------------------
local bit = require("bit")
local bxor, band, rshift = bit.bxor, bit.band, bit.rshift

local function u32(n)
    return string.char(band(rshift(n, 24), 0xFF), band(rshift(n, 16), 0xFF),
                        band(rshift(n, 8), 0xFF), band(n, 0xFF))
end

-- CRC32
local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
    end
    crc_table[i] = c
end
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bxor(crc_table[band(bxor(c, s:byte(i)), 0xFF)], rshift(c, 8))
    end
    return bxor(c, 0xFFFFFFFF)
end

local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local function chunk(typ, data)
    return u32(#data) .. typ .. data .. u32(crc32(typ .. data))
end

-- zlib stream with stored (uncompressed) deflate blocks
local function zlib_store(raw)
    local parts = { string.char(0x78, 0x01) }  -- zlib header
    local pos, n = 1, #raw
    while pos <= n do
        local len = math.min(65535, n - pos + 1)
        local last = (pos + len - 1 >= n) and 1 or 0
        local nlen = 65535 - len
        parts[#parts + 1] = string.char(last,
            len % 256, math.floor(len / 256) % 256,
            nlen % 256, math.floor(nlen / 256) % 256)
        parts[#parts + 1] = raw:sub(pos, pos + len - 1)
        pos = pos + len
    end
    parts[#parts + 1] = u32(adler32(raw))
    return table.concat(parts)
end

local function write_png(path, buf, w, h, n)
    local color_type = (n == 4) and 6 or 2  -- 6=RGBA, 2=RGB
    -- raw scanlines with a 0 filter byte per row
    local rows = {}
    for y = 0, h - 1 do
        local row = { "\0" }
        local base = y * w * n
        local chars = {}
        for i = 0, w * n - 1 do chars[i + 1] = string.char(buf[base + i]) end
        row[2] = table.concat(chars)
        rows[#rows + 1] = table.concat(row)
    end
    local raw = table.concat(rows)
    local ihdr = u32(w) .. u32(h) .. string.char(8, color_type, 0, 0, 0)
    local png = "\137PNG\r\n\26\n"
        .. chunk("IHDR", ihdr)
        .. chunk("IDAT", zlib_store(raw))
        .. chunk("IEND", "")
    local f = assert(io.open(path, "wb"))
    f:write(png)
    f:close()
end

------------------------------------------------------------------------------
-- Sample drawing on a modest canvas.
------------------------------------------------------------------------------
local W, H = 480, 640
local c = Canvas.new(W, H)

local function stroke(kind, width, pts, alpha, color)
    c:startStroke(kind, width, alpha, color)
    for i = 1, #pts, 2 do c:addPoint(pts[i], pts[i + 1]) end
    c:finishStroke()
end

-- a rough smiley sketch
stroke("ink", 8, { 120, 200, 160, 210, 200, 205 })              -- left brow
stroke("ink", 8, { 280, 205, 320, 210, 360, 200 })              -- right brow
stroke("ink", 10, { 150, 300, 150, 360 })                       -- left eye
stroke("ink", 10, { 330, 300, 330, 360 })                       -- right eye
-- a smile as a polyline arc
local smile = {}
for t = 0, 1.0001, 0.05 do
    local x = 130 + t * 220
    local y = 430 + math.sin(t * math.pi) * 90
    smile[#smile + 1] = x
    smile[#smile + 1] = y
end
stroke("ink", 10, smile)
-- scribble then erase part of it
stroke("ink", 14, { 60, 560, 120, 545, 180, 565, 240, 545 })
stroke("erase", 30, { 120, 555, 180, 560 })
-- a faint 40%-opacity underline to show the pen opacity control
stroke("ink", 12, { 120, 150, 360, 150 }, math.floor(0.40 * 255 + 0.5))
-- colour + grey shades (colour shows on colour screens; grey on e-ink)
stroke("ink", 12, { 90, 110, 390, 110 }, 255, { 0xD0, 0x00, 0x00 })   -- red
stroke("ink", 12, { 90, 600, 390, 600 }, 255, { 0x00, 0x50, 0xD0 })   -- blue
stroke("ink", 16, { 260, 610, 300, 630 }, 255, { 0x88, 0x88, 0x88 })  -- grey

local rgba = Export.buildRGBA(c)
write_png(out_dir .. "/ink-away-preview-transparent.png", rgba, W, H, 4)
local rgb = Export.buildRGB(c)
write_png(out_dir .. "/ink-away-preview-white.png", rgb, W, H, 3)

-- report transparency stats
local clear, opaque = 0, 0
for i = 0, W * H - 1 do
    if rgba[i * 4 + 3] == 0 then clear = clear + 1 else opaque = opaque + 1 end
end
print(("wrote preview PNGs to %s (%dx%d)"):format(out_dir, W, H))
print(("transparent pixels: %d (%.1f%%), opaque ink: %d"):format(
    clear, 100 * clear / (W * H), opaque))
