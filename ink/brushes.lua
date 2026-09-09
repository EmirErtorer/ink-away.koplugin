--[[
The brush list: the built in styles plus any brushes the reader makes themselves.

A brush is just the small table of numbers the rasterizer reads (density, grain
size, edge fade and so on, see ink/raster.lua). Built in brushes live in
Raster.STYLES; user brushes are kept in KOReader's global settings, which sit
outside the plugin folder, so a made brush survives both a restart and a plugin
update. On startup every saved brush is registered back into the rasterizer under
the key "user:<name>", so a project or an export always finds the style a stroke
was drawn with, even if the brush is later changed.
]]

local Raster = require("ink/raster")

local Brushes = {}

local SETTING = "inkaway_brushes"

-- Built in styles, in the order they appear in the pen menu.
local BUILTIN = {
    { key = "solid",   label = "Ink" },
    { key = "pencil",  label = "Pencil" },
    { key = "acrylic", label = "Acrylic" },
    { key = "hatch",   label = "Hatch" },
    { key = "stipple", label = "Stipple" },
}

-- The sliders a brush is built from, each 0..1 unless noted, with how they map
-- onto the rasterizer's fields. This is the whole vocabulary of the brush maker.
-- Ranges are kept modest on purpose: large spread/tooth make a brush scan many
-- more pixels per stamp, so capping them keeps a made brush about as quick as a
-- built in one.
Brushes.FIELDS = {
    { id = "density",  label = "Ink",       min = 0.2,  max = 1.0 },
    { id = "cell",     label = "Grain",     min = 1,    max = 4,  step = 1 },
    { id = "edge",     label = "Soft edge", min = 0.0,  max = 0.9 },
    { id = "grow",     label = "Spread",    min = 0.0,  max = 0.35 },
    { id = "tooth",    label = "Tooth",     min = 0,    max = 4,  step = 1 },
}

-- A sensible starting point for a brand new brush.
function Brushes.defaults()
    return { density = 0.8, cell = 2, edge = 0.3, grow = 0.1, tooth = 0 }
end

-- Read the saved user-brush list (array of { name, params }). Never nil.
function Brushes.userList(getSetting)
    local list = getSetting(SETTING)
    if type(list) ~= "table" then return {} end
    return list
end

-- Register every saved user brush with the rasterizer. Call once on startup.
function Brushes.loadAll(getSetting)
    for _, b in ipairs(Brushes.userList(getSetting)) do
        if b.name and b.params then Raster.registerStyle("user:" .. b.name, b.params) end
    end
end

-- The full menu list: built in styles first, then user brushes. Each entry is
-- { key, label, custom }.
function Brushes.menu(getSetting)
    local out = {}
    for _, b in ipairs(BUILTIN) do out[#out + 1] = { key = b.key, label = b.label } end
    for _, b in ipairs(Brushes.userList(getSetting)) do
        if b.name then out[#out + 1] = { key = "user:" .. b.name, label = b.name, custom = true } end
    end
    return out
end

-- Save a user brush by name (adding, or replacing one with the same name),
-- register it, and persist the list. Returns the style key.
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

-- Remove a user brush by name and persist. Returns true if one was removed.
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
