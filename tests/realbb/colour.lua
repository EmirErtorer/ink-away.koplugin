-- Colour-panel live drawing on KOReader's REAL blitter (RGB32, like the Kobo Libra
-- Colour) vs grey (BB8). On colour: every pen draws live with the fast waveform at
-- a bounded pace, a coloured pen shows a black preview while drawing, the master
-- keeps the real colour, a lift sends no blocking refresh, and one grey/colour
-- refresh settles the stroke once the pen rests: one that drives every pixel for
-- ink drawn in its own colours (a "ui" one skips pixels the fast waveform already
-- set), on a Kaleido panel with the dithering hint for its colour waveform. Grey
-- e-ink keeps the old path.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/colour.lua <repo>
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
local function rgb(bb, x, y) local c = bb:getPixel(x, y):getColorRGB32(); return c.r, c.g, c.b end

local function world(typ)
    local W, H = 1264, 1680
    Device.screen.bb = BB.new(W, H, typ)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
    Device.input.wacom_protocol = false
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    local clock = 0
    view.nowMs = function() return clock end
    local modes = {}
    local orig = UIManager.setDirty
    UIManager.setDirty = function(self, w, mode, region, dither)
        modes[#modes + 1] = tostring(mode)
        modes.dither = dither
        return orig(self, w, mode, region)
    end
    return view, modes, function(ms) clock = clock + ms end, function() UIManager.setDirty = orig end
end
local function count(list, m) local n = 0 for _, x in ipairs(list) do if x == m then n = n + 1 end end return n end

-- colour panel, red pen
do
    local view, modes, tick, done = world(BB.TYPE_BBRGB32)
    local v = view.view
    view:setTool("pen")
    view.pen_color = { 220, 20, 20 }
    local y = v.area_y + 400
    for k = 1, #modes do modes[k] = nil end
    view:onIaTouch(nil, { pos = { x = 200, y = y } })
    for x = 204, 600, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end   -- 5 ms apart
    local ax, ay = 400 - v.area_x, y - v.area_y
    local r, g, b = rgb(view.area_bb, ax, ay)
    ok(r > 150 and g < 100, "colour: a red pen shows red while drawing")
    local cx, cy = view:toCanvasClamped(400, y)
    local mr, mg = rgb(view.canvas_bb, math.floor(cx), math.floor(cy))
    ok(mr > 150 and mg < 100, "colour: the master keeps the real red")
    ok(count(modes, "ui") == 0 and count(modes, "flashui") == 0, "colour: no blocking refresh while drawing")
    local live = count(modes, "fast")
    ok(live > 0 and live <= 27, ("colour: live refreshes are paced to ~50/s (%d for 100 samples over 0.5 s)"):format(live))
    for k = 1, #modes do modes[k] = nil end
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()
    ok(count(modes, "ui") == 0 and count(modes, "flashui") == 0, "colour: the lift sends no blocking refresh")
    r, g, b = rgb(view.area_bb, ax, ay)
    ok(r > 150 and g < 100, "colour: the real colour is back in the screen buffer after the lift")
    -- a second stroke soon after pushes the settle back
    view:onIaTouch(nil, { pos = { x = 200, y = y + 100 } })
    for x = 204, 300, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y + 100 } }) end
    view:onIaPanRelease(nil, { pos = { x = 300, y = y + 100 } }); view:flushPending()
    ok(view._reconcile ~= nil and count(modes, "ui") == 0 and count(modes, "partial") == 0,
        "colour: the settle waits while writing continues")
    UIManager.fireScheduled()
    ok(count(modes, "partial") == 1 and count(modes, "ui") == 0,
        "colour: ONE refresh that drives every pixel settles both strokes when the pen rests")
    ok(not modes.dither, "colour: no dithering hint where the panel has no colour waveforms")
    -- the eraser over a notebook page: grey-capable but paced, and no flash on lift
    view:startNotebook({ style = "lines", size = 40, strength = 45 })
    view:setTool("erase")
    for k = 1, #modes do modes[k] = nil end
    view:onIaTouch(nil, { pos = { x = 200, y = y } })
    for x = 204, 600, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()
    local ui = count(modes, "ui")
    ok(ui > 0 and ui <= 10, ("colour: the notebook eraser's grey refreshes are paced (%d for 100 samples)"):format(ui))
    ok(count(modes, "flashui") == 0, "colour: no flashing refresh on an erase lift")
    view:onCloseWidget(); done()
end

