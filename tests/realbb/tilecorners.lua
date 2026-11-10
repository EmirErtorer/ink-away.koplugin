-- Rounded rings around pictures, on KOReader's REAL widgets and blitter: a colour
-- swatch's tile and a pen tile's sample must not cover the inside of the black
-- ring with square white corners (selected and not).
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/tilecorners.lua <repo>
local REPO = arg[1] or "."
require("setupkoenv")
local ffi = require("ffi")
ffi.cdef[[int setenv(const char *name, const char *value, int overwrite);]]
local lfs = require("libs/libkoreader-lfs")
local tmp = os.tmpname()
os.remove(tmp)
assert(lfs.mkdir(tmp))
ffi.C.setenv("KO_HOME", tmp, 1)
ffi.C.setenv("SDL_VIDEODRIVER", "dummy", 1)
ffi.C.setenv("EMULATE_READER_W", "1072", 1)
ffi.C.setenv("EMULATE_READER_H", "1448", 1)
_G.G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(tmp .. "/settings.reader.lua")
G_reader_settings:saveSetting("screen_dpi", 300)
local Device = require("device")
require("document/canvascontext"):init(Device)
local BB = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Screen = Device.screen
package.path = REPO .. "/?.lua;" .. package.path
local InkAwayView = require("ink/view")
local Accent = require("ink/accent")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function px(bb, x, y) local c = bb:getPixel(x, y):getColorRGB32(); return c.r, c.g, c.b, c.alpha end

local v = setmetatable({ screen_w = 1072, screen_h = 1448 }, { __index = InkAwayView })
function v:colorScreen() return true end
Accent.set(nil)

-- Pixels of the four corners of the ring (outer radius R, `bw` wide) at (x0, y0),
-- w x h, that are near white: they should all be the ring's black. The edges of
-- the curve (a pixel each side, anti-aliased) are left out.
local function whiteInRing(bb, x0, y0, w, h, R, bw)
    local n, seen = 0, 0
    for _i, cnr in ipairs({ { 0, 0, 1, 1 }, { w - 1, 0, -1, 1 }, { 0, h - 1, 1, -1 }, { w - 1, h - 1, -1, -1 } }) do
        for dy = 0, R - 1 do
            for dx = 0, R - 1 do
                local d = math.sqrt((R - dx - 0.5) ^ 2 + (R - dy - 0.5) ^ 2)
                if d < R - 1.5 and d > R - bw + 0.5 then
                    seen = seen + 1
                    local r, g, b = px(bb, x0 + cnr[1] + cnr[3] * dx, y0 + cnr[2] + cnr[4] * dy)
                    if r > 160 and g > 160 and b > 160 then n = n + 1 end
                end
            end
        end
    end
    return n, seen
end

-- The darkest pixel on each corner's diagonal, from the frame's corner inwards
-- R px: the ring crosses it, so it is dark unless a square corner covers it.
local function ringOnDiagonals(bb, x0, y0, w, h, R)
    local worst = 0
    for _i, cnr in ipairs({ { 0, 0, 1, 1 }, { w - 1, 0, -1, 1 }, { 0, h - 1, 1, -1 }, { w - 1, h - 1, -1, -1 } }) do
        local darkest = 255
        for t = 0, R do
            local r, g, b = px(bb, x0 + cnr[1] + cnr[3] * t, y0 + cnr[2] + cnr[4] * t)
            darkest = math.min(darkest, math.floor((r + g + b) / 3))
        end
        worst = math.max(worst, darkest)
    end
    return worst
end

local function onWhite(widget)
    local sz = widget:getSize()
    local bb = BB.new(sz.w + 40, sz.h + 40, BB.TYPE_BBRGB32)
    bb:fill(BB.COLOR_WHITE)
    widget:paintTo(bb, 20, 20)
    return bb, sz
end

-- a colour swatch, selected (thick ring) and not (thin ring)
for _i, sel in ipairs({ true, false }) do
    local name = sel and "selected" or "unselected"
    local tile = v:swatchTile({ 0xE8, 0xC0, 0x00 }, sel, Screen:scaleBySize(56), function() end, nil, Screen:scaleBySize(36))
    local bb, sz = onWhite(tile)
    local white, seen = whiteInRing(bb, 20, 20, sz.w, sz.h, Screen:scaleBySize(14), tile.bordersize)
    if sel then
        ok(seen > 0 and white == 0, "swatch (" .. name .. "): its ring's corners are black, not covered by the tile ("
            .. white .. " of " .. seen .. " white)")
    end
    local dark = ringOnDiagonals(bb, 20, 20, sz.w, sz.h, Screen:scaleBySize(14))
    ok(dark < 100, "swatch (" .. name .. "): the ring runs unbroken round each corner (darkest " .. dark .. ")")
    local r, g, b = px(bb, 20 + math.floor(sz.w / 2), 20 + math.floor(sz.h / 2))
    ok(r == 0xE8 and g == 0xC0 and b == 0x00, "swatch (" .. name .. "): the colour fills it")
    bb:free()
