--[[
Binder client for the Supernote (Ratta A5X2 family -- Nomad/Manta) firmware's
stylus ink daemon.

On these devices, the vendor firmware renders EMR pen strokes to its own EPDC
overlay at far lower latency than KOReader's normal repaint cycle can manage.
It exposes that renderer to any app via a system Binder service rather than a
public Android API, so talking to it means driving raw Binder transactions
ourselves: look up the service, build a `Parcel` with an interface token and a
small integer payload, and call `transact()` through JNI. None of this needs
koreader-base or launcher changes -- the `android.jni` helper already bundled
with KOReader's Android build is enough.

The service name, interface token and transaction codes below aren't
documented anywhere; they were recovered by reverse-engineering Supernote's
own Document app (see plateaukao/supernote_draw for a prior write-up), the
same protocol penannotate.koplugin's lib/supernote_ink.lua uses.

The Pen and Colour codes are plain data, so ink/supernotedrive.lua can map a
pen onto them without touching JNI (see tests/supernotedrive.lua). Everything
below them needs the real JNI and is a no-op stub everywhere else: non-Android
targets (the `android` require fails) and Android devices without this
particular binder (the service lookup returns null). Safe to require
unconditionally.
]]

local SupernoteInk = {}

-- Pen shape codes for the firmware's pen table (Nomad / A5X2 deviceType=3).
SupernoteInk.Pen = {
    NEEDLE = 10, -- uniform-width ballpoint; the closest match to a plain line
    INK = 16,
    MARK = 11, -- highlighter
    CALLIGRAPHY = 15,
}

SupernoteInk.Color = {
    BLACK = 0,
    DARK_GRAY = -101,
    GRAY = -102,
    LIGHT_GRAY = 254,
}

local ok_android, android = pcall(require, "android")
if not ok_android or not android or not android.app then
    local noop = function() end
    SupernoteInk.isAvailable = function() return false end
    SupernoteInk.sendWriteAppInfo = noop
    SupernoteInk.setPen = noop
    SupernoteInk.setEraser = noop
    SupernoteInk.clearAll = noop
    SupernoteInk.setFullScreenDisable = noop
    SupernoteInk.clearDisableAreas = noop
    SupernoteInk.enableFullUiAuto = noop
    return SupernoteInk
end

local ffi = require("ffi")
local C = ffi.C
local logger = require("logger")
local JNI = android.jni

local IFACE_TOKEN = "android.demo.IMyService"
local APP_NAME = "koreader-inkaway"
local SERVICE_NAMES = { "service_myservice", "service.myservice" }

-- Binder transaction codes understood by the firmware's ink daemon.
local TX_CLAIM_OWNERSHIP = 0
local TX_DISABLE_AREA = 1
local TX_SET_PEN = 2
local TX_CLEAR_OVERLAY = 6

local binder_gref = nil
local available = nil -- tri-state: nil = untested, false/true once probed

local function newStringUTF(jni, s)
    return jni.env[0].NewStringUTF(jni.env, s)
end

local function deleteLocalRef(jni, obj)
    if obj ~= nil then
        jni.env[0].DeleteLocalRef(jni.env, obj)
    end
end

local function lookupBinder(jni)
    for _, name in ipairs(SERVICE_NAMES) do
        local jname = newStringUTF(jni, name)
        local binder = jni:callStaticObjectMethod(
            "android/os/ServiceManager", "getService",
            "(Ljava/lang/String;)Landroid/os/IBinder;", jname)
        deleteLocalRef(jni, jname)
        if binder ~= nil then
            logger.info("Ink Away: found Supernote ink binder \"" .. name .. "\"")
            local gref = jni.env[0].NewGlobalRef(jni.env, binder)
            deleteLocalRef(jni, binder)
            return gref
        end
    end
    return nil
end

local function isBinderAlive(jni)
    return binder_gref ~= nil and jni:callBooleanMethod(binder_gref, "isBinderAlive", "()Z")
end

function SupernoteInk.isAvailable()
    if available ~= nil then return available end
    JNI:context(android.app.activity.vm, function(jni)
        binder_gref = lookupBinder(jni)
        available = (binder_gref ~= nil)
    end)
    if not available then
        logger.info("Ink Away: Supernote ink binder not present, will no-op")
    end
    return available
end

