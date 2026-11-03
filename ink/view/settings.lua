--[[
The settings list (gear) and its sub-lists: the grid, the theme colour and the
appearance, all on KOReader's own Menu (see ink/view/nativemenu.lua). On a
colour screen it also sets the theme colour (see ink/accent.lua).
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local PenTest = require("ink/pentest")
local Theme = require("ink/ui/theme")
local Palette = require("ink/palette")
local Storage = require("ink/storage")

local Screen = Device.screen

local function pxfmt(v) return v .. _(" px") end
local function hex(c) return string.format("#%02X%02X%02X", c[1], c[2], c[3]) end

-- Friendly names for the notebook paper (ruling) styles.
local TEMPLATE_LABEL = { lines = _("lined"), grid = _("grid"), dots = _("dotted"), iso = _("isometric"),
    margin = _("margin"), cornell = _("Cornell"), blank = _("blank"), checklist = _("checklist"),
    twocol = _("2 columns"), weekly = _("weekly"), monthly = _("monthly"), storyboard = _("storyboard"),
    music = _("music"), handwriting = _("handwriting"), daily = _("daily"), weekcols = _("week columns"),
    meeting = _("meeting notes"), habits = _("habit tracker") }

-- The grid types, in the order they are offered.
local GRID_OPTIONS = {
    { "off", _("Off") }, { "square", _("Square") }, { "dots", _("Dots") },
    { "lines", _("Lines") }, { "iso", _("Isometric") }, { "thirds", _("Thirds") },
    { "checklist", _("Checklist") }, { "twocol", _("2 columns") }, { "weekly", _("Weekly") },
    { "monthly", _("Monthly") }, { "storyboard", _("Storyboard") }, { "music", _("Music") },
    { "handwriting", _("Handwriting") }, { "daily", _("Daily") }, { "weekcols", _("Week columns") },
    { "meeting", _("Meeting notes") }, { "habits", _("Habit tracker") }, { "cornell", _("Cornell") },
}

-- The names of the ready-made theme colours (Accent.PRESETS, in order).
local PRESET_NAMES = { _("Blue"), _("Teal"), _("Red"), _("Purple"), _("Orange") }

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

-- Choose the theme colour: Ink Away green (the default), black, the ready-made
-- colours, the last two picked on the wheel, and the wheel. A choice is used at
-- once and the settings come back.
function InkAwayView:openThemeColour()
    local cur = Accent.get().rgb or { 0, 0, 0 }
    local list = {}
    local function add(name, rgb)
        list[#list + 1] = { label = (Accent.same(cur, rgb) and self.CHOSEN or "") .. name,
            cb = function() self:setAccent(rgb); self:openSettings() end }
    end
    add(_("Default"), Accent.SIGNATURE)
    add(_("Black"), { 0, 0, 0 })
    for i, p in ipairs(Accent.PRESETS) do add(PRESET_NAMES[i] or hex(p), p) end
    for _i, c in ipairs(self:accentRecent()) do add(hex(c), c) end
    list[#list + 1] = { label = _("Colour wheel"), cb = function() self:chooseAccent() end }
    self:chooseFromList{ field = "_theme_colour", title = _("Theme Color"), items = list }
end

-- The grid sub-list: type, size and opacity, opened from the settings' Grid
-- row. Each change shows at once on the grid behind it; closing it goes back to
-- the settings.
function InkAwayView:openGridSettings()
    if self._grid_dialog and self._grid_dialog.refresh then self._grid_dialog.refresh(); return end
    self:openNativeMenu{ field = "_grid_dialog", title = _("Grid"),
        back = function() self:openSettings("paper") end,
        items = function()
            return {
                -- "Off" remembers the last style, so turning the grid back on restores it.
                -- Only the type switches the grid on; size and opacity are kept for next time.
                { text = _("Grid"), separator = true, choice = { options = GRID_OPTIONS,
                    get = function() return self.grid_on and self.grid_style or "off" end,
                    set = function(v)
                        if v == "off" then
                            self.grid_on = false; self:setSetting("inkaway_grid", false)
                        else
                            self.grid_style = v; self:setSetting("inkaway_grid_style", v)
                            self.grid_on = true; self:setSetting("inkaway_grid", true)
                        end
                        self:renderView(); self:refreshArea()
                    end } },
                { text = _("Size"), number = { min = 8, max = 200, step = 2, format = pxfmt,
                    get = function() return self.grid_size end,
                    set = function(v) self.grid_size = v; self:setSetting("inkaway_grid_size", v)
                        self:renderView(); self:refreshArea() end } },
                { text = _("Opacity"), number = { min = 5, max = 100, step = 5,
                    get = function() return self.grid_strength end,
                    set = function(v) self.grid_strength = v; self:setSetting("inkaway_grid_strength", v)
                        self:renderView(); self:refreshArea() end } },
            }
        end }
end

-- Put the zoom and Pan buttons at the "right" or "left", or hide them.
function InkAwayView:setFabSide(side)
    self.fab_side = side
    self:setSetting("inkaway_fab_side", side)
    self._blit_rect = nil
    UIManager:setDirty(self, "ui")
    self:openSettings()
end

-- Light, dark or as KOReader's night mode: Ink Away's own controls (see
-- ink/ui/theme.lua). The page is never changed.
local function appearanceRow(self)
    return { text = _("Appearance"),
        help = _("Dark turns Ink Away's toolbars and menus dark; the page stays as it is. System follows KOReader's night mode."),
        choice = { options = { { "light", _("Light") }, { "dark", _("Dark") }, { "system", _("System") } },
            get = function() return Theme.mode() end,
            set = function(m)
                self:setSetting(Theme.SETTING, m)
                self._paint_all = true
                UIManager:setDirty("all", "ui")
            end } }
end

-- The settings (gear): a panel with tabs. Toolbar: orientation, the toolbar and
-- the zoom and Pan buttons. Appearance: light or dark, and the theme colour.
-- Paper: the grid or notebook paper, and symmetry. More: ghosting, where files
-- are kept, and the other sheets.
function InkAwayView:openSettings(tab)
    self:resetLasso()   -- drop any selection first
    self:ensureUserIcons()
    self:openNativeMenu{ field = "_settings_dialog", title = _("Settings"), tab = tab,
        tabs = { { "bar", _("Toolbar") }, { "look", _("Appearance") }, { "paper", _("Paper") }, { "more", _("More") } },
        items = function()
        local rows = {}
        local function add(tab_id, r) r.tab = tab_id; rows[#rows + 1] = r end
        -- news from the update check, on top
        if self:updateNews() then
            add("more", { text = _("Updates"), value = "\u{25CF}", close = true, action = function() self:openUpdates() end })
        end
        -- orientation: picking one closes the panel, as the screen size changes
        if self:orientationSupported() then
            add("bar", { text = _("Orientation"), choice = { options = { { "portrait", _("Portrait") }, { "landscape", _("Landscape") } },
                get = function() return self:orientationClass() end,
                set = function(v) self:closeSheet("_settings_dialog"); self:setOrientation(v) end } })
        end
        -- the toolbar: across the top, or down the left or right of the screen
        add("bar", { text = _("Toolbar"), choice = { options = { { "top", _("Top") }, { "left", _("Left") }, { "right", _("Right") } },
            get = function() return self:canvasBarSide() end,
            set = function(side) self:closeSheet("_settings_dialog"); self:setCanvasBarSide(side); self:openSettings("bar") end } })
        -- the zoom and Pan buttons: at either side, or none (pinch and two fingers do the same)
        add("bar", { text = _("Zoom and Pan buttons"), help = _("Pinch to zoom, and drag with two fingers to move around the page."),
            choice = { options = { { "right", _("Right") }, { "left", _("Left") }, { "hidden", _("Hidden") } },
                get = function() return self.fab_side end,
                set = function(side) self:setFabSide(side) end } })
        add("look", appearanceRow(self))
        -- the theme colour, on a colour screen
        if self:colorScreen() then
            add("look", { text = _("Theme Color"), submenu = function() self:openThemeColour() end,
                value = function() local rgb = Accent.get().rgb; return rgb and hex(rgb) or _("Default") end })
            add("look", { text = _("Colour while drawing"),
                help = _("Off: colour ink shows black until the pen rests, which reads more clearly on some colour e-ink screens."),
                toggle = { get = function() return self.live_colour end,
                    set = function(on) self.live_colour = on; self:setSetting("inkaway_live_colour", on) end } })
            add("look", { text = _("Keep colours in night mode"),
                help = _("In KOReader's night mode, ink keeps its colour: blue stays blue, and dark ink turns light so it reads on the dark page."),
                toggle = { get = function() return self:getSetting("inkaway_night_colours", true) ~= false end,
                    set = function(on) self:setSetting("inkaway_night_colours", on); self:nightModeChanged(true) end } })
        end
        -- grid (canvas) or paper (notebook), and beside it the paper's colour
        local paper_name = Palette.paperName(self:paperRGB())
        if self.notebook then
            local t = self.notebook.template
            add("paper", { text = _("Paper"), value = TEMPLATE_LABEL[t.style or "lines"] or t.style, submenu = function()
                self:closeSheet("_settings_dialog")
                self:openPaperSheet{ title = _("Notebook paper"), current = t.style, onpick = function(v)
                    t.style = v; self.nb_style = v; self:setSetting("inkaway_nb_style", v); self:markDirty()
                    self:composeCanvas(); self:renderView(); self:refreshArea(); self:openSettings("paper")
                end }
            end })
            add("paper", { text = _("Colour"), value = paper_name, submenu = function() self:openPaperColour() end })
            add("paper", { text = _("Line spacing"), number = { min = 12, max = 200, step = 2, format = pxfmt,
                get = function() return t.size or 40 end,
                set = function(v) t.size = v; self.nb_size = v; self:setSetting("inkaway_nb_size", v)
                    self:markDirty(); self:composeCanvas(); self:renderView(); self:refreshArea() end } })
            add("paper", { text = _("Line strength"), number = { min = 5, max = 100, step = 5,
                get = function() return t.strength or 45 end,
                set = function(v) t.strength = v; self.nb_strength = v; self:setSetting("inkaway_nb_strength", v)
                    self:markDirty(); self:composeCanvas(); self:renderView(); self:refreshArea() end } })
        else
            local cur = self.grid_on and self.grid_style or "off"
            local label
            for _i, o in ipairs(GRID_OPTIONS) do if o[1] == cur then label = o[2] end end
            add("paper", { text = _("Grid"), value = label or cur, submenu = function()
                self:closeSheet("_settings_dialog"); self:openGridSettings() end })
            add("paper", { text = _("Paper colour"), value = paper_name, submenu = function() self:openPaperColour() end })
        end
        add("paper", { text = _("Symmetry"), choice = { options = { { "off", _("Off") }, { "vert", _("Vertical") },
                { "horiz", _("Horizontal") }, { "quad", _("Four-way") } },
            get = function() return self.symmetry end,
            set = function(v) self.symmetry = v; self:setSetting("inkaway_symmetry", v) end } })
        -- ghosting cleanup: a full refresh every N strokes, 0 (off) to 50 in steps of 5
        add("more", { text = _("Ghosting"), help = _("Fast strokes leave faint marks; a full refresh clears them this often."),
            number = { min = 0, max = 50, step = 5,
                format = function(v) return v == 0 and _("off") or string.format(_("%d strokes"), v) end,
                get = function() return math.min(50, self.ghost_clean or 0) end,
                set = function(v) self.ghost_clean = v; self:setSetting("inkaway_ghost", v)
                    self._strokes_since_full = 0 end } })
        -- one full refresh now, as the "Refresh the screen" gesture does
        add("more", { text = _("Refresh the screen"), close = true, action = function() self:refreshScreen() end })
        -- where documents are kept, and what opening Ink Away shows
        add("more", { text = _("Library"), value = Storage.baseName(self:libraryDir()), close = true,
            action = function() self:chooseLibraryRoot() end })
        add("more", { text = _("Export"), value = Storage.baseName(self:defaultExportDir()), close = true,
            action = function() self:chooseExportRoot() end })
        add("more", { text = _("When Ink Away opens"), choice = { options = { { "last", _("Last document") },
                { "library", _("Library") }, { "notebooks", _("Notebooks") } },
            get = function() return self:getSetting("inkaway_start", "last") end,
            set = function(v) self:setSetting("inkaway_start", v) end } })
        -- (palm rejection, the stabilizer and the pen test are in the Pen
        -- sheet's Pen and input, set from where the pen is)
        add("more", { text = _("Gestures and pen buttons"), close = true, action = function() self:openGestureSettings() end })
        add("more", { text = _("Updates"), close = true, action = function() self:openUpdates() end })
        add("more", { text = _("Guide"), close = true, action = function() self:openGuide() end })
        add("more", { text = _("Support"), close = true, action = function() self:openSupport() end })
        return rows
    end }
end

-- The appearance on its own (from the guide, or the book's settings).
function InkAwayView:openAppearance()
    self:closeSheet("_settings_dialog")
    self:openNativeMenu{ field = "_appearance", title = _("Appearance"),
        back = function() self:openSettings() end,
        items = function() return { appearanceRow(self) } end }
end

-- A quiet note from the maker, one tap from Settings: a few plain words, and
-- a QR code for the coffee page where KOReader can draw one.
local SUPPORT_URL = "https://buymeacoffee.com/emirertorer"
function InkAwayView:openSupport()
    self:closeSheet("_settings_dialog")
    local okq, QRMessage = pcall(require, "ui/widget/qrmessage")
    self:ask{ field = "_support", title = _("Support"),
        text = _("Ink Away is free and made by one person. If it makes your writing better, a coffee helps keep it going.")
            .. "\n\n" .. SUPPORT_URL,
        ok_text = okq and QRMessage and _("Scan with your phone") or _("Done"),
        cancel_text = _("Close"),
        on_ok = function()
            if okq and QRMessage then
                local side = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.6)
                UIManager:show(QRMessage:new{ text = SUPPORT_URL, width = side, height = side })
            end
        end }
end

-- The faster-drawing tip for this reader, or nil: none where KOReader drives
-- the panel fully. When `auto` (shown unasked), none on a Boox either, where Ink
-- Away asks for the fast refresh itself (unless the reader turned that off).
function InkAwayView:deviceTipText(auto)
    if not self:onAndroid() then return nil end
    local ok, facts = pcall(function() return require("ink/ui/pentestscreen").deviceFacts() end)
    if not ok then return nil end
    if auto and facts.boox and self:getSetting("inkaway_boox_fast", true) ~= false then return nil end
    return PenTest.androidTip(facts)
end

-- The faster-drawing tip for Android readers whose panel KOReader can't fully
-- drive: shown once by itself where it is still needed, or again on request
-- (`again`).
function InkAwayView:deviceTips(again)
    if not again and self:getSetting("inkaway_device_tip_shown") then return end
    local tip = self:deviceTipText(not again)
    if not tip then
        if again then self:tell(_("This reader needs no special settings for Ink Away.")) end
        return
    end
    self:setSetting("inkaway_device_tip_shown", true)
    self:tell(_(tip))
end

-- The pen and touch test, full screen. The canvas stops drawing from fingers
-- while it is open (the test watches them itself), and gets its pen back after.
function InkAwayView:openPenTest()
    self:closeSheet("_settings_dialog")
    local PenTestScreen = require("ink/ui/pentestscreen")
    local raw = self._raw_installed
    if raw then self:uninstallRawFinger() end
    UIManager:show(PenTestScreen:new{ on_close = function()
        if raw and not self.closing then self:installRawFinger() end
        self:applyPalmReject()
    end })
end

return InkAwayView
