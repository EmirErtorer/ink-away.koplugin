--[[
Building blocks shared by the sheets: title row, buttons, icon tiles, colour
swatches and brush samples (cached while the canvas is open).
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Raster = require("ink/raster")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local TILE_BG = Paint.TILE_BG
local sameColor = Palette.sameColor
local uiFill = Paint.uiFill
local isChromatic = Paint.isChromatic

local InkAwayView = {}

-- One row of colour swatches. Each is a coloured button; the selected one gets
-- a thick border so it reads on any shade (a checkmark would vanish on a dark
-- swatch). `current` is the rgb to mark; `onpick(rgb)` is called on a tap.
function InkAwayView:swatchRowFor(entries, current, onpick)
    local sw = math.floor(math.min(self.screen_w, self.screen_h) * 0.9 / 6)
    local row = {}
    for _, e in ipairs(entries) do
        local selected = sameColor(current, e.rgb)
        row[#row + 1] = {
            text = "",
            background = uiFill(e.rgb),
            width = sw,
            bordersize = selected and Size.border.thick or Size.border.default,
            radius = 0,
            callback = function() onpick(e.rgb) end,
        }
    end
    return row
end

-- Where a tool sheet's top should sit: just under the toolbar, so its options
-- open right where the hand tapped (falls back to a small margin if unknown).
function InkAwayView:sheetTopY()
    return (self._bar_h or 0) + Screen:scaleBySize(6)
end

-- Shared tile helpers, used by both the Shapes menu and its line/arrow/curve
-- child menu so they look identical.
function InkAwayView:iconPath(name)
    return self:pluginDir() .. "ink/icons/" .. name .. ".svg"
end
-- Transparent icon (tile colour shows through) when unselected; white-flattened +
-- whole-rect inverted when selected so black strokes read white on the black tile.
function InkAwayView:tileIcon(name, size, sel)
    local ok, w = pcall(function()
        if sel then
            return IconWidget:new{ file = self:iconPath(name), width = size, height = size,
                alpha = false, invert = true }
        end
        return IconWidget:new{ file = self:iconPath(name), width = size, height = size, alpha = true }
    end)
    return ok and w or nil
end
-- A rounded tile button. Uses Button's native icon path (so `text` stays nil and
-- the tap-highlight takes the safe invert branch, not the text one which would
-- index a fgcolor our icon widget lacks), then swaps in a transparent icon,
-- optionally above a label and a small grey hint sublabel. `hold_cb` wires a
-- long-press action.
function InkAwayView:makeTile(name, w, h, size, sel, cb, label, sublabel, hold_cb)
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    local b = Button:new{ icon = "inkaway." .. name, icon_width = size, icon_height = size,
        width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(16), background = sel and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    local iw = self:tileIcon(name, size, sel)
    if iw and b.label_container then
        if label then
            local tw = TextWidget:new{ text = label, face = Font:getFace("cfont", 15),
                bold = true, fgcolor = sel and WHITE or BLACK }
            local vg = VerticalGroup:new{ align = "center", iw,
                VerticalSpan:new{ width = Screen:scaleBySize(6) }, tw }
            if sublabel then
                local hint = TextWidget:new{ text = sublabel, face = Font:getFace("cfont", 11),
                    fgcolor = sel and Blitbuffer.ColorRGB32(0xC8, 0xC8, 0xC8, 0xFF)
                                   or Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF) }
                table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(3) })
                table.insert(vg, hint)
            end
            b.label_widget = vg; b.label_container[1] = vg
        else
            b.label_widget = iw; b.label_container[1] = iw
        end
    end
    return b
end

-- Title row shared by every tool sheet: the sheet title on the left and a filled
-- black pill (Done / Back) on the right, spanning content_w.
function InkAwayView:sheetTitle(title, content_w, pill_label, pill_cb)
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    local titleW = TextWidget:new{ text = title, face = Font:getFace("cfont", 22), bold = true }
    local pill = Button:new{ text = "", width = Screen:scaleBySize(84), height = Screen:scaleBySize(34),
        bordersize = 0, radius = Screen:scaleBySize(11), background = BLACK, margin = 0, padding = 0,
        callback = pill_cb, show_parent = self }
    local ptw = TextWidget:new{ text = pill_label or _("Done"), face = Font:getFace("cfont", 15),
        bold = true, fgcolor = WHITE }
    if pill.label_container then pill.label_widget = ptw; pill.label_container[1] = ptw end
    local g = content_w - titleW:getSize().w - pill:getSize().w
    return HorizontalGroup:new{ align = "center",
        titleW, HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), g) }, pill }
end

-- A full/any-width rounded action button (grey by default, black when `dark`).
function InkAwayView:actionButton(label, w, cb, dark, big)
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    local b = Button:new{ text = "", width = w, height = Screen:scaleBySize(48), bordersize = 0,
        radius = Screen:scaleBySize(14), background = dark and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, show_parent = self }
    -- `big` marks a primary action (New drawing / New notebook): a larger bold
    -- face so it reads heavier than the ordinary buttons around it
    local tw = TextWidget:new{ text = label, face = Font:getFace("cfont", big and 20 or 17), bold = true,
        fgcolor = dark and WHITE or BLACK }
    if b.label_container then b.label_widget = tw; b.label_container[1] = tw end
    return b
end

