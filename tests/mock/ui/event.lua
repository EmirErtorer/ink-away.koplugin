-- KOReader's Event, as far as the tests need it: a name and its arguments.
local Event = {}
Event.__index = Event
function Event:new(name, ...) return setmetatable({ name = name, args = { ... } }, self) end
return Event
