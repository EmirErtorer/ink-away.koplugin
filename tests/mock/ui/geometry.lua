local Geom = {}
Geom.__index = Geom
function Geom:new(o) o = o or {}; return setmetatable(o, self) end
function Geom:copy() return Geom:new{ x=self.x, y=self.y, w=self.w, h=self.h } end
return Geom
