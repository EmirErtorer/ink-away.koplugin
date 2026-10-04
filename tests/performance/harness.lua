-- The headless set-up the benchmarks share (bench.lua, features.lua): KOReader's
-- real blitter, lfs and MuPDF with the test stand-ins for its widgets, a private
-- data folder, a fake screen of the asked size, rotation and colour, and JIT
-- trace counting. Not part of the plugin.
--   local H = dofile(<this file>)(REPO, MOCK, CFG, SIZE)
-- returns the pieces as fields: ffi, BB, mupdf, real_lfs, now_us, Screen,
-- UIManager, Input, gd, TMP, settings, colour, rot, SW, SH, jit (counts), and
-- fake_img_calls() for the made-up pictures decoded.
return function(REPO, MOCK, CFG, SIZE)
    local jitopt = os.getenv("BENCH_JITOPT")
    if jitopt and jitopt ~= "" then
        local args = {}
        for a in jitopt:gmatch("[^,]+") do args[#args + 1] = a end
        jit.opt.start(unpack(args))
    end
    require("ffi/loadlib")
    local ffi = require("ffi")
    local BB = require("ffi/blitbuffer")
    local mupdf = require("ffi/mupdf")
    local real_lfs = require("libs/libkoreader-lfs")   -- the real one, before the mocks shadow it
    package.path = REPO .. "/?.lua;" .. MOCK .. "/?.lua;" .. package.path
    package.loaded["libs/libkoreader-lfs"] = real_lfs

    ffi.cdef[[uint64_t clock_gettime_nsec_np(int clock_id);]]
    local function now_us() return tonumber(ffi.C.clock_gettime_nsec_np(8)) / 1000 end

    local jit_flushes, jit_traces = 0, 0
    jit.attach(function(what)
        if what == "flush" then jit_flushes = jit_flushes + 1
        elseif what == "stop" then jit_traces = jit_traces + 1 end
    end, "trace")

    local kind, rotstr = CFG:match("^(%a+):(%d)$")
    local colour = (kind == "colour")
    local rot = tonumber(rotstr)
    local SW, SH = SIZE:match("^(%d+)x(%d+)$")
    SW, SH = tonumber(SW), tonumber(SH)

    -- a private data folder per process: library, settings, cache, exports
    local TMP = os.tmpname(); os.remove(TMP)
    os.execute("mkdir -p '" .. TMP .. "/settings' '" .. TMP .. "/lib'")
    package.loaded["datastorage"] = {
        getDataDir = function() return TMP end,
        getSettingsDir = function() return TMP .. "/settings" end,
        getFullDataDir = function() return TMP end,
    }

    local settings = { inkaway_autosave = "exit", inkaway_session_migrated = true,
        inkaway_library_dir = TMP .. "/lib",
        inkaway_orientation = (rot % 2 == 1) and "landscape" or "portrait" }
    _G.G_reader_settings = { data = settings,
        readSetting = function(self, k, d) local v = self.data[k]; if v == nil then return d end; return v end,
        saveSetting = function(self, k, v) self.data[k] = v end,
        delSetting = function(self, k) self.data[k] = nil end,
        has = function(self, k) return self.data[k] ~= nil end,
        isTrue = function(self, k) return self.data[k] == true end,
        nilOrTrue = function(self, k) return self.data[k] ~= false end,
        nilOrFalse = function(self, k) return not self.data[k] end,
        flush = function() end }

    local fake_img_calls = 0
    package.loaded["ui/renderimage"] = {
        scaleBlitBuffer = function(_, bb, width, height, free_orig_bb)
            if not width or not height then return bb end
            width, height = math.floor(width), math.floor(height)
            if bb:getWidth() == width and bb:getHeight() == height then return bb end
            local s = mupdf.scaleBlitBuffer(bb, width, height)
            if free_orig_bb ~= false then bb:free() end
            return s
        end,
        -- real decoding for files that exist (cached thumbnails); a generated
        -- picture for the drawing scenario's made-up image
        renderImageFile = function(_, file)
            if file and real_lfs.attributes(file, "mode") == "file" then
                return mupdf.renderImageFile(file)
            end
            fake_img_calls = fake_img_calls + 1
            local b = BB.new(480, 320, BB.TYPE_BBRGB32)
            for y = 0, 319 do for x = 0, 479 do
                b:setPixel(x, y, BB.ColorRGB32((x * 2) % 256, (y * 3) % 256, (x + y) % 256, (x < 40) and 0 or 255))
            end end
            return b
        end,
        renderSVGImageFile = function() return nil end,
    }

    local Screen = {
        DEVICE_ROTATED_UPRIGHT = 0, DEVICE_ROTATED_CLOCKWISE = 1,
        DEVICE_ROTATED_UPSIDE_DOWN = 2, DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    }
    function Screen:getWidth() return self.bb:getWidth() end
    function Screen:getHeight() return self.bb:getHeight() end
    function Screen:getSize() return { x = 0, y = 0, w = self:getWidth(), h = self:getHeight() } end
    function Screen:scaleBySize(px) return math.floor(px * 1.4) end
    function Screen:getDPI() return 300 end
    function Screen:getRotationMode() return rot end
    function Screen:setRotationMode(mode) self.bb:setRotation(mode); rot = mode end
    function Screen:getTouchRotation() return rot end
    local Input = { group = { Back = { "Back" } }, wacom_protocol = false,
        registerStylusCallback = function(self, cb) self.stylus_callback = cb end,
        unregisterStylusCallback = function(self) self.stylus_callback = nil end }
    package.loaded["device"] = {
        screen = Screen,
        isTouchDevice = function() return true end,
        hasKeys = function() return false end,
        hasColorScreen = function() return colour end,
        isKindle = function() return false end,
        input = Input,
    }
    local UIManager = require("ui/uimanager")
    local MockButton = require("ui/widget/button")
    MockButton.paintTo = function() end
    local mock_new = MockButton.new
    MockButton.new = function(self, o)
        local b = mock_new(self, o)
        b.frame = b.frame or {}
        b.label_container = b.label_container or {}
        return b
    end
    function UIManager:getTopmostVisibleWidget()
        local st = self._window_stack
        return st[#st] and st[#st].widget
    end

    local FakeGD = {}
    FakeGD.__index = FakeGD
    function FakeGD.new() return setmetatable({ contacts = {}, contact_count = 0 }, FakeGD) end
    function FakeGD:getContact(slot) return self.contacts[slot] end
    function FakeGD:feedEvent(tevs)
        for _, tev in ipairs(tevs) do
            if tev.id and tev.id >= 0 then
                if not self.contacts[tev.slot] then self.contacts[tev.slot] = true; self.contact_count = self.contact_count + 1 end
            elseif self.contacts[tev.slot] then
                self.contacts[tev.slot] = nil; self.contact_count = self.contact_count - 1
            end
        end
    end
    local gd = FakeGD.new()
    Input.gesture_detector = gd

    return {
        ffi = ffi, BB = BB, mupdf = mupdf, real_lfs = real_lfs, now_us = now_us,
        Screen = Screen, UIManager = UIManager, Input = Input, gd = gd, TMP = TMP,
        settings = settings, colour = colour, rot = rot, SW = SW, SH = SH,
        jit = function() return jit_flushes, jit_traces end,
        fake_img_calls = function() return fake_img_calls end,
    }
end
