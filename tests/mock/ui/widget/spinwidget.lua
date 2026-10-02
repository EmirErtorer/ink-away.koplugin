local S = {}
S.__index = S
function S:new(o) o = o or {}; setmetatable(o, self); S.last = o; return o end
return S
