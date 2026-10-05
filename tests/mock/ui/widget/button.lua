local Button = {}
Button.__index = Button
-- Like KOReader's Button, the label lives in label_container[1] (callers swap
-- it), and a text button's tap highlight inverts label_widget.fgcolor.
function Button:new(o)
    o = o or {}
    setmetatable(o, self)
    o.width = o.width or 40
    o._h = 40
    o.label_widget = { fgcolor = o.text and { v = 0 } or nil }
    o.label_container = { o.label_widget }
    return o
end
function Button:setText(t, w) self.text = t; if w then self.width = w end end
function Button:getSize() return { w = self.width, h = self._h } end
function Button:paintTo(bb, x, y) bb:paintRect(x, y, self.width, self._h, { v = 0 }) end
-- Would the real tap highlight work? A text button's label needs an fgcolor to
-- invert, or KOReader crashes on the tap.
function Button:highlightSafe()
    return not self.text or (self.label_widget ~= nil and self.label_widget.fgcolor ~= nil)
end
return Button
