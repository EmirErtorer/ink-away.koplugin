local HG = {}
HG.__index = HG
function HG:new(o)
    o = o or {}
    return setmetatable(o, self)
end
function HG:getSize()
    local w, h = 0, 0
    for _, c in ipairs(self) do
        local s = c:getSize()
        w = w + s.w
        if s.h > h then h = s.h end
    end
    return { w = w, h = h }
end
function HG:paintTo(bb, x, y)
    local cx = x
    for _, c in ipairs(self) do
        c:paintTo(bb, cx, y)
        cx = cx + c:getSize().w
    end
end
return HG
