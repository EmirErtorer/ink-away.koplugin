--[[
InkAwayView, the fullscreen finger drawing canvas.

The layout is a thin toolbar across the top with the drawing area filling the
rest. The drawing area shows the fixed W x H canvas at the current zoom and pan.
The exported image is always the full W x H, whatever is on screen.

How it draws: the committed strokes are the source of truth. To show them, they
are replayed in screen space into one reused Blitbuffer the size of the area
(`area_bb`). paintTo just copies that buffer onto the screen, so a refresh is
cheap. A new stroke segment is stamped straight into `area_bb` and only its
small changed rectangle is refreshed. The big RGBA export buffer, which is the
full canvas size, is built only when you save and is never kept around.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

-- Grey shades, the primary choice on e-ink. Ordered dark to light.
local SHADES = {
    { name = _("Black"),      rgb = { 0x00, 0x00, 0x00 } },
    { name = _("Dark grey"),  rgb = { 0x44, 0x44, 0x44 } },
    { name = _("Grey"),       rgb = { 0x88, 0x88, 0x88 } },
    { name = _("Light grey"), rgb = { 0xBB, 0xBB, 0xBB } },
    { name = _("White"),      rgb = { 0xFF, 0xFF, 0xFF } },
}

-- Colours, offered only on colour screens (colour e-ink, Android, desktop).
local COLORS = {
    { name = _("Red"),    rgb = { 0xD0, 0x00, 0x00 } },
    { name = _("Orange"), rgb = { 0xE0, 0x70, 0x00 } },
    { name = _("Yellow"), rgb = { 0xE8, 0xC0, 0x00 } },
    { name = _("Green"),  rgb = { 0x00, 0x90, 0x00 } },
    { name = _("Blue"),   rgb = { 0x00, 0x50, 0xD0 } },
    { name = _("Purple"), rgb = { 0x80, 0x00, 0xB0 } },
}

local Canvas = require("ink/canvas")
local InkGeom = require("ink/geom")
local Raster = require("ink/raster")
local Shapes = require("ink/shapes")
local Fill = require("ink/fill")
local Export = require("ink/export")
local Project = require("ink/project")

local Screen = Device.screen

-- Remembered across saves within a KOReader session (module scope).
local last_save_dir = nil

local WHITE = Blitbuffer.COLOR_WHITE
local FRAME = Blitbuffer.COLOR_GRAY   -- colour of the frame around the page

-- When the finger lifts, wait this long before committing the stroke. If a
-- fresh touch lands nearby within the window, treat it as the SAME stroke.
-- Touch panels on these readers often drop and reacquire a finger in the middle
-- of a line, and this is what keeps one lift as one undo step, keeps exported
-- strokes whole, and fills the gap a dropped contact would otherwise leave.
local COALESCE_SEC = 0.15
local ZOOM_RATIO = 1.5    -- one zoom press multiplies by this, for even steps
local ZOOM_MAX = 8.0

-- A grey that, over the white canvas, looks like black ink at the given alpha,
-- so the display matches the exported PNG and JPEG. alpha 255 is black, 0 white.
-- On-screen colour for ink of rgb {r,g,b} drawn at opacity `alpha`, composited
-- over the white canvas so the display matches the exported image. rgb defaults
-- to black. On a grey e-ink panel the blitter turns the result into the right
-- shade; on a colour screen it shows in colour.
local function displayColor(rgb, alpha)
    local a = alpha or 255
    local r = rgb and rgb[1] or 0
    local g = rgb and rgb[2] or 0
    local b = rgb and rgb[3] or 0
    local function over(c) return math.floor(255 - a * (255 - c) / 255 + 0.5) end
    return Blitbuffer.ColorRGB32(over(r), over(g), over(b), 0xFF)
end

-- A span writer that paints horizontal runs into `bb`, clipped to w x h, and
-- (optionally) grows `acc` to cover everything it touched. Shared by the 1:1
-- master bitmap and the on-screen buffer so both are stamped the same way.
local function spanWriter(bb, w, h, color, acc)
    return function(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        bb:paintRect(x, y, len, 1, color)
        if acc then
            if x < acc.x0 then acc.x0 = x end
            if x + len > acc.x1 then acc.x1 = x + len end
            if y < acc.y0 then acc.y0 = y end
            if y + 1 > acc.y1 then acc.y1 = y + 1 end
        end
    end
end

local InkAwayView = InputContainer:extend{
    name = "inkaway_view",
    covers_fullscreen = true,
    -- The canvas is modal: swallow any gesture a toolbar button did not take
    -- (pinch, double tap, multiswipe, and so on) so the view under it stays put.
    stop_events_propagation = true,
}

------------------------------------------------------------------------------
-- Small geometry helpers
------------------------------------------------------------------------------

function InkAwayView:inArea(x, y)
    local v = self.view
    return x >= v.area_x and x < v.area_x + v.area_w
       and y >= v.area_y and y < v.area_y + v.area_h
end

-- screen -> canvas, clamped to the canvas bounds
function InkAwayView:toCanvasClamped(sx, sy)
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    if cx < 0 then cx = 0 elseif cx > self.view.canvas_w then cx = self.view.canvas_w end
    if cy < 0 then cy = 0 elseif cy > self.view.canvas_h then cy = self.view.canvas_h end
    return cx, cy
end

-- canvas to area coordinates (origin at the area's top left corner, i.e. area_bb)
function InkAwayView:toAreaLocal(cx, cy)
    local v = self.view
    return (cx - v.pan_x) * v.zoom, (cy - v.pan_y) * v.zoom
end

-- Snap a screen point to the grid (in canvas space) when grid snapping is on.
function InkAwayView:snapScreen(sx, sy)
    if not self.snap_grid then return sx, sy end
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    cx, cy = InkGeom.snapToGrid(cx, cy, self.grid_size)
    return InkGeom.toScreen(self.view, cx, cy)
end

------------------------------------------------------------------------------
-- Preferences (kept in KOReader's global settings so they persist)
------------------------------------------------------------------------------

function InkAwayView:getSetting(key, default)
    local G = rawget(_G, "G_reader_settings")
    if G and G.readSetting then
        local v = G:readSetting(key)
        if v ~= nil then return v end
    end
    return default
end

function InkAwayView:setSetting(key, value)
    local G = rawget(_G, "G_reader_settings")
    if G and G.saveSetting then G:saveSetting(key, value) end
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function InkAwayView:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = W, H
    self.dimen = GeomUI:new{ x = 0, y = 0, w = W, h = H }
    self.closing = false
    self.tool = "pen"          -- "pen" | "erase" | "pan" | "shape"
    self.capturing = false     -- a pen/erase stroke is in progress
    self.pending_lift = nil    -- {x,y}: finger lifted, stroke not yet committed
    self.pan_last = nil        -- last point of a pan drag in progress (screen)

    -- Shapes: the chosen shape and whether it is filled; drag/preview state.
    self.shape = "rect"        -- "line"|"curve"|"rect"|"ellipse"|"triangle"
    self.shape_fill = false
    self.shape_drag = nil      -- {x0,y0,x1,y1} in screen coords, while stretching
    self.curve_stage = nil     -- nil | "bend" (second phase of the curve tool)
    self.shape_preview = nil   -- op (screen coords) drawn on top in paintTo
    self._preview_rect = nil   -- last previewed screen rect, for tidy refreshes
    self.selected = nil        -- {op, idx}: shape picked by a long press
    self.rotating = nil        -- rotation-in-progress state

    -- Pen: width in canvas pixels (constant thickness in the export regardless
    -- of zoom) and opacity 0-255. The eraser is a good deal fatter.
    self.pen_width = 15               -- canvas px; a comfortable default
    self.pen_alpha = 255
    self.pen_color = { 0x00, 0x00, 0x00 }   -- {r,g,b}; black to start
    self.fill_color = { 0x88, 0x88, 0x88 }  -- paint bucket has its own colour...
    self.fill_alpha = 255                   -- ...and opacity, set from its menu
    self.eraser_width = 40            -- canvas px; adjustable, like the pen
    -- How close a fresh touch must land (screen px) to count as the same stroke.
    self.bridge_dist = math.max(24, math.floor(W / 22))

    -- Preferences and drawing aids, loaded from saved settings.
    self.pen_style   = self:getSetting("inkaway_pen_style", "solid")   -- solid|pencil|charcoal|marker
    self.stabilizer  = self:getSetting("inkaway_stabilizer", 40)       -- 0..100
    self.grid_on     = self:getSetting("inkaway_grid", false)
    self.grid_style  = self:getSetting("inkaway_grid_style", "square")  -- square|dots|lines|iso|thirds
    self.grid_size   = self:getSetting("inkaway_grid_size", math.max(24, math.floor(W / 16)))
    self.snap_grid   = self:getSetting("inkaway_snap_grid", false)
    self.snap_angle  = self:getSetting("inkaway_snap_angle", false)
    self.autosave    = self:getSetting("inkaway_autosave", "exit")     -- off|exit|periodic
    self.dirty = false
    self._autosave_tick = function() self:autosaveTick() end

    -- The canvas has a fixed size: the current screen dimensions.
    self.canvas = Canvas.new(W, H)

    -- Bound once so it can be scheduled and unscheduled by identity.
    self._finalize = function() self:finalizeStroke() end

    self:buildToolbar()
    local th = self.toolbar:getSize().h
    self.view = {
        area_x = 0, area_y = th, area_w = W, area_h = H - th,
        canvas_w = W, canvas_h = H,
        zoom = 1, pan_x = 0, pan_y = 0,
    }
    self.zoom_min = InkGeom.fitZoom(self.view)
    self.view.zoom = self.zoom_min              -- start fitted to the page
    InkGeom.clampPan(self.view)

    -- self[1] lets gesture events propagate to the toolbar buttons; the actual
    -- painting is done by our own paintTo.
    self[1] = self.toolbar

    if Device:isTouchDevice() then
        local full = self.dimen
        -- Ranged across the whole screen so we always get the lift even if the finger
        -- strays; the handlers gate on the area rect and the active tool.
        self.ges_events = {
            IaTouch      = { GestureRange:new{ ges = "touch",        range = full } },
            IaPan        = { GestureRange:new{ ges = "pan",          range = full } },
            IaHoldPan    = { GestureRange:new{ ges = "hold_pan",     range = full } },
            IaPanRelease = { GestureRange:new{ ges = "pan_release",  range = full } },
            IaHoldRel    = { GestureRange:new{ ges = "hold_release", range = full } },
            IaSwipe      = { GestureRange:new{ ges = "swipe",        range = full } },
            IaTap        = { GestureRange:new{ ges = "tap",          range = full } },
            IaHold       = { GestureRange:new{ ges = "hold",         range = full } },
            IaTwoPan     = { GestureRange:new{ ges = "two_finger_pan", range = full } },
            IaTwoPanRel  = { GestureRange:new{ ges = "two_finger_pan_release", range = full } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { IaClose = { { Device.input.group.Back } } }
    end

    -- Two buffers, both reused for the whole session:
    --  * canvas_bb is the drawing at 1:1 (the full canvas size). Strokes are
    --    stamped here once, at their real size, independent of zoom.
    --  * area_bb is what actually shows on screen. Zoom and pan just scale a
    --    crop of canvas_bb into it (a fast mupdf blit), so their cost depends
    --    only on the screen size, never on how much has been drawn or how far
    --    it is zoomed in.
    local bbtype = Screen.bb:getType()
    self.canvas_bb = Blitbuffer.new(self.view.canvas_w, self.view.canvas_h, bbtype)
    self.area_bb = Blitbuffer.new(self.view.area_w, self.view.area_h, bbtype)

    self:restoreSession()   -- reopen the last drawing if one was kept
    self:composeCanvas()
    self:renderView()
    self:scheduleAutosave()
end

------------------------------------------------------------------------------
-- Projects and autosave
------------------------------------------------------------------------------

-- Path of the kept "last session" file.
function InkAwayView:sessionPath()
    local ok, DataStorage = pcall(require, "datastorage")
    local dir = (ok and DataStorage and DataStorage:getSettingsDir()) or "/tmp"
    return dir .. "/inkaway_session." .. Project.EXT
end

-- Load ops from a project into the canvas, if they fit this screen. Returns ok.
function InkAwayView:loadProjectData(data)
    if not data or not data.ops then return false end
    self.canvas:setOps(data.ops)
    self.selected, self.rotating = nil, nil
    self.dirty = false
    return true
end

function InkAwayView:restoreSession()
    if self.autosave == "off" then return end
    local data = Project.load(self:sessionPath())
    if data then self:loadProjectData(data) end
end

function InkAwayView:saveSession()
    if self.canvas:isEmpty() then return end
    Project.save(self.canvas, self:sessionPath())
end

function InkAwayView:scheduleAutosave()
    UIManager:unschedule(self._autosave_tick)
    if self.autosave == "periodic" then
        UIManager:scheduleIn(180, self._autosave_tick)   -- every 3 minutes
    end
end

function InkAwayView:autosaveTick()
    if self.closing then return end
    if self.dirty then self:saveSession(); self.dirty = false end
    self:scheduleAutosave()
end

function InkAwayView:free()
    if self.area_bb then self.area_bb:free(); self.area_bb = nil end
    if self.canvas_bb then self.canvas_bb:free(); self.canvas_bb = nil end
end

function InkAwayView:onShow()
    UIManager:setDirty(self, "full")
    return true
end

-- Screen size changed, from a rotation or a window resize. The canvas keeps the
-- pixel size it had when it opened, since the export size is fixed at that
-- point, so all we do here is rebuild the toolbar and viewport and refit the page.
function InkAwayView:relayout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = W, H
    self.dimen.w, self.dimen.h = W, H     -- mutate in place; GestureRanges hold it
    self:buildToolbar()
    self[1] = self.toolbar
    local th = self.toolbar:getSize().h
    local v = self.view
    v.area_x, v.area_y, v.area_w, v.area_h = 0, th, W, H - th
    self.zoom_min = InkGeom.fitZoom(v)
    v.zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, v.zoom))
    InkGeom.clampPan(v)
    -- the canvas keeps its size; only the on-screen buffer follows the screen
    if self.area_bb then self.area_bb:free() end
    self.area_bb = Blitbuffer.new(v.area_w, v.area_h, Screen.bb:getType())
    self:renderView()
end

function InkAwayView:onSetDimensions()
    self:relayout()
    UIManager:setDirty(self, "full")
end

function InkAwayView:onCloseWidget()
    self.closing = true
    UIManager:unschedule(self._finalize)
    UIManager:unschedule(self._autosave_tick)
    if self.autosave ~= "off" then self:saveSession() end
    -- Leave the screen clean underneath.
    UIManager:setDirty(nil, "full")
    self:free()
end

function InkAwayView:onIaClose()
    self:promptExit()
    return true
end

------------------------------------------------------------------------------
-- Toolbar
------------------------------------------------------------------------------

function InkAwayView:buildToolbar()
    local specs = {
        -- tapping a tool when it is already active opens its settings
        { id = "pen",   label = _("Pen"),   tool = true, cb = function()
            if self.tool == "pen" then self:openPenSettings() else self:setTool("pen") end
        end },
        { id = "erase", label = _("Erase"), tool = true, cb = function()
            if self.tool == "erase" then self:openEraserSettings() else self:setTool("erase") end
        end },
        { id = "shape", label = _("Shapes"), tool = true, cb = function()
            self:setTool("shape"); self:openShapePicker()
        end },
        { id = "pan",   label = _("Pan"),   tool = true, cb = function() self:setTool("pan") end },
        { id = "zoomout", label = "\u{2212}", cb = function() self:zoomStep(-1) end },  -- minus
        { id = "zoomin",  label = "+",        cb = function() self:zoomStep(1) end },
        { id = "undo",  label = _("Undo"),  cb = function() self:undo() end },
        { id = "menu",  label = "\u{2699}", cb = function() self:openSettings() end },   -- gear
        { id = "save",  label = _("Save"),  cb = function() self:onSave() end },
        { id = "exit",  label = _("Exit"),  cb = function() self:promptExit() end },
    }
    local n = #specs
    local btn_w = math.floor(Screen:getWidth() / n)
    -- shrink the font a little on narrow screens so the labels never truncate
    local font_size = math.max(11, math.min(16, math.floor(btn_w / 6)))
    self.tool_buttons = {}
    local row = {}
    for i, s in ipairs(specs) do
        local w = (i == n) and (Screen:getWidth() - btn_w * (n - 1)) or btn_w
        local b = Button:new{
            text = s.label,
            callback = s.cb,
            width = w,
            bordersize = Size.border.default,   -- a real border so it reads as a button
            radius = Screen:scaleBySize(5),
            margin = Size.margin.small,
            padding = Size.padding.small,
            text_font_size = font_size,
            show_parent = self,
        }
        if s.tool then self.tool_buttons[s.id] = { button = b, label = s.label } end
        row[i] = b
    end
    self.toolbar = FrameContainer:new{
        background = WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        HorizontalGroup:new(row),
    }
    self:refreshToolLabels()
end

-- Mark the active tool with a leading bullet.
function InkAwayView:refreshToolLabels()
    -- U+25CF BLACK CIRCLE, written as explicit UTF-8 bytes for portability
    local BULLET = "\226\151\143 "
    -- the fill tool lives under the Shapes button, so mark Shapes for it too
    local active = (self.tool == "fill") and "shape" or self.tool
    for id, entry in pairs(self.tool_buttons) do
        local mark = (active == id) and BULLET or ""
        entry.button:setText(mark .. entry.label, entry.button.width)
    end
end

function InkAwayView:setTool(tool)
    if self.tool == tool then return end
    self:flushPending()        -- commit any stroke still in progress first
    -- a curve waiting for its bend is committed straight; other half-drags drop
    if self.curve_stage == "bend" then self:commitCurve() else self:cancelShape() end
    self.pan_last = nil
    self.tool = tool
    self:refreshToolLabels()
    UIManager:setDirty(self, "ui", GeomUI:new{
        x = 0, y = 0, w = self.screen_w, h = self.view.area_y })
end

-- Is the pen currently set to this rgb?
local function sameColor(a, b)
    return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

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
            background = Blitbuffer.ColorRGB32(e.rgb[1], e.rgb[2], e.rgb[3], 0xFF),
            width = sw,
            bordersize = selected and Size.border.thick or Size.border.default,
            radius = 0,
            callback = function() onpick(e.rgb) end,
        }
    end
    return row
end

-- Pen swatch row: marks the pen colour, and picking one reopens the pen popup.
function InkAwayView:swatchRow(entries)
    return self:swatchRowFor(entries, self.pen_color, function(rgb)
        self.pen_color = { rgb[1], rgb[2], rgb[3] }
        self:openPenSettings()
    end)
end

-- Pen settings popup: size and opacity together, plus shade and (on colour
-- screens) colour swatches. Rebuilt and reshown whenever something changes.
function InkAwayView:openPenSettings()
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._pen_dialog then UIManager:close(self._pen_dialog) end

    local pct = math.floor(self.pen_alpha / 255 * 100 + 0.5)
    local buttons = {}

    -- size + opacity, opened together in a precise slider dialog
    buttons[#buttons + 1] = {{
        text = string.format(_("Size %d px   •   Opacity %d%%"), self.pen_width, pct),
        callback = function()
            UIManager:close(self._pen_dialog)
            self:openSizeOpacity()
        end,
    }}

    -- brush style (two rows). Marker/watercolor/acrylic are experimental looks.
    local style_rows = {
        { { "solid", _("Ink") }, { "pencil", _("Pencil") }, { "charcoal", _("Charcoal") }, { "marker", _("Marker") } },
        { { "watercolor", _("Watercolour") }, { "acrylic", _("Acrylic") }, { "hatch", _("Hatch") }, { "stipple", _("Stipple") } },
    }
    buttons[#buttons + 1] = {{ text = _("Style"), enabled = false }}
    for _, sr in ipairs(style_rows) do
        local row = {}
        for _, s in ipairs(sr) do
            row[#row + 1] = {
                text = (self.pen_style == s[1] and "\u{25CF} " or "") .. s[2],
                callback = function()
                    self.pen_style = s[1]
                    self:setSetting("inkaway_pen_style", s[1])
                    self:openPenSettings()
                end,
            }
        end
        buttons[#buttons + 1] = row
    end

    -- shades (primary on e-ink)
    buttons[#buttons + 1] = {{ text = _("Shade"), enabled = false }}
    buttons[#buttons + 1] = self:swatchRow(SHADES)

    -- colours, only where the screen can show them
    if Device.hasColorScreen and Device:hasColorScreen() then
        buttons[#buttons + 1] = {{ text = _("Colour (colour screens)"), enabled = false }}
        buttons[#buttons + 1] = self:swatchRow(COLORS)
    end

    buttons[#buttons + 1] = {{ text = _("Done"),
        callback = function() UIManager:close(self._pen_dialog) end }}

    self._pen_dialog = ButtonDialog:new{ title = _("Pen"), title_align = "center", buttons = buttons }
    UIManager:show(self._pen_dialog)
end

-- The precise size + opacity slider dialog, reached from the pen popup.
function InkAwayView:openSizeOpacity()
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")
    local dlg
    dlg = DoubleSpinWidget:new{
        title_text = _("Pen size and opacity"),
        info_text = _("Size is in canvas pixels. Opacity sets how transparent the ink is; lower means more see-through in the export."),
        left_text = _("Size"),
        left_min = 1, left_max = 60, left_step = 1,
        left_value = self.pen_width,
        right_text = _("Opacity %"),
        right_min = 5, right_max = 100, right_step = 5,
        right_value = math.floor(self.pen_alpha / 255 * 100 + 0.5),
        callback = function(size, opacity)
            self.pen_width = math.max(1, math.floor(size))
            self.pen_alpha = math.max(1, math.min(255, math.floor(opacity / 100 * 255 + 0.5)))
            self:openPenSettings()   -- back to the pen popup with the new values
        end,
    }
    UIManager:show(dlg)
end

-- Eraser size, the same idea as the pen's size control.
function InkAwayView:openEraserSettings()
    local SpinWidget = require("ui/widget/spinwidget")
    local dlg = SpinWidget:new{
        title_text = _("Eraser size"),
        info_text = _("The eraser's width, in canvas pixels."),
        value = self.eraser_width,
        value_min = 4, value_max = 120, value_step = 2, value_hold_step = 10,
        unit = _("px"),
        callback = function(spin)
            self.eraser_width = math.max(1, math.floor(spin.value))
        end,
    }
    UIManager:show(dlg)
end

-- Shape chooser. Each entry shows the actual shape glyph next to its name; the
-- current one gets a checkmark. Shapes are drawn with the pen's size, opacity
-- and colour.
function InkAwayView:openShapePicker()
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._shape_dialog then UIManager:close(self._shape_dialog) end

    local items = {
        { { "\u{2571} " .. _("Line"),   "line",     false },
          { "\u{2312} " .. _("Curve"),  "curve",    false } },
        { { "\u{25EF} " .. _("Ellipse"),        "ellipse", false },
          { "\u{25CF} " .. _("Ellipse filled"), "ellipse", true } },
        { { "\u{25AD} " .. _("Rectangle"),        "rect", false },
          { "\u{25AC} " .. _("Rectangle filled"), "rect", true } },
        { { "\u{25B3} " .. _("Triangle"),        "triangle", false },
          { "\u{25B2} " .. _("Triangle filled"), "triangle", true } },
    }

    local buttons = {}
    for _, r in ipairs(items) do
        local row = {}
        for _, e in ipairs(r) do
            local label, shape, fill = e[1], e[2], e[3]
            row[#row + 1] = {
                text = label,
                checked_func = function()
                    return self.shape == shape and self.shape_fill == fill
                end,
                callback = function()
                    self.shape, self.shape_fill = shape, fill
                    self:refreshToolLabels()
                    self:openShapePicker()   -- reopen to move the checkmark
                end,
            }
        end
        buttons[#buttons + 1] = row
    end
    -- paint bucket: fill an enclosed area on tap, using the pen's colour/opacity
    buttons[#buttons + 1] = {{
        text = "\u{25A8} " .. _("Fill area (hold to set colour)"),
        checked_func = function() return self.tool == "fill" end,
        callback = function()
            self.tool = "fill"
            self:cancelShape()
            self:refreshToolLabels()
            UIManager:close(self._shape_dialog)
        end,
        hold_callback = function()
            UIManager:close(self._shape_dialog)
            self:openFillSettings()
        end,
    }}
    buttons[#buttons + 1] = {{ text = _("Drawn with the pen's size, opacity and colour."), enabled = false }}
    buttons[#buttons + 1] = {{ text = _("Done"),
        callback = function() UIManager:close(self._shape_dialog) end }}

    self._shape_dialog = ButtonDialog:new{ title = _("Shapes"), title_align = "center", buttons = buttons }
    UIManager:show(self._shape_dialog)
end

------------------------------------------------------------------------------
-- Zoom  (consistent multiplicative steps between fit and ZOOM_MAX)
------------------------------------------------------------------------------

function InkAwayView:setZoom(new_zoom, anchor_sx, anchor_sy)
    local v = self.view
    new_zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, new_zoom))
    if math.abs(new_zoom - v.zoom) < 1e-6 then return false end
    -- keep the canvas point under (anchor_sx, anchor_sy) fixed; default to the
    -- centre of the drawing area
    anchor_sx = anchor_sx or (v.area_x + v.area_w / 2)
    anchor_sy = anchor_sy or (v.area_y + v.area_h / 2)
    local acx, acy = InkGeom.toCanvas(v, anchor_sx, anchor_sy)
    v.zoom = new_zoom
    v.pan_x = acx - (anchor_sx - v.area_x) / v.zoom
    v.pan_y = acy - (anchor_sy - v.area_y) / v.zoom
    InkGeom.clampPan(v)
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

function InkAwayView:zoomStep(dir)
    self:flushPending()
    local factor = (dir > 0) and ZOOM_RATIO or (1 / ZOOM_RATIO)
    self:setZoom(self.view.zoom * factor)
end

------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------

-- The drawing area as a screen rect. A fresh Geom every call, because setDirty
-- keeps the region by reference rather than copying it.
function InkAwayView:areaScreenRect()
    local v = self.view
    return GeomUI:new{ x = v.area_x, y = v.area_y, w = v.area_w, h = v.area_h }
end

-- The colour a committed op is drawn with on screen (ink shade at its opacity,
-- or the background for an eraser).
function InkAwayView:opColor(op)
    if op.kind == "erase" then return WHITE end
    return displayColor(op.color, op.alpha or 255)
end

-- Rebuild the 1:1 master bitmap from the committed ops. Cost is proportional to
-- the ink drawn, not the zoom, and it only runs on open, undo, clear, or resize.
function InkAwayView:composeCanvas()
    if not self.canvas_bb then return end
    local W, H = self.view.canvas_w, self.view.canvas_h
    self.canvas_bb:paintRect(0, 0, W, H, WHITE)
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden then      -- a shape being rotated is drawn as a preview
            local put = spanWriter(self.canvas_bb, W, H, self:opColor(op), nil)
            Export.paintGeom(op, put)
        end
    end
end

-- Rebuild what is on screen from the master bitmap: take the visible crop of
-- canvas_bb (a zero-copy viewport) and scale it into area_bb with mupdf's fast
-- C scaler. This is the whole reason zoom and pan are cheap: the work is a
-- single scale of one screenful, whatever the zoom or the amount of ink.
function InkAwayView:renderView()
    if not (self.area_bb and self.canvas_bb) then return end
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    self.area_bb:paintRect(0, 0, v.area_w, v.area_h, WHITE)

    -- visible crop of the canvas, clamped inside it
    local sx = math.max(0, math.min(W - 1, math.floor(v.pan_x)))
    local sy = math.max(0, math.min(H - 1, math.floor(v.pan_y)))
    local sw = math.max(1, math.min(W - sx, math.ceil(v.area_w / v.zoom)))
    local sh = math.max(1, math.min(H - sy, math.ceil(v.area_h / v.zoom)))

    local dw = math.max(1, math.floor(sw * v.zoom))
    local dh = math.max(1, math.floor(sh * v.zoom))
    -- where that crop lands in the area: a positive margin when the whole page
    -- fits (letterbox), or a sub-pixel nudge when zoomed in, which we clamp to
    -- the area and trim so the blit always stays in bounds
    local ox = math.max(0, math.floor((sx - v.pan_x) * v.zoom))
    local oy = math.max(0, math.floor((sy - v.pan_y) * v.zoom))
    local bw = math.min(dw, v.area_w - ox)
    local bh = math.min(dh, v.area_h - oy)
    if bw < 1 or bh < 1 then return end

    local sub = self.canvas_bb:viewport(sx, sy, sw, sh)     -- shares memory
    local scaled = RenderImage:scaleBlitBuffer(sub, dw, dh, false)
    self.area_bb:blitFrom(scaled, ox, oy, 0, 0, bw, bh)
    if scaled ~= sub and scaled.free then scaled:free() end

    if self.grid_on then self:drawGridInto() end   -- baked in once, not per paint
end

-- A thin line into area_bb (area coords), clipped to it. Used for grid guides.
function InkAwayView:gridLine(x0, y0, x1, y1, color)
    local bb, aw, ah = self.area_bb, self.view.area_w, self.view.area_h
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 1 then return end
    local ix, iy = dx / steps, dy / steps
    local x, y = x0, y0
    for _ = 0, steps do
        local px, py = math.floor(x + 0.5), math.floor(y + 0.5)
        if px >= 0 and px < aw and py >= 0 and py < ah then bb:paintRect(px, py, 1, 1, color) end
        x = x + ix; y = y + iy
    end
end

-- Draw the current grid style into area_bb (display only; never exported).
function InkAwayView:drawGridInto()
    local v = self.view
    local aw, ah = v.area_w, v.area_h
    local g = self.grid_size
    local style = self.grid_style or "square"
    local col = FRAME
    local function ax(cx) return (cx - v.pan_x) * v.zoom end
    local function ay(cy) return (cy - v.pan_y) * v.zoom end

    if style == "thirds" then
        -- rule of thirds over the page rectangle
        for i = 1, 2 do
            local x = ax(v.canvas_w * i / 3)
            if x >= 0 and x < aw then self.area_bb:paintRect(math.floor(x), 0, 1, ah, col) end
            local y = ay(v.canvas_h * i / 3)
            if y >= 0 and y < ah then self.area_bb:paintRect(0, math.floor(y), aw, 1, col) end
        end
        return
    end

    if not g or g <= 0 then return end

    if style == "lines" then                       -- ruled horizontal lines
        local cy = 0
        while cy <= v.canvas_h do
            local y = math.floor(ay(cy))
            if y >= 0 and y < ah then self.area_bb:paintRect(0, y, aw, 1, col) end
            cy = cy + g
        end
    elseif style == "dots" then                     -- dot at each intersection
        local cy = 0
        while cy <= v.canvas_h do
            local y = math.floor(ay(cy))
            if y >= -1 and y < ah then
                local cx = 0
                while cx <= v.canvas_w do
                    local x = math.floor(ax(cx))
                    if x >= 0 and x < aw and y >= 0 then self.area_bb:paintRect(x, y, 2, 2, col) end
                    cx = cx + g
                end
            end
            cy = cy + g
        end
    elseif style == "iso" then                      -- isometric: verticals + 30 deg diagonals
        local cx = 0
        while cx <= v.canvas_w do
            local x = ax(cx)
            if x >= 0 and x < aw then self.area_bb:paintRect(math.floor(x), 0, 1, ah, col) end
            cx = cx + g
        end
        local slope = math.tan(math.rad(30))
        local spacing = g / math.cos(math.rad(30))
        -- two diagonal families, offset so they cover the whole area
        local start = -math.ceil(ah * slope / spacing) * spacing
        local b = start
        while b <= v.canvas_w * v.zoom + ah do
            self:gridLine(ax(0) + b, 0, ax(0) + b + ah * slope, ah, col)      -- down-right
            self:gridLine(ax(0) + b, ah, ax(0) + b + ah * slope, 0, col)      -- up-right
            b = b + spacing * v.zoom
        end
    else                                            -- "square"
        local cx = 0
        while cx <= v.canvas_w do
            local x = math.floor(ax(cx))
            if x >= 0 and x < aw then self.area_bb:paintRect(x, 0, 1, ah, col) end
            cx = cx + g
        end
        local cy = 0
        while cy <= v.canvas_h do
            local y = math.floor(ay(cy))
            if y >= 0 and y < ah then self.area_bb:paintRect(0, y, aw, 1, col) end
            cy = cy + g
        end
    end
end

------------------------------------------------------------------------------
-- Drawing gesture handlers
------------------------------------------------------------------------------

-- Current live ink colour and width, from the active tool.
function InkAwayView:liveColor()
    if self.tool == "erase" then return WHITE end
    return displayColor(self.pen_color, self.pen_alpha)
end
function InkAwayView:liveWidth()
    return (self.tool == "erase") and self.eraser_width or self.pen_width
end

-- Stamp the live segment ending at canvas point (cx,cy) into BOTH buffers: the
-- 1:1 master (so a later zoom/pan re-render is correct) and the on-screen buffer
-- at the current zoom (so drawing feels immediate). Only the on-screen dirty
-- rectangle is refreshed. `fresh` starts a new segment with no line back.
function InkAwayView:stampLive(cx, cy, fresh)
    local color = self:liveColor()
    local width = self:liveWidth()
    local style = (self.tool == "erase") and nil or self.pen_style
    local st = style and Raster.STYLES[style]
    local textured = st and not st.solid
    local seed = self.live_seed or 0
    local function stroke(seg, r, put)
        if textured then Raster.pathTex(seg, r, put, st, seed)
        else Raster.path(seg, r, put) end
    end

    -- master, at 1:1
    if self.canvas_bb then
        local cput = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h, color, nil)
        if self.last_cx and not fresh then
            stroke({ self.last_cx, self.last_cy, cx, cy }, width / 2, cput)
        else
            stroke({ cx, cy }, width / 2, cput)
        end
        self.last_cx, self.last_cy = cx, cy
    end

    -- on screen, at the current zoom
    local ax, ay = self:toAreaLocal(cx, cy)
    local acc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local aput = spanWriter(self.area_bb, self.view.area_w, self.view.area_h, color, acc)
    if self.last_ax and not fresh then
        stroke({ self.last_ax, self.last_ay, ax, ay }, (width * self.view.zoom) / 2, aput)
    else
        stroke({ ax, ay }, (width * self.view.zoom) / 2, aput)
    end
    self.last_ax, self.last_ay = ax, ay
    if acc.x1 >= acc.x0 then
        -- grow the whole-stroke bbox (area coords) for a tidy refresh at the end
        local sr = self._stroke_rect
        if not sr then
            self._stroke_rect = { x0 = acc.x0, y0 = acc.y0, x1 = acc.x1, y1 = acc.y1 }
        else
            if acc.x0 < sr.x0 then sr.x0 = acc.x0 end
            if acc.y0 < sr.y0 then sr.y0 = acc.y0 end
            if acc.x1 > sr.x1 then sr.x1 = acc.x1 end
            if acc.y1 > sr.y1 then sr.y1 = acc.y1 end
        end
        local v = self.view
        UIManager:setDirty(self, "fast", GeomUI:new{
            x = v.area_x + math.floor(acc.x0),
            y = v.area_y + math.floor(acc.y0),
            w = math.ceil(acc.x1 - acc.x0) + 1,
            h = math.ceil(acc.y1 - acc.y0) + 1,
        })
    end
end

-- Add a screen point to the live stroke (kept in canvas coords) and draw it.
-- The stabilizer smooths the finger's path toward a trailing point, so wobble
-- becomes a clean line; strength 0 draws the raw point.
function InkAwayView:addScreenPoint(sx, sy, fresh)
    local cx, cy = self:toCanvasClamped(sx, sy)
    if fresh then
        self.sm_x, self.sm_y = cx, cy
    else
        local a = InkGeom.stabilizerAlpha(self.stabilizer)
        self.sm_x, self.sm_y = InkGeom.ema(self.sm_x, self.sm_y, cx, cy, a)
        cx, cy = self.sm_x, self.sm_y
    end
    self.canvas:addPoint(cx, cy)
    self:stampLive(cx, cy, fresh)
end

function InkAwayView:beginStroke(sx, sy)
    local is_erase = self.tool == "erase"
    self.live_seed = math.random(1, 1000000)
    self.canvas:startStroke(is_erase and "erase" or "ink",
        self:liveWidth(), self.pen_alpha, self.pen_color,
        is_erase and nil or self.pen_style, self.live_seed)
    self.capturing = true
    self.pending_lift = nil
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    self._stroke_rect = nil
    self:addScreenPoint(sx, sy, true)
end

-- Provisional lift: hold the stroke open briefly (COALESCE_SEC) in case the
-- panel dropped the contact and it is about to come back nearby.
function InkAwayView:scheduleFinalize(sx, sy)
    self.pending_lift = { x = sx, y = sy }
    UIManager:unschedule(self._finalize)
    UIManager:scheduleIn(COALESCE_SEC, self._finalize)
end

-- Commit the live stroke as one op. Called by the coalesce timer, or eagerly
-- via flushPending() before any action that must see a consistent model.
function InkAwayView:finalizeStroke()
    if not self.capturing then return end
    UIManager:unschedule(self._finalize)
    self.pending_lift = nil
    self.capturing = false
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    local was_erase = self.tool == "erase"
    self.canvas:finishStroke()
    self.dirty = true
    -- Settle the fast-refresh ghosting over just the stroke's area. Erasing dark
    -- or textured ink leaves grey ghosts, so an erase gets a flashing refresh
    -- (which fully repaints black/white) to clear them.
    local mode = was_erase and "flashui" or "ui"
    local sr, v = self._stroke_rect, self.view
    if sr then
        UIManager:setDirty(self, mode, GeomUI:new{
            x = v.area_x + math.floor(sr.x0) - 2,
            y = v.area_y + math.floor(sr.y0) - 2,
            w = math.ceil(sr.x1 - sr.x0) + 4,
            h = math.ceil(sr.y1 - sr.y0) + 4,
        })
    else
        UIManager:setDirty(self, mode, self:areaScreenRect())
    end
    self._stroke_rect = nil
end

-- Commit immediately if a stroke is open (or pending). Safe to call any time.
function InkAwayView:flushPending()
    if self.capturing then self:finalizeStroke() end
end

------------------------------------------------------------------------------
-- Shapes: rubber-band placement (drag to stretch, like a paint program). The
-- committed drawing in canvas_bb is never touched while stretching; the shape
-- is drawn on top in paintTo and only its changed rectangle is refreshed, so it
-- stays snappy. On release the shape is stamped into the master and folded in.
------------------------------------------------------------------------------

-- Screen-coordinate op for the current drag, drawn as the live preview.
local function screenShapeOp(self, shape, fill, x0, y0, x1, y1, cx, cy)
    return {
        kind = "shape", shape = shape, fill = fill,
        width = math.max(1, self.pen_width * self.view.zoom),
        color = self.pen_color, alpha = self.pen_alpha,
        pts = cx and { x0, y0, x1, y1, cx, cy } or { x0, y0, x1, y1 },
    }
end

-- Padded screen rect touched by a preview op.
function InkAwayView:previewRect(op)
    local x0, y0, x1, y1 = Shapes.bounds(op)
    local pad = op.width + 4
    return { x = math.floor(x0 - pad), y = math.floor(y0 - pad),
             x2 = math.ceil(x1 + pad), y2 = math.ceil(y1 + pad) }
end

-- Refresh the union of the previous and current preview rectangles, so the old
-- outline is wiped (from the untouched base) and the new one drawn.
function InkAwayView:refreshPreview()
    local r = self.shape_preview and self:previewRect(self.shape_preview) or nil
    local u = r
    local prev = self._preview_rect
    if prev then
        if u then
            u = { x = math.min(u.x, prev.x), y = math.min(u.y, prev.y),
                  x2 = math.max(u.x2, prev.x2), y2 = math.max(u.y2, prev.y2) }
        else
            u = prev
        end
    end
    self._preview_rect = r
    if not u then return end
    local v = self.view
    local x = math.max(0, u.x)
    local yy = math.max(v.area_y, u.y)
    local x2 = math.min(self.screen_w, u.x2)
    local y2 = math.min(v.area_y + v.area_h, u.y2)
    if x2 > x and y2 > yy then
        UIManager:setDirty(self, "fast", GeomUI:new{ x = x, y = yy, w = x2 - x, h = y2 - yy })
    end
end

function InkAwayView:shapeTouch(pos)
    if self.curve_stage == "bend" then
        self.curve_ctrl = { x = pos.x, y = pos.y }
        self.shape_preview = screenShapeOp(self, "curve", false,
            self.curve_p0.x, self.curve_p0.y, self.curve_p1.x, self.curve_p1.y,
            self.curve_ctrl.x, self.curve_ctrl.y)
        self:refreshPreview()
        return true
    end
    local x0, y0 = self:snapScreen(pos.x, pos.y)
    self.shape_drag = { x0 = x0, y0 = y0, x1 = x0, y1 = y0 }
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, x0, y0, x0, y0)
    self:refreshPreview()
    return true
end

function InkAwayView:shapeMove(pos)
    if not pos then return true end
    if self.curve_stage == "bend" then
        self.curve_ctrl = { x = pos.x, y = pos.y }
        self.shape_preview = screenShapeOp(self, "curve", false,
            self.curve_p0.x, self.curve_p0.y, self.curve_p1.x, self.curve_p1.y,
            self.curve_ctrl.x, self.curve_ctrl.y)
        self:refreshPreview()
        return true
    end
    if not self.shape_drag then return false end
    local d = self.shape_drag
    d.x1, d.y1 = self:shapeEndPoint(pos)
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, d.x0, d.y0, d.x1, d.y1)
    self:refreshPreview()
    return true
end

-- Snap the drag's end point: to the grid (if on), and to 45-degree steps for a
-- line or curve (if angle snapping is on). Rectangles and ellipses are NOT
-- forced square, so you can draw any proportion.
function InkAwayView:shapeEndPoint(pos)
    local d = self.shape_drag
    local x1, y1 = self:snapScreen(pos.x, pos.y)
    if self.snap_angle and (self.shape == "line" or self.shape == "curve") then
        x1, y1 = InkGeom.snapAngle(d.x0, d.y0, x1, y1)
    end
    return x1, y1
end

function InkAwayView:shapeRelease(pos)
    if self.curve_stage == "bend" then
        if pos then self.curve_ctrl = { x = pos.x, y = pos.y } end
        self:commitCurve()
        return true
    end
    if not self.shape_drag then return false end
    if pos then self.shape_drag.x1, self.shape_drag.y1 = self:shapeEndPoint(pos) end
    local d = self.shape_drag
    local dx, dy = d.x1 - d.x0, d.y1 - d.y0
    if dx * dx + dy * dy < 9 then      -- basically a tap: nothing to place
        self:cancelShape()
        return true
    end
    if self.shape == "curve" then
        -- keep the straight segment on screen and wait for a bend drag
        self.curve_p0 = { x = d.x0, y = d.y0 }
        self.curve_p1 = { x = d.x1, y = d.y1 }
        self.curve_ctrl = { x = (d.x0 + d.x1) / 2, y = (d.y0 + d.y1) / 2 }
        self.curve_stage = "bend"
        self.shape_drag = nil
        return true
    end
    self:commitShape()
    return true
end

-- Stamp a committed op into the 1:1 master.
function InkAwayView:stampOpIntoCanvas(op)
    if not self.canvas_bb then return end
    local put = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h,
        self:opColor(op), nil)
    Export.paintGeom(op, put)
end

function InkAwayView:commitShape()
    local d = self.shape_drag
    local c0x, c0y = self:toCanvasClamped(d.x0, d.y0)
    local c1x, c1y = self:toCanvasClamped(d.x1, d.y1)
    local op = self.canvas:addShape(self.shape, self.shape_fill,
        { c0x, c0y, c1x, c1y }, self.pen_width, self.pen_alpha, self.pen_color)
    self:stampOpIntoCanvas(op)
    self.dirty = true
    self.shape_drag = nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:commitCurve()
    local c0x, c0y = self:toCanvasClamped(self.curve_p0.x, self.curve_p0.y)
    local c1x, c1y = self:toCanvasClamped(self.curve_p1.x, self.curve_p1.y)
    local ccx, ccy = self:toCanvasClamped(self.curve_ctrl.x, self.curve_ctrl.y)
    local op = self.canvas:addShape("curve", false,
        { c0x, c0y, c1x, c1y, ccx, ccy }, self.pen_width, self.pen_alpha, self.pen_color)
    self:stampOpIntoCanvas(op)
    self.dirty = true
    self.curve_stage = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Drop any in-progress shape and wipe its preview.
function InkAwayView:cancelShape()
    if not (self.shape_drag or self.curve_stage or self.shape_preview) then return end
    self.shape_drag = nil
    self.curve_stage = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self:refreshPreview()   -- clears the old preview region from the base
end

------------------------------------------------------------------------------
-- Paint bucket: flood fill an enclosed area on tap.
------------------------------------------------------------------------------

-- The paint bucket's own colour/opacity, so it need not share the pen's.
function InkAwayView:openFillSettings()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function pick(rgb)
        self.fill_color = { rgb[1], rgb[2], rgb[3] }
        UIManager:close(dlg)
        self:openFillSettings()
    end
    local pct = math.floor(self.fill_alpha / 255 * 100 + 0.5)
    local buttons = {}
    buttons[#buttons + 1] = {{
        text = string.format(_("Opacity %d%%"), pct),
        callback = function()
            UIManager:close(dlg)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("Fill opacity"), value = pct,
                value_min = 5, value_max = 100, value_step = 5, unit = "%",
                callback = function(s)
                    self.fill_alpha = math.max(1, math.min(255, math.floor(s.value / 100 * 255 + 0.5)))
                    self:openFillSettings()
                end,
            })
        end,
    }}
    buttons[#buttons + 1] = self:swatchRowFor(SHADES, self.fill_color, pick)
    if Device.hasColorScreen and Device:hasColorScreen() then
        buttons[#buttons + 1] = self:swatchRowFor(COLORS, self.fill_color, pick)
    end
    buttons[#buttons + 1] = {{ text = _("Done"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = _("Fill colour and opacity"), title_align = "center", buttons = buttons }
    UIManager:show(dlg)
end

function InkAwayView:doFill(pos)
    self:flushPending()
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    local gray = Export.buildGray(self.canvas)
    local runs = Fill.compute(gray, self.view.canvas_w, self.view.canvas_h,
        math.floor(cx), math.floor(cy), 40)
    if not runs or #runs == 0 then return end
    local op = self.canvas:addFillOp(runs, self.fill_color, self.fill_alpha)
    self:stampOpIntoCanvas(op)
    self.dirty = true
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

------------------------------------------------------------------------------
-- Settings menu (gear): drawing aids, projects, autosave.
------------------------------------------------------------------------------

function InkAwayView:refreshArea()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:setAutosave(mode)
    self.autosave = mode
    self:setSetting("inkaway_autosave", mode)
    self:scheduleAutosave()
end

function InkAwayView:openGridStyle()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local opts = {
        { "square", _("Square grid") }, { "dots", _("Dot grid") },
        { "lines", _("Ruled lines") }, { "iso", _("Isometric") },
        { "thirds", _("Rule of thirds") },
    }
    local buttons = {}
    for _, o in ipairs(opts) do
        buttons[#buttons + 1] = {{
            text = (self.grid_style == o[1] and "\u{25CF} " or "") .. o[2],
            callback = function()
                self.grid_style = o[1]
                self:setSetting("inkaway_grid_style", o[1])
                self.grid_on = true
                self:setSetting("inkaway_grid", true)
                UIManager:close(dlg)
                self:renderView(); self:refreshArea()
                self:openSettings()
            end,
        }}
    end
    dlg = ButtonDialog:new{ title = _("Grid style"), title_align = "center", buttons = buttons }
    UIManager:show(dlg)
end

function InkAwayView:openGridSize()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Grid spacing"),
        value = self.grid_size, value_min = 8, value_max = 200, value_step = 4, value_hold_step = 20,
        unit = _("px"),
        callback = function(spin)
            self.grid_size = math.max(4, math.floor(spin.value))
            self:setSetting("inkaway_grid_size", self.grid_size)
            self:renderView(); self:refreshArea()
            self:openSettings()
        end,
    })
