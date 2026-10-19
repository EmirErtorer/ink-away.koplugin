-- The eraser's outline on KOReader's REAL blitter, colour (RGB32) and grey (BB8):
-- while erasing a ring sits exactly on the edge of what the eraser clears, at
-- any zoom and with Erase whole strokes too, and it never changes the drawing:
-- the same stroke erased without the outline leaves the very same screen,
-- outside the ring while erasing and everywhere after the lift.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/erasecursor.lua <repo>
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
local EraserRing = require("ink/ui/eraserring")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function grey(bb, x, y) return bb:getPixel(x, y):getColorRGB32().r end

-- Draw a thick line, then erase down across it. Returns the screen while the
-- eraser is still down and after the lift (copies), the outline's state, the
-- view's zoom, and whether closing freed what the outline kept.
local function run(typ, case, outline)
    local W, H = 1264, 1680
    Device.screen.bb = BB.new(W, H, typ)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
    Device.input.wacom_protocol = false
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    view.erase_whole = case.whole or false
    if not outline then
        view.eraserCursorShow = function() end
        view.eraserCursorHide = function() end
    end
    local v = view.view
    if case.zoom ~= 1 then view:setZoom(case.zoom) end
    local function scr(cx, cy) return v.area_x + (cx - v.pan_x) * v.zoom, v.area_y + (cy - v.pan_y) * v.zoom end
    local cy = v.pan_y + v.area_h / v.zoom / 2
    local cx0, cx1 = v.pan_x + 40, v.pan_x + v.area_w / v.zoom - 40
    view:setTool("pen"); view.pen_width = 12
    local sx, sy = scr(cx0, cy)
    view:onIaTouch(nil, { pos = { x = sx, y = sy } })
    for x = cx0, cx1, 4 do local px, py = scr(x, cy); view:onIaPan(nil, { pos = { x = px, y = py } }) end
    local ex, ey = scr(cx1, cy)
    view:onIaPanRelease(nil, { pos = { x = ex, y = ey } }); view:flushPending()
    ok(view.eraser_outline == false, "the outline is off unless turned on")
    view.eraser_outline = true
    view:setTool("erase"); view.eraser_width = 40
    local mx = (cx0 + cx1) / 2
    local fx, fy = scr(mx, cy - 60)
    view:onIaTouch(nil, { pos = { x = fx, y = fy } })
    local tx, ty
    for yy = cy - 60, cy + 80, 3 do
        tx, ty = scr(mx, yy)
        view:onIaPan(nil, { pos = { x = tx, y = ty } })
    end
    local down = BB.new(v.area_w, v.area_h, typ)
    down:blitFrom(view.area_bb, 0, 0, 0, 0, v.area_w, v.area_h)
    local c = view._ecur
    view:onIaPanRelease(nil, { pos = { x = tx, y = ty } })
    local lifted = view._ecur == nil
    local after = BB.new(v.area_w, v.area_h, typ)
    after:blitFrom(view.area_bb, 0, 0, 0, 0, v.area_w, v.area_h)
    local zoom = v.zoom
    view:flushPending()
    view:onCloseWidget()
    return down, after, c, lifted, zoom, view._ecur_under == nil
end

-- pixels of a and b that differ, outside the box (x, y, w, h) when given
local function differ(a, b, box)
    local n = 0
    for y = 0, a:getHeight() - 1 do
        for x = 0, a:getWidth() - 1 do
            local inside = box and x >= box[1] and x < box[1] + box[3] and y >= box[2] and y < box[2] + box[4]
            if not inside and grey(a, x, y) ~= grey(b, x, y) then n = n + 1 end
        end
    end
    return n
end

for _, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    for _, case in ipairs({ { zoom = 1 }, { zoom = 2 }, { zoom = 1, whole = true } }) do
        local tag = (typ == BB.TYPE_BBRGB32 and "colour" or "grey") .. " / zoom " .. case.zoom
            .. (case.whole and " / whole strokes" or "")
        local plain_down, plain_after = run(typ, case, false)
        local down, after, c, lifted, zoom, freed = run(typ, case, true)
        ok(c ~= nil, tag .. ": erasing shows the outline")
        if c then
            local r = 40 / 2 * zoom
            ok(math.abs(c.r - r) < 1e-6, tag .. ": at the eraser's size at this zoom")
            local ax, ay = math.floor(c.cx), math.floor(c.cy)
            local line = EraserRing.line()
            ok(grey(down, ax + math.floor(r) - 1, ay) == 0 and grey(down, ax - math.floor(r), ay) == 0
                and grey(down, ax, ay + math.floor(r) - 1) == 0, tag .. ": its ring is black just inside the eraser's edge")
            ok(grey(down, ax + math.floor(r - line) - 2, ay) == 255, tag .. ": with a white line inside the black")
            ok(grey(down, ax, ay) == grey(plain_down, ax, ay), tag .. ": and the page as it is in its middle")
            ok(differ(down, plain_down, { c.x, c.y, c.w, c.h }) == 0,
                tag .. ": outside the ring the screen is what erasing without it shows")
        end
        ok(lifted, tag .. ": the lift takes the outline away")
        local n = differ(after, plain_after)
        ok(n == 0, tag .. ": after the lift no trace of it is left (" .. n .. " px)")
        ok(freed, tag .. ": closing frees what the outline kept")
        for _, b in ipairs({ plain_down, plain_after, down, after }) do b:free() end
    end
end
print(("realbb erasecursor: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
