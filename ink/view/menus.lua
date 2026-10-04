--[[
The tool sheets: pen, eraser, shapes and line variants, fill colour and text,
and the colour picker and brush maker they open.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Brushes = require("ink/brushes")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local SliderRow = require("ink/ui/controls").SliderRow
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local HAIRLINE = Paint.HAIRLINE
local TILE_BG = Paint.TILE_BG
local CARET_BG = Paint.CARET_BG
local SHADES = Palette.SHADES
local COLORS = Palette.COLORS
local sameColor = Palette.sameColor

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
local function pxfmt(v) return v .. _(" px") end

local PEN_CUSTOM_CAP = 12   -- how many made brushes a reader may keep

local InkAwayView = {}

-- The reader's saved custom colours, a list of {r,g,b} kept in the settings.
function InkAwayView:getCustomColors()
    local list = self:getSetting("inkaway_custom_colors")
    return type(list) == "table" and list or {}
end

function InkAwayView:addCustomColor(rgb)
    local list = self:getCustomColors()
    for _, c in ipairs(list) do
        if sameColor(c, rgb) then return end  -- already saved
    end
    list[#list + 1] = { rgb[1], rgb[2], rgb[3] }
    while #list > 18 do table.remove(list, 1) end   -- 3 rows of 6, oldest drops out
    self:setSetting("inkaway_custom_colors", list)
end

function InkAwayView:removeCustomColor(rgb)
    local list = self:getCustomColors()
    for i, c in ipairs(list) do
        if sameColor(c, rgb) then table.remove(list, i); break end
    end
    self:setSetting("inkaway_custom_colors", list)
end

-- Open the colour wheel to pick (and optionally save) an exact pen colour.
function InkAwayView:openColorPicker()
    local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
    if not ok then return end
    local function apply(rgb) self.pen_color = { rgb[1], rgb[2], rgb[3] } end
    UIManager:show(ColorPicker:new{
        color = self.pen_color,
        on_pick = function(rgb) apply(rgb); self:openPenSettings() end,
        on_save = function(rgb) apply(rgb); self:addCustomColor(rgb); self:openPenSettings() end,
    })
end

-- The pen sheet: size and opacity sliders, brush tiles with a create (+) tile,
-- colour swatch rows and the stroke aids. Rebuilt whenever something changes.
function InkAwayView:openPenSettings()
    if self:rebuildSheet("_pen_dialog") then return end
    self:ensureUserIcons()
    local content_w, gap = self:sheetWidth()
    local function closeSelf() self:closeSheet("_pen_dialog") end

    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end

        add(self:sheetTitle(_("Pen"), content_w, _("Done"), closeSelf))
        add(vspan(12))
        add(SliderRow:new{ label = _("Size"), value = self.pen_width, min = 1, max = 60,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v) self.pen_width = math.max(1, v) end })
        add(vspan(10))
        add(SliderRow:new{ label = _("Opacity"), value = math.floor(self.pen_alpha / 255 * 100 + 0.5),
            width = content_w, parent = menu,
            on_set = function(v) self.pen_alpha = math.max(1, math.floor(v / 100 * 255 + 0.5)) end })
        add(vspan(12))

        -- brush styles: wave tiles (four per row, wrapping), then a create (+) tile
        local styleMenu = Brushes.menu(function(k) return self:getSetting(k) end)
        local ncustom = 0
        for _, s in ipairs(styleMenu) do if s.custom then ncustom = ncustom + 1 end end
        local per = 4
        local swtile = math.floor((content_w - (per - 1) * gap) / per)
        local wave_h = Screen:scaleBySize(46)
        local tiles = {}
        for _, s in ipairs(styleMenu) do
            local sel = (self.pen_style == s.key)
            tiles[#tiles + 1] = self:brushWaveTile(s.key, swtile, wave_h, sel, function()
                self.pen_style = s.key; self:setSetting("inkaway_pen_style", s.key); self:openPenSettings()
            end, s.custom and function() self:confirmDeleteBrush(s.key, s.label) end or nil)
        end
        if ncustom < PEN_CUSTOM_CAP then
            tiles[#tiles + 1] = Button:new{ text = "+", text_font_size = 26, text_font_bold = true,
                width = swtile, height = wave_h, bordersize = 0, radius = Screen:scaleBySize(12),
                background = TILE_BG, margin = 0, padding = 0, show_parent = self,
                callback = function() closeSelf(); self:openBrushMaker() end }
        end
        for i = 1, #tiles, per do
            local row = HorizontalGroup:new{ align = "center" }
            for j = i, math.min(i + per - 1, #tiles) do
                if j > i then table.insert(row, HorizontalSpan:new{ width = gap }) end
                table.insert(row, tiles[j])
            end
            add(row)
            if i + per <= #tiles then add(vspan(gap)) end
        end
        add(vspan(12))

        -- The stroke aids (toggles and stabilizer) end the sheet and must never be
        -- pushed off screen, so they are built and measured first and the custom
        -- colour rows are capped to the space left (see the colour section).
        local function toggle(label, on, cb)
            return ToggleRow:new{ label = label, is_on = on, compact = true, parent = menu, callback = cb }
        end
        local tail = VerticalGroup:new{ align = "left" }
        local assist = toggle(_("Shape assist"), self.shape_assist, function(on)
            self.shape_assist = on; self:setSetting("inkaway_shape_assist", on)
            -- free the pre-stroke snapshot, which only shape assist uses
            if not on and self._pre_stroke_bb then
                self._pre_stroke_bb:free(); self._pre_stroke_bb = nil
                self._pre_stroke_valid = false
            end
        end)
        local palm = toggle(_("Palm rejection"), self.palm_reject, function(on)
            self.palm_reject = on; self:setSetting("inkaway_palm_reject", on); self:applyPalmReject()
            self:openPenSettings()   -- show or hide the options that need it
            if on and not self:penCapable() then
                UIManager:show(InfoMessage:new{ text = _(
                    "Palm rejection needs KOReader 2026.07 or newer (that release added the pen input support). Please update KOReader and it will start working. On a reader without a pen it does nothing.") })
            end
        end)
        table.insert(tail, HorizontalGroup:new{ align = "center", assist,
            HorizontalSpan:new{ width = math.max(Screen:scaleBySize(16), content_w - assist.width - palm.width) },
            palm })
        table.insert(tail, vspan(10))
        table.insert(tail, ToggleRow:new{ label = _("Hold still to straighten"), is_on = self.hold_straighten,
            width = content_w, parent = menu,
            callback = function(on) self.hold_straighten = on; self:setSetting("inkaway_hold_straighten", on) end })
        table.insert(tail, vspan(10))
        table.insert(tail, ToggleRow:new{ label = _("Pen taps menus and buttons"), is_on = self.pen_ui,
            width = content_w, parent = menu,
            callback = function(on) self.pen_ui = on; self:setSetting("inkaway_pen_ui", on) end })
        -- with palm rejection on, the pen writes and fingers can be kept for moving
        -- around: scrolling, turning pages, holding a picture or shape for its menu
        if self.palm_reject then
            table.insert(tail, vspan(10))
            table.insert(tail, self:sheetLabel(_("Finger on the page")))
            table.insert(tail, vspan(6))
            table.insert(tail, self:segmentedRow({ { "navigate", _("Navigate") }, { "nothing", _("Nothing") } },
                    self.finger_mode, content_w,
                function(m)
                    self.finger_mode = m; self:setSetting("inkaway_finger_mode", m)
                    self:openPenSettings()
                end))
        end
        -- Debug: the pen input test, hidden unless show_pen_test is set.
        if self.show_pen_test and self:penCapable() then
            table.insert(tail, vspan(10))
            table.insert(tail, self:actionButton(_("Test pen input"), content_w,
                function() closeSelf(); self:startPenInputTest() end))
        end
        table.insert(tail, vspan(12))
        table.insert(tail, SliderRow:new{ label = _("Stabilizer"), value = self.stabilizer, min = 0, max = 100,
            width = content_w, parent = menu, format = function(v) return tostring(v) end,
            on_set = function(v) self.stabilizer = v; self:setSetting("inkaway_stabilizer", v) end })
        table.insert(tail, vspan(4))
        table.insert(tail, self:sheetHint(
            _("Smooths shaky lines. Higher values steady the stroke but trail your finger slightly."), content_w))

        -- Colour swatches: the shades, then on a colour screen the colours and
        -- saved ones, and always the "+" tile for the colour wheel. Six tiles fill
        -- each row; short rows are centred. Tile height is capped on large high-DPI
        -- colour screens, so the colour rows never overflow the sheet.
        local sw = math.floor((content_w - 5 * gap) / 6)
        local swh = math.min(sw, Screen:scaleBySize(58))
        local function swatch(rgb, custom)
            return self:swatchTile(rgb, sameColor(self.pen_color, rgb), sw,
                function() self.pen_color = { rgb[1], rgb[2], rgb[3] }; self:openPenSettings() end,
                custom and function() self:removeCustomColor(rgb); self:openPenSettings() end or nil, swh)
        end
        local function pickerTile()
            local inner = sw - Screen:scaleBySize(8)
            local inner_h = swh - Screen:scaleBySize(8)
            local b = Button:new{ text = "+", text_font_size = 24, text_font_bold = true,
                width = inner, height = inner_h, background = TILE_BG,
                radius = Screen:scaleBySize(11), bordersize = 0, margin = 0, padding = 0,
                show_parent = self, callback = function() closeSelf(); self:openColorPicker() end }
            return FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = BLACK,
                radius = Screen:scaleBySize(14), padding = Screen:scaleBySize(3), margin = 0, b }
        end
        local function centeredRow(list)
            local hg = HorizontalGroup:new{ align = "center" }
            for i, t in ipairs(list) do
                if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
                table.insert(hg, t)
            end
            return CenterContainer:new{ dimen = GeomUI:new{ w = content_w, h = hg:getSize().h }, hg }
        end

        -- the rows are real widgets, so the custom rows are capped by their
        -- measured height, keeping the stroke aids on screen
        local rowWidgets = {}
        local shadeTiles = {}
        for _, e in ipairs(SHADES) do shadeTiles[#shadeTiles + 1] = swatch(e.rgb) end
        rowWidgets[#rowWidgets + 1] = centeredRow(shadeTiles)
        if self:colorScreen() then
            -- five preset colours and the "+" tile: one row of six
            local colorTiles = {}
            for i = 1, 5 do colorTiles[#colorTiles + 1] = swatch(COLORS[i].rgb) end
            colorTiles[#colorTiles + 1] = pickerTile()
            rowWidgets[#rowWidgets + 1] = centeredRow(colorTiles)

            -- saved colours go on rows below, as many as fit in the height left
            local head_h = content:getSize().h   -- head = title..brushes
            content._size = nil                  -- invalidate (VerticalGroup caches offsets)
            local fixed_h = head_h + tail:getSize().h + Screen:scaleBySize(16)
            for _, w in ipairs(rowWidgets) do fixed_h = fixed_h + w:getSize().h + gap end
            local per_row = rowWidgets[1]:getSize().h + gap
            local budget = Screen:getHeight() - self:sheetTopY() - Screen:scaleBySize(4)
                - Screen:scaleBySize(8) - 2 * Screen:scaleBySize(18) - 2 * Size.border.window
            local ncustrows = math.max(0, math.floor((budget - fixed_h) / per_row))
            local customs = self:getCustomColors()
            local shown = math.min(#customs, ncustrows * 6)
            for i = 1, shown, 6 do
                local chunk = {}
                for j = i, math.min(i + 5, shown) do chunk[#chunk + 1] = swatch(customs[j], true) end
                rowWidgets[#rowWidgets + 1] = centeredRow(chunk)
            end
        end
        for i, w in ipairs(rowWidgets) do
            if i > 1 then add(vspan(gap)) end
            add(w)
        end
        add(vspan(16))
        for _, w in ipairs(tail) do add(w) end
        return content
    end
    self:showSheet("_pen_dialog", build)
end

-- Open the brush maker. A saved brush becomes the current pen and stays in the
-- pen menu (it is kept in KOReader's settings, so it survives plugin updates).
function InkAwayView:openBrushMaker()
    local ok, BrushMaker = pcall(require, "ink/ui/brushmaker")
    if not ok then return end
    local maker = BrushMaker:new{
        params = Brushes.defaults(),
        on_save = function(name, params)
            local key = Brushes.save(
                function(k) return self:getSetting(k) end,
                function(k, val) self:setSetting(k, val) end,
                name, params)
            self.pen_style = key
            self:setSetting("inkaway_pen_style", key)
            self:openPenSettings()
        end,
    }
    UIManager:show(maker)
end

function InkAwayView:confirmDeleteBrush(key, label)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Delete the brush \"%s\"?"), label),
        ok_text = _("Delete"),
        ok_callback = function()
            local name = key:gsub("^user:", "")
            Brushes.remove(function(k) return self:getSetting(k) end,
                           function(k, v) self:setSetting(k, v) end, name)
            if self.pen_style == key then
                self.pen_style = "solid"
                self:setSetting("inkaway_pen_style", "solid")
            end
            self:openPenSettings()
        end,
    })
end

-- The eraser sheet: a size slider, and the Erase pictures and Erase whole
-- strokes toggles.
function InkAwayView:openEraserSettings()
    if self:rebuildSheet("_eraser_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_eraser_dialog") end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Eraser"), content_w, _("Done"), closeSelf))
        add(vspan(16))
        add(SliderRow:new{ label = _("Size"), value = self.eraser_width, min = 4, max = 120,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v) self.eraser_width = math.max(1, v) end })
        add(vspan(14))
        local pictures = ToggleRow:new{ label = _("Erase pictures"), is_on = self.erase_bg,
            compact = true, parent = menu,
            callback = function(on) self.erase_bg = on; self:setSetting("inkaway_erase_bg", on) end }
        local whole = ToggleRow:new{ label = _("Erase whole strokes"), is_on = self.erase_whole,
            compact = true, parent = menu,
            callback = function(on) self.erase_whole = on; self:setSetting("inkaway_erase_whole", on) end }
        add(HorizontalGroup:new{ align = "center", pictures,
            HorizontalSpan:new{ width = math.max(Screen:scaleBySize(16), content_w - pictures.width - whole.width) },
            whole })
        return content
    end
    self:showSheet("_eraser_dialog", build)
end

-- Arrowhead size, in canvas pixels (used by the arrow shapes).
function InkAwayView:openArrowSize()
    UIManager:show(SpinWidget:new{
        title_text = _("Arrowhead size"),
        info_text = _("How big the arrowheads are, in canvas pixels."),
        value = self.arrow_head, value_min = 6, value_max = 120, value_step = 2, value_hold_step = 10,
        unit = _("px"),
        callback = function(spin)
            self.arrow_head = math.max(4, math.floor(spin.value))
            self:setSetting("inkaway_arrow_head", self.arrow_head)
            self:openShapeLineMenu()
        end,
    })
end

-- The Shapes sheet: large shape tiles (a caret in the Line tile's corner opens
-- the line variants), smaller paint bucket and lasso tiles, and the fill and snap
-- toggles. Icons keep their transparency so the tile colour shows through; the
-- selected tile is black with the icon inverted to white.
function InkAwayView:openShapePicker()
    self:flushShape()
    if self:rebuildSheet("_shape_dialog") then return end
    self:ensureUserIcons()

    -- four square tiles fill a row with equal gaps; the content width comes from
    -- the tile size so everything lines up with the panel padding
    local content_w, gap, tileW = self:sheetWidth()
    local halfW = math.floor((content_w - gap) / 2)
    local isz = math.floor(tileW * 0.60)   -- big icon inside the tile
    local closeSelf = function() self:closeSheet("_shape_dialog") end

    -- the Line tile: a select button (a plain line) with a small caret button in
    -- its bottom right corner that opens the variants
    local function lineTile(sel)
        local select_btn = self:makeTile("sh_line", tileW, tileW, isz, sel, function()
            self:flushShape(); self.shape, self.shape_arrow = "line", nil
            self:refreshToolLabels(); self:openShapePicker()
        end)
        local caretW = Screen:scaleBySize(30)
        local inset = Screen:scaleBySize(5)
        local caretIsz = caretW - Screen:scaleBySize(8)
        local caret_btn = Button:new{ icon = "inkaway.caret", icon_width = caretIsz, icon_height = caretIsz,
            width = caretW, height = caretW,
            bordersize = 0, radius = Screen:scaleBySize(8), background = CARET_BG,
            margin = 0, padding = 0, show_parent = self,
            callback = function() self:openShapeLineMenu() end,
            overlap_offset = { tileW - caretW - inset, tileW - caretW - inset } }
        local cw = self:tileIcon("caret", caretIsz, false)
        if cw then self:setButtonLabel(caret_btn, cw) end
        -- the caret is child 1, so events reach its corner first and anything
        -- else falls through to the select button; paintTo draws in reverse so
        -- the caret stays on top
        local og = OverlapGroup:new{ dimen = { w = tileW, h = tileW },
            allow_mirroring = false, caret_btn, select_btn }
        function og:paintTo(bb, x, y)
            for i = #self, 1, -1 do
                local w = self[i]
                if w.overlap_offset then
                    w:paintTo(bb, x + w.overlap_offset[1], y + w.overlap_offset[2])
                else
                    w:paintTo(bb, x, y)
                end
            end
        end
        return og
    end

    local function shapeTile(name, shape)
        return self:makeTile(name, tileW, tileW, isz, self.shape == shape, function()
            self:flushShape(); self.shape, self.shape_arrow = shape, nil
            self:refreshToolLabels(); self:openShapePicker()
        end)
    end

    -- built inside the build callback so the toggles can use the menu as their
    -- repaint parent
    local build = function(menu)
        -- the tiles show the current selection, so they are rebuilt on every
        -- rebuild
        local lineSel = (self.shape == "line" or self.shape == "curve")
        local shapeRow = HorizontalGroup:new{ align = "center",
            lineTile(lineSel), HorizontalSpan:new{ width = gap },
            shapeTile("sh_rect", "rect"), HorizontalSpan:new{ width = gap },
            shapeTile("sh_ellipse", "ellipse"), HorizontalSpan:new{ width = gap },
            shapeTile("sh_triangle", "triangle"),
        }
        -- tools row: paint bucket and lasso, smaller tiles with a label
        local toolH = Screen:scaleBySize(96)
        local toolIsz = Screen:scaleBySize(36)
        local toolRow = HorizontalGroup:new{ align = "center",
            self:makeTile("bucket", halfW, toolH, toolIsz, self.tool == "fill", function()
                self:flushShape(); self.tool = "fill"; self:refreshToolLabels()
                closeSelf()
            end, _("Paint bucket"), _("hold to pick colour"), function() self:openFillColor() end),
            HorizontalSpan:new{ width = gap },
            self:makeTile("lasso", halfW, toolH, toolIsz, self.tool == "lasso", function()
                self:flushPending(); self:flushShape()
                if self.selection or self.lassoing then self:clearSelection() end
                self.tool = "lasso"; self:refreshToolLabels()
                closeSelf()
                self:composeCanvas(); self:renderView(); self:refresh("all", "full")
            end, _("Lasso select")),
        }
        -- three compact toggles (switch right after its label) spread across one row
        local function toggle(label, on, cb)
            return ToggleRow:new{ label = label, is_on = on, compact = true, parent = menu, callback = cb }
        end
        local fillRow = toggle(_("Fill"), self.shape_fill, function(on)
            self.shape_fill = on end)
        local gridRow = toggle(_("Snap to grid"), self.snap_grid, function(on)
            self.snap_grid = on; self:setSetting("inkaway_snap_grid", on) end)
        local snap45Row = toggle(_("Snap to 45\u{00B0}"), self.snap_angle, function(on)
            self.snap_angle = on; self:setSetting("inkaway_snap_angle", on) end)
        local totalW = fillRow.width + gridRow.width + snap45Row.width
        local slack = math.max(Screen:scaleBySize(16), math.floor((content_w - totalW) / 2))
        local togglesRow = HorizontalGroup:new{ align = "center",
            fillRow, HorizontalSpan:new{ width = slack },
            gridRow, HorizontalSpan:new{ width = slack },
            snap45Row }
        return VerticalGroup:new{ align = "left",
            self:sheetTitle(_("Shapes"), content_w, _("Done"), closeSelf), vspan(16),
            shapeRow, vspan(16),
            togglesRow, vspan(16),
            toolRow,
        }
    end
    self:showSheet("_shape_dialog", build)
end

-- The line, arrow and curve variants, opened from the Line tile: two rows of
-- three smaller tiles (straight and curved), the arrowhead size and a Back pill.
function InkAwayView:openShapeLineMenu()
    -- no rebuild in place: every button here closes the sheet
    self:closeSheet("_shape_dialog")
    self:closeSheet("_shape_line_dialog")
    self:ensureUserIcons()

    local gap, parentTileW = select(2, self:sheetWidth())
    local tileW = math.floor(parentTileW * 0.78)   -- smaller than the parent's tiles
    local isz = math.floor(tileW * 0.60)
    local content_w = 3 * tileW + 2 * gap
    local closeSelf = function() self:closeSheet("_shape_line_dialog") end

    local function isSel(shape, arrow)
        return self.shape == shape and (self.shape_arrow or false) == (arrow or false)
    end
    local function pick(shape, arrow)
        return function()
            self:flushShape(); self.shape, self.shape_arrow = shape, arrow
            self:refreshToolLabels()
            closeSelf()
            self:openShapePicker()
        end
    end
    local function tile(name, shape, arrow)
        return self:makeTile(name, tileW, tileW, isz, isSel(shape, arrow), pick(shape, arrow))
    end

    local row1 = HorizontalGroup:new{ align = "center",
        tile("sh_line", "line", nil), HorizontalSpan:new{ width = gap },
        tile("sh_arrow", "line", "end"), HorizontalSpan:new{ width = gap },
        tile("sh_darrow", "line", "both") }
    local row2 = HorizontalGroup:new{ align = "center",
        tile("sh_curve", "curve", nil), HorizontalSpan:new{ width = gap },
        tile("sh_carrow", "curve", "end"), HorizontalSpan:new{ width = gap },
        tile("sh_cdarrow", "curve", "both") }

    -- arrowhead size: a full-width text button
    local ahRow = Button:new{ text = string.format(_("Arrowhead size: %d px"), self.arrow_head),
        width = content_w, height = Screen:scaleBySize(48), bordersize = 0,
        radius = Screen:scaleBySize(14), background = TILE_BG, margin = 0, padding = 0,
        text_font_size = 17, show_parent = self,
        callback = function() closeSelf(); self:openArrowSize() end }

    local build = function()
        return VerticalGroup:new{ align = "left",
            self:sheetTitle(_("Line / arrow / curve"), content_w, _("Back"),
                function() closeSelf(); self:openShapePicker() end, 20), vspan(16),
            row1, vspan(gap),
            row2, vspan(16),
            ahRow,
        }
    end
    self:showSheet("_shape_line_dialog", build)
end

-- The paint bucket's colour sheet (hold the Paint bucket tile): swatch rows (the
-- shades, plus colours on a colour screen) and an opacity slider.
function InkAwayView:openFillColor()
    if self:rebuildSheet("_fill_dialog") then return end
    self:closeSheet("_shape_dialog")
    self:ensureUserIcons()

    local content_w, gap, sw = self:sheetWidth(6)   -- 6 swatches per row (colours)

    -- one swatch: a rounded colour tile; the current colour gets a black ring,
    -- the others a hairline
    local function swatch(e)
        local selected = sameColor(self.fill_color, e.rgb)
        local inner = sw - Screen:scaleBySize(8)
        local btn = self:colourTileButton(e.rgb, inner, inner, Screen:scaleBySize(12),
            function() self.fill_color = { e.rgb[1], e.rgb[2], e.rgb[3] }; self:openFillColor() end)
        return FrameContainer:new{
            bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
            color = selected and BLACK or HAIRLINE,
            radius = Screen:scaleBySize(15),
            padding = selected and Screen:scaleBySize(1) or Screen:scaleBySize(3),
            margin = 0, btn }
    end
    local function swatchRow(entries)
        local row = HorizontalGroup:new{ align = "center" }
        for i, e in ipairs(entries) do
            if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, swatch(e))
        end
        return row
    end

    -- opacity, built inside build() so the shown menu is its repaint parent
    local build = function(menu)
        local pct = math.floor(self.fill_alpha / 255 * 100 + 0.5)
        local opacity = SliderRow:new{ label = _("Opacity"), value = pct, width = content_w, parent = menu,
            on_set = function(v) self.fill_alpha = math.floor(v / 100 * 255 + 0.5) end }
        local content = VerticalGroup:new{ align = "center" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Fill colour"), content_w, _("Done"), function() self:closeSheet("_fill_dialog") end))
        add(vspan(16))
        add(swatchRow(SHADES))
        if self:colorScreen() then
            add(vspan(gap))
            add(swatchRow(COLORS))
        end
        add(vspan(18))
        add(opacity)
        return content
    end
    self:showSheet("_fill_dialog", build)
end

-- The text sheet: font chooser, a size slider, and the snap and eraser-protect
-- toggles.
function InkAwayView:openTextSettings()
    self:closeSheet("_text_settings")
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local size = self.text_size or math.max(16, math.floor(self.view.canvas_w / 32))
    local closeSelf = function() self:closeSheet("_text_settings") end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Text"), content_w, _("Done"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("Font: ") .. self:textFontDisplay(), content_w,
            function() closeSelf(); self:openTextFont() end))
        add(vspan(12))
        add(SliderRow:new{ label = _("Font size"), value = size, min = 10, max = 96,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v) self.text_size = v; self:setSetting("inkaway_text_size", v) end })
        add(vspan(14))
        add(ToggleRow:new{ label = _("Snap lines to ruling"), is_on = self.text_grid_snap,
            width = content_w, parent = menu,
            callback = function(on)
                self.text_grid_snap = on; self:setSetting("inkaway_text_grid_snap", on)
                if self.editing_text then
                    self.editing_text.grid_snap = on
                    if on then self:snapTextBoxToGrid(self.editing_text) end
                    self:invalidateLayout(); self:refreshTextBox("flashui")
                end
            end })
        add(vspan(10))
        add(ToggleRow:new{ label = _("Protect text from eraser"), is_on = self.text_erase_protect,
            width = content_w, parent = menu,
            callback = function(on)
                self.text_erase_protect = on; self:setSetting("inkaway_text_erase_protect", on)
            end })
        return content
    end
    self:showSheet("_text_settings", build)
end

return InkAwayView
