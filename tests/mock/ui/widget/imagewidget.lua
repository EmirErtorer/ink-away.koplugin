-- Minimal ImageWidget stub for the headless view tests: construction, a size
-- and a no-op paint.
local ImageWidget = {}
ImageWidget.__index = ImageWidget
function ImageWidget:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end
function ImageWidget:getSize() return { w = self.width or 0, h = self.height or 0 } end
function ImageWidget:paintTo(bb, x, y) end
function ImageWidget:free() end
return ImageWidget
