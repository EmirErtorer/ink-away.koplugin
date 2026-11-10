-- The quick menu and its icon in KOReader's top menu bar (ink/topbar.lua,
-- ink/launcher.lua) in the mock KOReader: the tab is added once and before the last
-- tab, the icon is copied where KOReader looks, a gesture is found and named
-- wherever the reader put it, and the sheet shows the right tiles in a book and
-- outside one.
--   luajit tests/launcher.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
local TestEnv = require("testenv")
local BASE = (os.getenv("INKAWAY_TMP") or "/tmp") .. "/inkaway-launcher-" .. os.time()
os.execute("rm -rf '" .. BASE .. "'; mkdir -p '" .. BASE .. "/data' '" .. BASE .. "/cwd/resources/icons'")
package.loaded["datastorage"] = { getDataDir = function() return BASE .. "/data" end, getSettingsDir = function() return BASE .. "/data/settings" end }
_G.G_reader_settings = {
    data = TestEnv.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local UIManager = require("ui/uimanager")
local Topbar = require("ink/topbar")
local Launcher = require("ink/launcher")
local Welcome = require("ink/welcome")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what) ok(a == b, what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
local function texts(w, out, seen)
    out, seen = out or {}, seen or {}
    if type(w) ~= "table" or seen[w] then return out end
    seen[w] = true
    if type(w.text) == "string" then out[#out + 1] = w.text end
    for k, v in pairs(w) do if k ~= "show_parent" and k ~= "parent" then texts(v, out, seen) end end
    return out
end
local function has(w, text)
    for _i, t in ipairs(texts(w)) do if t == text then return true end end
    return false
end
local function T(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end
local id = function(s) return s end

------------------------------------------------------------------------------
-- the tab
------------------------------------------------------------------------------
local tabs = { { icon = "appbar.filebrowser" }, { icon = "appbar.tools" }, { icon = "appbar.menu" } }
ok(Topbar.insertTab(tabs, function() end), "the tab is added")
eq(#tabs, 4, "one more tab")
eq(tabs[3].icon, Topbar.ICON, "just before the last (the main menu)")
eq(tabs[3].remember, false, "the menu never opens on it")
ok(not Topbar.insertTab(tabs, function() end) and #tabs == 4, "it is added only once")

ok(Topbar.enabled(function() return nil end), "the icon is on until switched off")
ok(not Topbar.enabled(function(k) if k == Topbar.SETTING then return false end end), "and off when it was")

-- a menu class: its tab table is rebuilt on every call, the tab follows each time
local built = 0
local Menu = { setUpdateItemTable = function(self)
    built = built + 1
    self.tab_item_table = { { icon = "a" }, { icon = "b" } }
end }
local on = true
ok(Topbar.patch(Menu, function() if not on then return false end end, function() end), "a menu class is patched")
ok(not Topbar.patch(Menu, function() end, function() end), "and only once")
local m = setmetatable({}, { __index = Menu })
m:setUpdateItemTable()
eq(#m.tab_item_table, 3, "the patched menu carries the tab")
eq(m.tab_item_table[2].icon, Topbar.ICON, "before the last")
m:setUpdateItemTable()
eq(#m.tab_item_table, 3, "and still one after another build")
on = false
m:setUpdateItemTable()
eq(#m.tab_item_table, 2, "switched off, the tab is gone")
ok(not Topbar.patch(nil, function() end, function() end), "no class, nothing to patch")
ok(not Topbar.patch({}, function() end, function() end), "a class without setUpdateItemTable is left alone")

-- tapping it: the top menu closes, then the quick menu is asked for
on = true
local tapped
local Menu2 = { setUpdateItemTable = function(self) self.tab_item_table = { { icon = "a" }, { icon = "b" } } end }
Topbar.patch(Menu2, function() return nil end, function(menu) tapped = menu end)
local m2
m2 = setmetatable({ menu_container = { { close_callback = function() m2.closed = true end } } }, { __index = Menu2 })
m2:setUpdateItemTable()
m2.tab_item_table[2].callback()
for fn in pairs(UIManager.scheduled) do fn() end
ok(m2.closed and m2.menu_container == nil and tapped == m2, "tapping closes the top menu and opens the quick menu")

------------------------------------------------------------------------------
-- the icon file
------------------------------------------------------------------------------
local lfs = require("libs/libkoreader-lfs")
local plugin_dir = "./"
local n = Topbar.installIcon(lfs, plugin_dir, BASE .. "/data", BASE .. "/cwd")
eq(n, 2, "the icon is copied to both places KOReader looks")
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local svg = read(BASE .. "/data/icons/" .. Topbar.ICON .. ".svg")
ok(svg and svg:find("<svg", 1, true) and svg:find("viewBox", 1, true), "an SVG, which KOReader draws for any screen")
ok(read(BASE .. "/cwd/resources/icons/" .. Topbar.ICON .. ".svg") == svg, "the same one in resources/icons")
eq(Topbar.installIcon(lfs, plugin_dir, BASE .. "/data", BASE .. "/cwd"), 2, "a second run keeps them")
do -- an old icon left by an earlier version is replaced even when its file time is newer
    local stale = BASE .. "/data/icons/" .. Topbar.ICON .. ".svg"
    local f = io.open(stale, "wb"); f:write("<svg>old</svg>"); f:close()
    Topbar.installIcon(lfs, plugin_dir, BASE .. "/data", BASE .. "/cwd")
    ok(read(stale) == svg, "a stale icon is replaced by the current one")
end
eq(Topbar.installIcon(lfs, plugin_dir, BASE .. "/none/at/all", nil), 0, "an unwritable place is skipped, not an error")
eq(Topbar.installIcon(lfs, "/no/such/plugin/", BASE .. "/data", nil), 0, "a missing source is skipped")
ok(not svg:find("png", 1, true) and not svg:find("<image", 1, true), "no raster in it, so no colour depth to go wrong")

------------------------------------------------------------------------------
-- gestures
------------------------------------------------------------------------------
local data = {
    gesture_reader = {
        one_finger_swipe_right_edge_down = { inkaway_annotate = true },
        two_finger_swipe_southwest = { inkaway_annotate = true },
        tap_top_right_corner = { inkaway_booknotes = true },
        pinch_gesture = { inkaway_capture = true },
    },
    gesture_fm = { two_finger_swipe_northwest = { inkaway_booknotes = true } },
}
eq(Launcher.gestureFor(data, "inkaway_annotate", { "gesture_reader" }), "one_finger_swipe_right_edge_down", "the gesture Ink Away set is found")
data.gesture_reader.one_finger_swipe_right_edge_down = nil
eq(Launcher.gestureFor(data, "inkaway_annotate", { "gesture_reader" }), "two_finger_swipe_southwest", "or the diagonal when the edge was taken")
eq(Launcher.gestureFor(data, "inkaway_booknotes", { "gesture_reader" }), "tap_top_right_corner", "a gesture the reader chose is found too")
eq(Launcher.gestureFor(data, "inkaway_booknotes", { "gesture_fm" }), "two_finger_swipe_northwest", "per screen: the file browser has its own")
eq(Launcher.gestureFor(data, "inkaway_library", { "gesture_reader" }), nil, "none when none is set")
eq(Launcher.gestureFor(nil, "inkaway_annotate"), nil, "and none without a gesture manager")

local t, glyph = Launcher.gesturePhrase("two_finger_swipe_southwest", nil, id, T)
eq(t, "Two-finger swipe from the top right to the bottom left", "Ink Away's own gestures keep the words the welcome notice uses")
eq(glyph, "ges_two_swipe_sw", "and their picture")
local names = { tap_top_right_corner = "Top right", hold_bottom_left_corner = "Bottom left", pinch_gesture = "Pinch",
    one_finger_swipe_left_edge_up = "Left edge up", two_finger_swipe_east = "\u{21D2}" }
local function name_of(g) return names[g] end
t, glyph = Launcher.gesturePhrase("tap_top_right_corner", name_of, id, T)
eq(t, "Tap: Top right", "a tap in a corner is named with KOReader's own words")
eq(glyph, "ges_tap", "with the tap picture")
eq((Launcher.gesturePhrase("hold_bottom_left_corner", name_of, id, T)), "Hold: Bottom left", "a hold")
eq((Launcher.gesturePhrase("one_finger_swipe_left_edge_up", name_of, id, T)), "Swipe: Left edge up", "an edge swipe")
eq((Launcher.gesturePhrase("two_finger_swipe_east", name_of, id, T)), "Two-finger swipe \u{21D2}", "a two-finger swipe, with KOReader's arrow")
eq((Launcher.gesturePhrase("pinch_gesture", name_of, id, T)), "Pinch", "any other gesture, by its name")
eq(Launcher.gesturePhrase("tap_top_left_corner", name_of, id, T), nil, "no name, no phrase")
for ges, g in pairs(Welcome.GESTURES) do
    ok(lfs.attributes("ink/icons/" .. g.glyph .. ".svg") ~= nil, ges .. ": its picture exists")
end

------------------------------------------------------------------------------
-- the tiles and the sheet
------------------------------------------------------------------------------
local ran = {}
local plugin = { ui = { gestures = {
    data = { gesture_reader = { one_finger_swipe_right_edge_down = { inkaway_annotate = true },
                                tap_top_right_corner = { inkaway_booknotes = true } },
             gesture_fm = {} },
    gestureTitleFunc = function(_, ges)
        return ({ tap_top_right_corner = "Top right   (Ink Away: book notes)" })[ges] or ges
    end } },
    book = {},
    onInkAwayAnnotate = function() ran.annotate = true end,
    onInkAwayBookNotes = function() ran.notes = true end,
    onInkAwayCapture = function() ran.capture = true end,
    openCanvas = function(_, lib) ran[lib and "library" or "canvas"] = true end,
}
local tiles = Launcher.tiles(plugin, id, T)
local by = {}
for _i, tile in ipairs(tiles) do by[tile.title] = tile end
eq(#tiles, 5, "in a book: annotate, notes, copy, open, library")
eq(by["Annotate the book"].note, "Swipe down along the right edge", "annotate says the gesture the reader has")
eq(by["Annotate the book"].glyph, "ges_edge_down", "and shows its picture")
eq(by["Book notes"].note, "Tap: Top right", "notes say the gesture the reader set, named by KOReader")
eq(by["Copy part of the screen"].note, "Copy part of the page as a picture", "with no gesture a tile says what it does")
eq(by["Copy part of the screen"].glyph, nil, "and has no picture")
for _i, tile in ipairs(tiles) do tile.run() end
ok(ran.annotate and ran.notes and ran.capture and ran.canvas and ran.library, "each tile does its thing")

plugin.book = nil
tiles = Launcher.tiles(plugin, id, T)
eq(#tiles, 2, "outside a book: Ink Away and its library")
eq(tiles[1].title, "Open Ink Away", "the first is opening Ink Away")

-- the sheet
plugin.book = {}
local host = Launcher.show(plugin)
ok(host and host[ "_launcher" ] ~= nil, "the sheet opens")
local sheet = host["_launcher"]
for _i, label in ipairs({ "Ink Away", "Close", "Annotate the book", "Book notes", "Open Ink Away", "Library" }) do
    ok(has(sheet, label), "the sheet shows " .. label)
end
ok(has(sheet, "Swipe down along the right edge"), "and the gesture on the tile")
host:closeSheet("_launcher")
plugin.book = nil
host = Launcher.show(plugin)
ok(host["_launcher"] ~= nil and not has(host["_launcher"], "Annotate the book") and has(host["_launcher"], "Library"),
    "outside a book there is no annotate tile")
host:closeSheet("_launcher")

print(string.format("launcher: %d checks, %d failures", checks, fails))
TestEnv.cleanup()
os.exit(fails == 0 and 0 or 1)
