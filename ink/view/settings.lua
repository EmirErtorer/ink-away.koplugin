--[[
The settings sheet (gear) and its sub-sheets: grid, background image and a list
chooser.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local IconMenu = require("ink/ui/iconmenu")
local SliderRow = require("ink/ui/controls").SliderRow

local Screen = Device.screen

local InkAwayView = {}

function InkAwayView:openBackground()
    if self._bg_dialog then UIManager:close(self._bg_dialog); self._bg_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local HINT = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF)
    local closeSelf = function()
        if self._bg_dialog then UIManager:close(self._bg_dialog); self._bg_dialog = nil end
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        table.insert(content, self:sheetTitle(_("Background image"), content_w, _("Done"), closeSelf))
        table.insert(content, vspan(16))
        table.insert(content, self:actionButton(_("Open image as background"), content_w,
            function() closeSelf(); self:chooseBackground() end))
        if self.bg_bb then
            table.insert(content, vspan(8))
            table.insert(content, self:actionButton(_("Remove background"), content_w,
                function() closeSelf(); self:removeBackground() end, true))
        end
        table.insert(content, vspan(12))
        local hint = self.bg_bb
            and _("At save time you can include the picture or export just your drawing. The grid is always left out.")
            or _("Draw over a photo or screenshot; your drawing sits on top. To draw on a PDF, use \u{201C}Open PDF as notebook\u{201D} instead.")
        table.insert(content, TextBoxWidget:new{ text = hint, width = content_w,
            face = Font:getFace("cfont", 15), fgcolor = HINT })
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._bg_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._bg_dialog = nil end }
    UIManager:show(self._bg_dialog)
end

-- Friendly names for the notebook paper (ruling) styles.
local TEMPLATE_LABEL = { lines = _("lined"), grid = _("grid"), dots = _("dotted"),
    margin = _("margin"), cornell = _("Cornell"), blank = _("blank") }

-- A generic "pick one of a list" sub-sheet in the shapes-menu style: a vertical
-- stack of full-width buttons, the current one filled black. `options` is a list
-- of { value, label }; onpick(value) is called after the sheet closes.
function InkAwayView:openChooserSheet(title, options, current, onpick)
    if self._chooser_dialog then UIManager:close(self._chooser_dialog); self._chooser_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._chooser_dialog then UIManager:close(self._chooser_dialog); self._chooser_dialog = nil end
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        table.insert(content, self:sheetTitle(title, content_w, _("Done"), closeSelf))
        table.insert(content, vspan(16))
        for i, o in ipairs(options) do
            if i > 1 then table.insert(content, vspan(8)) end
            table.insert(content, self:actionButton(o[2], content_w,
                function() closeSelf(); onpick(o[1]) end, current == o[1]))
        end
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._chooser_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._chooser_dialog = nil end }
    UIManager:show(self._chooser_dialog)
end

-- The grid sub-sheet: type, size and opacity in one place, opened from the main
-- settings sheet's single "Grid" button so that sheet stays short (no scrolling).
-- Picking a type rebuilds this sheet in place (the highlight moves) like the other
-- segmented pickers; the sliders drive the same live grid refresh the old inline
-- controls did, and it wears the same rounded-corner sheet chrome as every sheet.
function InkAwayView:openGridSettings()
    if self._grid_dialog then
        if self._grid_dialog.rebuild then self._grid_dialog:rebuild(); return end
        UIManager:close(self._grid_dialog); self._grid_dialog = nil
    end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local pxfmt = function(v) return v .. _(" px") end
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._grid_dialog then UIManager:close(self._grid_dialog); self._grid_dialog = nil end
    end
    -- picking a type keeps the sheet open (rebuild in place) so several tweaks are
    -- one visit; "Off" remembers the last real style so turning it back on restores
    -- the same look. Size/opacity never force the grid on -- only the type does --
    -- so the "Off" choice stays honest while its values are kept for next time.
    local function pick(v)
        if v == "off" then
            self.grid_on = false; self:setSetting("inkaway_grid", false)
        else
            self.grid_style = v; self:setSetting("inkaway_grid_style", v)
            self.grid_on = true; self:setSetting("inkaway_grid", true)
        end
        self:renderView(); self:refreshArea(); self:openGridSettings()
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        -- a segmented row of equal buttons, the current one filled black
        local function seg(options, current, onpick)
            local n = #options
            local w = math.floor((content_w - (n - 1) * gap) / n)
            local row = HorizontalGroup:new{ align = "center" }
            for i, o in ipairs(options) do
                if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
                table.insert(row, self:actionButton(o[2], w, function() onpick(o[1]) end, current == o[1]))
            end
            return row
        end
        add(self:sheetTitle(_("Grid"), content_w, _("Done"),
            function() closeSelf(); self:openSettings() end))
        add(vspan(16))

        -- type: two tidy rows of three (Off + the five styles)
        local cur = self.grid_on and self.grid_style or "off"
        add(seg({ { "off", _("Off") }, { "square", _("Square") }, { "dots", _("Dots") } }, cur, pick))
        add(vspan(8))
        add(seg({ { "lines", _("Lines") }, { "iso", _("Isometric") }, { "thirds", _("Thirds") } }, cur, pick))
        add(vspan(16))

        -- size + opacity, live-refreshing the grid behind the sheet as they move
        add(SliderRow:new{ label = _("Size"), value = self.grid_size, min = 8, max = 200, step = 2,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v) self.grid_size = v; self:setSetting("inkaway_grid_size", v)
                self:renderView(); self:refreshArea() end })
        add(vspan(12))
        add(SliderRow:new{ label = _("Opacity"), value = self.grid_strength, min = 5, max = 100, step = 5,
            width = content_w, parent = menu,
            on_set = function(v) self.grid_strength = v; self:setSetting("inkaway_grid_strength", v)
                self:renderView(); self:refreshArea() end })

        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._grid_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._grid_dialog = nil end }
    UIManager:show(self._grid_dialog)
