-- Dark controls (ink/ui/theme.lua) on KOReader's REAL blitter: a panel is drawn
-- as in light and inverted within its rounded shape, the parts that keep their
-- colours come out exactly as painted (only what a scrolled list shows of them),
-- a button flashes on a dark panel by inverting what is shown and back, and
-- KOReader's night mode is never inverted twice.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/theme.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
local Device = require("device")
local Theme = require("ink/ui/theme")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local W, H = 400, 300
-- a light picture: grey stripes, a black square and a colour patch
local function picture(colour)
    local bb = BB.new(W, H, colour and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE)
    for y = 0, H - 1, 6 do bb:paintRect(0, y, W, 2, BB.Color8(0xCC)) end
    bb:paintRect(50, 50, 40, 40, BB.COLOR_BLACK)
    if colour then bb:paintRectRGB32(200, 120, 60, 50, BB.ColorRGB32(20, 140, 220, 0xFF)) end
    return bb
end
local function px(bb, x, y) local c = bb:getPixel(x, y):getColorRGB32(); return c.r, c.g, c.b end
local function same(a, b, x, y)
    local r1, g1, b1 = px(a, x, y); local r2, g2, b2 = px(b, x, y)
    return r1 == r2 and g1 == g2 and b1 == b2
end
local function inverse(a, b, x, y)
    local r1, g1, b1 = px(a, x, y); local r2, g2, b2 = px(b, x, y)
    return math.abs(255 - r1 - r2) <= 1 and math.abs(255 - g1 - g2) <= 1 and math.abs(255 - b1 - b2) <= 1
end
local function every(x0, y0, x1, y1, f)
    for y = y0, y1 - 1 do for x = x0, x1 - 1 do if not f(x, y) then return false, x, y end end end
    return true
end
local function mode(m) G_reader_settings:saveSetting(Theme.SETTING, m) end

for _i, colour in ipairs({ false, true }) do
    local tag = colour and "colour" or "grey"
    -- the rounded inversion: inside the shape inverted, its corners and the
    -- rest as they were, and twice is nothing
    local base, bb = picture(colour), picture(colour)
    Theme.invertRounded(bb, 40, 30, 300, 200, 24)
    ok(every(40, 30 + 24, 340, 230 - 24, function(x, y) return inverse(base, bb, x, y) end),
        tag .. ": the panel's body is inverted")
    ok(every(40 + 24, 30, 340 - 24, 230, function(x, y) return inverse(base, bb, x, y) end),
        tag .. ": its top and bottom rows between the corners too")
    ok(same(base, bb, 40, 30) and same(base, bb, 339, 30) and same(base, bb, 40, 229) and same(base, bb, 339, 229)
        and same(base, bb, 42, 32), tag .. ": outside its round corners nothing changes")
    ok(every(0, 0, W, 30, function(x, y) return same(base, bb, x, y) end)
        and every(0, 230, W, H, function(x, y) return same(base, bb, x, y) end)
        and every(0, 0, 40, H, function(x, y) return same(base, bb, x, y) end), tag .. ": nor around the panel")
    Theme.invertRounded(bb, 40, 30, 300, 200, 24)
    ok(every(0, 0, W, H, function(x, y) return same(base, bb, x, y) end), tag .. ": inverted twice is the picture again")
    -- a corner is a quarter circle: symmetric on all four sides
    local cbb = picture(colour)
    Theme.invertRounded(cbb, 40, 30, 300, 200, 24)
    ok(every(0, 0, 24, 24, function(x, y)
        local a = same(base, cbb, 40 + x, 30 + y)
        return a == same(base, cbb, 339 - x, 30 + y) and a == same(base, cbb, 40 + x, 229 - y)
            and a == same(base, cbb, 339 - x, 229 - y)
    end), tag .. ": the four corners match")
    base:free(); bb:free(); cbb:free()

    -- a panel with a kept part (a theme colour, a swatch): inverted, the kept
    -- part exactly as painted
    Device.screen.night_mode = false
    mode("dark")
    base, bb = picture(colour), picture(colour)
    local swatch = Theme.keep({ dimen = { x = 190, y = 110, w = 80, h = 70 } }, 10)
    local root = { { { swatch } }, hidden = { _cache = { Theme.keep({ dimen = { x = 60, y = 60, w = 20, h = 20 } }) } } }
    ok(Theme.apply(bb, root, 40, 30, 300, 200, 0), tag .. ": dark applies")
    ok(every(200, 120, 260, 170, function(x, y) return same(base, bb, x, y) end), tag .. ": the kept part shows as painted")
    ok(every(60, 60, 80, 80, function(x, y) return inverse(base, bb, x, y) end),
        tag .. ": what is under a private field is not taken for a kept part")
    ok(every(40, 30, 180, 100, function(x, y) return inverse(base, bb, x, y) end), tag .. ": the rest is inverted")
    ok(same(base, bb, 191, 111) == false, tag .. ": the kept part's corner is inverted with the panel (it is round)")
    -- light: nothing at all
    mode("light")
    local lbb = picture(colour)
    ok(not Theme.apply(lbb, root, 40, 30, 300, 200, 0)
        and every(0, 0, W, H, function(x, y) return same(base, lbb, x, y) end), tag .. ": light leaves it alone")
    base:free(); bb:free(); lbb:free()

    -- a scrolled list: a kept part that runs past its window is given back
    -- only where it shows
    mode("dark")
    base, bb = picture(colour), picture(colour)
    local tile = Theme.keep({ dimen = { x = 100, y = 60, w = 100, h = 80 } })
    local scroll = { _is_scrollable = true, dimen = { x = 60, y = 100, w = 260, h = 100 }, _crop_dx = 0,
        _crop_w = 260, _crop_h = 100, { tile } }
    Theme.apply(bb, { scroll }, 40, 30, 300, 200, 0)
    ok(every(100, 100, 200, 140, function(x, y) return same(base, bb, x, y) end), tag .. ": the shown part of a scrolled tile as painted")
    ok(every(100, 60, 200, 100, function(x, y) return inverse(base, bb, x, y) end),
        tag .. ": above the list's window, the panel stays inverted")
    base:free(); bb:free()
