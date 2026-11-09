-- Model Android's logical frame separately from a handwriting-locked panel.
-- luajit tests/booxdisplay.lua
package.path = "./?.lua;" .. package.path
local Drive = require("ink/booxdrive")
local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local um = { jobs = {}, refreshes = {} }
function um:scheduleIn(delay, fn) self.jobs[fn] = delay end
function um:nextTick(fn) self:scheduleIn(0, fn) end
function um:unschedule(fn) self.jobs[fn] = nil end
function um:show() end
function um:close() end
function um:setDirty(_target, mode) self.refreshes[#self.refreshes + 1] = mode end
function um:fire()
    local jobs = self.jobs; self.jobs = {}
    for fn in pairs(jobs) do fn() end
end
local c = { ok = true, state = 0, posts = true, repaints = {}, broken = false }
function c:usable() return not self.broken end
function c:setStroke() return true end
function c:setRegion() return true end
function c:setPenState(n)
    self.state = n
    self.posts = n ~= 1 and n ~= 2
    return true
end
function c:setPosting(enabled) self.posts = enabled; return true end
local fb = { logical = 0, physical = 0 }
function fb:getWidth() return 1860 end
function fb:getHeight() return 2480 end
function fb:refreshUIImp()
    self.logical = self.logical + 1
    if c.posts then self.physical = self.logical end
    return "posted"
end
fb.refreshFastImp, fb.refreshFullImp = fb.refreshUIImp, fb.refreshUIImp
function c:repaint(x, y, w, h)
    self.repaints[#self.repaints + 1] = { x, y, w, h }
    if self.fail then self.broken = true; self:setPenState(0); return false end
    fb.physical = fb.logical
    return true
end
local view = {}
local want = { limit = { { x = 100, y = 0, w = 1760, h = 2480 } }, width = 3 }
function view:booxInkUpdate() return Drive.want(self, want) end
Drive.reset()
Drive.join(view, c)
Drive.watch(um)
Drive.watchScreen(fb, um)
Drive.watchScreen(fb, um) -- installation is idempotent
view:booxInkUpdate()

want.posts = true
view:booxInkUpdate()
ok(c.state == 2 and c.posts and not Drive.inkingFor(view), "prepared pen capture keeps ordinary screen posts open")
fb:refreshUIImp(0, 0, 10, 10)
ok(fb.physical == fb.logical and next(um.jobs) == nil, "first annotation frame reaches the panel before any pen contact")
want.posts = false
view:booxInkUpdate()
ok(c.state == 2 and not c.posts and Drive.inkingFor(view), "first contact gates posts without starting capture after DOWN")
want.posts = nil
fb.logical, fb.physical = 0, 0

ok(fb:refreshFastImp(10, 20, 30, 40) == "posted" and fb.logical == 1 and fb.physical == 0,
    "raw mode: Android frame advances while ordinary panel posts are gated")
ok(select(2, next(um.jobs)) == 0.04, "repaint waits for Android composition")
fb:refreshUIImp(20, 40, 80, 90)
um:fire()
ok(fb.physical == fb.logical and #c.repaints == 1, "handwriting repaint commits the frame to physical panel")
ok(table.concat(c.repaints[1], ",") == "10,20,90,110", "updates coalesce as a clipped screen rect")
fb:refreshFullImp()
um:fire()
ok(table.concat(c.repaints[2], ",") == "0,0,1860,2480", "full repaint uses the whole window")

view._boox_defer = true
local deferred = #c.repaints
fb:refreshUIImp(10, 20, 30, 40)
ok(next(um.jobs) == nil and #c.repaints == deferred,
    "batched handwriting does not repaint every committed letter")
view._boox_defer = nil
fb:refreshFastImp(10, 20, 30, 40)
local before_rest = next(um.jobs)
view._boox_defer = true
um:fire()
ok(#c.repaints == deferred, "a queued repaint cannot run inside a later handwriting batch")
before_rest()
view._boox_defer = nil

fb:refreshFastImp(100, 100, 10, 10)
local stale = next(um.jobs)
local n = #c.repaints
um:show({})
ok(c.posts and c.state == 3 and next(um.jobs) == nil, "menu restores ordinary posts and cancels native repaint")
stale()
ok(#c.repaints == n, "paused repaint callback cannot run later")
fb:refreshUIImp(0, 0, 100, 100)
ok(fb.physical == fb.logical and next(um.jobs) == nil, "menus refresh normally while native pen is paused")
um:close({}); um:fire()
ok(c.state == 2, "closing menu resumes pen")
fb:refreshFastImp(200, 300, 20, 30)
n = #c.repaints
stale()
ok(#c.repaints == n, "cancelled callback cannot replace a newer pending repaint")
um:fire()
ok(table.concat(c.repaints[#c.repaints], ",") == "200,300,20,30", "newer frame still reaches the panel")

local C = { APP_CMD_LOST_FOCUS = 7, APP_CMD_GAINED_FOCUS = 6, APP_CMD_TERM_WINDOW = 2,
    APP_CMD_PAUSE = 13, APP_CMD_DESTROY = 15 }
local input = { calls = 0 }
function input:handleMiscEv(ev)
    self.calls = self.calls + 1
    if ev.code == C.APP_CMD_LOST_FOCUS and ev.value == 1 then
        ok(c.posts, "focus loss unlocks the display before the original Android handler")
    end
    return "handled"
end
Drive.watchInput(input, C, um)
Drive.watchInput(input, C, um)
input:handleMiscEv{ code = C.APP_CMD_LOST_FOCUS, value = 42 }
ok(c.state == 2, "Android touch cancellation is not treated as real focus loss")
ok(input:handleMiscEv{ code = C.APP_CMD_LOST_FOCUS, value = 1 } == "handled" and c.state == 3,
    "system control panel pauses native ink and preserves input handler return")
view:booxInkUpdate()
ok(c.state == 3, "a paint cannot re-enable ink behind a system window")
input:handleMiscEv{ code = C.APP_CMD_GAINED_FOCUS, value = 1 }
ok(c.state == 3 and select(2, next(um.jobs)) == 0.05, "resume lets the returned Android window compose first")
um:fire()
ok(c.state == 2 and input.calls == 3, "focus return resumes ink once, with no duplicate hook")

fb:refreshFastImp(10, 20, 30, 40)
Drive.leave(view)
ok(c.state == 0 and c.posts and next(um.jobs) == nil, "closing releases display and cancels delayed work")
fb:refreshUIImp(0, 0, 100, 100)
ok(fb.physical == fb.logical and next(um.jobs) == nil, "refresh hooks pass through after close")

Drive.join(view, c); view:booxInkUpdate()
c.fail = true
fb:refreshFastImp(10, 20, 30, 40)
um:fire()
ok(c.posts and c.state == 0 and not Drive.inkingFor(view), "failed handwriting repaint unlocks software fallback")
ok(um.refreshes[#um.refreshes] == "full", "failed repaint requests a normal full refresh")
Drive.leave(view)
Drive.reset()
print(("booxdisplay: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
