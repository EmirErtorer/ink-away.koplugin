-- Native PNG round trip: crop logical pixels in grey/colour and landscape.
local REPO = arg[1] or "."
require("ffi/loadlib")
local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
local PNG = require("ffi/png")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
local Device = require("device")
local UIManager = require("ui/uimanager")
local Clipboard = require("ink/clipboard")
local Storage = require("ink/storage")
local TestEnv = require("testenv")
Storage.appDir = function() return TestEnv.libraryDir() end
require("ink/view").tellAnywhere = function() end   -- (the real view: the decision is its own sheet)
local Capture = require("ink/reader/capture")
local checks = 0
for _, typ in ipairs({ BB.TYPE_BB8, BB.TYPE_BBRGB32 }) do
    for rotation = 0, 3 do
        local panel = BB.new(600, 800, typ)
        panel:setRotation(rotation)
        Device.screen.bb = panel
        Device.screen.getWidth = function() return panel:getWidth() end
        Device.screen.getHeight = function() return panel:getHeight() end
        local book = {}
        -- A coloured mark inside the selected rectangle, painted as book content.
        function book:snapshot(bb, ink)
            assert(ink)
            bb:fill(BB.COLOR_WHITE)
            bb:paintRect(50, 60, 40, 30, BB.ColorRGB32(200, 40, 80))
            return true
        end
        local c = Capture:new{ book = book }; book._capture = c
        local expected = c.page:getPixel(60, 70):getColorRGB32()
        local r, g, b = expected.r, expected.g, expected.b
        local expected_paper = c.page:getPixel(30, 40):getColorRGB32().r
        UIManager:show(c)
        c:onCorner(nil, { pos = { x = 20, y = 30 } })
        -- The corner marker must be excluded from the saved picture.
        c:paintTo(panel, 0, 0)
        c:onCorner(nil, { pos = { x = panel:getWidth() - 1, y = 130 } })
        c:paintTo(panel, 0, 0)
        local indicator
        for y = 30, 100 do
            for x = panel:getWidth() - 100, panel:getWidth() - 2 do
                local on_screen = panel:getPixel(x, y):getColorRGB32()
                local original = c.page:getPixel(x, y):getColorRGB32()
                if on_screen.r ~= original.r then
                    indicator = { x = x - 20, y = y - 30, r = original.r }
                    break
                end
            end
            if indicator then break end
        end
        assert(indicator, "the active capture symbol is visible on screen")
        assert(c._confirmation and c.page, "the rectangle is only a preview before confirmation")
        c._confirmation.copy()
        local op = Clipboard.take()[1]
        local ok, image = PNG.decodeFromFile(op.path, 4)
        assert(ok and image.width == panel:getWidth() - 21 and image.height == 100)
        local data = ffi.cast("uint8_t*", image.data)
        local at = (40 * image.width + 40) * 4
        assert(data[at] == r and data[at + 1] == g and data[at + 2] == b,
            "the crop preserves logical coordinates and colour")
        assert(data[0] == expected_paper, "selection marker is absent from the PNG")
        assert(data[(indicator.y * image.width + indicator.x) * 4] == indicator.r,
            "the active capture symbol is absent from the PNG even when selected")
        ffi.C.free(image.data)
        assert(not book._capture and not c.page)
        panel:free()
        checks = checks + 1
    end
end
Clipboard.clear()
TestEnv.cleanup()
print("native capture: " .. checks .. " grey/colour/rotation PNG round trips passed")
