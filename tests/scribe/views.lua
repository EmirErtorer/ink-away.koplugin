-- Two Ink Away views open at once on KOReader's REAL input (a Kindle Scribe):
-- a book's notes over its annotation, or the canvas over a book. KOReader keeps
-- one stylus callback, and the pen bridge (ink/penbridge.lua) installs once on
-- the input. Closing either view leaves the other one its pen, palm rejection
-- and bridge, and a pen stroke then draws in it (#27, #38).
--   luajit tests/scribe/views.lua      (KO_SRC: a KOReader checkout, see tests/README.md)
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
_G.G_reader_settings = {
    data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function() return false end, isFalse = function() return false end,
    nilOrTrue = function() return true end, nilOrFalse = function() return true end,
}
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
local ffi = require("ffi")
require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

-- KOReader's real input.lua, loaded privately (as tests/scribe/harness.lua does)
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

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

Screen:setSize(1072, 1448); Screen:setRotationMode(0)
local kscreen = setmetatable({ scaleByDPI = function(_, px) return px end,
    getTouchRotation = function() return 0 end, getRotationMode = function() return 0 end }, { __index = Screen })
local fakeDevice = { screen = kscreen, isSDL = function() return false end, isAndroid = function() return false end,
    isPocketBook = function() return false end, isRemarkable = function() return false end }
local input = Input:new{ device = fakeDevice, input = {}, event_map = {}, group = { Back = {} } }
input.wacom_protocol = true                    -- KindleScribe:init
input.pen_slot = input.pen_slot or 4
local mock_input = Device.input
Device.input = input
UIManager.reset()
local InkAwayView = dofile("ink/view.lua")
local T = 1000.0
local function frame(evs, dt)
    T = T + (dt or 8) / 1000
    local sec = math.floor(T)
    local usec = math.floor((T - sec) * 1e6 + 0.5)
    evs[#evs + 1] = { C.EV_SYN, C.SYN_REPORT, 0 }
    for _, e in ipairs(evs) do
        local ev = { type = e[1], code = e[2], value = e[3], time = { sec = sec, usec = usec }, fd = 10 }
        input:eventAdjustHook(ev)
        if ev.type == C.EV_KEY then input:handleKeyBoardEv(ev) else input:handleTouchEv(ev) end
    end
end
local K, A = C.EV_KEY, C.EV_ABS
-- a pen stroke on the Wacom digitizer, as the Scribe reports it
local function penStroke(x0, y0)
    frame({ { K, C.BTN_TOOL_PEN, 1 }, { A, C.ABS_X, x0 }, { A, C.ABS_Y, y0 } })
    frame({ { K, C.BTN_TOUCH, 1 }, { A, C.ABS_X, x0 }, { A, C.ABS_Y, y0 }, { A, C.ABS_PRESSURE, 900 } })
    for i = 1, 12 do frame({ { A, C.ABS_X, x0 + i * 15 }, { A, C.ABS_Y, y0 + i * 4 }, { A, C.ABS_PRESSURE, 1000 } }) end
    frame({ { K, C.BTN_TOUCH, 0 }, { A, C.ABS_PRESSURE, 0 } })
    frame({ { K, C.BTN_TOOL_PEN, 0 } }, 30)
    UIManager.fireScheduled()
end
local function open()
    local v = InkAwayView:new{}
    v.palm_reject = true
    v:applyPalmReject()
    v.nowMs = function() return T * 1000 end
    v:setTool("pen")
    UIManager:show(v)
    return v
end
local function bridged() return rawget(input, "handleTouchEv") ~= nil and input.pen_slot == 15 end

-- the book's annotation (a), its notes over it (b), the notes closed
local a = open()
ok(input.stylus_callback == a._stylus_cb and bridged(), "the annotation holds the pen, bridged")
local b = open()
ok(input.stylus_callback == b._stylus_cb and bridged(), "the notes over it hold the pen, on the same bridge")
UIManager:close(b)
ok(input.stylus_callback == a._stylus_cb, "notes closed: the annotation has the pen again")
ok(bridged(), "notes closed: the bridge stays for the annotation")
local n0 = a.canvas:opCount()
penStroke(300, 500)
ok(a.canvas:opCount() == n0 + 1, ("notes closed: a pen stroke draws on the annotation (%d strokes)"):format(a.canvas:opCount() - n0))
UIManager:close(a)
ok(input.stylus_callback == nil and not bridged() and input.pen_slot == 4,
    "the annotation closed: no callback, the bridge gone, the pen slot as KOReader had it")

-- the one underneath closes first (the book closes with the canvas open over it)
a = open(); b = open()
UIManager:close(a)
ok(input.stylus_callback == b._stylus_cb and bridged(), "underneath closed: the one on top keeps its pen and bridge")
n0 = b.canvas:opCount()
penStroke(300, 700)
ok(b.canvas:opCount() == n0 + 1, "underneath closed: a pen stroke draws on the one on top")
UIManager:close(b)
ok(input.stylus_callback == nil and not bridged(), "both closed: nothing left on the input")

Device.input = mock_input
print(("scribe views: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
