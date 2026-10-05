--[[
The settings sheet (gear) and its sub-sheets: the grid and a list chooser. On a
colour screen it also sets the theme colour (see ink/accent.lua).
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
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
local function pxfmt(v) return v .. _(" px") end

-- Friendly names for the notebook paper (ruling) styles.
local TEMPLATE_LABEL = { lines = _("lined"), grid = _("grid"), dots = _("dotted"), iso = _("isometric"),
    margin = _("margin"), cornell = _("Cornell"), blank = _("blank"), checklist = _("checklist"),
    twocol = _("2 columns"), weekly = _("weekly"), monthly = _("monthly"), storyboard = _("storyboard"),
    music = _("music"), handwriting = _("handwriting"), daily = _("daily"), weekcols = _("week columns"),
    meeting = _("meeting notes"), habits = _("habit tracker") }

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

-- Use colour {r,g,b} for the buttons (black is {0,0,0}) and remember it; nil
-- goes back to the default, Ink Away green. Only the colour is kept; everything
-- drawn in it is drawn again as it is needed.
function InkAwayView:setAccent(rgb)
    self:setSetting("inkaway_accent", rgb and { rgb[1], rgb[2], rgb[3] } or nil)
    Accent.apply(rgb, self:colorScreen())
    -- what was built in the old colour: the Paste bubble, the text box's Done
    -- button and the active tool's icon (brush samples are kept by colour)
    if self._clip_widget then
        if self._clip_widget.free then self._clip_widget:free() end
        self._clip_widget = nil
    end
    local tm = self._text_btn_metrics
    if tm then
        for _, w in ipairs({ tm.fw, tm.dw }) do if w and w.free then w:free() end end
        self._text_btn_metrics = nil
    end
    -- only the toolbar shows the colour on the canvas (its active tool)
    self:updateToolbarActive()
    UIManager:setDirty(self, "ui", self.toolbar and self.toolbar.dimen or nil)
end

-- The colours last picked on the wheel, newest first (at most two). A colour in
-- use that is not among them (one chosen before they were kept) counts as the
-- newest; one that is stays where it is, so a box does not move when tapped.
function InkAwayView:accentRecent()
    local list = Accent.remember(self:getSetting("inkaway_accent_recent"), nil, 2)
    local cur = Accent.get().rgb
    if cur and not Accent.builtin(cur) then
        for _, c in ipairs(list) do if Accent.same(c, cur) then return list end end
        list = Accent.remember(list, cur, 2)
    end
    return list
end

-- Choose the theme colour on the colour wheel the pen uses; Use applies it,
-- keeps it among the last two picked, and the settings sheet comes back.
function InkAwayView:chooseAccent()
    local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
    if not ok then return end
    self:closeSheet("_settings_dialog")
    UIManager:show(ColorPicker:new{
        title = _("Theme Color"),
        color = Accent.get().rgb or Accent.PRESETS[1],
        on_pick = function(rgb)
            self:setSetting("inkaway_accent_recent", Accent.remember(self:accentRecent(), rgb, 2))
            self:setAccent(rgb)
            self:openSettings()
        end,
    })
end

-- The theme colour row: Ink Away green (the default, captioned so), black, the
-- ready-made colours, the last two picked on the wheel (empty boxes until then)
-- and the wheel, each a box the size of a swatch, spread across `width`, the one
-- in use framed. A tap uses a colour at once.
function InkAwayView:accentRow(width)
    local sw, sh = Screen:scaleBySize(56), Screen:scaleBySize(48)
    local min_gap = Screen:scaleBySize(6)
    local n = math.max(6, math.floor((width + min_gap) / (sw + min_gap)))
    local gap = math.floor((width - n * sw) / (n - 1))
    local cur = Accent.get().rgb or { 0, 0, 0 }
    local function use(rgb)
        return function()
            self:setAccent(rgb)
            self:openSettings()
        end
    end
    local green = Accent.SIGNATURE
    local tiles = {
        VerticalGroup:new{ align = "center",
            self:swatchTile(green, Accent.same(cur, green), sw, use(green), nil, sh),
            VerticalSpan:new{ width = Screen:scaleBySize(3) },
            self:sheetLabel(_("Default")) },
        self:swatchTile({ 0, 0, 0 }, Accent.same(cur, { 0, 0, 0 }), sw, use({ 0, 0, 0 }), nil, sh),
    }
    for i = 1, math.min(#Accent.PRESETS, n - 5) do
        local p = Accent.PRESETS[i]
        tiles[#tiles + 1] = self:swatchTile(p, Accent.same(cur, p), sw, use(p), nil, sh)
    end
    local recent = self:accentRecent()
    for i = 1, 2 do
        local c = recent[i]
        tiles[#tiles + 1] = c and self:swatchTile(c, Accent.same(cur, c), sw, use(c), nil, sh)
            or self:emptySlot(sw, sh)
    end
    tiles[#tiles + 1] = self:wheelTile(sw, sh, function() self:chooseAccent() end)
    local row = HorizontalGroup:new{ align = "top" }   -- (the caption hangs below)
    for i, t in ipairs(tiles) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        table.insert(row, t)
    end
    return row
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

        -- type: rows of three, Off first, then the guides and the planner pages
        local cur = self.grid_on and self.grid_style or "off"
        add(self:segmentedRow({ { "off", _("Off") }, { "square", _("Square") }, { "dots", _("Dots") } },
            cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "lines", _("Lines") }, { "iso", _("Isometric") }, { "thirds", _("Thirds") } },
            cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "checklist", _("Checklist") }, { "twocol", _("2 columns") },
            { "weekly", _("Weekly") } }, cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "monthly", _("Monthly") }, { "storyboard", _("Storyboard") },
            { "music", _("Music") } }, cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "handwriting", _("Handwriting") }, { "daily", _("Daily") },
            { "weekcols", _("Week columns") } }, cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "meeting", _("Meeting notes") }, { "habits", _("Habit tracker") },
            { "cornell", _("Cornell") } }, cur, content_w, pick))
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
    self:resetLasso()   -- drop any selection first
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

        -- the theme colour, on a colour screen
        if self:colorScreen() then
            add(self:sheetLabel(_("Theme Color"), true))
            add(vspan(6))
            add(self:accentRow(content_w))
            add(vspan(16))
            add(ToggleRow:new{ label = _("Colour while drawing"), is_on = self.live_colour,
                width = content_w, parent = menu,
                callback = function(on) self.live_colour = on; self:setSetting("inkaway_live_colour", on) end })
            add(vspan(4))
            add(self:sheetHint(_("Off: colour ink shows black until the pen rests, which reads more clearly on some colour e-ink screens."), content_w))
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
                lines = _("Lines"), iso = _("Isometric"), thirds = _("Thirds"), checklist = _("Checklist"),
                twocol = _("2 columns"), weekly = _("Weekly"), monthly = _("Monthly"),
                storyboard = _("Storyboard"), music = _("Music"), handwriting = _("Handwriting"),
                daily = _("Daily"), weekcols = _("Week columns"), meeting = _("Meeting notes"),
                habits = _("Habit tracker"), cornell = _("Cornell") }
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
        add(self:segmentedRow({ { "last", _("Last document") }, { "library", _("Library") },
                { "notebooks", _("Notebooks") } },
            self:getSetting("inkaway_start", "last"), content_w,
            function(v) self:setSetting("inkaway_start", v); self:openSettings() end))
        return content
    end
    self:showSheet("_settings_dialog", build)
end

return InkAwayView
