-- KOReader's TextViewer: keeps its options (title, text) for a test to read.
local V = {}
V.__index = V
function V:new(o) o = o or {}; setmetatable(o, self); V.last = o; return o end
return V
