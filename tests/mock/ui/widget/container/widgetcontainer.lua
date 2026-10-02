local W = {}
function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
function W:new(o)
    o = self:extend(o)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
function W:getSize() return self.dimen or { w = 0, h = 0 } end
function W:paintTo(bb, x, y) if self[1] and self[1].paintTo then self[1]:paintTo(bb, x, y) end end
return W
