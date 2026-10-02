local Button = {}
Button.__index = Button
function Button:new(o)
    o = o or {}
    setmetatable(o, self)
    o.width = o.width or 40
    o._h = 40
    return o
end
function Button:setText(t, w) self.text = t; if w then self.width = w end end
function Button:getSize() return { w = self.width, h = self._h } end
function Button:paintTo(bb, x, y) bb:paintRect(x, y, self.width, self._h, { v = 0 }) end
return Button
