-- Firmware JNI contracts, without the KOReader emulator: luajit tests/booxink.lua
package.path = "./?.lua;" .. package.path
local ffi = require("ffi")
pcall(ffi.cdef, [[
typedef union jvalue { uint8_t z; int8_t b; uint16_t c; int16_t s;
    int32_t i; int64_t j; float f; double d; void* l; } jvalue;
]])
local BooxInk = require("ink/booxink")
local BooxDrive = require("ink/booxdrive")
local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- Only exact class/signature/calling-convention matches yield a method ID.
local function firmware(opts)
    opts = opts or {}
    local view, helper, decor = 100, 101, 300
    local methods, arrays, calls, logs = {}, {}, {}, {}
    local pending, clears = false, 0
    local function pointer(n) return ffi.cast("void*", n) end
    local function number(p) return tonumber(ffi.cast("intptr_t", p)) end
    local signatures = {
        setScreenHandWritingPenState = "(I)V",
        setScreenHandWritingRegionLimit = "(Landroid/view/View;[I)V",
        setScreenHandWritingRegionExclude = "(Landroid/view/View;[I)V",
        setStrokeWidth = "(F)V", setStrokeColor = "(I)V", setStrokeStyle = "(I)V",
        enablePost = "(I)V", handwritingRepaint = "(Landroid/view/View;IIII)V",
    }
    local function register(cls, static, name)
        if opts.missing == name then return end
        methods[#methods + 1] = { cls = cls, static = static, name = name,
            sig = opts.wrong_signature == name and "(J)V" or signatures[name] }
    end
    for _, backend in ipairs({ "view", "helper" }) do
        if opts.backend == backend or opts.backend == "both" then
            for _, name in ipairs({ "setScreenHandWritingPenState", "setScreenHandWritingRegionLimit",
                    "setScreenHandWritingRegionExclude" }) do
                register(backend == "view" and view or helper, backend == "helper", name)
            end
        end
    end
    for _, name in ipairs({ "setStrokeWidth", "setStrokeColor", "setStrokeStyle" }) do
        register(opts.stroke_helper and helper or view, true, name)
    end
    for _, name in ipairs({ "enablePost", "handwritingRepaint" }) do
        register(opts.backend == "helper" and helper or view, true, name)
    end
    local function lookup(cls, static, name, sig)
        assert(not pending, "lookup with pending Java exception")
        for id, m in ipairs(methods) do
            if m.cls == number(cls) and m.static == static and m.name == name and m.sig == sig then
                return pointer(id)
            end
        end
        pending = true
        return nil
    end
    local function invoke(target, static, mid, args)
        assert(not pending, "call with pending Java exception")
        local m = assert(methods[number(mid)], "invalid method ID")
        assert(m.static == static, "wrong JNI calling convention")
        assert(number(target) == (static and m.cls or decor), "wrong JNI receiver/class")
        local call = { name = m.name, static = static, cls = m.cls }
        if m.name == "handwritingRepaint" then
            assert(number(args[0].l) == decor, "repaint must refer to decor view")
            call.value = { args[1].i, args[2].i, args[3].i, args[4].i }
        elseif m.name:find("Region") then
            assert(number(args[0].l) == decor, "region must refer to decor view")
            call.value = arrays[number(args[1].l)]
        elseif m.name == "setStrokeWidth" then call.value = args[0].f
        else call.value = args[0].i end
        calls[#calls + 1] = call
        if opts.throw == m.name then pending = true end
    end
    local env = { [0] = {
        ExceptionCheck = function() return pending and 1 or 0 end,
        ExceptionClear = function() pending = false; clears = clears + 1 end,
        FindClass = function(_e, name)
            assert(not pending, "FindClass with pending Java exception")
            if name == "android/view/View" then return pointer(view) end
            if name == "android/onyx/ViewUpdateHelper" and opts.helper ~= false then return pointer(helper) end
            pending = true
            return nil
        end,
        NewGlobalRef = function(_e, p) return p end,
        DeleteLocalRef = function() end,
        GetMethodID = function(_e, cls, name, sig) return lookup(cls, false, name, sig) end,
        GetStaticMethodID = function(_e, cls, name, sig) return lookup(cls, true, name, sig) end,
        NewIntArray = function(_e, n)
            if opts.no_array then return nil end
            arrays[#arrays + 1] = { n = n }
            return pointer(#arrays)
        end,
        SetIntArrayRegion = function(_e, arr, _start, n, buf)
            local a = arrays[number(arr)]
            for i = 0, n - 1 do a[i + 1] = buf[i] end
        end,
        CallVoidMethodA = function(_e, target, mid, args) invoke(target, false, mid, args) end,
        CallStaticVoidMethodA = function(_e, target, mid, args) invoke(target, true, mid, args) end,
    } }
    local jni = { env = env }
    function jni:callObjectMethod(_object, name, signature)
        assert(not pending, "object call with pending Java exception")
        if name == "getWindow" then
            assert(signature == "()Landroid/view/Window;")
            return pointer(200)
        end
        assert(name == "getDecorView" and signature == "()Landroid/view/View;")
        return not opts.no_view and pointer(decor) or nil
    end
    local android = { app = { activity = { vm = 1, clazz = pointer(1) } },
        jni = { context = function(_self, _vm, fn) return fn(jni) end } }
    local c = BooxInk.new(android, ffi, function(...)
        local s = {}
        for i = 1, select("#", ...) do s[i] = tostring(select(i, ...)) end
        logs[#logs + 1] = table.concat(s, " ")
    end)
    return c, calls, logs, function() return pending, clears end
end

for _, backend in ipairs({ "view", "helper", "both" }) do
    local c, calls, logs, status = firmware({ backend = backend, stroke_helper = backend == "helper" })
    ok(c.ok and c:usable(), backend .. ": complete firmware detected")
    ok(c.pen_static == (backend == "helper"), backend .. ": old View backend has priority")
    ok(not status(), backend .. ": lookup exceptions cleared")
    ok(c:setRegion({ { x = 10, y = 20, w = 300, h = 400 } },
        { { x = 250, y = 360, w = 40, h = 40 } }), backend .. ": regions accepted")
    ok(#calls == 2 and table.concat(calls[1].value, ",") == "10,20,310,420" and
        table.concat(calls[2].value, ",") == "250,360,290,400", backend .. ": exact region payload")
    ok(c:setStroke(4.5, -16777216, 1), backend .. ": stroke accepted")
    ok(#calls == 5 and calls[3].value == 4.5 and calls[4].value == -16777216 and
        calls[5].value == 1, backend .. ": float/int stroke arguments preserved")
    ok(c:setPenState(1) and c:setPenState(2) and c:setPenState(3) and c:setPenState(0),
        backend .. ": start/drawing/pause/stop accepted")
    ok(c.calls == 6, backend .. ": successful calls counted")
    ok(#logs == 2 and logs[1]:find("found:") and logs[2]:find("enabled:"), backend .. ": one detection/activation log")
    ok(c:setPosting(true) and calls[#calls].name == "enablePost" and calls[#calls].value == 1,
        backend .. ": capture can be prepared with ordinary posts open")
    ok(c:setPosting(false) and calls[#calls].name == "enablePost" and calls[#calls].value == 0,
        backend .. ": contact enters scribble mode using exact static post API")
end

do
    local c = firmware({ backend = "view", helper = false })
    ok(c.ok and not c.pen_static, "old firmware: no helper class required")
    c = firmware({ backend = "view", missing = "setStrokeWidth" })
    ok(c.ok and c:setStroke(3, -16777216, 0), "optional stroke API: firmware's default look")
    local calls
    c, calls = firmware({ backend = "helper", missing = "setScreenHandWritingRegionExclude" })
    ok(c.ok and c:setRegion({}, {}) and #calls == 1, "optional exclude API: only limit called")
    for _, name in ipairs({ "setScreenHandWritingPenState", "setScreenHandWritingRegionLimit" }) do
        local logs, status
        c, calls, logs, status = firmware({ backend = "helper", missing = name })
        ok(not c.ok and not c:setPenState(2) and #calls == 0 and not status(), name .. ": missing fails safely")
        ok(#logs == 1 and logs[1]:find("not found:"), name .. ": failure reason logged")
    end
    c = firmware({ backend = "helper", wrong_signature = "setScreenHandWritingPenState" })
    ok(not c.ok, "wrong method signature rejected")
    c = firmware({ backend = "helper", no_view = true })
    ok(not c.ok, "missing decor view rejected")
    c = BooxInk.new({}, ffi)
    ok(not c.ok and not c:usable(), "no Android JNI: software fallback")
end

for _, name in ipairs({ "setScreenHandWritingPenState", "setScreenHandWritingRegionLimit", "setStrokeWidth" }) do
    local c, calls, logs, status = firmware({ backend = "helper", stroke_helper = true, throw = name })
    local result
    if name == "setScreenHandWritingPenState" then result = c:setPenState(2)
    elseif name == "setScreenHandWritingRegionLimit" then result = c:setRegion({}, {})
    else result = c:setStroke(3, -16777216, 0) end
    ok(not result and c.broken and not c:usable(), name .. ": Java exception disables native ink")
    ok(not status() and #calls == 3 and calls[2].name == "enablePost" and calls[2].value == 1,
        name .. ": exception cleared, ordinary posts unlocked and native pen stopped")
    local n = #calls
    ok(not c:setPenState(2) and #calls == n, name .. ": broken client sends no more calls")
    ok(logs[#logs]:find("pen layer off:") and logs[#logs]:find("Java exception"), name .. ": exception logged")
end

do
    local c, calls = firmware({ backend = "helper", no_array = true })
    ok(not c:setRegion({}, {}) and not c:usable() and #calls == 2,
        "array allocation failure unlocks posts and stops native ink")
    c, calls = firmware({ backend = "helper", stroke_helper = true })
    local drive = BooxDrive.new(c)
    local want = { limit = { { x = 0, y = 0, w = 100, h = 200 } }, exclude = {}, width = 3 }
    ok(drive:apply(want) and drive:inking(), "helper drive: active after native calls")
    local n = #calls
    ok(drive:apply(want) and #calls == n, "helper drive: unchanged request not resent")
    ok(not drive:apply(nil) and not drive:inking(), "helper drive: pause disables live ink")
    drive:stop()
    ok(calls[#calls - 2].value == 0 and calls[#calls].value.n == 0, "helper drive: stop clears native regions")
    c = firmware({ backend = "helper", throw = "setScreenHandWritingPenState" })
    drive = BooxDrive.new(c)
    ok(not drive:apply(want) and not drive:inking(), "helper drive: failed activation keeps software drawing")
end

do
    local c, calls = firmware({ backend = "helper" })
    ok(c:repaint(10, 20, 30, 40) and table.concat(calls[1].value, ",") == "10,20,40,60",
        "handwriting repaint: static helper and exact LTRB payload")
    ok(c:setPenState(3) and calls[2].name == "enablePost" and calls[2].value == 1 and calls[3].value == 3,
        "pause unlocks normal posts before pausing pen")
    ok(c:setPenState(0) and calls[4].name == "enablePost" and calls[5].value == 0,
        "stop restores normal display updates")
    for _, missing in ipairs({ "enablePost", "handwritingRepaint" }) do
        c = firmware({ backend = "helper", missing = missing })
        ok(not c:usable(), missing .. ": unsafe incomplete firmware is not activated")
    end
    c, calls = firmware({ backend = "helper", throw = "handwritingRepaint" })
    ok(not c:repaint(1, 2, 3, 4) and not c:usable() and calls[2].name == "enablePost"
        and calls[3].value == 0, "repaint exception releases screen before software fallback")
    c, calls = firmware({ backend = "helper", throw = "enablePost" })
    ok(not c:setPosting(false) and not c:usable() and calls[#calls].name == "setScreenHandWritingPenState"
        and calls[#calls].value == 0, "post-gate exception stops native capture for software fallback")
end

-- What a firmware has, by name, for the report when the search failed.
do
    local pending = false
    local names = { ["android/view/View"] = { "invalidate", "enablePost", "getWidth" },
        ["android/onyx/ViewUpdateHelper"] = { "setScreenHandWritingPenState", "refreshScreen", "handwritingRepaint", "setStrokeWidth", "boom" } }
    local classes, arrays, deleted = {}, {}, 0
    local function pointer(n) return ffi.cast("void*", n) end
    local function number(p) return tonumber(ffi.cast("intptr_t", p)) end
    local objs = {}
    local function obj(v) objs[#objs + 1] = v; return pointer(#objs) end
    local env = { [0] = {
        ExceptionCheck = function() return pending and 1 or 0 end,
        ExceptionClear = function() pending = false end,
        FindClass = function(_e, n)
            assert(not pending, "FindClass with a pending exception")
            if names[n] then classes[#classes + 1] = n; return obj({ class = n }) end
            pending = true
            return nil
        end,
        GetArrayLength = function(_e, a) return #objs[number(a)].list end,
        GetObjectArrayElement = function(_e, a, k) return obj({ name = objs[number(a)].list[k + 1] }) end,
        DeleteLocalRef = function() deleted = deleted + 1 end,
    } }
    local jni = { env = env }
    function jni:callObjectMethod(o, method)
        assert(not pending, "call with a pending exception")
        local v = objs[number(o)]
        if method == "getMethods" then return obj({ list = names[v.class] }) end
        assert(method == "getName")
        if v.name == "boom" then pending = true; return nil end
        return obj({ str = v.name })
    end
    function jni:to_string(js) return objs[number(js)].str end
    local c = setmetatable({ android = { app = { activity = { vm = 1 } },
        jni = { context = function(_s, _vm, fn) return fn(jni) end } } }, { __index = BooxInk })
    local seen = table.concat(c:surveyMethods(), " ")
    ok(seen == "View.enablePost ViewUpdateHelper.setScreenHandWritingPenState ViewUpdateHelper.handwritingRepaint ViewUpdateHelper.setStrokeWidth",
        "survey: the pen calls by name, on both classes: " .. seen)
    ok(not pending, "survey: a Java exception on the way is cleared")
    ok(deleted > 10, "survey: its references are let go, there may be a thousand")
    ok(#BooxInk.surveyMethods({}) == 0, "survey: nothing without Android")
    local f = firmware({ backend = "view", missing = "handwritingRepaint" })
    ok(not f.ok and f.why:find("repaint", 1, true), "the reason it wasn't found is kept for the pen test")
end

print(("booxink: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
