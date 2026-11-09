-- Faster ink on Android and Boox's own pen layer, on KOReader's REAL blitter:
--   * ink/androidwindow.lua: a refresh posts only its rect to the app's window,
--     pixel for pixel what KOReader's whole-screen copy puts there, in every
--     rotation, inverted or not; and posts all of it when Android asks, when the
--     window is odd, or when it is off;
--   * ink/booxink.lua: Onyx's pen-layer methods found and called through a fake
--     JNI, a Java exception turning it off;
--   * ink/booxdrive.lua: when the firmware inks, sending nothing twice;
--   * the view: the firmware inks for an opaque pen only, pauses for anything
--     shown over the page, a pen stroke it inks gets no live refresh of its own
--     but one at the lift, a finger stroke keeps its live refreshes, and closing
--     stops it. Without the android module (every test but these), nothing at all.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/boox.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
local Device = require("device")
local UIManager = require("ui/uimanager")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

-- the bits of Android's headers these use (KOReader's android module declares them)
pcall(ffi.cdef, [[
typedef struct ARect { int32_t left; int32_t top; int32_t right; int32_t bottom; } ARect;
typedef struct ANativeWindow_Buffer { int32_t width; int32_t height; int32_t stride; int32_t format; void* bits; uint32_t reserved[6]; } ANativeWindow_Buffer;
enum { WINDOW_FORMAT_RGBA_8888 = 1, WINDOW_FORMAT_RGBX_8888 = 2, WINDOW_FORMAT_RGB_565 = 4 };
typedef union jvalue { uint8_t z; int8_t b; uint16_t c; int16_t s; int32_t i; int64_t j; float f; double d; void* l; } jvalue;
]])

------------------------------------------------------------------------------
-- The window: only the refresh's rect posted
------------------------------------------------------------------------------
local AndroidWindow = require("ink/androidwindow")

