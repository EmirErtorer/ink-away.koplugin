--[[
IconMenu: the sheet every tool menu opens in. It is built from stock KOReader
widgets (as ButtonDialog is), pinned under the toolbar or above the notebook bar,
and scrolls when it is taller than the screen.
]]

local Device = require("device")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

-- Shape chooser. Each entry shows the actual shape glyph next to its name; the
-- current one gets a checkmark. Shapes are drawn with the pen's size, opacity
-- and colour.
-- A lightweight modal composed of stock KOReader widgets, mirroring ButtonDialog's
-- machinery (CenterContainer > MovableContainer > FrameContainer) so it opens
-- reliably on device. `build(menu)` returns the FrameContainer (built with a
-- reference to the menu, so child CheckButtons can use it as their repaint
-- parent). A tap outside the panel, or Back, closes it.
--
-- The critical detail: UIManager:show(widget) with no refreshtype only marks the
-- widget dirty -- it paints into the buffer but schedules NO e-ink refresh, so
-- nothing reaches the panel and the menu looks like it "never opened". onShow must
-- schedule the refresh itself (as every stock modal does), with the region read
-- from a closure so movable.dimen is available (it is nil until first paintTo).
-- NOTE: deliberately NOT covers_fullscreen. The canvas below must keep painting
-- under the sheet (as ButtonDialog does): the sheet is smaller than the screen
-- and the child submenu is smaller than the parent, so covering the screen would
-- make _repaint skip the canvas and leave stale sheet pixels around a closing or
-- reopening smaller sheet (visible as ghost panels until you draw or refresh).
local IconMenu = InputContainer:extend{
    modal = true,              -- stay on top; don't let un-consumed gestures fall
                               -- through and draw on the canvas underneath
    build = nil,               -- function(menu) -> FrameContainer
    on_close = nil,
    top_y = nil,               -- if set, pin the sheet's top here (below the toolbar)
                               -- instead of centring it vertically
    bottom_y = nil,            -- if set, pin the sheet's BOTTOM here (e.g. touching
                               -- the notebook bottom bar); takes precedence over top_y
}
-- If the built sheet is taller than the screen allows (a long settings sheet, or
-- any sheet in short landscape), wrap its content in a ScrollableContainer capped to
-- the available height, so nothing is clipped -- it scrolls instead. This mirrors
-- how KOReader's own ButtonDialog copes with a button list taller than the screen.
-- Child-first gesture propagation means a pan inside the scroll area scrolls, while
-- MovableContainer only sees drags outside it, so the two coexist.
function IconMenu:fitFrame()
    if not self.frame then return end
    local content = self.frame[1]
    if not content or not content.getSize then return end
    local pad = Screen:scaleBySize(4)
    local avail
    if self.bottom_y then avail = self.bottom_y - pad
    else avail = Screen:getHeight() - (self.top_y or pad) - pad end
    local chrome = 2 * ((self.frame.padding or 0) + (self.frame.bordersize or 0))
    -- measuring can fail in the headless mock env (incomplete widgets); then just
    -- skip -- no scroll wrapper, exactly the old behaviour
    local ok, csz = pcall(function() return content:getSize() end)
    if not ok or not csz or csz.h + chrome <= avail then return end   -- fails or fits
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local sbw = ScrollableContainer:getScrollbarWidth()
    self.frame[1] = ScrollableContainer:new{
        dimen = GeomUI:new{ w = csz.w + sbw, h = math.max(1, avail - chrome) },
        show_parent = self,
        content,
    }
    self.frame._size = nil   -- drop any cached size so the frame remeasures
end

function IconMenu:init()
    local MovableContainer = require("ui/widget/container/movablecontainer")
    if self.build then self.frame = self:build(); self:fitFrame() end
    if Device:isTouchDevice() then
        self.ges_events = { TapClose = { GestureRange:new{ ges = "tap",
            range = GeomUI:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } } }
    end
    if Device:hasKeys() then
        self.key_events = { CloseMenu = { { Device.input.group.Back } } }
    end
    -- MovableContainer gives the content a reliable .dimen (set at paint time),
    -- and swallows drag gestures that start on the frame. We position it ourselves
    -- in paintTo (see below), so it is the sole child.
    self.movable = MovableContainer:new{ self.frame }
    self[1] = self.movable
