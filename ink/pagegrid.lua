--[[
The page overview: a grid of page thumbnails for a notebook, so you can see the
whole thing at a glance and jump straight to any page instead of stepping one at
a time. Thumbnails are rendered on demand by a callback the view supplies (the
same compositor the live page uses, so a thumbnail matches its page exactly),
and only the grid page on screen is ever rendered or held in memory, so even a
long imported PDF stays light.

Full-screen, opaque, and it reads its own taps, like the brush maker.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local _ = require("gettext")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local GREY  = Blitbuffer.COLOR_GRAY
-- Luminance greys (Color8), so paintRoundedRect gets a luminance colour -- passing a
-- ColorRGB32 to it renders on the newer emulator but misbehaves on older on-device
-- builds, so the rounded cards/pills stay on the luminance path.
local CARD  = Blitbuffer.Color8(0xE6)   -- light-grey rounded card behind a thumbnail
local LABEL = Blitbuffer.Color8(0x66)   -- muted grey for the page-number labels

local PageGrid = InputContainer:extend{
    count = 1,          -- number of pages
    current = 1,        -- currently open page (highlighted)
    render = nil,       -- function(index, maxw, maxh) -> BlitBuffer (caller renders)
    on_pick = nil,      -- function(index) called when a thumbnail is tapped
    cols = 3,
    rows = 3,
    modal = true,
    stop_events_propagation = true,
}

function PageGrid:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.sw, self.sh = sw, sh
    self.top_h = Screen:scaleBySize(46)
    self.bot_h = Screen:scaleBySize(58)
    self.pad = Screen:scaleBySize(12)
    self.per = self.cols * self.rows
    -- start on the grid page holding the current page
    self.gpage = math.floor((self.current - 1) / self.per)
    self.cache = {}     -- index -> thumbnail BlitBuffer, for the visible grid page
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        self.ges_events = {
            PgTap   = { GestureRange:new{ ges = "tap", range = full } },
            PgSwipe = { GestureRange:new{ ges = "swipe", range = full } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { PgClose = { { Device.input.group.Back } } }
    end
end

function PageGrid:gridCount()
    return math.max(1, math.ceil(self.count / self.per))
end

-- Screen rect of cell `slot` (0-based) on the current grid page, plus the page
-- index it shows (or nil for an empty slot past the last page).
function PageGrid:cellRect(slot)
    local col = slot % self.cols
    local row = math.floor(slot / self.cols)
    local area_y = self.top_h
    local area_h = self.sh - self.top_h - self.bot_h
    local cw = math.floor((self.sw - self.pad * (self.cols + 1)) / self.cols)
    local ch = math.floor((area_h - self.pad * (self.rows + 1)) / self.rows)
    local x = self.pad + col * (cw + self.pad)
    local y = area_y + self.pad + row * (ch + self.pad)
    local index = self.gpage * self.per + slot + 1
    if index > self.count then index = nil end
    return { x = x, y = y, w = cw, h = ch, index = index }
end

-- Render (and cache) every thumbnail on the current grid page.
function PageGrid:prepare()
    if not self.render then return end
    local label_h = Screen:scaleBySize(22)
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.index and not self.cache[c.index] then
            self.cache[c.index] = self.render(c.index, c.w, c.h - label_h) or false
        end
    end
end

function PageGrid:freeCache()
    for k, bb in pairs(self.cache) do
        if bb and bb.free then bb:free() end
        self.cache[k] = nil
    end
end

function PageGrid:onShow()
    self:prepare()
    UIManager:setDirty(self, "full")
    return true
end

function PageGrid:paintTo(bb, x, y)
    self:prepare()
    local sw, sh = self.sw, self.sh
    local S = function(px) return Screen:scaleBySize(px) end
    bb:paintRect(x, y, sw, sh, WHITE)
    local function label(s, cx, cy, face, fgcolor)
        local t = TextWidget:new{ text = s, face = face, fgcolor = fgcolor or BLACK }
        local sz = t:getSize()
        t:paintTo(bb, math.floor(cx - sz.w / 2), math.floor(cy - sz.h / 2))
        t:free()
    end
    -- top bar: a left-aligned bold title and a black "Done" pill on the right.
    -- Font sizes are plain points (Font:getFace applies the DPI scaling itself);
    -- wrapping them in scaleBySize would double-scale the text, oversizing it on
    -- higher-DPI/colour panels -- which is what the old page grid did.
    local title = TextWidget:new{ text = string.format(_("Pages  (%d)"), self.count),
        face = Font:getFace("cfont", 22), bold = true }
    local tsz = title:getSize()
    title:paintTo(bb, x + self.pad, y + math.floor(self.top_h / 2 - tsz.h / 2))
    title:free()
    local pill_w, pill_h = S(84), S(34)
    local pill_x = x + sw - self.pad - pill_w
    local pill_y = y + math.floor(self.top_h / 2 - pill_h / 2)
    bb:paintRoundedRect(pill_x, pill_y, pill_w, pill_h, BLACK, S(11))
    self._close = { x = pill_x, y = pill_y, w = pill_w, h = pill_h }
    label(_("Done"), pill_x + pill_w / 2, pill_y + pill_h / 2, Font:getFace("cfont", 15), WHITE)
    bb:paintRect(x, y + self.top_h - 1, sw, 1, GREY)

    local label_h = S(22)
    local card_r = S(16)
    local nface = Font:getFace("cfont", 17)
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.index then
            local sel = (c.index == self.current)
            -- a rounded light-grey card behind each thumbnail; the current page gets a
            -- solid black rounded border (a black card with an inset grey card)
            if sel then
                bb:paintRoundedRect(x + c.x, y + c.y, c.w, c.h, BLACK, card_r)
                local ins = S(3)
                bb:paintRoundedRect(x + c.x + ins, y + c.y + ins, c.w - 2 * ins, c.h - 2 * ins, CARD, card_r)
            else
                bb:paintRoundedRect(x + c.x, y + c.y, c.w, c.h, CARD, card_r)
            end
            local thumb = self.cache[c.index]
            if thumb then
                local tw, th = thumb:getWidth(), thumb:getHeight()
                local tx = x + c.x + math.floor((c.w - tw) / 2)
                local ty = y + c.y + math.floor((c.h - label_h - th) / 2)
                bb:blitFrom(thumb, tx, ty, 0, 0, tw, th)
            end
            label(tostring(c.index), x + c.x + c.w / 2, y + c.y + c.h - label_h / 2, nface,
                sel and BLACK or LABEL)
        end
    end

    -- bottom bar: rounded pill paging buttons, with a "grid page / total" indicator
    local by = y + sh - self.bot_h
    local pw, ph = S(120), S(40)
    local pcy = by + math.floor(self.bot_h / 2)
    local pface = Font:getFace("cfont", 16)
    self._prev, self._next = nil, nil
    if self.gpage > 0 then
        local px0 = x + self.pad
        bb:paintRoundedRect(px0, pcy - math.floor(ph / 2), pw, ph, CARD, S(14))
        self._prev = { x = px0, y = pcy - math.floor(ph / 2), w = pw, h = ph }
        label("\u{2039} " .. _("Prev"), px0 + pw / 2, pcy, pface)
    end
    if self.gpage < self:gridCount() - 1 then
        local px0 = x + sw - self.pad - pw
        bb:paintRoundedRect(px0, pcy - math.floor(ph / 2), pw, ph, CARD, S(14))
        self._next = { x = px0, y = pcy - math.floor(ph / 2), w = pw, h = ph }
        label(_("More") .. " \u{203A}", px0 + pw / 2, pcy, pface)
    end
    if self:gridCount() > 1 then
        label(string.format("%d / %d", self.gpage + 1, self:gridCount()),
            x + sw / 2, pcy, Font:getFace("cfont", 15), LABEL)
    end
end

function PageGrid:gridGo(delta)
    local g = self.gpage + delta
    if g < 0 or g >= self:gridCount() then return end
    self:freeCache()          -- only the visible grid page is kept resident
    self.gpage = g
    self:prepare()
    UIManager:setDirty(self, "full")
end

function PageGrid:onPgTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    local function hit(r) return r and p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h end
    if hit(self._prev) then self:gridGo(-1); return true end
    if hit(self._next) then self:gridGo(1); return true end
    if hit(self._close) then UIManager:close(self); return true end
    -- a thumbnail?
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.index and p.x >= c.x and p.x <= c.x + c.w and p.y >= self.top_h and p.y <= self.sh - self.bot_h
           and p.y >= c.y and p.y <= c.y + c.h then
            local pick = c.index
            UIManager:close(self)
            if self.on_pick then self.on_pick(pick) end
            return true
        end
    end
    return true
end

function PageGrid:onPgSwipe(_, ges)
    local dir = ges and ges.direction
    if dir == "west" then self:gridGo(1) elseif dir == "east" then self:gridGo(-1) end
    return true
end

function PageGrid:onPgClose()
    UIManager:close(self)
    return true
end

function PageGrid:onCloseWidget()
    self:freeCache()
    UIManager:setDirty("all", "full")   -- restore the canvas cleanly underneath
end

return PageGrid
