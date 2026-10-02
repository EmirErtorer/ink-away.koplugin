local P = {}
P.__index = P
function P:new(o) o = o or {}; setmetatable(o, self); P.last = o; return o end
return P
