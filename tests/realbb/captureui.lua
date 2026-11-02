-- The real KOReader window stack and widgets: confirmation must stay above the
-- modal capture, and pen drift/lift must not close either one. No mock widgets.
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
ffi.C.setenv("EMULATE_READER_W", "1860", 1)
ffi.C.setenv("EMULATE_READER_H", "2480", 1)
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(tmp .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", "it_IT")
G_reader_settings:saveSetting("screen_dpi", 300)
require("gettext").changeLang("it_IT")
local Device = require("device")
require("document/canvascontext"):init(Device)
require("ui/bidi").setup("it_IT")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. package.path
local Capture = require("ink/reader/capture")
local Clipboard = require("ink/clipboard")
local notices = 0
package.loaded["ink/view"] = { tellAnywhere = function() notices = notices + 1 end }
local book = {}
-- A clean book snapshot; all widgets, input dispatch and rendering stay real.
function book:snapshot(bb)
    bb:fill(BB.COLOR_WHITE)
    return true
end
-- Send gestures through the real input container and UIManager stack.
local function gesture(name, x, y)
    UIManager:sendEvent(Event:new("Gesture", { ges = name, pos = Geom:new{ x = x, y = y } }))
end
-- Tap real painted buttons, so a hidden dialog cannot pass via direct callbacks.
local function tapButton(dialog, row, column)
    local r = assert(dialog.layout[row][column].dimen)
    gesture("tap", r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2))
end
Capture.open(book)
local c = assert(book._capture)
assert(#UIManager._window_stack == 1 and UIManager._window_stack[1].widget == c,
    "activation enters capture directly without a modal instruction message")
UIManager:_repaint()
local activation_preview = os.getenv("INKAWAY_CAPTURE_ACTIVE_OUT")
if activation_preview then assert(Device.screen.bb:writePNG(activation_preview)) end
gesture("tap", 100, 100)
gesture("pan", 102, 102)
gesture("pan_release", 102, 102)
assert(c.page and c.corner, "pen drift after the first corner keeps the capture open")
gesture("tap", 400, 400)
local dialog = assert(c._confirmation)
assert(UIManager._window_stack[#UIManager._window_stack].widget == dialog,
    "confirmation must be above the modal capture, not hidden underneath")
UIManager:_repaint()
assert(dialog.dimen and dialog.dimen.w > 0 and dialog.dimen.h > 0, "the real dialog is visible")
local preview = os.getenv("INKAWAY_CAPTURE_UI_OUT")
if preview then assert(Device.screen.bb:writePNG(preview)) end
for _, name in ipairs({ "pan", "pan_release", "swipe", "hold" }) do
    gesture(name, 200, 200)
    assert(c.page and c._confirmation == dialog, "late pen events must not close confirmation")
end
tapButton(dialog, 1, 2)
assert(c.page and not c.selection and not c._confirmation, "Select again returns to corner selection")
assert(UIManager._window_stack[#UIManager._window_stack].widget == c)
gesture("touch", 200, 300)
gesture("pan", 500, 600)
assert(c.drag_box and not c.selection and not c._confirmation, "drag shows a live rectangle before lift")
UIManager:_repaint()
gesture("pan_release", 500, 600)
assert(c._confirmation and c.selection.w == 300 and c.selection.h == 300,
    "lifting the pen after dragging opens confirmation")
UIManager:_repaint()
tapButton(c._confirmation, 1, 1)
assert(not c.page and not book._capture and Clipboard.count() == 1 and notices == 1)
assert(#UIManager._window_stack == 0, "copy closes both real widgets")
local op = Clipboard.take()[1]
assert(op.w == 300 and op.h == 300)
c = Capture:new{ book = book }; book._capture = c
UIManager:show(c)
gesture("tap", 100, 100)
gesture("tap", 400, 400)
UIManager:_repaint()
tapButton(c._confirmation, 2, 1)
assert(not c.page and #UIManager._window_stack == 0, "Cancel closes both real widgets")
assert(Clipboard.take()[1].path == op.path, "Cancel preserves the clipboard")
c = Capture:new{ book = book }; book._capture = c
UIManager:show(c)
gesture("touch", 100, 100)
gesture("hold", 100, 100)
gesture("hold_pan", 500, 600)
assert(c.page and c.drag_box and not c._confirmation, "a paused pen can still start dragging")
gesture("hold_pan_release", 500, 600)
assert(c.selection and c.selection.w == 400 and c.selection.h == 500,
    "a drag after holding confirms at the original press point")
UIManager:_repaint()
tapButton(c._confirmation, 2, 1)
Clipboard.clear()
os.execute("rm -rf '" .. tmp:gsub("'", "'\\''") .. "'")
print("native capture UI: real modal stacking, rendering, pen events, reselect, copy and cancel passed")
