-- A drawing's Bookshelf cover (ink/framecover.lua) on KOReader's REAL blitter,
-- image decoder and scaler: every frame in every finish frames the drawing,
-- fills the cover to its edges with no seam where its pieces meet, keeps the
-- drawing's shape (portrait, landscape, square, very tall), lets the drawing
-- show in the opening, writes the instant photo's caption, and is quick.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/framecover.lua <repo> [outdir]
local REPO = arg[1] or "."
local OUTDIR = arg[2]
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
local Mupdf = require("ffi/mupdf")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
local Font = dofile(REPO .. "/tests/realbb/realtext.lua").install()
-- KOReader finds a bare font file name in its font folders
local here = io.popen("pwd"):read("*l")
local getFace = Font.getFace
function Font:getFace(name, size)
    if type(name) == "string" and name:match("^[%w%-]+%.ttf$") then name = here .. "/fonts/noto/" .. name end
    return getFace(self, name, size)
end
local scaled = 0
package.loaded["ui/renderimage"] = {
    scaleBlitBuffer = function(_, bb, w, h, free_orig)
        if bb:getWidth() == w and bb:getHeight() == h then return bb end
        scaled = scaled + 1
        local out = Mupdf.scaleBlitBuffer(bb, w, h)
        if free_orig ~= false then bb:free() end
        return out
    end,
    renderImageFile = function(_, file) return Mupdf.renderImageFile(file) end,
}
local TestEnv = require("testenv")
local FrameCover = require("ink/framecover")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function px(bb, x, y) return bb:getPixel(x, y):getColorRGB32() end
local function lum(c) return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b end

