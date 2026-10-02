--[[
Keeps a Wacom pen's events on the pen's own slot while the canvas is open.

KOReader reads the pen (a single-touch digitizer: ABS_X/ABS_Y/BTN_TOUCH) and the
capacitive panel (multi-touch: ABS_MT_*) through ONE "current slot" cursor. The
panel moves that cursor to a resting palm's slot, and the pen's next events then
land on the palm's slot instead of the pen's: the pen's coordinates are written
into the palm, and its lift (BTN_TOUCH 0) is dropped because KOReader only honours
it when the current slot holds a pen. The pen slot then never sees the lift, and
the next pen-down continues the old stroke -- the straight line from one stroke to
the next that Kindle Scribe users with a resting hand see.

While installed, the bridge gives each device its own cursor:
  * ABS_X / ABS_Y / ABS_PRESSURE always go to the pen slot;
  * BTN_TOUCH goes to the pen slot whenever the pen is in range or has a live
    contact, so a lift can never be lost (KOReader's own check looks at whatever
    slot is current);
  * every ABS_MT_* event goes back to the panel slot the panel last selected.
It also moves the pen slot out of the panel's 0..9 range (to 15), so a hand with
several contacts can never share the pen's slot. Everything is restored on close.

The approach follows pierspad's Notebook plugin (MIT), which showed the cursor
split is what makes palm rejection reliable on the Scribe. It is installed only on
Wacom-protocol devices that use KOReader's stock touch handlers.
]]

local PenBridge = {}

local EV_ABS = 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local ABS_MT_SLOT = 47
local ABS_MT_FIRST, ABS_MT_LAST = 48, 61     -- ABS_MT_TOUCH_MAJOR .. ABS_MT_TOOL_Y
local BTN_TOUCH = 330
local BTN_TOOL_PEN, BTN_TOOL_RUBBER = 320, 321
local EV_SYN = 0
local TOOL_FINGER, TOOL_PEN, TOOL_ERASER = 0, 1, 2

PenBridge.PEN_SLOT = 15

local function slotData(input, n)
    return input.ev_slots and input.ev_slots[n]
end

-- Make sure the slot record exists without touching this frame's slot list.
local function ensureSlot(input, n)
    if not input.ev_slots then return nil end
    if not input.ev_slots[n] then
        if input.initMtSlot then input:initMtSlot(n) else input.ev_slots[n] = { slot = n } end
    end
    return input.ev_slots[n]
end

-- Can the bridge run on this Input? Only Wacom-protocol devices that still use the
-- stock handlers (a device or plugin with its own handler is left alone).
function PenBridge.supported(input)
    return input ~= nil and input.wacom_protocol == true and input.pen_slot ~= nil
        and type(input.setupSlotData) == "function"
        and type(input.setCurrentMtSlot) == "function"
        and type(input.setCurrentMtSlotChecked) == "function"
        and type(input.handleTouchEv) == "function"
        and type(input.handleKeyBoardEv) == "function"
        and rawget(input, "handleTouchEv") == nil
        and rawget(input, "handleKeyBoardEv") == nil
end

