-- Tests for the pure stylus helpers (ink/stylus): the screen-rotation coordinate
-- transform and the pen down/move/up state machine. Pure Lua under luajit.
--
--   luajit tests/stylus.lua

package.path = "./?.lua;" .. package.path
local S = require("ink/stylus")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
-- assert S.rotate(x,y,mode,w,h) == (bx,by)
local function rot(x, y, mode, w, h, bx, by, what)
    local ax, ay = S.rotate(x, y, mode, w, h)
    ok(ax == bx and ay == by, ("%s (got %s,%s want %s,%s)"):format(what, ax, ay, bx, by))
end

-- ---- rotation transform (mirrors GestureDetector:translateCoordinates) -------
-- screen 100 x 200, a point at (10, 20)
do
    local w, h = 100, 200
    rot(10, 20, 0, w, h, 10, 20, "upright: unchanged")
    rot(10, 20, 1, w, h, w - 20, 10, "clockwise: (w-y, x)")
    rot(10, 20, 2, w, h, w - 10, h - 20, "upside down: (w-x, h-y)")
    rot(10, 20, 3, w, h, 20, h - 10, "counter-clockwise: (y, h-x)")

    -- 180 is its own inverse
    local rx, ry = S.rotate(10, 20, 2, w, h)
    rot(rx, ry, 2, w, h, 10, 20, "180 twice returns to the start")
end

-- ---- pen down/move/up state machine -----------------------------------------
do
    local st = S.new()
    ok(st.down == false, "fresh state is up")
    ok(S.step(st, 3) == "down", "first contact -> down")
    ok(st.down == true, "state marked down")
    ok(S.step(st, 3) == "move", "same contact -> move")
    ok(S.step(st, 7) == "move", "a new tracking id mid-contact is still a move")
    ok(S.step(st, -1) == "up", "id -1 -> up")
    ok(st.down == false, "state marked up")
    ok(S.step(st, -1) == nil, "still up -> nil")
    ok(S.step(st, nil) == nil, "no id -> nil")
    -- a fresh press after a lift starts a new down
    ok(S.step(st, 2) == "down", "press again -> down")
end

-- ---- tool classification -----------------------------------------------------
do
    ok(S.isPen(S.TOOL_PEN), "pen is a pen tool")
    ok(S.isPen(S.TOOL_ERASER), "eraser tip is a pen tool")
    ok(S.isPen(S.TOOL_HIGHLIGHTER), "highlighter is a pen tool")
    ok(not S.isPen(S.TOOL_FINGER), "finger is not a pen tool")
end

-- ---- slot role classification (the palm-rejection heart) ---------------------
-- The regression the tester hit: on a Scribe a resting palm is routed to the
-- stylus callback with tool == 2 (MT_TOOL_PALM), which is also TOOL_TYPE_ERASER.
-- classify must call that a palm, not the pen's eraser, whenever it is on a slot
-- other than the digitizer's dedicated pen slot.
local PEN, ERA, HIL, FIN = S.TOOL_PEN, S.TOOL_ERASER, S.TOOL_HIGHLIGHTER, S.TOOL_FINGER
local function role(slot, facts) return S.classify(slot, facts) end

