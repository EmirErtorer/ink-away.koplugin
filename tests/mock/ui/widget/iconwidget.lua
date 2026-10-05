-- Minimal IconWidget stub for the headless view tests. The real one resolves an
-- icon name to a file under the user/resource icon dirs, or takes a file directly;
-- here we only need construction, a size, a no-op paint, and free.
local IconWidget = {}
IconWidget.__index = IconWidget
function IconWidget:new(o)
    o = o or {}
    setmetatable(o, self)
    o.width = o.width or 24
    o.height = o.height or 24
    return o
end
function IconWidget:getSize() return { w = self.width, h = self.height } end
function IconWidget:paintTo(bb, x, y) end
function IconWidget:free() self.freed = true end
return IconWidget
