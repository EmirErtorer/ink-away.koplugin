local Geom = {}
Geom.__index = Geom
function Geom:new(o) o = o or {}; return setmetatable(o, self) end
function Geom:copy() return Geom:new{ x=self.x, y=self.y, w=self.w, h=self.h } end
function Geom:combine(o)
    local x0, y0 = math.min(self.x, o.x), math.min(self.y, o.y)
    local x1, y1 = math.max(self.x + self.w, o.x + o.w), math.max(self.y + self.h, o.y + o.h)
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end
return Geom
