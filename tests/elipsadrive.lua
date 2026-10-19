-- Elipsa worker ordering and failure recovery with a deliberately slow transport.
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local ElipsaDrive = require("ink/elipsadrive")
local ui = require("ui/uimanager")
local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local device = { model = "Kobo_europa", isSunxi = function() return true end }
local function world()
    ui.reset()
    local calls, workers = {}, {}
    local class = {}
    function class:mech_refresh(_, _, mode, x, y, w, h)
        calls[#calls + 1] = { mode = mode, x = x, y = y, w = w, h = h, marker = self.marker_data[0] }
    end
    function class:reinit() calls[#calls + 1] = { mode = "reinit" } end
    function class:setRotationMode() self:reinit() end
    function class:close() calls[#calls + 1] = { mode = "close" } end
    function class:refreshWaitForLastImp() calls[#calls + 1] = { mode = "wait", marker = self.marker_data[0] } end
    local fb = setmetatable({ fd = 3, data = {}, layer = {}, marker_data = { [0] = 0 }, waveform_fast = 2 }, { __index = class })
    local fail_start = false
    local function factory()
        if fail_start then return nil end
        local worker = { sent = {}, waits = 0 }
        workers[#workers + 1] = worker
        function worker:send(r)
            if self.fail_send then return false end
            self.sent[#self.sent + 1] = r
            return true
        end
        function worker:poll(wait)
            if self.dead then return false end
            if wait then self.waits = self.waits + 1 end
            if wait or self.ready then self.ready = false; return #self.sent end
        end
        function worker:close(failed)
            self.closed, self.failed = true, failed
            return true
        end
        return worker
    end
    return fb, calls, workers, factory, function() fail_start = true end
end
local function fast(fb, x, y, w, h) fb:mech_refresh(false, false, 2, x or 10, y or 20, w or 5, h or 6) end

do
    local fb = world()
    for _, name in ipairs({ "Kobo_cadmus", "Kobo_condor", "KindleScribe", "SDL" }) do
        ok(not ElipsaDrive.acquire({ model = name, isSunxi = device.isSunxi }, fb, ui), "excluded: " .. name)
    end
    fb.data = nil
    ok(not ElipsaDrive.acquire(device, fb, ui), "missing ION buffer: no hook")
end
do
    local fb, calls, workers, factory = world()
    local original = fb.mech_refresh
    ok(ElipsaDrive.acquire(device, fb, ui, nil, factory), "Elipsa acquired")
    fast(fb)
    ok(#calls == 0 and #workers == 1 and #workers[1].sent == 1, "first update goes to worker without synchronous refresh")
    for i = 1, 100 do fast(fb, 100 + i, 50, 5, 6) end
    ok(#workers[1].sent == 1 and workers[1].waits == 0, "slow worker: input never waits or queues 100 obsolete updates")
    workers[1].ready = true
    ui.fireScheduled()
    local r = workers[1].sent[2]
    ok(r and r.x == 101 and r.w == 104 and r.y == 50 and r.h == 6, "pending rectangles sent as one union")
    ok(fb.marker_data[0] == 1, "completed driver marker returned to parent")
    fb:mech_refresh(false, false, 32, 0, 0, 400, 600)
    ok(workers[1].closed and workers[1].waits == 1 and calls[1].mode == 32 and calls[1].marker == 2,
        "grey refresh fences worker and sees its last marker")
    fast(fb)
    ok(#workers == 2, "next live update starts a fresh driver snapshot")
    fb:setRotationMode(1)
    ok(workers[2].closed and calls[2].mode == "reinit", "rotation drains worker before changing layout")
    fast(fb)
    fb:refreshWaitForLastImp()
    ok(workers[3].closed and calls[3].mode == "wait" and calls[3].marker == 1, "panel wait fences worker")
    fast(fb)
    ElipsaDrive.release()
    ok(workers[4].closed and not ElipsaDrive.active(), "suspend releases worker and screen hooks")
    ElipsaDrive.acquire(device, fb, ui, nil, factory)
    ElipsaDrive.acquire(device, fb, ui, nil, factory)
    ElipsaDrive.release()
    ok(ElipsaDrive.active(), "nested view holds driver")
    fast(fb)
    ElipsaDrive.release()
    ok(not ElipsaDrive.active() and workers[5].closed and fb.mech_refresh == original and not rawget(fb, "mech_refresh"),
        "last view drains and restores inherited methods")
    ok(ui.pendingCount() == 0, "no timers left on close")
end
do
    local fb, calls, workers, factory = world()
    ElipsaDrive.acquire(device, fb, ui, nil, factory)
    fb._just_rotated = true
    fast(fb)
    ok(#workers == 0 and #calls == 1, "first refresh after rotation stays synchronous")
    fb._just_rotated = nil
    fast(fb)
    fast(fb, 100, 100)
    workers[1].dead = true
    ui.fireScheduled()
    ok(not ElipsaDrive.active() and workers[1].failed and #calls == 2, "dead worker killed and pending pixels repainted")
    ok(calls[2].x == 10 and calls[2].y == 20 and calls[2].w == 95 and calls[2].h == 86,
        "repaint includes both in-flight and pending rectangles")
    ok(not ElipsaDrive.acquire(device, fb, ui, nil, factory), "failed acquire does not leak a reference")
    fast(fb)
    ok(#calls == 3, "failure latches synchronous fallback")
    ElipsaDrive.release()
    ok(ui.pendingCount() == 0 and not rawget(fb, "mech_refresh"), "failed session cleans up")
end
do
    local fb, calls, _, factory, fail_start = world()
    ElipsaDrive.acquire(device, fb, ui, nil, factory)
    fail_start()
    fast(fb)
    ok(#calls == 1 and not ElipsaDrive.active(), "fork/ioctl failure falls back with the original rectangle")
    ElipsaDrive.release()
end
do
    local fb, calls, _, factory = world()
    ElipsaDrive.acquire(device, fb, ui, nil, factory)
    local ours = fb.mech_refresh
    local theirs = function(self, ...) return ours(self, ...) end
    fb.mech_refresh = theirs
    ElipsaDrive.release()
    fast(fb)
    ok(fb.mech_refresh == theirs and #calls == 1, "a later plugin wrapper survives release")
end
print(("elipsadrive: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
