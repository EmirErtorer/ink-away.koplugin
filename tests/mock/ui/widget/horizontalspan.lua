local HS = {}
HS.__index = HS
function HS:new(o) o = o or {}; return setmetatable(o, self) end
function HS:getSize() return { w = self.width or 0, h = 0 } end
function HS:paintTo() end
return HS
