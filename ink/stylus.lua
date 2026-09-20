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
--   wacom             true on a Wacom protocol device (Kindle Scribe, reMarkable)
--   eraser_latch      Input.stylus_eraser_active (a held barrel button, off Wacom)
--   highlighter_latch Input.stylus_highlighter_active
-- Returns one of ROLE_PEN / ROLE_PALM / ROLE_TOUCH.
Stylus.ROLE_PEN   = "pen"     -- a trusted stylus: draw or erase with it
Stylus.ROLE_PALM  = "palm"    -- a palm promoted to a stylus tool number: discard
Stylus.ROLE_TOUCH = "touch"   -- an ordinary finger that only reached us in passing
function Stylus.classify(slot, facts)
    if not slot then return Stylus.ROLE_TOUCH end
    facts = facts or {}
    local tool = slot.tool
    local stylus_tool = Stylus.isPen(tool)
    local pen_slot = facts.pen_slot

    if facts.wacom then
        -- Wacom (Kindle Scribe, reMarkable): the digitizer owns one pen slot, and
        -- the pen and its rear eraser are ALWAYS on it. A stylus-valued tool on
        -- any other slot is the palm collision above.
        if pen_slot == nil then
            -- The runtime never told us the pen slot: fail closed so nothing draws
            -- from a guess.
            return stylus_tool and Stylus.ROLE_PALM or Stylus.ROLE_TOUCH
        end
        if slot.slot == pen_slot then return Stylus.ROLE_PEN end
        if stylus_tool then return Stylus.ROLE_PALM end
        return Stylus.ROLE_TOUCH
    end

    -- Off Wacom (Kobo stylus, SDL) the tool number has several possible authors.
    -- The dedicated pen slot decides first; then a real PEN tool (the one value
    -- that means "pen" in every namespace); then KOReader's own barrel-button
    -- latch, which rewrites PEN into ERASER/HIGHLIGHTER while the button is held
    -- (live on a Kobo). A bare 2/3 with no latch is a panel MT_TOOL_PALM/DIAL --
    -- a palm.
    if pen_slot ~= nil and slot.slot == pen_slot then return Stylus.ROLE_PEN end
    if tool == Stylus.TOOL_PEN then return Stylus.ROLE_PEN end
    if tool == Stylus.TOOL_ERASER and facts.eraser_latch then return Stylus.ROLE_PEN end
    if tool == Stylus.TOOL_HIGHLIGHTER and facts.highlighter_latch then return Stylus.ROLE_PEN end
    if stylus_tool then return Stylus.ROLE_PALM end
    return Stylus.ROLE_TOUCH
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
