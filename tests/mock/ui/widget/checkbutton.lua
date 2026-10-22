local CheckButton = {}
CheckButton.__index = CheckButton
function CheckButton:new(o) return setmetatable(o, self) end
function CheckButton:getSize() return { w = self.width, h = 40 } end
function CheckButton:paintTo() end
function CheckButton:onTapCheckButton()
    self.checked = not self.checked
    if self.callback then self.callback() end
end
return CheckButton
