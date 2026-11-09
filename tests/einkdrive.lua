-- Fast ink on a Boox (ink/einkdrive.lua): which panels Ink Away drives itself,
-- what it asks KOReader's Onyx driver for, and that the screen is left as it was.
--   luajit tests/einkdrive.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local EinkDrive = require("ink/einkdrive")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- KOReader's android module as its launcher's drivers answer it: Onyx's
-- constants (full GC16 + wait, partial GC16, REAGL, GC16, DU; delays 250, 100, 0).
local function android(platform, full, consts)
    return {
        isEink = function() return platform ~= nil, platform end,
        isEinkFull = function() return full end,
        getEinkConstants = function() return unpack(consts) end,
    }
end
local ONYX = { 98, 2, 38, 2, 1, 250, 100, 0 }

-- ---- detect: only Onyx's full-only driver ------------------------------------
do
    local c = EinkDrive.detect(android("qualcomm", false, ONYX))
    ok(c and c.fast == 1 and c.ui == 2 and c.delay_fast == 0 and c.delay_ui == 100, "detect: a Boox gives DU and GC16")
    ok(EinkDrive.detect(android("qualcomm", true, ONYX)) == nil, "detect: a panel KOReader drives fully is left to it")
    ok(EinkDrive.detect(android("rockchip", false, { 4, 4, 4, 4, 4, 4, 4, 4 })) == nil, "detect: other full-only drivers are not Onyx")
    ok(EinkDrive.detect(android(nil, false, ONYX)) == nil, "detect: a panel KOReader doesn't know (Bigme)")
    ok(EinkDrive.detect(android("qualcomm", false, { 0, 0, 0, 0, 0, 0, 0, 0 })) == nil, "detect: no usable constants")
    ok(EinkDrive.detect({ isEink = function() error("no JNI") end }) == nil, "detect: a failing call is not a Boox")
end

