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

-- The touch panel takes a small contact (the edge of the hand at the side of the
-- screen) for a pen and reports MT_TOOL_PEN on its slot 0. That slot must never
-- become the pen's: the palm that then rests on it while the pen writes, as the
-- palm (2) or a finger (0), drew lines and broke the pen's strokes until a clean
-- pen stroke put things right (the Kindle Scribe 2024 report).
run("S7", "the panel reports a hand's edge as a pen on slot 0; then the palm rests on slot 0 while writing", function(w)
    panel.down(w, 0, 701, 560, 800, 1, 50)
    for i = 1, 4 do panel.move(w, { { 0, 560 + i * 4, 800 + i * 2 } }, 7) end
    panel.up(w, 0, 7)
    pen.enter(w, AX0 - 5, AY0 - 5, 60)
    pen.touch(w, AX0, AY0, 7)
    pen.move(w, AX0 + 6, AY0 + 3, 7)
    panel.down(w, 0, 702, 500, 700, 2, 3)
    for i = 2, 14 do
        pen.move(w, AX0 + i * 6, AY0 + i * 3, 4)
        if i % 2 == 0 then panel.move(w, { { 0, 500 + i * 3, 700 + i * 2 } }, 3) end
    end
    pen.lift(w, 7)
    panel.move(w, { { 0, 560, 760, 0 } }, 20)      -- the hand, now reported as a finger
    pen.hover(w, 300, 330, 7)
    panel.up(w, 0, 20)
    pen.leave(w, 30)
    strokeB(w)
    return ("learned pen slot: %s (the pen's is %s)"):format(tostring(w.view._learned_pen_slot), tostring(w.input.pen_slot))
end)

run("S7b", "the hand's edge, reported as a pen, rests on the panel while the pen writes", function(w)
    panel.down(w, 0, 711, 600, 800, 1, 50)
    pen.enter(w, AX0 - 5, AY0 - 5, 10)
    pen.touch(w, AX0, AY0, 7)
    for i = 1, 14 do
        pen.move(w, AX0 + i * 6, AY0 + i * 3, 4)
        if i % 2 == 0 then panel.move(w, { { 0, 600 + i * 2, 800 + i } }, 3) end
    end
    pen.lift(w, 7)
    pen.hover(w, 300, 330, 7)
    panel.up(w, 0, 20)
    pen.leave(w, 30)
    strokeB(w)
end)

