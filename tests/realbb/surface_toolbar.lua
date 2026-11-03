-- Compare stationary and navigating toolbar pixels over a changing live page.
-- Uses the real blitter, ReaderInkView layout, surround and theme painting;
-- host widgets/input and the generic book provider are fixtures.
-- From a KOReader runtime: ./luajit REPO/tests/realbb/surface_toolbar.lua REPO
local REPO = assert(arg[1])
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
local env = require("testenv")
_G.G_reader_settings = {
    data = env.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end,
}
local Device = require("device")
local Theme = require("ink/ui/theme")
-- Match the real toolbar's transparent button cells, with small opaque icon
-- tiles. The generic headless Button paints a whole cell with a mock color.
local Button = require("ui/widget/button")
function Button:getSize() return { w = self.width, h = self.height or self._h } end
function Button:paintTo(bb, x, y)
    bb:paintRect(x + 6, y + 6, 10, 10, BB.COLOR_WHITE)
    bb:paintRect(x + 8, y + 8, 6, 6, BB.COLOR_BLACK)
end
local ReaderInkView = require("ink/reader/inkview")
local checks, failures = 0, 0
local function ok(c, what)
    checks = checks + 1
    if not c then failures = failures + 1; print("FAIL: " .. what) end
end
local function sameRect(a, b, x0, y0, w, h)
    for y = y0, y0 + h - 1 do
        for x = x0, x0 + w - 1 do
            local p, q = a:getPixel(x, y):getColorRGB32(), b:getPixel(x, y):getColorRGB32()
            if p.r ~= q.r or p.g ~= q.g or p.b ~= q.b then return false end
        end
    end
    return true
end
for _, kind in ipairs({ BB.TYPE_BB8, BB.TYPE_BBRGB32 }) do
    for _, side in ipairs({ "left", "right", "top", "bottom" }) do
        for _, mode in ipairs({ "light", "dark" }) do
            local W, H = 600, 800
            Device.screen.bb = BB.new(W, H, kind)
            Device.screen:setSize(W, H)
            Device.screen.night_mode = false
            G_reader_settings:saveSetting("inkaway_book_toolbar_side", side)
            G_reader_settings:saveSetting("inkaway_book_toolbar_hidden", false)
            G_reader_settings:saveSetting(Theme.SETTING, mode)
            local shade = 73
            local book = {
                snapshot = function(_, bb) bb:fill(BB.Color8(shade)) end,
                pageOps = function() return { ops = {}, items = {} } end,
                save = function() end,
                repaint = function() end,
            }
            local view = ReaderInkView:new{ book = book }
            view._bar_toggle_hidden = true
            local baseline = BB.new(W, H, kind)
            view:paintTo(baseline, 0, 0)
            local size = view.toolbar:getSize()
            local tag = side .. "/" .. mode .. "/" .. kind
            -- A source panel may have constrained the old editable area. Live
            -- camera frames must not inherit that stale clip outside the bar.
            local v = view.view
            local px, py = v.area_x + 4, v.area_y + 4
            v.area_x, v.area_y = v.area_x + 20, v.area_y + 20
            v.area_w, v.area_h = v.area_w - 40, v.area_h - 40
            view._surface_navigating = true
            for frame = 1, 3 do
                shade = 100 + frame * 30
                local live = BB.new(W, H, kind)
                view:paintTo(live, 0, 0)
                ok(sameRect(baseline, live, view._bar_x, view._bar_y, size.w, size.h),
                    tag .. ": complete toolbar stays opaque and identical on frame " .. frame)
                local p = live:getPixel(math.floor(v.area_x + v.area_w / 2), math.floor(v.area_y + v.area_h / 2))
                ok(p:getColor8().a == shade, tag .. ": page beneath the editor continues updating")
                ok(live:getPixel(px, py):getColor8().a == shade,
                    tag .. ": live page is not obscured by the old canvas clip")
                live:free()
            end
            view._surface_navigating = nil
            view:setToolbarHidden(true)
            view._surface_navigating = true
            local hidden = BB.new(W, H, kind)
            view:paintTo(hidden, 0, 0)
            local p = hidden:getPixel(math.floor(W / 2), math.floor(H / 2))
            ok(p:getColor8().a == shade, tag .. ": collapsed toolbar does not obscure the live page")
            view._surface_navigating = nil
            hidden:free(); baseline:free()
            view:onCloseWidget()
            Device.screen.bb:free()
        end
    end
end
env.cleanup()
print(("surface_toolbar: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
