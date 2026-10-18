-- A text field: keeps its text; the last one made is InputText.last, so a test
-- can type into it and press Enter (enter_callback), as on the keyboard.
local T = {}
T.__index = T
function T:new(o) o = o or {}; setmetatable(o, self); o.text = o.text or ""; T.last = o; return o end
function T:getText() return self.text end
function T:setText(t) self.text = t end
function T:getSize() return { w = self.width or 100, h = 40 } end
function T:paintTo() end
function T:onShowKeyboard() self.keyboard_shown = true end
function T:onCloseKeyboard() self.keyboard_shown = false end
function T:onCloseWidget() self.closed = true end
return T
