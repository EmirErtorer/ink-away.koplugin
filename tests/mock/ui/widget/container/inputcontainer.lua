local IC = {}
function IC:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
function IC:new(o)
    o = self:extend(o)
    if not o.ges_events then o.ges_events = {} end
    if not o.key_events then o.key_events = {} end
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
return IC
