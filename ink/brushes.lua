--[[
The brush list: the built-in styles plus the brushes the reader makes.

A brush is the small table of numbers the rasterizer reads (see ink/raster.lua).
Made brushes are kept in KOReader's settings, outside the plugin folder, so they
survive plugin updates, and each is registered at startup under "user:<name>",
so a project or an export finds the style its strokes name.
]]

local Raster = require("ink/raster")

local Brushes = {}

local SETTING = "inkaway_brushes"

-- The built-in styles, in pen menu order.
local BUILTIN = {
    { key = "solid",   label = "Ink" },
    { key = "pencil",  label = "Pencil" },
    { key = "acrylic", label = "Acrylic" },
    { key = "hatch",   label = "Hatch" },
    { key = "stipple", label = "Stipple" },
}

-- The brush maker's sliders, each 0..1 unless noted, and how they map onto the
-- rasterizer's fields. The ranges are modest because a large spread or tooth
-- makes each stamp scan many more pixels.
Brushes.FIELDS = {
    { id = "density",  label = "Ink",       min = 0.2,  max = 1.0 },
    { id = "cell",     label = "Grain",     min = 1,    max = 4,  step = 1 },
    { id = "edge",     label = "Soft edge", min = 0.0,  max = 0.9 },
    { id = "grow",     label = "Spread",    min = 0.0,  max = 0.35 },
    { id = "tooth",    label = "Tooth",     min = 0,    max = 4,  step = 1 },
}

-- The starting values for a new brush.
function Brushes.defaults()
    return { density = 0.8, cell = 2, edge = 0.3, grow = 0.1, tooth = 0 }
end

-- The saved brushes, a list of { name, params }; never nil.
function Brushes.userList(getSetting)
    local list = getSetting(SETTING)
    if type(list) ~= "table" then return {} end
    return list
end

-- Register every saved brush with the rasterizer; called once at startup.
function Brushes.loadAll(getSetting)
    for _, b in ipairs(Brushes.userList(getSetting)) do
        if b.name and b.params then Raster.registerStyle("user:" .. b.name, b.params) end
    end
end

-- The pen menu's list: the built-in styles, then the made brushes, each as
-- { key, label, custom }.
function Brushes.menu(getSetting)
    local out = {}
    for _, b in ipairs(BUILTIN) do out[#out + 1] = { key = b.key, label = b.label } end
    for _, b in ipairs(Brushes.userList(getSetting)) do
        if b.name then out[#out + 1] = { key = "user:" .. b.name, label = b.name, custom = true } end
    end
    return out
end

-- Save a brush by name (adding it, or replacing one of the same name), register
-- it and store the list. Returns the style key.
function Brushes.save(getSetting, setSetting, name, params)
    local list = Brushes.userList(getSetting)
    local entry = { name = name, params = params }
    local replaced = false
    for i, b in ipairs(list) do
        if b.name == name then list[i] = entry; replaced = true; break end
    end
    if not replaced then list[#list + 1] = entry end
    setSetting(SETTING, list)
    Raster.registerStyle("user:" .. name, params)
    return "user:" .. name
end

-- Remove a brush by name and store the list. Returns true if one was removed.
function Brushes.remove(getSetting, setSetting, name)
    local list = Brushes.userList(getSetting)
    for i, b in ipairs(list) do
        if b.name == name then
            table.remove(list, i)
            setSetting(SETTING, list)
            Raster.STYLES["user:" .. name] = nil
            return true
        end
    end
    return false
end

return Brushes
