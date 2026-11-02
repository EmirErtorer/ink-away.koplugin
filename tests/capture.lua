-- Region capture: selection direction, bounds, clipboard lifetime and failures.
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local Clipboard = require("ink/clipboard")
local Storage = require("ink/storage")
local Capture = require("ink/reader/capture")
local TestEnv = require("testenv")
local dir = TestEnv.libraryDir()
local notices = {}
-- The decision sheet is Ink Away's own (see ink/view/sheetkit.lua); here a stand-in
-- with the same calls, whose sheet is a modal widget kept in the field it is shown in.
local View = { tellAnywhere = function(s) notices[#notices + 1] = s end }
function View:sheetWidth() return 400, 10 end
function View:sheetTitle(title, _w, pill, cb) return { text = title, pill = pill, callback = cb } end
function View:actionButton(label, _w, cb) return { text = label, callback = cb } end
function View:showSheet(field, build, opts)
    build()
    local sheet = { modal = true, bottom_y = opts.bottom_y }
    sheet.on_close = function() self[field] = nil; if opts.on_close then opts.on_close() end end
    self[field] = sheet
    UIManager:show(sheet)
end
function View:closeSheet(field)
    if self[field] then UIManager:close(self[field]); self[field] = nil end
end
package.loaded["ink/view"] = View
local appDir = Storage.appDir
Storage.appDir = function() return dir end
local sample = BB.new(1, 1)
local proto = getmetatable(sample)
sample:free()
local writePNG = proto.writePNG
local saved, fail
local fakePNG = "\137PNG\r\n\26\n" .. string.rep("\0", 32) .. "\0\0\0\0IEND\174\66\96\130"
-- Model both PNG failure conventions without overwriting a real picture.
function proto:writePNG(path)
    if fail == "throw" then error("write failed") end
    if fail and fail ~= "no_return" and fail ~= "partial" then return false, "disk full" end
    saved = { path = path, w = self.w, h = self.h }
    local f = assert(io.open(path, "wb"))
    f:write(fail == "partial" and fakePNG:sub(1, 20) or fakePNG)
    f:close()
    if fail == "no_return" or fail == "partial" then return end
    return true
end
local checks = 0
-- Count each regression assertion, failing at its first useful description.
local function ok(value, message)
    checks = checks + 1
    assert(value, message)
end
-- A snapshot must be independent of menus and include the book's ink.
local function book()
    return { snapshot = function(_, bb, ink)
        assert(ink); bb:fill(BB.COLOR_WHITE)
    end }
end
package.loaded["dispatcher"] = {}
local Plugin = dofile("main.lua")
local menus = {}
local plugin = setmetatable({ book = book(), ui = { document = { file = "book.epub" } } }, { __index = Plugin })
plugin:addToMainMenu(menus)
local entries = menus.inkaway.sub_item_table
ok(entries[1].text == "Annotate the book" and entries[2].text == "Copy part of the screen",
    "capture appears beside annotation in the book menu")
entries[2].callback()
ok(UIManager.shown.page and not UIManager.shown.ok_callback, "the menu activates capture without an instruction dialog")
UIManager.shown:onCancel()
-- Send the same two taps that KOReader dispatches to the selection overlay.
local function tap(c, x, y) c:onCorner(nil, { pos = { x = x, y = y } }) end
-- Confirm through the visible Copy button, as the reader does.
local function confirm(c) c._confirmation.copy() end
for _, wh in ipairs({ {600, 800}, {800, 600} }) do
    Screen:setSize(wh[1], wh[2])
    for _, reverse in ipairs({ false, true }) do
        UIManager.reset()
        local before = BB.allocated
        local b = book()
        Capture.open(b)
        local c = b._capture
        ok(c and c.page and UIManager.shown == c, "activation opens selection directly")
        local windows = UIManager.stackCount()
        Capture.open(b)
        ok(UIManager.stackCount() == windows and b._capture == c, "activating again does not create duplicate views")
        local saved_before, clipboard_before = saved, Clipboard.count()
        if reverse then tap(c, 320, 240); tap(c, 20, 40)
        else tap(c, 20, 40); tap(c, 320, 240) end
        ok(c.selection and c._confirmation and c.page, "two corners open a decision without closing capture")
        ok(c._confirmation._capture_sheet and c._confirmation._capture_sheet.modal, "confirmation must stack above the modal capture in KOReader")
        ok(c._confirmation._capture_sheet.bottom_y ~= nil, "a rectangle in the upper half puts the sheet at the bottom")
        c:onDrag(nil, { pos = { x = 500, y = 500 } })
        c:onDragEnd(nil, { pos = { x = 500, y = 500 } })
        ok(c.page and c._confirmation, "late movement/release/swipe events do not close a completed selection")
        ok(saved == saved_before and Clipboard.count() == clipboard_before, "selection does not save or replace the clipboard")
        c:paintTo(Screen.bb, 0, 0)
        confirm(c)
        local op = Clipboard.take()[1]
        ok(saved.w == 300 and saved.h == 200 and op.w == 300 and op.h == 200,
            "either direction produces the selected dimensions")
        ok(op.path == saved.path and Storage.exists(op.path), "clipboard refers to a permanent image")
        ok(not c.page and not b._capture and BB.allocated == before, "capture releases its buffers")
        local copy = Clipboard.take(400, 300)[1]
        ok(copy.x == 250 and copy.y == 200 and copy.path == op.path, "paste centres a fresh image copy")
        copy.w = 1
        ok(Clipboard.take()[1].w == 300, "pasting does not mutate the clipboard")
    end
end
for _, reverse in ipairs({ false, true }) do
    local c = Capture:new{ book = book() }
    local a = reverse and { x = 350, y = 400 } or { x = 50, y = 100 }
    local z = reverse and { x = 50, y = 100 } or { x = 350, y = 400 }
    local before = saved
    c:onDragStart(nil, { pos = a })
    c:onDrag(nil, { pos = z })
    ok(c.drag_box and not c.selection and not c._confirmation, "dragging previews a rectangle without confirming")
    ok(saved == before, "dragging does not save an image")
    c:paintTo(Screen.bb, 0, 0)
    c:onDragEnd(nil, { pos = z })
    ok(c.selection and c.selection.w == 300 and c.selection.h == 300 and c._confirmation,
        "lifting after a drag in either direction opens the confirmation")
    confirm(c)
    ok(saved.w == 300 and saved.h == 300, "confirming saves the dragged rectangle")
end
local swipe = Capture:new{ book = book() }
swipe:onDragEnd(nil, { pos = { x = 20, y = 30 }, end_pos = { x = 220, y = 330 } })
ok(swipe.selection and swipe.selection.w == 200 and swipe.selection.h == 300,
    "a quick swipe uses end_pos for the opposite corner")
swipe:onCancel()
local drift = Capture:new{ book = book() }
drift:onDragStart(nil, { pos = { x = 100, y = 100 } })
drift:onDragEnd(nil, { pos = { x = 102, y = 102 } })
ok(not drift.selection and not drift._confirmation and drift.page, "tap drift does not create a tiny selection")
drift:onCancel()
local shrink = Capture:new{ book = book() }
shrink:onDragStart(nil, { pos = { x = 200, y = 200 } })
shrink:onDrag(nil, { pos = { x = 500, y = 500 } })
shrink:onDrag(nil, { pos = { x = 220, y = 200 } })
shrink:paintTo(Screen.bb, 0, 0)
local dirty = UIManager.last().region
ok(dirty.x <= 200 and dirty.y <= 200 and dirty.x + dirty.w >= 500 and dirty.y + dirty.h >= 500,
    "shrinking a drag refreshes the previous rectangle too")
shrink:onDragEnd(nil, { pos = { x = -100, y = -100 } })
ok(shrink.selection.x == 0 and shrink.selection.y == 0, "a lift outside the page is clamped")
shrink:selectAgain()
ok(not shrink.drag_box and not shrink.drag_origin, "reselect clears the drag state")
shrink:onCancel()
local previous = Clipboard.take()[1].path
for _, reason in ipairs({ "cancel", "rotate", "close", "return", "throw", "folder" }) do
    local b = book()
    local c = Capture:new{ book = b }; b._capture = c
    UIManager:show(c)
    tap(c, 50, 50); tap(c, 50, 100)
    ok(c.page ~= nil, "a line does not replace the clipboard")
    tap(c, 150, 150)
    local dialog = c._confirmation and c._confirmation._capture_sheet
    if reason == "cancel" then c:onCancel()
    elseif reason == "rotate" then require("ink/reader/book").closeViews(b)
    elseif reason == "close" then c:onCloseDocument()
    else
        fail = reason == "return" and "return" or reason == "throw" and "throw" or nil
        if reason == "folder" then Storage.appDir = function() return nil end end
        confirm(c)
        fail = nil; Storage.appDir = function() return dir end
    end
    ok(not c.page and not b._capture, "cancel/failure clears the capture")
    ok(not c._confirmation, "cancel/failure closes the confirmation dialog")
    for _, window in ipairs(UIManager._window_stack) do
        assert(window.widget ~= dialog, "no orphaned confirmation remains on screen")
    end
    ok(Clipboard.take()[1].path == previous, "cancel/failure preserves the previous clipboard")
    if reason == "return" then ok(notices[#notices]:find("disk full", 1, true), "save errors retain their reason") end
end
for _, mode in ipairs({ "no_return", "partial" }) do
    local c = Capture:new{ book = book() }
    fail = mode
    tap(c, 20, 30); tap(c, 120, 130)
    confirm(c)
    fail = nil
    if mode == "no_return" then
        ok(Clipboard.take()[1].path == saved.path, "a complete PNG is accepted when writePNG returns nothing")
        previous = saved.path
    else
        ok(Clipboard.take()[1].path == previous, "a truncated PNG with no return value preserves the clipboard")
        ok(not Storage.exists(saved.path), "an incomplete PNG is removed")
    end
end
local c = Capture:new{ book = book() }
tap(c, 9999, 9999)
c:paintTo(Screen.bb, 0, 0)
tap(c, -20, -30)
confirm(c)
ok(saved.w == 799 and saved.h == 599, "off-screen taps are clamped")
ok(BB.out_of_bounds == 0, "selection marker and crop stay inside the screen")
local b = book()
local again = Capture:new{ book = b }; b._capture = again
UIManager:show(again)
local before = saved
tap(again, 10, 20); tap(again, 90, 100)
again._confirmation.again()
ok(again.page and not again.corner and not again.selection and not again._confirmation,
    "Select again keeps the clean page and clears both corners")
ok(saved == before, "reselecting writes no file")
tap(again, 30, 40); tap(again, 180, 240)
local dismissed = again._confirmation._capture_sheet
dismissed.on_close() -- a tap outside the sheet
UIManager:close(dismissed)
ok(not again.corner and not again.selection and again.page, "dismissing the decision allows a fresh selection")
tap(again, 30, 40); tap(again, 180, 240)
confirm(again)
ok(saved.w == 150 and saved.h == 200, "only the newly confirmed rectangle is copied")
local low = Capture:new{ book = book() }
tap(low, 40, 450); tap(low, 200, 560)
ok(low._confirmation._capture_sheet.bottom_y == nil, "a rectangle in the lower half leaves the sheet at the top")
low:onCancel()
local cancelled = Capture:new{ book = book() }
before = saved
local previous_path = Clipboard.take()[1].path
tap(cancelled, 10, 20); tap(cancelled, 100, 120)
cancelled._confirmation.cancel()
cancelled:copySelection()
ok(not cancelled.page and saved == before and Clipboard.take()[1].path == previous_path,
    "Cancel keeps the clipboard and a stale Copy callback cannot write")
for _, throws in ipairs({ false, true }) do
    local before = BB.allocated
    local bad = { snapshot = function()
        if throws then error("page unavailable") end
        return false
    end }
    Capture.open(bad)
    ok(not bad._capture and BB.allocated == before, "failed snapshot frees its buffer without opening selection")
end
package.loaded["ink/view"] = nil
_G.G_reader_settings = {
    data = TestEnv.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local view = require("ink/view"):new{}
view:pasteAt({ x = 400, y = 300 })
local image = view.canvas.ops[#view.canvas.ops]
ok(image.kind == "image" and image.path == saved.path, "the actual canvas Paste inserts the captured picture")
view:undo()
ok(#view.canvas.ops == 0 and Clipboard.count() == 1, "undo removes the paste while keeping the clipboard")
view:closeCanvas()
Storage.appDir, proto.writePNG = appDir, writePNG
Clipboard.clear()
TestEnv.cleanup()
print("capture: " .. checks .. " checks passed")
