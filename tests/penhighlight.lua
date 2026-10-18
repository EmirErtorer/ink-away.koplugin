-- Highlighting while reading with the pen's button (ink/reader/penhighlight.lua),
-- through KOReader's REAL Input and GestureDetector (tests/scribe/harness.lua):
-- on a Kobo pen (side button BTN_STYLUS2, eraser end BTN_STYLUS) and a Kindle
-- Scribe pen (side buttons BTN_STYLUS and BTN_STYLUS2, rear eraser a tool of its
-- own), a stroke with the Highlighter's button held is taken and made a
-- highlight; every other frame goes on (to the callback that had the pen
-- before, and to KOReader as a touch); and the pen goes back as it detaches.
--   luajit tests/penhighlight.lua      (KO_SRC: a KOReader checkout, see tests/README.md)
local H = dofile("tests/scribe/harness.lua")
local panel, pen, C = H.panel, H.pen, H.C
local K = C.EV_KEY
local UIManager = H.UIManager
local Actions = require("ink/actions")
local PenHighlight = require("ink/reader/penhighlight")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- A world with the book open and nothing of Ink Away over it: the reader on
-- top, another plugin's callback holding the pen before ours.
local function world(kobo)
    local w = H.newWorld({ kobo = kobo })
    w.view:onCloseWidget()
    w.input.stylus_callback = nil
    UIManager._window_stack = {}
    local ui = { name = "ReaderUI" }
    UIManager:show(ui)
    local book = { ui = ui, made = {} }
    function book:highlight(op) self.made[#self.made + 1] = op; return { text = "words" } end
    local other = { frames = 0 }
    w.input:registerStylusCallback(function() other.frames = other.frames + 1; return false end)
    other.cb = w.input.stylus_callback
    local ph = PenHighlight.new(book, w.input)
    ok(ph:attach(), (kobo and "kobo" or "scribe") .. ": it watches the pen while reading")
    return w, ph, book, other, ui
end

local tid = 300
local function button(w, fd, code, on) w.frame(fd, { { K, code, on and 1 or 0 } }, 5, "button", w.phys) end
local function kStroke(w, y, code)
    if code then button(w, H.PANEL_FD, code, true) end
    tid = tid + 1
    panel.down(w, 0, tid, 150, y, 1, 300)
    for i = 1, 10 do panel.move(w, { { 0, 150 + i * 30, y + (i % 2) } }, 10) end
    panel.up(w, 0, 10)
    if code then button(w, H.PANEL_FD, code, false) end
    H.tick(w, 400)
end
local function sStroke(w, y, code, rubber)
    if code then button(w, H.PEN_FD, code, true) end
    if rubber then
        w.frame(H.PEN_FD, { { K, C.BTN_TOOL_RUBBER, 1 }, { C.EV_ABS, C.ABS_X, 150 }, { C.EV_ABS, C.ABS_Y, y } }, 300, "rubber-enter", "hover")
        w.frame(H.PEN_FD, { { K, C.BTN_TOUCH, 1 }, { C.EV_ABS, C.ABS_X, 150 }, { C.EV_ABS, C.ABS_Y, y }, { C.EV_ABS, C.ABS_PRESSURE, 900 } }, 10, "rubber-touch", "touch")
    else
        pen.enterTouch(w, 150, y, 300)
    end
    for i = 1, 10 do pen.move(w, 150 + i * 30, y, 10) end
    if rubber then
        w.frame(H.PEN_FD, { { K, C.BTN_TOUCH, 0 }, { K, C.BTN_TOOL_RUBBER, 0 }, { C.EV_ABS, C.ABS_PRESSURE, 0 } }, 10, "rubber-out", "idle")
    else
        pen.liftLeave(w, 10)
    end
    if code then button(w, H.PEN_FD, code, false) end
    H.tick(w, 400)
end

for _, kobo in ipairs({ true, false }) do
    local tag = kobo and "kobo" or "scribe"
    local w, ph, book, other, ui = world(kobo)
    local stroke = kobo and kStroke or sStroke
    local SIDE = kobo and C.BTN_STYLUS2 or C.BTN_STYLUS
    -- the pen alone: nothing taken, it goes on to the other plugin and KOReader
    local g0, f0 = #w.gestures, other.frames
    stroke(w, 400)
    ok(#book.made == 0, tag .. ": the pen alone makes no highlight")
    ok(other.frames > f0, tag .. ": its frames go on to what had the pen before")
    ok(#w.gestures > g0, tag .. ": and on to KOReader as a touch (page turns, selection)")
    -- the side button held: one highlight, and nothing reaches KOReader
    g0, f0 = #w.gestures, other.frames
    stroke(w, 600, SIDE)
    ok(#book.made == 1, tag .. ": with the side button held the stroke becomes a highlight (" .. #book.made .. ")")
    local op = book.made[1]
    ok(op and op.style == "highlighter" and #op.pts >= 8 and (op.width or 0) > 0,
        tag .. ": from the stroke's points, with the highlighter's width")
    local ys = true
    for i = 2, #(op and op.pts or {}), 2 do if math.abs(op.pts[i] - 600) > 4 then ys = false end end
    ok(ys, tag .. ": where the pen went on the screen")
    ok(#w.gestures == g0, tag .. ": KOReader saw none of it (no page turn, no selection)")
    ok(other.frames == f0, tag .. ": nor did the other plugin")
    ok(ph.stroke == nil, tag .. ": the stroke ended at the lift")
    -- the eraser end, set to erase: not a highlight, the frames go on
    g0 = #w.gestures
    if kobo then stroke(w, 800, C.BTN_STYLUS) else stroke(w, 800, nil, true) end
    ok(#book.made == 1 and #w.gestures > g0, tag .. ": the eraser end (set to erase) is left alone while reading")
    -- set to the Highlighter, the eraser end highlights too
    local b = Actions.load(function(k) return G_reader_settings:readSetting(k) end)
    Actions.set(b, "pen_eraser", "highlighter")
    Actions.save(b, function(k, v) G_reader_settings:saveSetting(k, v) end)
    if kobo then stroke(w, 800, C.BTN_STYLUS) else stroke(w, 800, nil, true) end
    ok(#book.made == 2, tag .. ": set to the Highlighter, the eraser end highlights")
    Actions.reset(b); Actions.save(b, function(k, v) G_reader_settings:saveSetting(k, v) end)
    -- (Kobo) a palm the panel numbers as the eraser, on another slot while the
    -- eraser end is held, starts nothing once the pen's slot is known
    if kobo then
        local n0 = #book.made
        Actions.set(b, "pen_eraser", "highlighter")
        Actions.save(b, function(k, v) G_reader_settings:saveSetting(k, v) end)
        button(w, H.PANEL_FD, C.BTN_STYLUS, true)
        tid = tid + 1
        panel.down(w, 3, tid, 500, 900, 2, 300)
        for i = 1, 6 do panel.move(w, { { 3, 500 + i * 10, 900 } }, 10) end
        panel.up(w, 3, 10)
        button(w, H.PANEL_FD, C.BTN_STYLUS, false)
        H.tick(w, 400)
        ok(#book.made == n0 and ph.stroke == nil, tag .. ": a palm numbered as the eraser starts no highlight")
        Actions.reset(b); Actions.save(b, function(k, v) G_reader_settings:saveSetting(k, v) end)
    end
    -- with a menu over the page the button does nothing of ours
    local menu = { name = "menu" }
    UIManager:show(menu)
    stroke(w, 600, SIDE)
    ok(#book.made == 2, tag .. ": with a menu over the page nothing is highlighted")
    UIManager:close(menu)
    -- turned off: detached, the pen back with the other plugin
    ph:detach()
    ok(w.input.stylus_callback == other.cb, tag .. ": detached, the pen is back with what had it")
    stroke(w, 600, SIDE)
    ok(#book.made == 2, tag .. ": and the button highlights nothing")
    -- attached again; a plugin that takes the pen since keeps it at the detach
    ok(ph:attach() and w.input.stylus_callback == ph.cb, tag .. ": attached again")
    local later = function() return false end
    w.input:registerStylusCallback(later)
    ph:detach()
    ok(w.input.stylus_callback == later, tag .. ": a callback registered since is left in place")
    -- off in the settings: it does not attach at all
    PenHighlight.setEnabled(false)
    ok(not PenHighlight.new(book, w.input):attach(), tag .. ": turned off, it does not watch the pen")
    PenHighlight.setEnabled(true)
end

print(("penhighlight: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
