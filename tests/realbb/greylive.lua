-- See-through pens drawn live on grey e-ink, on KOReader's REAL blitter: the
-- highlighter, marker and watercolour show in their own greys as they are
-- drawn (nothing stands in for them), and their grey refreshes go out at a
-- steady pace, each carrying everything drawn since, so they never queue up
-- behind the pen; the last piece goes at the lift and the screen then equals
-- the saved stroke. Solid and thin grey pens keep their refresh per sample.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/greylive.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
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

local function world(colour)
    local W, H = 1072, 1448
    Device.screen.bb = BB.new(W, H, colour and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return colour end
    Device.input.wacom_protocol = false
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    view._instant_colour = false          -- an e-ink panel (the tests run off one)
    local clock = 0
    view.nowMs = function() return clock end
    local rs = {}
    local orig = UIManager.setDirty
    UIManager.setDirty = function(self, w, mode, region)
        rs[#rs + 1] = { mode = tostring(mode), region = region, t = clock }
        return orig(self, w, mode, region)
    end
    return view, rs, function(ms) clock = clock + ms end, function() view:onCloseWidget(); UIManager.setDirty = orig end
end

-- the greys (neither black nor white) in a rect of a buffer
local function greys(bb, x0, y0, x1, y1)
    local n = 0
    for y = y0, y1, 2 do
        for x = x0, x1, 2 do
            local r = bb:getPixel(x, y):getColorRGB32().r
            if r > 8 and r < 247 then n = n + 1 end
        end
    end
    return n
end
local function blacks(bb, x0, y0, x1, y1)
    local n = 0
    for y = y0, y1 do
        for x = x0, x1 do if bb:getPixel(x, y):getColorRGB32().r <= 8 then n = n + 1 end end
    end
    return n
end

-- drag along y from x0 to x1, 6 px a sample, 8 ms apart; returns the samples
local function drag(view, tick, x0, x1, y)
    view:onIaTouch(nil, { pos = { x = x0, y = y } })
    local n = 1
    for x = x0 + 6, x1, 6 do tick(8); view:onIaPan(nil, { pos = { x = x, y = y } }); n = n + 1 end
    return n
end
local function count(rs, mode)
    local n = 0
    for _k, r in ipairs(rs) do if r.mode == mode then n = n + 1 end end
    return n
end

for _i, pen in ipairs({ { "highlighter", 60, 255, nil }, { "felttip", 30, 190, nil }, { "wash", 70, 160, nil } }) do
    local name = pen[1]
    local view, rs, tick, done = world(false)
    local v = view.view
    view:choosePenType(name); view:setTool("pen")
    view.pen_width, view.pen_alpha = pen[2], pen[3]
    local y = v.area_y + 500
    local ax0, ax1 = 300 - v.area_x, 700 - v.area_x
    local ay0, ay1 = y - v.area_y - 20, y - v.area_y + 20
    for k = #rs, 1, -1 do rs[k] = nil end
    local n = drag(view, tick, 300, 700, y)
    ok(view._live_paced, name .. ": a see-through pen is paced")
    -- what shows while drawing is the pen itself: its greys, no dots
    local g = greys(view.area_bb, ax0, ay0, ax1 - 40, ay1)
    ok(g > 200, ("%s: the stroke shows in its own greys as it is drawn (%d)"):format(name, g))
    local b = blacks(view.area_bb, ax0, ay0, ax1 - 40, ay1)
    ok(b == 0, ("%s: and nothing black stands in for it (%d)"):format(name, b))
    local sx = 400 - v.area_x
    local cx, cy = require("ink/geom").toCanvas(v, 400, y)
    local on = view.area_bb:getPixel(sx, y - v.area_y):getColorRGB32().r
    local m = view.canvas_bb:getPixel(math.floor(cx), math.floor(cy)):getColorRGB32().r
    ok(math.abs(on - m) <= 2, ("%s: the screen shows the stroke as saved, while drawing (%d / %d)"):format(name, on, m))
    -- the grey refreshes are few and steady: about one per 320 ms of drawing
    local ui, fast = count(rs, "ui"), count(rs, "fast")
    local span = (n - 1) * 8
    ok(fast == 0 and ui >= 1 and ui <= math.ceil(span / 320) + 1,
        ("%s: %d grey refreshes over %d samples in %d ms, none fast"):format(name, ui, n, span))
    local last
    for _k, r in ipairs(rs) do
        if r.mode == "ui" then
            ok(not last or r.t - last >= 320, ("%s: refreshes %d ms apart"):format(name, last and r.t - last or 0))
            last = r.t
        end
    end
    -- the pen lifts: the last piece goes at once, and the screen is the stroke
    local before = #rs
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } })
    view:flushPending()
    local tail
    for k = before + 1, #rs do if rs[k].mode == "ui" then tail = rs[k] end end
    ok(tail and tail.region and tail.region.x + tail.region.w >= 690, name .. ": the last piece shows at the lift")
    ok(not view._live_pend and not view._live_paced, name .. ": nothing is left waiting")
    local ex = 690 - v.area_x
    local e1 = view.area_bb:getPixel(ex, y - v.area_y):getColorRGB32().r
    local ecx, ecy = require("ink/geom").toCanvas(v, 690, y)
    local e2 = view.canvas_bb:getPixel(math.floor(ecx), math.floor(ecy)):getColorRGB32().r
    ok(math.abs(e1 - e2) <= 2 and e1 < 247, ("%s: the screen equals the saved stroke to its end (%d / %d)"):format(name, e1, e2))
    ok(view.canvas:opCount() == 1, name .. ": one stroke saved")
    done()
end

-- a solid black pen and a thin grey pencil keep their refresh per sample
for _i, pen in ipairs({ { "solid", { 0, 0, 0 }, "fast" }, { "pencil", { 40, 40, 40 }, "ui" } }) do
    local view, rs, tick, done = world(false)
    view:choosePenType(pen[1]); view:setTool("pen")
    view.pen_width, view.pen_color, view.pen_alpha = 6, pen[2], 255
    for k = #rs, 1, -1 do rs[k] = nil end
    local n = drag(view, tick, 300, 700, view.view.area_y + 600)
    ok(not view._live_paced, pen[1] .. ": not paced")
    ok(count(rs, pen[3]) >= n - 2, ("%s: a %s refresh per sample (%d for %d)"):format(pen[1], pen[3], count(rs, pen[3]), n))
    view:onIaPanRelease(nil, { pos = { x = 700, y = view.view.area_y + 600 } }); view:flushPending()
    done()
end

-- a colour panel keeps its own pace
do
    local view, rs, tick, done = world(true)
    view:choosePenType("highlighter"); view:setTool("pen")
    local n = drag(view, tick, 300, 700, view.view.area_y + 500)
    ok(#rs > 0 and #rs < n, "colour: refreshes paced as before")
    view:onIaPanRelease(nil, { pos = { x = 700, y = view.view.area_y + 500 } }); view:flushPending()
    done()
end

print(("realbb greylive: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
