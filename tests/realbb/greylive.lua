-- See-through pens drawn live on grey e-ink, on KOReader's REAL blitter: the
-- highlighter, marker and watercolour show in their own greys as they are
-- drawn (nothing stands in for them), with a refresh per sample as the pen
-- moves, each covering only the pixels that sample changed (a sliver at the
-- front of the stroke, not a box round the tip), and the screen equals the
-- saved stroke. The smudge and the other pens keep their refresh per sample.
-- A Kindle Scribe, a Kobo Sage and a Kobo Elipsa pace their live refreshes (see
-- InkAwayView:mtkPen and sunxiPanel).
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
    -- a grey refresh per sample, as the pen moves, none fast
    local ui, fast = count(rs, "ui"), count(rs, "fast")
    ok(fast == 0 and ui >= n - 2, ("%s: a grey refresh per sample (%d for %d)"):format(name, ui, n))
    -- each one only the new sliver at the front, narrower than the box round the
    -- tip each refresh used to cover (the pen's width and the step, padded)
    local widths, areas = {}, 0
    for k = 2, #rs do
        local reg = rs[k].region
        if rs[k].mode == "ui" and reg then widths[#widths + 1] = reg.w; areas = areas + reg.w * reg.h end
    end
    table.sort(widths)
    local med = widths[math.ceil(#widths / 2)] or 999
    local box = pen[2] + 12
    ok(med <= 0.85 * box, ("%s: each refresh is the changed sliver (%d px wide, the box was %d)"):format(name, med, box))
    print(("  %s: refreshes %d px wide on average, %d%% of the old box's area"):format(name, med,
        math.floor(100 * areas / math.max(1, #widths * box * box))))
    -- the pen lifts: the screen is the stroke, to its end
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } })
    view:flushPending()
    local ex = 690 - v.area_x
    local e1 = view.area_bb:getPixel(ex, y - v.area_y):getColorRGB32().r
    local ecx, ecy = require("ink/geom").toCanvas(v, 690, y)
    local e2 = view.canvas_bb:getPixel(math.floor(ecx), math.floor(ecy)):getColorRGB32().r
    ok(math.abs(e1 - e2) <= 2 and e1 < 247, ("%s: the screen equals the saved stroke to its end (%d / %d)"):format(name, e1, e2))
    ok(view.canvas:opCount() == 1, name .. ": one stroke saved")
    done()
end

-- a solid black pen, a thin grey pencil and the smudge keep their refresh per sample
for _i, pen in ipairs({ { "solid", { 0, 0, 0 }, "fast" }, { "pencil", { 40, 40, 40 }, "ui" }, { "smudge", { 0, 0, 0 }, "ui" } }) do
    local view, rs, tick, done = world(false)
    if pen[1] == "smudge" then
        view:choosePenType("solid"); view:setTool("pen"); view.pen_width = 20
        drag(view, tick, 300, 700, view.view.area_y + 600)
        view:onIaPanRelease(nil, { pos = { x = 700, y = view.view.area_y + 600 } }); view:flushPending()
        tick(1000)
    end
    view:choosePenType(pen[1]); view:setTool("pen")
    view.pen_width, view.pen_color, view.pen_alpha = pen[1] == "smudge" and 40 or 6, pen[2], 255
    for k = #rs, 1, -1 do rs[k] = nil end
    local n = drag(view, tick, 300, 700, view.view.area_y + 600)
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

-- a Kindle Scribe (MTK panel, Wacom pen) paces its live refreshes: at most one
-- every 20 ms for black ink (80 ms for grey), each covering all that changed
-- since the last, still following the pen, and the end shown after the lift;
-- a grey reader without that pen keeps a refresh per sample (above)
for _i, pen in ipairs({ { "solid", { 0, 0, 0 }, "fast", 20 }, { "highlighter", nil, "ui", 80 } }) do
    local view, rs, tick, done = world(false)
    Device.isMTK = function() return true end
    Device.input.wacom_protocol = true
    local v = view.view
    view:choosePenType(pen[1]); view:setTool("pen")
    if pen[2] then view.pen_color = pen[2] end
    view.pen_width, view.pen_alpha = 8, 255
    local y = v.area_y + 600
    for k = #rs, 1, -1 do rs[k] = nil end
    local n = drag(view, tick, 300, 700, y)   -- 8 ms a sample
    local live = count(rs, pen[3])
    local most = math.floor(n * 8 / pen[4]) + 2
    ok(view:mtkPen(), pen[1] .. " (Scribe): taken for a Kindle Scribe")
    ok(live <= most and live >= math.floor(most / 2),
        ("%s (Scribe): refreshes paced, %d for %d samples (at most %d)"):format(pen[1], live, n, most))
    -- they follow the pen: one reaches its middle while it is still drawing
    local mid = false
    for _k, r in ipairs(rs) do
        local g = r.region
        if g and g.x <= 500 and g.x + g.w >= 500 then mid = true end
    end
    ok(mid, pen[1] .. " (Scribe): the ink shows as the pen goes, not only at the end")
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } })
    view:flushPending()
    tick(200); UIManager.fireScheduled()
    -- all of the stroke was refreshed, its end included
    local x0, x1 = math.huge, -math.huge
    for _k, r in ipairs(rs) do
        local g = r.region
        if g and g.y <= y and g.y + g.h >= y then
            x0 = math.min(x0, g.x); x1 = math.max(x1, g.x + g.w)
        end
    end
    ok(x0 <= 300 and x1 >= 700, ("%s (Scribe): the whole stroke was refreshed, %d to %d"):format(pen[1], x0, x1))
    Device.isMTK = nil
    Device.input.wacom_protocol = false
    done()
end

-- a Kobo Sage or Elipsa (an Allwinner display controller, no Wacom pen) paces its
-- live refreshes too, and at the lift one refresh covers the whole stroke, so
-- what the driver dropped while the pen moved shows then (#19). Black ink is
-- shown there with the fast waveform it was drawn with, its last samples in the
-- same update; what the lift drew again (a Ballpoint's thinner end) gets the
-- grey one only once the pen rests, never under the next stroke. Grey ink keeps
-- the grey waveform.
local function covers(r, x0, x1, y)
    local g = r.region
    return g and g.x <= x0 and g.x + g.w >= x1 and g.y <= y and g.y + g.h >= y
end
for _i, pen in ipairs({ { "solid", { 0, 0, 0 }, "fast" }, { "ballpoint", { 0, 0, 0 }, "fast", true },
        { "pencil", nil, "ui" } }) do
    local name = pen[1]
    local view, rs, tick, done = world(false)
    Device.isSunxi = function() return true end
    local v = view.view
    view:choosePenType(name); view:setTool("pen")
    if pen[2] then view.pen_color = pen[2] end
    view.pen_width, view.pen_alpha = 8, 255
    local y = v.area_y + 700
    for k = #rs, 1, -1 do rs[k] = nil end
    local n = drag(view, tick, 300, 700, y)
    local live = count(rs, pen[3])
    ok(view:sunxiPanel() and not view:mtkPen(), name .. " (Sage): taken for an Allwinner panel")
    local gap = pen[3] == "fast" and 20 or 80
    ok(live <= math.floor(n * 8 / gap) + 2 and live >= 3,
        ("%s (Sage): refreshes paced, %d for %d samples"):format(name, live, n))
    for k = #rs, 1, -1 do rs[k] = nil end
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } })
    view:flushPending()
    -- what the lift sends, before any timer runs
    local whole, grey = false, 0
    for _k, r in ipairs(rs) do
        if r.mode == pen[3] and covers(r, 300, 700, y) then whole = true end
        if r.mode == "ui" then grey = grey + 1 end
    end
    ok(whole, ("%s (Sage): the lift refreshes the whole stroke once more, %s"):format(name, pen[3]))
    ok(not view._live_pend and not view._live_flush_armed,
        name .. " (Sage): the last samples go with the lift's refresh, none follows")
    if pen[3] == "fast" then
        ok(grey == 0, ("%s (Sage): no grey refresh at the lift (%d)"):format(name, grey))
    end
    if pen[4] then
        -- its thinner end is drawn again, so the grey refresh waits for the pen
        -- to rest: a next stroke at once pushes it back, it runs after that one
        ok(view._reconcile and UIManager.scheduled[view._reconcile_cb],
            name .. " (Sage): the end drawn again gets the grey refresh once the pen rests")
        for k = #rs, 1, -1 do rs[k] = nil end
        tick(150)
        drag(view, tick, 300, 600, y + 60)
        view:runReconcile()   -- its timer, while the pen is down
        ok(count(rs, "ui") == 0, ("%s (Sage): none while the next stroke is drawn (%d)"):format(name, count(rs, "ui")))
        view:onIaPanRelease(nil, { pos = { x = 600, y = y + 60 } })
        view:flushPending()
        ok(count(rs, "ui") == 0 and UIManager.scheduled[view._reconcile_cb],
            name .. " (Sage): nor at its lift, still waiting for the pen to rest")
        -- an eraser stroke between does not lose it
        view:setTool("erase")
        drag(view, tick, 300, 400, y + 200)
        view:onIaPanRelease(nil, { pos = { x = 400, y = y + 200 } })
        view:flushPending()
        ok(view._reconcile and UIManager.scheduled[view._reconcile_cb],
            name .. " (Sage): an eraser stroke between leaves it to come")
        view:setTool("pen")
        tick(1000); UIManager.fireScheduled()
        local settled = false
        for _k, r in ipairs(rs) do if r.mode == "ui" and covers(r, 690, 700, y) then settled = true end end
        ok(settled, name .. " (Sage): once the pen rests the first stroke's end gets it")
    end
    -- and the screen holds the whole stroke (a pencil's grain is not all dark)
    view._area_only = true
    view:paintTo(Device.screen.bb, 0, 0)
    local sb = Device.screen.bb
    local dark, same = 0, 0
    for x = 310, 690, 20 do
        local c = sb:getPixel(x, y):getColorRGB32().r
        if c < 64 then dark = dark + 1 end
        if c == view.area_bb:getPixel(x - v.area_x, y - v.area_y):getColorRGB32().r then same = same + 1 end
    end
    ok(same == 20 and (dark >= 19 or pen[3] ~= "fast"),
        ("%s (Sage): the screen shows the stroke from end to end (%d of 20 points as drawn, %d dark)")
        :format(name, same, dark))
    Device.isSunxi = nil
    done()
end

-- any other grey reader keeps the grey waveform for the end a lift draws again
do
    local view, rs, tick, done = world(false)
    local v = view.view
    view:choosePenType("ballpoint"); view:setTool("pen")
    view.pen_color, view.pen_width, view.pen_alpha = { 0, 0, 0 }, 8, 255
    local y = v.area_y + 700
    drag(view, tick, 300, 700, y)
    for k = #rs, 1, -1 do rs[k] = nil end
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } })
    view:flushPending()
    local tail = false
    for _k, r in ipairs(rs) do if r.mode == "ui" and covers(r, 690, 700, y) then tail = true end end
    ok(not view:sunxiPanel() and tail and not view._reconcile,
        "ballpoint (grey reader): the end drawn again is shown with the grey waveform at the lift, as before")
    done()
