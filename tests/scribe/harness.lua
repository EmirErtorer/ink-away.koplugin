-- Kindle Scribe gen 1 pen/palm reproduction harness (v2).
--
-- Wires KOReader's REAL frontend/device/input.lua (handleKeyBoardEv wacom branch,
-- handleTouchEv, routeStylusEvents, setupSlotData/newFrame) and REAL
-- frontend/device/gesturedetector.lua to Ink Away's REAL ink/view.lua (under the
-- repo's mock KOReader env), and feeds synthetic evdev frames from TWO devices
-- (Wacom digitizer fd 10 + capacitive panel fd 11) into ONE Input, the way
-- libkoreader-input delivers them (whole frames, one fd per read batch:
-- base/input/input.c waitForInput) and the way Input:waitEvent dispatches them
-- (eventAdjustHook, then handleKeyBoardEv / handleTouchEv per event).
--
-- Driven by tests/scribe/replay.lua. ink/penbridge.lua is installed on the real
-- Input exactly as applyPalmReject does on a device (NOBRIDGE=1 to leave it off).

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
-- KOReader source checkout with the emulator built in it (KO_SRC overrides)
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
local VERBOSE = os.getenv("V") == "1"

_G.G_reader_settings = {
    data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function() return false end, isFalse = function() return false end,
    nilOrTrue = function() return true end, nilOrFalse = function() return true end,
}
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
local ffi = require("ffi")
require("ffi/blitbuffer")                 -- the repo mock
local Device = require("device")          -- the repo mock
local UIManager = require("ui/uimanager") -- the repo mock
local Screen = Device.screen

-- Private loader for KOReader's real modules (kept out of package.loaded).
local noop = function() end
local stubs = {
    logger = { dbg = noop, info = noop, warn = noop, err = noop },
    dbg = { is_on = false, guard = function() end },
    datastorage = { getSettingsDir = function() return "/nonexistent_ko_settings" end },
    gettext = setmetatable({}, { __call = function(_, s) return s end }),
    ["ffi/framebuffer"] = { DEVICE_ROTATED_UPRIGHT = 0, DEVICE_ROTATED_CLOCKWISE = 1,
        DEVICE_ROTATED_UPSIDE_DOWN = 2, DEVICE_ROTATED_COUNTER_CLOCKWISE = 3 },
    ["device/key"] = { new = function() return {} end },
    util = { tableDeepCopy = function(t)
        local function cp(o) if type(o) ~= "table" then return o end
            local r = {} for k, v in pairs(o) do r[k] = cp(v) end return r end
        return cp(t) end },
}
local kcache = {}
local function kreq(name)
    if kcache[name] ~= nil then return kcache[name] end
    if name == "ffi" or name == "bit" or name == "jit" then return require(name) end
    if stubs[name] then kcache[name] = stubs[name]; return stubs[name] end
    for _, root in ipairs({ KO .. "/frontend/", KO .. "/base/" }) do
        local path = root .. name .. ".lua"
        local f = io.open(path)
        if f then
            f:close()
            local chunk = assert(loadfile(path))
            setfenv(chunk, setmetatable({ require = kreq }, { __index = _G }))
            local r = chunk(name)
            if r == nil then r = true end
            kcache[name] = r
            return r
        end
    end
    error("kreq: not found " .. name)
end
local C = ffi.C
local Input = kreq("device/input")

local use_bridge = io.open("ink/penbridge.lua") ~= nil and os.getenv("NOBRIDGE") == nil
local PenBridge = use_bridge and require("ink/penbridge") or nil

local W, H = 1072, 1448
Screen:setSize(W, H)
Screen:setRotationMode(0)

local PEN_FD, PANEL_FD = 10, 11

