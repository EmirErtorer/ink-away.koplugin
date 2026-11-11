-- In KOReader's real emulator, with its real widgets and settings: a long press on a
-- book's page number toggles the bookmark with any tool, by finger, and a hidden
-- folder of pictures is listed in the picture picker once KOReader shows hidden files.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/bookmarkhidden.lua <repo>
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
_G.G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(tmp .. "/settings.reader.lua")
G_reader_settings:saveSetting("inkaway_session_migrated", true)
G_reader_settings:saveSetting("inkaway_welcome_seen", true)
G_reader_settings:saveSetting("inkaway_library_dir", tmp .. "/lib")
G_reader_settings:saveSetting("inkaway_palm_reject", false)
lfs.mkdir(tmp .. "/lib")
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. package.path
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

-- 1. a long press on the page number, real view and window stack, a stand-in book
local ReaderInkView = require("ink/reader/inkview")
local toggles, on = 0, false
local book = { ui = { view = { footer_visible = true, dogear_visible = false,
    footer = { getHeight = function() return 60 end } }, bookmark = {} } }
function book.ui.bookmark:onToggleBookmark() toggles = toggles + 1; on = not on; book.ui.view.dogear_visible = on end
function book:snapshot(bb) bb:fill(BB.COLOR_WHITE) end
function book:pageOps() return { ops = {}, items = {} } end
function book:setPageOps(ops) local m, k = {}, {}; for _, op in ipairs(ops) do m[op] = { id = "n" }; k[#k + 1] = m[op] end return m, k end
function book:save() end
function book:turn() end
function book:repaint() end
function book:hasInk() return false end
local view = ReaderInkView:new{ book = book }
UIManager:show(view)
local H = Device.screen:getHeight()
local x = view.toolbar:getSize().w + 100
for _, tool in ipairs({ "pen", "highlighter", "erase", "lasso", "pan" }) do
    view.tool = tool
    view:onIaTouch(nil, { pos = { x = x, y = H - 25 } })
    view:onIaHold(nil, { pos = { x = x, y = H - 25 } })
    view:onIaPanRelease(nil, { pos = { x = x, y = H - 25 } })
end
ok(toggles == 5 and #view.canvas.ops == 0, "a long press on the page number toggled the bookmark with five tools, drawing nothing (" .. toggles .. ")")
UIManager:close(view)

-- 2. the picture picker: a .emotis folder, real ThumbGrid, real lfs
local D = tmp .. "/pics"
lfs.mkdir(D); lfs.mkdir(D .. "/.emotis"); lfs.mkdir(D .. "/plain")
local f = io.open(D .. "/.emotis/cat.png", "w"); f:write("x"); f:close()
local InkAwayView = require("ink/view")
local v2 = InkAwayView:new{}
UIManager:show(v2)
-- the picker's grid: the topmost window with items
local function topGrid()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w and w.items and w.on_pick then return w end
    end
end
local function listing()
    v2:pickFile(D, function() end, v2.isPictureName)
    local grid = topGrid()
    local names = {}
    for _, it in ipairs(grid.items or {}) do names[#names + 1] = it.label end
    UIManager:close(grid)
    return table.concat(names, ","), grid
end
local off = listing()
ok(off == "plain", "hidden files off: only the plain folder (" .. off .. ")")
G_reader_settings:saveSetting("show_hidden", true)
local on_list, grid = listing()
ok(on_list == ".emotis,plain", "hidden files on: the .emotis folder is listed (" .. on_list .. ")")
v2:pickFile(D, function() end, v2.isPictureName)
grid = topGrid()
for _, it in ipairs(grid.items) do if it.label == ".emotis" then grid.on_pick(it) end end
ok(#grid.items == 1 and grid.items[1].label == "cat.png" and grid.items[1].picture, "and the picture in it can be picked")
UIManager:close(grid)
UIManager:close(v2)

print(("realbb bookmarkhidden: %d checks, %d failures"):format(checks, failures))
os.execute("rm -rf '" .. tmp .. "'")
os.exit(failures == 0 and 0 or 1)
