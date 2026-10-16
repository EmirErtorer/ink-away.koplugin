-- The lift of a pen whose width changes, on KOReader's REAL blitter: only what
-- the lift changes is drawn again (a Ballpoint's or Fountain's tapered end;
-- nothing for Calligraphy or a pressed Pencil; all of a see-through pen), and
-- the page then is what a full redraw from the saved strokes gives (what
-- thumbnails, exports and the notebook opened again show), but for a pixel or
-- two of the simplification along a stroke, as with any pen; the screen shows
-- it at once, mirrored, zoomed in and after a paint during the stroke.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/lift.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local ffi = require("ffi")
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

local W, H = 1264, 1680
local function world()
    Device.screen.bb = BB.new(W, H, BB.TYPE_BB8)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return false end
    UIManager.reset()
    package.loaded["ink/view"] = nil
    local view = require("ink/view"):new{}
    UIManager:show(view)
    view.hold_straighten = false
    local clock = 0
    view.nowMs = function() return clock end
    return view, function(ms) clock = clock + ms end
end

-- Pen pressure (Beta) on with a pen in hand: the strokes here come in by finger,
-- so the pen's own pressure is taken as on (the pressure is then full, as a pen
-- held evenly gives)
local function pressureOn(view)
    view.pen_pressure = true
    view.realPressure = function() return true end
end

