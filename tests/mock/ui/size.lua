local Screen = require("device").screen
local function s(px) return Screen:scaleBySize(px) end
return {
    border  = { default = s(1), thin = s(1), thick = s(3), window = s(2) },
    padding = { default = s(5), large = s(10), small = s(3), button = s(2) },
    margin  = { default = s(5), small = s(2) },
    radius  = { window = s(8), default = s(4) },
    line    = { medium = s(2), thick = s(3) },
}
