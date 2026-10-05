-- Live refresh pacing on Android (a Boox), on KOReader's REAL blitter. There every
-- refresh copies the whole screen into the app's window, so live refreshes of the
-- pen, the eraser, shape previews, the lasso and panning go out at a bounded pace,
-- with the last one always sent. Grey Kindle and Kobo e-ink keep one refresh per
-- sample, checked here for the same moves.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/android.lua <repo>
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

-- A Boox Nova 2 (Android: a 32-bit screen buffer, grey e-ink) or a Kindle (8-bit grey).
local function world(android)
    local W, H = 1404, 1872
    Device.screen.bb = BB.new(W, H, android and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return false end
    Device.isAndroid = function() return android end
    Device.input.wacom_protocol = false
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    local clock = 0
    view.nowMs = function() return clock end
    local rs = {}
    local orig = UIManager.setDirty
    UIManager.setDirty = function(self, w, mode, region)
        rs[#rs + 1] = { mode = tostring(mode), region = region }
        return orig(self, w, mode, region)
    end
    local function clear() for k = #rs, 1, -1 do rs[k] = nil end end
    return view, rs, clear, function(ms) clock = clock + ms end, function()
        view:onCloseWidget(); UIManager.setDirty = orig; Device.isAndroid = nil
    end
end
local function covers(r, x, y) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

-- drag from x0 to x1 at height y in 4 px steps, 5 ms apart (200 samples a second)
local function drag(view, tick, x0, x1, y, lift)
    view:onIaTouch(nil, { pos = { x = x0, y = y } })
    for x = x0 + 4, x1, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    if lift ~= false then view:onIaPanRelease(nil, { pos = { x = x1, y = y } }) end
end

------------------------------------------------------------------------------
-- Android
------------------------------------------------------------------------------
do
    local view, rs, clear, tick, done = world(true)
    local v = view.view
    ok(view:onAndroid(), "android: detected")
    local y = v.area_y + 400

    -- the pen: 100 samples over half a second
    view:setTool("pen")
    clear()
    drag(view, tick, 200, 600, y, false)
    local n = #rs
    ok(n >= 10 and n <= 14, ("android: pen refreshes paced to ~25/s (%d for 100 samples over 0.5 s)"):format(n))
    local ax = 600 - v.area_x
    ok(view._blit_rect and view._blit_rect.x1 >= ax, "android: the samples not yet shown stay in the region to paint")
    ok(UIManager.scheduled[view._live_flush_cb], "android: the last samples are due")
    view._live_flush_cb()
    ok(#rs == n + 1 and covers(rs[#rs].region, 599, y), "android: the last samples follow in one refresh")
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } })
    UIManager.fireScheduled()
    view:flushPending()
    local px = view.area_bb:getPixel(400 - v.area_x, y - v.area_y):getColorRGB32()
    ok(px.r == 0 and px.g == 0 and px.b == 0, "android: the stroke is drawn")
    ok(view.canvas:opCount() == 1, "android: and committed")

    -- after a pause the first sample of a new stroke shows at once
    tick(500); clear()
    view:onIaTouch(nil, { pos = { x = 200, y = y + 100 } })
    tick(5); view:onIaPan(nil, { pos = { x = 204, y = y + 100 } })
    ok(#rs == 1 and rs[1].mode == "fast", "android: a new stroke's first sample is not held back")
    view:onIaPanRelease(nil, { pos = { x = 204, y = y + 100 } })
    UIManager.fireScheduled(); view:flushPending()

    -- the whole-stroke eraser: paced, and its clean-up covers what was pending
    tick(500)
    view.erase_whole = true
    view:setTool("erase")
    clear()
    drag(view, tick, 200, 600, y, false)
    local live = #rs
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } })
    ok(view.canvas:opCount() == 1, "android: the whole-stroke eraser removed the stroke")
    ok(live >= 1 and live <= 14, ("android: the eraser's refreshes are paced (%d)"):format(live))
    ok(UIManager.scheduled[view._live_flush_cb] == nil, "android: nothing left pending after the eraser's clean-up")
    view.erase_whole = false

    -- a shape: its preview follows the finger at the same pace, and is placed
    tick(500)
    view:setTool("shape")
    view.shape, view.shape_fill, view.symmetry = "rect", false, "off"
    clear()
    drag(view, tick, 200, 600, y + 300, false)
    n = #rs
    ok(n >= 10 and n <= 14, ("android: shape preview refreshes paced (%d for 100 moves)"):format(n))
    ok(UIManager.scheduled[view._live_flush_cb], "android: the last preview is due")
    view._live_flush_cb()
    ok(#rs == n + 1 and covers(rs[#rs].region, 599, y + 300), "android: the last preview follows")
    view:onIaPanRelease(nil, { pos = { x = 600, y = y + 340 } })
    ok(view.canvas:opCount() == 2, "android: the shape is placed")

    -- the lasso loop
    tick(500)
    view:setTool("lasso")
    clear()
    drag(view, tick, 150, 650, y + 500, false)
    n = #rs
    ok(n >= 12 and n <= 17, ("android: lasso refreshes paced (%d for 125 samples)"):format(n))
    view:onIaPanRelease(nil, { pos = { x = 150, y = y + 500 } })
    view:dropSelection()
    UIManager.fireScheduled()

    -- text box and export box drags refresh through liveBox: paced, clipped to the area
    tick(500); clear()
    local box = { x = 300, y = y, w = 200, h = 80 }
    local bx0 = view:refreshRectUnion(box, box, 4, "fast", true)
    tick(5)
    local bx1 = view:refreshRectUnion(box, { x = 310, y = y, w = 200, h = 80 }, 4, "fast", true)
    ok(bx0 == 296 and bx1 == 296 and #rs == 1 and UIManager.scheduled[view._live_flush_cb],
        "android: a text box drag is paced like ink")
    view._live_flush_cb()
    ok(#rs == 2 and covers(rs[2].region, 513, y), "android: and its last position follows")
    ok(view:liveBox("fast", -50, -50, 10, 10) == nil, "android: a box off the drawing area refreshes nothing")

    -- panning: the page is redrawn at the refresh pace, and where it ended at the lift
    tick(500)
    view:zoomStep(1); view:zoomStep(1)
    view:setTool("pan")
    local renders = 0
    local render = view.renderView
    view.renderView = function(self) renders = renders + 1; return render(self) end
    clear()
    local px0 = v.pan_x
    view:onIaTouch(nil, { pos = { x = 900, y = y } })
    for x = 896, 500, -4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    n = #rs
    ok(v.pan_x > px0, "android: the pan moved the page")
    ok(n >= 10 and n <= 14 and renders <= n, ("android: panning refreshes and redraws paced (%d refreshes, %d redraws for 100 moves)"):format(n, renders))
    ok(view._view_stale, "android: the latest pan step waits for the next refresh")
    view:onIaPanRelease(nil, { pos = { x = 500, y = y } })
    ok(not view._view_stale and #rs == n + 1 and rs[#rs].mode == "ui", "android: the lift shows where the pan ended at once")
    local shown = BB.new(view.area_bb:getWidth(), view.area_bb:getHeight(), view.area_bb:getType())
    shown:blitFrom(view.area_bb)
    render(view)
    local same = true
    for yy = 0, shown:getHeight() - 1, 7 do
        for xx = 0, shown:getWidth() - 1, 7 do
            if shown:getPixel(xx, yy):getColorRGB32().r ~= view.area_bb:getPixel(xx, yy):getColorRGB32().r then same = false; break end
        end
        if not same then break end
    end
    ok(same, "android: the page shown after the pan is the page at the final position")
    shown:free()
    ok(UIManager.scheduled[view._live_flush_cb] == nil, "android: nothing more is due once the pan ended")
    view.renderView = nil
    done()
end

------------------------------------------------------------------------------
-- Grey e-ink, not Android (Kindle, Kobo): unchanged, one refresh per sample
------------------------------------------------------------------------------
do
    local view, rs, clear, tick, done = world(false)
    local v = view.view
    ok(not view:onAndroid(), "kindle: not Android")
    local y = v.area_y + 400
    view:setTool("pen")
    clear()
    drag(view, tick, 200, 600, y, false)
    ok(#rs == 101, ("kindle: the touch and every pen sample refresh at once (%d of 101)"):format(#rs))
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()

    view:setTool("shape")
    view.shape, view.shape_fill, view.symmetry = "rect", false, "off"
    clear()
    drag(view, tick, 200, 600, y + 300, false)
    ok(#rs == 101, ("kindle: the touch and every shape move refresh at once (%d of 101)"):format(#rs))
    view:onIaPanRelease(nil, { pos = { x = 600, y = y + 340 } })

    view:setTool("lasso")
    clear()
    drag(view, tick, 150, 650, y + 500, false)
    ok(#rs == 125, ("kindle: every lasso sample refreshes at once (%d of 125)"):format(#rs))
    local r = rs[#rs].region
    ok(r.w == 28 and r.h == 28, "kindle: the lasso refresh is the same small box as before")
    view:onIaPanRelease(nil, { pos = { x = 150, y = y + 500 } })
    view:dropSelection()

    clear()
    local box = { x = 300, y = y, w = 200, h = 80 }
    view:refreshRectUnion(box, box, 4, "fast", true)
    view:refreshRectUnion(box, { x = 310, y = y, w = 200, h = 80 }, 4, "fast", true)
    ok(#rs == 2, "kindle: a text box drag refreshes every move at once")

    view:zoomStep(1); view:zoomStep(1)
    view:setTool("pan")
    view:onIaTouch(nil, { pos = { x = 900, y = y } })
    clear()
    for x = 896, 500, -4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    ok(#rs == 100 and not view._view_stale, ("kindle: every pan step redraws and refreshes at once (%d of 100)"):format(#rs))
    view:onIaPanRelease(nil, { pos = { x = 500, y = y } })
    ok(UIManager.scheduled[view._live_flush_cb] == nil, "kindle: nothing is ever held back")
    done()
end

print(("realbb android: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
