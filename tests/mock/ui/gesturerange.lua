local GR = {}
GR.__index = GR
function GR:new(o) return setmetatable(o or {}, self) end
return GR