-- Wacom devices (Kindle Scribe, reMarkable): the pen owns pen_slot=5.
do
    local wacom = { wacom = true, pen_slot = 5 }
    ok(role({ slot = 5, tool = PEN, id = 1 }, wacom) == S.ROLE_PEN,
        "wacom: pen on pen slot -> pen")
    ok(role({ slot = 5, tool = ERA, id = 1 }, wacom) == S.ROLE_PEN,
        "wacom: rear eraser on pen slot -> pen (a real eraser)")
    ok(role({ slot = 0, tool = ERA, id = 7 }, wacom) == S.ROLE_PALM,
        "wacom: tool 2 on a finger slot -> palm (the bug: MT_TOOL_PALM==ERASER)")
    ok(role({ slot = 1, tool = PEN, id = 7 }, wacom) == S.ROLE_PEN,
        "wacom: a PEN tool is ALWAYS the pen (no finger/palm ever reports PEN)")
    ok(role({ slot = 2, tool = FIN, id = 7 }, wacom) == S.ROLE_TOUCH,
        "wacom: a plain finger off the pen slot -> touch")
    -- The dead-pen fix: even when the runtime never populated the pen slot, a real
    -- pen tip must still draw (the Kindle Scribe gen 1 "pen doesn't work" report).
    local nolot = { wacom = true, pen_slot = nil }
    ok(role({ slot = 0, tool = PEN, id = 1 }, nolot) == S.ROLE_PEN,
        "wacom without a pen slot: a real PEN tool still draws (dead-pen fix)")
    ok(role({ slot = 0, tool = ERA, id = 1 }, nolot) == S.ROLE_PALM,
        "wacom without a pen slot or learned slot: a bare tool 2 -> palm")
    ok(role({ slot = 0, tool = ERA, id = 1 }, { wacom = true, learned_slot = 0 }) == S.ROLE_PEN,
        "wacom: rear eraser (tool 2) on the LEARNED pen slot -> pen")
    ok(role({ slot = 3, tool = ERA, id = 1 }, { wacom = true, learned_slot = 0 }) == S.ROLE_PALM,
        "wacom: tool 2 off the learned pen slot -> palm")
    ok(role({ slot = 0, tool = FIN, id = 1 }, nolot) == S.ROLE_TOUCH,
        "wacom without a pen slot: a finger -> touch")
end

-- Off-Wacom devices (Kobo stylus, SDL, Android). tool value + latch + slot decide.
do
    local kobo = { wacom = false, pen_slot = 5 }
    ok(role({ slot = 5, tool = ERA, id = 1 }, kobo) == S.ROLE_PEN,
        "kobo: a stylus tool on the pen slot -> pen (rear eraser)")
    ok(role({ slot = 5, tool = FIN, id = 1 }, kobo) == S.ROLE_TOUCH,
        "kobo: a plain finger on the pen slot -> touch")
    ok(role({ slot = 1, tool = PEN, id = 1 }, kobo) == S.ROLE_PEN,
        "kobo: a real PEN tool -> pen")
    ok(role({ slot = 1, tool = ERA, id = 1 }, kobo) == S.ROLE_PALM,
        "kobo: bare tool 2 off the pen slot, no latch -> palm (panel MT_TOOL_PALM)")
    ok(role({ slot = 1, tool = ERA, id = 1 }, { wacom = false, eraser_latch = true }) == S.ROLE_PEN,
        "kobo: tool 2 WITH the eraser barrel latch -> pen (a held button)")
    ok(role({ slot = 1, tool = HIL, id = 1 }, { wacom = false }) == S.ROLE_PALM,
        "kobo: bare tool 3, no highlighter latch -> palm (panel MT_TOOL_DIAL)")
    ok(role({ slot = 1, tool = HIL, id = 1 }, { wacom = false, highlighter_latch = true }) == S.ROLE_PEN,
        "kobo: tool 3 WITH the highlighter latch -> pen")
    ok(role({ slot = 1, tool = FIN, id = 1 }, kobo) == S.ROLE_TOUCH,
        "kobo: a plain finger -> touch")
end

-- Guards.
do
    ok(role(nil, { wacom = true, pen_slot = 5 }) == S.ROLE_TOUCH, "nil slot -> touch")
    ok(role({ slot = 5, tool = PEN, id = 1 }, nil) == S.ROLE_PEN,
        "no facts: a PEN tool still classifies as pen")
    ok(role({ slot = 0, tool = ERA, id = 1 }, nil) == S.ROLE_PALM,
        "no facts: bare tool 2 -> palm (never draw from a guessed eraser)")
end

