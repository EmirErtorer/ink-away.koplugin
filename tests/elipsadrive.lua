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
    local fb = setmetatable({ fd = 3, data = {}, layer = {}, marker_data = { [0] = 0 }, waveform_fast = 2, waveform_ui = 4 },
        { __index = class })
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
            -- a slow grey update: still going for `busy_rounds` waits, or for good
            if wait and (self.hung or (self.busy_rounds or 0) > 0) then
                self.waits = self.waits + 1
                if not self.hung then self.busy_rounds = self.busy_rounds - 1 end
                return nil
            end
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
    fast(fb)
    ok(#calls == 3, "failure latches synchronous fallback")
    ok(ElipsaDrive.acquire(device, fb, ui, nil, factory), "a second view joins a helper that may come back")
    ElipsaDrive.release()
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
-- #50: while a stroke is drawn the helper also takes the grey updates inside
-- its drawing area (a highlighter), and nothing else changes
local function grey(fb, x, y, w, h, flash) fb:mech_refresh(false, flash or false, 4, x, y, w, h) end
do
    local fb, calls, workers, factory = world()
    ElipsaDrive.acquire(device, fb, ui, nil, factory)
    local area = { x = 0, y = 100, w = 600, h = 700 }
    grey(fb, 10, 200, 5, 6)
    ok(#calls == 1 and calls[1].mode == 4 and #workers == 0, "grey: without a stroke a grey update is made as before")
    ElipsaDrive.stroke(area)
    grey(fb, 10, 200, 5, 6)
    ok(#calls == 1 and #workers == 1 and workers[1].sent[1].mode == 4,
        "grey: during a stroke the helper makes a grey update in the area, in grey")
    grey(fb, 10, 50, 5, 6)
    ok(#calls == 2 and calls[2].mode == 4 and workers[1].closed, "grey: one reaching outside the area waits and is made as before")
    grey(fb, 10, 200, 5, 6, true)
    ok(#calls == 3, "grey: a flashing one too")
    -- a fast and a grey update waiting together go as one grey update
    fast(fb, 20, 300, 5, 5)
    grey(fb, 40, 320, 5, 5)
    fast(fb, 60, 340, 5, 5)
    workers[2].ready = true
    ui.fireScheduled()
    local r = workers[2].sent[2]
    ok(r and r.mode == 4 and r.x == 40 and r.w == 25, "grey: a fast and a grey update together are shown grey")
    ElipsaDrive.stroke(nil)
    grey(fb, 10, 200, 5, 6)
    ok(calls[#calls].mode == 4 and workers[2].closed, "grey: after the stroke, grey updates are made as before")
    ElipsaDrive.release()
end
do
    -- the area is in the screen's own coordinates, as the updates are
    local fb, calls, workers, factory = world()
    function fb:calculateRealCoordinates(x, y, w, h) return x + 50, y + 70, w, h end
    ElipsaDrive.acquire(device, fb, ui, nil, factory)
    ElipsaDrive.stroke({ x = 0, y = 0, w = 100, h = 100 })
    grey(fb, 60, 80, 10, 10)
    ok(#calls == 0 and #workers == 1, "grey: the area is moved as KOReader moves the updates")
    grey(fb, 10, 10, 10, 10)
    ok(#calls == 1, "grey: and an update outside it is not taken")
    ElipsaDrive.release()
end
do
    -- a helper still busy with a slow update is waited for, not given up on
    local fb, calls, workers, factory = world()
    local logged = {}
    ElipsaDrive.acquire(device, fb, ui, function(...) logged[#logged + 1] = table.concat({ ... }, " ") end, factory)
    ElipsaDrive.stroke({ x = 0, y = 0, w = 600, h = 800 })
    grey(fb, 10, 10, 50, 50)
    workers[1].busy_rounds = 3
    fb:mech_refresh(false, true, 32, 0, 0, 600, 800)   -- a full refresh: waits for the helper
    ok(ElipsaDrive.active() or workers[1].closed and not workers[1].failed, "busy: a slow helper is waited for")
    ok(#logged == 0 and calls[#calls].mode == 32, "busy: no failure, and the full refresh follows")
    -- one that never answers is stuck: it fails, after a bounded wait
    ElipsaDrive.stroke({ x = 0, y = 0, w = 600, h = 800 })
    grey(fb, 10, 10, 50, 50)
    workers[2].hung = true
    fb:mech_refresh(false, true, 32, 0, 0, 600, 800)
    ok(workers[2].failed and workers[2].waits <= 5 and #logged == 1, "busy: a helper that never answers fails after a few waits")
    ElipsaDrive.release()
end
do
    -- a failure leaves the helper off until the next stroke, which tries again;
    -- three failures in a row leave it off until Ink Away opens again
    local fb, calls, workers, factory = world()
    local logged = {}
    ElipsaDrive.acquire(device, fb, ui, function(...) logged[#logged + 1] = table.concat({ ... }, " ") end, factory)
    local area = { x = 0, y = 0, w = 600, h = 800 }
    local function dies()
        ElipsaDrive.stroke(area)
        fast(fb)
        workers[#workers].dead = true
        ui.fireScheduled()
    end
    dies()
    ok(not ElipsaDrive.active() and logged[1]:find("until the next stroke", 1, true), "retry: a failure says it will try again")
    local n = #calls
    fast(fb)
    ok(#calls == n + 1, "retry: meanwhile updates are made as before")
    ElipsaDrive.stroke(area)
    fast(fb)
    ok(ElipsaDrive.active() and #workers == 2 and #calls == n + 1, "retry: the next stroke has the helper again")
    workers[2].ready = true
    ui.fireScheduled()
    dies(); dies()
    ok(not ElipsaDrive.active() and logged[#logged]:find("until the next stroke", 1, true),
        "retry: a success between failures starts the count again")
    dies()
    ok(logged[#logged]:find("using normal refreshes", 1, true), "retry: three in a row and it is left off")
    ElipsaDrive.stroke(area)
    n = #calls
    fast(fb)
    ok(not ElipsaDrive.active() and #calls == n + 1, "retry: a stroke after that does not start it again")
    ok(not ElipsaDrive.acquire(device, fb, ui, nil, factory), "retry: nor does a second view")
    ElipsaDrive.release()
    ok(ui.pendingCount() == 0 and not rawget(fb, "mech_refresh"), "retry: and closing cleans up")
end
print(("elipsadrive: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
