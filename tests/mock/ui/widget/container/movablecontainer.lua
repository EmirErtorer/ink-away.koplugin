local MC = {}
MC.__index = MC
function MC:new(o) o = o or {}; return setmetatable(o, self) end
function MC:getSize() return (self[1] and self[1]:getSize()) or { w = 0, h = 0 } end
function MC:paintTo(bb, x, y)
    local s = self:getSize()
    self.dimen = { x = x, y = y, w = s.w, h = s.h }
    if self[1] then self[1]:paintTo(bb, x, y) end
end
return MC
