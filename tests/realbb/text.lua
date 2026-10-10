-- The text tool with KOReader's real fonts and blitter (see realtext.lua):
-- the grips and taps around the box being edited, and what the text draws.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/text.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
dofile(REPO .. "/tests/realbb/realtext.lua").install()
local Device = require("device")
local UIManager = require("ui/uimanager")
local Text = require("ink/text")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local W, H = 1072, 1448
local function newView(typ)
    Device.screen.bb = BB.new(W, H, typ or BB.TYPE_BB8)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
    Device.input.wacom_protocol = false
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    view:setTool("text")
    return view
end
local function tap(view, x, y)
    view:onIaTouch(nil, { pos = { x = x, y = y } })
    view:onIaTap(nil, { pos = { x = x, y = y } })
end
local function drag(view, x0, y0, x1, y1)
    view:onIaTouch(nil, { pos = { x = x0, y = y0 } })
    for i = 1, 8 do
        view:onIaPan(nil, { pos = { x = x0 + (x1 - x0) * i / 8, y = y0 + (y1 - y0) * i / 8 } })
    end
    view:onIaPanRelease(nil, { pos = { x = x1, y = y1 } })
end
local function type(view, s) for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do view:textAddChars(c) end end
-- How many dark pixels a bitmap has in a box (all of it by default).
local function darkIn(bb, x0, y0, x1, y1)
    x0, y0 = x0 or 0, y0 or 0
    x1, y1 = x1 or bb:getWidth(), y1 or bb:getHeight()
    local n = 0
    for y = math.max(0, y0), math.min(bb:getHeight(), y1) - 1 do
        for x = math.max(0, x0), math.min(bb:getWidth(), x1) - 1 do
            if bb:getPixel(x, y):getColorRGB32().r < 128 then n = n + 1 end
        end
    end
    return n
end

