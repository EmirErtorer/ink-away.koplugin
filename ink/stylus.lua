--[[
Pen / stylus helpers for palm rejection, kept pure so they can be unit tested
without a KOReader environment.

KOReader hands a plugin raw stylus events through `Input:registerStylusCallback`
(frontend/device/input.lua). The callback runs BEFORE gesture detection, once per
input frame the pen is present, with a slot table `{slot, id, x, y, tool, timev}`,
and returning true "dominates" the event so it never becomes a normal gesture.

Two pure pieces live here:

  * `rotate(x, y, mode, w, h)` reproduces GestureDetector:translateCoordinates, the
    ONLY coordinate adjustment applied to a gesture after the raw slot position
    (verified against the engine: a gesture's pos is exactly the slot x/y, then
    this rotation). The stylus callback fires before that step, so a plugin that
    draws from raw slot coordinates must apply this itself or strokes are wrong in
    any rotated orientation. `mode` is normalised: 0 upright, 1 clockwise,
    2 upside down, 3 counter-clockwise; `w`/`h` are the CURRENT (rotated) screen
    width/height.

  * a tiny down/move/up state machine (`new`/`step`) driven by the slot tracking
    `id` (>= 0 while the pen touches, -1 on lift), so the caller gets clean
    "the pen just went down / moved / lifted" transitions.

Tool type values are the ABS_MT_TOOL_TYPE constants KOReader uses (Elan panels):
finger 0, pen 1, eraser 2, highlighter 3.
]]

local Stylus = {}

Stylus.TOOL_FINGER = 0
Stylus.TOOL_PEN = 1
Stylus.TOOL_ERASER = 2
Stylus.TOOL_HIGHLIGHTER = 3

-- Apply the screen-rotation coordinate transform (mirrors
-- GestureDetector:translateCoordinates) to a raw slot position. Returns tx, ty.
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

-- What a routed slot physically is. KOReader's Input:routeStylusEvents hands the
-- stylus callback ANY slot whose tool is PEN/ERASER/HIGHLIGHTER, OR which sits on
-- the dedicated pen slot -- so a slot arriving at the callback is not necessarily
-- the pen. The trap: Linux reports a rejected touch as MT_TOOL_PALM, whose value
-- (2) is the SAME number as TOOL_TYPE_ERASER, so a resting palm reaches the
-- callback wearing the eraser's tool. Believing it is what draws/erases from a
-- palm. The reliable signal is the slot: a Wacom digitizer owns one dedicated pen
-- slot, and a stylus-valued tool on any other slot is a promoted palm.
--
-- `facts` carries what only the live Input object knows:
--   pen_slot          the digitizer's dedicated slot number (or nil)
--   learned_slot      the slot a genuine TOOL_PEN frame was last seen on this
--                     session (the caller learns it dynamically; see below)
--   wacom             true on a Wacom protocol device (Kindle Scribe, reMarkable)
--   eraser_latch      Input.stylus_eraser_active (a held barrel button)
--   highlighter_latch Input.stylus_highlighter_active
-- Returns one of ROLE_PEN / ROLE_PALM / ROLE_TOUCH.
--
-- The primary signal is the TOOL TYPE, not the slot number. A genuine pen tip
-- always reports TOOL_PEN (1), and no finger or palm ever does -- Linux reuses the
-- ERASER value (2) for MT_TOOL_PALM, but never the PEN value. So TOOL_PEN can be
-- trusted unconditionally, which means the pen draws even on a device/firmware that
-- never populates Input.pen_slot (the Kindle Scribe gen 1 "the pen doesn't work"
-- report: the old code required a preset pen_slot and, finding it nil, classified
-- the real pen as a palm so nothing drew). The slot number is only a secondary hint
-- for disambiguating the ERASER value (rear tip vs resting palm): we trust a stylus
-- tool on the pen's OWN slot -- preset by the runtime, or learned from the first
-- real pen frame -- and the barrel-button latch, and treat any other bare 2/3 as a
-- promoted palm.
Stylus.ROLE_PEN   = "pen"     -- a trusted stylus: draw or erase with it
Stylus.ROLE_PALM  = "palm"    -- a palm promoted to a stylus tool number: discard
Stylus.ROLE_TOUCH = "touch"   -- an ordinary finger that only reached us in passing
function Stylus.classify(slot, facts)
    if not slot then return Stylus.ROLE_TOUCH end
    facts = facts or {}
    local tool = slot.tool
    local stylus_tool = Stylus.isPen(tool)
    local pen_slot = facts.pen_slot
    local learned = facts.learned_slot
    local on_pen_slot = (pen_slot ~= nil and slot.slot == pen_slot)
                     or (learned ~= nil and slot.slot == learned)

    -- 1. A real pen tip is unambiguous on every device: always the pen.
    if tool == Stylus.TOOL_PEN then return Stylus.ROLE_PEN end
    -- 2. On the pen's own slot (preset or learned) a stylus tool is the pen, its
    --    rear eraser, or a held barrel button.
    if on_pen_slot and stylus_tool then return Stylus.ROLE_PEN end
    -- 3. KOReader rewrites the pen's tool to ERASER/HIGHLIGHTER while a side button
    --    is held; trust that latch even if slot bookkeeping lags.
    if tool == Stylus.TOOL_ERASER and facts.eraser_latch then return Stylus.ROLE_PEN end
    if tool == Stylus.TOOL_HIGHLIGHTER and facts.highlighter_latch then return Stylus.ROLE_PEN end
    -- 4. Any other stylus tool number is a promoted palm (a bare 2/3 == MT_TOOL_PALM,
    --    or a stylus tool on a slot that is not the pen's). Everything else is an
    --    ordinary finger that only reached the callback in passing.
    if stylus_tool then return Stylus.ROLE_PALM end
    return Stylus.ROLE_TOUCH
end

-- Kinematic palm filter: a real nib cannot teleport. Some Wacom panels (the Kindle
-- Scribe among them) share one slot table between the pen digitizer and the
-- capacitive panel, so a resting palm's coordinates get written into the pen's slot
-- and arrive as the nib "jumping" across the page -- the "sometimes weird lines"
-- report. Physics tells them apart: a sample more than `base + dt*speed` (pixels)
-- from the last accepted point in the elapsed time `dt_ms` is not the pen, so it is
-- dropped rather than drawn to. After `limit` consecutive drops we accept one anyway
-- so a genuine unreported lift/re-touch can never wedge the stroke shut.
--   state: {x, y, drops} carried across ONE stroke (pass a fresh {} at pen-down)
--   dt_ms: elapsed ms since the last sample, or nil when no reliable clock exists
--   scale: Screen DPI factor so the pixel thresholds are resolution-independent
-- Returns true to ACCEPT the sample, false to DROP it. Pure / unit-testable. When
-- dt_ms is missing it accepts unconditionally (no clock -> no filtering, never worse
-- than not having the filter at all).
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
    local dt = dt_ms < gap and dt_ms or gap
    local allowed = (base + dt * speed) * scale
    local dx, dy = x - state.x, y - state.y
    if dx * dx + dy * dy <= allowed * allowed then
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    state.drops = (state.drops or 0) + 1
    if state.drops >= limit then                  -- escape hatch: accept and restart
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    return false
end

-- Fresh per-pen tracking state.
function Stylus.new()
    return { down = false }
end

-- Advance the state machine with the slot's tracking id and return the
-- transition: "down" (first contact), "move" (still down), "up" (just lifted),
-- or nil (still up, nothing to do). An id of nil or < 0 means "not touching".
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
