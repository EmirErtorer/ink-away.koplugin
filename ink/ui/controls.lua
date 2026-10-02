--[[
The two row controls used in the sheets: ToggleRow (a label and a sliding switch)
and SliderRow (a label, a draggable track and the value).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen

-- A classic sliding on/off toggle row: a label on the left and a pill switch on
-- the right (grey track + white knob at left when off; black track + knob at
-- right when on). The whole row is one tap target and flips in place; `parent`
-- is the shown widget used as the repaint target.
local ToggleRow = InputContainer:extend{
    label = "", is_on = false, width = nil, callback = nil, parent = nil,
}
local TRACK_OFF = Blitbuffer.Color8(0xCF)   -- greys as Color8: rounded corners drawn in C
local KNOB_EDGE = Blitbuffer.Color8(0x99)
function ToggleRow:init()
    self.sw_h = Screen:scaleBySize(30)
    self.sw_w = Screen:scaleBySize(54)
    self:_build()
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap",
            range = function() return self.dimen end } } }
    end
end
function ToggleRow:_switch()
    local w, h = self.sw_w, self.sw_h
    local track = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
        radius = math.floor(h / 2), background = self.is_on and Blitbuffer.COLOR_BLACK or TRACK_OFF,
        WidgetContainer:new{ dimen = GeomUI:new{ w = w, h = h } } }
    local knob = h - Screen:scaleBySize(6)
    local inset = Screen:scaleBySize(3)
    local knobFrame = FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = KNOB_EDGE,
        padding = 0, margin = 0, radius = math.floor(knob / 2), background = Blitbuffer.COLOR_WHITE,
        WidgetContainer:new{ dimen = GeomUI:new{ w = knob - Screen:scaleBySize(2), h = knob - Screen:scaleBySize(2) } } }
    knobFrame.overlap_offset = { self.is_on and (w - knob - inset) or inset, math.floor((h - knob) / 2) }
    return OverlapGroup:new{ dimen = { w = w, h = h }, allow_mirroring = false, track, knobFrame }
end
function ToggleRow:_build()
    local label = TextWidget:new{ text = self.label, face = Font:getFace("cfont", 18) }
    local sw = self:_switch()
    local span
    if self.compact then
        -- toggle sits just after the label; the row is only as wide as its content
        span = Screen:scaleBySize(12)
        self.width = label:getSize().w + span + self.sw_w
    else
        span = math.max(Screen:scaleBySize(8), self.width - label:getSize().w - self.sw_w)
    end
    self[1] = HorizontalGroup:new{ align = "center",
        label, HorizontalSpan:new{ width = span }, sw }
    local sz = self[1]:getSize()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.width, h = sz.h }
end
function ToggleRow:onTap()
    self.is_on = not self.is_on
    self:_build()
    if self.callback then self.callback(self.is_on) end
    UIManager:setDirty(self.parent or self, "ui", self.dimen)
    return true
end
function ToggleRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

-- A horizontal slider row (0..100): a label on the left, a draggable track in
-- the middle, and the value on the right. Tap or drag the track to set it; the
-- value flips in place. `parent` is the shown widget used as the repaint target.
local SliderRow = InputContainer:extend{
    label = "", value = 0, width = nil, on_set = nil, parent = nil,
    min = 0, max = 100, step = 1, format = nil,   -- format(v) -> value text (default "N%")
}
function SliderRow:_fmt(v) return self.format and self.format(v) or string.format("%d%%", v) end
function SliderRow:init()
    self.knob = Screen:scaleBySize(26)
    self.track_h = Screen:scaleBySize(8)
    self:_build()
    if Device:isTouchDevice() then
        local range = function() return self.dimen end
        self.ges_events = {
            SlTap = { GestureRange:new{ ges = "tap", range = range } },
            SlPan = { GestureRange:new{ ges = "pan", range = range } },
            SlPanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
            SlHold = { GestureRange:new{ ges = "hold", range = range } },
            SlHoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        }
    end
