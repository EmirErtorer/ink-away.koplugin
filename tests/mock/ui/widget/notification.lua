-- KOReader's short notice at the top of the screen: shown, then gone by itself.
local N = {}
N.__index = N
function N:new(o) o = o or {}; o.toast = true; setmetatable(o, self); N.last = o; return o end
return N
