--[[
The brush maker: a small studio for building your own brush. A sample stroke is
drawn live at the top with the brush as it stands, and below it a row of sliders
sets each aspect of the feel: how much ink it lays down, how coarse the grain is,
how soft the edge is, how far it spreads, and how much the paper tooth breaks it
up. Drag a slider and the sample redraws at once, so you tune by eye rather than
by typing numbers. When it looks right, name it and it joins the pen menu.

It paints itself and reads its own touches, so the sliders and the preview are
one piece. Everything is clipped to the panel, and the sample stroke is rendered
through the very same rasterizer the pen uses, so what you tune is exactly what
you will draw with.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local Raster = require("ink/raster")
local Brushes = require("ink/brushes")
local _ = require("gettext")

local Screen = Device.screen

local BrushMaker = InputContainer:extend{
    params = nil,       -- brush params being edited
    on_save = nil,      -- function(name, params) called when saved
    init_name = nil,    -- prefilled name (when editing an existing brush)
    modal = true,
    stop_events_propagation = true,
}

local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local GREY  = Blitbuffer.COLOR_GRAY

function BrushMaker:init()
    self.params = self.params or Brushes.defaults()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.box_w = math.floor(math.min(sw * 0.9, Screen:scaleBySize(440)))
    self.pad = Screen:scaleBySize(16)
    self.preview_h = Screen:scaleBySize(120)
    self.row_h = Screen:scaleBySize(52)
    self.btn_h = Screen:scaleBySize(48)
    self.title_h = Screen:scaleBySize(40)
    local rows = #Brushes.FIELDS
    local function measure()
        self.box_h = self.title_h + self.preview_h + self.pad
                     + rows * self.row_h + self.btn_h + self.pad * 2
    end
    measure()
    -- if the panel is taller than the screen (high-DPI devices), shrink its
    -- parts to fit so the title and the Save/Cancel buttons are never clipped
    local avail = sh - Screen:scaleBySize(24)
    if self.box_h > avail then
        local k = avail / self.box_h
        self.title_h = math.floor(self.title_h * k)
        self.preview_h = math.floor(self.preview_h * k)
        self.row_h = math.floor(self.row_h * k)
        self.btn_h = math.floor(self.btn_h * k)
        self.pad = math.max(4, math.floor(self.pad * k))
        measure()
    end
    self.box_x = math.floor((sw - self.box_w) / 2)
    self.box_y = math.max(Screen:scaleBySize(12), math.floor((sh - self.box_h) / 2))
    -- span the whole screen so the panel is always inside the painted and
    -- refreshed region (a box-sized dimen let the edges fall outside on some
    -- devices); keep the box rect separately for the cheap slider refreshes
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.panel = Geom:new{ x = self.box_x, y = self.box_y, w = self.box_w, h = self.box_h }

    self.preview_bb = Blitbuffer.new(self.box_w - self.pad * 2, self.preview_h, Screen.bb:getType())
    self:renderPreview()

    if Device:isTouchDevice() then
        -- capture the whole screen so a touch outside the panel cannot fall
        -- through and draw on the canvas behind it. Rate-limit the pan with
        -- GestureRange's own `rate` (KOReader's built-in mechanism, tuned per
        -- device via Screen.low_pan_rate) rather than a hand-rolled timer.
        local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        local pan_rate = Screen.low_pan_rate and 2.0 or 30.0
        self.ges_events = {
            BmTap = { GestureRange:new{ ges = "tap", range = full } },
            BmPan = { GestureRange:new{ ges = "pan", range = full, rate = pan_rate } },
            BmHoldPan = { GestureRange:new{ ges = "hold_pan", range = full, rate = pan_rate } },
        }
    end
end

-- Refresh the whole panel when first shown, so it renders in full straight away
-- (otherwise only the region left by the closing pen popup gets refreshed, which
-- clips the title and buttons until the first slider move).
function BrushMaker:onShow()
    UIManager:setDirty(self, "ui", self.panel)
    return true
end

-- Screen rect of slider `i`'s draggable track.
function BrushMaker:trackRect(i)
    local x = self.box_x + self.pad
    local w = self.box_w - self.pad * 2
    local y = self.box_y + self.title_h + self.preview_h + self.pad + (i - 1) * self.row_h
    local label_w = math.floor(w * 0.34)
    local tx = x + label_w
    local tw = w - label_w - Screen:scaleBySize(44)
    return tx, y + math.floor(self.row_h / 2), tw, y, w, x
end

-- The two bottom buttons as screen rects: returns save{}, cancel{}.
function BrushMaker:buttonRects()
    local y = self.box_y + self.box_h - self.btn_h - self.pad
    local w = self.box_w - self.pad * 2
    local half = math.floor((w - self.pad) / 2)
    return { x = self.box_x + self.pad, y = y, w = half, h = self.btn_h },
           { x = self.box_x + self.pad + half + self.pad, y = y, w = half, h = self.btn_h }
end

-- Render the sample stroke with the current params into preview_bb.
function BrushMaker:renderPreview()
    local bb = self.preview_bb
    local w, h = bb:getWidth(), bb:getHeight()
    bb:paintRect(0, 0, w, h, WHITE)
    local st = {}
    for k, v in pairs(self.params) do st[k] = v end
    local function put(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len > 0 then bb:paintRect(x, y, len, 1, BLACK) end
    end
    -- a gentle S so the stroke shows body, edge and taper
    local pts = {}
    local n = 40
    for i = 0, n do
        local u = i / n
        pts[#pts + 1] = self.pad + u * (w - self.pad * 2)
        pts[#pts + 1] = h / 2 + math.sin(u * math.pi * 2) * (h * 0.24)
    end
    local r = math.max(6, Screen:scaleBySize(9))
    if st.solid then
        Raster.path(pts, r, put)
    else
        Raster.pathTex(pts, r, put, st, 12345)
    end
end

function BrushMaker:paintTo(bb, x, y)
    local bx, by, bw, bh = self.box_x + x, self.box_y + y, self.box_w, self.box_h
    -- panel
    bb:paintRect(bx, by, bw, bh, WHITE)
    bb:paintBorder(bx, by, bw, bh, Size.border.window or 2, BLACK)

    -- title
    local title = TextWidget:new{ text = _("Create brush"), face = Font:getFace("tfont", 20), fgcolor = BLACK }
    title:paintTo(bb, bx + self.pad, by + math.floor((self.title_h - title:getSize().h) / 2))
    title:free()

    -- preview
    bb:blitFrom(self.preview_bb, bx + self.pad, by + self.title_h, 0, 0,
        self.preview_bb:getWidth(), self.preview_bb:getHeight())
    bb:paintBorder(bx + self.pad, by + self.title_h, self.preview_bb:getWidth(),
        self.preview_bb:getHeight(), 1, GREY)

    -- sliders
    for i, f in ipairs(Brushes.FIELDS) do
        local tx, cy, tw, ry, w, rx = self:trackRect(i)
        tx = tx + x; cy = cy + y; ry = ry + y; rx = rx + x
        -- label
        local lbl = TextWidget:new{ text = _(f.label), face = Font:getFace("cfont", 17), fgcolor = BLACK }
        lbl:paintTo(bb, rx, cy - math.floor(lbl:getSize().h / 2))
        lbl:free()
        -- track
        local th = Screen:scaleBySize(4)
        bb:paintRect(tx, cy - math.floor(th / 2), tw, th, GREY)
        local val = self.params[f.id] or f.min
        local frac = (val - f.min) / (f.max - f.min)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local fillw = math.floor(tw * frac)
        bb:paintRect(tx, cy - math.floor(th / 2), fillw, th, BLACK)
        -- knob
        local kr = Screen:scaleBySize(9)
        bb:paintRect(tx + fillw - kr, cy - kr, kr * 2, kr * 2, BLACK)
        -- value readout
        local shown = f.step and tostring(math.floor(val + 0.5))
                              or tostring(math.floor(frac * 100 + 0.5))
        local vw = TextWidget:new{ text = shown, face = Font:getFace("cfont", 15), fgcolor = BLACK }
        vw:paintTo(bb, tx + tw + Screen:scaleBySize(8), cy - math.floor(vw:getSize().h / 2))
        vw:free()
    end

    -- buttons
    local save, cancel = self:buttonRects()
    for _, b in ipairs({ { save, _("Save brush"), true }, { cancel, _("Cancel"), false } }) do
        local r, label = b[1], b[2]
        bb:paintBorder(r.x + x, r.y + y, r.w, r.h, b[3] and 2 or 1, BLACK)
        local t = TextWidget:new{ text = label, face = Font:getFace("cfont", 18), fgcolor = BLACK }
        t:paintTo(bb, r.x + x + math.floor((r.w - t:getSize().w) / 2),
                      r.y + y + math.floor((r.h - t:getSize().h) / 2))
        t:free()
    end
end

-- Which slider (if any) a screen point falls on, with a generous vertical band.
function BrushMaker:sliderAt(px, py)
    for i, f in ipairs(Brushes.FIELDS) do
        local tx, cy, tw = self:trackRect(i)
        if py >= cy - self.row_h / 2 and py <= cy + self.row_h / 2
           and px >= tx - Screen:scaleBySize(12) and px <= tx + tw + Screen:scaleBySize(12) then
            local frac = (px - tx) / tw
            if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
            local val = f.min + frac * (f.max - f.min)
            if f.step then val = math.floor(val / f.step + 0.5) * f.step end
            return f, val
        end
    end
end

function BrushMaker:setSlider(px, py)
    local f, val = self:sliderAt(px, py)
    if not f then return false end
    if self.params[f.id] ~= val then
        -- Pan events are already rate-limited by the GestureRange, so we can
        -- redraw the sample directly here without a separate throttle.
        self.params[f.id] = val
        self:renderPreview()
        UIManager:setDirty(self, "fast", self.panel)
    end
    return true
end

function BrushMaker:onBmTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if self:setSlider(p.x, p.y) then return true end
    local save, cancel = self:buttonRects()
    local function hit(r) return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h end
    if hit(save) then self:promptName(); return true end
    if hit(cancel) then UIManager:close(self); return true end
    -- a tap outside the panel dismisses it
    if p.x < self.box_x or p.x > self.box_x + self.box_w
       or p.y < self.box_y or p.y > self.box_y + self.box_h then
        UIManager:close(self)
    end
    return true
end

function BrushMaker:onBmPan(_, ges)
    local p = ges and ges.pos
    if p then self:setSlider(p.x, p.y) end
    return true
end
BrushMaker.onBmHoldPan = BrushMaker.onBmPan

function BrushMaker:promptName()
    -- Close the full-screen maker FIRST, then show the name entry. Otherwise the
    -- entry (and, on a device, the on-screen keyboard) is drawn behind this
    -- full-screen modal and gets hidden. Capture what we need before closing.
    local on_save, params, init_name = self.on_save, self.params, self.init_name
    UIManager:close(self)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Name this brush"),
        input = init_name or os.date("brush-%H%M%S"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dlg:getInputText()
                UIManager:close(dlg)
                if not name or name == "" then return end
                name = name:gsub("[/\\%[%]\"]", " ")   -- keep it a plain, storable name
                if on_save then on_save(name, params) end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function BrushMaker:onCloseWidget()
    if self.preview_bb then self.preview_bb:free(); self.preview_bb = nil end
    -- The maker is a floating panel over the canvas; when it leaves, repaint the
    -- whole screen so its frame is wiped and the canvas underneath is restored.
    -- "all" re-runs every remaining widget's paintTo (nil would only refresh the
    -- e-ink from the stale buffer). Without this the panel's edges linger and the
    -- name entry that opens next leaves a panel-shaped hole where it was.
    UIManager:setDirty("all", "full")
end

return BrushMaker
