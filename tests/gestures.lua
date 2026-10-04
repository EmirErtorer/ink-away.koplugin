-- Two-finger gestures through KOReader's REAL Input and GestureDetector (see
-- tests/scribe/harness.lua) into Ink Away's real view: a two-finger tap undoes
-- and a two-finger swipe turns a notebook page, on a finger-only reader (where
-- the raw finger tracker owns the first finger) and on a pen device (palm
-- rejection on, fingers navigating). Run from the plugin root:
--   luajit tests/gestures.lua
local H = dofile("tests/scribe/harness.lua")
local panel = H.panel
local Device = require("device")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function has(w, ges)
    for _, g in ipairs(w.gestures) do if g == ges then return true end end
    return false
end

-- A world for a finger-only reader: palm rejection off, the raw finger tracker
-- wrapped around the real detector, as on a Kindle Paperwhite.
local function fingerWorld()
    local w = H.newWorld({})
    local view = w.view
    view.palm_reject = false
    view:applyPalmReject()
    Device.input.gesture_detector = w.input.gesture_detector
    view:uninstallRawFinger()
    view:installRawFinger()
    view:setTool("pen")
    return w
end

local tid = 100
local function nextId() tid = tid + 1; return tid end

-- one finger stroke on slot 0
local function stroke(w, x, y)
    panel.down(w, 0, nextId(), x, y, 0, 300)
    for i = 1, 10 do panel.move(w, { { 0, x + i * 15, y + i * 4 } }, 12) end
    panel.up(w, 0, 12)
    H.tick(w, 400)
end

-- two fingers down within `gap` ms, still, both up quickly
local function twoTap(w, x, y, gap)
    panel.down(w, 0, nextId(), x, y, 0, 400)
    panel.down(w, 1, nextId(), x + 220, y + 10, 0, gap or 30)
    panel.up(w, 0, 90)
    panel.up(w, 1, 15)
    H.tick(w, 400)
end

-- two fingers dragged sideways by dx together, quickly
local function twoSwipe(w, x, y, dx)
    panel.down(w, 0, nextId(), x, y, 0, 400)
    panel.down(w, 1, nextId(), x, y + 250, 0, 20)
    for i = 1, 6 do
        panel.move(w, { { 0, x + dx * i / 6, y + i }, { 1, x + dx * i / 6, y + 250 + i } }, 20)
    end
    panel.up(w, 0, 15)
    panel.up(w, 1, 10)
    H.tick(w, 400)
end