end

-- a button flashes on a dark panel by inverting what is shown, and back; in
-- light it flashes as KOReader draws it
do
    Device.screen.bb = picture(false)
    local orig = { did = 0, undid = 0 }
    local Btn = {}
    Btn.__index = Btn
    function Btn:_doFeedbackHighlight() orig.did = orig.did + 1 end
    function Btn:_undoFeedbackHighlight() orig.undid = orig.undid + 1 end
    local b = setmetatable({ { dimen = { x = 100, y = 80, w = 120, h = 40 }, radius = 6 } }, Btn)
    local kept = Theme.keep(setmetatable({ { dimen = { x = 0, y = 0, w = 10, h = 10 } },
        dimen = { x = 0, y = 0, w = 10, h = 10 } }, Btn))
    mode("dark")
    local panel = picture(false)
    Theme.apply(panel, { b, kept }, 0, 0, W, H, 0)
    local before = picture(false)
    before:blitFrom(Device.screen.bb, 0, 0, 0, 0, W, H)
    b:_doFeedbackHighlight()
    ok(orig.did == 0 and every(110, 85, 210, 115, function(x, y) return inverse(before, Device.screen.bb, x, y) end),
        "flash: a button on a dark panel inverts what is shown")
    b:_undoFeedbackHighlight()
    ok(orig.undid == 0 and every(0, 0, W, H, function(x, y) return same(before, Device.screen.bb, x, y) end),
        "flash: and back, exactly")
    kept:_doFeedbackHighlight(); kept:_undoFeedbackHighlight()
    ok(orig.did == 1 and orig.undid == 1, "flash: a kept button flashes as it always has")
    mode("light")
    b:_doFeedbackHighlight(); b:_undoFeedbackHighlight()
    ok(orig.did == 2 and orig.undid == 2, "flash: in light, KOReader's own flash")
    -- the mode changing during the tap (the Appearance buttons): the flash is
    -- undone the way it was done
    mode("dark")
    b:_doFeedbackHighlight(); mode("light"); b:_undoFeedbackHighlight()
    ok(orig.did == 2 and orig.undid == 2
        and every(0, 0, W, H, function(x, y) return same(before, Device.screen.bb, x, y) end),
        "flash: undone as it was done when the mode changes during the tap")
    panel:free(); before:free()
end

-- KOReader's night mode inverts the whole screen: Ink Away inverts only when
-- that does not already give the look chosen
do
    local cases = {
        { "light", false, false, false }, { "dark", false, true, true }, { "system", false, false, false },
        { "light", true, false, true }, { "dark", true, true, false }, { "system", true, true, false },
    }
    for _i, c in ipairs(cases) do
        mode(c[1]); Device.screen.night_mode = c[2]
        ok(Theme.dark() == c[3] and Theme.invert() == c[4],
            ("night mode %s, %s: dark %s, inverted here %s"):format(tostring(c[2]), c[1], tostring(c[3]), tostring(c[4])))
    end
    Device.screen.night_mode = false
    mode(nil)
    ok(Theme.mode() == "light", "no setting is light")
end

print(("realbb theme: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