-- A screen of W x H (its buffer's own size) and a window to post it to.
local function screenAndWindow(W, H, rot, inverse, opts)
    opts = opts or {}
    local fb = { bb = BB.new(W, H, BB.TYPE_BBRGB32), full = 0 }
    fb.bb:setRotation(rot)
    if inverse then fb.bb:invert() end
    -- a picture to post: every pixel its own colour
    for y = 0, fb.bb:getHeight() - 1, 3 do
        for x = 0, fb.bb:getWidth() - 1, 5 do
            fb.bb:paintRect(x, y, 5, 3, BB.ColorRGB32((x * 7) % 256, (y * 3) % 256, (x + y) % 256, 255))
        end
    end
    local mem = ffi.new("uint32_t[?]", W * H)
    local win = { mem = mem, locks = {}, posts = 0 }
    local android = { app = { window = ffi.cast("void*", 1) }, lib = {} }
    android.lib.ANativeWindow_lock = function(_w, buffer, dirty)
        if opts.fail then return -1 end
        win.locks[#win.locks + 1] = dirty ~= nil and { dirty[0].left, dirty[0].top, dirty[0].right, dirty[0].bottom } or "all"
        if dirty ~= nil and opts.whole then dirty[0].left, dirty[0].top, dirty[0].right, dirty[0].bottom = 0, 0, W, H end
        buffer[0].width, buffer[0].height, buffer[0].stride = W, H, W
        buffer[0].format = opts.format or ffi.C.WINDOW_FORMAT_RGBA_8888
        buffer[0].bits = mem
        return 0
    end
    android.lib.ANativeWindow_unlockAndPost = function() win.posts = win.posts + 1 end
    -- KOReader's own post: the whole screen (framebuffer_android's _updateWindow)
    fb._updateWindow = function(self)
        self.full = self.full + 1
        local wb = BB.new(W, H, BB.TYPE_BBRGB32, mem, W * 4, W)
        wb:setInverse(self.bb:getInverse()); wb:setRotation(self.bb:getRotation())
        if wb:getInverse() == 1 then wb:invertblitFrom(self.bb) else wb:blitFrom(self.bb) end
    end
    fb.refreshFastImp = function(self, x, y, w, h) self:_updateWindow() end
    fb.refreshUIImp = function(self, x, y, w, h) self:_updateWindow() end
    fb.refreshFullImp = function(self) self:_updateWindow() end
    return fb, win, android
end

-- the window's pixels, and what KOReader's whole-screen copy would make of them
local function windowBytes(win, W, H) return ffi.string(win.mem, W * H * 4) end
local function reference(fb, W, H)
    local mem = ffi.new("uint32_t[?]", W * H)
    local wb = BB.new(W, H, BB.TYPE_BBRGB32, mem, W * 4, W)
    wb:setInverse(fb.bb:getInverse()); wb:setRotation(fb.bb:getRotation())
    if wb:getInverse() == 1 then wb:invertblitFrom(fb.bb) else wb:blitFrom(fb.bb) end
    return mem
end

for _i, case in ipairs({ { 0, false }, { 1, false }, { 2, false }, { 3, false }, { 0, true }, { 1, true } }) do
    local rot, inv = case[1], case[2]
    local tag = string.format("window rot %d%s", rot, inv and " inverted" or "")
    AndroidWindow.reset()
    local W, H = 600, 800
    local fb, win, android = screenAndWindow(W, H, rot, inv)
    local deps = { android = android, ffi = ffi, BB = BB }
    ok(AndroidWindow.acquire(fb, deps), tag .. ": on")
    -- a refresh of a rect in the screen's own coordinates
    local x, y, w, h = 37, 91, 120, 45
    fb:refreshFastImp(x, y, w, h)
    ok(fb.full == 0 and win.posts == 1, tag .. ": the rect alone is posted (" .. fb.full .. " whole, " .. win.posts .. " posts)")
    local px, py, pw, ph = fb.bb:getPhysicalRect(x, y, w, h)
    local l = win.locks[1]
    ok(type(l) == "table" and l[1] == px and l[2] == py and l[3] == px + pw and l[4] == py + ph,
        tag .. ": the window is locked for that rect, in its own coordinates")
    -- inside it, what the whole copy would put; outside, nothing touched
    local ref = reference(fb, W, H)
    local inside, outside = true, true
    for yy = 0, H - 1 do
        for xx = 0, W - 1 do
            local i = yy * W + xx
            local inr = xx >= px and xx < px + pw and yy >= py and yy < py + ph
            if inr and win.mem[i] ~= ref[i] then inside = false end
            if not inr and win.mem[i] ~= 0 then outside = false end
        end
    end
    ok(inside, tag .. ": the rect's pixels are the whole copy's")
    ok(outside, tag .. ": nothing outside it is written")
    -- the logical rect back from the window's
    local lx, ly, lw, lh = AndroidWindow.logicalRect(fb.bb, px, py, pw, ph)
    ok(lx == x and ly == y and lw == w and lh == h, tag .. ": the window's rect maps back to the screen's")
    AndroidWindow.release()
end

do
    AndroidWindow.reset()
    local W, H = 300, 400
    -- Android cannot keep the frame before: all of it is asked for, and all of it posted
    local fb, win, android = screenAndWindow(W, H, 0, false, { whole = true })
    AndroidWindow.acquire(fb, { android = android, ffi = ffi, BB = BB })
    fb:refreshFastImp(10, 10, 20, 20)
    ok(fb.full == 0 and windowBytes(win, W, H) == ffi.string(reference(fb, W, H), W * H * 4),
        "window: Android asks for all of it, all of it is copied")
    -- a refresh with no rect (a full one): KOReader's own post
    fb:refreshFullImp()
    ok(fb.full == 1, "window: a full refresh posts as before")
    -- released: every refresh posts as before
    AndroidWindow.release()
    fb:refreshFastImp(10, 10, 20, 20)
    ok(fb.full == 2 and not AndroidWindow.active(), "window: released, the whole screen again")
    -- a 16-bit window: unlocked, then KOReader's own post
    AndroidWindow.reset()
    fb, win, android = screenAndWindow(W, H, 0, false, { format = ffi.C.WINDOW_FORMAT_RGB_565 })
    AndroidWindow.acquire(fb, { android = android, ffi = ffi, BB = BB })
    fb:refreshFastImp(10, 10, 20, 20)
    ok(fb.full == 1 and win.posts == 1, "window: a 16-bit window gets KOReader's own post")
    -- a lock that fails: KOReader's own post
    AndroidWindow.reset()
    fb, win, android = screenAndWindow(W, H, 0, false, { fail = true })
    AndroidWindow.acquire(fb, { android = android, ffi = ffi, BB = BB })
    fb:refreshFastImp(10, 10, 20, 20)
    ok(fb.full == 1, "window: a failed lock gets KOReader's own post")
    -- an error: off for the session, KOReader's post
    AndroidWindow.reset()
    fb, win, android = screenAndWindow(W, H, 0, false)
    android.lib.ANativeWindow_lock = function() error("boom") end
    local warned = false
    AndroidWindow.acquire(fb, { android = android, ffi = ffi, BB = BB, log = function() warned = true end })
    fb:refreshFastImp(10, 10, 20, 20)
    ok(fb.full == 1 and warned and not AndroidWindow.active(), "window: an error turns it off, as before")
    -- not KOReader on Android: never on
    AndroidWindow.reset()
    ok(not AndroidWindow.acquire({ refreshFastImp = function() end }, { android = {}, ffi = ffi, BB = BB }),
        "window: not on without Android's window calls")
    -- another plugin's wrapper on the same refresh stays in the chain
    AndroidWindow.reset()
    fb, win, android = screenAndWindow(W, H, 0, false)
    local other = 0
    local inner = fb.refreshFastImp
    fb.refreshFastImp = function(self, ...) other = other + 1; return inner(self, ...) end
    AndroidWindow.acquire(fb, { android = android, ffi = ffi, BB = BB })
    AndroidWindow.release()
    fb:refreshFastImp(10, 10, 20, 20)
    ok(other == 1 and fb.full == 1, "window: another plugin's wrapper still runs, off it passes through")
end

------------------------------------------------------------------------------
-- The pen layer through a fake JNI
------------------------------------------------------------------------------
local BooxInk = require("ink/booxink")

local function fakeJni(opts)
    opts = opts or {}
    local log = {}
    local pending = false
    local ids = { setScreenHandWritingPenState = 11, setScreenHandWritingRegionLimit = 12,
        setScreenHandWritingRegionExclude = 13, setStrokeWidth = 21, setStrokeColor = 22, setStrokeStyle = 23,
        enablePost = 31, handwritingRepaint = 32 }
    for _i, k in ipairs(opts.missing or {}) do ids[k] = nil end
    local arrays = {}
    local env
    local funcs = {
        ExceptionCheck = function() return pending and 1 or 0 end,
        ExceptionClear = function() pending = false end,
        FindClass = function(_e, name)
            if name == "android/view/View" then return ffi.cast("void*", 100) end
            return nil
        end,
        NewGlobalRef = function(_e, o) return o end,
        DeleteLocalRef = function() end,
        GetMethodID = function(_e, _c, name) local id = ids[name]; if not id then pending = true; return nil end; return ffi.cast("void*", id) end,
        GetStaticMethodID = function(_e, _c, name) local id = ids[name]; if not id then pending = true; return nil end; return ffi.cast("void*", id) end,
        NewIntArray = function(_e, n) arrays[#arrays + 1] = { n = n }; return ffi.cast("void*", 1000 + #arrays) end,
        SetIntArrayRegion = function(_e, p, _s, n, buf)
            local a = arrays[tonumber(ffi.cast("intptr_t", p)) - 1000]
            for i = 0, n - 1 do a[i + 1] = buf[i] end
        end,
        CallVoidMethodA = function(_e, _o, mid, args)
            local id = tonumber(ffi.cast("intptr_t", mid))
            if opts.throw == id then pending = true end
            if id == 11 then log[#log + 1] = { "state", args[0].i }
            else log[#log + 1] = { id == 12 and "limit" or "exclude", arrays[#arrays] } end
        end,
        CallStaticVoidMethodA = function(_e, _c, mid, args)
            local id = tonumber(ffi.cast("intptr_t", mid))
            if id == 21 then log[#log + 1] = { "width", args[0].f }
            elseif id == 22 then log[#log + 1] = { "color", args[0].i }
            elseif id == 23 then log[#log + 1] = { "style", args[0].i }
            elseif id == 31 then log[#log + 1] = { "post", args[0].i }
            else log[#log + 1] = { "repaint", args[1].i, args[2].i, args[3].i, args[4].i } end
        end,
    }
    env = { [0] = funcs }
    local jni = { env = env }
    function jni:callObjectMethod(_o, name)
        if name == "getWindow" then return ffi.cast("void*", 200) end
        if name == "getDecorView" then
            if opts.no_view then return nil end
            return ffi.cast("void*", 300)
        end
    end
    local android = { app = { activity = { vm = 1, clazz = ffi.cast("void*", 1) } },
        jni = { context = function(_self, _vm, fn) return fn(jni) end } }
    return android, log
end

do
    local android, log = fakeJni()
    local c = BooxInk.new(android, ffi)
    ok(c.ok and c:usable(), "pen layer: found on a Boox")
    ok(c:setPenState(2) and log[#log][1] == "state" and log[#log][2] == 2, "pen layer: the pen state")
    ok(c:setRegion({ { x = 10, y = 20, w = 300, h = 400 } }, { { x = 250, y = 360, w = 40, h = 40 } }), "pen layer: the area")
    local lim, exc = log[#log - 1], log[#log]
    ok(lim[1] == "limit" and lim[2][1] == 10 and lim[2][2] == 20 and lim[2][3] == 310 and lim[2][4] == 420,
        "pen layer: the area as left, top, right, bottom")
    ok(exc[1] == "exclude" and exc[2][1] == 250 and exc[2][4] == 400, "pen layer: and what is left out of it")
    ok(c:setStroke(4.5, -16777216, 0), "pen layer: the stroke's look")
    local w = log[#log - 2]
    ok(w[1] == "width" and math.abs(w[2] - 4.5) < 1e-6 and log[#log - 1][2] == -16777216, "pen layer: width and black")
    -- missing methods: not found
    android = fakeJni({ missing = { "setScreenHandWritingPenState" } })
    ok(not BooxInk.new(android, ffi).ok, "pen layer: not on a Boox without it")
    android = fakeJni({ no_view = true })
    ok(not BooxInk.new(android, ffi).ok, "pen layer: not without the window's view")
    -- no stroke methods: still on, the stroke's look the firmware's own
    android, log = fakeJni({ missing = { "setStrokeWidth" } })
    c = BooxInk.new(android, ffi)
    ok(c.ok and c:setStroke(3, 0, 0) and #log == 0, "pen layer: no stroke calls, the firmware's own look")
    -- a Java exception: cleared, and the layer off
    android, log = fakeJni({ throw = 11 })
    local warned
    c = BooxInk.new(android, ffi, function() warned = true end)
    ok(not c:setPenState(2) and not c:usable() and warned, "pen layer: a Java exception turns it off")
    ok(not c:setPenState(1) and #log == 3 and log[2][1] == "post" and log[3][2] == 0,
        "pen layer: cleanup unlocks posts, then nothing more is sent")
    -- not Android
    ok(not BooxInk.new({}, ffi).ok, "pen layer: nothing without Android")
end

------------------------------------------------------------------------------
-- The drive
------------------------------------------------------------------------------
local BooxDrive = require("ink/booxdrive")

local function fakeClient()
    local c = { ok = true, sent = {}, broken = false }
    function c:usable() return not self.broken end
    function c:setPenState(n) self.sent[#self.sent + 1] = "state " .. n; return true end
    function c:setPosting(enabled) self.posts = enabled; return true end
    function c:setRegion(l, e) self.sent[#self.sent + 1] = "region " .. #l .. "/" .. #(e or {}); return true end
    function c:setStroke(w) self.sent[#self.sent + 1] = "stroke " .. w; return true end
    return c
end

do
    BooxDrive.reset()
    local c = fakeClient()
    local d = BooxDrive.new(c)
    local want = { limit = { { x = 0, y = 0, w = 100, h = 100 } }, exclude = {}, width = 3 }
    ok(d:apply(want) and table.concat(c.sent, ",") == "stroke 3,region 1/0,state 1,state 2", "drive: on, in order")
    c.sent = {}
    ok(d:apply(want) and #c.sent == 0, "drive: asked again, nothing sent")
    ok(not d:apply(nil) and table.concat(c.sent, ",") == "state 3", "drive: paused")
    c.sent = {}
    ok(not d:apply(nil) and #c.sent == 0, "drive: paused again, nothing sent")
    want.width = 5
    ok(d:apply(want) and table.concat(c.sent, ",") == "stroke 5,state 2", "drive: a new width and back on")
    c.sent = {}
    d:stop()
    ok(table.concat(c.sent, ",") == "state 0,region 0/0", "drive: stopped, the area forgotten")
    -- views in order
    BooxDrive.reset()
    local a, b = { updates = 0 }, { updates = 0 }
    function a:booxInkUpdate() self.updates = self.updates + 1 end
    function b:booxInkUpdate() self.updates = self.updates + 1 end
    c = fakeClient()
    BooxDrive.join(a, c)
    BooxDrive.join(b, c)
    ok(BooxDrive.holder() == b and not BooxDrive.want(a, want) and BooxDrive.want(b, want), "drive: the newest view decides")
    BooxDrive.leave(b)
    ok(BooxDrive.holder() == a and a.updates == 1, "drive: when it closes, the one under it asks again")
    c.sent = {}
    BooxDrive.leave(a)
    ok(c.sent[1] == "state 0", "drive: no view left, it stops")
end

------------------------------------------------------------------------------
-- The view
------------------------------------------------------------------------------
local function world(client)
    local W, H = 1404, 1872
    Device.screen.bb = BB.new(W, H, BB.TYPE_BBRGB32)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return false end
    Device.isAndroid = function() return true end
    Device.input.wacom_protocol = false
    UIManager.reset()
    BooxDrive.reset()
    if client then BooxDrive.client(function() return client end, true) end
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    -- The tool/colour checks below model an actual contact. Idle views now keep
    -- the panel released, and the input-specific suite checks that transition.
    view.palm_reject, view._boox_contact = true, true
    view:booxInkUpdate()
    return view
end
-- (what a paint does first: the mock toolbar cannot paint itself)
local function paint(view) view:booxInkUpdate() end
local function last(c) return c.sent[#c.sent] end

do
    -- without KOReader's android module (here, and on every other device): nothing at all
    local view = world(nil)
    ok(view:onAndroid() and not view._boox_ink and not view._android_window, "view: no pen layer, no window posts without the android module")
    view:onCloseWidget()

    local c = fakeClient()
    view = world(c)
    ok(view._boox_ink and view:booxInking(), "view: the pen inks with the pen tool")
    ok(c.sent[1]:find("^stroke") and c.sent[2]:find("^region 1/") and c.sent[#c.sent] == "state 2", "view: its look, its area, then on")
    -- every paint asks first (a change of tool, pen or layout paints)
    local asked = 0
    local real = view.booxInkUpdate
    view.booxInkUpdate = function(self) asked = asked + 1; return real(self) end
    pcall(view.paintTo, view, Device.screen.bb, 0, 0)
    view.capturing = true
    pcall(view.paintTo, view, Device.screen.bb, 0, 0)
    view.capturing = false
    view.booxInkUpdate = nil
    ok(asked == 1, "view: a paint asks what the firmware may ink, not while a stroke is drawn")
    -- the eraser, the lasso: paused; the pen again: on
    view:setTool("erase"); paint(view)
    ok(last(c) == "state 3" and not view:booxInking(), "view: the eraser pauses it")
    view:setTool("lasso"); paint(view)
    ok(last(c) == "state 3", "view: so does the lasso")
    view:setTool("pen"); paint(view)
    ok(last(c) == "state 2", "view: the pen again")
    -- a see-through pen, a light pen, night mode: paused
    view.pen_alpha = 120; paint(view)
    ok(last(c) == "state 3", "view: a see-through pen pauses it")
    view.pen_alpha = 255; view.pen_color = { 250, 240, 90 }; paint(view)
    ok(last(c) == "state 3", "view: a light pen pauses it")
    view.pen_color = { 20, 40, 160 }; paint(view)
    ok(last(c) == "state 2", "view: a dark coloured pen inks (black, then its colour at the lift)")
    Device.screen.night_mode = true; paint(view)
    ok(last(c) == "state 3", "view: night mode pauses it")
    Device.screen.night_mode = false; paint(view)
    -- A menu ends a contact; closing it must not lock ordinary posts while idle.
    local sheet = { name = "a sheet" }
    UIManager:show(sheet)
    ok(last(c) == "state 3", "view: a sheet shown pauses it at once")
    UIManager:close(sheet)
    UIManager.fireScheduled()
    ok(not view:booxInking() and c.posts, "view: closed, prepares capture with ordinary posts open")
    view:booxInkContact()
    local toast = { toast = true }
    local n = #c.sent
    UIManager:show(toast)
    ok(#c.sent == n, "view: a passing toast changes nothing")
    UIManager:close(toast); UIManager.fireScheduled()
    -- the area: the drawing area, without the floating buttons
    local v = view.view
    local want = view:booxInkWant()
    ok(want and want.limit[1].x == v.area_x and want.limit[1].w == v.area_w and #want.exclude >= 1,
        "view: the area is the drawing area, its floating buttons left out")
    -- a pen stroke the firmware inks: no live refresh, one at the lift
    UIManager.refreshes = {}
    view._pen_started = true
    view:feedPen("down", 400, 600)
    for k = 1, 30 do view:feedPen("move", 400 + k * 6, 600 + k * 2) end
    local during = #UIManager.refreshes
    view:feedPen("up", 580, 660)
    view:flushPending()
    view._pen_started = false
    local covered = false
    for _i, r in ipairs(UIManager.refreshes) do
        local g = r.region
        if g and g.x <= 400 and g.x + g.w >= 580 and g.y <= 600 and g.y + g.h >= 660 then covered = true end
    end
    ok(during == 0, "view: no live refresh while the firmware inks (" .. during .. ")")
    ok(covered, "view: the stroke as drawn shown once at the lift")
    ok(#view.canvas.ops >= 1, "view: and kept")
    -- a finger stroke: live refreshes as before
    view.palm_reject, view._boox_contact = false, nil
    paint(view)
    UIManager.refreshes = {}
    view:onIaTouch(nil, { pos = { x = 300, y = 900 } })
    local t0 = (view._live_last or 0) + 1000
    for k = 1, 20 do view.nowMs = function() return t0 + k * 100 end; view:onIaPan(nil, { pos = { x = 300 + k * 8, y = 900 } }) end
    ok(#UIManager.refreshes > 0, "view: a finger stroke keeps its live refreshes")
    view:onIaPanRelease(nil, { pos = { x = 460, y = 900 } }); view:flushPending()
    view.palm_reject, view._boox_contact = true, true
    paint(view)
    -- a pen tap where the firmware may have inked: that part shown again
    UIManager.refreshes = {}
    view._hw_box = { x0 = 700, y0 = 700, x1 = 720, y1 = 720 }
    view:booxInkSweep()
    local r = UIManager.refreshes[#UIManager.refreshes]
    ok(r and r.region and r.region.x == 700 and r.region.w == 20, "view: a pen contact's spot shown again at the lift")
    -- the setting off: stops; on: inks again
    c.sent = {}
    view:stopBooxInk()
    ok(c.sent[1] == "state 0" and not view._boox_ink, "view: turned off, it stops")
    view:startBooxInk()
    ok(not view:booxInking(), "view: turned on, waits for a fresh contact")
    view:booxInkContact()
    -- sleep: stops; wake: again
    view:onSuspend()
    ok(not view._boox_ink and last(c) == "region 0/0", "view: asleep, stopped")
    view:onResume()
    ok(not view:booxInking(), "view: awake, the panel stays released until a new pen contact")
    view._boox_contact = true; paint(view)
    ok(view:booxInking(), "view: a fresh contact resumes native ink after wake")
    -- closing: stops
    c.sent = {}
    view:onCloseWidget()
    ok(c.sent[1] == "state 0", "view: closed, stopped")
    -- a broken layer: nothing more is sent, and the pen draws as before
    c = fakeClient()
    view = world(c)
    c.broken = true
    c.sent = {}
    view:setTool("erase"); paint(view); view:setTool("pen"); paint(view)
    ok(#c.sent == 0 and not view:booxInking(), "view: a broken layer sends nothing")
    view:onCloseWidget()
end

Device.isAndroid = nil
print(("boox: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
