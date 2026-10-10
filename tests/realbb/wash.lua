-- See-through pens and the pens whose width changes, on KOReader's REAL blitter:
--  * on a colour page (RGB32) the screen's C blend and the export's Lua blend
--    give the same pixels (highlighter, marker, watercolour over ink and ruling);
--  * a wash stroke drawn live, going back over itself, comes out as even as the
--    saved stroke and leaves the master exactly as a fresh compose of the page;
--  * a pressured fountain stroke drawn live ends equal to a fresh compose;
--  * on a grey page (BB8) black ink stays black under the highlighter.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/wash.lua <repo>
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
local Export = require("ink/export")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local function world(typ)
    local W, H = 1072, 1448
    Device.screen.bb = BB.new(W, H, typ)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
    Device.input.wacom_protocol = false
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    local clock = 0
    view.nowMs = function() return clock end
    return view, function(ms) clock = clock + ms end
end

-- the master compared with a fresh compose of the same ops, pixel for pixel
local function sameAsCompose(view)
    local W, H = view.view.canvas_w, view.view.canvas_h
    local fresh = BB.new(W, H, view.canvas_bb:getType())
    local saved = view.canvas_bb
    view.canvas_bb = fresh
    view:composeCanvas()
    view.canvas_bb = saved
    local diff = 0
    for y = 0, H - 1, 2 do
        for x = 0, W - 1, 2 do
            if saved:getPixel(x, y):getColorRGB32().r ~= fresh:getPixel(x, y):getColorRGB32().r
                    or saved:getPixel(x, y):getColorRGB32().b ~= fresh:getPixel(x, y):getColorRGB32().b then
                diff = diff + 1
            end
        end
    end
    fresh:free()
    return diff
end

-- ---- colour: screen blend == export blend --------------------------------------
do
    local view = world(BB.TYPE_BBRGB32)
    local c = view.canvas
    c.ops = {
        { kind = "ink", style = "solid", width = 8, alpha = 255, color = { 20, 20, 20 }, pts = { 100, 300, 900, 320 } },
        { kind = "ink", style = "highlighter", width = 40, alpha = 255, color = { 255, 235, 59 }, pts = { 80, 310, 950, 310 } },
        { kind = "ink", style = "felttip", width = 30, alpha = 140, color = { 30, 90, 220 }, pts = { 200, 200, 300, 700 } },
        { kind = "ink", style = "felttip", width = 30, alpha = 140, color = { 220, 40, 60 }, pts = { 100, 600, 700, 450 } },
        { kind = "ink", style = "wash", width = 80, alpha = 170, seed = 9, color = { 40, 160, 90 },
          pts = { 150, 900, 400, 1000, 700, 880 }, pr = { 120, 255, 200 } },
        { kind = "ink", style = "wash", width = 80, alpha = 170, seed = 4, color = { 230, 140, 30 },
          pts = { 300, 800, 500, 1100 } },
    }
    view:composeCanvas()
    local rgb, _n, ow = Export.buildRGB(c)
    local W, H = view.view.canvas_w, view.view.canvas_h
    local diff, worst, seen = 0, 0, 0
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local p = view.canvas_bb:getPixel(x, y):getColorRGB32()
            local o = (y * ow + x) * 3
            local d = math.max(math.abs(p.r - rgb[o]), math.abs(p.g - rgb[o + 1]), math.abs(p.b - rgb[o + 2]))
            if d > 0 then diff = diff + 1; if d > worst then worst = d end end
            if p.r ~= 255 or p.g ~= 255 or p.b ~= 255 then seen = seen + 1 end
        end
    end
    ok(seen > 50000, "colour: the page has the washes on it (" .. seen .. " px)")
    ok(diff == 0, ("colour: the export equals the screen (%d px differ, worst %d)"):format(diff, worst))
    local ink = view.canvas_bb:getPixel(500, 310):getColorRGB32()
    ok(ink.r == 20 and ink.g <= 20 and ink.b <= 20, "colour: dark ink under the highlighter stays dark (multiplied)")
    view:onCloseWidget()
end

-- ---- a live wash stroke over itself is even, and ends as a fresh compose -------
for _i, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    local name = typ == BB.TYPE_BB8 and "grey" or "colour"
    local view, tick = world(typ)
    local v = view.view
    view:setTool("pen")
    view.pen_style, view.pen_width, view.pen_alpha, view.pen_color = "felttip", 30, 130, { 30, 90, 220 }
    local y = v.area_y + 500
    view:onIaTouch(nil, { pos = { x = 200, y = y } })
    for x = 210, 800, 10 do tick(8); view:onIaPan(nil, { pos = { x = x, y = y } }) end
    for x = 790, 300, -10 do tick(8); view:onIaPan(nil, { pos = { x = x, y = y + 2 } }) end   -- back over it
    local cx1, cy1 = view:toCanvasClamped(500, y)
    local cx2, cy2 = view:toCanvasClamped(250, y)
    local twice = view.canvas_bb:getPixel(math.floor(cx1), math.floor(cy1)):getColorRGB32()
    local once = view.canvas_bb:getPixel(math.floor(cx2), math.floor(cy2)):getColorRGB32()
    ok(twice.r == once.r and twice.b == once.b,
        name .. ": going back over a live marker stroke does not darken it")
    view:onIaPanRelease(nil, { pos = { x = 300, y = y + 2 } })
    UIManager.fireScheduled()
    view:flushPending()
    ok(view.canvas.ops[#view.canvas.ops].style == "felttip", name .. ": the stroke is saved")
    ok(sameAsCompose(view) == 0, name .. ": after the lift the master equals a fresh compose")
    -- a fountain pen with simulated pressure ends equal to a fresh compose too
    view.pen_style, view.pen_width, view.pen_alpha, view.pen_color = "fountain", 16, 255, { 0, 0, 0 }
    local y2 = v.area_y + 800
    view:onIaTouch(nil, { pos = { x = 200, y = y2 } })
    for i = 1, 40 do tick(4 + (i % 5) * 6); view:onIaPan(nil, { pos = { x = 200 + i * 14, y = y2 + math.floor(math.sin(i / 4) * 60) } }) end
    view:onIaPanRelease(nil, { pos = { x = 760, y = y2 } })
    UIManager.fireScheduled()
    view:flushPending()
    local last = view.canvas.ops[#view.canvas.ops]
    ok(last.style == "fountain" and last.pr ~= nil, name .. ": the fountain stroke keeps a pressure per point")
    ok(sameAsCompose(view) == 0, name .. ": the fountain stroke's master equals a fresh compose")
    view:onCloseWidget()
end

-- ---- grey: black stays black under the highlighter ------------------------------
do
    local view = world(BB.TYPE_BB8)
    view.canvas.ops = {
        { kind = "ink", style = "solid", width = 8, alpha = 255, pts = { 100, 300, 900, 300 } },
        { kind = "ink", style = "highlighter", width = 40, alpha = 255, color = { 255, 235, 59 }, pts = { 80, 300, 950, 300 } },
    }
    view:composeCanvas()
    local k = view.canvas_bb:getPixel(500, 300):getColor8().a
    local hl = view.canvas_bb:getPixel(500, 315):getColor8().a
    ok(k == 0, "grey: black ink stays black under the highlighter")
    ok(hl < 255 and hl > 150, "grey: the highlighter shows as a light grey (" .. hl .. ")")
    view:onCloseWidget()
end

print(("realbb wash: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
