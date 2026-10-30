-- KOReader's PathChooser, as far as the tests need it: it keeps its options, and
-- leaves a tap on a folder to the real one (here: unhandled).
local PathChooser = {}
PathChooser.__index = PathChooser
function PathChooser:new(o) return setmetatable(o, self) end
function PathChooser:onMenuSelect() return false end
return PathChooser