-- a word's worth of letters: loops, a straight downstroke and a crossbar
local function letters(x0, y0)
    local out = {}
    for k = 0, 3 do
        local pts = {}
        for i = 0, 30 do
            local a = i / 30 * math.pi * 2.2
            pts[#pts + 1] = x0 + k * 110 + 30 * math.sin(a) + i * 2
            pts[#pts + 1] = y0 + 40 * math.cos(a * 0.9)
        end
        out[#out + 1] = pts
    end
    local down = {}
    for i = 0, 20 do down[#down + 1] = x0 + 480; down[#down + 1] = y0 - 60 + i * 8 end
    out[#out + 1] = down
    local bar = {}
    for i = 0, 20 do bar[#bar + 1] = x0 + 440 + i * 5; bar[#bar + 1] = y0 - 10 end
    out[#out + 1] = bar
    return out
end

-- draw strokes with the pen, as a hand does (5 ms between samples)
local function write(view, tick, strokes)
    local v = view.view
    local function at(x, y) return { pos = { x = v.area_x + x, y = v.area_y + y } } end
    for _, pts in ipairs(strokes) do
        view:onIaTouch(nil, at(pts[1], pts[2]))
        for i = 3, #pts - 1, 2 do tick(5); view:onIaPan(nil, at(pts[i], pts[i + 1])) end
        view:onIaPanRelease(nil, at(pts[#pts - 1], pts[#pts]))
        view:flushPending()
        tick(300)
    end
end

-- inked pixels of the page, and how many differ between two copies of it
local function inked(bb)
    local n = 0
    for y = 0, bb:getHeight() - 1 do
        for x = 0, bb:getWidth() - 1 do if bb:getPixel(x, y):getColor8().a < 128 then n = n + 1 end end
    end
    return n
end
-- pixels inked in one copy and not the other: all of them, and those with no
-- ink of the other copy within `r` px (more than an edge moved by a pixel)
local function differ(a, b, r)
    r = r or 1
    local w, h = a:getWidth(), a:getHeight()
    local function at(bb, x, y)
        return x >= 0 and y >= 0 and x < w and y < h and bb:getPixel(x, y):getColor8().a < 128
    end
    local function near(bb, x, y)
        for dy = -r, r do for dx = -r, r do if at(bb, x + dx, y + dy) then return true end end end
        return false
    end
    local n, far = 0, 0
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local ia, ib = at(a, x, y), at(b, x, y)
            if ia ~= ib then
                n = n + 1
                if not near(ia and b or a, x, y) then far = far + 1 end
            end
        end
    end
    return n, far
end

for _, case in ipairs({
    { pen = "ballpoint" }, { pen = "fountain" }, { pen = "calligraphy" }, { pen = "pencil" }, { pen = "solid" },
}) do
    local view, tick = world()
    view:choosePenType(case.pen)
    view:setTool("pen")
    pressureOn(view)
    -- each lift: what it redraws, and the time it takes
    local redrawn = {}
    local comp = view.composeRegion
    view.composeRegion = function(self, x0, y0, x1, y1)
        redrawn[#redrawn + 1] = (x1 - x0) * (y1 - y0)
        return comp(self, x0, y0, x1, y1)
    end
    write(view, tick, letters(200, 400))
    write(view, tick, letters(200, 700))
    view.composeRegion = comp
    local after = view.canvas_bb:copy()
    local pressured = false
    for _, op in ipairs(view.canvas.ops) do if op.pr then pressured = true end end
    -- what a full redraw from the saved strokes gives
    view:composeCanvas()
    local full = view.canvas_bb
    local ink = inked(full)
    local diff, far = differ(after, full, 1)
    local tag = case.pen
    ok(ink > 0, tag .. ": the strokes are on the page")
    print(("  %s: %d of %d inked pixels differ from a full redraw, %d of them more than a pixel from the other's ink")
        :format(tag, diff, ink, far))
    -- (a Fountain's width follows each segment's direction, and the
    -- simplification turns a curve's segments a little; a Pencil's grain is
    -- sampled where its segments fall: a few pixels each, never a stroke)
    ok(diff <= ink * 0.04 and far <= ink * 0.0025,
        ("%s: after the lifts the page is the saved strokes', but for edges a pixel off (%d differ, %d further)")
        :format(tag, diff, far))
    local area = 0
    for _, a in ipairs(redrawn) do area = area + a end
    if case.pen == "ballpoint" or case.pen == "fountain" then
        ok(pressured, tag .. ": the strokes keep a pressure per point")
        ok(#redrawn == 12 and area < 12 * 60 * 60 * 4, ("%s: each lift redraws only its tapered end (%d redraws, %d px in all)")
            :format(tag, #redrawn, area))
    elseif case.pen == "calligraphy" or case.pen == "pencil" then
        ok(pressured, tag .. ": the strokes keep a pressure per point")
        ok(#redrawn == 0, ("%s: a lift redraws nothing (%d redraws)"):format(tag, #redrawn))
    else
        ok(#redrawn == 0, ("%s: a lift redraws nothing, as before (%d redraws)"):format(tag, #redrawn))
    end
    after:free()
    view:onCloseWidget()
end

-- mirrored: each copy's end is drawn again too
for _, sym in ipairs({ "vert", "quad" }) do
    local view, tick = world()
    view:choosePenType("ballpoint")
    view:setTool("pen")
    pressureOn(view)
    view.symmetry = sym
    write(view, tick, letters(150, 400))
    local after = view.canvas_bb:copy()
    view:composeCanvas()
    local ink = inked(view.canvas_bb)
    local diff, far = differ(after, view.canvas_bb, 1)
    local mirrored = view.canvas.ops[1] and view.canvas.ops[1].sym == sym
    ok(mirrored and diff <= ink * 0.04 and far <= ink * 0.0025,
        ("symmetry %s: every copy is the saved strokes', but for edges a pixel off (%d of %d differ, %d further)")
        :format(sym, diff, ink, far))
    after:free()
    view:onCloseWidget()
end

-- a tapered end is drawn at the lift: the last few widths of a straight
-- Ballpoint stroke thin out, as the saved stroke draws them
do
    local view, tick = world()
    view:choosePenType("ballpoint")
    view:setTool("pen")
    pressureOn(view)
    local pts = {}
    for i = 0, 60 do pts[#pts + 1] = 200 + i * 10; pts[#pts + 1] = 900 end
    write(view, tick, { pts })
    local v = view.view
    local function thick(x)
        local cx, cy = view:toCanvasClamped(v.area_x + x, v.area_y + 900)
        local t = 0
        for dy = -40, 40 do
            if view.canvas_bb:getPixel(math.floor(cx), math.floor(cy) + dy):getColor8().a < 128 then t = t + 1 end
        end
        return t
    end
    ok(thick(798) < thick(500), ("ballpoint: its end thins at the lift (%d px at the end, %d mid)"):format(thick(798), thick(500)))
    view:onCloseWidget()
end

-- the screen shows the end drawn again: a paint during the stroke leaves the
-- next one copying only what the last samples changed, and the lift's redraw
-- must join it (the screen kept the full width end before)
for _, pen in ipairs({ "ballpoint", "fountain", "felttip" }) do
    local view, tick = world()
    view:choosePenType(pen)
    view:setTool("pen")
    pressureOn(view)
    local v = view.view
    local sb = Device.screen.bb
    local function at(x, y) return { pos = { x = v.area_x + x, y = v.area_y + y } } end
    -- (the drawing area alone: the mock toolbar cannot paint on the real blitter)
    local function paint() view._area_only = true; view:paintTo(sb, 0, 0) end
    view._full_blit = true
    paint()
    view:onIaTouch(nil, at(200, 900))
    for i = 1, 60 do
        tick(5); view:onIaPan(nil, at(200 + i * 8, 900))
        if i % 4 == 0 then paint() end
    end
    paint()
    tick(5)
    view:onIaPanRelease(nil, at(690, 900))
    view:flushPending()
    paint()
    -- the area as the screen shows it, against area_bb
    local bad = 0
    for y = 860, 940 do
        for x = 150, 750 do
            if sb:getPixel(v.area_x + x, v.area_y + y):getColor8().a ~= view.area_bb:getPixel(x, y):getColor8().a then
                bad = bad + 1
            end
        end
    end
    ok(bad == 0, ("%s: after the lift the screen shows the page as drawn (%d pixels left over)"):format(pen, bad))
    view:onCloseWidget()
end

-- zoomed in and panned: the end drawn again is shown where it lies on the
-- screen (the area's scaling is not real here, so the rect asked for is checked)
do
    local view, tick = world()
    view:choosePenType("ballpoint")
    view:setTool("pen")
    pressureOn(view)
    view:setZoom(1.7)
    local v = view.view
    local pts = {}
    for i = 0, 40 do pts[#pts + 1] = 300 + i * 10; pts[#pts + 1] = 700 end
    local shown = {}
    local rvr = view.renderViewRect
    view.renderViewRect = function(self, x0, y0, x1, y1)
        shown[#shown + 1] = { x0, y0, x1, y1 }
        return rvr(self, x0, y0, x1, y1)
    end
    write(view, tick, { pts })
    view.renderViewRect = rvr
    ok(v.zoom > 1.6 and v.pan_x > 0 and v.pan_y > 0, "zoomed: the page is zoomed in and panned")
    -- the stroke ends at (700, 700) on the screen; its tapered end lies just before
    local hit = false
    for _, r in ipairs(shown) do
        if r[1] <= 690 and r[3] >= 700 and r[2] <= 700 and r[4] >= 700
                and (r[3] - r[1]) * (r[4] - r[2]) < 200 * 120 then hit = true end
    end
    ok(hit, ("zoomed: the lift shows the end where it is on the screen (%d rects asked for)"):format(#shown))
    view:onCloseWidget()
end

print(("realbb lift: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
