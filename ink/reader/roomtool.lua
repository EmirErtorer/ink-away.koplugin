--[[
The Make room tool (from the Lasso's sheet, over a reflowing book): draw a box on
the page and the text moves out of it (ink/reader/rooms.lua). The box can be moved
and its corners dragged; what it will make shows under it as it goes: a band
across the page before the nearest paragraph, or space at a side beside the
paragraphs it covers. A tap on a room already made picks it, to change its size or
remove it.

It is a layer over the annotation mode with a clean picture of the page (and its
ink), like the screen clip (ink/reader/capture.lua). Its sheet stays open while the
box is dragged: the layer is always active, so a drag beside the sheet reaches it.
Making, changing or removing a room hands back to the annotation mode, which keeps
its page's ink first, then shows the page laid out again.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("ink/l10n")
local Rooms = require("ink/reader/rooms")

local Screen = Device.screen
local S = function(px) return Screen:scaleBySize(px) end
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.COLOR_GRAY
local SHEET = "_room_sheet"

local RoomTool = InputContainer:extend{
    modal = true,
    covers_fullscreen = true,
    is_always_active = true,   -- drags beside its sheet still reach it
    book = nil,                -- ink/reader/book.lua
    view = nil,                -- the annotation mode (ink/reader/inkview.lua)
    edit = nil,                -- a room to change, picked from the list
}

function RoomTool:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local typ = Screen.bb:getType() == Blitbuffer.TYPE_BB8 and Blitbuffer.TYPE_BB8 or Blitbuffer.TYPE_BBRGB32
    self.page = Blitbuffer.new(self.dimen.w, self.dimen.h, typ)
    local ok, painted = pcall(self.book.snapshot, self.book, self.page, true)
    self.ready = ok and painted ~= false
    self.area = self.book:textArea()
    self.blocks = self.book:pageBlocks()
    self.boxes = self.book:roomBoxes()
    self.ges_events = {}
    for _i, binding in ipairs({ { "touch", "Press" }, { "tap", "Tap" }, { "hold", "Press" },
        { "pan", "Drag" }, { "hold_pan", "Drag" }, { "pan_release", "Release" },
        { "hold_pan_release", "Release" }, { "hold_release", "Release" }, { "swipe", "Release" } }) do
        local name, event = binding[1], binding[2]
        self.ges_events[event] = self.ges_events[event] or {}
        table.insert(self.ges_events[event], GestureRange:new{ ges = name,
            range = (name == "touch" or name == "tap" or name == "hold") and self.dimen or nil })
    end
    self.key_events = { Cancel = { { Device.input.group.Back } } }
    if self.edit then self:pick(self.edit) end
end

------------------------------------------------------------------------------
-- The box
------------------------------------------------------------------------------

local function inside(r, x, y) return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h end

function RoomTool:point(pos)
    return { x = math.max(0, math.min(self.dimen.w - 1, math.floor(pos.x))),
             y = math.max(0, math.min(self.dimen.h - 1, math.floor(pos.y))) }
end

-- The corner of the box near (x, y), if any: "tl", "tr", "bl" or "br".
function RoomTool:cornerAt(x, y)
    local r = self.rect
    if not r then return nil end
    local reach = S(34)
    for _i, c in ipairs({ { "tl", r.x, r.y }, { "tr", r.x + r.w, r.y }, { "bl", r.x, r.y + r.h },
        { "br", r.x + r.w, r.y + r.h } }) do
        if math.abs(x - c[2]) <= reach and math.abs(y - c[3]) <= reach then return c[1] end
    end
end

-- The page's paragraphs as they would be without the room being changed (a band
-- pushes everything under it down by its height).
function RoomTool:planBlocks()
    local room, box = self.room, self.room_box
    if not (room and room.kind == "band" and box) then return self.blocks end
    local out = {}
    for i, b in ipairs(self.blocks) do
        if b.y0 >= box.y + box.h - 1 then
            out[i] = { xp = b.xp, y0 = b.y0 - room.h, y1 = b.y1 - room.h, starts = b.starts }
        else
            out[i] = b
        end
    end
    return out
end

-- What the box makes, and where it shows.
function RoomTool:replan()
    self.plan, self.pbox, self.why = nil, nil, nil
    if not self.rect then return end
    local plan, box = Rooms.plan(self.rect, self:planBlocks(), self.area)
    if plan then
        -- (a changed band shows where it will be: the text under it moves with it)
        self.plan, self.pbox = plan, box
    else
        self.why = box
    end
end

-- Pick a room made before: its box becomes the box to change.
function RoomTool:pick(room)
    for _i, e in ipairs(self.boxes) do
        if e.room.id == room.id then
            self.room, self.room_box = room, e.box
            self.rect = { x = e.box.x, y = e.box.y, w = e.box.w, h = e.box.h }
            self:replan()
            return true
        end
    end
    return false
end

------------------------------------------------------------------------------
-- Gestures
------------------------------------------------------------------------------

function RoomTool:onPress(_arg, ges)
    local p = self:point(ges.pos)
    local corner = self:cornerAt(p.x, p.y)
    if corner then
        self.drag = { mode = "resize", corner = corner, from = p, start = self.rect }
    elseif inside(self.rect, p.x, p.y) then
        self.drag = { mode = "move", from = p, start = self.rect }
    else
        self.drag = { mode = "draw", from = p }
    end
    return true
end

function RoomTool:onDrag(_arg, ges)
    local d = self.drag
    if not d and ges.start_pos then self:onPress(nil, { pos = ges.start_pos }); d = self.drag end
    if not d then return true end
    local p = self:point(ges.pos)
    local dx, dy = p.x - d.from.x, p.y - d.from.y
    if not d.moved and dx * dx + dy * dy < S(6) ^ 2 then return true end
    d.moved = true
    local old = self:dirtyBox()
    local r
    if d.mode == "draw" then
        r = { x = math.min(d.from.x, p.x), y = math.min(d.from.y, p.y),
              w = math.abs(p.x - d.from.x), h = math.abs(p.y - d.from.y) }
    elseif d.mode == "move" then
        local s = d.start
        r = { x = math.max(0, math.min(self.dimen.w - s.w, s.x + dx)),
              y = math.max(0, math.min(self.dimen.h - s.h, s.y + dy)), w = s.w, h = s.h }
    else
        local s = d.start
        local x0, y0, x1, y1 = s.x, s.y, s.x + s.w, s.y + s.h
        if d.corner:find("l") then x0 = x0 + dx else x1 = x1 + dx end
        if d.corner:find("t") then y0 = y0 + dy else y1 = y1 + dy end
        r = { x = math.min(x0, x1), y = math.min(y0, y1), w = math.abs(x1 - x0), h = math.abs(y1 - y0) }
    end
    r.w, r.h = math.max(1, r.w), math.max(1, r.h)
    self.rect = r
    self:replan()
    local new = self:dirtyBox()
    UIManager:setDirty(self, "fast", old and new and old:combine(new) or new or old)
    return true
end

function RoomTool:onRelease(_arg, ges)
    local d = self.drag
    if ges and ges.end_pos and not (d and d.moved) then
        -- a quick stroke comes as one swipe, its start in pos and its lift in
        -- end_pos: drawn, moved or resized from the one to the other
        self:onPress(nil, { pos = ges.pos })
        self:onDrag(nil, { pos = ges.end_pos })
    end
    d = self.drag
    self.drag = nil
    if d and d.moved then
        if self.rect and (self.rect.w < S(16) or self.rect.h < S(10)) and d.mode == "draw" then
            self.rect = nil; self:replan()
        end
        UIManager:setDirty(self, "ui")
        self:showSheet()
    end
    return true
end

-- A tap on a room made before picks it; a tap elsewhere, with no box, says how.
function RoomTool:onTap(_arg, ges)
    self.drag = nil
    local p = self:point(ges.pos)
    if self.rect and not self.room then return true end
    for _i, e in ipairs(self.boxes) do
        if inside(e.box, p.x, p.y) then
            self:pick(e.room)
            UIManager:setDirty(self, "ui")
            self:showSheet()
            return true
        end
    end
    return true
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

-- The part of the screen the box and what it makes take (to repaint), or nil.
function RoomTool:dirtyBox()
    local g
    for _i, r in ipairs({ self.rect, self.pbox }) do
        if r then
            local m = S(20)
            local b = Geom:new{ x = r.x - m, y = r.y - m, w = r.w + 2 * m, h = r.h + 2 * m }
            g = g and g:combine(b) or b
        end
    end
    if g then g = g:intersect(self.dimen) end
    return g
end

local function dashed(bb, x, y, w, h, t, c)
    local dash, gap = S(8), S(6)
    local function run(len, f)
        local p = 0
        while p < len do f(p, math.min(dash, len - p)); p = p + dash + gap end
    end
    run(w, function(p, l) bb:paintRect(x + p, y, l, t, c); bb:paintRect(x + p, y + h - t, l, t, c) end)
    run(h, function(p, l) bb:paintRect(x, y + p, t, l, c); bb:paintRect(x + w - t, y + p, t, l, c) end)
end

function RoomTool:paintTo(bb, x, y)
    bb:blitFrom(self.page, x, y, 0, 0, self.dimen.w, self.dimen.h)
    -- the rooms made before, outlined (the one being changed shows as the box)
    for _i, e in ipairs(self.boxes) do
        if not (self.room and self.room.id == e.room.id) then
            local b = e.box
            dashed(bb, x + b.x, y + b.y, b.w, b.h, S(2), GREY)
        end
    end
    -- what the box will make: shaded, with a dashed edge
    local pb = self.pbox
    if pb then
        local px0, py0 = math.max(0, pb.x), math.max(0, pb.y)
        local px1, py1 = math.min(self.dimen.w, pb.x + pb.w), math.min(self.dimen.h, pb.y + pb.h)
        if px1 > px0 and py1 > py0 then
            bb:darkenRect(x + px0, y + py0, px1 - px0, py1 - py0, 0.18)
            dashed(bb, x + px0, y + py0, px1 - px0, py1 - py0, S(2), BLACK)
        end
    end
    -- the box itself, with its corners
    local r = self.rect
    if r then
        bb:paintBorder(x + r.x, y + r.y, r.w, r.h, S(2), BLACK)
        if r.w > S(8) and r.h > S(8) then bb:paintBorder(x + r.x + S(2), y + r.y + S(2), r.w - S(4), r.h - S(4), 1, WHITE) end
        local hs = S(14)
        for _i, c in ipairs({ { r.x, r.y }, { r.x + r.w, r.y }, { r.x, r.y + r.h }, { r.x + r.w, r.y + r.h } }) do
            bb:paintRect(x + c[1] - hs / 2, y + c[2] - hs / 2, hs, hs, WHITE)
            bb:paintBorder(x + c[1] - hs / 2, y + c[2] - hs / 2, hs, hs, S(2), BLACK)
        end
    end
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

-- What the box will make, in a few words.
function RoomTool:describe()
    local p = self.plan
    if not self.rect then
        if #self.boxes > 0 then return _("Draw a box where the text should move away, or tap a room to change it.") end
        return _("Draw a box where the text should move away.")
    end
    if not p then
        if self.why == "no_break" then return _("No paragraph starts on this page, so there is nowhere to put a band.") end
        return _("There is no text here to move.")
    end
    if p.kind == "band" then return _("A band across the page, before the paragraph nearest the box's top.") end
    if p.side == "left" then return _("Space on the left, beside the paragraphs the box covers.") end
    return _("Space on the right, beside the paragraphs the box covers.")
end

function RoomTool:closeSheet()
    if self.view then self.view:closeSheet(SHEET) end
end

function RoomTool:showSheet()
    local view = self.view
    if not view then return end
    -- away from the box: at the foot when the box is in the upper half
    local r = self.rect
    local upper = not r or (r.y + r.h / 2 < self.dimen.h / 2)
    if view[SHEET] then
        if self._sheet_upper == upper and view:rebuildSheet(SHEET) then return end
        view:closeSheet(SHEET)
    end
    self._sheet_upper = upper
    local content_w, gap = view:sheetWidth()
    local half = math.floor((content_w - gap) / 2)
    local build = function()
        local editing = self.room ~= nil
        local content = VerticalGroup:new{ align = "left",
            view:sheetTitle(editing and _("Room") or _("Make room"), content_w,
                editing and _("Close") or _("Cancel"), function() self:onCancel() end),
            VerticalSpan:new{ width = S(8) },
            view:sheetHint(self:describe(), content_w, 15) }
        local buttons
        if editing then
            buttons = { view:actionButton(_("Save changes"), half, function() self:saveChange() end, self.plan ~= nil),
                        view:actionButton(_("Remove room"), half, function() self:askRemove() end) }
        elseif self.plan then
            buttons = { view:actionButton(_("Make room"), half, function() self:make() end, true),
                        view:actionButton(_("Draw again"), half, function() self:drawAgain() end) }
        end
        if buttons then
            table.insert(content, VerticalSpan:new{ width = S(12) })
            table.insert(content, HorizontalGroup:new{ align = "center", buttons[1], HorizontalSpan:new{ width = gap }, buttons[2] })
        end
        return content
    end
    local sheet
    view:showSheet(SHEET, build, {
        bottom_y = upper and (Screen:getHeight() - S(6)) or nil,
        top = not upper or nil,
        -- a tap beside the sheet closes it and lands nowhere: it is handed to the
        -- tool (a tap on a room picks it), and the sheet comes back; Back leaves
        on_close = function()
            local p = sheet and sheet.tap_pos
            UIManager:nextTick(function()
                if self.book._room_tool ~= self then return end
                if not p then return self:onCancel() end
                self:onTap(nil, { pos = p })
                self:showSheet()
            end)
        end })
    sheet = view[SHEET]
end

function RoomTool:drawAgain()
    self.rect, self.plan, self.pbox, self.why, self.room, self.room_box = nil, nil, nil, nil, nil, nil
    UIManager:setDirty(self, "ui")
    self:showSheet()
end

------------------------------------------------------------------------------
-- Making, changing and removing
------------------------------------------------------------------------------

-- Hand back to the annotation mode around `fn`, which changes the book's rooms
-- and returns the room to show (or nil and why it could not).
function RoomTool:commit(fn)
    local view = self.view
    self:closeSheet()
    UIManager:close(self)
    if view then view:changeRooms(fn) end
end

function RoomTool:make()
    local plan = self.plan
    if not plan then return end
    self:commit(function(book) return book:addRoom(plan) end)
end

function RoomTool:saveChange()
    local plan, room = self.plan, self.room
    if not (plan and room) then return end
    plan.id = room.id
    self:commit(function(book) return book:putRoom(plan) end)
end

-- Remove the room being changed; what is in it goes or follows the text, as asked
-- (nothing is asked for an empty room).
function RoomTool:askRemove()
    local room, view = self.room, self.view
    if not (room and view) then return end
    local function remove(how)
        self:commit(function(book)
            book:removeRoom(room.id, how)
            return nil
        end)
    end
    if #self.book:roomItems(room.id) == 0 then return remove("delete") end
    self:closeSheet()
    local content_w, gap = view:sheetWidth()
    local half = math.floor((content_w - gap) / 2)
    view:showSheet(SHEET, function()
        return VerticalGroup:new{ align = "left",
            view:sheetTitle(_("Remove room"), content_w, _("Back"), function()
                view:closeSheet(SHEET); self:showSheet()
            end),
            VerticalSpan:new{ width = S(8) },
            view:sheetHint(_("What is in this room: delete it, or keep it where it is and let it follow the text?"),
                content_w, 15),
            VerticalSpan:new{ width = S(12) },
            HorizontalGroup:new{ align = "center",
                view:actionButton(_("Delete it"), half, function() remove("delete") end),
                HorizontalSpan:new{ width = gap },
                view:actionButton(_("Let it follow the text"), half, function() remove("follow") end, true) } }
    end, { on_close = function() self:showSheet() end })
end

function RoomTool:onCancel()
    self:closeSheet()
    UIManager:close(self)
    return true
end

RoomTool.onSetDimensions = RoomTool.onCancel
RoomTool.onCloseDocument = RoomTool.onCancel

function RoomTool:onCloseWidget()
    if self.page then self.page:free(); self.page = nil end
    if self.book and self.book._room_tool == self then self.book._room_tool = nil end
    UIManager:setDirty(nil, "ui")
end

-- Open the tool over the annotation mode `view` (on `room` to change it).
function RoomTool.open(view, room)
    local book = view and view.book
    if not book or book._room_tool then return end
    local tool = RoomTool:new{ book = book, view = view, edit = room }
    if not tool.ready then
        tool:onCloseWidget()
        logger.warn("Ink Away: could not picture the page for the room tool")
        return
    end
    book._room_tool = tool
    UIManager:show(tool)
    UIManager:setDirty(tool, "ui")
    tool:showSheet()
end

return RoomTool