end

function InkAwayView:openStabilizer()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Stabilizer"),
        info_text = _("How much finger wobble is smoothed out. 0 draws exactly what your finger does; higher is smoother but the line trails a little behind."),
        value = self.stabilizer, value_min = 0, value_max = 100, value_step = 5, value_hold_step = 20,
        callback = function(spin)
            self.stabilizer = math.floor(spin.value)
            self:setSetting("inkaway_stabilizer", self.stabilizer)
            self:openSettings()
        end,
    })
end

function InkAwayView:openSettings()
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._settings_dialog then UIManager:close(self._settings_dialog) end
    local dlg
    local function reopen() self:openSettings() end
    local function onoff(b) return b and _("on") or _("off") end
    local function tog(key, field, redraw)
        self[field] = not self[field]
        self:setSetting(key, self[field])
        if redraw then self:refreshArea() end
        reopen()
    end
    local function mark(m) return (self.autosave == m) and "\u{25CF} " or "" end
    local buttons = {
        {{ text = _("Redo"), callback = function() UIManager:close(dlg); self:redo() end }},
        {
            { text = _("New"),          callback = function() UIManager:close(dlg); self:newDrawing() end },
            { text = _("Open project"), callback = function() UIManager:close(dlg); self:openProject() end },
            { text = _("Save project"), callback = function() UIManager:close(dlg); self:saveProject() end },
        },
        {
            { text = _("Grid: ") .. onoff(self.grid_on), callback = function()
                self.grid_on = not self.grid_on; self:setSetting("inkaway_grid", self.grid_on)
                self:renderView(); self:refreshArea(); reopen()
            end },
            { text = _("Style: ") .. self.grid_style, callback = function() UIManager:close(dlg); self:openGridStyle() end },
            { text = _("Size"), callback = function() UIManager:close(dlg); self:openGridSize() end },
        },
        {
            { text = _("Snap grid: ") .. onoff(self.snap_grid), callback = function() tog("inkaway_snap_grid", "snap_grid") end },
            { text = _("Snap 45°: ") .. onoff(self.snap_angle), callback = function() tog("inkaway_snap_angle", "snap_angle") end },
        },
        {{ text = string.format(_("Stabilizer: %d"), self.stabilizer),
           callback = function() UIManager:close(dlg); self:openStabilizer() end }},
        {
            { text = mark("off") .. _("No autosave"),  callback = function() self:setAutosave("off"); reopen() end },
            { text = mark("exit") .. _("Save on exit"), callback = function() self:setAutosave("exit"); reopen() end },
            { text = mark("periodic") .. _("Every 3 min"), callback = function() self:setAutosave("periodic"); reopen() end },
        },
        {{ text = _("Done"), callback = function() UIManager:close(dlg) end }},
    }
    dlg = ButtonDialog:new{ title = _("Settings"), title_align = "center", buttons = buttons }
    self._settings_dialog = dlg
    UIManager:show(dlg)
