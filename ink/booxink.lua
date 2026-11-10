--[[
The Boox pen layer, reached from Lua: the Onyx firmware draws the pen's ink on
the e-ink itself, straight from the pen, while the app is told where it may
(the way Boox's own notes app writes, and Onyx's pen kit for apps). Ink Away
then draws the stroke as it really is once the pen lifts (see ink/booxdrive.lua).

These are methods Onyx adds to Android's View class, not part of Android: KOReader
calls two of them the same way for its own Boox refreshes. They are found once,
by name and signature, through KOReader's JNI helper; on any other device, or a
Boox without them, `available()` is false and nothing is ever called. A Java
exception from any call clears it and turns the layer off for the session.

  * setScreenHandWritingPenState(int)        0 stop, 1 start, 2 drawing, 3 paused
  * setScreenHandWritingRegionLimit(View, int[])    where the pen inks: l, t, r, b, ...
  * setScreenHandWritingRegionExclude(View, int[])  where it does not, inside that
  * static setStrokeWidth(float), setStrokeColor(int), setStrokeStyle(int)

Signatures as Onyx's own SDK looks them up (onyxsdk-device, SDMDevice). The JNI
helper attaches the thread for each call, so method IDs and the window's view are
kept as global references.
]]

local BooxInk = {}

BooxInk.STOP, BooxInk.START, BooxInk.DRAWING, BooxInk.PAUSED = 0, 1, 2, 3

local VIEW = "android/view/View"
-- (the static stroke methods: on View on the Onyx firmwares seen, on its helper class on others)
local HELPER = "android/onyx/ViewUpdateHelper"

-- A client for the pen layer. `android` is KOReader's android module (required
-- when not given), `ffi` LuaJIT's. Returns the client; client.ok says whether the
-- firmware has the layer.
function BooxInk.new(android, ffi, log)
    local self = { ok = false, broken = false, log = log, calls = 0 }
    if not android then
        local okr, m = pcall(require, "android")
        android = okr and m or nil
    end
    ffi = ffi or require("ffi")
    if not (android and android.jni and android.app and android.app.activity) then return setmetatable(self, { __index = BooxInk }) end
    self.android, self.ffi = android, ffi
    setmetatable(self, { __index = BooxInk })
    local ok, err = pcall(self.probe, self)
    if not ok then
        self.ok = false
        if log then log("Ink Away: Boox pen layer not found:", err) end
    end
    return self
end

-- Run fn(env) with the thread attached; a pending Java exception is cleared and
-- reported as false.
function BooxInk:withEnv(fn)
    local android = self.android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local r1, r2 = fn(env, jni)
        if env[0].ExceptionCheck(env) ~= 0 then
            env[0].ExceptionClear(env)
            return false, "a Java exception"
        end
        return r1, r2
    end)
end

-- Find the methods and the window's view (once).
function BooxInk:probe()
    local found = self:withEnv(function(env, jni)
        local function clear()
            if env[0].ExceptionCheck(env) ~= 0 then env[0].ExceptionClear(env) end
        end
        local function class(name)
            local c = env[0].FindClass(env, name)
            clear()
            if c == nil then return nil end
            local g = env[0].NewGlobalRef(env, c)
            env[0].DeleteLocalRef(env, c)
            return g
        end
        local function method(cls, name, sig)
            if cls == nil then return nil end
            local m = env[0].GetMethodID(env, cls, name, sig)
            clear()
            return m ~= nil and m or nil
        end
        local function static(cls, name, sig)
            if cls == nil then return nil end
            local m = env[0].GetStaticMethodID(env, cls, name, sig)
            clear()
            return m ~= nil and m or nil
        end
        local view_cls = class(VIEW)
        if view_cls == nil then return false end
        self.pen_state = method(view_cls, "setScreenHandWritingPenState", "(I)V")
        self.region_limit = method(view_cls, "setScreenHandWritingRegionLimit", "(Landroid/view/View;[I)V")
        self.region_exclude = method(view_cls, "setScreenHandWritingRegionExclude", "(Landroid/view/View;[I)V")
        if not (self.pen_state and self.region_limit) then return false end
        -- the stroke's look, where the firmware has it
        for _i, cls in ipairs({ view_cls, class(HELPER) }) do
            local w = static(cls, "setStrokeWidth", "(F)V")
            if w then
                self.width_cls, self.stroke_width = cls, w
                self.stroke_color = static(cls, "setStrokeColor", "(I)V")
                self.stroke_style = static(cls, "setStrokeStyle", "(I)V")
                break
            end
        end
        -- the window's view: the pen inks where it is told, in its coordinates (the screen's)
        local activity = self.android.app.activity.clazz
        local window = jni:callObjectMethod(activity, "getWindow", "()Landroid/view/Window;")
        clear()
        if window == nil then return false end
        local decor = jni:callObjectMethod(window, "getDecorView", "()Landroid/view/View;")
        clear()
        env[0].DeleteLocalRef(env, window)
        if decor == nil then return false end
        self.view = env[0].NewGlobalRef(env, decor)
        env[0].DeleteLocalRef(env, decor)
        self.view_cls = view_cls
        return true
    end)
    self.ok = found == true
    return self.ok
