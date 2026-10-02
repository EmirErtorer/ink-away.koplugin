--[[
Pure pen helpers for palm rejection, testable without KOReader.

KOReader hands a plugin raw stylus events through Input:registerStylusCallback
(frontend/device/input.lua). The callback runs before gesture detection, once per
input frame while the pen is present, with a slot table {slot, id, x, y, tool,
timev}; returning true "dominates" the event so it never becomes a gesture.

Tool values are the ABS_MT_TOOL_TYPE constants KOReader uses: finger 0, pen 1,
eraser 2, highlighter 3.
]]

local Stylus = {}

Stylus.TOOL_FINGER = 0
Stylus.TOOL_PEN = 1
Stylus.TOOL_ERASER = 2
Stylus.TOOL_HIGHLIGHTER = 3

-- Apply the screen rotation to a raw slot position, as
-- GestureDetector:translateCoordinates does for a gesture (its only adjustment
-- after the raw position). The stylus callback fires before that step, so raw
-- coordinates need it. `mode` is 0 upright, 1 clockwise, 2 upside down or 3
-- counter-clockwise; `w` and `h` are the current (rotated) screen size.
-- Returns tx, ty.
function Stylus.rotate(x, y, mode, w, h)
    if mode == 1 then          -- clockwise (landscape)
        return w - y, x
    elseif mode == 2 then      -- upside down (portrait)
        return w - x, h - y
    elseif mode == 3 then      -- counter-clockwise (landscape)
        return y, h - x
    end
    return x, y                -- upright: unchanged
end

-- Is a tool type one of the pen-like tools we take over?
function Stylus.isPen(tool)
    return tool == Stylus.TOOL_PEN
        or tool == Stylus.TOOL_ERASER
        or tool == Stylus.TOOL_HIGHLIGHTER
end

