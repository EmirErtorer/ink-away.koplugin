local VS = {}
VS.__index = VS
function VS:new(o) o = o or {}; return setmetatable(o, self) end
function VS:getSize() return { w = 0, h = self.width or 0 } end
function VS:paintTo() end
return VS
