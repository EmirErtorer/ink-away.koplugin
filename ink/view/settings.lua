--[[
The settings sheet (gear) and its sub-sheets: the grid and a list chooser. On a
colour screen it also sets the button colour (see ink/accent.lua).
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Accent = require("ink/accent")
local Storage = require("ink/storage")
local SliderRow = require("ink/ui/controls").SliderRow

local Screen = Device.screen

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
local function pxfmt(v) return v .. _(" px") end

-- Friendly names for the notebook paper (ruling) styles.
local TEMPLATE_LABEL = { lines = _("lined"), grid = _("grid"), dots = _("dotted"),
    margin = _("margin"), cornell = _("Cornell"), blank = _("blank") }

local InkAwayView = {}

-- Choose the library folder. Picking Ink Away's own folder goes back to the
-- default.
function InkAwayView:chooseLibraryRoot()
    self:pickFolder(self:libraryDir(), function(dir)
        dir = dir:gsub("/+$", "")
        if dir == Storage.appRoot() then dir = nil end
        self:setSetting("inkaway_library_dir", dir)
        self:showNotice(string.format(_("Library folder: %s"), Storage.shortPath(self:libraryDir())))
    end)
end

-- Choose the folder exports go to. Picking "ink away/exports" goes back to the
-- default.
function InkAwayView:chooseExportRoot()
    self:pickFolder(self:defaultExportDir(), function(dir)
        dir = dir:gsub("/+$", "")
        if dir == Storage.appDir("exports") then dir = nil end
        self:setSetting("inkaway_export_dir", dir)
        self:showNotice(string.format(_("Export folder: %s"), Storage.shortPath(self:defaultExportDir())))
    end)
end

-- Use colour {r,g,b} for the buttons, or black when nil, and remember it. Only
-- the colour is kept; everything drawn in it is drawn again as it is needed.
function InkAwayView:setAccent(rgb)
    self:setSetting("inkaway_accent", rgb and { rgb[1], rgb[2], rgb[3] } or nil)
    Accent.set(self:colorScreen() and rgb or nil)
    -- what was built in the old colour: brush samples, the Paste bubble, the
    -- text box's Done button and the active tool's icon
    self:freeWaveCache()
    if self._clip_widget then
        if self._clip_widget.free then self._clip_widget:free() end
        self._clip_widget = nil
    end
    local tm = self._text_btn_metrics
    if tm then
        for _, w in ipairs({ tm.fw, tm.dw }) do if w and w.free then w:free() end end
        self._text_btn_metrics = nil
    end
    self:updateToolbarActive()
    UIManager:setDirty(self, "ui")
end

-- Choose the button colour on the colour wheel the pen uses; Use applies it and
-- the settings sheet comes back.
function InkAwayView:chooseAccent()
    local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
    if not ok then return end
    self:closeSheet("_settings_dialog")
    UIManager:show(ColorPicker:new{
        title = _("Button colour"),
        color = Accent.get().rgb or { 0x1E, 0x6F, 0xD9 },
        on_pick = function(rgb) self:setAccent(rgb); self:openSettings() end,
    })
end

-- A "pick one" sub-sheet: a stack of full-width buttons, the current one black.
-- `options` is a list of { value, label }; onpick(value) runs after it closes.
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

-- The grid sub-sheet: type, size and opacity, opened from the settings sheet's
-- Grid button. Picking a type rebuilds it in place; the sliders refresh the grid
-- behind the sheet as they move.
function InkAwayView:openGridSettings()
    if self:rebuildSheet("_grid_dialog") then return end
    local content_w = self:sheetWidth()
    -- "Off" remembers the last style, so turning the grid back on restores it.
    -- Only the type switches the grid on; size and opacity are kept for next time.
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

        -- type: two rows of three (Off and the five styles)
        local cur = self.grid_on and self.grid_style or "off"
        add(self:segmentedRow({ { "off", _("Off") }, { "square", _("Square") }, { "dots", _("Dots") } },
            cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "lines", _("Lines") }, { "iso", _("Isometric") }, { "thirds", _("Thirds") } },
            cur, content_w, pick))
        add(vspan(16))

        -- size and opacity, refreshing the grid behind the sheet as they move
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

