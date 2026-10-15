-- The page on a screen turned in software, on KOReader's REAL blitter: in every
-- rotation (upright, upside down and both landscapes) the drawing area must
-- show the page exactly as it does upright, after a full render and after the
-- eraser's redraw of a small rect, in grey and colour.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/rotation.lua <repo>
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

-- The area as it reads in logical coordinates, whatever order its bytes are in.
local function logical(bb, w, h)
    local out = BB.new(w, h, bb:getType())
    for y = 0, h - 1 do
        for x = 0, w - 1 do out:setPixel(x, y, bb:getPixel(x, y)) end
    end
    local s = bytes(out)
    out:free()
    return s
end

local function page()
    local ops = {}
    for i = 0, 7 do
        ops[#ops + 1] = { kind = "ink", width = 6 + i, alpha = (i % 3 == 0) and 140 or 255,
            color = (i % 2 == 0) and { 200, 30, 30 } or nil, seed = 7,
            pts = { 80 + i * 20, 150, 300 + i * 25, 420, 520 + i * 10, 200 } }
    end
    ops[#ops + 1] = { kind = "shape", shape = "rect", fill = false, width = 5, alpha = 255, pts = { 150, 450, 450, 650 } }
    ops[#ops + 1] = { kind = "shape", shape = "ellipse", fill = true, width = 4, alpha = 200, pts = { 400, 500, 650, 700 } }
    return ops
end

-- A stand-in book for the annotation mode: its page is lines of grey "text".
local function standInBook()
    local book = {}
    function book:snapshot(bb)
        bb:fill(BB.COLOR_WHITE)
        for y = 120, bb:getHeight() - 120, 46 do
            bb:paintRect(90, y, bb:getWidth() - 180 - (y % 230), 18, BB.gray(0.6))
        end
    end
    function book:pageOps() return { ops = {}, items = {} } end
    function book:setPageOps(ops) local m = {}; for _, op in ipairs(ops) do m[op] = { id = "new" } end; return m, {} end
    function book:save() end
    function book:repaint() end
    return book
end

-- Open a view on a W x H screen turned by `rot`, with the page drawn and
-- rendered: a drawing, or with `on_book` the annotation mode over a book.
local function open(typ, W, H, rot, on_book)
    Device.screen.bb = BB.new(W, H, typ)
    Device.screen.bb:setRotation(rot)
    Device.screen:setSize(Device.screen.bb:getWidth(), Device.screen.bb:getHeight())
    Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
    UIManager.reset()
    package.loaded["ink/view"] = nil
    package.loaded["ink/reader/inkview"] = nil
    local view
    if on_book then
        view = require("ink/reader/inkview"):new{ book = standInBook() }
    else
        view = require("ink/view"):new{}
        view.canvas:setOps(page())
    end
    UIManager:show(view)
    view:composeCanvas(); view:renderView()
    return view
end

-- What the drawing area shows at each step, read in logical coordinates: the
-- page, the eraser's redraw of a scribbled-on rect, a stroke drawn with the pen
-- (in the area and on the screen it is copied to) and, for a drawing, the page
-- zoomed in.
local function steps(view, on_book)
    local v = view.view
    local aw, ah = v.area_w, v.area_h
    local out = {}
    local function keep(what) out[#out + 1] = { what, logical(view.area_bb, aw, ah) } end
    keep("the page shows")
    view.area_bb:paintRect(200, 200, 300, 200, BB.COLOR_BLACK)
    view:renderViewRect(200, 200, 500, 400)
    keep("the eraser's redraw shows the page")
    view:setTool("pen")
    local x, y = v.area_x + 150, v.area_y + 600
    view:onIaTouch(nil, { pos = { x = x, y = y } })
    for i = 1, 12 do view:onIaPan(nil, { pos = { x = x + i * 25, y = y + (i % 3) * 12 } }) end
    keep("a stroke shows while it is drawn")
    view:onIaPanRelease(nil, { pos = { x = x + 300, y = y } })
    view:flushPending()
    keep("the stroke shows once drawn")
    view._area_only, view._paint_all, view._full_blit = true, false, true
    view:paintTo(Device.screen.bb, 0, 0)
    local sb = Device.screen.bb
    local shot = BB.new(aw, ah, sb:getType())
    for yy = 0, ah - 1 do
        for xx = 0, aw - 1 do shot:setPixel(xx, yy, sb:getPixel(v.area_x + xx, v.area_y + yy)) end
    end
    out[#out + 1] = { "the screen shows the area", bytes(shot) }
    shot:free()
    if not on_book then
        view:setZoom(1.7)
        keep("the page zoomed in shows")
    end
    return out
end

for _, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    local kind = typ == BB.TYPE_BBRGB32 and "colour" or "grey"
    for _, on_book in ipairs({ false, true }) do
        -- each turn against its upright twin: upside down against upright, and
        -- the second landscape against the first
        for _, pair in ipairs({ { 0, 2, 1264, 1680 }, { 1, 3, 1680, 1264 } }) do
            local base, rot, W, H = pair[1], pair[2], pair[3], pair[4]
            local want = open(typ, W, H, base, on_book)
            local aw, ah = want.view.area_w, want.view.area_h
            local ref = steps(want, on_book)
            want:onCloseWidget()

            local tag = ("%s / %s / rotation %d"):format(kind, on_book and "book" or "drawing", rot)
            local view = open(typ, W, H, rot, on_book)
            ok(view.view.area_w == aw and view.view.area_h == ah, tag .. ": the area has the same size")
            ok(view._area_rot == rot, tag .. ": the area is built in the screen's pixel order")
            for i, got in ipairs(steps(view, on_book)) do
                ok(got[2] == ref[i][2], ("%s: %s as it does turned by %d"):format(tag, got[1], base))
            end
            view:onCloseWidget()
        end
    end
end

print(("realbb rotation: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
