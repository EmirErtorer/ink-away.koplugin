--[[
The settings sheet (gear) and its sub-sheets: grid, background image and a list
chooser.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local SliderRow = require("ink/ui/controls").SliderRow

local Screen = Device.screen

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
local function pxfmt(v) return v .. _(" px") end

local InkAwayView = {}

function InkAwayView:openBackground()
    self:closeSheet("_bg_dialog")
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_bg_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Background image"), content_w, _("Done"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("Open image as background"), content_w,
            function() closeSelf(); self:chooseBackground() end))
        if self.bg_bb then
            add(vspan(8))
            add(self:actionButton(_("Remove background"), content_w,
                function() closeSelf(); self:removeBackground() end, true))
        end
        add(vspan(12))
        local hint = self.bg_bb
            and _("At save time you can include the picture or export just your drawing. The grid is always left out.")
            or _("Draw over a photo or screenshot; your drawing sits on top. To draw on a PDF, use \u{201C}Open PDF as notebook\u{201D} instead.")
        add(self:sheetHint(hint, content_w, 15))
        return content
    end
    self:showSheet("_bg_dialog", build)
end

-- Friendly names for the notebook paper (ruling) styles.
local TEMPLATE_LABEL = { lines = _("lined"), grid = _("grid"), dots = _("dotted"),
    margin = _("margin"), cornell = _("Cornell"), blank = _("blank") }

-- A generic "pick one of a list" sub-sheet in the shapes-menu style: a vertical
-- stack of full-width buttons, the current one filled black. `options` is a list
-- of { value, label }; onpick(value) is called after the sheet closes.
function InkAwayView:openChooserSheet(title, options, current, onpick)
    self:closeSheet("_chooser_dialog")
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_chooser_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(title, content_w, _("Done"), closeSelf))
        add(vspan(16))
        for i, o in ipairs(options) do
            if i > 1 then add(vspan(8)) end
            add(self:actionButton(o[2], content_w,
                function() closeSelf(); onpick(o[1]) end, current == o[1]))
        end
        return content
    end
    self:showSheet("_chooser_dialog", build)
end

-- The grid sub-sheet: type, size and opacity in one place, opened from the main
-- settings sheet's single "Grid" button so that sheet stays short (no scrolling).
-- Picking a type rebuilds this sheet in place (the highlight moves) like the other
-- segmented pickers; the sliders drive the same live grid refresh the old inline
-- controls did, and it wears the same rounded-corner sheet chrome as every sheet.
function InkAwayView:openGridSettings()
    if self:rebuildSheet("_grid_dialog") then return end
    local content_w = self:sheetWidth()
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
        add(self:sheetTitle(_("Grid"), content_w, _("Done"),
            function() self:closeSheet("_grid_dialog"); self:openSettings() end))
        add(vspan(16))

        -- type: two tidy rows of three (Off + the five styles)
        local cur = self.grid_on and self.grid_style or "off"
        add(self:segmentedRow({ { "off", _("Off") }, { "square", _("Square") }, { "dots", _("Dots") } },
            cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "lines", _("Lines") }, { "iso", _("Isometric") }, { "thirds", _("Thirds") } },
            cur, content_w, pick))
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
        return content
    end
    self:showSheet("_grid_dialog", build)
end

-- The gear menu (shapes-menu style): file/page actions as buttons, the grid or
-- notebook-paper controls as a toggle/chooser and sliders, and symmetry /
-- autosave as segmented rows. Reorganised into clear sections.
function InkAwayView:openSettings()
    if self.active_image then self:finishImageEdit() end   -- settle a selected image first
    -- `_settings_dialog` is normally this settings IconMenu (rebuild in place), but a
    -- few transient ButtonDialogs (Page menu, page overview) reuse the field and have
    -- no rebuild -- drop such a one and open fresh instead of crashing.
    if self:rebuildSheet("_settings_dialog") then return end
    self:ensureUserIcons()
    local content_w, gap = self:sheetWidth()
    local halfW = math.floor((content_w - gap) / 2)
    local closeSelf = function() self:closeSheet("_settings_dialog") end
    local function act(label, w, cb, dark, big)
        return self:actionButton(label, w, function() closeSelf(); cb() end, dark, big)
    end

    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        local function row2(a, b)
            return HorizontalGroup:new{ align = "center", a, HorizontalSpan:new{ width = gap }, b }
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
            add(self:sheetLabel(_("Orientation"), true))
            add(vspan(6))
            add(self:segmentedRow({ { "portrait", _("Portrait") }, { "landscape", _("Landscape") } },
                self:orientationClass(), content_w,
                function(v) closeSelf(); self:setOrientation(v) end))
            add(vspan(16))
        end

        -- grid (canvas) or paper (notebook)
        if self.notebook then
            local t = self.notebook.template
            add(act(_("Paper: ") .. (TEMPLATE_LABEL[t.style or "lines"] or t.style), content_w, function()
                self:openChooserSheet(_("Notebook paper"), self:notebookStyles(), t.style, function(v)
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

        -- symmetry and autosave pick in place: the sheet stays open and rebuilds
        -- with the highlight moved (refreshing just this region, no flash)
        add(self:sheetLabel(_("Symmetry"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "off", _("Off") }, { "vert", _("Vertical") }, { "horiz", _("Horizontal") },
                { "quad", _("Four-way") } }, self.symmetry, content_w,
            function(v) self.symmetry = v; self:setSetting("inkaway_symmetry", v); self:openSettings() end))
        add(vspan(14))

        -- ghosting cleanup slider (0 = off). 0-50 in 5s: a small range is easier to
        -- pinpoint, and clearing every >50 strokes is effectively never anyway.
        add(SliderRow:new{ label = _("Ghosting"), value = math.min(50, self.ghost_clean or 0), min = 0, max = 50, step = 5,
            width = content_w, parent = menu,
            format = function(v) return v == 0 and _("off") or string.format(_("%d strokes"), v) end,
            on_set = function(v) self.ghost_clean = v; self:setSetting("inkaway_ghost", v)
                self._strokes_since_full = 0 end })
        add(vspan(4))
        add(self:sheetHint(_("Fast strokes leave faint marks; a full refresh clears them this often."), content_w))
        add(vspan(14))

        add(self:sheetLabel(_("Autosave"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "off", _("Off") }, { "exit", _("On exit") }, { "periodic", _("Every 3 min") } },
            self.autosave, content_w, function(v) self:setAutosave(v); self:openSettings() end))
        return content
    end
    self:showSheet("_settings_dialog", build)
end

return InkAwayView