-- The settings sheet (gear): orientation, the grid or notebook paper, the
-- symmetry and ghosting options, and where files are kept.
function InkAwayView:openSettings()
    if self.active_image then self:finishImageEdit() end   -- settle a selected image first
    -- the field may hold a dialog without a rebuild; close it and open fresh
    if self:rebuildSheet("_settings_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_settings_dialog") end
    local function act(label, w, cb, dark)
        return self:actionButton(label, w, function() closeSelf(); cb() end, dark)
    end

    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end

        add(self:sheetTitle(_("Settings"), content_w, _("Done"), closeSelf))
        add(vspan(16))

        -- orientation: picking one closes the sheet, as the screen size changes
        if self:orientationSupported() then
            add(self:sheetLabel(_("Orientation"), true))
            add(vspan(6))
            add(self:segmentedRow({ { "portrait", _("Portrait") }, { "landscape", _("Landscape") } },
                self:orientationClass(), content_w,
                function(v) closeSelf(); self:setOrientation(v) end))
            add(vspan(16))
        end

        -- the button colour, on a colour screen: a swatch of it (tap to change),
        -- Choose for the colour wheel, and Black to go back
        if self:colorScreen() then
            local a = Accent.get()
            add(self:sheetLabel(_("Button colour"), true))
            add(vspan(6))
            local gap = Screen:scaleBySize(12)
            local sw = Screen:scaleBySize(56)
            local bw = math.floor((content_w - sw - 2 * gap) / 2)
            add(HorizontalGroup:new{ align = "center",
                self:swatchTile(a.rgb or { 0, 0, 0 }, false, sw, function() self:chooseAccent() end, nil,
                    Screen:scaleBySize(48)),
                HorizontalSpan:new{ width = gap },
                self:actionButton(_("Choose\u{2026}"), bw, function() self:chooseAccent() end),
                HorizontalSpan:new{ width = gap },
                self:actionButton(_("Black"), bw, function()
                    self:setAccent(nil); self:openSettings() end, not a.custom) })
            add(vspan(16))
        end

        -- grid (canvas) or paper (notebook)
        if self.notebook then
            local t = self.notebook.template
            add(act(_("Paper: ") .. (TEMPLATE_LABEL[t.style or "lines"] or t.style), content_w, function()
                self:openPaperSheet{ title = _("Notebook paper"), current = t.style, onpick = function(v)
                    t.style = v; self.nb_style = v; self:setSetting("inkaway_nb_style", v); self:markDirty()
                    self:composeCanvas(); self:renderView(); self:refreshArea(); self:openSettings()
                end }
            end))
            add(vspan(12))
            add(SliderRow:new{ label = _("Line spacing"), value = t.size or 40, min = 12, max = 200, step = 2,
                width = content_w, parent = menu, format = pxfmt,
                on_set = function(v) t.size = v; self.nb_size = v; self:setSetting("inkaway_nb_size", v)
                    self:markDirty(); self:composeCanvas(); self:renderView(); self:refreshArea() end })
            add(vspan(10))
            add(SliderRow:new{ label = _("Line strength"), value = t.strength or 45, min = 5, max = 100, step = 5,
                width = content_w, parent = menu,
                on_set = function(v) t.strength = v; self.nb_strength = v; self:setSetting("inkaway_nb_strength", v)
                    self:markDirty(); self:composeCanvas(); self:renderView(); self:refreshArea() end })
        else
            -- one button to the grid sub-sheet, labelled with the current grid
            local GRID_LABEL = { off = _("Off"), square = _("Square"), dots = _("Dots"),
                lines = _("Lines"), iso = _("Isometric"), thirds = _("Thirds") }
            local cur = self.grid_on and self.grid_style or "off"
            add(act(_("Grid: ") .. (GRID_LABEL[cur] or cur), content_w, function()
                self:openGridSettings() end))
        end
        add(vspan(16))

        -- symmetry rebuilds the sheet in place with the highlight moved
        add(self:sheetLabel(_("Symmetry"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "off", _("Off") }, { "vert", _("Vertical") }, { "horiz", _("Horizontal") },
                { "quad", _("Four-way") } }, self.symmetry, content_w,
            function(v) self.symmetry = v; self:setSetting("inkaway_symmetry", v); self:openSettings() end))
        add(vspan(14))

        -- ghosting cleanup: a full refresh every N strokes, 0 (off) to 50 in steps of 5
        add(SliderRow:new{ label = _("Ghosting"), value = math.min(50, self.ghost_clean or 0), min = 0, max = 50, step = 5,
            width = content_w, parent = menu,
            format = function(v) return v == 0 and _("off") or string.format(_("%d strokes"), v) end,
            on_set = function(v) self.ghost_clean = v; self:setSetting("inkaway_ghost", v)
                self._strokes_since_full = 0 end })
        add(vspan(4))
        add(self:sheetHint(_("Fast strokes leave faint marks; a full refresh clears them this often."), content_w))
        add(vspan(16))

        -- where documents are kept, and what opening Ink Away shows
        add(self:sheetLabel(_("Files"), true))
        add(vspan(6))
        add(act(_("Library folder: ") .. Storage.baseName(self:libraryDir()), content_w,
            function() self:chooseLibraryRoot() end))
        add(vspan(8))
        add(act(_("Export folder: ") .. Storage.baseName(self:defaultExportDir()), content_w,
            function() self:chooseExportRoot() end))
        add(vspan(10))
        add(self:sheetLabel(_("When Ink Away opens")))
        add(vspan(6))
        add(self:segmentedRow({ { "last", _("Last document") }, { "library", _("Library") } },
            self:getSetting("inkaway_start", "last"), content_w,
            function(v) self:setSetting("inkaway_start", v); self:openSettings() end))
        return content
    end
    self:showSheet("_settings_dialog", build)
end

return InkAwayView
