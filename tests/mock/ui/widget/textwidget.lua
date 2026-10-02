-- A tiny TextWidget stand-in: it reports a size derived from the label length so
-- the view's button layout has realistic metrics, and paints nothing (there are
-- no glyphs in the headless env). getSize/paintTo/free are all the view uses.
local TextWidget = {}
TextWidget.__index = TextWidget

function TextWidget:new(o)
    o = o or {}
    local text = tostring(o.text or "")
    o._w = math.max(1, #text * 10)
    o._h = 22
    return setmetatable(o, TextWidget)
end

function TextWidget:getSize() return { w = self._w, h = self._h } end
function TextWidget:paintTo(bb, x, y) end   -- no glyphs headless; nothing to draw
function TextWidget:setText(text)
    self.text = tostring(text or "")
    self._w = math.max(1, #self.text * 10)
end
function TextWidget:free() end

return TextWidget