-- colour panel, "Colour while drawing" off: a black preview, the colour on lift
do
    local view, modes, tick, done = world(BB.TYPE_BBRGB32)
    local v = view.view
    view.live_colour = false
    view:setTool("pen")
    view.pen_color = { 220, 20, 20 }
    local y = v.area_y + 400
    view:onIaTouch(nil, { pos = { x = 200, y = y } })
    for x = 204, 600, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    local ax, ay = 400 - v.area_x, y - v.area_y
    local r, g, b = rgb(view.area_bb, ax, ay)
    ok(r == 0 and g == 0 and b == 0, "colour, black first: a red pen shows black while drawing")
    ok(count(modes, "ui") == 0, "colour, black first: no blocking refresh while drawing")
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()
    r, g, b = rgb(view.area_bb, ax, ay)
    ok(r > 150 and g < 100 and view._reconcile ~= nil, "colour, black first: red on lift, settled when the pen rests")
    for k = 1, #modes do modes[k] = nil end
    UIManager.fireScheduled()
    ok(count(modes, "ui") == 1 and count(modes, "partial") == 0,
        "colour, black first: the lift changed the pixels, so a plain grey/colour refresh settles them")
    view:onCloseWidget(); done()
end

-- a Kaleido panel (colour Kobos): the settle asks for its colour waveform; black
-- ink, which the fast waveform shows exactly, keeps the plain settle
do
    local had = Device.hasKaleidoWfm
    Device.hasKaleidoWfm = function() return true end
    local view, modes, tick, done = world(BB.TYPE_BBRGB32)
    local v = view.view
    view:setTool("pen")
    local y = v.area_y + 400
    local function stroke(colour)
        view.pen_color = colour
        for k = 1, #modes do modes[k] = nil end
        modes.dither = nil
        view:onIaTouch(nil, { pos = { x = 200, y = y } })
        for x = 204, 600, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
        view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()
        UIManager.fireScheduled()
        y = y + 60
    end
    stroke({ 255, 105, 180 })
    ok(count(modes, "partial") == 1 and modes.dither == true,
        "kaleido: pink drawn in colour settles with the colour waveform")
    stroke({ 0, 0, 0 })
    ok(count(modes, "partial") == 0 and count(modes, "ui") == 1 and not modes.dither,
        "kaleido: black ink keeps the plain settle")
    view:onCloseWidget(); done()
    Device.hasKaleidoWfm = had
end

