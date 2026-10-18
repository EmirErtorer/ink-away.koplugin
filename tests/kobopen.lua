-- A Kobo pen (the Kobo Stylus 2 on a Libra Colour) through KOReader's REAL
-- Input and GestureDetector (see tests/scribe/harness.lua): its eraser end
-- (BTN_STYLUS) and side button (BTN_STYLUS2) do what Gestures and pen buttons
-- says, with palm rejection off as with it on (#13). With it off the pen still
-- draws through the gesture detector and Ink Away only watches it.
--   luajit tests/kobopen.lua      (KO_SRC: a KOReader checkout, see tests/README.md)
local H = dofile("tests/scribe/harness.lua")
local panel, C = H.panel, H.C
local K = C.EV_KEY

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local tid = 500
local function button(w, code, on) w.frame(H.PANEL_FD, { { K, code, on and 1 or 0 } }, 5, "button", w.phys) end
-- a pen stroke on slot 0 (tool 1, the pen) from (x, y) across
local function stroke(w, x, y, code)
    if code then button(w, code, true) end
    tid = tid + 1
    panel.down(w, 0, tid, x, y, 1, 300)
    for i = 1, 12 do panel.move(w, { { 0, x + i * 20, y + i * 2 } }, 10) end
    panel.up(w, 0, 10)
    if code then button(w, code, false) end
    for _ = 1, 8 do H.tick(w, 100) end   -- (the commit, then the tool put back)
end
local function last(w) local ops = w.view.canvas.ops; return ops[#ops] end

for _, palm in ipairs({ false, true }) do
    local tag = palm and "palm rejection on" or "palm rejection off"
    local w = H.newWorld({ kobo = true, palm = palm })
    local v = w.view
    if not palm then
        -- as on the reader: with palm rejection off the raw finger tracker owns
        -- the first contact, the pen's too (see tests/gestures.lua)
        local Device = require("device")
        Device.input.gesture_detector = w.input.gesture_detector
        v:uninstallRawFinger()
        v:installRawFinger()
    end
    ok(w.input.stylus_callback ~= nil, tag .. ": Ink Away hears the pen")
    -- the pen tip draws with the tool in hand
    stroke(w, 200, 300)
    local n = v.canvas:opCount()
    ok(n == 1 and last(w).kind ~= "erase", tag .. ": the tip draws (" .. n .. " ops)")
    -- the eraser end erases (the default), then the pen draws again
    stroke(w, 200, 300, C.BTN_STYLUS)
    ok(last(w) and last(w).kind == "erase" or v.canvas:opCount() == 0 or (last(w).ebg ~= nil),
        tag .. ": the eraser end erases (" .. tostring(last(w) and last(w).kind) .. ")")
    ok(v.tool == "pen", tag .. ": and the pen is back in hand after it")
    -- the side button highlights (the default)
    stroke(w, 200, 600, C.BTN_STYLUS2)
    ok(last(w) and last(w).style == "highlighter", tag .. ": the side button highlights ("
        .. tostring(last(w) and last(w).style) .. ")")
    ok(v.tool == "pen" and v.pen_style ~= "highlighter", tag .. ": and the pen is back after it")
    -- set to the lasso, the side button selects
    local Actions = require("ink/actions")
    local b = v:gestureBindings()
    Actions.set(b, "pen_side", "lasso")
    v:saveGestures()
    local before = v.canvas:opCount()
    tid = tid + 1
    button(w, C.BTN_STYLUS2, true)
    panel.down(w, 0, tid, 150, 550, 1, 300)
    for i = 1, 24 do
        local a = i / 24 * 2 * math.pi
        panel.move(w, { { 0, math.floor(400 + 260 * math.cos(a)), math.floor(620 + 120 * math.sin(a)) } }, 10)
    end
    panel.up(w, 0, 10)
    button(w, C.BTN_STYLUS2, false)
    for _ = 1, 8 do H.tick(w, 100) end
    ok(v.canvas:opCount() == before and v.selection ~= nil, tag .. ": set to the lasso, the side button selects")
    ok(v.tool == "pen", tag .. ": and the pen is back after it")
    v:clearSelection()
    Actions.reset(b); v:saveGestures()
    -- with a button held on the toolbar, the tool is left as it is
    tid = tid + 1
    button(w, C.BTN_STYLUS, true)
    panel.down(w, 0, tid, 30, 10, 1, 300)
    panel.up(w, 0, 30)
    button(w, C.BTN_STYLUS, false)
    for _ = 1, 8 do H.tick(w, 100) end
    ok(v.tool == "pen", tag .. ": a button held on the toolbar changes no tool")
    -- the pen is given back when Ink Away closes, and nothing is left running
    H.UIManager:close(v)
    v:onCloseWidget()
    H.tick(w, 2000)
    ok(not v._watch_state or not v._watch_state.down, tag .. ": closing leaves no pen held")
end

print(("kobopen: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
