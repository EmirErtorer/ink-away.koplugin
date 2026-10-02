local VG = {}
VG.__index = VG
function VG:new(o) o = o or {}; return setmetatable(o, self) end
function VG:getSize()
    local w, h = 0, 0
    for _, c in ipairs(self) do local s = c:getSize(); if s.w > w then w = s.w end; h = h + s.h end
    return { w = w, h = h }
end
function VG:paintTo(bb, x, y)
    local cy = y
    for _, c in ipairs(self) do c:paintTo(bb, x, cy); cy = cy + c:getSize().h end
end
return VG
