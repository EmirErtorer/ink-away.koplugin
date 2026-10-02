-- A tiny TextBoxWidget stand-in: it fills the given width and reports a wrapped
-- height derived from the text length, so the view's height-budget maths in the
-- pen/settings sheets have realistic metrics. Paints nothing (no glyphs headless).
local TextBoxWidget = {}
TextBoxWidget.__index = TextBoxWidget

function TextBoxWidget:new(o)
    o = o or {}
    local text = tostring(o.text or "")
    o._w = o.width or math.max(1, #text * 10)
    local per_line = math.max(1, math.floor(o._w / 10))
    local lines = math.max(1, math.ceil(#text / per_line))
    o._h = lines * 18
    return setmetatable(o, TextBoxWidget)
end

function TextBoxWidget:getSize() return { w = self._w, h = self._h } end
function TextBoxWidget:paintTo(bb, x, y) end
function TextBoxWidget:free() end

return TextBoxWidget