-- A tappable rounded tile filled with `rgb`. A grey uses a Color8 fill (rounded in
-- C). A real colour cannot: KOReader rounds an RGB32 fill pixel by pixel in Lua,
-- which made the colour rows the slowest part of opening the pen menu on colour
-- screens. So the rounded colour tile is drawn once into an image (white corners,
-- like the sheet) and reused for every later opening and repaint.
function InkAwayView:colourTileButton(rgb, w, h, radius, cb, hold_cb)
    local fill = uiFill(rgb)
    if not isChromatic(fill) then
        return Button:new{ text = "", width = w, height = h, background = fill,
            radius = radius, bordersize = 0, margin = 0, padding = 0,
            callback = cb, hold_callback = hold_cb, show_parent = self }
    end
    -- white Color8 frame behind the image: the tap highlight inverts it (a nil
    -- background would crash the highlight)
    local b = Button:new{ text = "", width = w, height = h, background = WHITE,
        radius = radius, bordersize = 0, margin = 0, padding = 0,
        callback = cb, hold_callback = hold_cb, show_parent = self }
    local ok, img_bb = pcall(function() return self:cachedColourTile(rgb, w, h, radius) end)
    if ok and img_bb and b.label_container then
        local img = ImageWidget:new{ image = img_bb, width = w, height = h,
            image_disposable = false, fgcolor = Blitbuffer.COLOR_BLACK }
        b.label_widget = img; b.label_container[1] = img
    else
        b.frame.background = fill   -- fall back to the plain (slow) colour fill
    end
    return b
end

function InkAwayView:cachedColourTile(rgb, w, h, radius)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local id = table.concat({ "tile", rgb[1], rgb[2], rgb[3], w, h, radius, Screen.bb:getType() }, "|")
    local e = cache[id]
    if e then return e.bb end
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:paintRect(0, 0, w, h, WHITE)
    bb:paintRoundedRectRGB32(0, 0, w, h, Blitbuffer.ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF), radius)
    cache[id] = { bb = bb }
    return bb
end

-- A colour swatch tile: a colour-filled rounded square with a thin black border
-- (thicker when selected, so white/light swatches stay visible). Optional
-- hold_cb for deleting a saved custom colour.
function InkAwayView:swatchTile(rgb, selected, w, cb, hold_cb, h)
    local BLACK = Blitbuffer.COLOR_BLACK
    local inner = w - Screen:scaleBySize(8)
    local inner_h = (h or w) - Screen:scaleBySize(8)
    local btn = self:colourTileButton(rgb, inner, inner_h, Screen:scaleBySize(11), cb, hold_cb)
    return FrameContainer:new{
        bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
        color = BLACK, radius = Screen:scaleBySize(14),
        padding = selected and Screen:scaleBySize(1) or Screen:scaleBySize(3),
        margin = 0, btn }
end

-- A brush-style tile: a small rounded rectangle showing a sample wave rendered
-- through the same rasterizer the pen uses, so it previews how the brush looks.
function InkAwayView:brushWaveTile(key, w, h, sel, cb, hold_cb)
    local BLACK = Blitbuffer.COLOR_BLACK
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(12), background = sel and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    -- render the sample wave into a bb sized to the inner tile
    local iw = w - Screen:scaleBySize(16)
    local ih = h - Screen:scaleBySize(16)
    local ok, wave = pcall(function() return self:cachedBrushWave(key, iw, ih, sel) end)
    if ok and wave and b.label_container then
        -- `fgcolor` is unused by ImageWidget, but Button's tap-highlight inverts
        -- `label_widget.fgcolor` whenever `text` is set (ours is ""), so it must be
        -- a real colour or the highlight crashes indexing a nil field. The sample
        -- belongs to the view's cache, so the widget must not free it.
        local img = ImageWidget:new{ image = wave, width = iw, height = ih,
            image_disposable = false, fgcolor = Blitbuffer.COLOR_BLACK }
        b.label_widget = img; b.label_container[1] = img
    end
    return b
end

-- The brush samples never change while the canvas is open (a textured one costs a
-- few ms to rasterize), so the pen menu reuses them instead of redrawing every one
-- on each opening. Keyed by style table, so an edited custom brush redraws.
function InkAwayView:cachedBrushWave(key, w, h, sel)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local st = Raster.STYLES[key] or Raster.STYLES.solid
    local id = table.concat({ key, w, h, sel and 1 or 0, Screen.bb:getType() }, "|")
    local e = cache[id]
    if e and e.st == st then return e.bb end
    if e then e.bb:free() end
    local bb = self:renderBrushWave(key, w, h, sel)
    cache[id] = { bb = bb, st = st }
    return bb
end

function InkAwayView:freeWaveCache()
    if self._wave_cache then
        for _, e in pairs(self._wave_cache) do e.bb:free() end
        self._wave_cache = nil
    end
end

-- Render a sample stroke for brush `key` into a fresh blitbuffer. White wave on a
-- dark tile when selected, black on grey else.
function InkAwayView:renderBrushWave(key, w, h, sel)
    local st = Raster.STYLES[key] or Raster.STYLES.solid
    local bg = sel and Blitbuffer.COLOR_BLACK or TILE_BG
    local ink = sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:paintRect(0, 0, w, h, bg)
    local pad = Screen:scaleBySize(6)
    local function put(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len > 0 then bb:paintRect(x, y, len, 1, ink) end
    end
    local pts, n = {}, 36
    for i = 0, n do
        local u = i / n
        pts[#pts + 1] = pad + u * (w - pad * 2)
        pts[#pts + 1] = h / 2 + math.sin(u * math.pi * 2) * (h * 0.26)
    end
    local r = math.max(3, Screen:scaleBySize(5))
    if st.solid then Raster.path(pts, r, put) else Raster.pathTex(pts, r, put, st, 12345) end
    return bb
end

-- A short, non-blocking message.
function InkAwayView:showNotice(text)
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and Notification then
        UIManager:show(Notification:new{ text = text })
    else
        UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
    end
end

return InkAwayView
