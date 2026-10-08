--[[
The pen case: the Pen sheet. From the top: the reader's saved pens, drawn at
their real size and colour (a tap takes one up, a hold edits it); the pen in
hand drawn at its real size on screen, which follows the size slider; its size
in mm and its opacity; its colour; the kinds of pen; and, for pens that change
width with pressure, how. Palm rejection, the stabilizer and the other input
settings, which are set once and not per pen, are in "Pen and input".
What is kept, and how each kind of pen remembers its settings: ink/penset.lua.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Brushes = require("ink/brushes")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local PenSample = require("ink/ui/pensample")
local Pens = require("ink/pens")
local Penset = require("ink/penset")
local Raster = require("ink/raster")
local SliderRow = require("ink/ui/controls").SliderRow
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local HAIRLINE = Paint.HAIRLINE
local TILE_BG = Paint.TILE_BG
local LABEL = Blitbuffer.Color8(0x55)
local SHADES = Palette.SHADES
local COLORS = Palette.COLORS
local sameColor = Palette.sameColor

local PEN_CUSTOM_CAP = 12   -- how many made brushes a reader may keep

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

------------------------------------------------------------------------------
-- The pen in hand, and keeping it
------------------------------------------------------------------------------

-- Canvas pixels per mm on this screen.
function InkAwayView:pxPerMM()
    local dpi = Screen.getDPI and Screen:getDPI() or 300
    return (dpi or 300) / 25.4
end

-- The pen case, loaded from the settings the first time it is needed.
function InkAwayView:penset()
    if not self._penset then
        self._penset = Penset.load(function(k) return self:getSetting(k) end,
            { colour = self:colorScreen(), pxmm = self:pxPerMM() },
            function(style) return Raster.STYLES[style] ~= nil end)
    end
    return self._penset
end

-- Take up a pen: the drawing uses its style, width, opacity and colour.
function InkAwayView:applyPen(p)
    self.pen_style = (p.style and Raster.STYLES[p.style]) and p.style or "solid"
    self.pen_width = p.width or self.pen_width
    self.pen_alpha = p.alpha or 255
    self.pen_color = p.color and { p.color[1], p.color[2], p.color[3] } or { 0, 0, 0 }
end

-- Keep the pen case after a change.
function InkAwayView:savePens()
    Penset.save(self:penset(), function(k, v) self:setSetting(k, v) end)
    self:setSetting("inkaway_pen_style", self.pen_style)   -- for 4.0 and older, if ever opened again
end

-- The pen in hand changed one setting (field: width, alpha or color).
function InkAwayView:penChanged(field, value)
    Penset.set(self:penset(), field, value)
    self:savePens()
end

function InkAwayView:usePen(p)
    self:applyPen(Penset.use(self:penset(), p))
    self:savePens()
end

function InkAwayView:choosePenType(style)
    self:applyPen(Penset.choose(self:penset(), style))
    self:savePens()
end

-- Back to the pen before this one (a gesture or pen button can do this).
function InkAwayView:swapPen()
    local p = Penset.swap(self:penset())
    if not p then return false end
    self:applyPen(p)
    self:savePens()
    if self.tool ~= "pen" then self:setTool("pen") end
    return true
end

------------------------------------------------------------------------------
-- Tiles
------------------------------------------------------------------------------

-- A cached sample of a pen, w x h, drawn at `width` px.
function InkAwayView:cachedPenSample(p, w, h, width)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local c = p.color or { 0, 0, 0 }
    local id = table.concat({ "pen", p.style, width, p.alpha or 255, c[1], c[2], c[3], w, h,
        Screen.bb:getType() }, "|")
    local e = cache[id]
    if e then return e.bb end
    local ok, bb = pcall(PenSample.render, p, w, h, width)
    if not ok then return nil end
    cache[id] = { bb = bb }
    return bb
end

-- A rounded frame around `inner`: thick and black when selected, as the colour
-- swatches are (a colour border would be drawn grey by KOReader's frame).
local function frame(inner, selected)
    return FrameContainer:new{
        bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
        color = selected and BLACK or HAIRLINE,
        radius = Screen:scaleBySize(12), padding = selected and 0 or Screen:scaleBySize(2),
        margin = 0, background = WHITE, inner }
end

-- A tile showing `bb` (owned by the cache), tappable.
function InkAwayView:imageTile(bb, w, h, cb, hold_cb)
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0, radius = Screen:scaleBySize(10),
        background = WHITE, margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    if bb then
        self:setButtonLabel(b, ImageWidget:new{ image = bb, width = w, height = h,
            image_disposable = false, fgcolor = BLACK })
    end
    return b
end

-- A small label under a tile.
local function caption(text, w)
    local t = TextWidget:new{ text = text, face = Font:getFace("cfont", 13), fgcolor = LABEL, max_width = w }
    return CenterContainer:new{ dimen = GeomUI:new{ w = w, h = t:getSize().h }, t }
end

-- Tiles laid out `per` to a row, `gap` apart.
local function rows(list, per, gap)
    local out = VerticalGroup:new{ align = "left" }
    for i = 1, #list, per do
        local row = HorizontalGroup:new{ align = "top" }
        for j = i, math.min(i + per - 1, #list) do
            if j > i then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, list[j])
        end
        if i > 1 then table.insert(out, VerticalSpan:new{ width = gap }) end
        table.insert(out, row)
    end
    return out
end

-- The pen in hand on a strip of paper, at its real width on screen. Updated in
-- place while the size or opacity slider moves; a tap opens the kinds of pen.
local Strip = InputContainer:extend{ w = 0, h = 0, bb = nil, on_tap = nil }
function Strip:init()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.w, h = self.h }
    if Device:isTouchDevice() then
        self.ges_events = { StripTap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
    end
end
function Strip:getSize() return GeomUI:new{ w = self.w, h = self.h } end
function Strip:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.w, self.h, WHITE)
    if self.bb then bb:blitFrom(self.bb, x, y, 0, 0, self.w, self.h) end
end
function Strip:setImage(new)
    if self.bb then self.bb:free() end
    self.bb = new
end
function Strip:onStripTap()
    if self.on_tap then self.on_tap() end
    return true
end
function Strip:onCloseWidget()
    if self.bb then self.bb:free(); self.bb = nil end
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

-- The Pen sheet, kept small: your saved pens; the pen in hand drawn at its real
-- size with its name (a tap there chooses another kind of pen); its size and
-- opacity; one row of colours; and the pressure switch for pens that use it.
function InkAwayView:openPenSettings()
    if self:rebuildSheet("_pen_dialog") then return end
    self:ensureUserIcons()
    local content_w, gap = self:sheetWidth()
    local function closeSelf() self:closeSheet("_pen_dialog") end
    local function again() self:openPenSettings() end

    local build = function(menu)
        local case = self:penset()
        local cur = case.cur
        local zoom = (self.view and self.view.zoom) or 1
        local pxmm = self:pxPerMM()
        local smudge = cur.style == "smudge"
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end

        add(self:sheetTitle(_("Pen"), content_w, _("Done"), closeSelf))
        add(vspan(10))

        -- Your pens, at their real size and colour: a tap takes one up, a hold
        -- replaces, moves or removes it
        local per = 6
        local fw = math.floor((content_w - (per - 1) * gap) / per)
        local fh = Screen:scaleBySize(34)
        local inner = fw - Screen:scaleBySize(6)
        local favs = {}
        for i, p in ipairs(case.favs) do
            -- thin enough to read as a stroke: the strip below shows the real size
            local bb = self:cachedPenSample(p, inner, fh, math.min(p.width * zoom, math.floor(fh * 0.4)))
            favs[#favs + 1] = frame(self:imageTile(bb, inner, fh,
                function() self:usePen(p); again() end,
                function() self:editSavedPen(i) end), Penset.same(p, cur))
        end
        if #case.favs < Penset.FAV_CAP then
            favs[#favs + 1] = frame(Button:new{ text = "+", text_font_size = 20, text_font_bold = true,
                width = inner, height = fh, bordersize = 0, radius = Screen:scaleBySize(10),
                background = TILE_BG, margin = 0, padding = 0, show_parent = self,
                callback = function() Penset.addFav(case); self:savePens(); again() end }, false)
        end
        add(rows(favs, per, gap))
        add(vspan(12))

        -- the pen in hand, its real size on screen, and its kind: tap to change
        local name_w = math.floor(content_w * 0.34)
        local strip_w = content_w - name_w - gap - 2 * Screen:scaleBySize(3)
        local strip_h = Screen:scaleBySize(46)
        local strip = Strip:new{ w = strip_w, h = strip_h,
            on_tap = function() closeSelf(); self:openPenTypes() end }
        local function preview()
            strip:setImage(PenSample.render(case.cur, strip.w, strip.h, math.max(1, case.cur.width * zoom)))
        end
        preview()
        self._pen_strip = strip
        local label = Penset.LABELS[cur.style] or (cur.style:match("^user:(.*)$")) or cur.style
        add(HorizontalGroup:new{ align = "center",
            FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = HAIRLINE, radius = Screen:scaleBySize(10),
                padding = Screen:scaleBySize(2), margin = 0, background = WHITE, strip },
            HorizontalSpan:new{ width = gap },
            self:actionButton(_(label) .. "  \u{203A}", name_w, function() closeSelf(); self:openPenTypes() end) })
        local function showPreview()
            preview()
            if strip.dimen then UIManager:setDirty(menu, "fast", strip.dimen) end
        end

        add(vspan(10))
        add(SliderRow:new{ label = _("Size"), value = cur.width, min = 1, max = Penset.maxWidth(cur.style),
            width = content_w, parent = menu, format = function(v) return Penset.mmText(v, pxmm) end,
            on_set = function(v)
                v = math.max(1, v)
                self.pen_width = v; self:penChanged("width", v); showPreview()
            end })
        add(vspan(6))
        add(SliderRow:new{ label = smudge and _("Strength") or _("Opacity"),
            value = math.floor((cur.alpha or 255) / 255 * 100 + 0.5),
            width = content_w, parent = menu,
            on_set = function(v)
                local a = math.max(1, math.floor(v / 100 * 255 + 0.5))
                self.pen_alpha = a; self:penChanged("alpha", a); showPreview()
            end })

        -- one row of colours (the smudge has none: it moves the colours already there)
        if not smudge then
            add(vspan(10))
            add(self:penColourRow(content_w, gap, cur, closeSelf, again))
        end

        -- pressure, for the pens it shapes
        if Pens.usesPressure(cur.style) then
            add(vspan(10))
            add(ToggleRow:new{ label = _("Width follows pressure"), is_on = self.pen_pressure ~= false,
                width = content_w, parent = menu, callback = function(on)
                    self.pen_pressure = on; self:setSetting("inkaway_pen_pressure", on)
                    if on then self:installPressure() else self:removePressure() end
                end })
        end

        add(vspan(12))
        add(self:actionButton(_("Pen and input settings"), content_w, function() closeSelf(); self:openPenInput() end))
        return content
    end
    self:showSheet("_pen_dialog", build, { on_close = function() self._pen_strip = nil end })