end
-- The sheet opens OVER the drawing canvas, which holds dark ink and grid lines.
-- It MUST be shown with a flashing refresh ("flashui"): only a flash fully clears
-- the region to the opaque white sheet. A non-flashing "ui" morphs the dark pixels
-- in (a slow fade), and a 1-bit "fast"/A2 refresh does not clear at all, so the
-- grid and ink ghost straight through the sheet (it looks translucent) and every
-- later refresh has to fight that ghost. The flash is a deliberate, one-time cost
-- for a crisp, opaque sheet -- do not "optimise" it to fast/ui.
function IconMenu:onShow()
    UIManager:setDirty(self, function() return "flashui", self.movable.dimen end)
end
-- On close, UIManager repaints the uncovered canvas underneath, so a plain "ui"
-- brings it back with no black blink. (A "flashui" here would be a black flash
-- where the menu had been.) Free the content subtree (some sheets build
-- blitbuffers, e.g. brush previews).
function IconMenu:onCloseWidget()
    local region = self.movable and self.movable.dimen
    UIManager:setDirty(nil, function() return "ui", region end)
    if self.movable and self.movable.free then self.movable:free() end
end
-- Rebuild the sheet's contents in place (used when a control inside it changes
-- state, e.g. picking a brush or colour), instead of closing and reopening the
-- whole dialog. When the sheet keeps its footprint -- the common case, a
-- selection highlight moving -- refresh only that region with a non-flashing "ui"
-- (the sheet is already an opaque white rectangle on screen, so there is nothing
-- dark to clear): the same partial, no-flash update the sliders and toggles do.
-- Only when the footprint changes (a row added/removed) fall back to repainting
-- the exposed canvas and flashing the union.
function IconMenu:rebuild()
    if not (self.movable and self.build) then return end
    local old = self.movable.dimen and self.movable.dimen:copy()
    if self.movable.free then self.movable:free() end
    local MovableContainer = require("ui/widget/container/movablecontainer")
    self.frame = self:build()
    self:fitFrame()
    self.movable = MovableContainer:new{ self.frame }
    self[1] = self.movable
    UIManager:widgetRepaint(self, 0, 0)      -- paint the new contents; sets movable.dimen
    local new = self.movable.dimen
    if old and new and old.x == new.x and old.y == new.y
            and old.w == new.w and old.h == new.h then
        -- mark THIS menu dirty (not nil): if the same tap also repaints the view
        -- underneath (e.g. a shape pick refreshes the toolbar pill), the menu must
        -- be repainted on top of it, or the canvas would clobber the sheet.
        UIManager:setDirty(self, function() return "ui", new end)
    else
        local region = (old and new) and old:combine(new) or new
        UIManager:setDirty("all", function() return "flashui", region end)
    end
end
-- Paint the sheet horizontally centred and, when top_y is set, pinned just below
-- the toolbar (so tapping a toolbar tool drops its options right under the hand),
-- clamped to stay on screen. MovableContainer sets its own .dimen from where we
-- paint it, which we adopt for hit-testing and refresh regions.
function IconMenu:paintTo(bb, x, y)
    local sz = self.movable:getSize()
    local pad = Screen:scaleBySize(4)
    local px = math.floor((Screen:getWidth() - sz.w) / 2)
    local py
    if self.bottom_y then
        -- pin the sheet's BOTTOM here (e.g. touching the notebook bottom bar's top)
        py = math.max(pad, math.min(self.bottom_y - sz.h, Screen:getHeight() - sz.h - pad))
    elseif self.top_y then
        py = math.max(pad, math.min(self.top_y, Screen:getHeight() - sz.h - pad))
    else
        py = math.floor((Screen:getHeight() - sz.h) / 2)
    end
    self.movable:paintTo(bb, px, py)
    self.dimen = self.movable.dimen
end
function IconMenu:onTapClose(_, ges)
    if ges and ges.pos and self.movable.dimen
            and ges.pos:notIntersectWith(self.movable.dimen) then
        self:onCloseMenu()
    end
    return true
end
function IconMenu:onCloseMenu()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

return IconMenu
