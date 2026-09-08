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
    self:composeCanvas()
    self:renderView()
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
        { id = "zoomout", label = _("Zoom −"), cb = function() self:zoomStep(-1) end },
        { id = "zoomin",  label = _("Zoom +"), cb = function() self:zoomStep(1) end },
        { id = "undo",  label = _("Undo"),  cb = function() self:undo() end },
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

    -- master, at 1:1
    if self.canvas_bb then
        local cput = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h, color, nil)
        if self.last_cx and not fresh then
            Raster.path({ self.last_cx, self.last_cy, cx, cy }, width / 2, cput)
        else
            Raster.path({ cx, cy }, width / 2, cput)
        end
        self.last_cx, self.last_cy = cx, cy
    end

    -- on screen, at the current zoom
    local ax, ay = self:toAreaLocal(cx, cy)
    local acc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local aput = spanWriter(self.area_bb, self.view.area_w, self.view.area_h, color, acc)
    if self.last_ax and not fresh then
        Raster.path({ self.last_ax, self.last_ay, ax, ay }, (width * self.view.zoom) / 2, aput)
    else
        Raster.path({ ax, ay }, (width * self.view.zoom) / 2, aput)
    end
    self.last_ax, self.last_ay = ax, ay
    if acc.x1 >= acc.x0 then
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
function InkAwayView:addScreenPoint(sx, sy, fresh)
    local cx, cy = self:toCanvasClamped(sx, sy)
    self.canvas:addPoint(cx, cy)
    self:stampLive(cx, cy, fresh)
end

function InkAwayView:beginStroke(sx, sy)
    self.canvas:startStroke(self.tool == "erase" and "erase" or "ink",
        self:liveWidth(), self.pen_alpha, self.pen_color)
    self.capturing = true
    self.pending_lift = nil
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
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
    self.canvas:finishStroke()
    -- a clean partial refresh settles any ghosting the fast refresh left behind
    UIManager:setDirty(self, "ui", self:areaScreenRect())
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
    self.shape_drag = { x0 = pos.x, y0 = pos.y, x1 = pos.x, y1 = pos.y }
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill,
        pos.x, pos.y, pos.x, pos.y)
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
    self.shape_drag.x1, self.shape_drag.y1 = pos.x, pos.y
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill,
        self.shape_drag.x0, self.shape_drag.y0, pos.x, pos.y)
    self:refreshPreview()
    return true
end

function InkAwayView:shapeRelease(pos)
    if self.curve_stage == "bend" then
        if pos then self.curve_ctrl = { x = pos.x, y = pos.y } end
        self:commitCurve()
        return true
    end
    if not self.shape_drag then return false end
    if pos then self.shape_drag.x1, self.shape_drag.y1 = pos.x, pos.y end
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
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
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
                { text = "\u{21BB} " .. _("Rotate"), callback = function() close(); self:beginRotate(sel) end },
                { text = "\u{2715} " .. _("Delete"), callback = function() close(); self:deleteSelected(sel) end },
            },
            {
                { text = "\u{25D1} " .. _("Colour"),  callback = function() close(); self:editSelectedColour(sel) end },
                { text = "\u{25A9} " .. _("Opacity"), callback = function() close(); self:editSelectedOpacity(sel) end },
                { text = "\u{25CF} " .. _("Size"),    callback = function() close(); self:editSelectedSize(sel) end },
            },
            {{ text = _("Done"), callback = close }},
        },
    }
    self._shape_menu = dlg
    UIManager:show(dlg)
end

function InkAwayView:deleteSelected(sel)
    table.remove(self.canvas.ops, sel.idx)
    self.selected = nil
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:editSelectedColour(sel)
    local ButtonDialog = require("ui/widget/buttondialog")
    local op = sel.op
    local dlg
    local function repaint()
        self:composeCanvas(); self:renderView()
        UIManager:setDirty(self, "ui", self:areaScreenRect())
    end
    local function pick(rgb)
        op.color = { rgb[1], rgb[2], rgb[3] }
        repaint()
        UIManager:close(dlg)
        self:editSelectedColour(sel)   -- reopen to move the selection border
    end
    local buttons = { self:swatchRowFor(SHADES, op.color, pick) }
    if Device.hasColorScreen and Device:hasColorScreen() then
        buttons[#buttons + 1] = self:swatchRowFor(COLORS, op.color, pick)
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
            op.width = math.max(1, math.floor(spin.value))
            self:composeCanvas(); self:renderView()
            UIManager:setDirty(self, "ui", self:areaScreenRect())
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
            op.alpha = math.max(1, math.min(255, math.floor(spin.value / 100 * 255 + 0.5)))
            self:composeCanvas(); self:renderView()
            UIManager:setDirty(self, "ui", self:areaScreenRect())
        end,
    })
end

-- Rotation: hide the shape from the master, show it as a preview, and let a drag
-- spin it freely about its centre. Cheap per frame (only the preview redraws).
function InkAwayView:beginRotate(sel)
    local op = sel.op
    op.hidden = true
    self.rotating = { op = op, base = op.angle or 0, cur = op.angle or 0 }
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
    r.op.angle = r.cur or r.base
    r.op.hidden = nil
    self.rotating = nil
    self.shape_preview = nil
    self._preview_rect = nil
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
    local op = self.canvas:undo()
    if not op then
        UIManager:show(InfoMessage:new{ text = _("Nothing to undo."), timeout = 1 })
        return
    end
    self:composeCanvas()   -- rebuild the master from the remaining ops
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
    -- drawing area
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
