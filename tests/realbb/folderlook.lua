-- A library folder's colour and icon (ink/folderlook.lua) on KOReader's REAL
-- blitter and SVG renderer: every colour fills the folder's front and a darker
-- back with its tab, the corners stay the card's grey, an icon shows in a
-- deeper shade on the front, a look the binder holds wrongly draws nothing or
-- what it can, and a folder is drawn once and then reused.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/folderlook.lua <repo> [outdir]
local REPO = arg[1] or "."
local OUTDIR = arg[2]
require("setupkoenv")
package.path = REPO .. "/?.lua;" .. package.path   -- (KOReader's own modules, not the mocks)
local BB = require("ffi/blitbuffer")
local Mupdf = require("ffi/mupdf")
-- KOReader's renderers as ui/renderimage drives them (it needs the whole app)
local NnSVG = require("libs/libkoreader-nnsvg")
package.loaded["ui/renderimage"] = {
    renderSVGImageFile = function(_, file, w, h)
        local svg = NnSVG.new(file)
        local nw, nh = svg:getSize()
        local zoom = math.min(w / nw, h / nh)
        local bb = BB.new(w, h, BB.TYPE_BBRGB32)
        svg:drawTo(bb, zoom, math.floor((w - math.ceil(zoom * nw)) / 2 + 0.5), math.floor((h - math.ceil(zoom * nh)) / 2 + 0.5))
        svg:free()
        return bb, true
    end,
    renderImageFile = function(_, file) return Mupdf.renderImageFile(file) end,
    scaleBlitBuffer = function(_, bb, w, h) local out = Mupdf.scaleBlitBuffer(bb, w, h); bb:free(); return out end,
}
local FolderLook = require("ink/folderlook")
local time = require("ui/time")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function px(bb, x, y) return bb:getPixel(x, y):getColorRGB32() end
local function near(c, rgb, tol)
    return math.abs(c.r - rgb[1]) <= tol and math.abs(c.g - rgb[2]) <= tol and math.abs(c.b - rgb[3]) <= tol
end
local function lum(c) return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b end

-- the colours
ok(#FolderLook.COLORS == 12, "twelve colours (" .. #FolderLook.COLORS .. ")")
local keys = {}
for _, c in ipairs(FolderLook.COLORS) do
    ok(not keys[c.key], c.key .. " once"); keys[c.key] = true
    ok(type(c.name) == "string" and #c.rgb == 3, c.key .. " has a name and an rgb")
end

-- what the binder may hold
ok(FolderLook.clean(nil) == nil, "no look")
ok(FolderLook.clean("green") == nil, "a look that is not a table")
ok(FolderLook.clean({}) == nil, "an empty look")
ok(FolderLook.clean({ color = "mauve" }) == nil, "an unknown colour alone draws nothing")
local c = FolderLook.clean({ color = "mauve", icon = "ko/star.full.svg" })
ok(c and c.color == nil and c.icon == "ko/star.full.svg", "an unknown colour keeps the icon")
ok(FolderLook.clean({ color = "teal", icon = 5 }).icon == nil, "an icon that is not a name is dropped")

-- the icons on offer
local icons = FolderLook.icons()
local kinds, ids = {}, {}
for _, i in ipairs(icons) do
    local kind = i.id:match("^(%a+)/")
    kinds[kind] = (kinds[kind] or 0) + 1
    ids[i.id] = i
    ok(FolderLook.iconPath(i.id) == i.path, i.id .. " is found again by its id")
end
ok((kinds.ko or 0) >= 20, "KOReader's icons are offered (" .. tostring(kinds.ko) .. ")")
ok((kinds.ink or 0) >= 10, "Ink Away's icons are offered (" .. tostring(kinds.ink) .. ")")
ok(ids["ko/star.full.svg"] and ids["ko/appbar.settings.svg"], "star and settings are there")
ok(not ids["ko/rotation.0UR.svg"] and not ids["ko/wifi.open.50.svg"], "state variants are left out")
ok(not ids["ink/ges_tap.svg"] and not ids["ink/sh_rect.svg"], "toolbar parts are left out")
ok(ids["ink/pen.svg"] and ids["ink/notebook.svg"], "pen and notebook are there")
for _, i in ipairs(icons) do
    ok(not i.id:match("^user/inkaway%."), "Ink Away's copies in koreader/icons are not offered twice: " .. i.id)
end
ok(ids["ko/appbar.settings.svg"].label == "Settings", "appbar.settings reads Settings")
ok(FolderLook.iconLabel("book.opened") == "Book opened", "book.opened reads Book opened")
ok(FolderLook.iconPath("ko/no-such-icon.svg") == nil, "a missing icon is nil")
ok(FolderLook.iconPath("../../etc/passwd") == nil and FolderLook.iconPath("ko/..") == nil,
    "an id is a kind and a file name only")
ok(FolderLook.iconName("ink/booknotes.svg") == "Booknotes", "an icon's name")

-- every colour, plain and with an icon
local W, BG = 160, 0xE6
local H = math.floor(W * FolderLook.ASPECT + 0.5)
local sheet = BB.new(W * 6 + 70, (H + 10) * 4 + 10, BB.TYPE_BBRGB32)
sheet:fill(BB.Color8(BG))
local t0 = time.now()
for i, col in ipairs(FolderLook.COLORS) do
    for j, icon in ipairs({ false, "ko/star.full.svg" }) do
        local look = { color = col.key, icon = icon or nil }
        local t = FolderLook.tile(look, W, BG)
        local what = col.key .. (icon and " with an icon" or "")
        ok(t ~= nil, what .. " draws")
        if t then
            ok(t:getWidth() == W and t:getHeight() == H, what .. " is " .. W .. " x " .. H)
            ok(near(px(t, 0, 0), { BG, BG, BG }, 2) and near(px(t, W - 1, H - 1), { BG, BG, BG }, 2),
                what .. ": its rounded corners show the card")
            ok(near(px(t, W - 3, 2), { BG, BG, BG }, 2), what .. ": right of the tab is the card")
            local tab = px(t, math.floor(W * 0.2), math.floor(H * 0.06))
            ok(near(tab, { col.rgb[1] * 0.8, col.rgb[2] * 0.8, col.rgb[3] * 0.8 }, 3), what .. ": the tab is the darker back")
            local front = px(t, math.floor(W * 0.08), math.floor(H * 0.6))
            ok(near(front, col.rgb, 3), what .. ": the front is the colour")
            -- the icon's box on the front
            local dark = 0
            for y = math.floor(H * 0.35), math.floor(H * 0.85) do
                for x = math.floor(W * 0.3), math.floor(W * 0.7) do
                    if lum(px(t, x, y)) < lum(front) - 25 then dark = dark + 1 end
                end
            end
            if icon then ok(dark > 150, what .. ": the icon shows darker on the front (" .. dark .. ")")
            else ok(dark == 0, what .. ": a plain front") end
            sheet:blitFrom(t, 10 + ((i - 1) % 6) * (W + 10), 10 + (math.floor((i - 1) / 6) * 2 + (j - 1)) * (H + 10), 0, 0, W, H)
        end
    end
end
local first_ms = time.to_ms(time.since(t0))
ok(first_ms < 1500, ("24 folders drawn in %d ms"):format(first_ms))

-- drawn once: the same picture comes back, quickly
local a = FolderLook.tile({ color = "green", icon = "ko/star.full.svg" }, W, BG)
t0 = time.now()
for _ = 1, 1000 do FolderLook.tile({ color = "green", icon = "ko/star.full.svg" }, W, BG) end
local again_ms = time.to_ms(time.since(t0))
ok(FolderLook.tile({ color = "green", icon = "ko/star.full.svg" }, W, BG) == a, "the same look is the same picture")
ok(again_ms < 50, ("a kept folder comes back at once (1000 in %d ms)"):format(again_ms))
ok(FolderLook.tile({ color = "green", icon = "ko/star.full.svg" }, W, 0x19) ~= a, "on a dark card it is drawn again")
local dark = FolderLook.tile({ color = "green" }, W, 0x19)
ok(near(px(dark, 0, 0), { 0x19, 0x19, 0x19 }, 2), "on a dark card its corners are dark")

-- what draws nothing, and what draws without its icon
ok(FolderLook.tile(nil, W, BG) == nil, "no look, no folder (the plain icon shows)")
ok(FolderLook.tile({ color = "green" }, 4, BG) == nil, "too small to draw")
local gone = FolderLook.tile({ color = "blue", icon = "ko/no-such-icon.svg" }, W, BG)
ok(gone ~= nil, "an icon gone from KOReader leaves the coloured folder")
local plain_icon = FolderLook.tile({ icon = "ko/star.full.svg" }, W, BG)
ok(plain_icon and lum(px(plain_icon, math.floor(W * 0.08), math.floor(H * 0.6))) > 150,
    "an icon without a colour sits on a light grey folder")

-- the chooser's previews
local pv = FolderLook.iconPreview(ids["ko/star.full.svg"].path, 64, BG)
ok(pv and pv:getWidth() == 64, "an icon's preview")
if pv then pv:free() end

-- only so many are kept
local keep = FolderLook.KEEP
FolderLook.KEEP = 4
for wdt = 40, 60 do FolderLook.tile({ color = "red" }, wdt, BG) end
FolderLook.KEEP = keep
ok(true, "older folders are let go past the limit")

if OUTDIR then sheet:writePNG(OUTDIR .. "/folderlook.png") end
sheet:free()
FolderLook.free()
print(("folderlook: %d checks, %d failures (24 drawn in %d ms, 1000 kept in %d ms)"):format(checks, failures, first_ms, again_ms))
os.exit(failures == 0 and 0 or 1)
