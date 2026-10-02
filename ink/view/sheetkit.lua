--[[
Building blocks shared by the sheets: opening and closing them, title row,
buttons, icon tiles, colour swatches and brush samples (cached while the canvas
is open).
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
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Raster = require("ink/raster")
local IconMenu = require("ink/ui/iconmenu")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local LABEL = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF)   -- section headings
local HINT = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF)    -- explanations under a control
local TILE_BG = Paint.TILE_BG
local sameColor = Palette.sameColor
local uiFill = Paint.uiFill
local isChromatic = Paint.isChromatic

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

-- A cached image as a Button label. The cache owns the buffer, so the widget must
-- not free it, and fgcolor must be set: Button's tap highlight inverts
-- label_widget.fgcolor whenever `text` is set (ours is ""), and a nil one crashes.
local function imageLabel(bb, w, h)
    return ImageWidget:new{ image = bb, width = w, height = h,
        image_disposable = false, fgcolor = BLACK }
end

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

-- The width of a sheet's content: `cols` equal columns (four by default) and the
-- gaps between them, about 84% of the screen's short side. Returns the width, the
-- gap and the column width.
function InkAwayView:sheetWidth(cols)
    cols = cols or 4
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local col = math.floor((target - (cols - 1) * gap) / cols)
    return cols * col + (cols - 1) * gap, gap, col
end

-- Show a sheet (an IconMenu) and keep it in self[field] while it is open. It
-- hangs from the toolbar unless opts.bottom_y pins its bottom edge there;
-- opts.on_close runs when a tap outside it or Back closes it.
function InkAwayView:showSheet(field, build, opts)
    opts = opts or {}
    self[field] = IconMenu:new{ build = build,
        top_y = not opts.bottom_y and self:sheetTopY() or nil, bottom_y = opts.bottom_y,
        on_close = function()
            self[field] = nil
            if opts.on_close then opts.on_close() end
        end }
    UIManager:show(self[field])
end

-- Close the sheet kept in self[field], if one is open.
function InkAwayView:closeSheet(field)
    if self[field] then UIManager:close(self[field]); self[field] = nil end
end

-- Rebuild the sheet in self[field] in place. Returns false, after closing
-- whatever else the field holds, when there is no sheet to rebuild.
function InkAwayView:rebuildSheet(field)
    local sheet = self[field]
    if sheet and sheet.rebuild then sheet:rebuild(); return true end
    self:closeSheet(field)
    return false
end

-- Show `widget` in place of a Button's own label.
function InkAwayView:setButtonLabel(button, widget)
    if button.label_container then
        button.label_widget = widget; button.label_container[1] = widget
    end
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
    local b = Button:new{ icon = "inkaway." .. name, icon_width = size, icon_height = size,
        width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(16), background = sel and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    local iw = self:tileIcon(name, size, sel)
    if iw and label then
        local vg = VerticalGroup:new{ align = "center", iw, vspan(6),
            TextWidget:new{ text = label, face = Font:getFace("cfont", 15),
                bold = true, fgcolor = sel and WHITE or BLACK } }
        if sublabel then
            table.insert(vg, vspan(3))
            table.insert(vg, TextWidget:new{ text = sublabel, face = Font:getFace("cfont", 11),
                fgcolor = sel and Blitbuffer.ColorRGB32(0xC8, 0xC8, 0xC8, 0xFF) or HINT })
        end
        iw = vg
    end
    if iw then self:setButtonLabel(b, iw) end
    return b
end

-- Title row shared by every tool sheet: the sheet title on the left and a filled
-- black pill (Done / Back) on the right, spanning content_w.
function InkAwayView:sheetTitle(title, content_w, pill_label, pill_cb, title_size)
    local titleW = TextWidget:new{ text = title, face = Font:getFace("cfont", title_size or 22), bold = true }
    local pill = Button:new{ text = "", width = Screen:scaleBySize(84), height = Screen:scaleBySize(34),
        bordersize = 0, radius = Screen:scaleBySize(11), background = BLACK, margin = 0, padding = 0,
        callback = pill_cb, show_parent = self }
    self:setButtonLabel(pill, TextWidget:new{ text = pill_label or _("Done"), face = Font:getFace("cfont", 15),
        bold = true, fgcolor = WHITE })
    local g = content_w - titleW:getSize().w - pill:getSize().w
    return HorizontalGroup:new{ align = "center",
        titleW, HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), g) }, pill }
