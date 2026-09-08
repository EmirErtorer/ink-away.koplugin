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
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Canvas = require("ink/canvas")
local InkGeom = require("ink/geom")
local Raster = require("ink/raster")
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
local function inkColor(alpha)
    local g = 255 - alpha
    return Blitbuffer.ColorRGB32(g, g, g, 0xFF)
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
    self.tool = "pen"          -- "pen" | "erase" | "pan"
    self.capturing = false     -- a pen/erase stroke is in progress
    self.pending_lift = nil    -- {x,y}: finger lifted, stroke not yet committed
    self.pan_last = nil        -- last point of a pan drag in progress (screen)

    -- Pen: width in canvas pixels (constant thickness in the export regardless
    -- of zoom) and opacity 0-255. The eraser is a good deal fatter.
    self.pen_width = math.max(2, math.floor(W / 320 + 0.5) * 2)
    self.pen_alpha = 255
    self.eraser_width = self.pen_width * 6
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

    -- One reused display buffer for the drawing area.
    self.area_bb = Blitbuffer.new(self.view.area_w, self.view.area_h, Screen.bb:getType())
    self:composeAll()
end

function InkAwayView:free()
    if self.area_bb then
        self.area_bb:free()
        self.area_bb = nil
    end
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
    if self.area_bb then self.area_bb:free() end
    self.area_bb = Blitbuffer.new(v.area_w, v.area_h, Screen.bb:getType())
    self:composeAll()
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
        -- tapping Pen when it is already the active tool opens its settings
        { id = "pen",   label = _("Pen"),   cb = function()
            if self.tool == "pen" then self:openPenSettings() else self:setTool("pen") end
        end },
        { id = "erase", label = _("Eraser"), cb = function() self:setTool("erase") end },
        { id = "pan",   label = _("Pan"),   cb = function() self:setTool("pan") end },
        { id = "zoomout", label = _("Zoom −"), cb = function() self:zoomStep(-1) end },
        { id = "zoomin",  label = _("Zoom +"), cb = function() self:zoomStep(1) end },
        { id = "undo",  label = _("Undo"),  cb = function() self:undo() end },
        { id = "save",  label = _("Save"),  cb = function() self:onSave() end },
        { id = "exit",  label = _("Exit"),  cb = function() self:promptExit() end },
    }
    local n = #specs
    local btn_w = math.floor(Screen:getWidth() / n)
    self.tool_buttons = {}
    local row = {}
    for i, s in ipairs(specs) do
        local w = (i == n) and (Screen:getWidth() - btn_w * (n - 1)) or btn_w
        local b = Button:new{
            text = s.label,
            callback = s.cb,
            width = w,
            bordersize = 0,
            radius = 0,
            margin = 0,
            text_font_size = 16,
            show_parent = self,   -- so the button's tap refresh targets us
        }
        if s.id == "pen" or s.id == "erase" or s.id == "pan" then
            self.tool_buttons[s.id] = { button = b, label = s.label }
        end
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
    for id, entry in pairs(self.tool_buttons) do
        local mark = (self.tool == id) and BULLET or ""
        entry.button:setText(mark .. entry.label, entry.button.width)
    end
end

function InkAwayView:setTool(tool)
    if self.tool == tool then return end
    self:flushPending()        -- commit any stroke still in progress first
    self.pan_last = nil
    self.tool = tool
    self:refreshToolLabels()
    UIManager:setDirty(self, "ui", GeomUI:new{
        x = 0, y = 0, w = self.screen_w, h = self.view.area_y })
end

-- Pen thickness + opacity, applied to subsequent strokes.
function InkAwayView:openPenSettings()
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")
    local dlg
    dlg = DoubleSpinWidget:new{
        title_text = _("Pen settings"),
        info_text = _("Thickness is in canvas pixels; opacity sets how transparent the ink is in the export."),
        left_text = _("Thickness"),
        left_min = 1, left_max = 40, left_step = 1,
        left_value = self.pen_width,
        right_text = _("Opacity %"),
        right_min = 5, right_max = 100, right_step = 5,
        right_value = math.floor(self.pen_alpha / 255 * 100 + 0.5),
        callback = function(thickness, opacity)
            self.pen_width = math.max(1, math.floor(thickness))
            self.pen_alpha = math.max(1, math.min(255, math.floor(opacity / 100 * 255 + 0.5)))
        end,
    }
    UIManager:show(dlg)
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
    self:composeAll()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

function InkAwayView:zoomStep(dir)
    self:flushPending()
    local factor = (dir > 0) and ZOOM_RATIO or (1 / ZOOM_RATIO)
    self:setZoom(self.view.zoom * factor)
end

------------------------------------------------------------------------------
-- Compositing into area_bb
------------------------------------------------------------------------------