-- the drawing: a red square on white with a black ring, so its edges and
-- middle are easy to find
local function drawing(w, h)
    local b = BB.new(w, h, BB.TYPE_BBRGB32)
    b:paintRectRGB32(0, 0, w, h, BB.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
    b:paintRectRGB32(math.floor(w * 0.3), math.floor(h * 0.3), math.floor(w * 0.4), math.floor(h * 0.4),
        BB.ColorRGB32(0xD0, 0x20, 0x20, 0xFF))
    return b
end

local frames = FrameCover.frames()
ok(#frames == 12, "twelve frames (" .. #frames .. ")")
local names = FrameCover.names()
for _, k in ipairs(frames) do
    ok(names[k] ~= nil, k .. " has a name")
    ok(#FrameCover.options(k) >= 3, k .. " has finishes")
    for _, o in ipairs(FrameCover.options(k)) do
        ok(FrameCover.optionName(k, o) ~= o or o == "", k .. "/" .. o .. " has a name")
        if FrameCover.frame(k).kind ~= "canvas" then
            local f = io.open(FrameCover.dataDir() .. k .. "-" .. o .. ".jpg")
            ok(f ~= nil, k .. "/" .. o .. " has its pieces")
            if f then f:close() end
        end
    end
end
ok(select(2, FrameCover.lookOf("baroque", "nope")) == "gold", "an unknown finish gives the frame's first")
ok(FrameCover.lookOf("nope", "gold") == nil, "an unknown frame gives nothing")
ok(FrameCover.render{ frame = "nope" } == nil, "an unknown frame draws nothing")

-- every frame and finish, on a portrait and a landscape drawing
local portrait, landscape = drawing(536, 724), drawing(724, 536)
local slowest, total, n = 0, 0, 0
for _, k in ipairs(frames) do
    local fr = FrameCover.frame(k)
    for _, o in ipairs(FrameCover.options(k)) do
        for _, case in ipairs({ { portrait, "true" }, { portrait, "fill" }, { landscape, "true" }, { landscape, "fill" } }) do
            local pic, shape = case[1], case[2]
            local t0 = os.clock()
            local bb = FrameCover.render{ frame = k, option = o, shape = shape, picture = pic, name = "Sunny house" }
            local dt = os.clock() - t0
            total, n = total + dt, n + 1
            slowest = math.max(slowest, dt)
            local what = k .. "/" .. o .. (pic == portrait and " portrait" or " landscape") .. " " .. shape
            ok(bb ~= nil, what .. " draws")
            if bb then
                local W, H, _open, box = FrameCover.layout(fr, pic:getWidth(), pic:getHeight(), shape)
                ok(bb:getWidth() == W and bb:getHeight() == H and W == 480, what .. " is " .. W .. "x" .. H)
                local pa = pic:getHeight() / pic:getWidth()
                if shape == "fill" then
                    ok(H == 720, what .. ": 2:3, as Bookshelf shows covers")
                    -- trimmed to fill, never by more than a quarter: the
                    -- red square (the middle 40% of the drawing) is whole
                    local cy = box.y + math.floor(box.h / 2)
                    local reds, x0 = 0, nil
                    for x = box.x, box.x + box.w - 1 do
                        local c = px(bb, x, cy)
                        if c.r > 150 and c.g < 90 then reds = reds + 1; x0 = x0 or x end
                    end
                    local shown = reds / box.w
                    ok(shown > 0.40 and shown < 0.56, what .. ": trimmed a little at most (" .. math.floor(shown * 100) .. "% red)")
                else
                    ok(math.abs(box.h / box.w - pa) < 0.02, what .. ": the frame hugs the drawing in its own shape")
                end
                -- the drawing shows in the middle of the opening
                local mid = px(bb, box.x + math.floor(box.w / 2), box.y + math.floor(box.h / 2))
                ok(mid.r > 150 and mid.g < 90, what .. " shows the drawing (" .. mid.r .. "," .. mid.g .. ")")
                -- the frame covers the whole edge: no unpainted (black) pixel
                -- along the outer edge, except a canvas's wall
                if fr.kind ~= "canvas" then
                    local holes = 0
                    for x = 0, W - 1 do
                        for _, y in ipairs({ 0, 2, H - 3, H - 1 }) do
                            local c = px(bb, x, y)
                            if c.r + c.g + c.b == 0 then holes = holes + 1 end
                        end
                    end
                    for y = 0, H - 1, 3 do
                        for _, x in ipairs({ 0, 2, W - 3, W - 1 }) do
                            local c = px(bb, x, y)
                            if c.r + c.g + c.b == 0 then holes = holes + 1 end
                        end
                    end
                    ok(holes == 0, what .. " has no gaps at its edges (" .. holes .. ")")
                end
                -- no seam: along the middle of the top side, neighbouring
                -- columns differ no more than the carving itself does
                if fr.kind == "frame" then
                    local y = math.floor(fr.t / 2)
                    local worst, sum, cnt = 0, 0, 0
                    for x = fr.c + 1, W - fr.c - 2 do
                        local d = math.abs(lum(px(bb, x, y)) - lum(px(bb, x - 1, y)))
                        worst = math.max(worst, d); sum = sum + d; cnt = cnt + 1
                    end
                    ok(cnt == 0 or worst < 160, what .. " has no hard seam (" .. math.floor(worst) .. ")")
                end
                if OUTDIR and (o == FrameCover.options(k)[1] or (pic == portrait and shape == "fill")) then
                    bb:writePNG(OUTDIR .. "/" .. k .. "-" .. o .. "-" .. (pic == portrait and "p" or "l") .. "-" .. shape .. ".png")
                end
                bb:free()
            end
        end
    end
end
print(string.format("TIME %d covers: %.1f ms each, slowest %.1f ms", n, total / n * 1000, slowest * 1000))
ok(slowest < 0.25, "every cover draws quickly")

-- odd shapes: square, very tall (kept to the limit), tiny
for _, sz in ipairs({ { 600, 600 }, { 300, 1400 }, { 1400, 300 }, { 40, 60 } }) do
    local pic = drawing(sz[1], sz[2])
    for _, k in ipairs({ "baroque", "deco", "instant", "canvas", "crafts" }) do
        local bb = FrameCover.render{ frame = k, picture = pic, name = "x" }
        ok(bb ~= nil, k .. " draws a " .. sz[1] .. "x" .. sz[2] .. " drawing")
        if bb then
            local a = bb:getHeight() / bb:getWidth()
            ok(a == 1.5, k .. " " .. sz[1] .. "x" .. sz[2] .. ": a 2:3 cover (" .. a .. ")")
            bb:free()
            bb = FrameCover.render{ frame = k, shape = "true", picture = pic, name = "x" }
            a = bb:getHeight() / bb:getWidth()
            ok(a >= 0.5 and a <= 2.0, k .. " " .. sz[1] .. "x" .. sz[2] .. " in its own shape stays one a shelf can show (" .. a .. ")")
            bb:free()
        end
    end
    pic:free()
end

-- no drawing: blank paper in the frame
local bb = FrameCover.render{ frame = "louis" }
ok(bb ~= nil, "a cover without its drawing yet shows blank paper")
if bb then
    local _W, _H, _open, box = FrameCover.layout(FrameCover.frame("louis"))
    local c = px(bb, box.x + math.floor(box.w / 2), box.y + math.floor(box.h / 2))
    ok(c.r == 255 and c.g == 255, "blank paper is white")
    bb:free()
end

-- the instant photo writes its name under the drawing
local function inkUnder(name)
    local b = FrameCover.render{ frame = "instant", option = "white", shape = "true", picture = portrait, name = name }
    local fr = FrameCover.frame("instant")
    local _W, H, _open, box = FrameCover.layout(fr, portrait:getWidth(), portrait:getHeight(), "true")
    local dark = 0
    for y = box.y + box.h + 4, H - 8 do
        for x = box.x, box.x + box.w - 1, 2 do
            if lum(px(b, x, y)) < 140 then dark = dark + 1 end
        end
    end
    b:free()
    return dark
end
ok(inkUnder("Sunny house") > 40, "the instant photo's caption is written")
ok(inkUnder("") == 0, "no caption without a name")
ok(inkUnder(string.rep("A very long drawing name ", 6)) > 40, "a long name still fits")

-- kept atlases and picture: the frame picker's many previews
local keep = {}
local snap = TestEnv.libraryDir() .. "/snap.png"
portrait:writePNG(snap)
for _, k in ipairs(frames) do
    local b = FrameCover.render({ frame = k, file = snap }, keep)
    ok(b ~= nil, k .. " draws from a snapshot file")
    if b then b:free() end
end
local kept = 0
for _ in pairs(keep) do kept = kept + 1 end
ok(kept == 14, "the picker keeps the picture, eleven atlases and the two tiles (" .. kept .. ")")
FrameCover.free(keep)
ok(next(keep) == nil, "and frees them")

-- written to a file
local file = TestEnv.libraryDir() .. "/cover.png"
ok(FrameCover.write(file, { frame = "museum", option = "oak", file = snap }), "a cover is written")
local back = Mupdf.renderImageFile(file)
ok(back and back:getWidth() == FrameCover.W, "and reads back")
if back then back:free() end
ok(not FrameCover.write(file .. "2", { frame = "nope" }), "an unknown frame writes nothing")

-- a never-opened drawing's picture, drawn once from its file: its strokes
-- scaled down onto its paper (see DrawingShelf.drawingImage)
do
    local Project = require("ink/project")
    local DShelf = require("ink/drawingshelf")
    local dpath = TestEnv.libraryDir() .. "/Pic.inkaway"
    assert(Project.save({ w = 1072, h = 1448, ops = {
        { kind = "ink", width = 30, alpha = 255, style = "solid", seed = 1, pts = { 100, 700, 970, 700 } },
        { kind = "ink", width = 30, alpha = 255, color = { 220, 30, 30 }, style = "solid", seed = 2,
          pts = { 100, 1100, 970, 1100 } } } }, dpath, { paper = { 250, 244, 226 } }))
    local t0 = os.clock()
    local img = DShelf.drawingImage(dpath, FrameCover.W)
    local dt = os.clock() - t0
    ok(img ~= nil, "draft: a drawing is drawn from its file")
    if img then
        ok(img:getWidth() == FrameCover.W and math.abs(img:getHeight() - math.floor(FrameCover.W * 1448 / 1072 + 0.5)) <= 1,
            "draft: at the cover's width, in the drawing's shape")
        local k = FrameCover.W / 1072
        local black = px(img, math.floor(500 * k), math.floor(700 * k))
        local red = px(img, math.floor(500 * k), math.floor(1100 * k))
        local paper = px(img, 10, 10)
        ok(black.r < 80 and black.g < 80, "draft: the black stroke is there")
        ok(red.r > 150 and red.g < 90, "draft: the red stroke too")
        ok(paper.r > 200 and paper.b < paper.r, "draft: on its cream paper (" .. paper.r .. "," .. paper.b .. ")")
        img:free()
    end
    print(string.format("TIME draft of a 1072x1448 drawing: %.1f ms", dt * 1000))
    local draft = TestEnv.libraryDir() .. "/Pic-draft.png"
    ok(DShelf.writeDraft(dpath, draft), "draft: written to a file")
    ok(not DShelf.writeDraft(TestEnv.libraryDir() .. "/none.inkaway", draft .. "2"), "draft: nothing for a missing file")
    -- a notebook is not a drawing
    local Notebook = require("ink/notebook")
    local npath = TestEnv.libraryDir() .. "/Nb.inkaway"
    assert(Project.saveNotebook(Notebook.new(600, 800, { style = "lines" }), npath))
    ok(DShelf.drawingImage(npath, 480) == nil, "draft: not for a notebook")
end

portrait:free(); landscape:free()
TestEnv.cleanup()
print(string.format("framecover (real blitter): %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