end

-- the tile image itself: clear corners, the colour inside
local img = v:cachedColourTile({ 0xE8, 0xC0, 0x00 }, 80, 50, 11)
local _r, _g, _b, al = px(img, 0, 0)
ok(al == 0, "colour tile image: its corner is clear")
_r, _g, _b, al = px(img, 40, 25)
ok(al == 0xFF, "colour tile image: and its middle opaque")

-- a pen tile: its sample (a white picture) in the pen sheet's ring (padding 0 when selected)
for _i, sel in ipairs({ true, false }) do
    local name = sel and "selected" or "unselected"
    local w, h = Screen:scaleBySize(80), Screen:scaleBySize(40)
    local sample = BB.new(w, h, BB.TYPE_BBRGB32)
    sample:fill(BB.COLOR_WHITE)   -- (a grey fill: white)
    sample:paintRect(10, math.floor(h / 2) - 2, w - 20, 4, BB.COLOR_BLACK)
    local frame = FrameContainer:new{ bordersize = Screen:scaleBySize(sel and 3 or 1), color = BB.COLOR_BLACK,
        radius = Screen:scaleBySize(12), padding = sel and 0 or Screen:scaleBySize(2), margin = 0,
        background = BB.COLOR_WHITE, v:imageTile(sample, w, h, function() end) }
    local bb, sz = onWhite(frame)
    local white, seen = whiteInRing(bb, 20, 20, sz.w, sz.h, Screen:scaleBySize(12), frame.bordersize)
    if sel then
        ok(seen > 0 and white == 0, "pen tile (" .. name .. "): its ring's corners are black, not covered by the sample ("
            .. white .. " of " .. seen .. " white)")
    end
    local dark = ringOnDiagonals(bb, 20, 20, sz.w, sz.h, Screen:scaleBySize(12))
    ok(dark < 100, "pen tile (" .. name .. "): the ring runs unbroken round each corner (darkest " .. dark .. ")")
    local r, g, b = px(bb, 20 + math.floor(sz.w / 2), 20 + math.floor(sz.h / 2))
    ok(r == 0 and g == 0 and b == 0, "pen tile (" .. name .. "): the sample shows in it")
    -- the corners look just as the same frame round a plain white tile (no specks
    -- where the picture's rounded edge meets the ring)
    local plain = FrameContainer:new{ bordersize = frame.bordersize, color = BB.COLOR_BLACK,
        radius = Screen:scaleBySize(12), padding = frame.padding, margin = 0, background = BB.COLOR_WHITE,
        require("ui/widget/button"):new{ text = "", width = w, height = h, bordersize = 0,
            radius = Screen:scaleBySize(10), background = BB.COLOR_WHITE, margin = 0, padding = 0,
            callback = function() end } }
    local ref = onWhite(plain)
    local R, worst = Screen:scaleBySize(12), 0
    for _j, cnr in ipairs({ { 0, 0, 1, 1 }, { sz.w - 1, 0, -1, 1 }, { 0, sz.h - 1, 1, -1 }, { sz.w - 1, sz.h - 1, -1, -1 } }) do
        for dy = 0, R do
            for dx = 0, R do
                local x, y = 20 + cnr[1] + cnr[3] * dx, 20 + cnr[2] + cnr[4] * dy
                local r1, g1, b1 = px(bb, x, y)
                local r2, g2, b2 = px(ref, x, y)
                worst = math.max(worst, math.abs(r1 - r2), math.abs(g1 - g2), math.abs(b1 - b2))
            end
        end
    end
    ok(worst <= 48, "pen tile (" .. name .. "): its corners match a plain tile's (largest difference " .. worst .. ")")
    ref:free()
    bb:free()
end

-- a rounded copy keeps the picture and clears only the corners
local pic = BB.new(60, 30, BB.TYPE_BBRGB32)
pic:paintRectRGB32(0, 0, 60, 30, BB.ColorRGB32(0x20, 0x40, 0x60, 0xFF))
local round = v:roundedImage(pic, 10)
_r, _g, _b, al = px(round, 0, 0)
ok(al == 0, "rounded copy: a corner is clear")
local r, g, b
r, g, b, al = px(round, 30, 0)
ok(r == 0x20 and g == 0x40 and b == 0x60 and al == 0xFF, "rounded copy: the top edge between the corners is kept")
r, g, b, al = px(round, 59, 29)
ok(al == 0, "rounded copy: the opposite corner too")
ok(v:roundedImage(pic, 10) == round, "rounded copy: made once per picture")

print(("realbb tilecorners: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
