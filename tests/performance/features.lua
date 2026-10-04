-- Timings of the October 2026 features on KOReader's real blitter (headless):
-- the selection (lifting, dragging, resizing, turning, its menu and actions)
-- against a full redraw, hold to straighten's cost per stroke, links on a page
-- and the contents page, searching a library of 30 notebooks, and the trash.
-- One screen config per process; prints the median and 90th percentile of
-- each action in microseconds.
--   cd <emulator>/koreader && ./luajit features.lua <plugin_dir> <mock_dir> <cfg> <out> <WxH>
--   cfg: grey:<rot> | colour:<rot>
local REPO, MOCK, CFG, OUT, SIZE, PART = arg[1], arg[2], arg[3], arg[4], arg[5] or "1072x1448", arg[6] or "ui"
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


------------------------------------------------------------------------------
-- Recording
------------------------------------------------------------------------------

local samples, order = {}, {}
local function rec(metric, v)
    local t = samples[metric]
    if not t then t = {}; samples[metric] = t; order[#order + 1] = metric end
    t[#t + 1] = v
end
local function timeit(metric, fn)
    local t = now_us(); local r = fn(); rec(metric, now_us() - t); return r
end

Screen.bb = BB.new(SW, SH, colour and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
Screen.bb:setRotation(rot)
UIManager.reset()
math.randomseed(7)

local View = dofile(REPO .. "/ink/view.lua")
local view = View:new{}
-- text needs KOReader's fonts, which the stand-ins do not have: the contents
-- page is timed without drawing its letters
view.stampTextInto = function() end
UIManager:show(view)
view.nowMs = function() return 0 end
local function paint() view:paintTo(Screen.bb, 0, 0) end
paint()
UIManager.fireScheduled()
local v = view.view
local function P(x, y) return { pos = { x = math.floor(x), y = math.floor(y) } } end
local Geom = require("ink/geom")
local function scr(cx, cy) return Geom.toScreen(v, cx, cy) end

-- a dense page: 300 strokes of handwriting-like waves, a few shapes, a picture
local function wave(x0, y0, x1, n, amp, phase)
    local t = {}
    for i = 0, n do
        local u = i / n
        t[#t + 1] = x0 + (x1 - x0) * u
        t[#t + 1] = y0 + math.sin(u * math.pi * 3 + (phase or 0)) * amp
    end
    return t
end
local function densePage()
    local ops = {}
    local W, H = v.canvas_w, v.canvas_h
    for k = 1, 300 do
        local row, col = math.floor((k - 1) / 6), (k - 1) % 6
        local x0 = 40 + col * (W - 80) / 6
        local y0 = 60 + row * (H - 120) / 50
        ops[#ops + 1] = { kind = "ink", width = 3, alpha = 255, pts = wave(x0, y0, x0 + (W - 80) / 6 - 12, 24, 6, k) }
    end
    for k = 1, 6 do
        ops[#ops + 1] = { kind = "shape", shape = (k % 2 == 0) and "ellipse" or "rect", width = 4, alpha = 255,
            pts = { 100 + k * 60, 300 + k * 40, 220 + k * 60, 380 + k * 40 } }
    end
    return ops
end
view.canvas:setOps(densePage())
view:composeCanvas(); view:renderView(); paint()

local REPEAT = tonumber(os.getenv("FEAT_REPEAT") or "8")

------------------------------------------------------------------------------
-- The selection
------------------------------------------------------------------------------
for r = 1, REPEAT do
    timeit("page.full_redraw", function() view:composeCanvas(); view:renderView(); paint() end)
    view:setTool("lasso")
    -- a third of the page, about 100 strokes
    local W, H = v.canvas_w, v.canvas_h
    local poly = { 20, 40, W * 0.55, 40, W * 0.55, H * 0.33, 20, H * 0.33 }
    timeit("sel.select_and_menu", function()
        view:computeSelection(poly); view:openSelectionMenu(); paint()
    end)
    rec("sel.count", #view.selection.idxs)
    timeit("sel.menu_rebuild", function() view:openSelectionMenu() end)
    local f = view:selFrame()
    local cx, cy = (f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2
    -- move: lift on the first movement, then frames, then the drop
    view:onIaTouch(nil, P(cx, cy))
    timeit("sel.move.lift", function() view:onIaPan(nil, P(cx + 4, cy + 3)); paint() end)
    for i = 2, 20 do timeit("sel.move.frame", function() view:onIaPan(nil, P(cx + i * 4, cy + i * 3)); paint() end) end
    timeit("sel.move.drop", function() view:onIaPanRelease(nil, P(cx + 80, cy + 60)); paint() end)
    UIManager.fireScheduled()
    -- resize from a corner
    f = view:selFrame()
    view:onIaTouch(nil, P(f.x1, f.y1))
    timeit("sel.resize.lift", function() view:onIaPan(nil, P(f.x1 + 5, f.y1 + 5)); paint() end)
    for i = 2, 20 do timeit("sel.resize.frame", function() view:onIaPan(nil, P(f.x1 + i * 5, f.y1 + i * 4)); paint() end) end
    timeit("sel.resize.drop", function() view:onIaPanRelease(nil, P(f.x1 + 100, f.y1 + 80)); paint() end)
    UIManager.fireScheduled()
    -- turn with the knob
    local kx, ky = view:selKnob()
    view:onIaTouch(nil, P(kx, ky))
    for i = 1, 20 do timeit("sel.turn.frame", function() view:onIaPan(nil, P(kx + i * 6, ky + i * 2)); paint() end) end
    timeit("sel.turn.drop", function() view:onIaPanRelease(nil, P(kx + 120, ky + 40)); paint() end)
    UIManager.fireScheduled()
    timeit("sel.action.colour", function() view:selSetColour({ 60, 60, 60 }); paint() end)
    timeit("sel.action.size", function() view:selSetSize(5); paint() end)
    timeit("sel.action.flip", function() view:selFlip("h"); paint() end)
    timeit("sel.action.turn90", function() view:selTurn90(); paint() end)
    timeit("sel.action.duplicate", function() view:selDuplicate(); paint() end)
    timeit("sel.action.delete", function() view:selDelete(); paint() end)
    view:dropSelection()
    view.canvas:setOps(densePage())
    view:composeCanvas(); view:renderView()
end

-- a picture in the selection takes the full-page path
view:insertImage("fake.png")
for r = 1, REPEAT do
    local f = view:selFrame()
    local cx, cy = (f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2
    view:onIaTouch(nil, P(cx, cy))
    timeit("sel.picture.lift", function() view:onIaPan(nil, P(cx + 4, cy + 3)); paint() end)
    for i = 2, 10 do timeit("sel.picture.frame", function() view:onIaPan(nil, P(cx + i * 4, cy + i * 3)); paint() end) end
    timeit("sel.picture.drop", function() view:onIaPanRelease(nil, P(cx + 40, cy + 30)); paint() end)
    UIManager.fireScheduled()
end
view:dropSelection()

------------------------------------------------------------------------------
-- Hold to straighten: what it costs a stroke
------------------------------------------------------------------------------
view:setTool("pen")
for _, on in ipairs({ false, true, false, true }) do
    view.hold_straighten = on
    local tag = on and "on" or "off"
    for r = 1, REPEAT do
        local pts = wave(100, 600 + r * 10, 700, 60, 20, r)
        local x, y = scr(pts[1], pts[2])
        timeit("stroke.start.hold_" .. tag, function() view:onIaTouch(nil, P(x, y)) end)
        for i = 3, #pts, 2 do
            x, y = scr(pts[i], pts[i + 1])
            timeit("stroke.point.hold_" .. tag, function() view:onIaPan(nil, P(x, y)) end)
        end
        view:onIaPanRelease(nil, P(x, y))
        view:flushPending()
        UIManager.fireScheduled()
    end
end
view.hold_straighten = true
for r = 1, REPEAT do
    local x0, y0 = scr(100, 900)
    view:onIaTouch(nil, P(x0, y0))
    for i = 1, 40 do view:onIaPan(nil, P(x0 + i * 12, y0 + (i % 2))) end
    UIManager.scheduled[view._straighten_cb] = nil
    timeit("straighten.snap", function() view:straightenNow(); paint() end)
    view:onIaPanRelease(nil, P(x0 + 480, y0))
    UIManager.fireScheduled()
end

------------------------------------------------------------------------------
-- Links and the contents page
------------------------------------------------------------------------------
local Links = require("ink/links")
for r = 1, REPEAT do timeit("paint.no_links", paint) end
for k = 1, 40 do
    view.canvas.ops[#view.canvas.ops + 1] = Links.new({ x0 = 50, y0 = k * 30, x1 = 400, y1 = k * 30 + 24 }, { id = k })
end
view.canvas:pushHistory()
for r = 1, REPEAT do timeit("paint.40_links", paint) end
view:newNotebook("lines")
v = view.view
for i = 1, 40 do
    if i > 1 then view:nbAddPage() end
    view.canvas.ops[1] = { kind = "ink", width = 3, alpha = 255, pts = wave(100, 400, 600, 30, 10, i) }
    view:markDirty(); view:nbSyncOut()
    view.notebook.pages[i].title = "Chapter " .. i
end
for r = 1, REPEAT do timeit("contents.make_40", function() view:nbMakeContents() end) end

------------------------------------------------------------------------------
-- Search and the trash, over a library of 30 notebooks of 40 pages
------------------------------------------------------------------------------
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Search = require("ink/search")
local Trash = require("ink/trash")
local Text = require("ink/text")
local LIB = TMP .. "/lib"
os.execute("mkdir -p '" .. LIB .. "/School/Physics'")
for n = 1, 30 do
    local nb = Notebook.new(v.canvas_w, v.canvas_h, { style = "lines", size = 40 })
    for p = 1, 40 do
        if p > 1 then nb:addPage() end
        local op = Text.new{ x = 20, y = 20, w = 600, size = 20 }
        Text.insert(op, { p = 1, o = 0 }, "Notes page " .. p .. " of notebook " .. n .. " the quick brown fox", nil)
        nb.pages[p].ops = { { kind = "ink", width = 3, alpha = 255, pts = wave(100, 300, 700, 120, 20, p) }, op }
        if p % 7 == 0 then nb.pages[p].title = "Forces " .. n .. "." .. p end
    end
    Project.saveNotebook(nb, LIB .. "/School/Physics/Course " .. n .. ".inkaway")
end
local function lower(s) return s:lower() end
for r = 1, math.max(2, math.floor(REPEAT / 2)) do
    os.remove(LIB .. "/" .. Search.CACHE)
    for _, inside in ipairs({ false, true }) do
        local tag = inside and "inside" or "names"
        for _, warm in ipairs({ false, true }) do
            if not warm and inside then os.remove(LIB .. "/" .. Search.CACHE) end
            timeit("search." .. tag .. (warm and ".cached" or ".cold"), function()
                local entries = Search.walk(LIB, {})
                local idx = Search.newIndex(Search.loadCache(LIB))
                for _, e in ipairs(entries) do if e.kind == "doc" then idx:document(e, inside) end end
                local res = Search.find(entries, idx.docs, "forces 1", lower, inside)
                if idx.changed then Search.saveCache(LIB, idx) end
                return res
            end)
        end
    end
end
local big = LIB .. "/School/Physics/Course 1.inkaway"
for r = 1, REPEAT do
    local item = timeit("trash.put_notebook", function() return Trash.putDocument(LIB, big, true) end)
    timeit("trash.restore_notebook", function() return Trash.restore(LIB, item.id) end)
    local data = Project.load(big)
    local nb = Notebook.fromData(data)
    local pitem = timeit("trash.put_page", function() return Trash.putPage(LIB, big, nb, 5) end)
    nb:takePage(5); Project.saveNotebook(nb, big)
    timeit("trash.restore_page_into_file", function()
        return Trash.restore(LIB, pitem.id, function(path, saved, it)
            local n2 = Notebook.fromData(Project.load(path))
            n2:insertPage(saved.page, Trash.pageSlot(n2, it))
            return Project.saveNotebook(n2, path)
        end)
    end)
end

------------------------------------------------------------------------------
-- Report
------------------------------------------------------------------------------
local f = io.open(OUT, "w")
for _, m in ipairs(order) do
    local t = samples[m]
    table.sort(t)
    local med = t[math.ceil(#t / 2)]
    local p90 = t[math.max(1, math.ceil(#t * 0.9))]
    f:write(string.format("%-34s n=%-4d median %10.1f  p90 %10.1f\n", m, #t, med, p90))
end
f:close()
os.execute("rm -rf '" .. TMP .. "'")
