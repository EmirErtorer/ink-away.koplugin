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

print(("realbb colour: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
