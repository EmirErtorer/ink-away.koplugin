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
    bb:paintRect(x, y, sw, sh, WHITE)
    -- top bar
    local face = Font:getFace("cfont", Screen:scaleBySize(20))
    local function text(s, cx, cy, fgcolor)
        local t = TextWidget:new{ text = s, face = face, fgcolor = fgcolor or BLACK }
        local sz = t:getSize()
        t:paintTo(bb, math.floor(cx - sz.w / 2), math.floor(cy - sz.h / 2))
        t:free()
    end
    bb:paintRect(x, y + self.top_h - 1, sw, 1, GREY)
    text(string.format(_("Pages  (%d)"), self.count), x + sw / 2, y + self.top_h / 2)

    local label_h = Screen:scaleBySize(22)
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.index then
            -- thumbnail frame; thicker border on the current page
            local border = (c.index == self.current) and 3 or 1
            bb:paintBorder(x + c.x, y + c.y, c.w, c.h - label_h, border,
                (c.index == self.current) and BLACK or GREY)
            local thumb = self.cache[c.index]
            if thumb then
                local tw, th = thumb:getWidth(), thumb:getHeight()
                local tx = x + c.x + math.floor((c.w - tw) / 2)
                local ty = y + c.y + math.floor((c.h - label_h - th) / 2)
                bb:blitFrom(thumb, tx, ty, 0, 0, tw, th)
            end
            text(tostring(c.index), x + c.x + c.w / 2, y + c.y + c.h - label_h / 2,
                (c.index == self.current) and BLACK or GREY)
        end
    end

    -- bottom bar: grid paging + close
    local by = y + sh - self.bot_h
    bb:paintRect(x, by, sw, 1, GREY)
    local third = math.floor(sw / 3)
    self._prev = { x = x, y = by, w = third, h = self.bot_h }
    self._close = { x = x + third, y = by, w = sw - 2 * third, h = self.bot_h }
    self._next = { x = x + sw - third, y = by, w = third, h = self.bot_h }
    local bcy = by + self.bot_h / 2
    if self.gpage > 0 then text("\u{2039} " .. _("Prev"), x + third / 2, bcy) end
    text(_("Close"), x + sw / 2, bcy)
    if self.gpage < self:gridCount() - 1 then text(_("More") .. " \u{203A}", x + sw - third / 2, bcy) end
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
