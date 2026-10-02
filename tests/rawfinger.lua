-- Raw finger tracking (view.lua installRawFinger/onRawFrame), against a fake
-- GestureDetector that records what reaches it. The real detector emits nothing
-- until a contact has moved PAN_THRESHOLD (5.6 mm), so small letters drawn from
-- gestures became straight lines; these checks pin the raw path that fixes it.
--
-- Run from the plugin root with:  luajit tests/rawfinger.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

_G.G_reader_settings = {
    data = { inkaway_autosave = "off" },
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- Fake detector: a class method feedEvent (so install/uninstall can be checked
-- with rawget), contacts per slot, and a log of every slot it was fed.
local FakeGD = {}
FakeGD.__index = FakeGD
function FakeGD.new() return setmetatable({ contacts = {}, contact_count = 0, fed = {} }, FakeGD) end
function FakeGD:getContact(slot) return self.contacts[slot] end
function FakeGD:feedEvent(tevs)
    for _, tev in ipairs(tevs) do
        self.fed[#self.fed + 1] = { slot = tev.slot, id = tev.id }
        if tev.id and tev.id >= 0 then
            if not self.contacts[tev.slot] then
                self.contacts[tev.slot] = true
                self.contact_count = self.contact_count + 1
            end
        elseif self.contacts[tev.slot] then
            self.contacts[tev.slot] = nil
            self.contact_count = self.contact_count - 1
        end
    end
    return {}
end

-- the real UIManager has this (uimanager.lua:844); the mock does not
function UIManager:getTopmostVisibleWidget()
    local st = self._window_stack
    return st[#st] and st[#st].widget
end

Screen:setSize(1072, 1448)
UIManager.reset()
Device.input.wacom_protocol = false          -- a finger reader: palm rejection defaults off
local saved_pen_slot = Device.input.pen_slot
Device.input.pen_slot = nil
local gd = FakeGD.new()
Device.input.gesture_detector = gd

local InkAwayView = dofile("ink/view.lua")
local view = InkAwayView:new{}
view.tool = "pen"
UIManager:show(view)
local v = view.view
ok(not view.palm_reject, "palm rejection defaults off on a finger reader")
ok(rawget(gd, "feedEvent") ~= nil, "showing the canvas wraps the detector's feedEvent")

-- Input keeps one persistent record per slot and feeds the frame's changed slots.
local slots = {}
local clock = 1700000000 * 1000000          -- fts microseconds, like time.timeval(ev.time)
local function frame(list)
    clock = clock + 10000                    -- 10 ms per frame
    local tevs = {}
    for _, e in ipairs(list) do
        local s = slots[e.slot or 0] or { slot = e.slot or 0 }
        slots[e.slot or 0] = s
        s.id = e.id
        if e.x then s.x, s.y = e.x, e.y end
        s.timev = clock
        tevs[#tevs + 1] = s
    end
    gd:feedEvent(tevs)                        -- what Input:handleTouchEv does per SYN_REPORT
end
local function fedFor(slot)
    local n = 0
    for _, f in ipairs(gd.fed) do if f.slot == slot then n = n + 1 end end
    return n
end

-- 1. A 4 mm lowercase loop (well inside the 66 px pan threshold): every frame draws.
local cx, cy, r = 500, 700, 24
local N = 40
gd.fed = {}
for k = 0, N - 1 do
    local a = 2 * math.pi * k / N
    frame({ { slot = 0, id = 11, x = math.floor(cx + r * math.cos(a) + 0.5),
              y = math.floor(cy + r * math.sin(a) + 0.5) } })
end
local npts = view.canvas.live and #view.canvas.live.pts / 2 or 0
ok(view.capturing, "a contact in the drawing area opens a stroke at once")
ok(npts >= N - 1, ("every frame of a small letter is drawn (%d points for %d frames)"):format(npts, N))
ok(fedFor(0) == 0, "the owned contact never reaches the gesture detector")
frame({ { slot = 0, id = -1 } })
ok(fedFor(0) == 0, "nor does its lift")
ok(view.pending_lift ~= nil, "the lift goes through the normal release (coalesce window)")
UIManager.fireScheduled()
ok(not view.capturing and view.canvas:opCount() == 1, "one lift commits one op")

-- 1b. Two letters written quickly and close together stay two strokes: a real
--     lift (here 100 ms) commits instead of bridging with a straight connector.
local before = view.canvas:opCount()
frame({ { slot = 0, id = 21, x = 600, y = 700 } })
frame({ { slot = 0, id = 21, x = 610, y = 705 } })
frame({ { slot = 0, id = -1 } })
for _ = 1, 9 do clock = clock + 10000 end        -- 100 ms of pen-up, no UI timers run
frame({ { slot = 0, id = 22, x = 620, y = 700 } })
frame({ { slot = 0, id = 22, x = 630, y = 706 } })
frame({ { slot = 0, id = -1 } })
UIManager.fireScheduled()
ok(view.canvas:opCount() == before + 2, "a real lift between nearby letters starts a new stroke")

-- 1c. A one-frame contact drop (the panel losing the finger) is still bridged.
before = view.canvas:opCount()
frame({ { slot = 0, id = 23, x = 600, y = 800 } })
frame({ { slot = 0, id = 23, x = 612, y = 804 } })
frame({ { slot = 0, id = -1 } })
frame({ { slot = 0, id = 24, x = 618, y = 806 } })
frame({ { slot = 0, id = 24, x = 630, y = 810 } })
frame({ { slot = 0, id = -1 } })
UIManager.fireScheduled()
ok(view.canvas:opCount() == before + 1, "a 10 ms contact drop is bridged into one stroke")

-- 2. Other tools stay on the gesture path.
view.tool = "pan"
gd.fed = {}
frame({ { slot = 0, id = 12, x = 400, y = 600 } })
frame({ { slot = 0, id = -1 } })
ok(fedFor(0) == 2, "the pan tool's contacts reach the detector")
view.tool = "pen"

-- 3. A contact that lands on the toolbar is not owned.
gd.fed = {}
frame({ { slot = 0, id = 13, x = 300, y = math.max(0, v.area_y - 10) } })
frame({ { slot = 0, id = -1 } })
ok(fedFor(0) == 2, "a touch outside the drawing area reaches the detector")

-- 4. A second finger hands the multi-touch back to gestures, and the barely
--    started stroke under the first finger is dropped, not committed as a dot.
local ops = view.canvas:opCount()
gd.fed = {}
frame({ { slot = 0, id = 14, x = 500, y = 900 } })
frame({ { slot = 0, id = 14, x = 502, y = 901 } })
frame({ { slot = 1, id = 15, x = 700, y = 900 } })
ok(view._raw.slot == nil, "a second finger ends raw ownership")
ok(not view.capturing, "the young stroke under the first finger is cancelled")
frame({ { slot = 0, id = 14, x = 510, y = 905 }, { slot = 1, id = 15, x = 708, y = 905 } })
ok(fedFor(0) == 1 and fedFor(1) == 2, "both fingers reach the detector after the hand-off")
view:onIaTouch(nil, { pos = { x = 510, y = 905 } })
ok(not view.capturing, "a detector touch during the hand-off does not open a stroke")
frame({ { slot = 0, id = -1 }, { slot = 1, id = -1 } })
UIManager.fireScheduled()
ok(view.canvas:opCount() == ops, "a two-finger gesture leaves no ink")
ok(view._raw.ignore_slot == nil, "the hand-off state clears when the fingers lift")

-- 5. A dialog on top: not owned.
local dlg = { name = "dialog" }
UIManager:show(dlg)
gd.fed = {}
frame({ { slot = 0, id = 16, x = 500, y = 900 } })
frame({ { slot = 0, id = -1 } })
ok(fedFor(0) == 2 and not view.capturing, "no raw drawing under a dialog")
UIManager:close(dlg)

-- 6. Palm rejection on: the pen path owns input, fingers are left alone.
view.palm_reject = true
gd.fed = {}
frame({ { slot = 0, id = 17, x = 500, y = 900 } })
frame({ { slot = 0, id = -1 } })
ok(fedFor(0) == 2, "with palm rejection on, finger frames go to the detector")
view.palm_reject = false
UIManager.fireScheduled()

-- 7. An error inside the tracker disarms it and the frame still reaches the detector.
local real = view.onRawFrame
view.onRawFrame = function() error("boom") end
gd.fed = {}
frame({ { slot = 0, id = 18, x = 500, y = 900 } })
ok(fedFor(0) == 1 and view._raw_wrapper == nil, "a tracker error disarms it and passes the frame on")
frame({ { slot = 0, id = -1 } })
view.onRawFrame = real

-- 8. Closing restores the detector's own method.
UIManager:close(view)
ok(rawget(gd, "feedEvent") == nil, "closing the canvas unwraps feedEvent")

Device.input.gesture_detector = nil
Device.input.wacom_protocol = true
Device.input.pen_slot = saved_pen_slot

print(("rawfinger: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