-- Runs `write_payload(jni, parcel)` after the interface-token/app-name
-- preamble, then transacts and recycles both parcels.
local function transact(code, write_payload)
    if not SupernoteInk.isAvailable() then return end
    JNI:context(android.app.activity.vm, function(jni)
        if not isBinderAlive(jni) then
            binder_gref = lookupBinder(jni) -- firmware service may have restarted
            if binder_gref == nil then
                available = false
                logger.warn("Ink Away: Supernote ink binder gone, disabling")
                return
            end
        end

        local data = jni:callStaticObjectMethod("android/os/Parcel", "obtain", "()Landroid/os/Parcel;")
        local reply = jni:callStaticObjectMethod("android/os/Parcel", "obtain", "()Landroid/os/Parcel;")

        local jtoken = newStringUTF(jni, IFACE_TOKEN)
        jni:callVoidMethod(data, "writeInterfaceToken", "(Ljava/lang/String;)V", jtoken)
        deleteLocalRef(jni, jtoken)

        local japp = newStringUTF(jni, APP_NAME)
        jni:callVoidMethod(data, "writeString", "(Ljava/lang/String;)V", japp)
        deleteLocalRef(jni, japp)

        write_payload(jni, data)

        jni:callBooleanMethod(binder_gref, "transact",
            "(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z",
            ffi.new("int32_t", code), data, reply, ffi.new("int32_t", 0))

        if jni.env[0].ExceptionCheck(jni.env) == C.JNI_TRUE then
            jni.env[0].ExceptionClear(jni.env) -- e.g. DeadObjectException; next call re-looks-up
        end

        jni:callVoidMethod(data, "recycle", "()V")
        jni:callVoidMethod(reply, "recycle", "()V")
        deleteLocalRef(jni, data)
        deleteLocalRef(jni, reply)
    end)
end

local function writeInt(jni, parcel, n)
    jni:callVoidMethod(parcel, "writeInt", "(I)V", ffi.new("int32_t", n))
end

-- Claims pen ownership so the firmware routes ink to us instead of its own apps.
function SupernoteInk.sendWriteAppInfo()
    transact(TX_CLAIM_OWNERSHIP, function(jni, data)
        writeInt(jni, data, 0)
        writeInt(jni, data, 0)
    end)
end

function SupernoteInk.setPen(pen_type, size_emr, color)
    transact(TX_SET_PEN, function(jni, data)
        writeInt(jni, data, pen_type)
        writeInt(jni, data, size_emr)
        writeInt(jni, data, color)
    end)
end

function SupernoteInk.setEraser(rectangular, size_emr)
    transact(TX_SET_PEN, function(jni, data)
        writeInt(jni, data, rectangular and 3 or 1)
        writeInt(jni, data, size_emr)
        writeInt(jni, data, 255)
    end)
end

function SupernoteInk.clearAll()
    transact(TX_CLEAR_OVERLAY, function(jni, data)
        writeInt(jni, data, 255)
        writeInt(jni, data, 0)
    end)
end

function SupernoteInk.setFullScreenDisable(width, height)
    transact(TX_DISABLE_AREA, function(jni, data)
        writeInt(jni, data, 1) -- rect count
        writeInt(jni, data, 0) -- x
        writeInt(jni, data, 0) -- y
        writeInt(jni, data, width)
        writeInt(jni, data, height)
        writeInt(jni, data, 0) -- reserved
    end)
end

function SupernoteInk.clearDisableAreas()
    transact(TX_DISABLE_AREA, function(jni, data)
        writeInt(jni, data, 0) -- zero rects
    end)
end

-- Reflection on Activity.getSystemService("eink").enableFullUiAuto(boolean),
-- required so the firmware paints ink anywhere on screen rather than only
-- inside its own whitelisted apps.
function SupernoteInk.enableFullUiAuto(enable)
    if not SupernoteInk.isAvailable() then return end
    JNI:context(android.app.activity.vm, function(jni)
        local activity = android.app.activity.clazz
        local jsname = newStringUTF(jni, "eink")
        local eink = jni:callObjectMethod(activity, "getSystemService",
            "(Ljava/lang/String;)Ljava/lang/Object;", jsname)
        deleteLocalRef(jni, jsname)
        if eink == nil then return end

        jni:callVoidMethod(eink, "enableFullUiAuto", "(Z)V", ffi.new("int32_t", enable and 1 or 0))
        if jni.env[0].ExceptionCheck(jni.env) == C.JNI_TRUE then
            jni.env[0].ExceptionClear(jni.env) -- some firmwares don't expose this method
        end
        deleteLocalRef(jni, eink)
    end)
end

return SupernoteInk
