--[[
InkSheet — a premium bottom sheet for the tool options (pen, eraser, shapes,
fill), replacing the stacked ButtonDialogs.

It is one full-screen InputContainer that paints a dim backdrop and a rounded
white sheet at the bottom, and draws its whole content itself (labels via
RenderText, everything else via Blitbuffer). Interaction is handled at the sheet
level by hit-testing the tapped point against each control's rect, which is far
simpler and more reliable on e-ink than composing dozens of sub-widgets.

The caller passes a `controls` list; each entry is a table with a `kind`:
  { kind="preview",  h=60, draw=function(bb,x,y,w,h) }
  { kind="swatches", items={{c=ColorRGB32, sel=bool}, ...}, rgb=bool,
                     on_pick=function(i)  (i is an index, or "rgb") }
  { kind="slider",   label=, val=, right=, on_set=function(v01) }  -- v01 in 0..1
  { kind="chips",    items={{t=text, sel=bool}, ...}, on_pick=function(i) }
  { kind="toggles",  items={{t=text, on=bool, cb=fn}, ...} }  -- 1..2 per row
  { kind="section",  text= }
The caller keeps its own state; on_pick/on_set/cb mutate it and usually call
sheet:refresh() to repaint.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local WHITE   = Blitbuffer.COLOR_WHITE
local INK     = Blitbuffer.ColorRGB32(0x19, 0x1A, 0x1C, 0xFF)
local SUB     = Blitbuffer.ColorRGB32(0x8A, 0x8D, 0x91, 0xFF)
local TRACK   = Blitbuffer.ColorRGB32(0xEA, 0xE8, 0xE1, 0xFF)
local CHIP_BG = Blitbuffer.ColorRGB32(0xF0, 0xEE, 0xE7, 0xFF)
local HAIR    = Blitbuffer.ColorRGB32(0xEF, 0xED, 0xE6, 0xFF)
local DIM     = Blitbuffer.ColorRGB32(0x19, 0x1A, 0x1C, 0x26)   -- backdrop veil

local InkSheet = InputContainer:extend{
    title = "",
    controls = nil,
    on_close = nil,
    covers_fullscreen = true,
}

local function S(px) return Screen:scaleBySize(px) end

function InkSheet:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.pad = S(18)
    self:layout()
    local range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {
        SheetTap = { GestureRange:new{ ges = "tap", range = range } },
        SheetPan = { GestureRange:new{ ges = "pan", range = range } },
        SheetPanRel = { GestureRange:new{ ges = "pan_release", range = range } },
        SheetHoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
    }
    if Device:hasKeys() then
        self.key_events = { SheetClose = { { Device.input.group.Back } } }
    end
end

-- Measure each control and stack them from the sheet top, giving each a y/h.
function InkSheet:layout()
    local content_w = self.screen_w - 2 * self.pad
    local y = S(14) + S(6)                -- handle
    y = y + S(30)                          -- title row
    for _, c in ipairs(self.controls or {}) do
        c._w = content_w
        if c.kind == "chips" then
            -- wrap chips into rows so many styles/brushes never overlap
            local gap, minw, chiph = S(7), S(88), S(40)
            local per = math.max(1, math.floor((content_w + gap) / (minw + gap)))
            local rows = math.ceil(#c.items / per)
            c._per, c._chiph, c._chgap, c._rows = per, chiph, gap, rows
            c.h = rows * chiph + (rows - 1) * S(8)
        else
            c.h = c.h or ({ preview = S(56), swatches = S(50), slider = S(52),
                            sliders2 = S(52), toggles = S(46), pilltoggles = S(44),
                            caption = S(20), divider = S(13), section = S(24) })[c.kind] or S(40)
        end
        c._y = y
        y = y + c.h + (c.kind == "section" and S(4) or S(14))
    end
    self.sheet_h = y + S(8)
    self.sheet_y = self.screen_h - self.sheet_h
    self.content_x = self.pad
end

function InkSheet:refresh()
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = self.sheet_y, w = self.screen_w, h = self.sheet_h })
end

function InkSheet:getSize() return self.dimen end

-- ---- painting -------------------------------------------------------------

function InkSheet:face(px, bold)
    local Font = require("ui/font")
    self._faces = self._faces or {}
    local key = px .. (bold and "b" or "")
    if not self._faces[key] then
        self._faces[key] = Font:getFace(bold and "cfont" or "cfont", px)
    end
    return self._faces[key]
end

function InkSheet:text(bb, x, y, px, str, color, bold)
    local RenderText = require("ui/rendertext")
    RenderText:renderUtf8Text(bb, x, math.floor(y), self:face(px, bold), str, true, false, color or INK)
end

function InkSheet:paintTo(bb, x, y)
    -- backdrop veil over the whole screen
    bb:paintRect(0, 0, self.screen_w, self.screen_h, DIM)
    local sy = self.sheet_y
    -- sheet: white, rounded top (round all corners; the bottom sits off-screen)
    bb:paintRoundedRect(0, sy, self.screen_w, self.sheet_h + S(24), WHITE, S(20))
    -- grab handle
    local hw = S(40)
    bb:paintRoundedRect(math.floor((self.screen_w - hw) / 2), sy + S(9), hw, S(5),
        Blitbuffer.ColorRGB32(0xDC, 0xD9, 0xD0, 0xFF), S(2))
    -- title + Done pill
    local RenderText = require("ui/rendertext")
    local title_y = sy + S(20) + S(10)
    self:text(bb, self.content_x, title_y, S(19), self.title, INK, true)
    if self.title_draw then
        local tw = RenderText:sizeUtf8Text(0, nil, self:face(S(19), true), self.title, true).x
        local pw = S(96)
        self.title_draw(bb, self.content_x + tw + S(16), sy + S(20) - S(2), pw, S(28))
    end
    local dlabel = "Done"
    local dtw = RenderText:sizeUtf8Text(0, nil, self:face(S(13), true), dlabel, true).x
    local done_w, done_h = dtw + S(30), S(30)
    self._done_rect = { x = self.screen_w - self.pad - done_w, y = sy + S(20) + S(2), w = done_w, h = done_h }
    bb:paintRoundedRect(self._done_rect.x, self._done_rect.y, done_w, done_h, INK, S(11))
    self:text(bb, self._done_rect.x + math.floor((done_w - dtw) / 2), self._done_rect.y + S(20), S(13), dlabel, WHITE, true)

    for _, c in ipairs(self.controls) do
        local cy = sy + c._y
        local cx = self.content_x
        if c.kind == "section" then
            self:text(bb, cx, cy + S(16), S(12), c.text or "", SUB, true)
        elseif c.kind == "preview" then
            bb:paintRoundedRect(cx, cy, c._w, c.h, Blitbuffer.ColorRGB32(0xF9,0xF8,0xF4,0xFF), S(12))
            bb:paintBorder(cx, cy, c._w, c.h, 1, HAIR, S(12))
            if c.draw then c.draw(bb, cx, cy, c._w, c.h) end
        elseif c.kind == "swatches" then
            self:paintSwatches(bb, cx, cy, c)
        elseif c.kind == "slider" then
            self:paintSlider(bb, cx, cy, c)
        elseif c.kind == "sliders2" then
            self:paintSliders2(bb, cx, cy, c)
        elseif c.kind == "chips" then
            self:paintChips(bb, cx, cy, c)
        elseif c.kind == "toggles" then
            self:paintToggles(bb, cx, cy, c)
        elseif c.kind == "pilltoggles" then
            self:paintPillToggles(bb, cx, cy, c)
        elseif c.kind == "caption" then
            self:text(bb, cx, cy + S(13), S(11), c.text or "", SUB, false)
        elseif c.kind == "divider" then
            bb:paintRect(cx, cy + math.floor(c.h / 2), c._w, math.max(1, S(1)), HAIR)
        end
    end
end

function InkSheet:paintSwatches(bb, x, y, c)
    local d = S(30)
    local gap = S(12)
    c._hit = {}
    local cxp = x
    for i, it in ipairs(c.items) do
        bb:paintRoundedRect(cxp, y, d, d, it.c, math.floor(d / 2))
        bb:paintBorder(cxp, y, d, d, math.max(1, S(1)), Blitbuffer.ColorRGB32(0xDC,0xD9,0xD0,0xFF), math.floor(d / 2))
        if it.sel then bb:paintBorder(cxp - S(3), y - S(3), d + S(6), d + S(6), S(2), INK, math.floor(d / 2) + S(3)) end
        c._hit[i] = { x = cxp, y = y, w = d, h = d }
        cxp = cxp + d + gap
    end
    if c.rgb then
        local rx = x + c._w - d
        -- a ring to signal the RGB picker (grey on mono; real wheel on colour)
        bb:paintBorder(rx, y, d, d, S(3), SUB, math.floor(d / 2))
        c._rgb_rect = { x = rx, y = y, w = d, h = d }
    end
end

-- Draw one slider (label + value + track + knob) inside [x, x+tw]; returns its
-- hit rect so both single and paired sliders can share the geometry.
function InkSheet:drawSlider(bb, x, y, tw, h, s)
    local RenderText = require("ui/rendertext")
    self:text(bb, x, y + S(12), S(12), s.label or "", SUB, true)
    if s.right then
        local w = RenderText:sizeUtf8Text(0, nil, self:face(S(12), true), s.right, true).x
        self:text(bb, x + tw - w, y + S(12), S(12), s.right, Blitbuffer.ColorRGB32(0x3A,0x3B,0x3D,0xFF), true)
    end
    local ty = y + h - S(12)
    bb:paintRoundedRect(x, ty, tw, S(4), TRACK, S(2))
    local v = math.max(0, math.min(1, s.val or 0))
    bb:paintRoundedRect(x, ty, math.max(S(4), math.floor(tw * v)), S(4), INK, S(2))
    local kn = S(20)
    local kx = x + math.floor(tw * v) - kn / 2
    kx = math.max(x - S(2), math.min(x + tw - kn + S(2), kx))
    bb:paintRoundedRect(kx, ty - kn / 2 + S(2), kn, kn, WHITE, math.floor(kn / 2))
    bb:paintBorder(kx, ty - kn / 2 + S(2), kn, kn, math.max(1, S(1)), INK, math.floor(kn / 2))
    return { x = x, y = y, w = tw, h = h }
end

function InkSheet:paintSlider(bb, x, y, c)
    c._track = self:drawSlider(bb, x, y, c._w, c.h, c)
end

-- Two sliders side by side (e.g. WIDTH | OPACITY), halving the vertical space.
function InkSheet:paintSliders2(bb, x, y, c)
    local gap = S(24)
    local hw = math.floor((c._w - gap) / 2)
    c._track_l = self:drawSlider(bb, x, y, hw, c.h, c.left)
    c._track_r = self:drawSlider(bb, x + hw + gap, y, hw, c.h, c.right)
end

-- Toggles rendered as full pill buttons (dark + check when on), 1..2 per row,
-- matching the flagship mock.
function InkSheet:paintPillToggles(bb, x, y, c)
    local RenderText = require("ui/rendertext")
    local n = #c.items
    local gap = S(14)
    local cw = math.floor((c._w - gap * (n - 1)) / n)
    c._hit = {}
    for i, it in ipairs(c.items) do
        local px = x + (i - 1) * (cw + gap)
        bb:paintRoundedRect(px, y, cw, c.h, it.on and INK or CHIP_BG, S(12))
        local label = (it.on and "✓ " or "") .. it.t
        local col = it.on and WHITE or INK
        local tw = RenderText:sizeUtf8Text(0, nil, self:face(S(13), true), label, true).x
        RenderText:renderUtf8Text(bb, px + math.max(S(8), math.floor((cw - tw) / 2)),
            y + math.floor(c.h / 2) + S(5), self:face(S(13), true), label, true, false, col, cw - S(12))
        c._hit[i] = { x = px, y = y, w = cw, h = c.h }
    end
end

function InkSheet:paintChips(bb, x, y, c)
    local per, chiph, gap = c._per, c._chiph, c._chgap
    local cw = math.floor((c._w - gap * (per - 1)) / per)
    local RenderText = require("ui/rendertext")
    c._hit = {}
    for i, it in ipairs(c.items) do
        local col = (i - 1) % per
        local rowi = math.floor((i - 1) / per)
        local px = x + col * (cw + gap)
        local py = y + rowi * (chiph + S(8))
        bb:paintRoundedRect(px, py, cw, chiph, it.sel and INK or CHIP_BG, S(11))
        local tw = RenderText:sizeUtf8Text(0, nil, self:face(S(12), it.sel), it.t, true).x
        -- clip overly long custom names to the chip
        local tx = px + math.max(S(6), math.floor((cw - tw) / 2))
        RenderText:renderUtf8Text(bb, tx, py + math.floor(chiph / 2) + S(5), self:face(S(12), it.sel),
            it.t, true, false, it.sel and WHITE or INK, cw - S(10))
        c._hit[i] = { x = px, y = py, w = cw, h = chiph }
    end
end

function InkSheet:paintToggles(bb, x, y, c)
    local n = #c.items
    local gap = S(14)
    local cw = math.floor((c._w - gap * (n - 1)) / n)
    c._hit = {}
    for i, it in ipairs(c.items) do
        local px = x + (i - 1) * (cw + gap)
        self:text(bb, px, y + math.floor(c.h / 2) + S(5), S(13), it.t, INK, true)
        local sw, sh = S(46), S(27)
        local tx = px + cw - sw
        local ty = y + math.floor((c.h - sh) / 2)
        bb:paintRoundedRect(tx, ty, sw, sh, it.on and INK or Blitbuffer.ColorRGB32(0xE4,0xE1,0xD9,0xFF), math.floor(sh / 2))
        local kd = sh - S(6)
        local kx = it.on and (tx + sw - kd - S(3)) or (tx + S(3))
        bb:paintRoundedRect(kx, ty + S(3), kd, kd, WHITE, math.floor(kd / 2))
        c._hit[i] = { x = px, y = y, w = cw, h = c.h }
    end
end

-- ---- gestures -------------------------------------------------------------

local function inR(p, r) return r and p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h end

function InkSheet:close()
    UIManager:close(self)
    if self.on_close then self.on_close() end
end

function InkSheet:onSheetClose() self:close(); return true end

function InkSheet:onSheetTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if p.y < self.sheet_y then self:close(); return true end       -- tap the backdrop
    if inR(p, self._done_rect) then self:close(); return true end
    for _, c in ipairs(self.controls) do
        if c.kind == "swatches" then
            for i, r in ipairs(c._hit or {}) do if inR(p, r) then c.on_pick(i); return true end end
            if c._rgb_rect and inR(p, c._rgb_rect) then c.on_pick("rgb"); return true end
        elseif c.kind == "chips" then
            for i, r in ipairs(c._hit or {}) do if inR(p, r) then c.on_pick(i); return true end end
        elseif c.kind == "toggles" or c.kind == "pilltoggles" then
            for i, r in ipairs(c._hit or {}) do if inR(p, r) then c.items[i].cb(); return true end end
        elseif c.kind == "slider" and inR(p, c._track) then
            c.on_set(math.max(0, math.min(1, (p.x - c._track.x) / c._track.w)))
            return true
        elseif c.kind == "sliders2" then
            if inR(p, c._track_l) then c.left.on_set(math.max(0, math.min(1, (p.x - c._track_l.x) / c._track_l.w))); return true end
            if inR(p, c._track_r) then c.right.on_set(math.max(0, math.min(1, (p.x - c._track_r.x) / c._track_r.w))); return true end
        end
    end
    return true
end

function InkSheet:onSheetPan(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    local function near(t) return t and p.x >= t.x - S(20) and p.x <= t.x + t.w + S(20)
        and p.y >= t.y - S(10) and p.y <= t.y + t.h + S(10) end
    for _, c in ipairs(self.controls) do
        if c.kind == "slider" and near(c._track) then
            c.on_set(math.max(0, math.min(1, (p.x - c._track.x) / c._track.w)))
            return true
        elseif c.kind == "sliders2" then
            if near(c._track_l) then c.left.on_set(math.max(0, math.min(1, (p.x - c._track_l.x) / c._track_l.w))); return true end
            if near(c._track_r) then c.right.on_set(math.max(0, math.min(1, (p.x - c._track_r.x) / c._track_r.w))); return true end
        end
    end
    return true
end
InkSheet.onSheetHoldPan = InkSheet.onSheetPan
function InkSheet:onSheetPanRel() return true end

return InkSheet