-- a shape dragged out on a colour panel: each later outline waits for the panel
-- to finish the last (each covers the shape's whole box), so the moves made
-- meanwhile go out as one refresh of the newest outline; grey e-ink, the
-- emulator and Android send theirs as before
do
    local function drag(typ, setup)
        local view, modes, tick, done = world(typ)
        if setup then setup(view) end
        local v = view.view
        view:setTool("shape")
        view.shape, view.shape_fill = "rect", false
        view.pen_color = { 220, 20, 20 }
        local x0, y0 = v.area_x + 100, v.area_y + 200
        UIManager.vsyncs = 0
        for k = 1, #modes do modes[k] = nil end
        view:onIaTouch(nil, { pos = { x = x0, y = y0 } })
        local n = 0
        for i = 1, 60 do
            tick(5); n = n + 1
            view:onIaPan(nil, { pos = { x = x0 + 12 * i, y = y0 + 16 * i } })
        end
        local x1, y1 = x0 + 720, y0 + 960
        -- the newest outline is what the next paint draws
        view:paintShapePreview(Device.screen.bb, 0, 0)
        local r, g = rgb(Device.screen.bb, x1, math.floor((y0 + y1) / 2))
        local shown = (r < 200 or g < 200)
        local vs = UIManager.vsyncs
        view:onIaPanRelease(nil, { pos = { x = x1, y = y1 } }); view:flushPending()
        local placed = view.canvas.ops[#view.canvas.ops]
        view:onCloseWidget(); done()
        return vs, n, count(modes, "fast"), shown, placed and placed.kind == "shape"
    end
    local vs, n, fast, shown, placed = drag(BB.TYPE_BBRGB32)
    ok(vs == n, ("shape, colour: each outline after the first waits for the panel (%d of %d moves)"):format(vs, n))
    ok(fast >= n and shown and placed, "shape, colour: every move is still drawn, the newest outline shows, the shape is placed")
    vs, n, fast, shown, placed = drag(BB.TYPE_BB8)
    ok(vs == 0 and fast >= n and shown and placed, "shape, grey e-ink: unchanged, no waiting")
    local had = Device.isEmulator
    Device.isEmulator = function() return true end
    vs = drag(BB.TYPE_BBRGB32)
    ok(vs == 0, "shape, emulator: no waiting where every refresh is instant")
    Device.isEmulator = had
    local hadA = Device.isAndroid
    Device.isAndroid = function() return true end
    vs = drag(BB.TYPE_BBRGB32)
    ok(vs == 0, "shape, Android: no waiting, its own pacing stays")
    Device.isAndroid = hadA
end

-- a grey pen on a colour panel, "Colour while drawing" on (the default): a grey
-- has no colour to show, and the fast waveform shows a light grey as white, so
-- its live copy is drawn in the page's ink (black, white on a dark paper) like
-- the copy of any pen with that setting off; the grey is back on the lift and
-- settles. A real colour still draws in its colour.
do
    local function stroke(color, alpha, setup)
        local view, modes, tick, done = world(BB.TYPE_BBRGB32)
        if setup then setup(view) end
        local v = view.view
        view:setTool("pen")
        view.pen_color, view.pen_alpha = color, alpha or 255
        local y = v.area_y + 400
        view:onIaTouch(nil, { pos = { x = 200, y = y } })
        for x = 204, 600, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
        local ax, ay = 400 - v.area_x, y - v.area_y
        local live = { rgb(view.area_bb, ax, ay) }
        local cx, cy = view:toCanvasClamped(400, y)
        local master = { rgb(view.canvas_bb, math.floor(cx), math.floor(cy)) }
        view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()
        local after = { rgb(view.area_bb, ax, ay) }
        local settle = view._reconcile ~= nil
        view:onCloseWidget(); done()
        return live, master, after, settle
    end
    local function same(c, r, g, b) return c[1] == r and c[2] == g and c[3] == b end
    local live, master, after, settle = stroke({ 136, 136, 136 })
    ok(same(live, 0, 0, 0), ("grey pen, colour: drawn in the page's ink while writing (%d,%d,%d)"):format(live[1], live[2], live[3]))
    ok(same(master, 136, 136, 136) and same(after, 136, 136, 136) and settle,
        "grey pen, colour: the master keeps the grey, it is back on the lift, and it settles")
    live = stroke(nil, 110)
    ok(same(live, 0, 0, 0), "grey pen, colour: black at a lowered opacity (a grey) too")
    live, master = stroke({ 136, 136, 136 }, 255, function(view) view.paper = { 30, 30, 30 } end)
    ok(same(live, 255, 255, 255), ("grey pen, colour: on a dark paper the page's ink is white (%d,%d,%d)"):format(live[1], live[2], live[3]))
    live = stroke({ 220, 20, 20 })
    ok(live[1] > 150 and live[2] < 100, "grey pen, colour: a red pen still draws red")
    live = stroke({ 220, 20, 20 }, 255, function(view) view.live_colour = false; view.paper = { 30, 30, 30 } end)
    ok(same(live, 255, 255, 255), "grey pen, colour: with Colour while drawing off, the copy on a dark paper is white too")
    local had = Device.isEmulator
    Device.isEmulator = function() return true end
    live = stroke({ 136, 136, 136 })
    ok(same(live, 136, 136, 136), "grey pen, emulator: drawn grey, where every refresh shows it as drawn")
    Device.isEmulator = had
end

-- a shape's outline while it is dragged out, refreshed with the fast waveform
-- (black and white only): a pen that is not solid black (a colour, or any
-- opacity below full) shows its outline in the page's ink, which that waveform
-- shows whole, instead of a shade it breaks up or leaves out; the placed shape
-- keeps its own colour and opacity. Solid black is unchanged, and where every
-- refresh shows colour as drawn (the emulator) the outline keeps its shade.
do
    local function shape(typ, color, alpha, setup)
        local view, modes, tick, done = world(typ)
        if setup then setup(view) end
        local v = view.view
        view:setTool("shape")
        view.shape, view.shape_fill = "rect", false
        view.pen_color, view.pen_alpha, view.pen_width = color, alpha, 6
        local x0, y0 = v.area_x + 100, v.area_y + 200
        local x1, y1 = x0 + 500, y0 + 600
        for k = 1, #modes do modes[k] = nil end
        view:onIaTouch(nil, { pos = { x = x0, y = y0 } })
        for i = 1, 20 do tick(20); view:onIaPan(nil, { pos = { x = x0 + 25 * i, y = y0 + 30 * i } }) end
        view:paintShapePreview(Device.screen.bb, 0, 0)
        local ym = math.floor((y0 + y1) / 2)
        local pr, pg, pb = rgb(Device.screen.bb, x1, ym)
        local fast = count(modes, "fast")
        view:onIaPanRelease(nil, { pos = { x = x1, y = y1 } }); view:flushPending()
        local placed = view.canvas.ops[#view.canvas.ops]
        local cr, cg, cb = rgb(view.area_bb, x1 - v.area_x, ym - v.area_y)
        view:onCloseWidget(); done()
        return { pr, pg, pb }, fast, placed, { cr, cg, cb }
    end
    local function black(c) return c[1] == 0 and c[2] == 0 and c[3] == 0 end
    local function white(c) return c[1] == 255 and c[2] == 255 and c[3] == 255 end
    for _, typ in ipairs({ BB.TYPE_BB8, BB.TYPE_BBRGB32 }) do
        local tag = typ == BB.TYPE_BB8 and "grey" or "colour"
        local p, fast, placed = shape(typ, nil, 255)
        ok(black(p) and fast > 0 and placed.kind == "shape", "shape preview, " .. tag .. ": solid black shows black, with the fast waveform")
        local c
        p, fast, placed, c = shape(typ, nil, 90)
        ok(black(p), ("shape preview, %s: a see-through pen's outline shows in the page's ink (%d,%d,%d)"):format(tag, p[1], p[2], p[3]))
        ok(fast > 0 and placed.alpha == 90 and not black(c) and not white(c),
            ("shape preview, %s: and the placed shape keeps its opacity (%d,%d,%d)"):format(tag, c[1], c[2], c[3]))
        p, fast, placed = shape(typ, { 240, 220, 40 }, 255)
        ok(black(p) and placed.color and placed.color[1] == 240, "shape preview, " .. tag .. ": a pale colour's outline shows in the page's ink, the shape keeps its colour")
        p = shape(typ, { 220, 20, 20 }, 120, function(view) view.paper = { 30, 30, 30 } end)
        ok(white(p), ("shape preview, %s: on a dark paper the page's ink is white (%d,%d,%d)"):format(tag, p[1], p[2], p[3]))
    end
    local had = Device.isEmulator
    Device.isEmulator = function() return true end
    local p = shape(BB.TYPE_BBRGB32, nil, 90)
    ok(not black(p) and not (p[1] == 255 and p[2] == 255), ("shape preview, emulator: the outline keeps its shade (%d,%d,%d)"):format(p[1], p[2], p[3]))
    Device.isEmulator = had
end

-- the emulator (or a screen that is not e-ink): the colour as drawn, no settle
do
    local had = Device.isEmulator
    Device.isEmulator = function() return true end
    local view, modes, tick, done = world(BB.TYPE_BBRGB32)
    local v = view.view
    view:setTool("pen")
    view.pen_color = { 220, 20, 20 }
    local y = v.area_y + 400
    view:onIaTouch(nil, { pos = { x = 200, y = y } })
    for x = 204, 600, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    local r, g = rgb(view.area_bb, 400 - v.area_x, y - v.area_y)
    ok(r > 150 and g < 100, "instant colour: red while drawing")
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()
    ok(view._reconcile == nil, "instant colour: nothing to settle after the lift")
    UIManager.fireScheduled()
    ok(count(modes, "ui") == 0, "instant colour: no settle refresh")
    view:onCloseWidget(); done()
    Device.isEmulator = had
end

-- grey e-ink: fast per sample for black, and nothing more at the lift
do
    local view, modes, tick, done = world(BB.TYPE_BB8)
    local v = view.view
    view:setTool("pen")
    local y = v.area_y + 400
    view:onIaTouch(nil, { pos = { x = 200, y = y } })
    for x = 204, 600, 4 do tick(5); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    ok(count(modes, "fast") >= 99, "grey: every sample still refreshes at once (unchanged)")
    view:onIaPanRelease(nil, { pos = { x = 600, y = y } }); view:flushPending()
    ok(count(modes, "ui") == 0 and count(modes, "flashui") == 0, "grey: the lift adds no refresh (the live ones showed it)")
    view:onCloseWidget(); done()
end

-- KOReader's night mode on a colour screen (#11): it inverts the whole screen,
-- so the page is drawn with each colour's hue turned half way round and its
-- lightness kept, and the inverted screen shows the colour's own hue (lightness
-- inverted: dark ink light on the dark page). Black and greys stay as they are.
-- Thumbnails, kept as files, keep their own colours; the setting turns it off.
do
    local Paint = require("ink/paint")
    local function hue(r, g, b)
        local hi, lo = math.max(r, g, b), math.min(r, g, b)
        if hi == lo then return nil end
        local d = hi - lo
        local h
        if hi == r then h = ((g - b) / d) % 6 elseif hi == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
        return h * 60
    end
    local blue = { 25, 45, 130 }
    local n = Paint.nightInk(blue)
    local shown = { 255 - n[1], 255 - n[2], 255 - n[3] }   -- what the inverted screen shows
    ok(math.abs(hue(shown[1], shown[2], shown[3]) - hue(blue[1], blue[2], blue[3])) < 1,
        "night: the screen shows the ink's own hue (blue stays blue)")
    ok((math.max(shown[1], shown[2], shown[3]) + math.min(shown[1], shown[2], shown[3])) / 2 > 128,
        "night: and dark blue shows light on the dark page")
    ok(Paint.nightInk({ 0, 0, 0 })[1] == 0 and Paint.nightInk({ 128, 128, 128 })[2] == 128,
        "night: black and grey are left as they are")
    -- the page drawn in night mode
    local view, modes, tick, done = world(BB.TYPE_BBRGB32)
    Device.screen.night_mode = true
    G_reader_settings.data.inkaway_night_colours = nil
    view:choosePenType("solid"); view:setTool("pen")
    view.pen_color, view.pen_width, view.pen_alpha = blue, 12, 255
    local v = view.view
    local y = v.area_y + 500
    view:onIaTouch(nil, { pos = { x = 300, y = y } })
    for i = 1, 8 do tick(8); view:onIaPan(nil, { pos = { x = 300 + i * 30, y = y } }) end
    view:onIaPanRelease(nil, { pos = { x = 540, y = y } })
    view:flushPending(); tick(2000); UIManager.fireScheduled()
    local cx, cy = require("ink/geom").toCanvas(v, 420, y)
    local r, g, b = rgb(view.canvas_bb, math.floor(cx), math.floor(cy))
    ok(r == n[1] and g == n[2] and b == n[3], ("night: the stroke is drawn turned for night mode (%d,%d,%d)"):format(r, g, b))
    view:composeCanvas()
    r, g, b = rgb(view.canvas_bb, math.floor(cx), math.floor(cy))
    ok(r == n[1] and g == n[2] and b == n[3], "night: and so when the page is drawn again")
    -- a see-through pen too
    local Wash = require("ink/wash")
    local wop = { kind = "ink", style = "marker", color = { 210, 40, 40 }, alpha = 190, width = 20, pts = { 100, 100, 200, 100 } }
    ok(view:shownWash(wop).color[2] == Paint.nightInk({ 210, 40, 40 })[2] and view:shownWash(wop).width == 20,
        "night: a see-through pen's colour is turned, the rest of the stroke as it is")
    ok(Wash ~= nil and wop.color[1] == 210, "night: the saved stroke keeps its colour")
    -- a thumbnail (kept as a file) keeps the true colour
    local tc
    view:trueColours(function() tc = view:shownInk(blue, nil) end)
    ok(tc[1] == 25 and tc[3] == 130, "night: a thumbnail is drawn in the ink's own colours")
    -- the setting off: as before
    G_reader_settings.data.inkaway_night_colours = false
    view:composeCanvas()
    r, g, b = rgb(view.canvas_bb, math.floor(cx), math.floor(cy))
    ok(r == 25 and g == 45 and b == 130, "night: with Keep colours in night mode off, the ink's own colour as before")
    -- day: the ink's own colour
    G_reader_settings.data.inkaway_night_colours = nil
    Device.screen.night_mode = false
    view:composeCanvas()
    r, g, b = rgb(view.canvas_bb, math.floor(cx), math.floor(cy))
    ok(r == 25 and g == 45 and b == 130, "night: by day, the ink's own colour")
    -- turning night mode on redraws the page in its night colours
    Device.screen.night_mode = true
    view:onToggleNightMode()
    UIManager.fireScheduled()
    r, g, b = rgb(view.canvas_bb, math.floor(cx), math.floor(cy))
    ok(r == n[1] and g == n[2] and b == n[3], "night: turning night mode on draws the page again in its night colours")
    Device.screen.night_mode = nil
    view:onCloseWidget(); done()
end

print(("realbb colour: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
