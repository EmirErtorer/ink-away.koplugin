local CC = {}
CC.__index = CC
function CC:new(o) o = o or {}; return setmetatable(o, self) end
function CC:getSize() return self.dimen or (self[1] and self[1]:getSize()) or { w = 0, h = 0 } end
function CC:paintTo(bb, x, y) if self[1] then self[1]:paintTo(bb, x, y) end end
return CC
