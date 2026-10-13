--[[
The cover sheet of a notebook on a Bookshelf shelf (ink/bookshelf.lua): its
six cover styles as previews of its own cover, the one in use framed, and a
second grid for the colour of the cover's coloured part (its tab colour, the
swatches, or any colour on the colour wheel). Opened by a long press on the
shelf, from a notebook's menu in Ink Away's library, and, for the style every
notebook gets unless given its own, from Ink Away's settings.

Previews share the notebook's first page, drawn once for the sheet and freed
when it closes, so the sheet leaves nothing behind.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Cover = require("ink/notebookcover")
local Palette = require("ink/palette")
local Shelf = require("ink/bookshelf")
local Storage = require("ink/storage")

local CoverPicker = {}

-- Does this screen show colour (the emulator can be told to act grey)?
local function colourScreen()
    if Device.isEmulator and Device:isEmulator() and os.getenv("INKAWAY_FORCE_MONO") then return false end
    return (Device.hasColorScreen and Device:hasColorScreen()) and true or false
end

-- The colours offered for a cover's coloured part: on a colour screen the
-- cover colours and the swatches, on a grey one the greys.
local function swatches()
    local out = {}
    if colourScreen() then
        local names = { _("Navy"), _("Forest"), _("Wine"), _("Charcoal"), _("Plum"), _("Teal") }
        for i, c in ipairs(Cover.BOARDS) do out[#out + 1] = { label = names[i], rgb = c } end
        for _, c in ipairs(Palette.COLORS) do out[#out + 1] = { label = c.name, rgb = c.rgb } end
        out[#out + 1] = { label = Palette.SHADES[1].name, rgb = Palette.SHADES[1].rgb }
    else
        for i = 1, 4 do out[#out + 1] = { label = Palette.SHADES[i].name, rgb = Palette.SHADES[i].rgb } end
    end
    return out
end

-- Draw a cover preview to fit `maxw` x `maxh`. `look` as for Cover.render.
local function preview(path, look, maxw, maxh)
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(Cover.render, path, look)
    if not (ok and bb) then return nil end
    local s = math.min(maxw / Cover.W, maxh / Cover.H)
    return RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(Cover.W * s)),
        math.max(1, math.floor(Cover.H * s)), true)
end

-- The style grid. `o`: path (the notebook), view (an open Ink Away view, to
-- draw its page with text and pictures), open (opens the notebook; shown as
-- a button when given), on_change, and default (true: choose the style every
-- notebook gets, previewed on this notebook).
function CoverPicker.show(o)
    local ThumbGrid = require("ink/ui/thumbgrid")
    local path = o.path
    local nb = path and Cover.load(path)
    if not nb then return end
    local pages = {}   -- the first page, drawn once for every preview
    local look = Shelf.lookOf(path)
    local names = Cover.names()
    local grid
    local function current() return o.default and Shelf.defaultStyle() or look.style end
    local function items()
        local list = {}
        for _, s in ipairs(Cover.STYLES) do
            list[#list + 1] = { label = names[s], style = s, selected = s == current() }
        end
        return list
    end
    local function changed()
        look = Shelf.lookOf(path)
        grid:setItems(items())
        if o.on_change then o.on_change() end
    end
    local actions = {}
    if not o.default then
        actions[#actions + 1] = { _("Colour"), function() CoverPicker.colour(path, nb, pages, o.view, changed) end }
        actions[#actions + 1] = { _("Use for all"), function()
            Shelf.setDefaultStyle(look.style)
            Shelf.setLook(path, false)
            Shelf.defaultChanged()
            changed()
        end }
        if o.open then
            actions[#actions + 1] = { _("Open"), function() grid:close(); o.open() end, true }
        end
    end
    grid = ThumbGrid:new{
        title = o.default and _("Covers on Bookshelf") or Storage.stem(path),
        items = items(),
        cols = 3, rows = 2,
        flash_open = false,
        actions = actions,
        render = function(it, maxw, maxh)
            return preview(path, { style = it.style, colour = look.colour, nb = nb, pages = pages,
                view = o.view }, maxw, maxh)
        end,
        on_pick = function(it)
            if o.default then
                Shelf.setDefaultStyle(it.style)
                Shelf.defaultChanged()
            else
                Shelf.setLook(path, it.style)
                Shelf.lookChanged(path, o.view)
            end
            changed()
        end,
        on_close = function() Cover.freePages(pages) end,
    }
    UIManager:show(grid)
    return grid
end

-- The colour grid for notebook `path` (loaded as `nb`, its first page shared
-- in `pages`): its tab colour (or the automatic one), the swatches and, on a
-- colour screen, the colour wheel; each previewed on its cover.
function CoverPicker.colour(path, nb, pages, view, on_change)
    local ThumbGrid = require("ink/ui/thumbgrid")
    local look = Shelf.lookOf(path)
    local grid
    local function items()
        local list = { { label = look.tab and _("Tab colour") or _("Automatic"), follow = true,
            rgb = look.tab or Cover.boardOf(path), selected = not look.own_colour } }
        for _, c in ipairs(swatches()) do
            list[#list + 1] = { label = c.label, rgb = c.rgb,
                selected = look.own_colour and Palette.sameColor(c.rgb, look.colour) or false }
        end
        if colourScreen() then
            list[#list + 1] = { label = _("Colour wheel"), wheel = true, rgb = look.colour }
        end
        return list
    end
    local function use(rgb)
        Shelf.setLook(path, nil, rgb or false)
        Shelf.lookChanged(path, view)
        look = Shelf.lookOf(path)
        grid:setItems(items())
        if on_change then on_change() end
    end
    grid = ThumbGrid:new{
        title = _("Cover colour"),
        items = items(),
        cols = 4, rows = 3,
        flash_open = false,
        close_label = _("Done"),
        render = function(it, maxw, maxh)
            return preview(path, { style = look.style, colour = it.rgb, nb = nb, pages = pages, view = view },
                maxw, maxh)
        end,
        on_pick = function(it)
            if it.follow then return use(nil) end
            if not it.wheel then return use(it.rgb) end
            local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
            if not ok then return end
            UIManager:show(ColorPicker:new{
                title = _("Cover colour"),
                color = look.colour,
                on_pick = function(rgb) use(rgb) end,
            })
        end,
    }
    UIManager:show(grid)
    return grid
end

-- The style every notebook gets unless given its own, previewed on the
-- notebook at `sample` (the newest in the library).
function CoverPicker.showDefault(sample, on_change)
    return CoverPicker.show{ path = sample, default = true, on_change = on_change }
end

return CoverPicker
