local FC = {}
FC.__index = FC
function FC:new(o)
    o = o or {}
    o.padding = o.padding or 0
    return setmetatable(o, self)
end
function FC:getSize()
    local s = self[1]:getSize()
    return { w = s.w + 2 * self.padding, h = s.h + 2 * self.padding }
end
function FC:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.padding, y + self.padding)
end
return FC