-- A screen like KOReader's Android framebuffer: the class's refreshFastImp posts
-- the window; _updatePartial asks the panel.
local function screen()
    local log = {}
    local Class = {}
    Class.__index = Class
    function Class.refreshFastImp(fb, x, y, w, h) log[#log + 1] = { "post", x, y, w, h } end
    function Class._updatePartial(fb, mode, delay, x, y, w, h) log[#log + 1] = { "ask", mode, delay, x, y, w, h } end
    function Class.getWidth() return 1404 end
    function Class.getHeight() return 1872 end
    return setmetatable({}, Class), log, Class
end

-- ---- live requests ---------------------------------------------------------------
do
    local fb, log, Class = screen()
    local t = 0
    local c = EinkDrive.detect(android("qualcomm", false, ONYX))
    ok(EinkDrive.acquire(fb, c, function() return t end), "acquire: on")
    ok(rawget(fb, "refreshFastImp") ~= nil, "acquire: the screen's fast refresh is hooked")
    fb:refreshFastImp(100, 200, 30, 20)
    ok(#log == 2 and log[1][1] == "post" and log[2][1] == "ask", "fast: the window is posted, then the panel asked")
    local a = log[2]
    ok(a[2] == 1 and a[3] == EinkDrive.FAST_DELAY_MS and a[4] == 100 and a[5] == 200 and a[6] == 30 and a[7] == 20,
        "fast: DU over the same rect, a frame later")
    -- paced: a request soon after waits, and goes with the next one, over both
    t = 40
    fb:refreshFastImp(140, 210, 30, 20)
    ok(#log == 3 and log[3][1] == "post", "paced: the window is posted, the panel isn't asked yet")
    t = 90
    fb:refreshFastImp(170, 215, 30, 20)
    ok(#log == 4, "paced: nor again")
    t = EinkDrive.PACE_MS
    fb:refreshFastImp(200, 220, 30, 20)
    a = log[6]
    ok(#log == 6 and a[1] == "ask" and a[4] == 100 and a[5] == 200 and a[6] == 130 and a[7] == 40,
        "paced: the next request covers all that waited, and the one before")
    -- at the pen's speed: requests per second, not per post
    local before = #log
    local asks = 0
    for i = 1, 25 do
        t = t + 40
        fb:refreshFastImp(10 + i, 10, 5, 5)
    end
    for k = before + 1, #log do if log[k][1] == "ask" then asks = asks + 1 end end
    ok(asks >= 5 and asks <= 7, "paced: a second of posts asks about 6 times, not 25 (" .. asks .. ")")
    t = 5000
    fb:refreshFastImp(500, 500, 10, 10)     -- (what waited goes with this one)
    t = 6000
    local waiting = #log
    fb:refreshFastImp(600, 600, 10, 10)
    ok(#log == waiting + 2 and log[#log][4] == 600 and log[#log][6] == 10, "fast: after a pause, just its own rect")
    t = 7000
    fb:refreshFastImp()
    a = log[#log]
    ok(a[4] == 0 and a[5] == 0 and a[6] == 1404 and a[7] == 1872, "fast: no rect means the whole screen")

    -- a stroke's end and the grey settle are asked for directly
    ok(EinkDrive.ask("fast", 10, 20, 30, 40), "ask: the tail")
    a = log[#log]
    ok(a[2] == 1 and a[3] == EinkDrive.TAIL_DELAY_MS, "ask: the tail is DU, a little later")
    ok(EinkDrive.ask("ui", 10, 20, 30, 40), "ask: the settle")
    a = log[#log]
    ok(a[2] == 2 and a[3] == 100, "ask: the settle is GC16 after KOReader's ui delay")
    ok(not EinkDrive.ask("ui", 10, 20, 0, 40), "ask: nothing for an empty rect")
    ok(EinkDrive.asked() > 6, "asked: counted")

    -- a second view shares it; the last one out unhooks
    ok(EinkDrive.acquire(fb, c), "acquire: a second view")
    EinkDrive.release()
    ok(EinkDrive.active() and rawget(fb, "refreshFastImp") ~= nil, "release: still hooked for the other view")
    EinkDrive.release()
    ok(not EinkDrive.active() and rawget(fb, "refreshFastImp") == nil, "release: the screen is as it was")
    local n = #log
    fb:refreshFastImp(1, 1, 1, 1)
    ok(#log == n + 1 and log[#log][1] == "post", "release: a fast refresh only posts again")
    ok(not EinkDrive.ask("fast", 1, 1, 1, 1), "release: nothing asked once off")
    ok(Class.refreshFastImp ~= nil, "release: the class method untouched")
end

-- ---- the pen stops while a request waits: it still goes out ------------------------
do
    local fb, log = screen()
    local t = 0
    local timers = {}
    local c = EinkDrive.detect(android("qualcomm", false, ONYX))
    EinkDrive.acquire(fb, c, function() return t end, nil, function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end)
    fb:refreshFastImp(10, 10, 5, 5)
    t = 40
    fb:refreshFastImp(20, 10, 5, 5)
    t = 80
    fb:refreshFastImp(30, 10, 5, 5)
    ok(#timers == 1 and timers[1].ms == EinkDrive.PACE_MS - 40, "paced: one timer for what waits")
    local n = #log
    t = 160
    timers[1].fn()
    ok(#log == n + 1 and log[#log][1] == "ask" and log[#log][4] == 10, "paced: the timer sends it")
    timers[1].fn()
    ok(#log == n + 1, "paced: and nothing twice")
    -- a stroke's end covers what waits
    t = 200
    fb:refreshFastImp(40, 10, 5, 5)
    EinkDrive.ask("fast", 0, 0, 100, 100)
    n = #log
    timers[#timers].fn()
    ok(#log == n, "paced: the tail already covered what waited")
    -- closed while one waits
    t = 240
    fb:refreshFastImp(50, 10, 5, 5)
    local fire = timers[#timers].fn
    EinkDrive.release()
    n = #log
    fire()
    ok(#log == n, "paced: nothing asked once off")
end

-- ---- the firmware has the panel: nothing is asked of it ------------------------------
do
    local fb, log = screen()
    local busy = true
    EinkDrive.quiet = function() return busy end
    local c = EinkDrive.detect(android("qualcomm", false, ONYX))
    EinkDrive.acquire(fb, c, function() return 0 end)
    fb:refreshFastImp(10, 10, 5, 5)
    ok(#log == 1 and log[1][1] == "post", "quiet: the window is posted, the panel not asked")
    ok(not EinkDrive.ask("fast", 1, 1, 5, 5) and not EinkDrive.ask("ui", 1, 1, 5, 5), "quiet: nor directly")
    busy = false
    ok(EinkDrive.ask("ui", 1, 1, 5, 5), "quiet: over, it can ask again")
    EinkDrive.release()
    EinkDrive.quiet = nil
end

-- ---- another plugin wraps on top: ours passes through after release ----------------
do
    local fb, log = screen()
    local c = EinkDrive.detect(android("qualcomm", false, ONYX))
    EinkDrive.acquire(fb, c)
    local ours = fb.refreshFastImp
    local theirs = function(self, ...) log[#log + 1] = { "theirs" }; return ours(self, ...) end
    fb.refreshFastImp = theirs
    EinkDrive.release()
    ok(rawget(fb, "refreshFastImp") == theirs, "chain: the other plugin's wrapper stays")
    local n = #log
    fb:refreshFastImp(1, 1, 1, 1)
    ok(#log == n + 2 and log[n + 2][1] == "post", "chain: ours no longer asks the panel")
end

-- ---- a failing call turns it off --------------------------------------------------
do
    local fb, log = screen()
    local warned
    fb._updatePartial = function() error("JNI went away") end
    local c = EinkDrive.detect(android("qualcomm", false, ONYX))
    EinkDrive.acquire(fb, c, nil, function() warned = true end)
    local okc = pcall(fb.refreshFastImp, fb, 1, 1, 1, 1)
    ok(okc and #log == 1 and warned, "broken: the refresh still goes out and the failure is logged")
    ok(not EinkDrive.active(), "broken: off for the rest of the session")
    EinkDrive.release()
end

-- ---- a screen without the Android driver's pieces is never hooked -------------------
do
    local c = EinkDrive.detect(android("qualcomm", false, ONYX))
    ok(not EinkDrive.acquire({}, c), "acquire: not on a screen without _updatePartial")
    ok(not EinkDrive.active(), "acquire: so nothing is on")
end

print(("einkdrive: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
