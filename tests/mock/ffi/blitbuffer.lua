-- A small Blitbuffer stand in. It records paint and blit calls and counts any
-- writes that fall past the buffer edges, so the view tests can check that
-- nothing draws out of bounds.
local BB = {}
BB.__index = BB
local M = { out_of_bounds = 0, allocated = 0 }

local function color(v) return { v = v } end
function M.Color8(v) return color(v) end
function M.isColor8(c) return c ~= nil and c.v ~= nil end
M.COLOR_BLACK = color(0)
M.COLOR_WHITE = color(0xFF)
M.COLOR_GRAY  = color(0xAA)
M.COLOR_DARK_GRAY = color(0x55)
function M.ColorRGB32(r, g, b, a) return { r = r, g = g, b = b, alpha = a } end
function M.ColorRGB24(r, g, b) return { r = r, g = g, b = b } end
M.TYPE_BB8, M.TYPE_BBRGB32 = 1, 5

-- `data` (4th arg) means a NON-OWNING wrapper over existing memory (real FFI sets
-- allocated=0 for these), so it must not count toward the live-allocation tally used
-- by leak tests. Only owning buffers (no data) increment `allocated`. Owning buffers
-- still get a sentinel `.data` so a physical-view wrapper (physView, which passes
-- bb.data through) is correctly treated as NON-owning and never leaks.
function M.new(w, h, t, data, stride, pixel_stride)
    local owns = data == nil
    if owns then M.allocated = M.allocated + 1 end
    return setmetatable({
        w = w, h = h, t = t or 1, freed = false, paints = 0, _owns = owns,
        data = data or {}, stride = stride, pixel_stride = pixel_stride,
        rotation = 0, inverse = 0,
    }, BB)
end

function BB:getType() return self.t end
-- Rotation-aware, like the real thing: a quarter turn swaps the reported dims. The
-- stored w/h are the physical storage dims; a plain (rotation 0) buffer is unchanged.
function BB:getWidth()  return (self.rotation % 2 == 0) and self.w or self.h end
function BB:getHeight() return (self.rotation % 2 == 0) and self.h or self.w end
function BB:getRotation() return self.rotation end
function BB:setRotation(r) self.rotation = r % 4 end
function BB:getInverse() return self.inverse or 0 end
function BB:setInverse(i) self.inverse = i end
-- Map a logical rect to physical storage coordinates (same formula as real KOReader),
-- so the panel-order render path can be exercised headlessly.
function BB:getPhysicalRect(x, y, w, h)
    local r = self.rotation
    if r == 0 then return x, y, w, h
    elseif r == 1 then return self.w - (y + h), x, h, w
    elseif r == 2 then return self.w - (x + w), self.h - (y + h), w, h
    else return y, self.h - (x + w), h, w end
end
function BB:free() self.freed = true; if self._owns then M.allocated = M.allocated - 1 end end
-- A new owning buffer of the same size and type (the real one copies the pixels).
function BB:copy() return M.new(self.w, self.h, self.t) end

local function checkBounds(self, x, y, w, h)
    if x < 0 or y < 0 or x + (w or 1) > self.w or y + (h or 1) > self.h then
        M.out_of_bounds = M.out_of_bounds + 1
        if M.verbose then
            print(("  OOB paint %s,%s %sx%s in %sx%s"):format(x, y, w, h, self.w, self.h))
        end
    end
end

function BB:paintRect(x, y, w, h, c)
    self.paints = self.paints + 1
    checkBounds(self, x, y, w, h)
end

function BB:paintRoundedRect(x, y, w, h, c, r)
    self.paints = self.paints + 1
    checkBounds(self, x, y, w, h)
end
BB.paintRoundedRectRGB32 = BB.paintRoundedRect

function BB:paintBorder(x, y, w, h, bw, c, r)
    self.paints = self.paints + 1
    checkBounds(self, x, y, w, h)
end
BB.paintBorderRGB32 = BB.paintBorder

function BB:blitFrom(src, x, y, ox, oy, w, h)
    self.paints = self.paints + 1
    checkBounds(self, x, y, w, h)
end

-- Alpha-composited blit (placed images). Same bookkeeping as blitFrom here.
function BB:alphablitFrom(src, x, y, ox, oy, w, h)
    self.paints = self.paints + 1
    checkBounds(self, x, y, w, h)
end

-- The blends the see-through pens use (ink/wash.lua): bookkeeping only.
function BB:multiplyRectRGB(x, y, w, h, c)
    self.paints = self.paints + 1
    checkBounds(self, x, y, w, h)
end
function BB:colorblitFrom(src, x, y, ox, oy, w, h)
    self.paints = self.paints + 1
    checkBounds(self, x, y, w, h)
end
BB.colorblitFromRGB32 = BB.colorblitFrom

-- Flood the whole buffer with one colour; no bounds concern.
function BB:fill(c) self.paints = self.paints + 1 end

-- Per-pixel access (used by the image orientation transform). The mock does not
-- store pixel data, so getPixel returns a placeholder colour and setPixel only
-- bounds-checks; the geometry (sizes, permutation targets) is what tests assert.
function BB:getPixel(x, y) return M.ColorRGB32(0, 0, 0, 0xFF) end
function BB:setPixel(x, y, c) checkBounds(self, x, y, 1, 1) end

-- Zero-copy sub-view in the real thing; here just a sized stand-in.
function BB:viewport(x, y, w, h)
    -- Real KOReader returns a ZERO-COPY view sharing this buffer's memory (no
    -- allocation, nothing to free) whose STORAGE is the physical rect and which
    -- carries this buffer's rotation/inverse. Model that so leak tests are not
    -- fooled (non-owning) and the panel-order path lines up: a rotated buffer's
    -- viewport must itself be rotated.
    local px, py, pw, ph = self:getPhysicalRect(x, y, w, h)
    checkBounds(self, px, py, pw, ph)
    local vp = M.new(pw, ph, self.t, self.data)   -- data given => non-owning
    vp:setRotation(self.rotation)
    vp:setInverse(self.inverse)
    return vp
end

return M
