--[[
Viewport: orientation, where the drawing area sits on screen, zoom and pan, and
collapsing the toolbar or notebook bar to give the page more room.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InkGeom = require("ink/geom")

local Screen = Device.screen

local ZOOM_RATIO = 1.5    -- one zoom press multiplies by this, for even steps
local ZOOM_MAX = 8.0

local InkAwayView = {}

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
-- Orientation (portrait / landscape)
--
-- KOReader rotates the whole screen: a rotation mode is 0 (upright portrait),
-- 1 (clockwise landscape), 2 (upside-down portrait) or 3 (counter-clockwise
-- landscape) -- the odd modes are the two landscapes. Ink Away can run either
-- way up. It remembers the reader's own rotation when it opens and puts it back
-- on close, and it remembers the orientation you last drew in so a fresh launch
-- comes up the same way. Opening while the device is already held in landscape
-- works too, since the very first launch simply adopts whatever the screen is.
--
-- The canvas is created at the screen size, so a landscape session gets a wide
-- canvas and its PNG/JPEG/PDF export comes out landscape with no extra work. A
-- drawing already on screen keeps its size and is just shown rotated (you pan to
-- reach it); only a still-blank page is reshaped to the new orientation.
------------------------------------------------------------------------------

local function modeIsLandscape(mode) return mode ~= nil and (mode % 2 == 1) end

-- Is screen rotation available at all (it is on real devices and the emulator;
-- guard so the headless tests, which stub Screen, never call a missing method).
function InkAwayView:orientationSupported()
    return (Screen.setRotationMode and Screen.getRotationMode) and true or false
end

function InkAwayView:currentRotation()
    return (Screen.getRotationMode and Screen:getRotationMode()) or 0
end

-- The "portrait" / "landscape" class of a rotation mode (the current one if none
-- is given).
function InkAwayView:orientationClass(mode)
    if mode == nil then mode = self:currentRotation() end
    return modeIsLandscape(mode) and "landscape" or "portrait"
end

-- Which rotation mode to use for a requested orientation. Prefer the reader's own
-- rotation when it already matches the class (so we keep the exact way up the
-- device is held), else a sensible default: upright for portrait, and
-- counter-clockwise for landscape (so the device's bottom bezel ends up on the
-- right, matching how most readers turn a device for landscape).
function InkAwayView:rotationForClass(class)
    local orig = self.orig_rotation
    if class == "landscape" then
        if modeIsLandscape(orig) then return orig end
        return Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE or 3
    else
        if orig ~= nil and not modeIsLandscape(orig) then return orig end
        return Screen.DEVICE_ROTATED_UPRIGHT or 0
    end
end

-- Apply the orientation Ink Away should open in, called once at init BEFORE the
-- canvas and buffers are sized. Uses the remembered choice if there is one, else
-- adopts (and remembers) however the device is currently held.
function InkAwayView:applyStartupOrientation()
    if not self:orientationSupported() then
        self.orientation = self:orientationClass()
        return
    end
    local pref = self:getSetting("inkaway_orientation", nil)
    if pref ~= "portrait" and pref ~= "landscape" then
        self.orientation = self:orientationClass()
        self:setSetting("inkaway_orientation", self.orientation)
        return
    end
    self.orientation = pref
    local target = self:rotationForClass(pref)
    if target ~= self:currentRotation() then
        pcall(function() Screen:setRotationMode(target) end)
    end
end

-- Switch orientation from the Settings sheet. Rotates the screen, remembers the
-- choice, then re-lays-out (and reshapes a blank page to the new orientation).
function InkAwayView:setOrientation(class)
    if not self:orientationSupported() then return end
    if self:orientationClass() == class then return end   -- already that way up
    pcall(function() Screen:setRotationMode(self:rotationForClass(class)) end)
    self.orientation = class
    self:setSetting("inkaway_orientation", class)
    self:handleScreenResize()
    -- a full refresh both draws the new orientation and clears the panel, which is
    -- exactly when a full refresh earns its cost
    UIManager:setDirty(self, "full")
end

-- Reshape the page to the screen's current size, so it always MATCHES the
-- orientation: a landscape session gets a landscape page (and a landscape export),
-- a portrait session a portrait one. Existing marks keep their canvas coordinates,
-- so they stay upright and line-snapped text stays on its ruling; a mark that now
-- falls past the new, shorter edge is simply not drawn or exported until you rotate
-- back -- nothing is deleted from the ops list, so it is fully reversible. A
-- PDF-backed notebook is the one exception: its page size is the imported PDF's, so
-- it is never reshaped. Returns true if it reshaped, and recomposes the master so
-- the caller's renderView shows the reshaped page.
function InkAwayView:reshapeToScreen()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local v = self.view
    if not v then return false end
    if v.canvas_w == W and v.canvas_h == H then return false end   -- already that shape
    -- a PDF-backed notebook's pages ARE the imported PDF at its own size: never reshape
    if self.notebook and self.notebook.template and self.notebook.template.pdf_path then
        return false
    end
    v.canvas_w, v.canvas_h = W, H
    self.canvas.w, self.canvas.h = W, H
    if self.notebook then self.notebook.w, self.notebook.h = W, H end
    if self.canvas_bb then self.canvas_bb:free() end
    self.canvas_bb = Blitbuffer.new(W, H, Screen.bb:getType())
    self:composeCanvas()   -- marks past the new bounds are just not drawn (kept in ops)
    return true
end

-- Re-lay-out after the screen size changed -- from our own orientation toggle, or
-- the device being physically turned (onSetDimensions). Reshape the page to the new
-- orientation first, then rebuild the toolbar/area and refit the view.
function InkAwayView:handleScreenResize()
    self:reshapeToScreen()
    self:relayout()
    self.orientation = self:orientationClass()
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
    if self.notebook then self.nb_bar_h = self:nbBarHeight() end
    local th = self.toolbar:getSize().h
    local v = self.view
    v.area_x, v.area_y, v.area_w, v.area_h = 0, th, W, H - th - self.nb_bar_h
    self:refitArea()   -- the canvas keeps its size; only the on-screen buffer follows the screen
    self._area_only = false   -- layout/chrome changed: the next paint must be full
end

-- Refit the view after the drawing area changed size, then reallocate the
-- on-screen buffer and re-render it. The default is to cover the whole area (see
-- InkGeom.coverZoom), so a page whose shape differs from the screen (a landscape
-- drawing shown after rotating back to portrait) still fills it, with no
-- undrawable margin and no stray page edge under the toolbar. A zoomed-in view is
-- kept; only a view below "cover" is lifted up to it.
function InkAwayView:refitArea()
    local v = self.view
    self.zoom_min = InkGeom.fitZoom(v)
    v.zoom = math.max(InkGeom.coverZoom(v), math.min(ZOOM_MAX, v.zoom))
    InkGeom.clampPan(v)
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
    self:renderView()
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
    self:redraw()
    return true
end

function InkAwayView:zoomStep(dir)
    self:flushPending()
    local factor = (dir > 0) and ZOOM_RATIO or (1 / ZOOM_RATIO)
    self:setZoom(self.view.zoom * factor)
end

-- Pinch (dir<0, fingers together -> zoom out) and spread (dir>0, fingers apart
-- -> zoom in) zoom the CANVAS, anchored at the gesture's midpoint, by an amount
-- proportional to how far the fingers moved. On e-ink a single anchored jump per
-- gesture (rather than a live continuous zoom) is what avoids ghosting.
function InkAwayView:pinchZoom(ges, dir)
    self:flushPending()
    self:cancelShape()
    local v = self.view
    local dist = (ges and ges.distance) or 0
    local ref = math.min(self.screen_w, self.screen_h) * 0.6
    local factor = 1 + math.min(dist, ref) / ref            -- up to ~2x per gesture
    local nz = (dir > 0) and (v.zoom * factor) or (v.zoom / factor)
    local pos = ges and ges.pos
    self:setZoom(nz, pos and pos.x, pos and pos.y)
end

-- Hide or show the top toolbar, growing the paper to fill the freed space. The
-- drawing-area buffer is reallocated and the view re-fitted, exactly as on a
-- screen-rotation relayout.
function InkAwayView:setToolbarHidden(hidden)
    if (self._toolbar_hidden or false) == hidden then return end
    self:flushPending()
    self._toolbar_hidden = hidden
    self._area_only = false   -- toolbar shown/hidden: the next paint must be full
    local v = self.view
    local th = self.toolbar:getSize().h
    v.area_y = hidden and 0 or th
    v.area_h = (hidden and self.screen_h or (self.screen_h - th)) - self.nb_bar_h
    -- when hidden, the toolbar buttons must not swallow taps in the freed strip
    -- (plain if/else: `hidden and nil or self.toolbar` would never yield nil)
    if hidden then self[1] = nil else self[1] = self.toolbar end
    self:refitArea()
    self:refresh(self, "full")
end

-- Hide or show the notebook bottom bar, growing the paper to fill the freed space
-- (mirrors setToolbarHidden). Honours a hidden toolbar too, so the two can be
-- collapsed independently.
function InkAwayView:setNbBarHidden(hidden)
    if not self.notebook then return end
    if (self._nb_collapsed or false) == hidden then return end
    self:flushPending()
    self._nb_collapsed = hidden
    self.nb_bar_h = self:nbBarHeight()      -- 0 when collapsed (see nbBarHeight)
    local v = self.view
    local th = self._toolbar_hidden and 0 or self.toolbar:getSize().h
    v.area_y = th
    v.area_h = self.screen_h - th - self.nb_bar_h
    self:refitArea()
    self:refresh(self, "full")
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
    self:redraw()
end

-- Recompute the drawing area (it shrinks by nb_bar_h in notebook mode) and the
-- fit zoom, then reallocate the on-screen buffer to the new height.
function InkAwayView:recomputeArea()
    local v = self.view
    local th = self.toolbar:getSize().h
    v.area_y = th
    v.area_h = self.screen_h - th - self.nb_bar_h
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
    self.zoom_min = InkGeom.fitZoom(v)
    -- Cover the whole area (no letterbox), exactly like a flat canvas; this keeps a
    -- notebook filling the device -- and, if its page shape differs from the screen
    -- after a rotation, still covers the area rather than centring with a margin.
    v.zoom = math.max(self.zoom_min, InkGeom.coverZoom(v))
    InkGeom.clampPan(v)
end

return InkAwayView