-- Install on `input`. Returns a handle for uninstall, or nil when not supported.
function PenBridge.install(input)
    if not PenBridge.supported(input) then return nil end
    local h = { input = input, orig_pen_slot = input.pen_slot }
    -- The panel's slot cursor: where KOReader's cursor is now, unless that is the pen.
    local cur = input.cur_slot
    h.panel_slot = (cur ~= nil and cur ~= input.pen_slot) and cur or (input.main_finger_slot or 0)

    -- Move the pen slot, carrying over whether the pen is in range right now (the
    -- canvas is often opened with the pen hovering, and BTN_TOOL_PEN won't repeat).
    local new_slot = PenBridge.PEN_SLOT
    local old = slotData(input, h.orig_pen_slot)
    local fresh = ensureSlot(input, new_slot)
    if fresh then
        fresh.tool = old and old.tool or nil
        fresh.id = -1
        fresh.x, fresh.y = old and old.x, old and old.y
    end
    input.pen_slot = new_slot

    local touch = input.handleTouchEv          -- the class methods (checked above)
    local key = input.handleKeyBoardEv

    local function penActive(this)
        local p = slotData(this, this.pen_slot)
        if not p then return false end
        return p.tool == TOOL_PEN or p.tool == TOOL_ERASER or (p.id ~= nil and p.id >= 0)
    end

    -- Each returns true when it took the event itself.
    local function steerTouch(this, ev)
        if ev.type == EV_SYN then h.touch_pending = nil; return false end
        if ev.type ~= EV_ABS then return false end
        local code = ev.code
        if code == ABS_MT_SLOT then
            h.panel_slot = ev.value
        elseif code >= ABS_MT_FIRST and code <= ABS_MT_LAST then
            if this.cur_slot ~= h.panel_slot then this:setupSlotData(h.panel_slot) end
        elseif code == ABS_X or code == ABS_Y then
            this:setupSlotData(this.pen_slot)
            this:setCurrentMtSlotChecked(code == ABS_X and "x" or "y", ev.value)
            return true
        elseif code == ABS_PRESSURE then
            this:setupSlotData(this.pen_slot)
            this:setCurrentMtSlotChecked("pressure", ev.value)
            -- KOReader drops hovering pen frames on pressure 0 when it knows the
            -- pressure axis; keep that behaviour on the pen slot.
            if ev.value == 0 and this.pressure_event == ABS_PRESSURE then
                local p = slotData(this, this.pen_slot)
                if p and p.tool == TOOL_PEN then this:setCurrentMtSlot("id", -1) end
            end
            return true
        end
        return false
    end
    local function steerKey(this, ev)
        if ev.code == BTN_TOUCH then
            if penActive(this) then
                this:setupSlotData(this.pen_slot)
                this:setCurrentMtSlot("id", ev.value == 1 and this.pen_slot or -1)
                return true
            end
            -- Some reports put the touch BEFORE the pen's "in range" key in the
            -- same frame. Hold it until that key arrives, or the contact-down is
            -- lost and the whole stroke is taken for hovering.
            h.touch_pending = ev.value
        elseif (ev.code == BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER) and ev.value == 1
                and h.touch_pending == 1 then
            key(this, ev)                                -- KOReader sets the pen tool
            this:setupSlotData(this.pen_slot)
            this:setCurrentMtSlot("id", this.pen_slot)
            h.touch_pending = nil
            return true
        end
        return false
    end

    -- A fault in the bridge must never take KOReader's input loop down: it removes
    -- itself and the event goes to KOReader as if the bridge had never been there.
    input.handleTouchEv = function(this, ev)
        if not h.dead then
            local ok, took = pcall(steerTouch, this, ev)
            if ok and took then return nil end
            if not ok then h.dead = true; pcall(PenBridge.uninstall, h) end
        end
        return touch(this, ev)
    end
    input.handleKeyBoardEv = function(this, ev)
        if not h.dead then
            local ok, took = pcall(steerKey, this, ev)
            if ok and took then return nil end
            if not ok then h.dead = true; pcall(PenBridge.uninstall, h) end
        end
        return key(this, ev)
    end

    h.touch_wrapper, h.key_wrapper = input.handleTouchEv, input.handleKeyBoardEv
    return h
end

function PenBridge.uninstall(h)
    if not h then return end
    local input = h.input
    -- Only unwind what is still ours (another wrapper may sit on top: leave it).
    if rawget(input, "handleTouchEv") == h.touch_wrapper then input.handleTouchEv = nil end
    if rawget(input, "handleKeyBoardEv") == h.key_wrapper then input.handleKeyBoardEv = nil end
    if input.pen_slot == PenBridge.PEN_SLOT then
        local moved = slotData(input, PenBridge.PEN_SLOT)
        local back = ensureSlot(input, h.orig_pen_slot)
        if back then
            back.tool = moved and moved.tool or TOOL_FINGER
            back.id = -1
        end
        if moved then moved.id = -1 end
        input.pen_slot = h.orig_pen_slot
        if input.cur_slot == PenBridge.PEN_SLOT then input.cur_slot = input.main_finger_slot or 0 end
    end
end

return PenBridge