end

-- Call `fn(env, args)` for the layer; false (and the layer off for the session)
-- if it fails.
function BooxInk:call(fn)
    if not self.ok or self.broken then return false end
    local ok, r, why = pcall(self.withEnv, self, fn)
    if not ok or r == false then
        self.broken = true
        if self.log then self.log("Ink Away: Boox pen layer off:", ok and why or r) end
        return false
    end
    self.calls = self.calls + 1
    return true
end

-- The pen layer's state: BooxInk.STOP, START, DRAWING or PAUSED.
function BooxInk:setPenState(n)
    local ffi = self.ffi
    return self:call(function(env)
        local a = ffi.new("jvalue[1]")
        a[0].i = n
        env[0].CallVoidMethodA(env, self.view, self.pen_state, a)
        return true
    end)
end

local function intArray(env, ffi, list)
    local n = #list
    local arr = env[0].NewIntArray(env, n)
    if arr == nil then return nil end
    if n > 0 then
        local buf = ffi.new("int32_t[?]", n)
        for i = 1, n do buf[i - 1] = math.floor(list[i] + 0.5) end
        env[0].SetIntArrayRegion(env, arr, 0, n, buf)
    end
    return arr
end

local function flatten(rects)
    local out = {}
    for _i, r in ipairs(rects or {}) do
        out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] = r.x, r.y, r.x + r.w, r.y + r.h
    end
    return out
end

-- Where the pen inks: `limit` and `exclude` are lists of screen rects { x, y, w, h }.
function BooxInk:setRegion(limit, exclude)
    local ffi = self.ffi
    return self:call(function(env)
        local function send(mid, rects)
            if not mid then return true end
            local arr = intArray(env, ffi, flatten(rects))
            if arr == nil then return false end
            local a = ffi.new("jvalue[2]")
            a[0].l = self.view
            a[1].l = arr
            env[0].CallVoidMethodA(env, self.view, mid, a)
            env[0].DeleteLocalRef(env, arr)
            return true
        end
        return send(self.region_limit, limit) and send(self.region_exclude, exclude or {})
    end)
end

-- The ink's look while the pen moves: its width in screen pixels, its colour
-- (0xAARRGGBB) and style (0 even, 1 following pressure). Where the firmware has
-- no such call the ink keeps its own.
function BooxInk:setStroke(width, color, style)
    if not self.stroke_width then return true end
    local ffi = self.ffi
    return self:call(function(env)
        local a = ffi.new("jvalue[1]")
        a[0].f = width
        env[0].CallStaticVoidMethodA(env, self.width_cls, self.stroke_width, a)
        if self.stroke_color then
            a[0].i = color
            env[0].CallStaticVoidMethodA(env, self.width_cls, self.stroke_color, a)
        end
        if self.stroke_style then
            a[0].i = style or 0
            env[0].CallStaticVoidMethodA(env, self.width_cls, self.stroke_style, a)
        end
        return true
    end)
end

-- Can it ink (found, and nothing has failed)?
function BooxInk:usable()
    return self.ok and not self.broken
end

return BooxInk