end

------------------------------------------------------------------------------
-- Projects: new / open / save (the editable drawing, not the image export).
------------------------------------------------------------------------------

function InkAwayView:newDrawing()
    local function fresh()
        self.canvas:setOps({})
        self.selected, self.rotating = nil, nil
        self.dirty = false
        self:composeCanvas(); self:renderView()
        UIManager:setDirty(self, "full")
    end
    if self.canvas:isEmpty() then fresh(); return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Start a new drawing? The current one will be cleared."),
        ok_text = _("New"), ok_callback = fresh,
    })
end

function InkAwayView:openProject()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:defaultDir(),
        onConfirm = function(path)
            local data, err = Project.load(path)
            if data and self:loadProjectData(data) then
                self:composeCanvas(); self:renderView()
                UIManager:setDirty(self, "full")
            else
                UIManager:show(InfoMessage:new{
                    text = _("Could not open that project.\n") .. tostring(err) })
            end
        end,
    })
end

function InkAwayView:saveProject()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true, select_file = false, show_files = true,
        path = self:defaultDir(),
        onConfirm = function(dir)
            last_save_dir = dir
            local InputDialog = require("ui/widget/inputdialog")
            local name = os.date("ink-%Y%m%d-%H%M%S")
            local d
            d = InputDialog:new{
                title = _("Project name"),
                input = name,
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(d) end },
                    { text = _("Save"), is_enter_default = true, callback = function()
                        local n = d:getInputText()
                        UIManager:close(d)
                        if not n or n == "" then n = name end
                        n = n:gsub("[/\\]", "_")
                        if not n:lower():match("%." .. Project.EXT .. "$") then n = n .. "." .. Project.EXT end
                        local sep = (dir:sub(-1) == "/") and "" or "/"
                        local ok, e = Project.save(self.canvas, dir .. sep .. n)
                        UIManager:show(InfoMessage:new{
                            text = ok and (_("Project saved:\n") .. dir .. sep .. n)
                                        or (_("Could not save project.\n") .. tostring(e)) })
                    end },
                }},
            }
            UIManager:show(d)
            d:onShowKeyboard()
        end,
    })
