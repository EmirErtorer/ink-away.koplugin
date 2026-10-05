-- Eraser vs notebook ruling on KOReader's REAL blitter, colour (RGB32, like the
-- Kobo Libra Colour) and grey (BB8). The ruling is part of the paper: neither the
-- normal eraser nor "Erase pictures" may remove it -- live, after the stroke
-- commits, after a recompose, or in the page-overview thumbnail.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/eraser.lua <repo>
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
local function grey(bb, x, y) return bb:getPixel(x, y):getColorRGB32().r end

for _, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    for _, hard in ipairs({ false, true }) do
        local tag = (typ == BB.TYPE_BBRGB32 and "colour" or "grey") .. (hard and " / Erase pictures" or " / normal eraser")
        local W, H = 1264, 1680
        Device.screen.bb = BB.new(W, H, typ)
        Device.screen:setSize(W, H)
        Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
        Device.input.wacom_protocol = false
        G_reader_settings.data.inkaway_erase_bg = hard
        UIManager.reset()
        local view = dofile(REPO .. "/ink/view.lua"):new{}
        UIManager:show(view)
        view:startNotebook({ style = "lines", size = 40, strength = 45 })
        local v = view.view
        local ry
        for y = 100, 400 do if grey(view.canvas_bb, 300, y) < 250 then ry = y; break end end
        local rule = ry and grey(view.canvas_bb, 300, ry)
        ok(rule and rule < 250, tag .. ": the page has ruling")
        local function scr(cx, cy) return v.area_x + (cx - v.pan_x) * v.zoom, v.area_y + (cy - v.pan_y) * v.zoom end
        local x0, y = scr(200, ry)
        local x1 = scr(400, ry)
        local ax = math.floor(scr(300, ry) - v.area_x)
        local ay = math.floor(y - v.area_y)
        local function stroke(tool)
            view:setTool(tool)
            view:onIaTouch(nil, { pos = { x = x0, y = y } })
            for x = x0, x1, 4 do view:onIaPan(nil, { pos = { x = x, y = y } }) end
        end
        stroke("pen")
        view:onIaPanRelease(nil, { pos = { x = x1, y = y } }); view:flushPending()
        ok(grey(view.canvas_bb, 300, ry) == 0, tag .. ": ink covers the ruling")
        stroke("erase")
        ok(grey(view.canvas_bb, 300, ry) == rule and grey(view.area_bb, ax, ay) == rule,
            tag .. ": live erase reveals the ruling")
        view:onIaPanRelease(nil, { pos = { x = x1, y = y } }); view:flushPending()
        ok(grey(view.canvas_bb, 300, ry) == rule, tag .. ": committed erase keeps the ruling")
        view:composeCanvas(); view:renderView()
        ok(grey(view.canvas_bb, 300, ry) == rule and grey(view.area_bb, ax, ay) == rule,
            tag .. ": the ruling survives a recompose")
        view:nbSyncOut()
        local scratch = BB.new(v.canvas_w, v.canvas_h, typ)
        view:composeInto(scratch, view.notebook.pages[view.notebook.index].ops, nil, view.notebook.template)
        ok(grey(scratch, 300, ry) == rule, tag .. ": the page thumbnail keeps the ruling")
        scratch:free()
        view:onCloseWidget()
    end
end
print(("realbb eraser: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