end
function SliderRow:_build()
    local gap = Screen:scaleBySize(14)
    local labelw = TextWidget:new{ text = self.label, face = Font:getFace("cfont", 18) }
    local valw = TextWidget:new{ text = self:_fmt(self.value),
        face = Font:getFace("cfont", 16), bold = true }
    -- reserve a fixed width for the value (measured at the max) so the track
    -- doesn't jump as digits change
    local wmax = TextWidget:new{ text = self:_fmt(self.max), face = Font:getFace("cfont", 16), bold = true }
    local val_w = math.max(wmax:getSize().w, Screen:scaleBySize(40)); wmax:free()
    local track_w = self.width - labelw:getSize().w - val_w - 2 * gap
    self._track_w = track_w
    self._track_dx = labelw:getSize().w + gap
    local frac = math.max(0, math.min(1, (self.value - self.min) / (self.max - self.min)))
    local th, kn = self.track_h, self.knob
    local ty = math.floor((kn - th) / 2)
    local fillW = math.max(th, math.floor(track_w * frac))
    local track = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, radius = math.floor(th / 2),
        background = TRACK_OFF, WidgetContainer:new{ dimen = GeomUI:new{ w = track_w, h = th } } }
    track.overlap_offset = { 0, ty }
    local fill = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, radius = math.floor(th / 2),
        background = Blitbuffer.COLOR_BLACK, WidgetContainer:new{ dimen = GeomUI:new{ w = fillW, h = th } } }
    fill.overlap_offset = { 0, ty }
    local knob = FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = KNOB_EDGE,
        padding = 0, margin = 0, radius = math.floor(kn / 2), background = Blitbuffer.COLOR_WHITE,
        WidgetContainer:new{ dimen = GeomUI:new{ w = kn - Screen:scaleBySize(2), h = kn - Screen:scaleBySize(2) } } }
    local knobX = math.max(0, math.min(track_w - kn, math.floor(track_w * frac) - math.floor(kn / 2)))
    knob.overlap_offset = { knobX, 0 }
    local trackGroup = OverlapGroup:new{ dimen = { w = track_w, h = kn }, allow_mirroring = false,
        track, fill, knob }
    self[1] = HorizontalGroup:new{ align = "center",
        labelw, HorizontalSpan:new{ width = gap }, trackGroup, HorizontalSpan:new{ width = gap }, valw }
    -- references so _apply can update the moving parts in place, without rebuilding
    -- the whole row (and re-measuring text) on every drag tick
    self._fill_wc, self._knob, self._valw = fill[1], knob, valw
    local sz = self[1]:getSize()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.width, h = sz.h }
end
-- Update only the fill width, knob position and value text for the current value,
-- in place -- no widget/text-shaping churn per drag tick.
function SliderRow:_apply()
    local track_w, th, kn = self._track_w, self.track_h, self.knob
    local frac = math.max(0, math.min(1, (self.value - self.min) / (self.max - self.min)))
    if self._fill_wc then self._fill_wc.dimen.w = math.max(th, math.floor(track_w * frac)) end
    if self._knob then
        self._knob.overlap_offset[1] =
            math.max(0, math.min(track_w - kn, math.floor(track_w * frac) - math.floor(kn / 2)))
    end
    if self._valw then self._valw:setText(self:_fmt(self.value)) end
end
function SliderRow:_setFromX(x, mode)
    if not (self.dimen and self._track_w and self._track_w > 0) then return end
    local rel = x - (self.dimen.x + self._track_dx)
    local frac = math.max(0, math.min(1, rel / self._track_w))
    local v = self.min + frac * (self.max - self.min)
    v = self.min + math.floor((v - self.min) / self.step + 0.5) * self.step
    v = math.max(self.min, math.min(self.max, v))
    if v ~= self.value then
        self.value = v
        self:_apply()   -- update the moving parts in place; no rebuild, dimen unchanged
        if self.on_set then self.on_set(v) end
        -- Refresh only the track-to-value band, not the whole row, and use the fast
        -- (A2, monochrome) waveform WHILE dragging so the black fill, white knob and
        -- value follow the finger crisply; settle to grey-capable "ui" on release so
        -- the light-grey track renders correctly (A2 can't show its grey). This is
        -- what stops a slider drag from flashing a screen-wide GC16 strip per tick.
        -- self.parent (the sheet) is still the repaint target so the menu stays on
        -- top of any canvas the on_set refreshed underneath (e.g. a grid preview).
        local band = GeomUI:new{ x = self.dimen.x + self._track_dx, y = self.dimen.y,
            w = self.width - self._track_dx, h = self.dimen.h }
        UIManager:setDirty(self.parent or self, mode or "ui", band)
    end
end
function SliderRow:onSlTap(_, ges) self:_setFromX(ges.pos.x, "ui"); return true end
function SliderRow:onSlPan(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlHold(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlHoldPan(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlPanRelease(_, ges) if ges and ges.pos then self:_setFromX(ges.pos.x, "ui")
    else UIManager:setDirty(self.parent or self, "ui", self.dimen) end; return true end
function SliderRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

return { ToggleRow = ToggleRow, SliderRow = SliderRow }
