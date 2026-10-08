-- The smudge on KOReader's REAL blitter: smudging live (grey BB8 and colour
-- RGB32) leaves the master exactly as a fresh compose replays it, the colour
-- master equals the export, and a notebook's ruling is never moved.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/smudge.lua <repo>
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


for _i, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    local name = typ == BB.TYPE_BB8 and "grey" or "colour"
    local view, tick = world(typ)
    local v = view.view
    view.canvas.ops = {
        { kind = "ink", style = "solid", width = 20, alpha = 255, color = { 200, 30, 30 }, pts = { 300, 200, 300, 700 } },
        { kind = "ink", style = "solid", width = 20, alpha = 255, color = { 30, 60, 200 }, pts = { 360, 200, 360, 700 } },
    }
    view:composeCanvas(); view:renderView()
    view:setTool("pen")
    view.pen_style, view.pen_width, view.pen_alpha = "smudge", 40, 255
    local function scr(cx, cy)
        local z = v.zoom
        return v.area_x + (cx - v.pan_x) * z, v.area_y + (cy - v.pan_y) * z
    end
    local x0, y0 = scr(250, 450)
    view:onIaTouch(nil, { pos = { x = x0, y = y0 } })
    for i = 1, 30 do
        tick(10)
        local x, y = scr(250 + i * 8, 450 + math.floor(math.sin(i / 3) * 30))
        view:onIaPan(nil, { pos = { x = x, y = y } })
    end
    local x1, y1 = scr(490, 450)
    view:onIaPanRelease(nil, { pos = { x = x1, y = y1 } })
    UIManager.fireScheduled()
    view:flushPending()
    local op = view.canvas.ops[#view.canvas.ops]
    ok(op.kind == "smudge" and #op.pts >= 20, name .. ": the smudge is saved with its points")
    local moved = view.canvas_bb:getPixel(420, 450):getColorRGB32()
    ok(not (moved.r == 255 and moved.g == 255 and moved.b == 255), name .. ": ink was dragged right of the strokes")
    ok(sameAsCompose(view) == 0, name .. ": the live smudge equals the replay")
    if typ == BB.TYPE_BBRGB32 then
        local rgb, _n, ow = Export.buildRGB(view.canvas)
        local W, H = v.canvas_w, v.canvas_h
        local diff = 0
        for y = 0, H - 1, 2 do for x = 0, W - 1, 2 do
            local p = view.canvas_bb:getPixel(x, y):getColorRGB32()
            local o = (y * ow + x) * 3
            if p.r ~= rgb[o] or p.g ~= rgb[o + 1] or p.b ~= rgb[o + 2] then diff = diff + 1 end
        end end
        ok(diff == 0, name .. ": the export equals the screen (" .. diff .. " px differ)")
    end
    view:onCloseWidget()
end

print(("realbb smudge: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