-- What a routed slot physically is. Input:routeStylusEvents hands the callback
-- any slot with a pen, eraser or highlighter tool, or on the dedicated pen slot,
-- so a routed slot is not necessarily the pen: Linux reports a rejected touch as
-- MT_TOOL_PALM, the same value (2) as the eraser, so a resting palm arrives
-- looking like the eraser.
--
-- The tool type comes first. A pen tip always reports TOOL_PEN (1) and no finger
-- or palm ever does, so TOOL_PEN is trusted even where Input.pen_slot is never
-- set. The slot only settles the ambiguous eraser value: a stylus tool on the
-- pen's own slot (preset by the runtime, or learned from the first real pen
-- frame) or with a barrel-button latch is the pen; any other bare 2 or 3 is a
-- promoted palm.
--
-- `facts` carries what only the live Input object knows:
--   pen_slot          the digitizer's dedicated slot number (or nil)
--   learned_slot      the slot a genuine TOOL_PEN frame was last seen on
--   wacom             true on a Wacom protocol device (Kindle Scribe, reMarkable)
--   eraser_latch      Input.stylus_eraser_active (a held barrel button)
--   highlighter_latch Input.stylus_highlighter_active
-- Returns one of the ROLE_ values below.
Stylus.ROLE_PEN   = "pen"     -- a trusted stylus: draw or erase with it
Stylus.ROLE_PALM  = "palm"    -- a palm promoted to a stylus tool number: discard
Stylus.ROLE_TOUCH = "touch"   -- an ordinary finger that only reached us in passing
Stylus.ROLE_PEN_OUT = "pen_out" -- the pen leaving range on its dedicated slot: end the stroke
function Stylus.classify(slot, facts)
    if not slot then return Stylus.ROLE_TOUCH end
    facts = facts or {}
    local tool = slot.tool
    local stylus_tool = Stylus.isPen(tool)
    local pen_slot = facts.pen_slot
    local learned = facts.learned_slot
    local on_pen_slot = (pen_slot ~= nil and slot.slot == pen_slot)
                     or (learned ~= nil and slot.slot == learned)

    -- 0. On a Wacom device KOReader writes the finger tool into the pen's own
    --    slot when the pen leaves range (BTN_TOOL_PEN 0). That frame is the pen
    --    going away, never a finger, and when the pen is lifted out of range in
    --    one quick motion it is the only lift we get, so it must end the stroke;
    --    otherwise the next pen-down draws a line from the previous stroke.
    if facts.wacom and on_pen_slot and not stylus_tool then return Stylus.ROLE_PEN_OUT end

    -- 1. A real pen tip is unambiguous on every device: always the pen.
    if tool == Stylus.TOOL_PEN then return Stylus.ROLE_PEN end
    -- 2. On the pen's own slot (preset or learned) a stylus tool is the pen, its
    --    rear eraser, or a held barrel button.
    if on_pen_slot and stylus_tool then return Stylus.ROLE_PEN end
    -- 3. KOReader rewrites the pen's tool to ERASER or HIGHLIGHTER while a side
    --    button is held; trust that latch even if the slot bookkeeping lags.
    if tool == Stylus.TOOL_ERASER and facts.eraser_latch then return Stylus.ROLE_PEN end
    if tool == Stylus.TOOL_HIGHLIGHTER and facts.highlighter_latch then return Stylus.ROLE_PEN end
    -- 4. Any other stylus tool number is a promoted palm (a bare 2 or 3, or a
    --    stylus tool on a slot that is not the pen's). Everything else is an
    --    ordinary finger that only reached the callback in passing.
    if stylus_tool then return Stylus.ROLE_PALM end
    return Stylus.ROLE_TOUCH
end

-- What a trusted pen contact should do, for slots already classified ROLE_PEN.
-- KOReader rewrites the tool to ERASER while the primary barrel button
-- (BTN_STYLUS, Input.stylus_eraser_active) is held, so the value 2 means either a
-- held side button or the pen's real rear eraser; the latch tells them apart:
--   primary side button held                  ACT_SELECT (lasso select)
--   rear eraser end (tool ERASER, no latch)   ACT_ERASE
--   anything else                             ACT_DRAW (the current tool)
Stylus.ACT_DRAW   = "draw"
Stylus.ACT_ERASE  = "erase"
Stylus.ACT_SELECT = "select"
function Stylus.penAction(slot, facts)
    facts = facts or {}
    if facts.eraser_latch then return Stylus.ACT_SELECT end   -- primary side button held
    if slot and slot.tool == Stylus.TOOL_ERASER then return Stylus.ACT_ERASE end
    return Stylus.ACT_DRAW
end

-- Kinematic palm filter: a real nib cannot teleport. Some Wacom panels (the
-- Kindle Scribe among them) share one slot table between the pen digitizer and the
-- touch panel, so a resting palm's coordinates land in the pen's slot and look like
-- the nib jumping across the page. A sample further than `base + dt * speed`
-- pixels from the last accepted point is not the pen and is dropped. After `limit`
-- drops in a row one is accepted anyway, so a lift that was never reported cannot
-- wedge the stroke.
--   state  {x, y, drops} for one stroke (pass a fresh {} at pen-down)
--   dt_ms  elapsed ms since the last sample, or nil when there is no clock
--   scale  the screen DPI factor, so the thresholds hold at any resolution
-- Returns whether to accept the sample, and `restart`: true when an accepted
-- sample cannot continue the line (the drop limit was hit, or the pen reappears
-- far away after a gap no drawing pen leaves). The caller then ends the stroke and
-- starts a new one there instead of joining them. Without dt_ms every sample is
-- accepted.
function Stylus.acceptMove(state, x, y, dt_ms, scale, tune)
    tune = tune or {}
    scale = scale or 1
    if state.x == nil then                       -- first point of the stroke: seed
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    if not (dt_ms and dt_ms >= 0) then           -- no reliable elapsed time: don't filter
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    local base  = tune.jump_base  or 48          -- px allowed even at ~zero elapsed
    local speed = tune.max_speed  or 6           -- px per ms a real nib can move
    local gap   = tune.max_gap_ms or 120         -- cap dt so a long gap can't allow anything
    local limit = tune.limit      or 8
    local dx, dy = x - state.x, y - state.y
    local d2 = dx * dx + dy * dy
    -- A pen on the glass reports continuously; a long silence followed by a point
    -- well away from the last one is a new contact whose lift we never saw.
    if dt_ms > gap and d2 > (base * scale) * (base * scale) then
        state.x, state.y, state.drops = x, y, 0
        return true, true
    end
    local dt = dt_ms < gap and dt_ms or gap
    local allowed = (base + dt * speed) * scale
    if d2 <= allowed * allowed then
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    state.drops = (state.drops or 0) + 1
    if state.drops >= limit then                  -- escape hatch: accept, as a new stroke
        state.x, state.y, state.drops = x, y, 0
        return true, true
    end
    return false
end

-- Milliseconds from a slot's timestamp. KOReader stamps slots with
-- time.timeval(ev.time), an fts number in microseconds; very old builds used a
-- {sec, usec} table. Returns nil when there is no usable stamp.
function Stylus.timevMs(tv)
    if type(tv) == "number" then return tv / 1000 end
    if type(tv) == "table" then
        local sec, usec = tv.tv_sec or tv.sec, tv.tv_usec or tv.usec
        if sec then return sec * 1000 + (usec or 0) / 1000 end
    end
    return nil
end

-- Fresh per-pen tracking state for step.
function Stylus.new()
    return { down = false }
end

-- Advance the down/move/up state machine with the slot's tracking id (>= 0 while
-- touching, nil or -1 when not) and return the transition: "down" (first
-- contact), "move" (still down), "up" (just lifted), or nil (still up).
function Stylus.step(st, id)
    local touching = id ~= nil and id >= 0
    if touching then
        if st.down then return "move" end
        st.down = true
        return "down"
    else
        if st.down then
            st.down = false
            return "up"
        end
        return nil
    end
end

return Stylus
