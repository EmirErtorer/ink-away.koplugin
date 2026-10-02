-- Kindle Scribe pen + palm replay through KOReader's REAL Input/GestureDetector
-- (from the KOReader checkout, see tests/README.md) into Ink Away's real view.
-- Run from the plugin root:
--   luajit tests/scribe/replay.lua          summary + pass/fail
--   V=1 ONLY=S2 luajit tests/scribe/replay.lua   one scenario with the frame trace
local H = dofile("tests/scribe/harness.lua")
local pen, panel = H.pen, H.panel
local ONLY = os.getenv("ONLY")
print(("pen bridge: %s"):format(H.use_bridge and "on" or "off"))

local AX0, AY0 = 200, 300      -- stroke A (top-left)
local BX0, BY0 = 800, 1200     -- stroke B (bottom-right, far away)

local function strokeA(w, n)
    pen.enter(w, AX0 - 5, AY0 - 5, 50)
    for i = 1, 3 do pen.hover(w, AX0 - 5 + i, AY0 - 5 + i, 7) end
    pen.touch(w, AX0, AY0, 7)
    n = n or 12
    for i = 1, n do pen.move(w, AX0 + i * 6, AY0 + i * 3, 7) end
    return AX0 + n * 6, AY0 + n * 3
end
local function strokeBbody(w)
    for i = 1, 12 do pen.move(w, BX0 + i * 6, BY0 - i * 4, 7) end
    pen.lift(w, 7)
    pen.leave(w, 40)
end
local function strokeB(w)
    pen.enter(w, BX0 - 5, BY0 - 5, 300)
    for i = 1, 3 do pen.hover(w, BX0 - 5 + i, BY0 - 5 + i, 7) end
    pen.touch(w, BX0, BY0, 7)
    strokeBbody(w)
end

