-- See-through pens drawn live on grey e-ink, on KOReader's REAL blitter: the
-- highlighter, marker and watercolour show as black dots with the fast waveform
-- while the pen moves (no grey, so no slow grey refresh trailing behind the
-- pen), the master takes the true blend at the lift, and once the pen rests the
-- screen shows exactly the saved stroke after one grey refresh. A colour panel
-- and a solid pen are untouched.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/dots.lua <repo>
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
        rs[#rs + 1] = { mode = tostring(mode), region = region }
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

-- drag along y from x0 to x1, 6 px a sample, 8 ms apart
local function drag(view, tick, x0, x1, y)
    view:onIaTouch(nil, { pos = { x = x0, y = y } })
    for x = x0 + 6, x1, 6 do tick(8); view:onIaPan(nil, { pos = { x = x, y = y } }) end
end

for _i, pen in ipairs({ { "highlighter", 60, 255, nil }, { "felttip", 30, 190, { 210, 40, 40 } }, { "wash", 70, 160, { 40, 120, 220 } } }) do
    local name = pen[1]
    local view, rs, tick, done = world(false)
    local v = view.view
    view:choosePenType(name); view:setTool("pen")
    view.pen_width, view.pen_alpha = pen[2], pen[3]
    if pen[4] then view.pen_color = pen[4] end
    local y = v.area_y + 500
    local ax0, ax1 = 300 - v.area_x, 700 - v.area_x
    local ay0, ay1 = y - v.area_y - 20, y - v.area_y + 20
    for k = #rs, 1, -1 do rs[k] = nil end
    drag(view, tick, 300, 700, y)
    ok(view._live_dither, name .. ": drawn as dots on grey e-ink")
    local fast, other = 0, 0
    for _k, r in ipairs(rs) do if r.mode == "fast" then fast = fast + 1 else other = other + 1 end end
    ok(fast > 0 and other == 0, ("%s: every live refresh is the fast one (%d fast, %d other)"):format(name, fast, other))
    ok(greys(view.area_bb, ax0, ay0, ax1, ay1) == 0, name .. ": no grey on screen while the pen moves")
    local dots = blacks(view.area_bb, ax0, ay0, ax1, ay1)
    local area = (ax1 - ax0 + 1) * (ay1 - ay0 + 1)
    ok(dots > area * 0.1 and dots < area * 0.95, ("%s: the stroke shows as dots (%d%% of its band)"):format(name, math.floor(100 * dots / area)))
    -- the pen lifts: the master takes the true blend, drawn from the saved stroke
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } })
    view:flushPending()
    local cx, cy = require("ink/geom").toCanvas(v, 500, y)
    local m = view.canvas_bb:getPixel(math.floor(cx), math.floor(cy)):getColorRGB32().r
    ok(m > 8 and m < 247, name .. ": the master holds the true grey (" .. m .. ")")
    for k = #rs, 1, -1 do rs[k] = nil end
    ok(UIManager.scheduled[view._reconcile_cb], name .. ": the settle is due once the pen rests")
    view._reconcile_cb()
    ok(#rs == 1 and rs[1].mode == "ui", name .. ": settled with one grey refresh")
    local g = greys(view.area_bb, ax0, ay0, ax1, ay1)
    ok(g > 0, name .. ": the screen shows the true greys after (" .. g .. ")")
    local s = view.area_bb:getPixel(500 - v.area_x, y - v.area_y):getColorRGB32().r
    ok(math.abs(s - m) <= 2, ("%s: the screen equals the master there (%d / %d)"):format(name, s, m))
    ok(view.canvas:opCount() == 1, name .. ": one stroke saved")
    done()
end

-- black text under the highlighter stays black while it is drawn
do
    local view, _rs, tick, done = world(false)
    local v = view.view
    view:choosePenType("solid"); view:setTool("pen")
    view.pen_width = 6
    local y = v.area_y + 600
    drag(view, tick, 300, 700, y)
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } }); view:flushPending()
    ok(not view._live_dither, "solid: a solid pen draws as before")
    view:choosePenType("highlighter"); view:setTool("pen")
    tick(1000)
    drag(view, tick, 300, 700, y)
    local px = view.area_bb:getPixel(500 - v.area_x, y - v.area_y):getColorRGB32().r
    ok(px <= 8, "highlighter: ink under it stays black while it is drawn")
    done()
end

-- a colour panel keeps its own way (the fast waveform in colour)
do
    local view, _rs, tick, done = world(true)
    view:choosePenType("highlighter"); view:setTool("pen")
    drag(view, tick, 300, 700, view.view.area_y + 500)
    ok(not view._live_dither, "colour: no dots on a colour panel")
    done()
end

print(("realbb dots: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
