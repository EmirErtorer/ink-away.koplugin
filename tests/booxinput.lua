-- Native pen layer follows rear eraser/held tools before the next paint.
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Device = require("device")
local UIManager = require("ui/uimanager")
local BooxDrive = require("ink/booxdrive")
_G.G_reader_settings = { data = require("testenv").settings({ inkaway_palm_reject = true,
    inkaway_device_tip_shown = true }),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end }
Device.isAndroid = function() return true end
Device.input.pen_slot = 4
Device.input.wacom_protocol = false
BooxDrive.reset()
local c = { ok = true, states = {} }
function c:usable() return true end
function c:setPenState(n) self.states[#self.states + 1] = n; return true end
function c:setStroke() return true end
function c:setRegion() return true end
function c:setPosting(enabled) self.posts = enabled; return true end
BooxDrive.client(function() return c end, true)
local View = dofile("ink/view.lua")
View.androidPenTypes = function() return true end -- this nightly supplies pen/eraser tools
local view = View:new{}
UIManager:show(view)
view:booxInkUpdate()
local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
ok(not view:booxInking() and c.posts and c.states[#c.states] == 2,
    "idle canvas prepares capture before first DOWN while leaving ordinary display posts open")
local function slot(tool, id, x)
    return { slot = 4, id = id, tool = tool, x = x or 400, y = 600 }
end
view:onStylusSlot(Device.input, slot(1, 1))
ok(view:booxInking() and view._hw_stroke, "real pen contact starts native preview before first point")
view:onStylusSlot(Device.input, slot(1, 1, 440))
view:onStylusSlot(Device.input, slot(1, -1, 440))
local first = view._boox_rest_task
ok(view:booxInking() and first and UIManager.scheduled[first], "pen lift keeps preview for a bounded writing pause")
ok(#view.canvas.ops == 1 and not view.canvas.live, "stroke is committed before the delayed physical refresh")
local states = #c.states
view:onStylusSlot(Device.input, slot(1, 2, 470))
ok(view:booxInking() and not UIManager.scheduled[first] and #c.states == states,
    "next letter cancels the old rest timer without pausing the firmware")
first()
ok(view:booxInking() and not view._boox_rest_task, "stale rest callback cannot release a new stroke")
view:onStylusSlot(Device.input, slot(1, -1, 500))
local second = view._boox_rest_task
ok(second and second ~= first and #view.canvas.ops == 2, "each lift commits its stroke and restarts the rest timer")
second()
ok(not view:booxInking() and c.posts and not view._boox_rest_task,
    "rest deadline releases ordinary display posts and removes the timer")
ok(UIManager.last().mode == "ui", "rest deadline repaints the saved ink after releasing posts")
ok(UIManager.last().region == nil, "with nothing recorded, the whole view")
view:onStylusSlot(Device.input, slot(1, 5, 300))
view:onStylusSlot(Device.input, slot(1, -1, 300))
view._boox_blocked = { x0 = 280, y0 = 590, x1 = 340, y1 = 640 }
local rest = view._boox_rest_task
rest()
local rr = UIManager.last().region
ok(rr and rr.x == 280 and rr.y == 590 and rr.w == 60 and rr.h == 50 and UIManager.last().mode == "ui",
    "rest refresh: only what was held back, not the whole page")
ok(view._boox_blocked == nil, "rest refresh: and it is forgotten")
-- Android's real rear-eraser tool, no side-button latch, without a paint.
view:onStylusSlot(Device.input, slot(2, 1))
ok(view.tool == "erase" and view.canvas.live and view.canvas.live.kind == "erase",
    "rear eraser starts an erase operation")
ok(not view:booxInking() and c.states[#c.states] == 3, "rear eraser pauses firmware before first sample")
view:onStylusSlot(Device.input, slot(2, 1, 440))
view:onStylusSlot(Device.input, slot(2, -1, 440))
ok(view.tool == "pen" and not view:booxInking(), "rear eraser lift restores pen without locking idle display")
ok(view:undo(), "rear eraser operation is undoable")
view:onStylusSlot(Device.input, slot(1, 3))
view:holdAction("button1")
ok(view.pen_style == "highlighter" and not view:booxInking(), "held highlighter pauses firmware without paint")
view:restoreHeld()
ok(view.pen_alpha == 255 and view:booxInking(), "held highlighter lift restores native pen")
view:setTool("erase")
ok(not view:booxInking(), "toolbar eraser pauses firmware before paint")
view:setTool("pen")
ok(view:booxInking(), "toolbar pen resumes firmware for the current contact")
view:onStylusSlot(Device.input, slot(1, -1))
local stale = view._boox_rest_task
UIManager:show({ name = "menu" })
ok(not view:booxInking() and not view._boox_rest_task and not UIManager.scheduled[stale],
    "opening a menu bypasses the writing delay immediately")
UIManager:close(UIManager.shown)
UIManager.fireScheduled()
stale()
ok(not view:booxInking(), "closing a menu does not resume idle native drawing")

local function letter(x)
    view:onStylusSlot(Device.input, slot(1, 10, x))
    view:onStylusSlot(Device.input, slot(1, 10, x + 25))
    view:onStylusSlot(Device.input, slot(1, -1, x + 25))
end
letter(600)
view._reject_finger, view._palm_count = false, 0
ok(not view:fingerRejected() and not view:booxInking() and not view._boox_rest_task,
    "accepted finger navigation releases a pending writing refresh immediately")
letter(650)
view:penUiStart(4, 50, 30)
ok(not view:booxInking() and not view._boox_rest_task, "pen tapping the toolbar bypasses the delay")
view:resetPenState()

view.booxInkDelayMs = function() return 0 end
letter(700)
ok(not view:booxInking() and not view._boox_rest_task, "zero delay preserves immediate lift refresh")
view.booxInkDelayMs = nil
ok(view:booxInkDelayMs() == 500, "writing pause uses the half-second default")
letter(750)
stale = view._boox_rest_task
view:onSuspend()
stale()
ok(not view:booxInking() and not view._boox_rest_task and not UIManager.scheduled[stale],
    "suspend cancels delayed refresh and a stale callback cannot resume the layer")
view:onResume()
ok(not view:booxInking(), "wake leaves ordinary posts enabled until fresh contact")
letter(800)
stale = view._boox_rest_task
UIManager:close(view)
stale()
ok(c.states[#c.states] == 0 and not UIManager.scheduled[stale], "closing stops firmware and cancels delayed refresh")
require("testenv").cleanup()
print(("booxinput: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
