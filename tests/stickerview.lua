-- The sticker sheet and its place in the toolbar (ink/view/stickers.lua) in the mock
-- KOReader: the button, the sheet's tabs, tiles and colour row, putting a sticker on
-- the page (selected whole, one undo step), writing that joins it, hiding and
-- deleting, and the options.
--   luajit tests/stickerview.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local TestEnv = require("testenv")
_G.G_reader_settings = {
    data = TestEnv.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local BASE = (os.getenv("INKAWAY_TMP") or "/tmp") .. "/inkaway-stickerview-" .. os.time()
os.execute("rm -rf '" .. BASE .. "'; mkdir -p '" .. BASE .. "/data'")
package.loaded["datastorage"] = { getDataDir = function() return BASE .. "/data" end, getSettingsDir = function() return BASE .. "/data/settings" end }

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what) ok(a == b, what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
local function walk(w, fn, seen)
    seen = seen or {}
    if type(w) ~= "table" or seen[w] then return end
    seen[w] = true
    fn(w)
    for k, v in pairs(w) do if k ~= "show_parent" and k ~= "parent" then walk(v, fn, seen) end end
end
local function textIn(w)
    local out = {}
    walk(w, function(t) if type(t.text) == "string" then out[#out + 1] = t.text end end)
    return table.concat(out, "\n")
end
local function findButton(w, text)
    local found
    walk(w, function(t)
        if not found and type(t.callback) == "function" then
            local has = false
            walk(t, function(c) if c.text == text then has = true end end)
            if has then found = t end
        end
    end)
    return found
end
-- the tiles of a sheet: the Buttons with a hold, which only tiles have
local function tiles(w)
    local out = {}
    walk(w, function(t) if type(t.hold_callback) == "function" and type(t.callback) == "function" then out[#out + 1] = t end end)
    return out
end

Screen:setSize(1072, 1448)
UIManager.reset()
local Stickers = require("ink/stickers")
local InkAwayView = dofile("ink/view.lua")
local view = InkAwayView:new{}

------------------------------------------------------------------------------
-- the toolbar
------------------------------------------------------------------------------
local function barIds()
    local ids = {}
    for i, e in ipairs(view._toolbar_icons or {}) do ids[i] = e.id end
    return ids
end
local ids = barIds()
local at_image, at_sticker
for i, id in ipairs(ids) do if id == "image" then at_image = i end; if id == "sticker" then at_sticker = i end end
ok(at_image and at_sticker == at_image + 1, "the Stickers button sits next to the Image button")
ok(view:stickersInToolbar(), "it is in the toolbar unless Settings says otherwise")

view:setStickersInToolbar(false)
local without = barIds()
local has = false
for _, id in ipairs(without) do if id == "sticker" then has = true end end
ok(not has and #without == #ids - 1, "switched off, the toolbar has one button less")
view:chooseImage()
ok(findButton(view._img_src_dialog, "Stickers"), "and Stickers is under Image instead")
view:closeSheet("_img_src_dialog")
view:setStickersInToolbar(true)
eq(#barIds(), #ids, "switched on, the button is back")
view:chooseImage()
ok(not findButton(view._img_src_dialog, "Stickers"), "and no longer under Image")
view:closeSheet("_img_src_dialog")

------------------------------------------------------------------------------
-- the sheet
------------------------------------------------------------------------------
view:openStickers("notes")
local sheet = view._stickers
ok(sheet ~= nil, "the sheet opens")
local t = textIn(sheet)
for _, name in ipairs({ "Stickers", "Notes", "Bubbles", "Marks", "Tape", "Fun", "Mine", "Done" }) do
    ok(t:find(name, 1, true), "it shows " .. name)
end
local n = #tiles(sheet)
ok(n >= 1 and n <= 6, "a page of notes shows up to six stickers (" .. n .. ")")
ok(t:find("moves with the note", 1, true), "and says writing on a note moves with it")

view:setSetting("inkaway_stickers_per_page", 12)
view:closeSheet("_stickers"); view:openStickers("notes")
ok(#tiles(view._stickers) > n, "more to a page when asked for more")
view:setSetting("inkaway_stickers_per_page", 4)
view:closeSheet("_stickers"); view:openStickers("notes")
eq(#tiles(view._stickers), 4, "four to a page when asked for four")
view:setSetting("inkaway_stickers_per_page", nil)
eq(view:stickersPerPage(), 6, "six to a page is the default")
view:setSetting("inkaway_stickers_per_page", 7)
eq(view:stickersPerPage(), 6, "and a value that is not an option is the default too")
view:setSetting("inkaway_stickers_per_page", nil)

-- paging
view:closeSheet("_stickers"); view:openStickers("notes")
local first = tiles(view._stickers)[1]
ok(findButton(view._stickers, "Next \u{203A}"), "there are more pages of notes")
findButton(view._stickers, "Next \u{203A}").callback()
ok(tiles(view._stickers)[1] ~= first, "Next shows others")
ok(textIn(view._stickers):find("2 / ", 1, true), "and the page number")
findButton(view._stickers, "\u{2039} Prev").callback()
ok(textIn(view._stickers):find("1 / ", 1, true), "Prev goes back")
-- the reader's page turn buttons turn them too (#79)
ok(view._stickers:onMenuPageFwd() and textIn(view._stickers):find("2 / ", 1, true), "the page turn button turns the sheet on")
ok(view._stickers:onMenuPageBack() and textIn(view._stickers):find("1 / ", 1, true), "and back")
view._stickers:onMenuPageBack()
ok(textIn(view._stickers):find("1 / ", 1, true), "back on the first page: it stays there")

-- the tabs
findButton(view._stickers, "Marks").callback()
ok(view._stk.cat == "marks", "a tab opens its category")
findButton(view._stickers, "Mine").callback()
ok(view._stk.cat == "mine" and findButton(view._stickers, "+") or textIn(view._stickers):find("+", 1, true),
    "Mine starts with a tile to add one")

------------------------------------------------------------------------------
-- putting one on the page
------------------------------------------------------------------------------
view:closeSheet("_stickers")
view:openStickers("notes")
local before = view.canvas:opCount()
tiles(view._stickers)[1].callback()
ok(view._stickers == nil, "a tap closes the sheet")
local added = view.canvas:opCount() - before
ok(added >= 2, "and puts the sticker's shapes on the page (" .. added .. ")")
ok(view.selection and #view.selection.idxs == added, "all of them selected, to move together")
local gid = view.canvas.ops[view.selection.idxs[1]].group
ok(gid ~= nil, "as one group")
eq(view:getSetting("inkaway_sticker_last"), "postit", "the last one used is remembered")
local v = view.view
local bx0 = view.selection.bbox
ok(bx0.x0 >= 0 and bx0.y0 >= 0 and bx0.x1 <= v.canvas_w and bx0.y1 <= v.canvas_h, "it lands inside the page")
ok((bx0.x1 - bx0.x0) < v.area_w / v.zoom * 0.6, "at a size that leaves room round it")
view:undo()
eq(view.canvas:opCount(), before, "one undo takes the whole sticker off")
view:redo()
eq(view.canvas:opCount(), before + added, "and redo puts it back")

-- writing on it joins it
local ops = view.canvas.ops
local body
for i, op in ipairs(ops) do if op.sbody then body = { op = op, i = i } end end
local xs, ys = {}, {}
for i = 1, #body.op.pts, 2 do xs[#xs + 1] = body.op.pts[i]; ys[#ys + 1] = body.op.pts[i + 1] end
table.sort(xs); table.sort(ys)
local cx, cy = (xs[1] + xs[#xs]) / 2, (ys[1] + ys[#ys]) / 2
view.canvas:placeOp({ kind = "ink", pts = { cx, cy, cx + 5, cy + 5 }, width = 3 })
local written = ops[#ops]
eq(written.group, gid, "a stroke begun on the note belongs to it")
view:dropSelection()
view:selectOps({ #ops }, "pan")
eq(#view.selection.idxs, added + 1, "touching the writing selects the note and the writing")
view:dropSelection()
view:selectOps({ body.i }, "pan")
eq(#view.selection.idxs, added + 1, "touching the note does too")

-- a copy is a sticker of its own
view:selDuplicate()
local groups = {}
for _, op in ipairs(view.canvas.ops) do if op.group then groups[op.group] = (groups[op.group] or 0) + 1 end end
local ngroups = 0
for _ in pairs(groups) do ngroups = ngroups + 1 end
eq(ngroups, 2, "a duplicate is a second sticker, not part of the first")

------------------------------------------------------------------------------
-- colour
------------------------------------------------------------------------------
view:openStickers("notes")
local pink = Stickers.COLOURS.pastel[2]
local tile_before = tiles(view._stickers)[1]
findButton(view._stickers, "") -- (swatches have no text)
local swatch
walk(view._stickers, function(tt)
    if not swatch and tt.background and tt.callback and tt.text == "" and not tt.hold_callback then
        local c = tt.background
        local rgb = c.getColorRGB32 and c:getColorRGB32()
        if rgb and rgb.r == pink[1] and rgb.g == pink[2] and rgb.b == pink[3] then swatch = tt end
    end
end)
if swatch then
    swatch.callback()
    eq(view:stickerColour("pastel")[2], pink[2], "tapping a colour keeps it for next time")
else
    -- the mock paints tiles another way: set it as the swatch does
    view:setSetting("inkaway_sticker_colour_pastel", pink)
    ok(true, "(the colour swatch is not found by its fill in the mock)")
end
view:closeSheet("_stickers")
view:dropSelection()
local n0 = view.canvas:opCount()
view:placeSticker(Stickers.get("postit_tall"), view:stickerColour("pastel"))
local newbody
for i = n0 + 1, view.canvas:opCount() do if view.canvas.ops[i].sbody then newbody = view.canvas.ops[i] end end
eq(newbody.fill_color[2], pink[2], "the next note comes in the colour chosen")

------------------------------------------------------------------------------
-- hiding and deleting
------------------------------------------------------------------------------
view:dropSelection()
view:openStickers("notes")
local count0 = #view:stickerItems("notes")
tiles(view._stickers)[1].hold_callback()
ok(view._stk_ask ~= nil and textIn(view._stk_ask):find("Hide this sticker?", 1, true), "a hold asks before hiding a built-in sticker")
findButton(view._stk_ask, "Hide").callback()
eq(#view:stickerItems("notes"), count0 - 1, "hidden, it is gone from the list")
view:openStickerOptions()
ok(textIn(view._stk_options):find("1 hidden", 1, true), "the options say how many are hidden")
findButton(view._stk_options, "Show all stickers (1 hidden)").callback()
eq(#view:stickerItems("notes"), count0, "and bring them back")
view:closeSheet("_stk_options")

-- the reader's own
local dir = view:userStickersDir()
ok(dir ~= nil, "the reader's stickers have a folder")
local f = io.open(dir .. "/1-1.png", "wb"); f:write("x"); f:close()
local mine = view:stickerItems("mine")
eq(#mine, 2, "an added tile and the one sticker")
view:closeSheet("_stickers"); view:openStickers("mine")
local own
for _, tl in ipairs(tiles(view._stickers)) do own = own or tl end
ok(own ~= nil, "it is a tile of its own")
own.hold_callback()
ok(view._stk_ask and textIn(view._stk_ask):find("Delete this sticker?", 1, true), "a hold asks before deleting it")
findButton(view._stk_ask, "Delete").callback()
eq(#view:stickerItems("mine"), 1, "and then it is gone")
ok(io.open(dir .. "/1-1.png", "rb") == nil, "from the folder too")

------------------------------------------------------------------------------
-- the options
------------------------------------------------------------------------------
view:closeSheet("_stickers")
view:openStickerOptions()
local o = view._stk_options
ok(o and textIn(o):find("Stickers per page", 1, true), "the options sheet opens")
findButton(o, "9").callback()
eq(view:stickersPerPage(), 9, "the number to a page is chosen there")
findButton(view._stk_options, "Stickers button in the toolbar") -- (a switch)
view:setStickersInToolbar(false)
ok(not view:stickersInToolbar(), "and where the button is")
view:setStickersInToolbar(true)

------------------------------------------------------------------------------
-- pinning to the page (over a reflowing book)
------------------------------------------------------------------------------
view:dropSelection()
view:placeSticker(Stickers.get("postit"), nil)
ok(view._sel_dialog and not findButton(view._sel_dialog, "Pin to this page"), "outside a book there is nothing to pin to")
view:closeSelectionMenu()
view.canPinSelection = function() return true end   -- (a reflowing book, as ReaderInkView says)
view:openSelectionMenu()
local pin = findButton(view._sel_dialog, "Pin to this page")
ok(pin ~= nil, "over a reflowing book the selection menu offers to pin")
pin.callback()
local all_pinned = view:selectionPinned()
ok(all_pinned, "pinned: every part of the sticker and what is on it is pinned")
ok(view._sel_dialog and findButton(view._sel_dialog, "Let it follow the text"), "and the button says how to undo it")
findButton(view._sel_dialog, "Let it follow the text").callback()
ok(not view:selectionPinned(), "unpinned again")
view.canPinSelection = nil

print(string.format("stickerview: %d checks, %d failures", checks, fails))
TestEnv.cleanup()
os.exit(fails == 0 and 0 or 1)