end

-- The kinds of pen, each drawn as it is set, in groups; the reader's made
-- brushes (a hold deletes one), and making one. A tap takes the kind up, set as
-- it was last time, and goes back to the Pen sheet.
function InkAwayView:openPenTypes()
    if self:rebuildSheet("_pentypes_dialog") then return end
    self:ensureUserIcons()
    local content_w, gap = self:sheetWidth()
    local function closeSelf() self:closeSheet("_pentypes_dialog") end
    local build = function()
        local case = self:penset()
        local cur = case.cur
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Kind of pen"), content_w, _("Back"), function() closeSelf(); self:openPenSettings() end))
        local cols = 5
        local kw = math.floor((content_w - (cols - 1) * gap) / cols)
        local kh = Screen:scaleBySize(34)
        local function kindTile(style, label, hold_cb)
            local p = case.types[style] or Penset.default(style, case.opts)
            local shown = { style = style, width = p.width, alpha = p.alpha, color = p.color }
            local bb = self:cachedPenSample(shown, kw - Screen:scaleBySize(6), kh,
                math.min(p.width, math.floor(kh * 0.45)))
            local tile = frame(self:imageTile(bb, kw - Screen:scaleBySize(6), kh,
                function() closeSelf(); self:choosePenType(style); self:openPenSettings() end, hold_cb),
                cur.style == style)
            return VerticalGroup:new{ align = "center", tile, caption(_(label), kw) }
        end
        for _i, g in ipairs(Penset.GROUPS) do
            add(vspan(10))
            add(self:sheetLabel(_(g.label)))
            add(vspan(6))
            local tiles = {}
            for _j, style in ipairs(g.types) do tiles[#tiles + 1] = kindTile(style, Penset.LABELS[style]) end
            add(rows(tiles, cols, gap))
        end
        local mine = Brushes.userList(function(k) return self:getSetting(k) end)
        if #mine > 0 then
            add(vspan(10))
            add(self:sheetLabel(_("Your brushes")))
            add(vspan(6))
            local tiles = {}
            for _i, b in ipairs(mine) do
                if b.name then
                    local key = "user:" .. b.name
                    tiles[#tiles + 1] = kindTile(key, b.name, function() self:confirmDeleteBrush(key, b.name) end)
                end
            end
            add(rows(tiles, cols, gap))
        end
        if #mine < PEN_CUSTOM_CAP then
            add(vspan(14))
            add(self:actionButton(_("Make a brush"), content_w, function() closeSelf(); self:openBrushMaker() end))
        end
        return content
    end
    self:showSheet("_pentypes_dialog", build)
end

-- One row of colours: on a colour screen black, grey, five colours and the
-- colour wheel (the saved colours are a row under it, if there are any); on a
-- greyscale one the five shades.
function InkAwayView:penColourRow(content_w, gap, cur, closeSelf, again)
    local out = VerticalGroup:new{ align = "left" }
    local colour = self:colorScreen()
    local n = colour and 8 or 5
    local sw = math.floor((content_w - (n - 1) * gap) / n)
    local swh = math.min(sw, Screen:scaleBySize(36))
    local function swatch(rgb, custom)
        return self:swatchTile(rgb, sameColor(cur.color, rgb), sw,
            function() self.pen_color = { rgb[1], rgb[2], rgb[3] }; self:penChanged("color", self.pen_color); again() end,
            custom and function() self:removeCustomColor(rgb); again() end or nil, swh)
    end
    local function line(list)
        local hg = HorizontalGroup:new{ align = "center" }
        for i, t in ipairs(list) do
            if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
            table.insert(hg, t)
        end
        return hg
    end
    local tiles = {}
    if colour then
        tiles[1] = swatch(SHADES[1].rgb)
        tiles[2] = swatch(SHADES[3].rgb)
        for i = 1, 5 do tiles[#tiles + 1] = swatch(COLORS[i].rgb) end
        tiles[#tiles + 1] = self:wheelTile(sw, swh, function() closeSelf(); self:openColorPicker() end)
    else
        for _i, e in ipairs(SHADES) do tiles[#tiles + 1] = swatch(e.rgb) end
    end
    table.insert(out, line(tiles))
    if colour then
        local customs = self:getCustomColors()
        if #customs > 0 then
            local chunk = {}
            for j = 1, math.min(#customs, n) do chunk[#chunk + 1] = swatch(customs[j], true) end
            table.insert(out, VerticalSpan:new{ width = gap })
            table.insert(out, line(chunk))
        end
    end
    return out
end

-- A saved pen's menu (from a hold): replace it with the pen in hand, move it,
-- or remove it.
function InkAwayView:editSavedPen(i)
    local case = self:penset()
    local function done() self:savePens(); self:openPenSettings() end
    self:openActionSheet("_penfav_menu", _("Saved pen"), nil, {
        { { _("Replace with the pen in hand"), function() Penset.replaceFav(case, i); done() end } },
        { { _("Move left"), function() Penset.moveFav(case, i, -1); done() end },
          { _("Move right"), function() Penset.moveFav(case, i, 1); done() end } },
        { { _("Remove"), function() Penset.removeFav(case, i); done() end, true } },
    })
end

------------------------------------------------------------------------------
-- Pen and input: the settings that are set once, not per pen
------------------------------------------------------------------------------

function InkAwayView:openPenInput()
    if self:rebuildSheet("_peninput_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local function closeSelf() self:closeSheet("_peninput_dialog") end
    local function again() self:openPenInput() end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Pen and input"), content_w, _("Done"), closeSelf))
        add(vspan(12))
        add(ToggleRow:new{ label = _("Palm rejection"), is_on = self.palm_reject,
            width = content_w, parent = menu, callback = function(on)
                self.palm_reject = on; self:setSetting("inkaway_palm_reject", on); self:applyPalmReject()
                again()   -- show or hide the options that need it
                if on and not self:penCapable() then
                    UIManager:show(InfoMessage:new{ text = _(
                        "Palm rejection needs KOReader 2026.07 or newer (that release added the pen input support). Please update KOReader and it will start working. On a reader without a pen it does nothing.") })
                end
            end })
        -- with palm rejection on, the pen writes and fingers can be kept for moving
        -- around: scrolling, turning pages, holding a picture or shape for its menu
        if self.palm_reject then
            add(vspan(10))
            add(self:sheetLabel(_("Finger on the page")))
            add(vspan(6))
            add(self:segmentedRow({ { "navigate", _("Navigate") }, { "nothing", _("Nothing") } },
                self.finger_mode, content_w,
                function(m) self.finger_mode = m; self:setSetting("inkaway_finger_mode", m); again() end))
        end
        add(vspan(10))
        add(ToggleRow:new{ label = _("Hold still to straighten"), is_on = self.hold_straighten,
            width = content_w, parent = menu,
            callback = function(on) self.hold_straighten = on; self:setSetting("inkaway_hold_straighten", on) end })
        add(vspan(10))
        add(ToggleRow:new{ label = _("Pen taps menus and buttons"), is_on = self.pen_ui,
            width = content_w, parent = menu,
            callback = function(on) self.pen_ui = on; self:setSetting("inkaway_pen_ui", on) end })
        if self:penCapable() then
            add(vspan(12))
            add(self:sheetLabel(_("Pen pressure")))
            add(vspan(6))
            add(self:segmentedRow({ { "soft", _("Light touch") }, { "medium", _("Medium") }, { "firm", _("Firm") } },
                self.pressure_curve or "medium", content_w,
                function(c) self.pressure_curve = c; self:setSetting("inkaway_pressure_curve", c); again() end))
        end
        add(vspan(12))
        add(SliderRow:new{ label = _("Stabilizer"), value = self.stabilizer, min = 0, max = 100,
            width = content_w, parent = menu, format = function(v) return tostring(v) end,
            on_set = function(v) self.stabilizer = v; self:setSetting("inkaway_stabilizer", v) end })
        add(vspan(4))
        add(self:sheetHint(
            _("Smooths shaky lines. Higher values steady the stroke but trail your finger slightly."), content_w))
        add(vspan(14))
        add(self:actionButton(_("Test pen and touch"), content_w, function() closeSelf(); self:openPenTest() end))
        return content
    end
    self:showSheet("_peninput_dialog", build)
end

return InkAwayView