end

-- A small grey line of text in a sheet; a section heading when `bold`.
function InkAwayView:sheetLabel(text, bold)
    return TextWidget:new{ text = text, face = Font:getFace("cfont", 15), bold = bold, fgcolor = LABEL }
end

-- A grey explanation under a control, wrapped to `width`.
function InkAwayView:sheetHint(text, width, size)
    return TextBoxWidget:new{ text = text, width = width, face = Font:getFace("cfont", size or 13),
        fgcolor = HINT }
end

-- A full/any-width rounded action button (grey by default, black when `dark`).
function InkAwayView:actionButton(label, w, cb, dark, big)
    local b = Button:new{ text = "", width = w, height = Screen:scaleBySize(48), bordersize = 0,
        radius = Screen:scaleBySize(14), background = dark and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, show_parent = self }
    -- `big` marks a primary action (New drawing / New notebook): a larger bold
    -- face so it reads heavier than the ordinary buttons around it
    self:setButtonLabel(b, TextWidget:new{ text = label, face = Font:getFace("cfont", big and 20 or 17),
        bold = true, fgcolor = dark and WHITE or BLACK })
    return b
end

-- A row of equal buttons across `width`, one per { value, label } option, with
-- the current one filled black. A tap calls onpick(value).
function InkAwayView:segmentedRow(options, current, width, onpick)
    local gap = Screen:scaleBySize(12)
    local w = math.floor((width - (#options - 1) * gap) / #options)
    local row = HorizontalGroup:new{ align = "center" }
    for i, o in ipairs(options) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        table.insert(row, self:actionButton(o[2], w, function() onpick(o[1]) end, current == o[1]))
    end
    return row
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
        self:setButtonLabel(b, imageLabel(img_bb, w, h))
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
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(12), background = sel and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    -- render the sample wave into a bb sized to the inner tile
    local iw = w - Screen:scaleBySize(16)
    local ih = h - Screen:scaleBySize(16)
    local ok, wave = pcall(function() return self:cachedBrushWave(key, iw, ih, sel) end)
    if ok and wave then self:setButtonLabel(b, imageLabel(wave, iw, ih)) end
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
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:paintRect(0, 0, w, h, sel and BLACK or TILE_BG)
    Paint.brushSample(bb, st, sel and WHITE or BLACK,
        Screen:scaleBySize(6), math.max(3, Screen:scaleBySize(5)), 0.26, 36)
    return bb
end

-- Ask for a line of text in a stock InputDialog with Cancel and an OK button.
-- `o` holds title, input, hint, description, input_type, ok_text and on_ok(text),
-- plus optional on_cancel() and `default`, the text on_ok gets when the field is
-- left empty.
function InkAwayView:promptText(o)
    local dialog
    dialog = InputDialog:new{
        title = o.title, input = o.input, input_hint = o.hint, input_type = o.input_type,
        description = o.description,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                if o.on_cancel then o.on_cancel() end
            end },
            { text = o.ok_text, is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                if o.default and (not text or text == "") then text = o.default end
                o.on_ok(text)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Let the reader pick a file, starting in folder `path`.
function InkAwayView:pickFile(path, on_pick)
    UIManager:show(PathChooser:new{ select_directory = false, select_file = true, show_files = true,
        path = path, onConfirm = on_pick })
end

-- Let the reader pick a folder, starting in `path`.
function InkAwayView:pickFolder(path, on_pick)
    UIManager:show(PathChooser:new{ select_directory = true, select_file = false, show_files = true,
        path = path, onConfirm = on_pick })
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
