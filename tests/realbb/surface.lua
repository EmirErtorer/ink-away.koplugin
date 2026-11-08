-- A viewer plugin's surface (ink/integration.lua) on KOReader's REAL blitter, and
-- what it must never change for everyone else:
--   * annotation mode over a book's own page is as it always was: not modal, none
--     of the surface's stand-ins on the view, a black pen drawn live with the fast
--     refresh (the e-ink pen path), the toolbar's arrows back and forward;
--   * the book's ink painted on a surface stays inside the surface's clip: what
--     reaches past it is put back pixel for pixel, the rest of the screen untouched,
--     and no copy of the screen is made for it.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/surface.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
local Device = require("device")
local UIManager = require("ui/uimanager")
local env = require("testenv")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local W, H = 1072, 1448
Device.screen.bb = BB.new(W, H, BB.TYPE_BB8)
Device.screen:setSize(W, H)
Device.hasColorScreen = function() return false end
Device.input.wacom_protocol = false
UIManager.reset()

local Book = require("ink/reader/book")
local BookInk = require("ink/reader/bookink")

-- a fixed-page book shown by KOReader's own view (page 3 at 1:1)
local document = { file = env.libraryDir() .. "/surface-real.pdf" }
local ui = { document = document, paging = {}, view = {
    state = { page = 3, zoom = 1, offset = { x = 0, y = 0 } }, visible_area = { x = 0, y = 0 },
    paintTo = function(_, bb) bb:fill(BB.COLOR_WHITE) end,
} }
function ui.view:screenToPageTransform(p) return { page = 3, x = p.x, y = p.y } end
function ui:handleEvent(ev) self.last_event = ev end

------------------------------------------------------------------------------
-- 1. the reader's own page: nothing of the surface
------------------------------------------------------------------------------
do
    local book = Book.new(ui, require("ink/integration").new())
    book._data = BookInk.new()
    book.sidecar, book.dirs = env.libraryDir(), { env.libraryDir() }
    UIManager._window_stack = {}
    ok(book:doc() == book:readerDoc() and book:currentPage() == book:readerPage()
        and book:layoutKey() == book:readerLayoutKey() and book:visiblePages()[1] == 3,
        "native: the book is asked as the reader's own view")
    book:annotate()
    local view = book._view
    ok(view ~= nil and view.modal == nil and book.surface == nil, "native: annotation mode as always, not modal")
    ok(rawget(view, "paintTo") == nil and rawget(view, "handleEvent") == nil and rawget(view, "inArea") == nil,
        "native: none of a surface's stand-ins on the view")
    ok(view._reader_viewport == nil, "native: no viewer room kept")
    -- a black pen, live: the fast refresh, as on main
    local modes = {}
    local orig = UIManager.setDirty
    UIManager.setDirty = function(self, w, mode, region)
        modes[#modes + 1] = tostring(mode)
        return orig(self, w, mode, region)
    end
    view.pen_color, view.pen_alpha, view.pen_style = { 0, 0, 0 }, 255, "solid"
    view:setTool("pen")
    local x, y = view.view.area_x + 200, 600
    view:onIaTouch(nil, { pos = { x = x, y = y } })
    for i = 1, 12 do view:onIaPan(nil, { pos = { x = x + i * 15, y = y + i * 2 } }) end
    local live = view._live_mode
    view:onIaPanRelease(nil, { pos = { x = x + 180, y = y + 24 } })
    view:flushPending()
    UIManager.setDirty = orig
    ok(live == "fast", "native: a black pen is drawn live with the fast refresh (" .. tostring(live) .. ")")
    local fast = 0
    for _i, m in ipairs(modes) do if m == "fast" then fast = fast + 1 end end
    ok(fast > 0, "native: its live refreshes are fast ones (" .. fast .. " of " .. #modes .. ")")
    -- the arrows: back and forward
    local turned = {}
    ui.handleEvent = function(_, ev) turned[#turned + 1] = ev.args and ev.args[1] end
    view:turnArrow("left"); view:turnArrow("right")
    ok(turned[1] == -1 and turned[2] == 1, "native: the toolbar's left arrow goes back, the right one forward")
    ok(rawget(view, "paintTo") == nil, "native: still none of a surface's stand-ins after turning")
    view:closeCanvas()
    ok(book._view == nil and book.surface == nil, "native: closed, nothing left")
end

------------------------------------------------------------------------------
-- 2. ink on a surface stays inside its clip
------------------------------------------------------------------------------
do
    local book = Book.new(ui, require("ink/integration").new())
    book._data = BookInk.new()
    book.sidecar, book.dirs = env.libraryDir(), { env.libraryDir() }
    local s = { version = 1, document = document }
    function s:pages() return { 7 } end
    function s:key() return "real-7" end
    function s:toPage(x, y) return 7, x, y, 1, 0 end
    function s:toScreen(page, x, y) if page == 7 then return x, y, 1, 0 end end
    function s:clip() return { x = 300, y = 300, w = 400, h = 400 } end
    function s:snapshot(bb) bb:fill(BB.COLOR_WHITE) end
    function s:repaint() end
    -- a black stroke across the clip and far past it on both sides
    book:setSurface(s)
    local op = { kind = "ink", pts = { 100, 500, 400, 500, 700, 500, 950, 500 }, width = 12, color = { 0, 0, 0 } }
    book:setPageOps({ op }, nil, nil)
    book:setSurface(nil)
    ok(#book:data().items == 1 and book:data().items[1].a.page == 7, "the stroke is kept on the surface's page")
    local bb = BB.new(W, H, BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE)
    -- a mark outside the clip that must survive
    bb:paintRect(150, 480, 20, 40, BB.COLOR_GRAY)
    local before = bb:getPixel(160, 500):getColor8().a
    book:paintSurface(s, bb)
    local function dark(px, py) return bb:getPixel(px, py):getColor8().a < 128 end
    ok(dark(500, 500), "inside the clip the ink is painted")
    ok(not dark(250, 500) and not dark(850, 500), "past the clip, left and right, nothing is painted")
    ok(bb:getPixel(160, 500):getColor8().a == before, "what was on the screen past the clip is exactly as it was")
    ok(not dark(500, 200) and not dark(500, 900), "above and below the clip, untouched")
    -- a folded spread: two parts, each its own clip
    function s:regions()
        local a = setmetatable({}, { __index = s }); function a.clip() return { x = 300, y = 300, w = 150, h = 400 } end
        local b = setmetatable({}, { __index = s }); function b.clip() return { x = 550, y = 300, w = 150, h = 400 } end
        return { a, b }
    end
    bb:fill(BB.COLOR_WHITE)
    book:paintSurface(s, bb)
    ok(dark(350, 500) and dark(650, 500), "a folded spread: each part painted")
    ok(not dark(500, 500), "and nothing between the two parts (the fold)")
    -- the book's ink hidden in the settings: nothing, unless asked for
    G_reader_settings.data.inkaway_book_ink = false
    s.regions = nil
    bb:fill(BB.COLOR_WHITE)
    book:paintSurface(s, bb)
    ok(not dark(500, 500), "the book's ink hidden: not painted on the surface")
    book:paintSurface(s, bb, true)
    ok(dark(500, 500), "unless forced (annotation mode's own picture)")
    G_reader_settings.data.inkaway_book_ink = nil
    bb:free()
end

env.cleanup()
print(("realbb surface: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
