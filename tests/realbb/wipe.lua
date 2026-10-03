-- The whole-stroke eraser on KOReader's REAL blitter: after it removes marks,
-- redrawing only where they were must leave the page exactly as a full redraw
-- would, in grey and colour, on a plain page and on ruled notebook paper.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/wipe.lua <repo>
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
local function bytes(bb) return ffi.string(bb.data, bb.stride * bb:getHeight()) end

local function page()
    local ops = {}
    for i = 0, 7 do   -- crossing strokes, some textured and grey
        ops[#ops + 1] = { kind = "ink", width = 6 + i, alpha = (i % 3 == 0) and 140 or 255,
            color = (i % 2 == 0) and { 200, 30, 30 } or nil, style = (i == 3) and "pencil" or nil, seed = 7,
            pts = { 80 + i * 20, 150, 300 + i * 25, 420, 520 + i * 10, 200 } }
    end
    ops[#ops + 1] = { kind = "shape", shape = "rect", fill = false, width = 5, alpha = 255,
        pts = { 150, 450, 450, 650 }, fill_color = { 180, 180, 180 } }
    ops[#ops + 1] = { kind = "shape", shape = "ellipse", fill = true, width = 4, alpha = 200, pts = { 400, 500, 650, 700 } }
    ops[#ops + 1] = { kind = "erase", width = 30, pts = { 100, 300, 600, 330 } }
    ops[#ops + 1] = { kind = "erase", width = 20, ebg = true, pts = { 200, 600, 500, 560 } }
    ops[#ops + 1] = { kind = "ink", width = 8, alpha = 255, pts = { 120, 700, 620, 520 } }
    return ops
end

for _, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    for _, nb in ipairs({ false, true }) do
        local tag = (typ == BB.TYPE_BBRGB32 and "colour" or "grey") .. (nb and " / notebook" or " / drawing")
        local W, H = 1072, 1448
        Device.screen.bb = BB.new(W, H, typ)
        Device.screen:setSize(W, H)
        Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
        UIManager.reset()
        local view = dofile(REPO .. "/ink/view.lua"):new{}
        UIManager:show(view)
        if nb then view:startNotebook({ style = "lines", size = 40, strength = 45 }) end
        view.canvas:setOps(page())
        view:composeCanvas(); view:renderView()
        local v = view.view
        local function at(cx, cy)
            return { pos = { x = v.area_x + (cx - v.pan_x) * v.zoom, y = v.area_y + (cy - v.pan_y) * v.zoom } }
        end
        view.erase_whole = true
        view:setTool("erase")
        view.eraser_width = 16
        local n0 = view.canvas:opCount()
        -- one eraser stroke across several strokes, then one on the filled ellipse alone
        view:onIaTouch(nil, at(300, 250))
        view:onIaPan(nil, at(420, 260))
        view:onIaPanRelease(nil, at(420, 260))
        UIManager.fireScheduled()
        view:onIaTouch(nil, at(560, 640))
        view:onIaPanRelease(nil, at(570, 645))
        UIManager.fireScheduled()
        ok(view.canvas:opCount() < n0 - 2, tag .. ": the eraser removed marks")
        local master, screen = bytes(view.canvas_bb), bytes(view.area_bb)
        view:composeCanvas(); view:renderView()
        ok(bytes(view.canvas_bb) == master, tag .. ": the page matches a full redraw")
        ok(bytes(view.area_bb) == screen, tag .. ": the screen matches a full redraw")
        view:onCloseWidget()
    end
end
print(("realbb wipe: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