-- The drawing area as a screen rect. A fresh Geom every call, because setDirty
-- keeps the region by reference rather than copying it.
function InkAwayView:areaScreenRect()
    local v = self.view
    return GeomUI:new{ x = v.area_x, y = v.area_y, w = v.area_w, h = v.area_h }
end

-- Build a span writer that paints into area_bb with the given colour, tracking
-- the touched bounding box, in area coordinates, in `acc`.
function InkAwayView:areaPut(color, acc)
    local bb = self.area_bb
    local aw, ah = self.view.area_w, self.view.area_h
    return function(x, y, len)
        if y < 0 or y >= ah then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > aw then len = aw - x end
        if len <= 0 then return end
        bb:paintRect(x, y, len, 1, color)
        if x < acc.x0 then acc.x0 = x end
        if x + len > acc.x1 then acc.x1 = x + len end
        if y < acc.y0 then acc.y0 = y end
        if y + 1 > acc.y1 then acc.y1 = y + 1 end
    end
end

-- Stamp a single op (in canvas coords) into area_bb. Returns the touched
-- rect in area coordinates, or nil.
function InkAwayView:stampOp(op)
    local color = (op.kind == "erase") and WHITE or inkColor(op.alpha or 255)
    local acc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local put = self:areaPut(color, acc)
    -- move the canvas points into area coordinates, keep width in screen px
    local spts = {}
    local pts = op.pts
    for i = 1, #pts, 2 do
        local ax, ay = self:toAreaLocal(pts[i], pts[i + 1])
        spts[#spts + 1] = ax
        spts[#spts + 1] = ay
    end
    Raster.path(spts, (op.width * self.view.zoom) / 2, put)
    if acc.x1 < acc.x0 then return nil end
    return { x = acc.x0, y = acc.y0, w = acc.x1 - acc.x0, h = acc.y1 - acc.y0 }
end

-- Rebuild the whole drawing area from the committed ops.
function InkAwayView:composeAll()
    if not self.area_bb then return end
    self.area_bb:paintRect(0, 0, self.view.area_w, self.view.area_h, WHITE)
    for _, op in ipairs(self.canvas.ops) do
        self:stampOp(op)
    end
end

------------------------------------------------------------------------------
-- Drawing gesture handlers
------------------------------------------------------------------------------

-- Stamp the segment ending at area point (ax,ay) onto area_bb and refresh just
-- that rectangle. `fresh` starts a new segment (no line back to the last point).
function InkAwayView:stampLive(ax, ay, fresh)
    local color = (self.tool == "erase") and WHITE or inkColor(self.pen_alpha)
    local width = (self.tool == "erase") and self.eraser_width or self.pen_width
    local acc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local put = self:areaPut(color, acc)
    local seg
    if self.last_ax and not fresh then
        seg = { self.last_ax, self.last_ay, ax, ay }
    else
        seg = { ax, ay }
    end
    Raster.path(seg, (width * self.view.zoom) / 2, put)
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

-- Add a screen point to the live stroke (in canvas coords) and draw it.
function InkAwayView:addScreenPoint(sx, sy, fresh)
    local cx, cy = self:toCanvasClamped(sx, sy)
    self.canvas:addPoint(cx, cy)
    local ax, ay = self:toAreaLocal(cx, cy)
    self:stampLive(ax, ay, fresh)
end

function InkAwayView:beginStroke(sx, sy)
    self.canvas:startStroke(self.tool == "erase" and "erase" or "ink",
        self.tool == "erase" and self.eraser_width or self.pen_width,
        self.pen_alpha)
    self.capturing = true
    self.pending_lift = nil
    self.last_ax, self.last_ay = nil, nil
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
    self.canvas:finishStroke()
    -- a clean partial refresh settles any ghosting the fast refresh left behind
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Commit immediately if a stroke is open (or pending). Safe to call any time.
function InkAwayView:flushPending()
    if self.capturing then self:finalizeStroke() end
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
    self:composeAll()
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
    -- Toolbar taps are consumed by the buttons before this runs. A tap inside
    -- the area finishes the dot started by the preceding touch.
    if self.capturing then
        if ges and ges.pos then self:addScreenPoint(ges.pos.x, ges.pos.y, false) end
        self:scheduleFinalize(ges and ges.pos and ges.pos.x or 0,
                              ges and ges.pos and ges.pos.y or 0)
        return true
    end
    return false
end

function InkAwayView:onIaHold(_, ges)
    -- Soak up holds inside the area so they don't turn into a long press menu;
    -- the stroke is already live from the touch.
    if self.capturing then return true end
    local pos = ges and ges.pos
    return pos and self:inArea(pos.x, pos.y) or false
end

-- Two finger pan works whatever tool is active. Commit any stroke in progress
-- first so no ink is lost, then pan by how far the midpoint between the two
-- fingers moved since the last step.
function InkAwayView:onIaTwoPan(_, ges)
    self:flushPending()
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
    self:composeAll()
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
