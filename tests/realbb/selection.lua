-- The selection on KOReader's REAL blitter: moving, resizing and turning it, and
-- each action of its menu, redraw only the boxes they touch, and that must leave
-- the page exactly as a full redraw would, in grey and colour, on a plain page
-- and on ruled notebook paper, with erasers crossing what is moved. While a
-- drag lifts the selection, the page under it must be the page without it.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/selection.lua <repo>
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
    for i = 0, 7 do   -- crossing strokes, some textured, grey or coloured
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
    ops[#ops + 1] = { kind = "fill", alpha = 255, color = { 0x88, 0x88, 0x88 },
        runs = { 700, 800, 60, 700, 801, 60, 702, 802, 56, 704, 803, 52 } }
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
        -- after each change, the page and the screen must match a full redraw
        local function same(what)
            local master, screen = bytes(view.canvas_bb), bytes(view.area_bb)
            view:composeCanvas(); view:renderView()
            ok(bytes(view.canvas_bb) == master, tag .. ": " .. what .. ": the page matches a full redraw")
            ok(bytes(view.area_bb) == screen, tag .. ": " .. what .. ": the screen matches a full redraw")
        end
        view:setTool("lasso")
        -- three strokes, the rectangle and the fill: erasers cross them
        view:selectOps({ 2, 4, 6, 9, 13 }, "lasso")
        local function frame() return view:selFrame() end

        -- a move: lifted mid-drag, then dropped
        local f = frame()
        local mx, my = (f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2
        view:onIaTouch(nil, { pos = { x = mx, y = my } })
        view:onIaPan(nil, { pos = { x = mx + 70, y = my + 40 } })
        ok(view._lifted ~= nil and view.sel_drag.card ~= nil, tag .. ": a move lifts the selection")
        same("lifted")
        view:onIaPanRelease(nil, { pos = { x = mx + 70, y = my + 40 } })
        ok(view._lifted == nil, tag .. ": and drops it")
        same("moved")
        -- a resize from a corner
        f = frame()
        view:onIaTouch(nil, { pos = { x = f.x1, y = f.y1 } })
        view:onIaPan(nil, { pos = { x = f.x1 + 90, y = f.y1 + 60 } })
        same("resizing")
        view:onIaPanRelease(nil, { pos = { x = f.x1 + 90, y = f.y1 + 60 } })
        same("resized")
        -- a turn with the round handle
        local kx, ky = view:selKnob()
        f = frame()
        view:onIaTouch(nil, { pos = { x = kx, y = ky } })
        view:onIaPan(nil, { pos = { x = kx + 120, y = ky + 30 } })
        view:onIaPanRelease(nil, { pos = { x = kx + 120, y = ky + 30 } })
        same("turned")
        -- the menu's actions
        view:selTurn90(); same("quarter turn")
        view:selFlip("h"); same("mirrored")
        view:selFlip("v"); same("mirrored up and down")
        view:selSetColour({ 30, 120, 200 }); same("recoloured")
        view:selSetSize(14); same("thicker")
        view:selSetOpacity(50); same("lighter")
        view:selToFront(); same("brought to the front")
        view:selDuplicate(); same("duplicated")
        local before = bytes(view.canvas_bb)
        view:selDelete(); same("deleted")
        ok(bytes(view.canvas_bb) ~= before, tag .. ": deleting changed the page")
        view:undo()   -- (a full redraw)
        ok(bytes(view.canvas_bb) == before, tag .. ": undo returns the page to how it was")
        view:onCloseWidget()
    end
end
print(("realbb selection: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
