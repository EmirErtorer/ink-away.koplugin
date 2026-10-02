local D = {}
D.__index = D
function D:new(o) o = o or {}; setmetatable(o, self); D.last = o; return o end
function D:getInputText() return self.input end
function D:onShowKeyboard() end
return D
