-- Minimal OverlapGroup mock: stacks children, positions them by overlap_offset,
-- and honours a passed-in dimen for its size.
local OG = {}
OG.__index = OG
function OG:new(o)
    o = o or {}
    return setmetatable(o, self)
end
function OG:getSize()
    if self.dimen and self.dimen.w then return { w = self.dimen.w, h = self.dimen.h } end
    local w, h = 0, 0
    for _, c in ipairs(self) do
        local s = c:getSize()
        if s.w > w then w = s.w end
        if s.h > h then h = s.h end
    end
    return { w = w, h = h }
end
function OG:paintTo(bb, x, y)
    local s = self:getSize()
    self.dimen = { x = x, y = y, w = s.w, h = s.h }
    for _, c in ipairs(self) do
        local ox = (c.overlap_offset and c.overlap_offset[1]) or 0
        local oy = (c.overlap_offset and c.overlap_offset[2]) or 0
        c:paintTo(bb, x + ox, y + oy)
    end
end
return OG
