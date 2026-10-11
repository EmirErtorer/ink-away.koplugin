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
local Palette = require("ink/palette")

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
local function findButton(w, text)
    local function has(t, seen)
        if _G.type(t) ~= "table" or seen[t] then return false end
        seen[t] = true
        if t.text == text then return true end
        for k, val in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" and has(val, seen) then return true end
        end
        return false
    end
    local function find(t, seen)
        if _G.type(t) ~= "table" or seen[t] then return nil end
        seen[t] = true
        if _G.type(t.callback) == "function" and has(t, {}) then return t end
        for k, val in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" then
                local f = find(val, seen); if f then return f end
            end
        end
    end
    return find(w, {})
end
local function press(view, label)
    local b = findButton(view._text_fmt, label)
    if b then b.callback() end
    return b ~= nil
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
        if raster[(j * rw + i) * 3] < 128 then
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

------------------------------------------------------------------------------
-- On colour e-ink, dragging a text box (moving, resizing, turning) and the
-- export box waits for the panel before each refresh after the first, as a
-- shape's outline does: each covers the whole box, and the panel would queue
-- them. Grey e-ink and the emulator do not wait.
------------------------------------------------------------------------------
do
    local function drags(typ, emulator)
        local had = Device.isEmulator
        if emulator then Device.isEmulator = function() return true end end
        local view = newView(typ)
        tap(view, 300, 400)
        type(view, "Paced")
        local out = {}
        local function count(kind, fn)
            UIManager.vsyncs = 0
            local n = fn()
            out[kind] = { UIManager.vsyncs, n }
        end
        count("move", function()
            local pts = view:textGripPoints()
            view:onIaTouch(nil, { pos = { x = pts.move.x, y = pts.move.y } })
            for i = 1, 20 do view:onIaPan(nil, { pos = { x = pts.move.x + 6 * i, y = pts.move.y + 4 * i } }) end
            view:onIaPanRelease(nil, { pos = { x = pts.move.x + 120, y = pts.move.y + 80 } })
            return 20
        end)
        count("resize", function()
            local pts = view:textGripPoints()
            view:onIaTouch(nil, { pos = { x = pts.resize.x, y = pts.resize.y } })
            for i = 1, 20 do view:onIaPan(nil, { pos = { x = pts.resize.x - 5 * i, y = pts.resize.y } }) end
            view:onIaPanRelease(nil, { pos = { x = pts.resize.x - 100, y = pts.resize.y } })
            return 20
        end)
        count("turn", function()
            local pts = view:textGripPoints()
            local cx, cy = Text.centre(view.editing_text)
            local sx, sy = require("ink/geom").toScreen(view.view, cx, cy)
            local rad = math.sqrt((pts.turn.x - sx) ^ 2 + (pts.turn.y - sy) ^ 2)
            local a0 = math.atan2(pts.turn.y - sy, pts.turn.x - sx)
            view:onIaTouch(nil, { pos = { x = pts.turn.x, y = pts.turn.y } })
            for i = 1, 20 do
                local a = a0 + math.rad(2 * i)
                view:onIaPan(nil, { pos = { x = sx + rad * math.cos(a), y = sy + rad * math.sin(a) } })
            end
            view:onIaPanRelease(nil, { pos = { x = sx, y = sy - rad } })
            return 20
        end)
        local turned = view.editing_text.angle
        view:finishTextEdit(true)
        count("export", function()
            local v = view.view
            view:cropTouch({ x = v.area_x + 50, y = v.area_y + 50 })
            for i = 1, 20 do view:cropMove({ x = v.area_x + 50 + 20 * i, y = v.area_y + 50 + 30 * i }) end
            view:cropRelease({ x = v.area_x + 450, y = v.area_y + 650 })
            return 20
        end)
        view:onCloseWidget()
        Device.isEmulator = had
        return out, turned
    end
    local c, turned = drags(BB.TYPE_BBRGB32)
    ok(turned and turned > 30 and turned < 50, "the turn drag turned the box")
    for _, k in ipairs({ "move", "resize", "turn", "export" }) do
        local w, n = c[k][1], c[k][2]
        -- (the first moves within a finger's wobble are no drag yet)
        ok(w >= n - 6 and w < n, ("%s, colour: each refresh after the first waits for the panel (%d of %d moves)"):format(k, w, n))
    end
    local g = drags(BB.TYPE_BB8)
    local e = drags(BB.TYPE_BBRGB32, true)
    for _, k in ipairs({ "move", "resize", "turn", "export" }) do
        ok(g[k][1] == 0, k .. ", grey e-ink: no waiting")
        ok(e[k][1] == 0, k .. ", emulator: no waiting")
    end
end

------------------------------------------------------------------------------
-- Colours: a word in a colour, highlights in colours, on colour and grey
-- screens and on a dark paper, and in exports
------------------------------------------------------------------------------
do
    local Export = require("ink/export")
    local function rgbAt(bb, x, y) local c = bb:getPixel(x, y):getColorRGB32(); return c.r, c.g, c.b end
    local function boxOf(op) return math.floor(op.x), math.floor(op.y), math.ceil(op.x + op.w), math.ceil(op.y + op.h) end
    -- counts pixels of a kind in a box
    local function countIn(bb, x0, y0, x1, y1, pred)
        local n = 0
        for y = y0, y1 - 1 do for x = x0, x1 - 1 do if pred(rgbAt(bb, x, y)) then n = n + 1 end end end
        return n
    end
    local function reddish(r, g, b) return r > 150 and g < 90 and b < 90 end
    local function yellowish(r, g, b) return r > 200 and g > 190 and b < 120 end
    local function blueish(r, g, b) return b > 200 and r < 140 end
    for _, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
        local colour = typ == BB.TYPE_BBRGB32
        local tag = colour and "colour" or "grey"
        local view = newView(typ)
        local op = Text.new{ x = 100, y = 200, w = 700, size = 40 }
        Text.insert(op, { p = 1, o = 0 }, "Red word, yellow mark, blue mark")
        Text.applyStyle(op, { a = { p = 1, o = 0 }, b = { p = 1, o = 8 } }, "c", Text.packRGB({ 0xD0, 0, 0 }))
        Text.applyStyle(op, { a = { p = 1, o = 10 }, b = { p = 1, o = 21 } }, "hl", true)
        Text.applyStyle(op, { a = { p = 1, o = 23 }, b = { p = 1, o = 32 } }, "hl", Text.packRGB(Palette.HIGHLIGHTS[3].rgb))
        local page = BB.new(1000, 600, typ); page:fill(BB.COLOR_WHITE)
        view:stampTextInto(page, op)
        local x0, y0, x1, y1 = boxOf(op)
        local red, yellow, blue = countIn(page, x0, y0, x1, y1, reddish), countIn(page, x0, y0, x1, y1, yellowish),
            countIn(page, x0, y0, x1, y1, blueish)
        if colour then
            ok(red > 50, tag .. ": the red word is red")
            ok(yellow > 500 and blue > 500, tag .. ": the default highlight is yellow and the other blue")
        else
            local grey = countIn(page, x0, y0, x1, y1, function(r) return r > 150 and r < 215 end)
            ok(red == 0 and yellow == 0 and blue == 0 and grey > 1000, tag .. ": colours show as grey, highlights the one grey")

        end
        -- the letters on a highlight stay black
        local dark = countIn(page, x0, y0, x1, y1, function(r, g, b) return r < 60 and g < 60 and b < 60 end)
        ok(dark > 200, tag .. ": the letters stay dark")
        -- the export draws the colours as the screen does
        Export.text_raster = function(o, paper, ink) return view:exportTextRaster(o, paper, ink) end
        local c = require("ink/canvas").new(1000, 600)
        c.ops = { op }
        local rgb = Export.buildRGB(c)
        local function px3(x, y) local o = (y * 1000 + x) * 3; return rgb[o], rgb[o + 1], rgb[o + 2] end
        local ered, eyel = 0, 0
        for y = y0, y1 - 1 do for x = x0, x1 - 1 do
            local r, g, b = px3(x, y)
            if reddish(r, g, b) then ered = ered + 1 end
            if yellowish(r, g, b) then eyel = eyel + 1 end
        end end
        ok(colour and (ered > 50 and eyel > 500) or (not colour and ered == 0 and eyel == 0),
            tag .. ": the export shows the same colours")
        Export.text_raster = nil
        page:free()
        view:onCloseWidget()
    end
    -- on a dark paper the highlight is toned down and the letters are white
    local view = newView(BB.TYPE_BBRGB32)
    view.paperRGB = function() return { 0, 0, 0 } end
    local op = Text.new{ x = 50, y = 50, w = 600, size = 40 }
    Text.insert(op, { p = 1, o = 0 }, "Marked on black")
    Text.applyStyle(op, { a = { p = 1, o = 0 }, b = { p = 1, o = 6 } }, "hl", true)
    local page = BB.new(800, 300, BB.TYPE_BBRGB32); page:fill(BB.COLOR_BLACK)
    view:stampTextInto(page, op, nil, BB.COLOR_WHITE)
    local mark = countIn(page, 50, 50, 650, 50 + math.ceil(op.h), function(r, g, b) return r > 90 and r < 140 and g > 90 and b < 60 end)
    local white = countIn(page, 50, 50, 650, 50 + math.ceil(op.h), function(r, g, b) return r > 220 and g > 220 and b > 220 end)
    ok(mark > 300 and white > 100, "dark paper: a toned-down highlight under white letters")
    page:free()
    view:onCloseWidget()
end

------------------------------------------------------------------------------
-- The Format sheet stays open while options are picked; Done brings the
-- keyboard back. Its tabs: Text, Paragraph, Edit.
------------------------------------------------------------------------------
do
    local view = newView(BB.TYPE_BBRGB32)
    tap(view, 200, 300)
    type(view, "one two three")
    local op = view.editing_text
    view:openTextFormatMenu()
    ok(view._text_fmt ~= nil and view._text_kb == nil, "Format takes the keyboard's place")
    -- the caret is after "three": Bold applies to that word, and the sheet stays
    ok(press(view, "Bold"), "the Text tab has Bold")
    ok(view._text_fmt ~= nil and view._text_kb == nil, "picking an option keeps the sheet open")
    ok(press(view, "Italic") and view._text_fmt ~= nil, "so a second one can follow")
    local st = Text.styleAt(op, { p = 1, o = 12 })
    ok(st.b and st.i and not Text.styleAt(op, { p = 1, o = 3 }).b, "both went on the word under the caret")
    press(view, "A+")
    ok((Text.styleAt(op, { p = 1, o = 12 }).sz or 1) > 1.1, "A+ grows it, sheet still open")
    press(view, "Plain")
    st = Text.styleAt(op, { p = 1, o = 12 })
    ok(not (st.b or st.i or st.sz), "Plain takes every style off")
    -- colours through the same path the swatches use
    view:textSetStyle("c", Text.packRGB({ 0, 0x50, 0xD0 }))
    view:textSetStyle("hl", Text.packRGB(Palette.HIGHLIGHTS[4].rgb))
    ok(view:textStyleValue("c") == Text.packRGB({ 0, 0x50, 0xD0 }) and view:textStyleValue("hl") == Text.packRGB(Palette.HIGHLIGHTS[4].rgb),
        "a colour and a highlight on the word")
    view:textSetStyle("hl", nil)
    ok(view:textStyleValue("hl") == nil, "None takes the highlight off")
    -- the Paragraph tab
    ok(press(view, "Paragraph"), "a Paragraph tab")
    ok(press(view, "Centre") and op.align == "center", "alignment: centre")
    ok(press(view, "Right") and op.align == "right", "alignment: right")
    ok(press(view, "Loose") and op.spacing == "loose", "line spacing: loose")
    local h_loose = op.h
    press(view, "Tight")
    ok(op.spacing == "tight" and op.h < h_loose, "tight lines take less room")
    press(view, "Normal")
    ok(op.spacing == nil, "and back to normal")
    ok(press(view, "\u{2713} Checklist") and op.paras[1].bullet == "check", "a checklist")
    ok(findButton(view._text_fmt, "Font: Default") ~= nil, "the font is one tap away")
    -- a new box stood on end starts where it was tapped (in a book's margin it
    -- would otherwise stand on the text)
    local tx, ty = view:toCanvasClamped(200, 300)
    ok(press(view, "Reads down") and op.angle == 90, "reading down")
    local nx0, ny0 = Text.bounds(op)
    ok(math.abs(nx0 - tx) < 1 and math.abs(ny0 - ty) < 1, "its top-left is where the box was tapped")
    local _a, _b, _c, ny1 = Text.bounds(op)
    ok(ny1 <= view.view.canvas_h, "a line too long for the page there is shortened")
    ok(press(view, "Reads up") and op.angle == 270, "reading up")
    ok(press(view, "Across") and op.angle == nil, "and across again")
    local ax0, ay0, ax1 = Text.bounds(op)
    ok(ax0 >= 0 and ax1 <= view.view.canvas_w and ay0 >= 0, "kept on the page")
    -- an old box keeps its top-left where it shows
    view._text_tap_at = nil
    local bx0, by0 = Text.bounds(op)
    press(view, "Reads up")
    nx0, ny0 = Text.bounds(op)
    ok(op.angle == 270 and math.abs(nx0 - bx0) < 1 and math.abs(ny0 - by0) < 1, "a box opened again turns where it shows")
    press(view, "Across")
    -- the Edit tab
    ok(press(view, "Edit"), "an Edit tab")
    ok(press(view, "Select all") and Text.plainRange(op, view.text_sel) == "one two three", "Select all")
    view.text_sel = nil
    view.text_cur = { p = 1, o = 0 }
    ok(press(view, "Date") and #Text.plain(op) > #"one two three" + 6, "the date is typed at the caret")
    -- Done brings the keyboard back
    local done = findButton(view._text_fmt, "Done")
    done.callback()
    ok(view._text_fmt == nil and view._text_kb ~= nil, "Done closes Format and brings the keyboard back")
    -- a tap outside it does too
    view:openTextFormatMenu()
    view._text_fmt:onCloseMenu()
    ok(view._text_kb ~= nil, "closing it any other way brings the keyboard back too")
    view:finishTextEdit(true)
    view:onCloseWidget()
end

------------------------------------------------------------------------------
-- Checklists: a tap on the box ticks it, in an open box and on a saved one (an
-- undo step); a double tap on a word selects it
------------------------------------------------------------------------------
do
    local view = newView()
    tap(view, 200, 300)
    type(view, "milk")
    view:textAddChars("\n")
    type(view, "eggs")
    local op = view.editing_text
    Text.setBullet(op, { a = { p = 1, o = 0 }, b = { p = 2, o = 0 } }, "check")
    view:invalidateLayout()
    local lay = view:editTextLayout()
    local ln1
    for _, ln in ipairs(lay.lines) do if ln.para == 1 then ln1 = ln; break end end
    ok(ln1 and ln1.bullet and ln1.bullet.check and ln1.text_x > 0, "a checklist item has its box and indent")
    local bx, by = view:textToScreen(ln1.bullet.box / 2 + 1, ln1.top + ln1.height / 2)
    tap(view, bx, by)
    ok(op.paras[1].checked == true and not op.paras[2].checked, "a tap on its box ticks the item")
    ok(view.text_cur.p == 2, "and leaves the caret where it was")
    -- the ticked item draws its box with a tick and greyed letters
    local shot = BB.new(W, H, BB.TYPE_BB8); shot:fill(BB.COLOR_WHITE)
    view:paintTextOverlay(shot, 0, 0)
    local r = view:textBoxScreenRect()
    local grey = 0
    for y = math.floor(r.y), math.floor(r.y + ln1.height) do
        for x = math.floor(r.x + ln1.text_x), math.floor(r.x + r.w) do
            local a = shot:getPixel(x, y):getColor8().a
            if a > 100 and a < 200 then grey = grey + 1 end
        end
    end
    ok(grey > 30, "a ticked item's letters are greyed")
    shot:free()
    view:textUndo()
    ok(not op.paras[1].checked, "undo unticks it")
    view:finishTextEdit(true)
    -- on the saved box: a tap on the second item's box ticks it without opening
    local saved = view.canvas.ops[1]
    local slay = view:layoutText(saved, 1)
    local l2
    for _, ln in ipairs(slay.lines) do if ln.para == 2 then l2 = ln end end
    local px, py = Text.toPage(saved, l2.bullet.box / 2 + 1, l2.top + l2.height / 2)
    local sx, sy = require("ink/geom").toScreen(view.view, px, py)
    tap(view, sx, sy)
    ok(view.editing_text == nil and view.canvas.ops[1].paras[2].checked == true, "a tap on a saved box's item ticks it, the box stays closed")
    ok(saved.paras[2].checked == nil, "the old box is kept for undo")
    view:undo()
    ok(not view.canvas.ops[1].paras[2].checked, "one undo unticks it")
    -- a double tap on a word selects it, and keeps the keyboard
    local wx, wy = Text.toPage(view.canvas.ops[1], l2.text_x + 10, l2.top + l2.height / 2)
    sx, sy = require("ink/geom").toScreen(view.view, wx, wy)
    tap(view, sx, sy)
    ok(view.editing_text ~= nil, "a tap on the word opens the box")
    view:showPendingKeyboard()
    tap(view, sx, sy)
    ok(view.text_sel and Text.plainRange(view.editing_text, view.text_sel) == "eggs", "a second tap selects the word")
    ok(view._text_fmt == nil and view._text_kb ~= nil, "and the keyboard stays, to type over it")
    view:textAddChars("X")
    ok(Text.plain(view.editing_text) == "milk\nX", "typing replaces the word")
    view:finishTextEdit(true)
    view:onCloseWidget()
end

------------------------------------------------------------------------------
-- Saved text and highlight colours: up to three of each, the oldest goes
------------------------------------------------------------------------------
do
    local view = newView(BB.TYPE_BBRGB32)
    for i = 1, 4 do view:textSaveColour("mark", { i * 40, 100, 100 }) end
    local list = view:textSavedColours("mark")
    ok(#list == 3 and list[1][1] == 80 and list[3][1] == 160, "three highlight colours kept, the oldest gone")
    view:textSaveColour("mark", { 120, 100, 100 })
    ok(#view:textSavedColours("mark") == 3, "saving one already kept adds nothing")
    view:textForgetColour("mark", { 120, 100, 100 })
    list = view:textSavedColours("mark")
    ok(#list == 2 and list[1][1] == 80 and list[2][1] == 160, "a hold removes one")
    ok(#view:textSavedColours("ink") == 0, "text colours are kept apart")
    view:onCloseWidget()
end

print(("realbb text: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
