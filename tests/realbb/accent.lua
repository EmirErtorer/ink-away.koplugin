-- The accent colour on KOReader's REAL blitter: which text colour reads on it,
-- the rounded shapes and slider bars drawn in it (clear corners, the colour
-- inside), icons drawn on it, and the library grid's pills in it.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/accent.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
local Device = require("device")

-- an icon renderer for Accent.icon: a black square in the middle of a clear
-- image, the way an SVG icon comes out (straight alpha)
package.loaded["ui/renderimage"] = {
    renderSVGImageFile = function(_, file, w, h)
        local bb = BB.new(w, h, BB.TYPE_BBRGB32)
        for y = math.floor(h / 4), math.floor(h * 3 / 4) - 1 do
            for x = math.floor(w / 4), math.floor(w * 3 / 4) - 1 do
                bb:setPixel(x, y, BB.ColorRGB32(0, 0, 0, 0xFF))
            end
        end
        return bb, true
    end,
}
local Accent = require("ink/accent")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function px(bb, x, y) local c = bb:getPixel(x, y):getColorRGB32(); return c.r, c.g, c.b, c.alpha end
local function near(a, b) return math.abs(a - b) <= 2 end

-- the text colour follows contrast
ok(Accent.darkText({ 0xFF, 0xE0, 0x40 }), "accent: black text on yellow")
ok(not Accent.darkText({ 0x1E, 0x3A, 0x8A }), "accent: white text on navy")
ok(Accent.darkText({ 0xFF, 0xFF, 0xFF }) and not Accent.darkText({ 0, 0, 0 }), "accent: black on white, white on black")

-- black by default, and for nothing usable
Accent.set(nil)
ok(not Accent.get().custom and Accent.get().fill == BB.COLOR_BLACK, "accent: black when none is set")
Accent.set({ 0, 0, 0 })
ok(not Accent.get().custom, "accent: choosing black is the default look")
Accent.set({ 300, 2, 2 })
ok(not Accent.get().custom, "accent: an impossible colour is ignored")
Accent.set({ 0x80, 0x80, 0x80 })
ok(Accent.get().custom and not Accent.get().chromatic, "accent: a grey is drawn the quick grey way")

-- a colour: shapes with clear corners
Accent.set({ 0x1E, 0x6F, 0xD9 })
local a = Accent.get()
ok(a.chromatic and a.text == BB.COLOR_WHITE, "accent: a blue takes white text")
local shape = Accent.shape(120, 40, 12)
local r, g, b, al = px(shape, 0, 0)
ok(al == 0, "accent: the shape's corner is clear")
r, g, b, al = px(shape, 60, 20)
ok(r == 0x1E and g == 0x6F and b == 0xD9 and al == 0xFF, "accent: the shape is the colour inside")
ok(Accent.shape(120, 40, 12) == shape, "accent: a shape is drawn once and reused")

-- painted on a white colour screen
local scr = BB.new(400, 200, BB.TYPE_BBRGB32)
scr:fill(BB.COLOR_WHITE)
Accent.paintRounded(scr, 10, 10, 120, 40, 12)
r, g, b = px(scr, 10, 10)
ok(r == 255 and g == 255 and b == 255, "accent: painted, the corner shows the white behind it")
r, g, b = px(scr, 70, 30)
ok(r == 0x1E and g == 0x6F and b == 0xD9, "accent: and the middle is the colour")
-- a slider bar: round on the left, square on the right, any width
Accent.paintBar(scr, 10, 100, 237, 16)
r, g, b = px(scr, 10, 100)
ok(r == 255 and g == 255 and b == 255, "accent: a bar's left corner is round")
r, g, b = px(scr, 246, 100)
ok(r == 0x1E and g == 0x6F and b == 0xD9, "accent: its right end is square, under the knob")
r, g, b = px(scr, 130, 108)
ok(r == 0x1E and g == 0x6F and b == 0xD9, "accent: and it is filled between")

-- an icon on the accent: lines in the text colour (white here) on the colour
local icon = Accent.icon("whatever.svg", 32)
ok(icon ~= nil, "accent: an icon is drawn on it")
if icon then
    r, g, b = px(icon, 1, 1)
    ok(r == 0x1E and g == 0x6F and b == 0xD9, "accent: around the icon's lines is the colour")
    r, g, b = px(icon, 16, 16)
    ok(r == 255 and g == 255 and b == 255, "accent: the lines are white on blue")
end
Accent.set({ 0xFF, 0xE0, 0x40 })
icon = Accent.icon("whatever.svg", 32)
if icon then
    r, g, b = px(icon, 16, 16)
    ok(r == 0 and g == 0 and b == 0, "accent: and black on yellow")
end

-- the library's grid draws its pills in it
Accent.set({ 0xC0, 0x30, 0x30 })
Device.screen.bb = BB.new(1072, 1448, BB.TYPE_BBRGB32)
Device.screen:setSize(1072, 1448)
local ThumbGrid = require("ink/ui/thumbgrid")
local grid = ThumbGrid:new{ title = "Library", items = { { label = "One", selected = true } },
    actions = { { "+ Drawing", function() end, true } } }
grid:paintTo(Device.screen.bb, 0, 0)
local c = grid._close
r, g, b = px(Device.screen.bb, c.x + math.floor(c.w / 2), c.y + 3)
ok(near(r, 0xC0) and near(g, 0x30) and near(b, 0x30), "grid: the Close pill is in the accent")
r, g, b = px(Device.screen.bb, c.x, c.y)
ok(r == 255 and g == 255 and b == 255, "grid: with round corners on the white bar")
local act = grid._actions[1]
r, g, b = px(Device.screen.bb, act.x + 4, act.y + math.floor(act.h / 2))
ok(near(r, 0xC0) and near(g, 0x30), "grid: a dark action pill is in it too")
local cell = grid:cellRect(0)
r, g, b = px(Device.screen.bb, cell.x + math.floor(cell.w / 2), cell.y + 1)
ok(near(r, 0xC0) and near(g, 0x30), "grid: and the selected card's border")
grid:onCloseWidget()

Accent.set(nil)
grid = ThumbGrid:new{ title = "Library", items = {} }
grid:paintTo(Device.screen.bb, 0, 0)
c = grid._close
r, g, b = px(Device.screen.bb, c.x + math.floor(c.w / 2), c.y + 3)
ok(r == 0 and g == 0 and b == 0, "grid: black again once the accent is black")
Accent.free()

print(("realbb accent: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