-- Kinematic palm filter (Stylus.acceptMove): a real nib cannot teleport.
do
    local st = {}
    ok(S.acceptMove(st, 100, 100, 8, 1) == true, "acceptMove: the first point is seeded/accepted")
    ok(S.acceptMove(st, 110, 108, 8, 1) == true, "acceptMove: a small physical move is accepted")
    ok(S.acceptMove(st, 900, 700, 8, 1) == false, "acceptMove: an implausible jump is dropped")
    -- with no timestamp the filter never engages (never worse than not filtering)
    local st2 = {}
    ok(S.acceptMove(st2, 0, 0, nil, 1) == true, "acceptMove: seeds with no clock")
    ok(S.acceptMove(st2, 5000, 5000, nil, 1) == true, "acceptMove: no clock -> no filtering")
    -- escape hatch: after `limit` consecutive drops, accept one so a stroke can't wedge
    local st3 = { x = 0, y = 0, drops = 0 }
    local function far() return S.acceptMove(st3, 5000, 5000, 1, 1) end
    for _ = 1, 7 do far() end
    local acc, restart = far()
    ok(acc == true, "acceptMove: accepts after the drop limit (no permanent wedge)")
    ok(restart == true, "acceptMove: ...but as a NEW stroke, never a connecting segment")
    -- a long silence then a far point: a lift we never saw -> accept as a new stroke
    local st4 = {}
    S.acceptMove(st4, 100, 100, 8, 1)
    local a4, r4 = S.acceptMove(st4, 700, 900, 400, 1)
    ok(a4 == true and r4 == true, "acceptMove: far point after a long gap starts a new stroke")
    -- a pause then a nearby point (pen held still on the glass) stays the same stroke
    local a5, r5 = S.acceptMove(st4, 705, 903, 400, 1)
    ok(a5 == true and not r5, "acceptMove: a pause without moving away continues the stroke")
    -- ordinary fast writing at 100 Hz is accepted
    local st6 = {}
    S.acceptMove(st6, 0, 0, 10, 1)
    local a6, r6 = S.acceptMove(st6, 60, 40, 10, 1)
    ok(a6 == true and not r6, "acceptMove: a fast pen move between frames is accepted")
end

-- Slot timestamps: KOReader stamps slots with fts MICROSECONDS (time.timeval).
do
    ok(S.timevMs(1700000000 * 1000000 + 8000) == 1700000000 * 1000 + 8,
        "timevMs: fts microseconds -> ms (was read as seconds: filter wide open)")
    ok(S.timevMs({ sec = 2, usec = 500000 }) == 2500, "timevMs: {sec,usec} table -> ms")
    ok(S.timevMs(nil) == nil, "timevMs: no stamp -> nil")
end

-- Pen leaving range on its own slot (KOReader writes FINGER there on BTN_TOOL_PEN 0).
do
    local wacom = { wacom = true, pen_slot = 4 }
    ok(role({ slot = 4, tool = FIN, id = -1 }, wacom) == S.ROLE_PEN_OUT,
        "wacom: tool 0 on the pen slot is the pen leaving range (the 'tool=0 slot=4' frame)")
    ok(role({ slot = 4, tool = FIN, id = 4 }, wacom) == S.ROLE_PEN_OUT,
        "wacom: tool 0 on the pen slot with a stale live id still ends the pen")
    ok(role({ slot = 4, tool = FIN, id = 1 }, { wacom = false, pen_slot = 4 }) == S.ROLE_TOUCH,
        "kobo: a finger on slot 4 is just a finger (no dedicated pen slot)")
end

-- Pen action: the rear eraser end erases, the primary side (barrel) button is a
-- lasso-select modifier, everything else draws. KOReader overrides a held side
-- button's tool to ERASER, so the eraser latch is what tells the button apart from
-- the pen's real rear-eraser end.
do
    local PENt, ERAt, HILt = S.TOOL_PEN, S.TOOL_ERASER, S.TOOL_HIGHLIGHTER
    ok(S.penAction({ tool = PENt }, {}) == S.ACT_DRAW, "penAction: a plain pen tip draws")
    ok(S.penAction({ tool = ERAt }, {}) == S.ACT_ERASE,
        "penAction: the rear eraser end (tool 2, no latch) erases")
    ok(S.penAction({ tool = ERAt }, { eraser_latch = true }) == S.ACT_SELECT,
        "penAction: the side button (eraser latch) is lasso select, not erase")
    ok(S.penAction({ tool = PENt }, { eraser_latch = true }) == S.ACT_SELECT,
        "penAction: the side-button latch wins even if the tool still reads pen")
    ok(S.penAction({ tool = HILt }, { highlighter_latch = true }) == S.ACT_DRAW,
        "penAction: the second barrel button draws with the current tool")
    ok(S.penAction({ tool = ERAt }, nil) == S.ACT_ERASE,
        "penAction: with no facts the rear tip still erases")
end

print(string.format("stylus: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