end

-- The eraser over a notebook's ruling (#47, #50): on a grey Kobo with a pen it
-- erases with the fast waveform, a refresh per sample as before, and its lift
-- shows the erased path again as it is (the ruling back in its grey); the Libra
-- Colour and readers without a pen keep the grey waveform while erasing.
for _i, case in ipairs({ { "Kobo_condor", false, false, "fast" }, { "Kobo_europa", true, false, "fast" },
        { "Kobo_cadmus", true, false, "fast" }, { "Kobo_monza", false, true, "ui" }, { "Kobo_nova", false, false, "ui" } }) do
    local model, sunxi, colour, want = case[1], case[2], case[3], case[4]
    local saved_model = Device.model
    Device.model = model
    local view, rs, tick, done = world(colour)
    if sunxi then Device.isSunxi = function() return true end end
    view:newNotebook("lines", require("testenv").libraryDir() .. "/eraser " .. model)
    local v = view.view
    view:choosePenType("solid"); view:setTool("pen")
    view.pen_color, view.pen_width, view.pen_alpha = { 0, 0, 0 }, 10, 255
    local y = v.area_y + 600
    drag(view, tick, 300, 700, y)
    view:onIaPanRelease(nil, { pos = { x = 700, y = y } })
    view:flushPending()
    tick(1000); UIManager.fireScheduled()
    -- the paper as it is under the stroke's row, before any ink
    local paper = view:eraseRevealBB()
    local ruled = 0
    for yy = y - v.area_y - 40, y - v.area_y + 40 do
        local c = paper:getPixel(500 - v.area_x, yy):getColorRGB32().r
        if c < 247 then ruled = ruled + 1 end
    end
    view:setTool("erase"); view.eraser_width = 60
    for k = #rs, 1, -1 do rs[k] = nil end
    local n = 1
    view:onIaTouch(nil, { pos = { x = 500, y = y - 40 } })
    for yy = y - 34, y + 40, 6 do tick(8); view:onIaPan(nil, { pos = { x = 500, y = yy } }); n = n + 1 end
    ok(view._live_mode == want, ("eraser (%s): erases live with %s (%s)"):format(model, want, tostring(view._live_mode)))
    local live_other = 0
    for _k, r in ipairs(rs) do if r.mode ~= want then live_other = live_other + 1 end end
    -- (a colour panel paces them, see liveDirty)
    ok(count(rs, want) >= (colour and 1 or 3) and live_other == 0,
        ("eraser (%s): its live refreshes are all %s (%d, %d other)"):format(model, want, count(rs, want), live_other))
    for k = #rs, 1, -1 do rs[k] = nil end
    view:onIaPanRelease(nil, { pos = { x = 500, y = y + 40 } })
    view:flushPending()
    tick(1000); UIManager.fireScheduled()
    if want == "fast" then
        local shown = false
        for _k, r in ipairs(rs) do
            if r.mode ~= "fast" and covers(r, 490, 510, y) then shown = true end
        end
        ok(shown, ("eraser (%s): the lift shows the erased path again with a grey-capable refresh"):format(model))
    end
    -- the ink is gone there and the ruling is back, as the page has it
    local inked, same = 0, 0
    for yy = y - v.area_y - 40, y - v.area_y + 40 do
        local c = view.area_bb:getPixel(500 - v.area_x, yy):getColorRGB32().r
        if c <= 8 then inked = inked + 1 end
        if c == paper:getPixel(500 - v.area_x, yy):getColorRGB32().r then same = same + 1 end
    end
    ok(ruled > 0 and inked == 0 and same == 81,
        ("eraser (%s): the ink is gone and the ruling shows as before (%d ruled, %d inked, %d of 81 the same)")
        :format(model, ruled, inked, same))
    Device.isSunxi = nil
    Device.model = saved_model
    done()
end

print(("realbb greylive: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
