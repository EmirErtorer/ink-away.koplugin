local M = {}
M.__index = M
function M:new(o) return setmetatable(o or {}, self) end
return M
