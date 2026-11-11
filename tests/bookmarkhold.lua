-- A long press on the page number of a book toggles KOReader's bookmark on the
-- page, with any tool in hand, by finger or by pen, and never draws; a tap there
-- and a long press elsewhere do nothing; without the reader's footer there is no
-- page number to press.
--   luajit tests/bookmarkhold.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
_G.G_reader_settings = {
    data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function pos(x, y) return { pos = { x = x, y = y } } end

local W, H = 1072, 1448
Screen:setSize(W, H)
UIManager.reset()
package.loaded["ink/view"] = nil
package.loaded["ink/reader/inkview"] = nil
local ReaderInkView = require("ink/reader/inkview")

-- a stand-in book whose reader has a footer 60 px tall and a bookmark list
local function book(footer_visible)
    local b = { saved = 0 }
    b.ui = { view = { footer_visible = footer_visible, dogear_visible = false,
                      footer = { getHeight = function() return 60 end } } }
    b.ui.bookmark = { toggles = 0 }
    function b.ui.bookmark:onToggleBookmark()
        self.toggles = self.toggles + 1
        b.ui.view.dogear_visible = not b.ui.view.dogear_visible
        return true
    end
    function b:snapshot(bb) bb:fill(BB.COLOR_WHITE) end
    function b:pageOps() return { ops = {}, items = {} } end
    function b:setPageOps(ops) local m, k = {}, {}; for _, op in ipairs(ops) do m[op] = { id = "n" }; k[#k + 1] = m[op] end return m, k end
    function b:save() self.saved = self.saved + 1 end
    function b:turn() end
    function b:repaint() end
    function b:hasInk() return false end
    return b
end

local bk = book(true)
local view = ReaderInkView:new{ book = bk }
local notices = {}
view.showNotice = function(_self, text) notices[#notices + 1] = text end
local tw = view.toolbar:getSize().w
local fy = H - 30                        -- in the footer strip
local x = tw + 200

ok(view:pageNumberRect() and view:pageNumberRect().y == H - 60, "the strip is the reader's footer at the bottom")

-- every tool: a long press on the page number toggles, and draws nothing
local on = false
for _, tool in ipairs({ "pen", "highlighter", "erase", "text", "shape", "lasso", "pan", "fill" }) do
    view.tool = tool
    local before = #view.canvas.ops
    view:onIaTouch(nil, pos(x, fy))
    view:onIaHold(nil, pos(x, fy))
    view:onIaPanRelease(nil, pos(x, fy))
    on = not on
    ok(bk.ui.bookmark.toggles == ({ pen = 1, highlighter = 2, erase = 3, text = 4, shape = 5, lasso = 6, pan = 7, fill = 8 })[tool],
        tool .. ": a long press on the page number toggles the bookmark")
    ok(#view.canvas.ops == before, tool .. ": and draws nothing")
    ok(notices[#notices] == (on and "Bookmark added" or "Bookmark removed"), tool .. ": and says what it did (" .. tostring(notices[#notices]) .. ")")
end

-- a tap there does nothing
view.tool = "pen"
local n = bk.ui.bookmark.toggles
view:onIaTouch(nil, pos(x, fy))
view:onIaTap(nil, pos(x, fy))
ok(bk.ui.bookmark.toggles == n, "a tap on the page number does nothing")

-- a long press on the page itself does not
view:onIaTouch(nil, pos(x, 500))
view:onIaHold(nil, pos(x, 500))
view:onIaPanRelease(nil, pos(x, 500))
ok(bk.ui.bookmark.toggles == n, "a long press on the page is not a bookmark")

-- a drag from the strip draws, as from a floating button
view:onIaTouch(nil, pos(x, fy))
for i = 1, 8 do view:onIaPan(nil, pos(x + i * 15, fy - i * 10)) end
view:onIaPanRelease(nil, pos(x + 120, fy - 80))
view:flushPending()
ok(bk.ui.bookmark.toggles == n, "a drag from the page number toggles nothing")

-- the pen: held past KOReader's hold time and lifted
view.tool = "highlighter"
local clock = 0
view.nowMs = function() return clock end
view._pen_fab = { kind = "pagenum", slot = 0, x = x, y = fy, now = 0 }
clock = 2000
view:penFabFrame({ id = -1 }, true)
ok(bk.ui.bookmark.toggles == n + 1, "the pen held on the page number toggles it when lifted")
view._pen_fab = { kind = "pagenum", slot = 0, x = x, y = fy, now = 2000 }
clock = 2050
view:penFabFrame({ id = -1 }, true)
ok(bk.ui.bookmark.toggles == n + 1, "a pen tap on it does nothing")

-- the toolbar's own controls are untouched: a hold on a floating button does nothing
local before = bk.ui.bookmark.toggles
view:fabHold("pan")
ok(bk.ui.bookmark.toggles == before, "a hold on another control does nothing")
view:onCloseWidget()

-- no footer: no page number to press
local off = ReaderInkView:new{ book = book(false) }
off.showNotice = function() end
ok(off:pageNumberRect() == nil, "no footer, no strip")
off.tool = "pen"
off:onIaTouch(nil, pos(x, fy))
off:onIaHold(nil, pos(x, fy))
ok(off.book.ui.bookmark.toggles == 0, "with the footer off a long press at the bottom is not a bookmark")
off:onCloseWidget()

print(("bookmarkhold: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