------------------------------------------------------------------------------
-- A tap away from the box only closes it; a tap on another box opens that one
------------------------------------------------------------------------------
do
    local view = newView()
    tap(view, 200, 300)
    ok(view.editing_text ~= nil, "a tap with Text starts a box")
    type(view, "First")
    tap(view, 500, 900)
    ok(view.editing_text == nil and #view.canvas.ops == 1, "a tap away saves the box and starts no other")
    ok(view._text_kb == nil, "and the keyboard stays away")
    tap(view, 500, 900)
    ok(view.editing_text ~= nil, "the next tap starts a new box")
    type(view, "Second")
    local first = view.canvas.ops[1]
    local fx, fy = require("ink/geom").toScreen(view.view, first.x + 10, first.y + first.h / 2)
    tap(view, fx, fy)
    ok(view.editing_text and Text.plain(view.editing_text) == "First" and #view.canvas.ops == 2,
        "a tap on another box saves this one and opens that")
    view:finishTextEdit(true)
    view:onCloseWidget()
end

------------------------------------------------------------------------------
-- Grips sized for a finger: move and resize just outside the corners, the band
-- around the frame moves the box when dragged and closes it when tapped, and
-- the inside always places the caret
------------------------------------------------------------------------------
do
    local view = newView()
    tap(view, 300, 400)
    type(view, "Grip test")
    local op = view.editing_text
    op.w = 500; view:invalidateLayout(); view:editTextLayout()
    local r = view:textBoxScreenRect()
    local g = view:textGrips()
    ok(g.reach >= 2 * g.r and g.reach >= Device.screen:scaleBySize(25),
        "grips reach further than they are drawn, about 9 mm across")
    local pts = view:textGripPoints()
    ok(pts.move.x < r.x and pts.move.y < r.y, "the move grip sits outside the top-left corner")
    ok(pts.resize.x > r.x + r.w and pts.resize.y > r.y + r.h, "the resize grip outside the bottom-right one")
    ok(view:textZone(pts.move.x, pts.move.y) == "move", "a finger on the move grip moves")
    ok(view:textZone(pts.resize.x + g.reach - 3, pts.resize.y) == "resize", "the resize grip reaches past its disc")
    ok(view:textZone(r.x + 3, r.y + 3) == "inside", "just inside the corner is the text, not the grip")
    ok(view:textZone(r.x + r.w - 3, r.y + r.h - 3) == "inside", "so is the bottom-right corner")
    ok(view:textZone(r.x + r.w / 4, r.y - g.band + 2) == "frame", "the band above the frame")
    ok(view:textZone(r.x + r.w / 4, r.y - g.band - 20) == "outside", "beyond it is outside")
    -- a drag on the band moves the box
    local x0 = op.x
    drag(view, r.x + r.w / 2, r.y - 4, r.x + r.w / 2 + 120, r.y - 4)
    ok(view.editing_text == op and math.abs(op.x - (x0 + 120 / view.view.zoom)) < 1, "dragging the band moves the box")
    -- a drag on the resize grip widens it
    local w0 = op.w
    pts = view:textGripPoints()
    drag(view, pts.resize.x, pts.resize.y, pts.resize.x - 100, pts.resize.y)
    ok(math.abs(op.w - (w0 - 100 / view.view.zoom)) < 1, "dragging the resize grip changes the width")
    -- a tap on the band closes the box, like a tap away
    r = view:textBoxScreenRect()
    tap(view, r.x + r.w / 2, r.y - 4)
    view:onIaPanRelease(nil, { pos = { x = r.x + r.w / 2, y = r.y - 4 } })
    ok(view.editing_text == nil and #view.canvas.ops == 1, "a tap on the band closes the box")
    -- the grips stay on the screen for a box that runs to the page's edges
    tap(view, 300, 400)
    op = view.editing_text
    local v = view.view
    op.x, op.w = 0, v.canvas_w
    view:invalidateLayout(); view:editTextLayout()
    pts = view:textGripPoints()
    ok(pts.move.x - g.r >= v.area_x and pts.resize.x + g.r < v.area_x + v.area_w,
        "a page-wide box keeps both grips whole on the screen")
    -- they are drawn
    local shot = BB.new(W, H, BB.TYPE_BB8); shot:fill(BB.COLOR_WHITE)
    view:paintTextOverlay(shot, 0, 0)
    ok(shot:getPixel(pts.move.x + g.r - 2, pts.move.y):getColorRGB32().r < 64, "the move grip is drawn")
    ok(shot:getPixel(pts.move.x, pts.move.y):getColorRGB32().r > 192, "with a light mark on it")
    ok(darkIn(shot, pts.resize.x - g.r, pts.resize.y - g.r, pts.resize.x + g.r, pts.resize.y + g.r) > g.r * g.r,
        "the resize grip is drawn")
    shot:free()
    view:finishTextEdit(true)
    view:onCloseWidget()
end

------------------------------------------------------------------------------
-- A turned box: a quarter turn draws exactly the upright pixels turned, any
-- angle stays on the box, the page under it is untouched, and exports match
------------------------------------------------------------------------------
do
    local Turn = require("ink/turn")
    local view = newView()
    local op = Text.new{ x = 300, y = 200, w = 400, size = 30 }
    Text.insert(op, { p = 1, o = 0 }, "Quarter turn")
    local up = BB.new(1072, 1448, BB.TYPE_BB8); up:fill(BB.COLOR_WHITE)
    view:stampTextInto(up, op)
    local h = op.h
    ok(h and h > 0, "the box is laid out")
    local turned = BB.new(1072, 1448, BB.TYPE_BB8); turned:fill(BB.COLOR_WHITE)
    op.angle = 90
    view:stampTextInto(turned, op)
    local same, total, stray = true, 0, 0
    for j = 0, math.ceil(h) - 1 do
        for i = 0, 399 do
            local a = up:getPixel(300 + i, 200 + j):getColor8().a
            local b = turned:getPixel(300 - j - 1, 200 + i):getColor8().a
            if a ~= b then same = false end
            if a < 128 then total = total + 1 end
        end
    end
    ok(total > 200 and same, "a quarter turn is the upright text, pixel for pixel, standing on end")
    -- nothing drawn outside the turned box
    for y = 0, 1447, 3 do
        for x = 0, 1071, 3 do
            if turned:getPixel(x, y):getColor8().a < 250 and not Text.contains(op, x + 0.5, y + 0.5, 4) then
                stray = stray + 1
            end
        end
    end
    ok(stray == 0, "a turned box draws only on itself")
    -- any angle: the ink under it stays exactly as it was where no letter falls
    local page = BB.new(600, 600, BB.TYPE_BB8)
    for y = 0, 599 do for x = 0, 599 do page:setPixel(x, y, BB.Color8((x * 7 + y * 13) % 256)) end end
    local before = page:copy()
    local op2 = Text.new{ x = 150, y = 300, w = 300, size = 28 }
    Text.insert(op2, { p = 1, o = 0 }, "Thirty degrees")
    op2.angle = 330
    view:stampTextInto(page, op2)
    local changed_off, changed_on = 0, 0
    for y = 0, 599 do
        for x = 0, 599 do
            if page:getPixel(x, y):getColor8().a ~= before:getPixel(x, y):getColor8().a then
                if Text.contains(op2, x + 0.5, y + 0.5, view:textOverhang(op2)) then changed_on = changed_on + 1
                else changed_off = changed_off + 1 end
            end
        end
    end
    ok(changed_on > 100 and changed_off == 0, "at 330 degrees the letters land on the box and nothing else changes")
    -- the same on a colour page
    local cpage = BB.new(600, 600, BB.TYPE_BBRGB32)
    cpage:paintRectRGB32(0, 0, 600, 600, BB.ColorRGB32(200, 230, 255, 255))
    view:stampTextInto(cpage, op2)
    local dark = 0
    for y = 0, 599, 2 do for x = 0, 599, 2 do
        local c = cpage:getPixel(x, y):getColorRGB32()
        if c.r < 100 and c.g < 100 and c.b < 100 then dark = dark + 1 end
    end end
    local corner = cpage:getPixel(2, 2):getColorRGB32()
    ok(dark > 30 and corner.r == 200 and corner.g == 230 and corner.b == 255, "and on a colour page")
    -- the exported raster sits where the screen draws it
    local raster, rw, rh, rx, ry = view:exportTextRaster(op)
    local hits, misses = 0, 0
    for j = 0, rh - 1 do for i = 0, rw - 1 do
        if raster[j * rw + i] < 128 then
            if turned:getPixel(rx + i, ry + j):getColor8().a < 128 then hits = hits + 1 else misses = misses + 1 end
        end
    end end
    ok(rx and hits > 200 and misses == 0, "the export of a turned box matches the screen")
    -- a turned box shows in the page's box and is found where it is drawn
    local x0, y0, x1, y1 = require("ink/canvas").opBox(op)
    ok(math.abs(x0 - (300 - h)) < 1e-6 and math.abs(y1 - 600) < 1e-6, "its page box is the turned box")
    view.canvas:pushHistory(); view.canvas:placeOp(op)
    ok(view:textOpAt(300 - h / 2, 390) == op and view:textOpAt(350, 220) == nil,
        "a tap finds it where it is drawn, not where it was")
    up:free(); turned:free(); page:free(); before:free(); cpage:free()
    view:onCloseWidget()
    -- quarter turns paint upright bitmaps of every kind
    local probe = BB.new(50, 50, BB.TYPE_BB8); probe:fill(BB.COLOR_WHITE)
    Turn.paint(probe, 40, 10, 0, 1, 20, 10, 0, function(b, x, y) b:paintRect(x, y, 20, 10, BB.COLOR_BLACK) end)
    ok(probe:getPixel(35, 25):getColor8().a == 0 and probe:getPixel(29, 25):getColor8().a == 255
        and probe:getPixel(35, 31):getColor8().a == 255, "Turn.paint: a 20 x 10 block turned is 10 x 20")
    probe:free()
end

------------------------------------------------------------------------------
-- Editing a turned box: the grips go round with it, the turning grip turns it
-- about its middle (snapping to quarter turns), a tap places the caret along its
-- lines, and the resize grip follows its lines
------------------------------------------------------------------------------
do
    local view = newView()
    tap(view, 200, 300)
    type(view, "ABCDEFGHIJ")
    local op = view.editing_text
    op.w = 400; view:invalidateLayout(); view:editTextLayout()
    local g = view:textGrips()
    local pts = view:textGripPoints()
    local r = view:textBoxScreenRect()
    ok(math.abs(pts.turn.x - (r.x + r.w / 2)) <= 1 and pts.turn.y < r.y - g.stem / 2, "the turning grip stands above the middle")
    ok(view:textZone(pts.turn.x, pts.turn.y) == "turn", "a finger on it turns")
    local cx, cy = Text.centre(op)
    local scx, scy = require("ink/geom").toScreen(view.view, cx, cy)
    -- drag it a quarter turn round the middle (and a little more: it snaps)
    local rad = scy - pts.turn.y
    drag(view, pts.turn.x, pts.turn.y, scx + rad * math.cos(math.rad(3)), scy + rad * math.sin(math.rad(3)))
    local ncx, ncy = Text.centre(op)
    ok(op.angle == 90, "a quarter turn of the grip snaps the box to 90 degrees")
    ok(math.abs(ncx - cx) < 1e-6 and math.abs(ncy - cy) < 1e-6, "turned about its middle")
    pts = view:textGripPoints()
    ok(view:textZone(pts.turn.x, pts.turn.y) == "turn" and pts.turn.x > scx, "the grip went round with it")
    -- a tap near the end of its line puts the caret there
    local ex, ey = view:textToScreen(op.w * view.view.zoom * 0.98, op.h * view.view.zoom / 2)
    local lay = view:editTextLayout()
    local endx = Text.caret(op, lay, { p = 1, o = 10 }, view:textCtx(op, view.view.zoom)).x
    ex, ey = view:textToScreen(endx - 2, op.h * view.view.zoom / 2)
    tap(view, ex, ey)
    ok(view.editing_text == op and view.text_cur.o >= 9, "a tap at the far end of a turned line puts the caret there")
    -- the resize grip drags along the lines: down the page now
    local w0 = op.w
    pts = view:textGripPoints()
    drag(view, pts.resize.x, pts.resize.y, pts.resize.x + 30, pts.resize.y + 100)
    ok(math.abs(op.w - (w0 + 100 / view.view.zoom)) < 1, "resizing a turned box follows its lines")
    -- it paints turned, with its grips on the screen
    local shot = BB.new(W, H, BB.TYPE_BB8); shot:fill(BB.COLOR_WHITE)
    view:paintTextOverlay(shot, 0, 0)
    r = view:textBoxScreenRect()
    ok(r.h > r.w and darkIn(shot, r.x, r.y, r.x + r.w, r.y + r.h) > 100, "the turned box is drawn standing up")
    shot:free()
    view:finishTextEdit(true)
    ok(view.canvas.ops[1].angle == 90, "it is saved turned")
    -- on the page and in a thumbnail it is drawn turned as well
    view:composeCanvas()
    local x0, y0, x1, y1 = require("ink/canvas").opBox(view.canvas.ops[1])
    ok(darkIn(view.canvas_bb, math.floor(x0), math.floor(y0), math.ceil(x1), math.ceil(y1)) > 100,
        "the page shows the turned box")
    view:onCloseWidget()
end

print(("realbb text: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
