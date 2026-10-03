--[[
A full-screen grid of cards, paged: the page overview and the library. Each card
is a folder or a thumbnail with a name under it; a tap picks it, a hold asks for
its menu. Thumbnails come from a callback, and only the grid page on screen is
rendered and kept, so a long notebook or a full folder stays light. An optional
column of tabs on the left (the notebooks of a folder, in the overview) chooses
what the grid shows.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local GREY  = Blitbuffer.COLOR_GRAY
-- Luminance greys (Color8): paintRoundedRect misbehaves with a ColorRGB32 on
-- older device builds.
local CARD  = Blitbuffer.Color8(0xE6)   -- light-grey rounded card behind a thumbnail
local LABEL = Blitbuffer.Color8(0x66)   -- muted grey for names and notes

local ThumbGrid = InputContainer:extend{
    title = "",
    items = nil,        -- list of { label, sub, folder = bool, selected = bool, star = bool }
    render = nil,       -- function(item, maxw, maxh) -> BlitBuffer or nil (the grid frees it)
    on_pick = nil,      -- function(item) after a tap; the grid stays open unless it closes itself
    on_hold = nil,      -- function(item) after a hold
    on_back = nil,      -- function(): shows a back arrow before the title
    on_close = nil,     -- function() once the grid has closed
    actions = nil,      -- header buttons left of the close pill: { { label, cb, dark }, ... }
    close_label = nil,  -- the close pill's text (Done by default)
    empty_text = nil,   -- shown when there are no items
    folder_icon = nil,  -- path of the SVG drawn on folder cards
    on_title = nil,     -- function() for a tap on the title
    tabs = nil,         -- list of { label, color = Blitbuffer colour or nil, selected = bool }
    on_tab = nil,       -- function(tab) after a tap on a tab
    on_tab_hold = nil,  -- function(tab) after a hold on a tab
    tab_footer = nil,   -- { label, cb }: a button under the tabs
    start = 1,          -- the item whose grid page shows first
    cols = nil,         -- 3 x 3 cards, or 4 x 2 on a wide screen, unless given
    rows = nil,
    -- not modal: its menus and prompts must open on top of it
    stop_events_propagation = true,
}

function ThumbGrid:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.sw, self.sh = sw, sh
    self.top_h = Screen:scaleBySize(54)
    self.bot_h = Screen:scaleBySize(58)
    self.pad = Screen:scaleBySize(12)
    self.label_h = Screen:scaleBySize(22)
    local wide = sw > sh
    -- with tabs, the cards share the width with the tab column
    self.tab_w = self.tabs and math.floor(sw * (wide and 0.24 or 0.32)) or 0
    self.tpage = 0
    if self.tabs then
        self.cols = self.cols or (wide and 3 or 2)
        self.rows = self.rows or (wide and 2 or 3)
    end
    self.cols = self.cols or (wide and 4 or 3)
    self.rows = self.rows or (wide and 2 or 3)
    self.per = self.cols * self.rows
    self.items = self.items or {}
    self.gpage = math.floor(((self.start or 1) - 1) / self.per)
    self.cache = {}     -- item -> thumbnail BlitBuffer, for the visible grid page
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        self.ges_events = {
            TgTap   = { GestureRange:new{ ges = "tap", range = full } },
            TgHold  = { GestureRange:new{ ges = "hold", range = full } },
            TgSwipe = { GestureRange:new{ ges = "swipe", range = full } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { TgClose = { { Device.input.group.Back } } }
    end
end

function ThumbGrid:gridCount()
    return math.max(1, math.ceil(#self.items / self.per))
end

-- Replace the cards (after a rename, a move, a new folder...), keeping the grid
-- page when it still exists, and optionally the tabs.
function ThumbGrid:setItems(items, title, tabs)
    self:freeCache()
    self.items = items or {}
    if title then self.title = title end
    if tabs then self.tabs = tabs end
    self.gpage = math.min(self.gpage, self:gridCount() - 1)
    UIManager:setDirty(self, "ui")
end

-- The tab column's layout: tab height and gap, how many tabs fit, and the rects
-- of the paging arrows and the footer button.
function ThumbGrid:tabLayout()
    local th, gap = Screen:scaleBySize(52), Screen:scaleBySize(8)
    local top = self.top_h + self.pad
    local bottom = self.sh - self.bot_h
    local x, w = self.pad, self.tab_w - self.pad
    local foot = self.tab_footer and { x = x, y = bottom - th, w = w - self.pad, h = th } or nil
    local avail = (foot and foot.y - gap or bottom) - top
    local fit = math.max(1, math.floor((avail + gap) / (th + gap)))
    local arrows
    if #self.tabs > fit then
        fit = math.max(1, fit - 1)   -- a row for the arrows
        local ay = top + fit * (th + gap)
        local aw = math.floor((w - self.pad - gap) / 2)
        arrows = { up = { x = x, y = ay, w = aw, h = th }, down = { x = x + aw + gap, y = ay, w = aw, h = th } }
    end
    return { th = th, gap = gap, top = top, x = x, w = w, fit = fit, foot = foot, arrows = arrows }
end

-- Screen rect of the tab in slot `i` (0-based) of the shown tab page, and the tab.
function ThumbGrid:tabRect(L, i)
    local tab = self.tabs[self.tpage * L.fit + i + 1]
    return { x = L.x, y = L.top + i * (L.th + L.gap), w = L.w, h = L.th, tab = tab }
end

-- Show the tab page holding the selected tab.
function ThumbGrid:showSelectedTab()
    if not self.tabs then return end
    local L = self:tabLayout()
    for i, t in ipairs(self.tabs) do
        if t.selected then self.tpage = math.floor((i - 1) / L.fit) end
    end
end

-- Screen rect of cell `slot` (0-based) on the current grid page, plus the item
-- it shows (or nil for an empty slot past the last one).
function ThumbGrid:cellRect(slot)
    local col = slot % self.cols
    local row = math.floor(slot / self.cols)
    local area_h = self.sh - self.top_h - self.bot_h
    local area_w = self.sw - self.tab_w
    local cw = math.floor((area_w - self.pad * (self.cols + 1)) / self.cols)
    local ch = math.floor((area_h - self.pad * (self.rows + 1)) / self.rows)
    local x = self.tab_w + self.pad + col * (cw + self.pad)
    local y = self.top_h + self.pad + row * (ch + self.pad)
    return { x = x, y = y, w = cw, h = ch, item = self.items[self.gpage * self.per + slot + 1] }
end

-- Render (and cache) every thumbnail on the current grid page.
function ThumbGrid:prepare()
    if not self.render then return end
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.item and not c.item.folder and self.cache[c.item] == nil then
            local ok, bb = pcall(self.render, c.item, c.w - 2 * self.pad, c.h - self.label_h - 2 * self.pad)
            self.cache[c.item] = ok and bb or false
        end
    end
end

function ThumbGrid:freeCache()
    for k, bb in pairs(self.cache) do
        if bb and bb.free then bb:free() end
        self.cache[k] = nil
    end
end

-- The folder icon on a card-coloured tile, drawn once per size.
function ThumbGrid:folderTile(sz)
    if self._folder and self._folder.sz == sz then return self._folder.bb end
    if self._folder and self._folder.bb then self._folder.bb:free() end
    self._folder = { sz = sz }
    if not self.folder_icon then return nil end
    local ok, raw, straight = pcall(function()
        return RenderImage:renderSVGImageFile(self.folder_icon, sz, sz)
    end)
    if ok and raw then
        local w, h = raw:getWidth(), raw:getHeight()
        local tile = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        tile:fill(CARD)
        if straight then tile:alphablitFrom(raw, 0, 0, 0, 0, w, h)
        else tile:pmulalphablitFrom(raw, 0, 0, 0, 0, w, h) end
        raw:free()
        self._folder.bb = tile
    end
    return self._folder.bb
end

function ThumbGrid:onShow()
    self:showSelectedTab()
    self:prepare()
    UIManager:setDirty(self, "full")
    return true
end

function ThumbGrid:paintTo(bb, x, y)
    self:prepare()
    local sw, sh = self.sw, self.sh
    local S = function(px) return Screen:scaleBySize(px) end
    bb:paintRect(x, y, sw, sh, WHITE)
    local function label(s, cx, cy, face, fgcolor, max_w, bold)
        local t = TextWidget:new{ text = s, face = face, fgcolor = fgcolor or BLACK, bold = bold,
            max_width = max_w }
        local sz = t:getSize()
        t:paintTo(bb, math.floor(cx - sz.w / 2), math.floor(cy - sz.h / 2))
        t:free()
    end
    -- top bar: an optional back arrow and the title on the left, then the action
    -- pills and a black close pill on the right; font sizes are plain points, as
    -- Font:getFace applies the DPI scaling
    local pill_h = S(36)
    local pill_y = y + math.floor(self.top_h / 2 - pill_h / 2)
    local pface = Font:getFace("cfont", 15)
    local right = x + sw - self.pad
    local function pill(text, dark)
        local t = TextWidget:new{ text = text, face = pface, bold = true }
        local w = math.max(S(84), t:getSize().w + S(28))
        t:free()
        right = right - w
        bb:paintRoundedRect(right, pill_y, w, pill_h, dark and BLACK or CARD, S(11))
        label(text, right + w / 2, pill_y + pill_h / 2, pface, dark and WHITE or BLACK, nil, true)
        local r = { x = right, y = pill_y, w = w, h = pill_h }
        right = right - S(8)
        return r
    end
    self._close = pill(self.close_label or _("Done"), true)
    self._actions = {}
    for i = #(self.actions or {}), 1, -1 do
        local a = self.actions[i]
        self._actions[i] = pill(a[1], a[3])
    end
    local tx = x + self.pad
    self._back = nil
    if self.on_back then
        local bw = S(40)
        label("\u{2039}", tx + bw / 2, y + self.top_h / 2, Font:getFace("cfont", 30), BLACK)
        self._back = { x = tx - self.pad, y = y, w = bw + self.pad, h = self.top_h }
        tx = tx + bw
    end
    local title = TextWidget:new{ text = self.title, face = Font:getFace("cfont", 22), bold = true,
        max_width = math.max(S(40), right - tx) }
    local tsz = title:getSize()
    title:paintTo(bb, tx, y + math.floor(self.top_h / 2 - tsz.h / 2))
    self._title = { x = tx, y = y, w = tsz.w, h = self.top_h }
    title:free()
    bb:paintRect(x, y + self.top_h - 1, sw, 1, GREY)

    -- the tab column: each tab a card with its colour as a strip on the left; the
    -- selected one white, framed and reaching into the grid
    if self.tabs then
        local L = self:tabLayout()
        local tface = Font:getFace("cfont", 16)
        local strip = S(8)
        for i = 0, L.fit - 1 do
            local r = self:tabRect(L, i)
            local t = r.tab
            if t then
                local rx, ry = x + r.x, y + r.y
                if t.selected then
                    bb:paintRoundedRect(rx, ry, r.w + self.pad, r.h, BLACK, S(12))
                    bb:paintRoundedRect(rx + S(2), ry + S(2), r.w + self.pad - S(2), r.h - S(4), WHITE, S(11))
                else
                    bb:paintRoundedRect(rx, ry, r.w - self.pad, r.h, CARD, S(12))
                end
                if t.color then bb:paintRect(rx + S(4), ry + S(8), strip, r.h - S(16), t.color) end
                local tw = TextWidget:new{ text = t.label, face = tface, bold = t.selected,
                    max_width = r.w - self.pad - strip - S(16) }
                local twsz = tw:getSize()
                tw:paintTo(bb, rx + strip + S(10), ry + math.floor((r.h - twsz.h) / 2))
                tw:free()
            end
        end
        if L.arrows then
            local a = L.arrows
            local pages = math.ceil(#self.tabs / L.fit)
            if self.tpage > 0 then
                bb:paintRoundedRect(x + a.up.x, y + a.up.y, a.up.w, a.up.h, CARD, S(12))
                label("\u{25B2}", x + a.up.x + a.up.w / 2, y + a.up.y + a.up.h / 2, tface)
            end
            if self.tpage < pages - 1 then
                bb:paintRoundedRect(x + a.down.x, y + a.down.y, a.down.w, a.down.h, CARD, S(12))
                label("\u{25BC}", x + a.down.x + a.down.w / 2, y + a.down.y + a.down.h / 2, tface)
            end
        end
        if L.foot then
            local f = L.foot
            bb:paintRoundedRect(x + f.x, y + f.y, f.w, f.h, BLACK, S(12))
            label(self.tab_footer[1], x + f.x + f.w / 2, y + f.y + f.h / 2, tface, WHITE, f.w - S(8), true)
        end
        -- the line between the tabs and the grid, broken where the selected tab joins it
        bb:paintRect(x + self.tab_w, y + self.top_h, 1, sh - self.top_h - self.bot_h, GREY)
        for i = 0, L.fit - 1 do
            local r = self:tabRect(L, i)
            if r.tab and r.tab.selected then bb:paintRect(x + self.tab_w, y + r.y + S(2), 1, r.h - S(4), WHITE) end
        end
    end

    if #self.items == 0 and self.empty_text then
        local aw = sw - self.tab_w
        label(self.empty_text, x + self.tab_w + aw / 2, y + self.top_h + (sh - self.top_h - self.bot_h) / 2,
            Font:getFace("cfont", 17), LABEL, aw - 4 * self.pad)
    end

    local card_r = S(16)
    local nface = Font:getFace("cfont", 16)
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        local it = c.item
        if it then
            local cx, cy = x + c.x, y + c.y
            -- a rounded light grey card; the selected one gets a black border (a
            -- black card with an inset grey card)
            if it.selected then
                bb:paintRoundedRect(cx, cy, c.w, c.h, BLACK, card_r)
                local ins = S(3)
                bb:paintRoundedRect(cx + ins, cy + ins, c.w - 2 * ins, c.h - 2 * ins, CARD, card_r)
            else
                bb:paintRoundedRect(cx, cy, c.w, c.h, CARD, card_r)
            end
            local img = it.folder and self:folderTile(math.floor(math.min(c.w, c.h - self.label_h) * 0.45))
                or self.cache[it]
            if img then
                local iw, ih = img:getWidth(), img:getHeight()
                bb:blitFrom(img, cx + math.floor((c.w - iw) / 2),
                    cy + math.floor((c.h - self.label_h - ih) / 2), 0, 0, iw, ih)
            end
            local name = it.star and ("\u{2605} " .. it.label) or it.label
            label(name, cx + c.w / 2, cy + c.h - self.label_h / 2 - S(4), nface,
                it.selected and BLACK or LABEL, c.w - 2 * self.pad, it.selected)
        end
    end

    -- bottom bar: paging pills and a "grid page / total" indicator
    local by = y + sh - self.bot_h
    local pw, ph = S(120), S(40)
    local pcy = by + math.floor(self.bot_h / 2)
    local bface = Font:getFace("cfont", 16)
    self._prev, self._next = nil, nil
    if self.gpage > 0 then
        local px0 = x + self.pad
        bb:paintRoundedRect(px0, pcy - math.floor(ph / 2), pw, ph, CARD, S(14))
        self._prev = { x = px0, y = pcy - math.floor(ph / 2), w = pw, h = ph }
        label("\u{2039} " .. _("Prev"), px0 + pw / 2, pcy, bface)
    end
    if self.gpage < self:gridCount() - 1 then
        local px0 = x + sw - self.pad - pw
        bb:paintRoundedRect(px0, pcy - math.floor(ph / 2), pw, ph, CARD, S(14))
        self._next = { x = px0, y = pcy - math.floor(ph / 2), w = pw, h = ph }
        label(_("More") .. " \u{203A}", px0 + pw / 2, pcy, bface)
    end
    if self:gridCount() > 1 then
        label(string.format("%d / %d", self.gpage + 1, self:gridCount()),
            x + sw / 2, pcy, Font:getFace("cfont", 15), LABEL)
    end
end

function ThumbGrid:gridGo(delta)
    local g = self.gpage + delta
    if g < 0 or g >= self:gridCount() then return end
    self:freeCache()          -- only the visible grid page is kept resident
    self.gpage = g
    self:prepare()
    UIManager:setDirty(self, "full")
end

-- The card under screen point p, if any.
function ThumbGrid:itemAt(p)
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.item and p.x >= c.x and p.x <= c.x + c.w and p.y >= c.y and p.y <= c.y + c.h then
            return c.item
        end
    end
end

local function hit(r, p) return r and p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h end

-- What of the tab column is at screen point p: a tab, "up" or "down" (paging),
-- "footer", or nil.
function ThumbGrid:tabAt(p)
    if not self.tabs or p.x > self.tab_w then return nil end
    local L = self:tabLayout()
    if L.foot and hit(L.foot, p) then return "footer" end
    if L.arrows then
        if hit(L.arrows.up, p) and self.tpage > 0 then return "up" end
        if hit(L.arrows.down, p) and self.tpage < math.ceil(#self.tabs / L.fit) - 1 then return "down" end
    end
    for i = 0, L.fit - 1 do
        local r = self:tabRect(L, i)
        if r.tab and hit(r, p) then return r.tab end
    end
end

function ThumbGrid:onTgTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if hit(self._close, p) then self:close(); return true end
    for i, r in pairs(self._actions or {}) do
        if hit(r, p) then self.actions[i][2](); return true end
    end
    if hit(self._back, p) then self.on_back(); return true end
    if self.on_title and hit(self._title, p) then self.on_title(); return true end
    local tab = self:tabAt(p)
    if tab == "up" then self.tpage = math.max(0, self.tpage - 1); UIManager:setDirty(self, "ui"); return true end
    if tab == "down" then self.tpage = self.tpage + 1; UIManager:setDirty(self, "ui"); return true end
    if tab == "footer" then self.tab_footer[2](); return true end
    if tab then
        if self.on_tab then self.on_tab(tab) end
        return true
    end
    if hit(self._prev, p) then self:gridGo(-1); return true end
    if hit(self._next, p) then self:gridGo(1); return true end
    local it = self:itemAt(p)
    if it and self.on_pick then self.on_pick(it) end
    return true
end

function ThumbGrid:onTgHold(_, ges)
    local p = ges and ges.pos
    local tab = p and self:tabAt(p)
    if type(tab) == "table" then
        if self.on_tab_hold then self.on_tab_hold(tab) end
        return true
    end
    local it = p and self:itemAt(p)
    if it and self.on_hold then self.on_hold(it) end
    return true
end

function ThumbGrid:onTgSwipe(_, ges)
    local dir = ges and ges.direction
    if dir == "west" then self:gridGo(1) elseif dir == "east" then self:gridGo(-1) end
    return true
end

function ThumbGrid:onTgClose()
    self:close()
    return true
end

function ThumbGrid:close()
    UIManager:close(self)
end

function ThumbGrid:onCloseWidget()
    self:freeCache()
    if self._folder and self._folder.bb then self._folder.bb:free() end
    self._folder = nil
    UIManager:setDirty("all", "full")   -- restore the canvas cleanly underneath
    if self.on_close then self.on_close() end
end

return ThumbGrid
