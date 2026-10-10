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
    ok(view:textZone(r.x + r.w / 2, r.y - g.band + 2) == "frame", "the band above the frame")
    ok(view:textZone(r.x + r.w / 2, r.y - g.band - 20) == "outside", "beyond it is outside")
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

print(("realbb text: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