-- 1. Finger-only reader: a stroke, then a two-finger tap takes it back, and the
--    tap itself never drew anything.
do
    local w = fingerWorld()
    local view = w.view
    local ay = view.view.area_y
    stroke(w, 200, ay + 300)
    ok(view.canvas:opCount() == 1, "finger reader: a finger stroke draws")
    w.gestures = {}
    H.UIManager.refreshes = {}
    panel.down(w, 0, nextId(), 400, ay + 600, 0, 400)
    ok(#H.UIManager.refreshes == 0, "finger reader: the first finger of a two-finger tap shows no dot")
    panel.down(w, 1, nextId(), 620, ay + 610, 0, 30)
    panel.up(w, 0, 90)
    panel.up(w, 1, 15)
    H.tick(w, 400)
    ok(has(w, "two_finger_tap"), "finger reader: KOReader sees a two-finger tap (" .. table.concat(w.gestures, ",") .. ")")
    ok(view.canvas:opCount() == 0 and not view.capturing, "finger reader: it undoes the stroke and draws nothing")
    view:redo()
    view._two_tap = nil   -- (the test runs faster than a person: no double tap)
    -- a slower second finger (still well inside KOReader's tap time)
    w.gestures = {}
    twoTap(w, 400, ay + 600, 120)
    ok(has(w, "two_finger_tap") and view.canvas:opCount() == 0,
        "finger reader: a second finger 120 ms later still makes a two-finger tap")

    -- a quick second two-finger tap makes the pair a redo
    view:redo()
    view._two_tap = nil
    twoTap(w, 400, ay + 600)
    ok(view.canvas:opCount() == 0, "finger reader: a two-finger tap undoes")
    twoTap(w, 400, ay + 600)
    ok(view.canvas:opCount() == 1, "finger reader: a second one right after redoes instead")
    view._two_tap = nil
    -- "Nothing to redo." times out on a reader; here it would sit on top
    for i = #H.UIManager._window_stack, 1, -1 do
        local wd = H.UIManager._window_stack[i].widget
        if wd ~= view then H.UIManager:close(wd) end
    end
    -- a long two-finger swipe up opens the Library from a drawing
    local opened
    view.openLibrary = function() opened = "library" end
    view.openOverview = function() opened = "overview" end
    opened = nil
    panel.down(w, 0, nextId(), 400, ay + 1000, 0, 400)
    panel.down(w, 1, nextId(), 650, ay + 1000, 0, 20)
    for i = 1, 6 do panel.move(w, { { 0, 400, ay + 1000 - i * 90 }, { 1, 650, ay + 1000 - i * 90 } }, 20) end
    panel.up(w, 0, 15); panel.up(w, 1, 10)
    H.tick(w, 400)
    ok(opened == "library", "finger reader: a long two-finger swipe up opens the Library from a drawing")

    -- two-finger swipes in a notebook
    view:newNotebook("lines")
    for _ = 1, 3 do view:nbAddPage() end
    view:nbGoTo(2)
    w.gestures = {}
    twoSwipe(w, 800, ay + 400, -500)
    ok(has(w, "two_finger_swipe") and view.notebook.index == 3,
        "finger reader: a two-finger swipe to the left turns to the next page (" .. table.concat(w.gestures, ",") .. ")")
    twoSwipe(w, 300, ay + 400, 500)
    ok(view.notebook.index == 2, "finger reader: to the right goes back")
    opened = nil
    panel.down(w, 0, nextId(), 400, ay + 1000, 0, 400)
    panel.down(w, 1, nextId(), 650, ay + 1000, 0, 20)
    for i = 1, 6 do panel.move(w, { { 0, 400, ay + 1000 - i * 90 }, { 1, 650, ay + 1000 - i * 90 } }, 20) end
    panel.up(w, 0, 15); panel.up(w, 1, 10)
    H.tick(w, 400)
    ok(opened == "overview" and view.notebook.index == 2, "finger reader: in a notebook it opens Browse")
    view:setZoom(2)
    opened = nil
    panel.down(w, 0, nextId(), 400, ay + 1000, 0, 400)
    panel.down(w, 1, nextId(), 650, ay + 1000, 0, 20)
    for i = 1, 6 do panel.move(w, { { 0, 400, ay + 1000 - i * 90 }, { 1, 650, ay + 1000 - i * 90 } }, 20) end
    panel.up(w, 0, 15); panel.up(w, 1, 10)
    H.tick(w, 400)
    ok(opened == nil, "finger reader: zoomed in, a swipe up scrolls instead")
    view:setZoom(view.zoom_min)
    ok(view.canvas:opCount() == 0, "finger reader: and the swipes leave no ink")
    -- a one-finger stroke still draws right after
    stroke(w, 200, ay + 300)
    ok(view.canvas:opCount() == 1, "finger reader: one finger still draws afterwards")
    view:onCloseWidget()
end

-- 2. Pen device: palm rejection on, fingers navigating; the pen is away.
do
    local w = H.newWorld({})
    local view = w.view
    view.finger_mode = "navigate"
    view:newNotebook("lines")
    for _ = 1, 3 do view:nbAddPage() end
    view:nbGoTo(2)
    local ay = view.view.area_y
    view.canvas:addShape("rect", false, { 100, 100, 300, 200 }, 6, 255)
    H.tick(w, 1000)
    w.gestures = {}
    twoTap(w, 400, ay + 600)
    ok(has(w, "two_finger_tap") and view.canvas:opCount() == 0, "pen device: a two-finger tap undoes")
    twoSwipe(w, 800, ay + 400, -500)
    ok(view.notebook.index == 3, "pen device: a two-finger swipe turns the page")
    -- one finger swipes the page too, and draws nothing
    panel.down(w, 0, nextId(), 800, ay + 500, 0, 400)
    for i = 1, 6 do panel.move(w, { { 0, 800 - i * 90, ay + 500 + i } }, 20) end
    panel.up(w, 0, 15)
    H.tick(w, 400)
    ok(view.notebook.index == 4 and view.canvas:opCount() == 0, "pen device: a one-finger swipe turns the page and draws nothing")
    view:onCloseWidget()
end

Device.input.gesture_detector = nil
print(("gestures: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