end

------------------------------------------------------------------------------
-- Editing a placed shape: hold one to pick it, then rotate / recolour / resize
-- / delete it from a small menu anchored beside it.
------------------------------------------------------------------------------

-- Find the top-most shape op under a screen point. Returns {op, idx} or nil.
function InkAwayView:hitTestShape(sx, sy)
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "shape" then
            local tol = (op.width or 6) / 2 + 8 / self.view.zoom
            if Shapes.hit(op, cx, cy, tol) then return { op = op, idx = i } end
        end
    end
    return nil
end

-- A screen-coordinate copy of a shape op (for the rotate preview overlay).
function InkAwayView:screenShapeFromOp(op, angle)
    local v = self.view
    local sp = {}
    for i = 1, #op.pts, 2 do
        local sx, sy = InkGeom.toScreen(v, op.pts[i], op.pts[i + 1])
        sp[#sp + 1] = sx
        sp[#sp + 1] = sy
    end
    return {
        kind = "shape", shape = op.shape, fill = op.fill, angle = angle,
        width = math.max(1, (op.width or 2) * v.zoom),
        color = op.color, alpha = op.alpha, pts = sp,
    }
end

function InkAwayView:openShapeMenu(sel)
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._shape_menu then UIManager:close(self._shape_menu) end
    local op = sel.op
    local dlg
    local function close() if dlg then UIManager:close(dlg) end end
    dlg = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function()
            local x0, y0, x1, y1 = Shapes.bounds(op)
            local sx0, sy0 = InkGeom.toScreen(self.view, x0, y0)
            local sx1, sy1 = InkGeom.toScreen(self.view, x1, y1)
            return GeomUI:new{ x = math.floor(sx0), y = math.floor(sy0),
                               w = math.ceil(sx1 - sx0), h = math.ceil(sy1 - sy0) }
        end,
        buttons = {
            {
                { text = "\u{21BB} " .. _("Rotate"),    callback = function() close(); self:beginRotate(sel) end },
                { text = "\u{29C9} " .. _("Duplicate"), callback = function() close(); self:duplicateSelected(sel) end },
                { text = "\u{2715} " .. _("Delete"),    callback = function() close(); self:deleteSelected(sel) end },
            },
            {
                { text = "\u{25D1} " .. _("Colour"),  callback = function() close(); self:editSelectedColour(sel) end },
                { text = "\u{25A9} " .. _("Opacity"), callback = function() close(); self:editSelectedOpacity(sel) end },
                { text = "\u{25CF} " .. _("Size"),    callback = function() close(); self:editSelectedSize(sel) end },
            },
            {
                { text = "\u{2190}", callback = function() close(); self:nudgeSelected(sel, -1, 0) end },
                { text = "\u{2191}", callback = function() close(); self:nudgeSelected(sel, 0, -1) end },
                { text = "\u{2193}", callback = function() close(); self:nudgeSelected(sel, 0, 1) end },
                { text = "\u{2192}", callback = function() close(); self:nudgeSelected(sel, 1, 0) end },
            },
            {{ text = _("Done"), callback = close }},
        },
    }
    self._shape_menu = dlg
    UIManager:show(dlg)
end

-- Apply an edit to the selected op through copy-on-write, so undo/redo work.
function InkAwayView:applyEdit(sel, mutate)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    mutate(clone)
    self.canvas:replaceOp(sel.idx, clone)
    sel.op = clone
    if self.selected then self.selected.op = clone end
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:deleteSelected(sel)
    self.canvas:pushHistory()
    self.canvas:removeOp(sel.idx)
    self.selected = nil
    self.dirty = true
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Duplicate the selected shape, offset a little, and select the copy.
function InkAwayView:duplicateSelected(sel)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    local d = self.grid_on and self.grid_size or 14
    for i = 1, #clone.pts, 2 do clone.pts[i] = clone.pts[i] + d; clone.pts[i + 1] = clone.pts[i + 1] + d end
    self.canvas.ops[#self.canvas.ops + 1] = clone
    self.selected = { op = clone, idx = #self.canvas.ops }
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openShapeMenu(self.selected)
end

-- Nudge the selected shape by (dx,dy) canvas px (a grid step, or a few px).
function InkAwayView:nudgeSelected(sel, dirx, diry)
    local step = self.grid_on and self.grid_size or 6
    self:applyEdit(sel, function(o)
        for i = 1, #o.pts, 2 do o.pts[i] = o.pts[i] + dirx * step; o.pts[i + 1] = o.pts[i + 1] + diry * step end
    end)
    self:openShapeMenu(sel)   -- keep the menu up for repeated nudges
end

function InkAwayView:editSelectedColour(sel)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function pick(rgb)
        self:applyEdit(sel, function(o) o.color = { rgb[1], rgb[2], rgb[3] } end)
        UIManager:close(dlg)
        self:editSelectedColour(sel)   -- reopen to move the selection border
    end
    local buttons = { self:swatchRowFor(SHADES, sel.op.color, pick) }
    if Device.hasColorScreen and Device:hasColorScreen() then
        buttons[#buttons + 1] = self:swatchRowFor(COLORS, sel.op.color, pick)
    end
    buttons[#buttons + 1] = {{ text = _("Done"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = _("Shape colour"), title_align = "center", buttons = buttons }
    UIManager:show(dlg)
end

function InkAwayView:editSelectedSize(sel)
    local SpinWidget = require("ui/widget/spinwidget")
    local op = sel.op
    UIManager:show(SpinWidget:new{
        title_text = _("Shape line size"),
        value = op.width, value_min = 1, value_max = 60, value_step = 1, value_hold_step = 6,
        unit = _("px"),
        callback = function(spin)
            self:applyEdit(sel, function(o) o.width = math.max(1, math.floor(spin.value)) end)
        end,
    })
end

function InkAwayView:editSelectedOpacity(sel)
    local SpinWidget = require("ui/widget/spinwidget")
    local op = sel.op
    UIManager:show(SpinWidget:new{
        title_text = _("Shape opacity"),
        value = math.floor((op.alpha or 255) / 255 * 100 + 0.5),
        value_min = 5, value_max = 100, value_step = 5, value_hold_step = 20,
        unit = "%",
        callback = function(spin)
            self:applyEdit(sel, function(o)
                o.alpha = math.max(1, math.min(255, math.floor(spin.value / 100 * 255 + 0.5)))
            end)
        end,
    })
end

-- Rotation: hide the shape from the master, show it as a preview, and let a drag
-- spin it freely about its centre. Cheap per frame (only the preview redraws).
function InkAwayView:beginRotate(sel)
    local op = sel.op
    op.hidden = true
    self.rotating = { op = op, idx = sel.idx, base = op.angle or 0, cur = op.angle or 0 }
    self:composeCanvas(); self:renderView()
    self.shape_preview = self:screenShapeFromOp(op, op.angle or 0)
    self._preview_rect = nil
    self:refreshPreview()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    UIManager:show(InfoMessage:new{
        text = _("Drag anywhere to rotate the shape; lift to finish."), timeout = 2 })
end

function InkAwayView:rotateCentreScreen(op)
    local x0, y0, x1, y1 = op.pts[1], op.pts[2], op.pts[3], op.pts[4]
    return InkGeom.toScreen(self.view, (x0 + x1) / 2, (y0 + y1) / 2)
end

function InkAwayView:rotateTouch(pos)
    local r = self.rotating
    local cx, cy = self:rotateCentreScreen(r.op)
    r.cx, r.cy = cx, cy
    r.grab = math.atan2(pos.y - cy, pos.x - cx)
    return true
end

function InkAwayView:rotateMove(pos)
    local r = self.rotating
    if not r.grab then return self:rotateTouch(pos) end
    local a = math.atan2(pos.y - r.cy, pos.x - r.cx)
    r.cur = r.base + (a - r.grab)
    self.shape_preview = self:screenShapeFromOp(r.op, r.cur)
    self:refreshPreview()
    return true
end

function InkAwayView:rotateEnd()
    local r = self.rotating
    if not r then return true end
    r.op.hidden = nil
    self.rotating = nil
    self.shape_preview = nil
    self._preview_rect = nil
    if math.abs((r.cur or r.base) - r.base) > 1e-4 then
        -- commit the new angle through copy-on-write so it can be undone
        self.canvas:pushHistory()
        local clone = self.canvas:cloneOp(r.op)
        clone.angle = r.cur
        self.canvas:replaceOp(r.idx, clone)
        if self.selected then self.selected.op = clone end
        self.dirty = true
    end
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

------------------------------------------------------------------------------
-- Pan, shared by the Pan tool and two finger pan. It works from one step to the
-- next, so it stays reliable even when the panel sends events unevenly.
------------------------------------------------------------------------------

function InkAwayView:panByScreen(dx, dy)
    local v = self.view
    -- content follows the finger: dragging right reveals more of the left
    v.pan_x = v.pan_x - dx / v.zoom
    v.pan_y = v.pan_y - dy / v.zoom
    InkGeom.clampPan(v)
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

------------------------------------------------------------------------------
-- Drawing / pan gesture handlers
------------------------------------------------------------------------------

-- Touch down: begin a stroke or a pan, or carry on a stroke that just lifted if
-- the panel dropped the finger and picked it up again.
function InkAwayView:onIaTouch(_, ges)
    local pos = ges.pos
    if not pos or not self:inArea(pos.x, pos.y) then return false end
    if self.rotating then return self:rotateTouch(pos) end
    if self.tool == "fill" then self:doFill(pos); return true end
    if self.tool == "shape" then return self:shapeTouch(pos) end
    if self.tool == "pan" then
        self.pan_last = { x = pos.x, y = pos.y }
        return true
    end
    if self.capturing and self.pending_lift then
        -- within the coalesce window: same stroke if the new contact is close
        local dx = pos.x - self.pending_lift.x
        local dy = pos.y - self.pending_lift.y
        if dx * dx + dy * dy <= self.bridge_dist * self.bridge_dist then
            UIManager:unschedule(self._finalize)
            self.pending_lift = nil
            self:addScreenPoint(pos.x, pos.y, false)  -- bridge the gap
            return true
        end
        self:finalizeStroke()   -- genuinely a new stroke elsewhere
    elseif self.capturing then
        self:finalizeStroke()   -- a lift was missed; don't lose the old stroke
    end
    self:beginStroke(pos.x, pos.y)
    return true
end

function InkAwayView:onIaPan(_, ges)
    local pos = ges.pos
    if self.rotating then return self:rotateMove(pos) end
    if self.tool == "fill" then return true end   -- fill is a tap, ignore drags
    if self.tool == "shape" then return self:shapeMove(pos) end
    if self.tool == "pan" then
        if self.pan_last then
            self:panByScreen(pos.x - self.pan_last.x, pos.y - self.pan_last.y)
            self.pan_last.x, self.pan_last.y = pos.x, pos.y
            return true
        end
        return false
    end
    if not self.capturing then return false end
    if self.pending_lift then          -- movement resumes the held stroke
        UIManager:unschedule(self._finalize)
        self.pending_lift = nil
    end
    self:addScreenPoint(pos.x, pos.y, false)
    return true
end
InkAwayView.onIaHoldPan = InkAwayView.onIaPan

function InkAwayView:onIaPanRelease(_, ges)
    if self.rotating then return self:rotateEnd() end
    if self.tool == "fill" then return true end
    if self.tool == "shape" then return self:shapeRelease(ges and ges.pos) end
    if self.tool == "pan" then
        self.pan_last = nil
        return true
    end
    if not self.capturing then return false end
    if ges and ges.pos then self:addScreenPoint(ges.pos.x, ges.pos.y, false) end
    self:scheduleFinalize(ges and ges.pos and ges.pos.x or 0,
                          ges and ges.pos and ges.pos.y or 0)
    return true
end
InkAwayView.onIaHoldRel = InkAwayView.onIaPanRelease

function InkAwayView:onIaSwipe(_, ges)
    if self.rotating then return self:rotateEnd() end
    if self.tool == "fill" then return true end
    if self.tool == "shape" then return self:shapeRelease(ges and (ges.end_pos or ges.pos)) end
    if self.tool == "pan" then
        self.pan_last = nil
        return true
    end
    if not self.capturing then return false end
    -- swipe reports the lift point separately as end_pos
    local p = ges and (ges.end_pos or ges.pos)
    if p then self:addScreenPoint(p.x, p.y, false) end
    self:scheduleFinalize(p and p.x or 0, p and p.y or 0)
    return true
end

function InkAwayView:onIaTap(_, ges)
    -- Toolbar taps are consumed by the buttons before this runs.
    if self.rotating then return self:rotateEnd() end
    if self.tool == "fill" then return true end   -- fill already happened on touch
    if self.tool == "shape" then return self:shapeRelease(ges and ges.pos) end
    -- A tap inside the area finishes the dot started by the preceding touch.
    if self.capturing then
        if ges and ges.pos then self:addScreenPoint(ges.pos.x, ges.pos.y, false) end
        self:scheduleFinalize(ges and ges.pos and ges.pos.x or 0,
                              ges and ges.pos and ges.pos.y or 0)
        return true
    end
    return false
end

function InkAwayView:onIaHold(_, ges)
    -- A hold on a placed shape picks it and opens its little edit menu. Otherwise
    -- soak up holds inside the area so they don't become a long press menu.
    if self.capturing or self.shape_drag or self.curve_stage or self.rotating then return true end
    local pos = ges and ges.pos
    if not (pos and self:inArea(pos.x, pos.y)) then return false end
    -- selecting a placed shape only happens in Pan mode, so a hold never fights
    -- with drawing in the pen or shape tools
    if self.tool == "pan" then
        local sel = self:hitTestShape(pos.x, pos.y)
        if sel then
            self.selected = sel
            self:openShapeMenu(sel)
        end
    end
    return true
end

-- Two finger pan works whatever tool is active. Commit any stroke in progress
-- first so no ink is lost, then pan by how far the midpoint between the two
-- fingers moved since the last step.
function InkAwayView:onIaTwoPan(_, ges)
    self:flushPending()
    self:cancelShape()   -- a two-finger pan drops any half-placed shape
    local pos = ges.pos
    if not self.pan_last then
        self.pan_last = { x = pos.x, y = pos.y }
    else
        self:panByScreen(pos.x - self.pan_last.x, pos.y - self.pan_last.y)
        self.pan_last.x, self.pan_last.y = pos.x, pos.y
    end
    return true
end

function InkAwayView:onIaTwoPanRel()
    self.pan_last = nil
    return true
end

------------------------------------------------------------------------------
-- Undo / exit
------------------------------------------------------------------------------

function InkAwayView:undo()
    self:flushPending()
    if self.rotating then self:rotateEnd() end
    if not self.canvas:undo() then
        UIManager:show(InfoMessage:new{ text = _("Nothing to undo."), timeout = 1 })
        return
    end
    self.selected = nil
    self.dirty = true
    self:composeCanvas()   -- rebuild the master from the restored ops
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:redo()
    self:flushPending()
    if not self.canvas:redo() then
        UIManager:show(InfoMessage:new{ text = _("Nothing to redo."), timeout = 1 })
        return
    end
    self.selected = nil
    self.dirty = true
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:promptExit()
    local ConfirmBox = require("ui/widget/confirmbox")
    self:flushPending()
    if self.canvas:isEmpty() then
        UIManager:close(self)
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Leave Ink Away? Any unsaved drawing will be lost."),
        ok_text = _("Leave"),
        ok_callback = function() UIManager:close(self) end,
    })
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

function InkAwayView:paintTo(bb, x, y)
    local v = self.view
    -- white background across the whole screen
    bb:paintRect(x, y, self.screen_w, self.screen_h, WHITE)
    -- toolbar
    self.toolbar:paintTo(bb, x, y)
    -- drawing area (the grid, if any, is already baked into area_bb by renderView)
    bb:blitFrom(self.area_bb, x + v.area_x, y + v.area_y, 0, 0, v.area_w, v.area_h)
    -- the frame marking the page: where the full W x H export sits on screen
    local fx0, fy0 = InkGeom.toScreen(v, 0, 0)
    local fx1, fy1 = InkGeom.toScreen(v, v.canvas_w, v.canvas_h)
    fx0, fy0 = math.floor(fx0 + x), math.floor(fy0 + y)
    fx1, fy1 = math.floor(fx1 + x), math.floor(fy1 + y)
    -- clip the frame to the area so it never draws over the toolbar
    local ay0 = y + v.area_y
    local ay1 = y + v.area_y + v.area_h
    local top = math.max(fy0, ay0)
    local bot = math.min(fy1, ay1)
    if fx0 >= x and fx0 < x + self.screen_w and bot > top then
        bb:paintRect(fx0, top, 1, bot - top, FRAME)
    end
    if fx1 >= x and fx1 <= x + self.screen_w and bot > top then
        bb:paintRect(math.min(fx1, x + self.screen_w - 1), top, 1, bot - top, FRAME)
    end
    if fy0 >= ay0 and fy0 < ay1 then
        bb:paintRect(math.max(fx0, x), fy0, math.min(fx1, x + self.screen_w) - math.max(fx0, x), 1, FRAME)
    end
    if fy1 > ay0 and fy1 <= ay1 then
        bb:paintRect(math.max(fx0, x), math.min(fy1, ay1 - 1), math.min(fx1, x + self.screen_w) - math.max(fx0, x), 1, FRAME)
    end

    -- live shape preview drawn on top of the (untouched) drawing, clipped to
    -- the area so it never spills onto the toolbar
    if self.shape_preview then
        local color = displayColor(self.shape_preview.color, self.shape_preview.alpha)
        local sw = self.screen_w
        local cy0, cy1 = y + v.area_y, y + v.area_y + v.area_h
        local put = function(px, py, len)
            py = py + y
            if py < cy0 or py >= cy1 then return end
            px = px + x
            if px < x then len = len + (px - x); px = x end
            if px + len > x + sw then len = x + sw - px end
            if len > 0 then bb:paintRect(px, py, len, 1, color) end
        end
        Shapes.render(self.shape_preview, put)
    end
end

------------------------------------------------------------------------------
-- Save workflow: format -> destination folder -> filename -> encode
------------------------------------------------------------------------------

function InkAwayView:onSave()
    self:flushPending()
    if self.canvas:isEmpty() then
        UIManager:show(InfoMessage:new{ text = _("The canvas is empty."), timeout = 2 })
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = _("Save drawing as:"),
        title_align = "center",
        buttons = {
            {{
                text = _("PNG (transparent background)"),
                callback = function() UIManager:close(dialog); self:chooseDestination("png") end,
            }},
            {{
                text = _("JPEG (white background)"),
                callback = function() UIManager:close(dialog); self:chooseDestination("jpg") end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function InkAwayView:defaultDir()
    if last_save_dir then return last_save_dir end
    local ok, fmutil = pcall(require, "apps/filemanager/filemanagerutil")
    if ok and fmutil and fmutil.getDefaultDir then
        local d = fmutil.getDefaultDir()
        if d then return d end
    end
    return "/"
end

function InkAwayView:chooseDestination(fmt)
    local PathChooser = require("ui/widget/pathchooser")
    local chooser
    chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = true,
        path = self:defaultDir(),
        onConfirm = function(dir)
            last_save_dir = dir
            self:promptFilename(fmt, dir)
        end,
    }
    UIManager:show(chooser)
end

function InkAwayView:promptFilename(fmt, dir)
    local ext = (fmt == "png") and "png" or "jpg"
    local default_name = os.date("ink-%Y%m%d-%H%M%S")
    local dialog
    dialog = InputDialog:new{
        title = _("File name"),
        input = default_name,
        input_hint = default_name,
        description = string.format(_("Saving to:\n%s\n\nExtension .%s will be added."), dir, ext),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    if not name or name == "" then name = default_name end
                    self:writeFile(fmt, dir, name, ext)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function InkAwayView:writeFile(fmt, dir, name, ext)
    -- strip any path separators the user typed, keep it a simple filename
    name = name:gsub("[/\\]", "_")
    if not name:lower():match("%." .. ext .. "$") then
        name = name .. "." .. ext
    end
    local sep = (dir:sub(-1) == "/") and "" or "/"
    local path = dir .. sep .. name

    local ok, err
    if fmt == "png" then
        ok, err = Export.savePNG(self.canvas, path)
    else
        ok, err = Export.saveJPEG(self.canvas, path, 90)
    end

    if ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Saved %d × %d image:\n%s"),
                self.canvas.w, self.canvas.h, path),
        })
    else
        logger.warn("InkAway: save failed:", err)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not save the image.\n%s"), tostring(err)),
            icon = "notice-warning",
        })
    end
end

return InkAwayView
