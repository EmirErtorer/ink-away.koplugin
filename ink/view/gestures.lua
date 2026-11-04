--[[
Gestures and pen buttons, as the reader set them (ink/actions.lua): carrying out
an action, two-finger taps and swipes, a pen button that acts while it is held,
and the settings sheet where each gesture and button is given its action.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Actions = require("ink/actions")
local InkGeom = require("ink/geom")
local Penset = require("ink/penset")

local Screen = Device.screen

local TWO_TAP_REDO_MS = 600     -- a second two-finger tap within this is a double tap

local InkAwayView = {}

-- The bindings, loaded the first time they are needed.
function InkAwayView:gestureBindings()
    if not self._gestures then
        self._gestures = Actions.load(function(k) return self:getSetting(k) end)
    end
    return self._gestures
end

function InkAwayView:saveGestures()
    Actions.save(self:gestureBindings(), function(k, v) self:setSetting(k, v) end)
end

------------------------------------------------------------------------------
-- Carrying out an action
------------------------------------------------------------------------------

-- The pen of saved slot i, or nil.
function InkAwayView:savedPen(i)
    return self:penset().favs[i]
end

-- The reader's page turn buttons (#14): the action Gestures and pen buttons gives
-- them, by default the next or previous page of a notebook, or of the book in
-- annotation mode. Taken either way, so the book under the canvas never turns
-- on its own.
function InkAwayView:keyAction(trigger)
    local id = self:gestureBindings()[trigger]
    if id and id ~= "nothing" then self:runAction(id) end
    return true
end
function InkAwayView:onIaKeyFwd() return self:keyAction("key_fwd") end
function InkAwayView:onIaKeyBack() return self:keyAction("key_back") end

-- Does this reader have page turn buttons?
function InkAwayView:pageKeys()
    local ok, keys = pcall(function() return Device:hasKeys() end)
    local g = Device.input and Device.input.group
    return (ok and keys and g and g.PgFwd ~= nil) and true or false
end

-- Draw the screen again from the page and refresh all of it with a flash: what a
-- quick refresh left out shows, and the marks fast drawing leaves go (#12).
function InkAwayView:refreshScreen()
    self:flushPending()
    self:renderView()
    self._paint_all = true
    UIManager:setDirty(self, "full")
end

-- Do `id` once (a gesture). Tools are toggled: asking for the eraser while it is
-- in hand goes back to the pen. Returns whether something happened.
function InkAwayView:runAction(id)
    if id == "nothing" or not id then return false end
    if id == "undo" then return self:undo() end
    if id == "redo" then return self:redo() end
    if id == "next_page" or id == "prev_page" then
        if not self.notebook then return false end
        self:nbGo(id == "next_page" and 1 or -1)
        return true
    end
    if id == "browse" then
        if self.notebook then self:openOverview() else self:openLibrary() end
        return true
    end
    if id == "library" then self:openLibrary(); return true end
    if id == "pan" then self:togglePan(); return true end
    if id == "toolbar" then self:setToolbarHidden(not self._toolbar_hidden); return true end
    if id == "fit" then self:setZoom(self.zoom_min or self.view.zoom); return true end
    if id == "refresh" then self:refreshScreen(); return true end
    if id == "contents" then return self:goToContents() end
    if id == "eraser" then self:setTool(self.tool == "erase" and "pen" or "erase"); return true end
    if id == "lasso" then self:setTool(self.tool == "lasso" and "pen" or "lasso"); return true end
    if id == "prev_pen" then return self:swapPen() end
    if id == "highlighter" then
        if self.tool == "pen" and self.pen_style == "highlighter" then return self:swapPen() end
        self:choosePenType("highlighter")
        self:setTool("pen")
        return true
    end
    local fav = id:match("^fav(%d)$")
    if fav then
        if not self:selectPen(tonumber(fav)) then return false end
        self:setTool("pen")
        return true
    end
    return false
end

-- A pen part (button or eraser end) is down for a stroke: do its action for this
-- stroke only. The tool or pen it swaps in is put back by restoreHeld at the lift.
function InkAwayView:holdAction(control)
    local trigger = require("ink/stylus").TRIGGER[control]
    if not trigger then return end
    local id = self:gestureBindings()[trigger]
    if not id or id == "nothing" then return end
    local function swapTool(tool)
        if self.tool ~= tool then self._pen_prev_tool = self.tool; self.tool = tool end
    end
    local function swapPen(p)
        if not p then return end
        self._pen_held_pen = { style = self.pen_style, width = self.pen_width,
                               alpha = self.pen_alpha, color = self.pen_color }
        self:applyPen(p)
        swapTool("pen")
    end
    if id == "lasso" then swapTool("lasso")
    elseif id == "eraser" then swapTool("erase")
    elseif id == "highlighter" then
        local case = self:penset()
        swapPen(case.types.highlighter or Penset.default("highlighter", case.opts))
    elseif id == "prev_pen" then swapPen(self:penset().prev)
    else
        local fav = id:match("^fav(%d)$")
        if fav then swapPen(self:savedPen(tonumber(fav))) end
    end
end

-- Put back the tool and pen a held pen part swapped in.
function InkAwayView:restoreHeld()
    if self._pen_held_pen then self:applyPen(self._pen_held_pen); self._pen_held_pen = nil end
    if self._pen_prev_tool then self.tool = self._pen_prev_tool; self._pen_prev_tool = nil end
end

------------------------------------------------------------------------------
-- Two-finger gestures
------------------------------------------------------------------------------

-- A two-finger tap does its action at once. When the double tap is set too, a
-- second tap within TWO_TAP_REDO_MS makes a double tap. With the usual undo and
-- redo the undo still happens at once: a double tap takes it back and redoes one
-- step. With other actions the single tap waits that long for a second one.
-- A dot the first finger began (with palm rejection off, a drawing finger
-- arrives as gestures) is dropped first, so an undo takes back the last real
-- change and not the dot; any other stroke still open is committed first.
function InkAwayView:onIaTwoTap(_, ges)
    if self:diagonalGesture(ges) then return false end   -- KOReader's screenshot
    if self:fingerRejected() then return true end   -- the writing hand, not a gesture
    self._finger_nav = nil
    if self.capturing and self._finger_dot and self.canvas.live
            and #self.canvas.live.pts <= 4 then
        self:penDropFingerOps()
    end
    self:flushPending()
    self:cancelShape()
    local b = self:gestureBindings()
    local single, double = b.two_tap, b.two_double_tap
    local now = self:nowMs()
    local last = self._two_tap
    if double == "nothing" then
        self._two_tap = nil
        if single == "nothing" then self:handBack(ges) end
        self:runAction(single)
        return true
    end
    if last and now - last.at <= TWO_TAP_REDO_MS then
        self._two_tap = nil
        if last.pending then UIManager:unschedule(last.pending) end
        if single == "undo" and double == "redo" then
            if last.undid then self:redo() end   -- take that undo back
            self:redo()
        else
            self:runAction(double)
        end
        return true
    end
    if single == "undo" and double == "redo" then
        self._two_tap = { at = now, undid = self:undo() }
    else
        local entry = { at = now }
        entry.pending = function()
            if self._two_tap == entry then self._two_tap = nil; self:runAction(single) end
        end
        self._two_tap = entry
        UIManager:scheduleIn(TWO_TAP_REDO_MS / 1000, entry.pending)
    end
    return true
end

-- Is this KOReader's screenshot gesture: two fingers tapping, or one finger
-- swiping, between opposite corners (as far apart as the screen's diagonal, give
-- or take 200 px, as its Screenshot module reads it)? Ink Away leaves those to it.
function InkAwayView:diagonalGesture(ges)
    if not ges then return false end
    local a, b = ges.pos, ges.end_pos
    local span = ges.span or (a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)) or 0
    local diagonal = math.sqrt(Screen:getWidth() ^ 2 + Screen:getHeight() ^ 2)
    return span >= diagonal - Screen:scaleBySize(200) and span <= diagonal + 1
end

-- A gesture Ink Away has no use for goes to KOReader's own, so the gestures the
-- reader set (the light, a screenshot, a refresh...) work here too. A plain
-- swipe over a book is left alone: it would turn the book's page underneath.
function InkAwayView:handBack(ges, plain)
    local ui = self.kui
    if not (ui and ges and ui.handleEvent) or (plain and ui.document) then return false end
    local Event = require("ui/event")
    local ok, used = pcall(ui.handleEvent, ui, Event:new("Gesture", ges))
    return ok and used and true or false
end

-- A two-finger swipe: sideways (unless the zoomed page moved sideways instead),
-- or a long one up or down (a third of the area, when not zoomed in; a short one
-- stays a scroll).
function InkAwayView:onIaTwoSwipe(_, ges)
    if self:fingerRejected() then return true end
    local start = self.pan_last
    self.pan_last, self._finger_nav = nil, nil
    local a, b = ges and ges.pos, ges and ges.end_pos
    if not (a and b) then return true end
    local dx, dy = b.x - a.x, b.y - a.y
    local binds = self:gestureBindings()
    local trigger
    if math.abs(dx) >= self.view.area_w / 8 and math.abs(dx) > 1.5 * math.abs(dy) then
        if self:sidewaysRoom() then return true end   -- it panned
        trigger = dx < 0 and "two_swipe_left" or "two_swipe_right"
    elseif math.abs(dy) >= self.view.area_h / 4 and math.abs(dy) > 1.5 * math.abs(dx) and not self:zoomedIn() then
        trigger = dy < 0 and "two_swipe_up" or "two_swipe_down"
    end
    local id = trigger and binds[trigger]
    if not id or id == "nothing" then self:handBack(ges); return true end
    -- the two-finger move panned on its way: put the page back first
    if start and start.px and (trigger == "two_swipe_up" or trigger == "two_swipe_down") then
        self.view.pan_x, self.view.pan_y = start.px, start.py
        InkGeom.clampPan(self.view)
        self:renderView()
    end
    self:runAction(id)
    return true
end

------------------------------------------------------------------------------
-- The settings sheet
------------------------------------------------------------------------------

-- Which triggers this reader can make: the pen's only with pen support, the page
-- turn buttons only on a reader with them. The second side button is not
-- offered: neither a Kindle Scribe pen nor a Kobo pen has one (a Kobo pen's
-- BTN_STYLUS2 is its only side button, see Stylus.penAction); a pen that sends
-- it anyway does what its default says.
function InkAwayView:availableTriggers()
    local out = {}
    local keys = self:pageKeys()
    for _i, t in ipairs(Actions.TRIGGERS) do
        if t.key then
            if keys then out[#out + 1] = t end
        elseif not t.pen or (self:penCapable() and not t.second) then
            out[#out + 1] = t
        end
    end
    return out
end

-- Gestures and pen buttons: each trigger with its action on a pill; a tap on the
-- pill chooses another.
-- An action's name where it acts (the annotation mode names some its own way).
function InkAwayView:actionLabel(id)
    return _(Actions.label(id))
end

-- Whether to offer an action here (every one, in the canvas).
function InkAwayView:actionOffered(_id) return true end

-- The tab a trigger is on: the finger gestures, the pen's buttons, or the page turn keys.
local function gestureTab(t)
    return t.pen and "pen" or t.key and "keys" or "touch"
end

-- Gestures and pen buttons: a panel with a tab for each kind of trigger (only
-- the kinds this device has), each row a trigger and its action; a tap on a row
-- lists the actions it may have.
function InkAwayView:openGestureSettings(tab)
    self:ensureUserIcons()
    local b = self:gestureBindings()
    local triggers = self:availableTriggers()
    local tabs, seen = {}, {}
    local LABEL = { touch = _("Gestures"), pen = _("Pen"), keys = _("Page turn buttons") }
    for _i, t in ipairs(triggers) do
        local id = gestureTab(t)
        if not seen[id] then seen[id] = true; tabs[#tabs + 1] = { id, LABEL[id] } end
    end
    self:openNativeMenu{ field = "_gestures_dialog", title = _("Gestures and pen buttons"),
        tabs = tabs, tab = seen[tab] and tab or nil,
        items = function()
            local rows = {}
            for _i, t in ipairs(triggers) do
                -- (an asterisk marks an action with a note: a long press shows it)
                local notes = self.reader_mode and {} or Actions.notes(b, t.id)
                rows[#rows + 1] = { tab = gestureTab(t), text = _(t.label),
                    value = self:actionLabel(b[t.id]) .. (#notes > 0 and " *" or ""),
                    help = #notes > 0 and table.concat((function()
                        local out = {}
                        for _j, n in ipairs(notes) do out[#out + 1] = _(n) end
                        return out
                    end)(), "\n\n") or nil,
                    submenu = function() self:chooseGestureAction(t, gestureTab(t)) end }
            end
            rows[#rows + 1] = { text = _("Back to the usual"), action = function()
                Actions.reset(b); self:saveGestures() end }
            return rows
        end }
end

-- Choose the action for trigger `t`: a list of the actions it may have, the
-- one in use ticked. An action another gesture already does asks whether to
-- move it here or keep it on both.
function InkAwayView:chooseGestureAction(t, tab)
    local b = self:gestureBindings()
    local function apply(id, move)
        Actions.set(b, t.id, id, move)
        self:saveGestures()
        self:openGestureSettings(tab)
    end
    local function pick(id)
        local info = Actions.preview(b, t.id, id)
        -- (only the triggers this reader has: a Kobo pen was asked about a
        -- second side button it does not have)
        local shown, also = {}, {}
        for _i, tr in ipairs(self:availableTriggers()) do shown[tr.id] = true end
        for _i, other in ipairs(info.also) do if shown[other] then also[#also + 1] = other end end
        if #also == 0 then return apply(id, false) end
        local names = {}
        for _i, other in ipairs(also) do names[#names + 1] = _(Actions.trigger(other).label) end
        self:ask{ title = _("Already in use"),
            text = string.format(_("%s already does \"%s\". Use it only for %s, or for both?"),
                table.concat(names, ", "), self:actionLabel(id), _(t.label)),
            ok_text = _("Only this one"), cancel_text = _("Both"),
            on_ok = function() apply(id, true) end,
            on_cancel = function() apply(id, false) end }
    end
    local list = {}
    for _i, a in ipairs(Actions.choices(t.id)) do
        if self:actionOffered(a.id) then
            list[#list + 1] = { label = (b[t.id] == a.id and self.CHOSEN or "") .. self:actionLabel(a.id),
                cb = function() pick(a.id) end }
        end
    end
    self:chooseFromList{ field = "_gesture_pick", title = _(t.label), items = list }
end

return InkAwayView
