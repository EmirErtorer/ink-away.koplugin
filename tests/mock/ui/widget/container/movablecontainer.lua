-- KOReader's MovableContainer as far as the tests need it: where a drag moved
-- it (an offset from where it is painted), and its painted dimen.
local MC = { _moved_offset_x = 0, _moved_offset_y = 0 }
MC.__index = MC
function MC:new(o) o = o or {}; return setmetatable(o, self) end
function MC:getSize() return (self[1] and self[1]:getSize()) or { w = 0, h = 0 } end
function MC:getMovedOffset() return { x = self._moved_offset_x, y = self._moved_offset_y } end
function MC:setMovedOffset(p)
    if p then self._moved_offset_x, self._moved_offset_y = p.x, p.y end
end
function MC:paintTo(bb, x, y)
    local s = self:getSize()
    x, y = x + self._moved_offset_x, y + self._moved_offset_y
    self.dimen = require("ui/geometry"):new{ x = x, y = y, w = s.w, h = s.h }
    if self[1] then self[1]:paintTo(bb, x, y) end
end
return MC