---------------------------------------------------------------------------
-- Pen taps menus and buttons: a pen contact that lands on the toolbar, a
-- floating control, the notebook bar or a shown menu goes to the gesture
-- detector like a finger.
---------------------------------------------------------------------------
local uichecks = {}
local function uiok(c, what) uichecks[#uichecks + 1] = { c, what } end
local C = require("ffi").C
local K, A = C.EV_KEY, C.EV_ABS

local function tapAt(w, x, y)
    pen.enter(w, x - 3, y - 3, 60)
    pen.hover(w, x - 1, y - 1, 7)
    pen.touch(w, x, y, 7)
    pen.move(w, x, y, 7)
    pen.lift(w, 7)
    pen.leave(w, 30)
end
local function gestures(w, name)
    local out = {}
    for _, g in ipairs(w.ges_log) do if g.ges == name then out[#out + 1] = g end end
    return out
end
local function uirun(id, desc, fn, opts)
    if ONLY and ONLY ~= id then return end
    local w = H.newWorld(opts)
    print(("=== %s: %s ==="):format(id, desc))
    fn(w)
    if os.getenv("V") == "1" then for _, l in ipairs(w.log) do print(l) end end
    H.tick(w, 1000)   -- the lift debounce and the UI pass-through run out
    local v = w.view
    uiok(not v._pen_ui_contact and v._pen_ui == nil, id .. ": the UI contact ended")
    uiok(not v._pen_state.down and not v:fingerRejected(), id .. ": no stuck pen or finger rejection")
end

uirun("U1", "pen taps the toolbar", function(w)
    local v = w.view
    local y = math.floor(v.view.area_y / 2)
    tapAt(w, 300, y)
    local taps = gestures(w, "tap")
    uiok(#taps == 1 and taps[1].x == 300 and taps[1].y == y, "U1: one tap on the toolbar reaches the gesture detector")
    uiok(#w.fed == 0 and v.canvas:opCount() == 0, "U1: the pen drew nothing")
end)

uirun("U2", "pen taps the zoom pill", function(w)
    local v = w.view
    local r = v:fabRect("zoom")
    local z0 = v.view.zoom
    tapAt(w, math.floor(r.x + r.w / 2), math.floor(r.y + r.h / 4))
    uiok(v.view.zoom > z0, "U2: the zoom pill zoomed in")
    uiok(v.canvas:opCount() == 0, "U2: nothing drawn")
end)

uirun("U3", "toggle off: the pen on the toolbar stays with Ink Away", function(w)
    local v = w.view
    tapAt(w, 300, math.floor(v.view.area_y / 2))
    uiok(#w.ges_log == 0, "U3: the gesture detector saw nothing from the pen")
    uiok(v.canvas:opCount() == 0, "U3: nothing drawn")
end, { pen_ui = false })

uirun("U4", "a stroke that starts on the canvas carries on over the toolbar", function(w)
    local v = w.view
    local ay = v.view.area_y
    pen.enter(w, 300, ay + 60, 60)
    pen.touch(w, 300, ay + 60, 7)
    for i = 1, 12 do pen.move(w, 300 + i * 4, ay + 60 - i * 8, 7) end
    pen.lift(w, 7)
    pen.leave(w, 30)
    uiok(#w.ges_log == 0, "U4: the gesture detector saw nothing")
    uiok(v.canvas:opCount() == 1 and #w.fed == 14, "U4: one stroke from every touching frame")
end)

uirun("U5", "a palm (finger tool) rests on the canvas while the pen taps the toolbar", function(w)
    local v = w.view
    local y = math.floor(v.view.area_y / 2)
    pen.enter(w, 300, y - 4, 60)
    panel.down(w, 0, 501, 500, 900, 0, 3)
    panel.move(w, { { 0, 506, 904 } }, 8)
    pen.touch(w, 300, y, 7)
    panel.move(w, { { 0, 512, 908 } }, 4)
    pen.move(w, 300, y, 4)
    pen.lift(w, 7)
    panel.move(w, { { 0, 518, 912 } }, 8)
    panel.up(w, 0, 8)
    pen.leave(w, 30)
    local taps = gestures(w, "tap")
    uiok(#taps == 1 and taps[1].y == y, "U5: the pen's tap reaches the detector")
    uiok(v.canvas:opCount() == 0 and not v.capturing, "U5: the palm drew nothing")
    -- the pen draws as usual afterwards
    local ay = v.view.area_y
    pen.enter(w, 300, ay + 300, 400)
    pen.touch(w, 300, ay + 300, 7)
    for i = 1, 6 do pen.move(w, 300 + i * 6, ay + 300 + i * 3, 7) end
    pen.lift(w, 7)
    pen.leave(w, 30)
    uiok(v.canvas:opCount() == 1, "U5: a later pen stroke draws")
end)

uirun("U6", "pen lifts and leaves in one frame on the toolbar", function(w)
    local v = w.view
    local y = math.floor(v.view.area_y / 2)
    pen.enter(w, 200, y, 60)
    pen.touch(w, 200, y, 7)
    pen.liftLeave(w, 7)
    uiok(#gestures(w, "tap") == 1, "U6: the tap still reaches the detector")
end)

uirun("U7", "pen leaves range before its lift on the toolbar (tool key first)", function(w)
    local v = w.view
    local y = math.floor(v.view.area_y / 2)
    pen.enter(w, 200, y, 60)
    pen.touch(w, 200, y, 7)
    pen.leaveLift(w, 7)
    uiok(#gestures(w, "tap") == 1, "U7: the contact ends as a tap")
    -- and the next stroke on the canvas draws
    local ay = v.view.area_y
    pen.enter(w, 300, ay + 300, 400)
    pen.touch(w, 300, ay + 300, 7)
    for i = 1, 6 do pen.move(w, 300 + i * 6, ay + 300 + i * 3, 7) end
    pen.lift(w, 7)
    pen.leave(w, 30)
    uiok(v.canvas:opCount() == 1, "U7: the next stroke draws")
end)

uirun("U8", "a menu is open: the pen works it, and draws again once it closes", function(w)
    local v = w.view
    local UI = H.UIManager
    local menu = { name = "menu" }
    UI._window_stack[#UI._window_stack + 1] = { widget = v }
    UI._window_stack[#UI._window_stack + 1] = { widget = menu }
    local ay = v.view.area_y
    pen.enter(w, 300, ay + 300, 60)
    pen.touch(w, 300, ay + 300, 7)
    for i = 1, 6 do pen.move(w, 300 + i * 6, ay + 300 + i * 3, 7) end
    pen.lift(w, 7)
    pen.leave(w, 30)
    uiok(#gestures(w, "touch") == 1 and #w.fed == 0, "U8: with a menu up the pen goes to the gesture detector")
    uiok(v.canvas:opCount() == 0, "U8: nothing drawn under the menu")
    UI._window_stack[#UI._window_stack] = nil
    pen.enter(w, 300, ay + 300, 400)
    pen.touch(w, 300, ay + 300, 7)
    for i = 1, 6 do pen.move(w, 300 + i * 6, ay + 300 + i * 3, 7) end
    pen.lift(w, 7)
    pen.leave(w, 30)
    uiok(v.canvas:opCount() == 1, "U8: once it closes the pen draws")
    UI._window_stack = {}
end)

uirun("U9", "a message that closes by itself does not take the pen", function(w)
    local v = w.view
    local UI = H.UIManager
    UI._window_stack[#UI._window_stack + 1] = { widget = v }
    UI._window_stack[#UI._window_stack + 1] = { widget = { timeout = 2 } }
    local ay = v.view.area_y
    pen.enter(w, 300, ay + 300, 60)
    pen.touch(w, 300, ay + 300, 7)
    for i = 1, 6 do pen.move(w, 300 + i * 6, ay + 300 + i * 3, 7) end
    pen.lift(w, 7)
    pen.leave(w, 30)
    uiok(#w.ges_log == 0 and v.canvas:opCount() == 1, "U9: the pen still draws")
    UI._window_stack = {}
end)

uirun("U10", "pen taps the notebook bar's add-page button", function(w)
    local v = w.view
    v:startNotebook({ style = "lines", size = 40, strength = 45 })
    v:paintTo(require("device").screen.bb, 0, 0)   -- lays out the bar's buttons
    local n0 = #v.notebook.pages
    local r = v._nb_plus
    tapAt(w, math.floor(r.x + r.w / 2), math.floor(r.y + r.h / 2))
    uiok(#v.notebook.pages == n0 + 1, "U10: a page was added")
end)

uirun("U11", "the pen's eraser end on the toolbar works it, and the tool is left alone", function(w)
    local v = w.view
    local y = math.floor(v.view.area_y / 2)
    w.frame(H.PEN_FD, { { K, C.BTN_TOOL_RUBBER, 1 }, { A, C.ABS_X, 300 }, { A, C.ABS_Y, y } }, 60, "rubber-enter", "hover")
    w.frame(H.PEN_FD, { { K, C.BTN_TOUCH, 1 }, { A, C.ABS_X, 300 }, { A, C.ABS_Y, y }, { A, C.ABS_PRESSURE, 900 } }, 7, "rubber-touch", "touch")
    pen.lift(w, 7)
    pen.leave(w, 30)
    uiok(#gestures(w, "tap") == 1, "U11: the tap reaches the detector")
    uiok(v.tool == "pen", "U11: the tool is still the pen")
end)

uirun("U12", "keyboard up: the pen's taps on the canvas get through, a palm's do not", function(w)
    local v = w.view
    local UI = H.UIManager
    UI._window_stack[#UI._window_stack + 1] = { widget = v }
    UI._window_stack[#UI._window_stack + 1] = { widget = { name = "keyboard" } }
    v.is_always_active = true   -- as while typing (showTextKeyboard)
    local pen_seen, palm_seen = {}, {}
    local fr = v.fingerRejected
    v.fingerRejected = function(self, pos)
        local r = fr(self, pos)
        if pos then
            local list = (pos.x < 400) and pen_seen or palm_seen
            list[#list + 1] = r
        end
        return r
    end
    local ay = v.view.area_y
    pen.enter(w, 300, ay + 200, 60)
    panel.down(w, 0, 601, 600, 900, 0, 3)
    pen.touch(w, 300, ay + 200, 7)
    pen.move(w, 300, ay + 200, 7)
    pen.lift(w, 7)
    panel.up(w, 0, 8)
    pen.leave(w, 30)
    local all_false = #pen_seen > 0
    for _, r in ipairs(pen_seen) do if r then all_false = false end end
    local all_true = #palm_seen > 0
    for _, r in ipairs(palm_seen) do if not r then all_true = false end end
    uiok(all_false, "U12: the pen's touch and tap reach the canvas")
    uiok(all_true, "U12: the palm is still rejected")
    v.fingerRejected = nil
    v.is_always_active = false
    UI._window_stack = {}
end)

-- A pen contact that lands on a floating button is a tap only if it stays within
-- the tap slop (8 dp, about 1.3 mm) and lifts within half a second; one that
-- moves further is a stroke from where it landed, and never presses the button.
local function onPill(v)
    local r = v:fabRect("zoom")
    return math.floor(r.x + r.w / 2), math.floor(r.y + r.h / 4)   -- the zoom-in half
end
uirun("U13", "a stroke that starts on the zoom pill draws from where it landed", function(w)
    local v = w.view
    local x, y = onPill(v)
    local z0 = v.view.zoom
    pen.enter(w, x, y, 60); pen.touch(w, x, y, 7)
    for i = 1, 16 do pen.move(w, x - i * 10, y - i * 3, 7) end
    pen.lift(w, 7); pen.leave(w, 30)
    local op = v.canvas.ops[1]
    local cx, cy = v:toCanvasClamped(x, y)
    uiok(v.view.zoom == z0, "U13: the zoom stays")
    uiok(v.canvas:opCount() == 1 and op.pts[1] == cx and op.pts[2] == cy,
        "U13: one stroke, starting where the pen landed on the pill")
    uiok(#w.ges_log == 0, "U13: the gesture detector saw nothing")
end)
uirun("U14", "a tap that skids within the slop zooms; just past it draws", function(w)
    local v = w.view
    local x, y = onPill(v)
    local slop = v:penTapSlop()
    local z0 = v.view.zoom
    local d = math.floor(slop * 0.6)
    pen.enter(w, x, y, 60); pen.touch(w, x, y, 7)
    pen.move(w, x + d, y, 7); pen.move(w, x, y + d, 7)
    pen.lift(w, 7); pen.leave(w, 30)
    local z1 = v.view.zoom
    uiok(z1 > z0 and v.canvas:opCount() == 0, ("U14: a skid of %d px of %d is still a tap"):format(d, slop))
    H.tick(w, 1000)
    local x2, y2 = onPill(v)
    local e = math.ceil(slop * 1.6)
    pen.enter(w, x2, y2, 60); pen.touch(w, x2, y2, 7)
    pen.move(w, x2 - e, y2, 7); pen.move(w, x2 - 2 * e, y2, 7)
    pen.lift(w, 7); pen.leave(w, 30)
    uiok(v.view.zoom == z1 and v.canvas:opCount() == 1, ("U14: %d px is a stroke, no zoom"):format(e))
end)
uirun("U15", "the pen held still on the pill for 0.8 s does nothing", function(w)
    local v = w.view
    local x, y = onPill(v)
    local z0 = v.view.zoom
    pen.enter(w, x, y, 60); pen.touch(w, x, y, 7)
    for _ = 1, 8 do pen.move(w, x, y, 100) end
    pen.lift(w, 7); pen.leave(w, 30)
    uiok(v.view.zoom == z0 and v.canvas:opCount() == 0, "U15: no zoom, no ink")
end)
uirun("U16", "a stroke that starts on the toolbar chevron draws; the toolbar stays", function(w)
    local v = w.view
    local r = v:fabRect("bar")
    local x, y = math.floor(r.x + r.w / 2), math.floor(r.y + r.h / 2)
    pen.enter(w, x, y, 60); pen.touch(w, x, y, 7)
    for i = 1, 12 do pen.move(w, x - i * 8, y + i * 8, 7) end
    pen.lift(w, 7); pen.leave(w, 30)
    uiok(not v._toolbar_hidden and v.canvas:opCount() == 1, "U16: drawn, toolbar unchanged")
end)
uirun("U17", "a palm rests while the pen taps the pill; leaving range counts as the lift", function(w)
    local v = w.view
    local x, y = onPill(v)
    local z0 = v.view.zoom
    panel.down(w, 0, 801, 600, 900, 0, 50)
    pen.enter(w, x, y, 20); pen.touch(w, x, y, 7)
    panel.move(w, { { 0, 606, 904 } }, 4)
    pen.leaveLift(w, 7)
    panel.move(w, { { 0, 612, 910 } }, 8)
    panel.up(w, 0, 8)
    uiok(v.view.zoom > z0 and v.canvas:opCount() == 0, "U17: zoomed, nothing drawn")
end)
uirun("U18", "with a menu up, the pen on the pill goes to the menu's world as before", function(w)
    local v = w.view
    local UI = H.UIManager
    UI._window_stack[#UI._window_stack + 1] = { widget = v }
    UI._window_stack[#UI._window_stack + 1] = { widget = { name = "menu" } }
    local x, y = onPill(v)
    tapAt(w, x, y)
    uiok(#gestures(w, "touch") == 1 and #w.fed == 0 and v.canvas:opCount() == 0, "U18: the gesture path, nothing drawn")
    UI._window_stack = {}
end)

-- The side button through KOReader's real input: on a Kindle Scribe it is
-- BTN_STYLUS, which KOReader keeps as its "eraser" latch and relabels the pen's
-- tool while held. By default it highlights while held (B0); set to Lasso the
-- stroke selects instead of inking (B1). Either way the pen goes back to its
-- tool and pen at the lift.
if not ONLY or ONLY == "B0" then
    local w = H.newWorld({})
    local v = w.view
    local ax, ay = strokeA(w, 6)
    pen.lift(w, 7); pen.leave(w, 40)
    H.UIManager.fireScheduled()
    local n0 = v.canvas:opCount()
    local style0 = v.pen_style
    pen.enter(w, AX0, AY0 + 200, 300)
    w.frame(10, { { K, 331, 1 } }, 5, "button-down", "hover")
    pen.touch(w, AX0, AY0 + 200, 7)
    local style_during = v.pen_style
    for i = 1, 10 do pen.move(w, AX0 + i * 20, AY0 + 200, 7) end
    pen.lift(w, 7)
    w.frame(10, { { K, 331, 0 } }, 5, "button-up", "hover")
    pen.leave(w, 40)
    H.UIManager.fireScheduled()
    uiok(style_during == "highlighter", "B0: Kindle side button held: the pen highlights (" .. tostring(style_during) .. ")")
    uiok(v.canvas:opCount() == n0 + 1 and v.canvas.ops[#v.canvas.ops].style == "highlighter",
        "B0: one highlighter stroke is drawn")
    uiok(v.pen_style == style0 and v.tool == "pen", "B0: the pen is back as it was after the lift")
end
if not ONLY or ONLY == "B1" then
    local w = H.newWorld({})
    local v = w.view
    v:gestureBindings().pen_side = "lasso"
    local ax, ay = strokeA(w, 6)
    pen.lift(w, 7); pen.leave(w, 40)
    H.UIManager.fireScheduled()
    local n0 = v.canvas:opCount()
    pen.enter(w, AX0 - 40, AY0 - 40, 300)
    w.frame(10, { { K, 331, 1 } }, 5, "button-down", "hover")
    pen.touch(w, AX0 - 40, AY0 - 40, 7)
    local tool_during = v.tool
    for i = 1, 10 do pen.move(w, AX0 - 40 + i * 20, AY0 - 40 + (i % 2) * 90, 7) end
    pen.move(w, AX0 - 40, AY0 + 80, 7)
    pen.lift(w, 7)
    w.frame(10, { { K, 331, 0 } }, 5, "button-up", "hover")
    pen.leave(w, 40)
    H.UIManager.fireScheduled()
    uiok(tool_during == "lasso", "B1: Kindle side button held: the pen lassoes (" .. tostring(tool_during) .. ")")
    uiok(v.canvas:opCount() == n0, "B1: and draws no ink")
    uiok(v.tool == "pen", "B1: the pen is back to its tool after the lift")
end

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
for _, c in ipairs(uichecks) do ok(c[1], c[2]) end
print(("scribe: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