end

-- The gear menu (shapes-menu style): file/page actions as buttons, the grid or
-- notebook-paper controls as a toggle/chooser and sliders, and symmetry /
-- autosave as segmented rows. Reorganised into clear sections.
function InkAwayView:openSettings()
    if self.active_image then self:finishImageEdit() end   -- settle a selected image first
    -- `_settings_dialog` is normally this settings IconMenu (rebuild in place), but a
    -- few transient ButtonDialogs (Page menu, page overview) reuse the field and have
    -- no rebuild -- drop such a one and open fresh instead of crashing.
    if self._settings_dialog then
        if self._settings_dialog.rebuild then self._settings_dialog:rebuild(); return end
        UIManager:close(self._settings_dialog); self._settings_dialog = nil
    end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    self:ensureUserIcons()
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local halfW = math.floor((content_w - gap) / 2)
    local pxfmt = function(v) return v .. _(" px") end
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._settings_dialog then UIManager:close(self._settings_dialog); self._settings_dialog = nil end
    end
    local function act(label, w, cb, dark, big)
        return self:actionButton(label, w, function() closeSelf(); cb() end, dark, big)
    end
    local function header(txt)
        return TextWidget:new{ text = txt, face = Font:getFace("cfont", 15), bold = true,
            fgcolor = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF) }
    end

    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        local function row2(a, b)
            return HorizontalGroup:new{ align = "center", a, HorizontalSpan:new{ width = gap }, b }
        end
        -- a segmented picker: N equal buttons, the current one filled black
        local function seg(options, current, onpick)
            local n = #options
            local w = math.floor((content_w - (n - 1) * gap) / n)
            local row = HorizontalGroup:new{ align = "center" }
            for i, o in ipairs(options) do
                if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
                -- do NOT close the sheet: these pickers change a setting and stay,
                -- so onpick's openSettings() rebuilds this sheet in place (the moved
                -- highlight refreshes just this region, no full-screen flash)
                table.insert(row, self:actionButton(o[2], w, function() onpick(o[1]) end,
                    current == o[1]))
            end
            return row
        end

        add(self:sheetTitle(_("Settings"), content_w, _("Done"), closeSelf))
        add(vspan(16))

        -- files & pages. New drawing / New notebook are the primary actions, so
        -- they get the larger bold face (the `big` flag) to stand out.
        add(row2(act(_("New drawing"), halfW, function() self:newDrawing() end, false, true),
                 act(_("New notebook"), halfW, function() self:newNotebook() end, false, true)))
        add(vspan(8))
        add(row2(act(_("Open project"), halfW, function() self:openProject() end),
                 act(_("Save project"), halfW, function() self:saveProject() end)))
        add(vspan(8))
        add(row2(act(_("Open PDF"), halfW, function() self:openPdfAsNotebook() end),
                 act(_("Background"), halfW, function() self:openBackground() end)))
        add(vspan(16))

        -- orientation: portrait vs landscape. Switches the whole app (and the shape
        -- of new canvases and notebooks) the chosen way up. Closes the sheet on pick
        -- because the screen size changes; reopen it to see the new highlight.
        if self:orientationSupported() then
            add(header(_("Orientation")))
            add(vspan(6))
            local cur = self:orientationClass()
            add(row2(
                self:actionButton(_("Portrait"), halfW, function()
                    closeSelf(); self:setOrientation("portrait") end, cur == "portrait"),
                self:actionButton(_("Landscape"), halfW, function()
                    closeSelf(); self:setOrientation("landscape") end, cur == "landscape")))
            add(vspan(16))
        end

        -- grid (canvas) or paper (notebook)
        if self.notebook then
            local t = self.notebook.template
            add(act(_("Paper: ") .. (TEMPLATE_LABEL[t.style or "lines"] or t.style), content_w, function()
                self:openChooserSheet(_("Notebook paper"), {
                    { "lines", _("Lined") }, { "grid", _("Grid") }, { "dots", _("Dotted") },
                    { "margin", _("Margin ruled") }, { "cornell", _("Cornell") }, { "blank", _("Blank") } },
                    t.style, function(v)
                        t.style = v; self.nb_style = v; self:setSetting("inkaway_nb_style", v); self.dirty = true
                        self:composeCanvas(); self:renderView(); self:refreshArea(); self:openSettings()
                    end)
            end))
            add(vspan(12))
            add(SliderRow:new{ label = _("Line spacing"), value = t.size or 40, min = 12, max = 200, step = 2,
                width = content_w, parent = menu, format = pxfmt,
                on_set = function(v) t.size = v; self.nb_size = v; self:setSetting("inkaway_nb_size", v)
                    self.dirty = true; self:composeCanvas(); self:renderView(); self:refreshArea() end })
            add(vspan(10))
            add(SliderRow:new{ label = _("Line strength"), value = t.strength or 45, min = 5, max = 100, step = 5,
                width = content_w, parent = menu,
                on_set = function(v) t.strength = v; self.nb_strength = v; self:setSetting("inkaway_nb_strength", v)
                    self.dirty = true; self:composeCanvas(); self:renderView(); self:refreshArea() end })
        else
            -- The grid type, size and opacity all live in their own sub-sheet
            -- (openGridSettings), reached by this one button. Folding three
            -- controls into one keeps the main sheet short enough to never scroll.
            -- The button shows the current grid at a glance; state is remembered.
            local GRID_LABEL = { off = _("Off"), square = _("Square"), dots = _("Dots"),
                lines = _("Lines"), iso = _("Isometric"), thirds = _("Thirds") }
            local cur = self.grid_on and self.grid_style or "off"
            add(act(_("Grid: ") .. (GRID_LABEL[cur] or cur), content_w, function()
                self:openGridSettings() end))
        end
        add(vspan(16))

        -- symmetry (segmented)
        add(header(_("Symmetry")))
        add(vspan(6))
        add(seg({ { "off", _("Off") }, { "vert", _("Vertical") }, { "horiz", _("Horizontal") }, { "quad", _("Four-way") } },
            self.symmetry, function(v) self.symmetry = v; self:setSetting("inkaway_symmetry", v); self:openSettings() end))
        add(vspan(14))

        -- ghosting cleanup slider (0 = off). 0-50 in 5s: a small range is easier to
        -- pinpoint, and clearing every >50 strokes is effectively never anyway.
        add(SliderRow:new{ label = _("Ghosting"), value = math.min(50, self.ghost_clean or 0), min = 0, max = 50, step = 5,
            width = content_w, parent = menu,
            format = function(v) return v == 0 and _("off") or string.format(_("%d strokes"), v) end,
            on_set = function(v) self.ghost_clean = v; self:setSetting("inkaway_ghost", v)
                self._strokes_since_full = 0 end })
        add(vspan(4))
        do
            local TextBoxWidget = require("ui/widget/textboxwidget")
            add(TextBoxWidget:new{
                text = _("Fast strokes leave faint marks; a full refresh clears them this often."),
                face = Font:getFace("cfont", 13),
                fgcolor = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF), width = content_w })
        end
        add(vspan(14))

        -- autosave (segmented)
        add(header(_("Autosave")))
        add(vspan(6))
        add(seg({ { "off", _("Off") }, { "exit", _("On exit") }, { "periodic", _("Every 3 min") } },
            self.autosave, function(v) self:setAutosave(v); self:openSettings() end))

        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._settings_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._settings_dialog = nil end }
    UIManager:show(self._settings_dialog)
end

return InkAwayView
