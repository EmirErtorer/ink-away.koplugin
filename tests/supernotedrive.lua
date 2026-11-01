-- Low-latency ink on a Supernote (ink/supernotedrive.lua): the pen-mapping policy
-- and claim/release/stroke lifecycle, against a fake binder client (no real JNI).
--   luajit tests/supernotedrive.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local SupernoteDrive = require("ink/supernotedrive")
local SupernoteInk = require("ink/supernoteink") -- off Android: the stub, but real Pen/Colour constants
local UIManager = require("ui/uimanager")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function clear(t) for k in pairs(t) do t[k] = nil end end

-- A fake binder client recording every call it was sent.
local function fakeInk(opts)
    opts = opts or {}
    local calls = {}
    local ink = { Pen = SupernoteInk.Pen, Color = SupernoteInk.Color }
    local function record(name)
        return function(...) calls[#calls + 1] = { name, ... } end
    end
    ink.isAvailable = function() return opts.available ~= false end
    ink.sendWriteAppInfo = opts.fail_claim and function() error("binder gone") end or record("claim")
    ink.setPen = record("setPen")
    ink.setEraser = record("setEraser")
    ink.clearAll = record("clearAll")
    ink.setFullScreenDisable = record("setFullScreenDisable")
    ink.clearDisableAreas = record("clearDisableAreas")
    ink.enableFullUiAuto = record("enableFullUiAuto")
    return ink, calls
end

-- ---- detect -----------------------------------------------------------------
do
    local ink = fakeInk({ available = true })
    ok(SupernoteDrive.detect(ink) == true, "detect: present")
    local gone = fakeInk({ available = false })
    ok(SupernoteDrive.detect(gone) == nil, "detect: absent is nil, not false")
    local failing = fakeInk()
    failing.isAvailable = function() error("JNI not ready") end
    ok(SupernoteDrive.detect(failing) == nil, "detect: a failing probe is not available")
end

-- ---- acquire / release: claims and releases the overlay, shared by refcount -----
do
    local ink, calls = fakeInk()
    ok(SupernoteDrive.acquire(ink), "acquire: claims the overlay")
    ok(#calls == 3, "acquire: claim, full-UI ink on, and no disabled areas")
    local names = {}
    for _, c in ipairs(calls) do names[c[1]] = true end
    ok(names.claim and names.enableFullUiAuto and names.clearDisableAreas, "acquire: the right three calls")
    ok(calls[2][1] == "enableFullUiAuto" and calls[2][2] == true, "acquire: full-UI ink turned on")
    ok(SupernoteDrive.active(), "acquire: active")

    -- a second view shares it: no new calls, refcounted
    ok(SupernoteDrive.acquire(ink), "acquire: a second view")
    ok(#calls == 3, "acquire: a shared claim makes no new calls")
    SupernoteDrive.release(1404, 1872)
    ok(SupernoteDrive.active(), "release: still held by the other view")
    SupernoteDrive.release(1404, 1872)
    ok(not SupernoteDrive.active(), "release: the last view out releases it")
    local last3 = { calls[#calls - 2][1], calls[#calls - 1][1], calls[#calls][1] }
    ok(last3[1] == "setFullScreenDisable" and last3[2] == "clearAll" and last3[3] == "enableFullUiAuto",
        "release: disables everywhere, clears, and turns full-UI ink back off")
    ok(calls[#calls - 2][2] == 1404 and calls[#calls - 2][3] == 1872, "release: disabled over the real screen size")
    ok(calls[#calls][2] == false, "release: full-UI ink turned off")
end

-- ---- acquire: nothing without the binder, or a second view's different client ----
do
    local gone = fakeInk({ available = false })
    ok(not SupernoteDrive.acquire(gone), "acquire: nothing without the binder")
    ok(not SupernoteDrive.active(), "acquire: so nothing is held")

    local a = fakeInk()
    local b = fakeInk()
    ok(SupernoteDrive.acquire(a), "acquire: the first view")
    ok(not SupernoteDrive.acquire(b), "acquire: a stray second client is refused (one drive at a time)")
    SupernoteDrive.release(100, 100)
end

-- ---- acquire: a claim that fails midway is refused and logged -------------------
do
    local ink = fakeInk({ fail_claim = true })
    local warned
    ok(not SupernoteDrive.acquire(ink, function(...) warned = true end), "acquire: a failed claim is refused")
    ok(warned, "acquire: and logged")
    ok(not SupernoteDrive.active(), "acquire: nothing held after a failed claim")
end

-- ---- setPen: needle vs. mark, eraser, deduped, width and colour mapped -----------
do
    local ink, calls = fakeInk()
    SupernoteDrive.acquire(ink)
    clear(calls)
    SupernoteDrive.setPen(false, "solid", 3, { 0, 0, 0 })
    ok(#calls == 1 and calls[1][1] == "setPen", "setPen: a plain pen")
    ok(calls[1][2] == SupernoteInk.Pen.NEEDLE, "setPen: the needle for a plain line")
    ok(calls[1][4] == SupernoteInk.Color.BLACK, "setPen: black for black")

    SupernoteDrive.setPen(false, "solid", 3, { 0, 0, 0 })
    ok(#calls == 1, "setPen: the same pen again is not re-sent")

    SupernoteDrive.setPen(false, "highlighter", 24, { 255, 235, 59 })
    ok(#calls == 2 and calls[2][2] == SupernoteInk.Pen.MARK, "setPen: the mark pen for a highlighter")
    ok(calls[2][4] == SupernoteInk.Color.LIGHT_GRAY, "setPen: a pale colour buckets to the lightest tier")

    SupernoteDrive.setPen(false, "felttip", 10, { 90, 90, 90 })
    ok(calls[3][4] == SupernoteInk.Color.DARK_GRAY, "setPen: a mid-dark colour buckets to dark grey")
    SupernoteDrive.setPen(false, "felttip", 10, { 150, 150, 150 })
    ok(calls[4][4] == SupernoteInk.Color.GRAY, "setPen: a mid-light colour buckets to grey")

    SupernoteDrive.setPen(true, nil, 40, nil)
    ok(calls[5][1] == "setEraser" and calls[5][2] == false, "setPen: a round eraser")
    SupernoteDrive.setPen(true, nil, 40, nil)
    ok(#calls == 5, "setPen: the same eraser size again is not re-sent")
    SupernoteDrive.setPen(true, nil, 4, nil)
    ok(calls[6][3] == 400, "setPen: the eraser's EMR size has a floor")

    -- width: a usable, clamped EMR range (the exact mapping is unspecified)
    SupernoteDrive.setPen(false, "solid", 1, { 0, 0, 0 })
    ok(calls[7][3] == 200, "setPen: a thin pen's EMR size has a floor")
    SupernoteDrive.setPen(false, "solid", 999, { 0, 0, 0 })
    ok(calls[8][3] == 2400, "setPen: a very wide pen's EMR size has a ceiling")

    SupernoteDrive.release(100, 100)
end

-- ---- setPen: nothing without an acquired drive -----------------------------------
do
    local ink, calls = fakeInk()
    SupernoteDrive.setPen(false, "solid", 3, { 0, 0, 0 })
    ok(#calls == 0, "setPen: a no-op when nothing is acquired")
end

-- ---- clearSoon: debounced, only clears while acquired ----------------------------
do
    local ink, calls = fakeInk()
    SupernoteDrive.acquire(ink)
    clear(calls)
    SupernoteDrive.clearSoon(UIManager, 0.3)
    ok(UIManager.pendingCount() == 1, "clearSoon: scheduled")
    SupernoteDrive.clearSoon(UIManager, 0.3) -- a second stroke's settle pushes it back
    ok(UIManager.pendingCount() == 1, "clearSoon: a new call replaces the pending one, not stacks")
    UIManager.fireScheduled()
    ok(#calls == 1 and calls[1][1] == "clearAll", "clearSoon: clears once it fires")

    SupernoteDrive.release(100, 100)
    SupernoteDrive.clearSoon(UIManager, 0.3)
    ok(UIManager.pendingCount() == 0, "clearSoon: nothing scheduled once released")
end

print(("supernotedrive: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