local rows = {}
local function run(id, desc, fn, opts)
    if ONLY and ONLY ~= id then return end
    local w = H.newWorld(opts)
    local extra = fn(w)
    local r = H.report(id .. ": " .. desc, w, extra)
    rows[#rows + 1] = { id, r }
end

run("S0", "pen only; lift, hover, leave in separate frames; re-enter far away", function(w)
    local ax, ay = strokeA(w)
    pen.lift(w, 7); pen.hover(w, ax, ay - 20, 7); pen.leave(w, 7)
    strokeB(w)
end)

run("S1", "lift+leave in ONE frame (BTN_TOUCH first); finger stroke later; pen re-enters (hover first)", function(w)
    local ax, ay = strokeA(w)
    pen.liftLeave(w, 7)
    local st = ("right after the lift+leave frame: pen down=%s capturing=%s"):format(
        tostring(w.view._pen_state.down), tostring(w.view.capturing))
    H.UIManager.fireScheduled()           -- debounce long expired
    local rej = w.view:fingerRejected()
    -- a finger stroke 2 s later, pen out of range (palm rejection should not block it)
    local n0 = w.view.canvas:opCount()
    panel.down(w, 0, 300, 300, 800, 0, 2000)
    for i = 1, 8 do panel.move(w, { { 0, 300 + i * 12, 800 + i * 6 } }, 12) end
    panel.up(w, 0, 12)
    H.UIManager.fireScheduled()
    local finger_ok = w.view.canvas:opCount() > n0
    strokeB(w)
    return st .. (" | after debounce fingerRejected=%s | finger stroke drew: %s"):format(tostring(rej), tostring(finger_ok))
end)

run("S1b", "lift+leave in one frame (BTN_TOUCH first), then enter+touch in one frame (tool first)", function(w)
    strokeA(w)
    pen.liftLeave(w, 7)
    pen.enterTouch(w, BX0, BY0, 400)
    strokeBbody(w)
end)

run("S1c", "leave+lift in one frame (BTN_TOOL_PEN first), pen re-enters (hover first)", function(w)
    strokeA(w)
    pen.leaveLift(w, 7)
    local s4 = w.input.ev_slots[w.input.pen_slot]
    local mid = ("KOReader pen slot after that frame: id=%s tool=%s"):format(tostring(s4.id), tostring(s4.tool))
    strokeB(w)
    return mid
end)

run("S1d", "clean leave, then touch+enter in one frame (BTN_TOUCH first)", function(w)
    local ax, ay = strokeA(w)
    pen.lift(w, 7); pen.hover(w, ax, ay - 20, 7); pen.leave(w, 7)
    pen.touchEnter(w, BX0, BY0, 400)
    strokeBbody(w)
end)

-- THE VIDEO: palm resting (two ordinary-finger contacts) while writing; the panel's
-- ABS_MT_SLOT moves the shared cursor between pen frames.
run("S2", "palm (finger tool, 2 contacts) rests while writing; palm lifts; pen draws far away", function(w)
    pen.enter(w, AX0 - 5, AY0 - 5, 50)
    pen.touch(w, AX0, AY0, 7)
    pen.move(w, AX0 + 6, AY0 + 3, 7)
    panel.down(w, 0, 101, 500, 700, 0, 3)
    panel.down(w, 1, 102, 560, 760, 0, 3)
    local ax, ay
    for i = 2, 14 do
        pen.move(w, AX0 + i * 6, AY0 + i * 3, 4); ax, ay = AX0 + i * 6, AY0 + i * 3
        if i % 2 == 0 then panel.move(w, { { 0, 500 + i, 700 }, { 1, 560 + i, 760 } }, 3) end
    end
    pen.lift(w, 7)
    local mid = ("after the pen's BTN_TOUCH 0: KOReader pen slot id=%s (cur_slot was %s)")
        :format(tostring(w.input.ev_slots[w.input.pen_slot].id), tostring(w.input.cur_slot))
    pen.hover(w, ax + 10, ay - 10, 7)
    panel.up(w, 0, 20); panel.up(w, 1, 5)
    pen.leave(w, 30)
    strokeB(w)
    return mid
end)

run("S2b", "as S2 but the panel flags both palm contacts MT_TOOL_PALM (2)", function(w)
    pen.enter(w, AX0 - 5, AY0 - 5, 50)
    pen.touch(w, AX0, AY0, 7)
    pen.move(w, AX0 + 6, AY0 + 3, 7)
    panel.down(w, 0, 101, 500, 700, 0, 3)
    panel.down(w, 1, 102, 560, 760, 0, 3)
    panel.move(w, { { 0, 501, 700, 2 }, { 1, 561, 760, 2 } }, 3)
    for i = 2, 14 do
        pen.move(w, AX0 + i * 6, AY0 + i * 3, 4)
        if i % 2 == 0 then panel.move(w, { { 0, 500 + i, 700 }, { 1, 560 + i, 760 } }, 3) end
    end
    pen.lift(w, 7)
    pen.hover(w, 300, 330, 7)
    panel.up(w, 0, 20); panel.up(w, 1, 5)
    pen.leave(w, 30)
    strokeB(w)
end)

run("S3", "pen hovering; a palm lands with no ABS_MT_SLOT (panel's last slot was 0), finger tool", function(w)
    w.panel_last_slot = 0
    pen.enter(w, AX0 - 5, AY0 - 5, 50)
    for i = 1, 4 do pen.hover(w, AX0 + i, AY0 + i, 7) end
    panel.down(w, 0, 201, 600, 900, 0, 3)
    for i = 1, 6 do panel.move(w, { { 0, 600 + i * 6, 900 + i * 4 } }, 8) end
    panel.up(w, 0, 8)
    pen.leave(w, 30)
end)

run("S4", "pen hovering; palm lands with no ABS_MT_SLOT flagged MT_TOOL_PALM; then the pen writes", function(w)
    w.panel_last_slot = 0
    pen.enter(w, AX0 - 5, AY0 - 5, 50)
    for i = 1, 4 do pen.hover(w, AX0 + i, AY0 + i, 7) end
    panel.down(w, 0, 201, 600, 900, 2, 3)
    pen.hover(w, AX0 + 5, AY0 + 5, 7)
    pen.touch(w, AX0, AY0, 7)
    for i = 1, 12 do pen.move(w, AX0 + i * 6, AY0 + i * 3, 7) end
    pen.lift(w, 7)
    panel.up(w, 0, 8)
    pen.leave(w, 30)
    return ("tool Ink Away ended with: %s"):format(tostring(w.view.tool))
end)

run("S5", "pen hovering 1 s after a stroke; palm lands on its OWN slot (proper ABS_MT_SLOT)", function(w)
    local ax, ay = strokeA(w)
    pen.lift(w, 7)
    for i = 1, 12 do pen.hover(w, ax + i, ay + i, 80) end     -- ~1 s of hover
    w.panel_last_slot = 3                                    -- forces an ABS_MT_SLOT 0
    panel.down(w, 0, 301, 600, 900, 0, 3)
    pen.hover(w, ax + 20, ay + 20, 5)
    for i = 1, 6 do panel.move(w, { { 0, 600 + i * 6, 900 + i * 4 } }, 8); pen.hover(w, ax + 20 + i, ay + 20, 2) end
    panel.up(w, 0, 8)
    pen.leave(w, 30)
end)

-- Handwriting with the palm resting: several short strokes with hover in between,
-- palm jitter frames interleaved; then palm lifts, pen leaves, far stroke.
run("S6", "4 short strokes with a resting palm (finger tool) jittering; then a far stroke", function(w)
    pen.enter(w, AX0 - 5, AY0 - 5, 50)
    panel.down(w, 0, 401, 520, 760, 0, 3)
    local jitter = 0
    for s = 0, 3 do
        local x0 = AX0 + s * 60
        pen.hover(w, x0 - 2, AY0 - 2, 7)
        pen.touch(w, x0, AY0, 7)
        for i = 1, 8 do
            pen.move(w, x0 + i * 4, AY0 + (i % 4) * 8, 6)
            if i % 3 == 0 then jitter = jitter + 1; panel.move(w, { { 0, 520 + jitter, 760 + jitter } }, 2) end
        end
        pen.lift(w, 6)
        pen.hover(w, x0 + 40, AY0 - 10, 6)
    end
    panel.up(w, 0, 30)
    pen.leave(w, 30)
    strokeB(w)
    return "expected: 5 separate pen strokes (4 short + B), no connecting line, no palm mark"
end)

print()
print("SUMMARY  id    fedStrokes ops connects palmMarks penPalmLines eraseOps hoverInk panelInk teleports  touchFramesDrawn  endDown endRejected")
for _, row in ipairs(rows) do
    local id, r = row[1], row[2]
    print(("         %-5s %-10d %-3d %-8d %-9d %-12d %-8d %-8d %-8d %-9d %3d/%-3d           %-7s %s"):format(id, r.fed_strokes,
        #r.ops, r.connects, r.palm_marks, r.pen_palm, r.erase_ops, r.hover_fed, r.panel_fed, r.teleports,
        r.fed_touch, r.touch_frames, tostring(r.final_down), tostring(r.final_rejected)))
end

-- Pass/fail: every scenario must draw every touching pen frame, never connect two
-- strokes, never ink from a palm, hover or the panel, and leave nothing stuck.
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
for _, row in ipairs(rows) do
    local id, r = row[1], row[2]
    ok(r.connects == 0 and r.pen_palm == 0 and r.teleports == 0, id .. ": no straight line joins strokes")
    ok(r.palm_marks == 0 and r.hover_fed == 0 and r.panel_fed == 0, id .. ": no ink from a palm, hover or the panel")
    ok(r.fed_touch == r.touch_frames, id .. ": every touching pen frame is drawn")
    ok(not r.final_down and not r.final_rejected, id .. ": no stuck pen or finger rejection")
end
print(("scribe: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