-- Time-aware timers: the repo mock only fires timers on demand; here a timer
-- fires when the simulated clock passes its deadline (checked before each frame),
-- like UIManager running due tasks between input batches.
local CLOCK = { T = 1000.0 }
local deadlines = {}
UIManager.scheduleIn = function(_, sec, fn) UIManager.scheduled[fn] = true; deadlines[fn] = CLOCK.T + (sec or 0) end
UIManager.nextTick = function(_, fn) UIManager.scheduled[fn] = true; deadlines[fn] = CLOCK.T end
UIManager.unschedule = function(_, fn) UIManager.scheduled[fn] = nil; deadlines[fn] = nil end
local function tick()
    local due = {}
    for fn in pairs(UIManager.scheduled) do if (deadlines[fn] or 0) <= CLOCK.T then due[#due + 1] = fn end end
    table.sort(due, function(a, b) return (deadlines[a] or 0) < (deadlines[b] or 0) end)
    for _, fn in ipairs(due) do
        if UIManager.scheduled[fn] then UIManager.scheduled[fn] = nil; deadlines[fn] = nil; fn() end
    end
end

local function newWorld(opts)
    opts = opts or {}
    UIManager.reset()
    CLOCK.T = 1000.0
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view.palm_reject = true
    if opts.pen_ui ~= nil then view.pen_ui = opts.pen_ui end
    view:applyPalmReject()
    view:setTool(opts.tool or "pen")

    local kscreen = setmetatable({ scaleByDPI = function(_, px) return px end,
        getTouchRotation = function() return 0 end, getRotationMode = function() return 0 end },
        { __index = Screen })
    local fakeDevice = { screen = kscreen,
        isSDL = function() return false end, isAndroid = function() return false end,
        isPocketBook = function() return false end, isRemarkable = function() return false end }
    local input = Input:new{ device = fakeDevice, input = {}, event_map = {}, group = { Back = {} } }
    input.wacom_protocol = true                    -- KindleScribe:init (kindle/device.lua:1896)
    input:registerStylusCallback(view._stylus_cb)  -- the real Input calls cb(input, slot)
    if PenBridge and not opts.no_bridge then
        assert(PenBridge.install(input), "penbridge refused")
    end

    local w = { view = view, input = input, log = {}, T = CLOCK.T, panel_last_slot = nil,
                panel_tool = {}, fed = {}, gestures = {}, phys = "idle",
                touch_frames = 0, hover_fed = 0, panel_fed = 0, stylus_frames = {}, ges_log = {} }
    local log = w.log

    local cb = input.stylus_callback
    input.stylus_callback = function(inp, slot)
        local r = cb(inp, slot)
        w.stylus_frames[#w.stylus_frames + 1] = { tool = slot.tool, slot = slot.slot, id = slot.id, r = r }
        log[#log + 1] = string.format("  cb slot=%s tool=%s id=%s x=%s y=%s -> %s  [down=%s started=%s rejF=%s]",
            tostring(slot.slot), tostring(slot.tool), tostring(slot.id), tostring(slot.x), tostring(slot.y),
            tostring(r), tostring(view._pen_state.down), tostring(view._pen_started), tostring(view:fingerRejected()))
        return r
    end
    local feedPen = view.feedPen
    view.feedPen = function(self, kind, x, y)
        log[#log + 1] = string.format("  feedPen %s (%d,%d)  [physical: %s]", kind, x, y, w.phys)
        w.fed[#w.fed + 1] = { kind, x, y, w.phys }
        if kind ~= "up" and w.phys == "hover" then w.hover_fed = w.hover_fed + 1 end
        if kind ~= "up" and w.phys == "panel" then w.panel_fed = w.panel_fed + 1 end
        return feedPen(self, kind, x, y)
    end

    local map = { touch = "onIaTouch", pan = "onIaPan", hold_pan = "onIaHoldPan",
        pan_release = "onIaPanRelease", hold_release = "onIaHoldRel", swipe = "onIaSwipe",
        tap = "onIaTap", hold = "onIaHold", two_finger_pan = "onIaTwoPan",
        two_finger_pan_release = "onIaTwoPanRel", two_finger_tap = "onIaTwoTap",
        two_finger_swipe = "onIaTwoSwipe", pinch = "onIaPinch", spread = "onIaSpread" }
    -- Gestures reach the view unless another widget is on top and the view is not
    -- is_always_active (UIManager:sendEvent); those are logged as taken by "menu".
    local function viewGets()
        local st = UIManager._window_stack
        local top = st[#st] and st[#st].widget
        return top == nil or top == view or view.is_always_active
    end
    local function dispatch(evs)
        for _, e in ipairs(evs or {}) do
            local ges = e.args and e.args[1]
            if ges then
                local h = map[ges.ges]
                local r = "menu"
                if viewGets() then r = h and view[h] and view[h](view, nil, ges) end
                w.gestures[#w.gestures + 1] = ges.ges
                w.ges_log[#w.ges_log + 1] = { ges = ges.ges, x = ges.pos and ges.pos.x,
                    y = ges.pos and ges.pos.y, r = r }
                log[#log + 1] = string.format("  GESTURE %s (%s,%s) -> %s %s", ges.ges,
                    tostring(ges.pos and ges.pos.x), tostring(ges.pos and ges.pos.y), tostring(h), tostring(r))
            end
        end
    end

    -- One evdev frame from one device, terminated by SYN_REPORT, dispatched like
    -- Input:waitEvent: eventAdjustHook, then the key / touch handler.
    function w.frame(fd, evs, dt_ms, tag, phys)
        w.T = w.T + (dt_ms or 7) / 1000
        CLOCK.T = w.T
        tick()
        w.phys = phys or w.phys
        if phys == "touch" then w.touch_frames = w.touch_frames + 1 end
        local sec = math.floor(w.T)
        local usec = math.floor((w.T - sec) * 1e6 + 0.5)
        evs[#evs + 1] = { C.EV_SYN, C.SYN_REPORT, 0 }
        log[#log + 1] = string.format("FRAME fd=%d %-22s cur_slot(before)=%s", fd, tag or "", tostring(input.cur_slot))
        for _, e in ipairs(evs) do
            local ev = { type = e[1], code = e[2], value = e[3], time = { sec = sec, usec = usec }, fd = fd }
            input:eventAdjustHook(ev)
            if ev.type == C.EV_KEY then
                input:handleKeyBoardEv(ev)
            elseif ev.type == C.EV_ABS or ev.type == C.EV_SYN then
                dispatch(input:handleTouchEv(ev))
            end
        end
    end
    return w
end

---------------------------------------------------------------------------
-- Device vocabularies
---------------------------------------------------------------------------
local K, A = C.EV_KEY, C.EV_ABS
-- Wacom digitizer, wacom_i2c style; the input core drops unchanged key/abs values,
-- so mid-stroke frames carry only ABS_X/ABS_Y/ABS_PRESSURE.
local pen = {}
function pen.enter(w, x, y, dt) w.frame(PEN_FD, { {K, C.BTN_TOOL_PEN, 1}, {A, C.ABS_X, x}, {A, C.ABS_Y, y} }, dt, "pen-enter", "hover") end
function pen.hover(w, x, y, dt) w.frame(PEN_FD, { {A, C.ABS_X, x}, {A, C.ABS_Y, y} }, dt, "pen-hover", "hover") end
function pen.touch(w, x, y, dt) w.frame(PEN_FD, { {K, C.BTN_TOUCH, 1}, {A, C.ABS_X, x}, {A, C.ABS_Y, y}, {A, C.ABS_PRESSURE, 900} }, dt, "pen-touch", "touch") end
function pen.move(w, x, y, dt) w.frame(PEN_FD, { {A, C.ABS_X, x}, {A, C.ABS_Y, y}, {A, C.ABS_PRESSURE, 1000 + (math.floor(w.T * 1000) % 7)} }, dt, "pen-move", "touch") end
function pen.lift(w, dt) w.frame(PEN_FD, { {K, C.BTN_TOUCH, 0}, {A, C.ABS_PRESSURE, 0} }, dt, "pen-lift", "hover") end
function pen.leave(w, dt) w.frame(PEN_FD, { {K, C.BTN_TOOL_PEN, 0} }, dt, "pen-leave", "idle") end
-- lift and out-of-range in ONE frame, wacom_i2c report order (BTN_TOUCH first)
function pen.liftLeave(w, dt) w.frame(PEN_FD, { {K, C.BTN_TOUCH, 0}, {K, C.BTN_TOOL_PEN, 0}, {A, C.ABS_PRESSURE, 0} }, dt, "pen-lift+leave", "idle") end
-- same, tool key first
function pen.leaveLift(w, dt) w.frame(PEN_FD, { {K, C.BTN_TOOL_PEN, 0}, {K, C.BTN_TOUCH, 0}, {A, C.ABS_PRESSURE, 0} }, dt, "pen-leave+lift", "idle") end
-- enter range and touch in one frame, tool key first / touch key first
function pen.enterTouch(w, x, y, dt) w.frame(PEN_FD, { {K, C.BTN_TOOL_PEN, 1}, {K, C.BTN_TOUCH, 1}, {A, C.ABS_X, x}, {A, C.ABS_Y, y}, {A, C.ABS_PRESSURE, 900} }, dt, "pen-enter+touch", "touch") end
function pen.touchEnter(w, x, y, dt) w.frame(PEN_FD, { {K, C.BTN_TOUCH, 1}, {K, C.BTN_TOOL_PEN, 1}, {A, C.ABS_X, x}, {A, C.ABS_Y, y}, {A, C.ABS_PRESSURE, 900} }, dt, "pen-touch+enter", "touch") end

-- Capacitive panel, protocol B. The input core emits ABS_MT_SLOT only when the
-- device's slot differs from the last one IT emitted, and drops unchanged
-- per-slot values (TOOL_TYPE re-sent only on change).
local panel = {}
local function pslot(w, evs, s)
    if w.panel_last_slot ~= s then evs[#evs + 1] = { A, C.ABS_MT_SLOT, s }; w.panel_last_slot = s end
end
function panel.down(w, s, tid, x, y, tool, dt)
    local evs = {}
    pslot(w, evs, s)
    evs[#evs + 1] = { A, C.ABS_MT_TRACKING_ID, tid }
    if w.panel_tool[s] ~= (tool or 0) then evs[#evs + 1] = { A, C.ABS_MT_TOOL_TYPE, tool or 0 }; w.panel_tool[s] = tool or 0 end
    evs[#evs + 1] = { A, C.ABS_MT_POSITION_X, x }
    evs[#evs + 1] = { A, C.ABS_MT_POSITION_Y, y }
    local keep = w.phys
    w.frame(PANEL_FD, evs, dt, ("palm-down s%d"):format(s), "panel"); w.phys = keep
end
function panel.move(w, list, dt)   -- list of {s, x, y[, tool]}
    local evs = {}
    for _, p in ipairs(list) do
        pslot(w, evs, p[1])
        if p[4] and w.panel_tool[p[1]] ~= p[4] then evs[#evs + 1] = { A, C.ABS_MT_TOOL_TYPE, p[4] }; w.panel_tool[p[1]] = p[4] end
        evs[#evs + 1] = { A, C.ABS_MT_POSITION_X, p[2] }
        evs[#evs + 1] = { A, C.ABS_MT_POSITION_Y, p[3] }
    end
    local keep = w.phys
    w.frame(PANEL_FD, evs, dt, "palm-move", "panel"); w.phys = keep
end
function panel.up(w, s, dt)
    local evs = {}
    pslot(w, evs, s)
    evs[#evs + 1] = { A, C.ABS_MT_TRACKING_ID, -1 }
    local keep = w.phys
    w.frame(PANEL_FD, evs, dt, ("palm-up s%d"):format(s), "panel"); w.phys = keep
end

---------------------------------------------------------------------------
-- Analysis
---------------------------------------------------------------------------
-- Screen regions used by the scenarios: stroke A lives at y < 500, stroke B at
-- y > 1000, palms at 450<x<700, 650<y<960.
local function region(x, y)
    if y < 500 then return "A" end
    if y > 1000 then return "B" end
    if x > 450 and x < 700 and y > 650 and y < 960 then return "P" end
    return "-"
end

local function analyse(w)
    UIManager.fireScheduled(); UIManager.fireScheduled()
    local v = w.view
    local res = { ops = {}, connects = 0, palm_marks = 0, erase_ops = 0, pen_palm = 0 }
    for i, op in ipairs(v.canvas.ops) do
        local pts = op.pts or {}
        local seen = {}
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for k = 1, #pts - 1, 2 do
            local sx, sy = pts[k] + v.view.area_x, pts[k + 1] + v.view.area_y
            seen[region(sx, sy)] = true
            x0, y0 = math.min(x0, sx), math.min(y0, sy)
            x1, y1 = math.max(x1, sx), math.max(y1, sy)
        end
        local flags = {}
        if seen.A and seen.B then res.connects = res.connects + 1; flags[#flags + 1] = "CONNECTS A-B" end
        if seen.P and not (seen.A and seen.B) then
            if seen.A or seen.B then res.pen_palm = res.pen_palm + 1; flags[#flags + 1] = "PEN<->PALM LINE"
            else res.palm_marks = res.palm_marks + 1; flags[#flags + 1] = "PALM MARK" end
        end
        if op.kind == "erase" then res.erase_ops = res.erase_ops + 1; flags[#flags + 1] = "ERASE" end
        res.ops[#res.ops + 1] = string.format("    op%d %-5s pts=%-3d bbox=(%d,%d)-(%d,%d) %s", i, tostring(op.kind),
            #pts / 2, x0, y0, x1, y1, table.concat(flags, " "))
    end
    -- pen-fed strokes and teleports inside them
    local strokes, cur = {}, nil
    for _, f in ipairs(w.fed) do
        if f[1] == "down" then cur = { f }; strokes[#strokes + 1] = cur
        elseif cur then cur[#cur + 1] = f end
    end
    res.fed_strokes = #strokes
    res.teleports = 0
    for _, s in ipairs(strokes) do
        for k = 2, #s do
            local d = math.sqrt((s[k][2] - s[k - 1][2]) ^ 2 + (s[k][3] - s[k - 1][3]) ^ 2)
            if d > 250 and s[k][1] ~= "up" then res.teleports = res.teleports + 1 end
        end
    end
    local fed_draw = 0
    for _, f in ipairs(w.fed) do if f[1] ~= "up" and f[4] == "touch" then fed_draw = fed_draw + 1 end end
    res.fed_touch, res.touch_frames = fed_draw, w.touch_frames
    res.hover_fed, res.panel_fed = w.hover_fed, w.panel_fed
    res.final_down = v._pen_state.down
    res.final_capturing = v.capturing
    res.final_rejected = v:fingerRejected()
    return res
end

local function report(name, w, extra)
    local r = analyse(w)
    print(("=== %s ==="):format(name))
    if VERBOSE then for _, l in ipairs(w.log) do print(l) end end
    print(("  pen-fed strokes=%d  committed ops=%d  gestures->view: %s"):format(r.fed_strokes, w.view.canvas:opCount(),
        #w.gestures > 0 and table.concat(w.gestures, ",") or "-"))
    print(("  pen ink: %d of %d touching frames drawn; drawn while HOVERING=%d; driven by PANEL frames=%d; teleports>250px=%d")
        :format(r.fed_touch, r.touch_frames, r.hover_fed, r.panel_fed, r.teleports))
    for _, l in ipairs(r.ops) do print(l) end
    if extra then print("  " .. extra) end
    print(("  end state (timers fired): pen down=%s capturing=%s fingerRejected=%s")
        :format(tostring(r.final_down), tostring(r.final_capturing), tostring(r.final_rejected)))
    return r
end

return { tick = function(w, dt_ms) w.T = w.T + dt_ms / 1000; CLOCK.T = w.T; tick() end, newWorld = newWorld, report = report, pen = pen, panel = panel, UIManager = UIManager,
         use_bridge = use_bridge, PenBridge = PenBridge, PEN_FD = PEN_FD, PANEL_FD = PANEL_FD }
