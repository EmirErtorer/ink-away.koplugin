-- The export filename prompt with KOReader's actual InputText tap and
-- FocusManager code. Rendering, keyboard display and event delivery are adapters.
-- From a KOReader runtime: ./luajit REPO/tests/realbb/promptfocus.lua REPO
local REPO = assert(arg[1])
require("ffi/loadlib")
require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;frontend/?.lua;" .. package.path
local env = require("testenv")
local settings = env.settings()
_G.G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
    nilOrFalse = function(_, k) return not settings[k] end,
}
local Device = require("device")
Device.hasDPad = function() return true end
Device.hasFewKeys = function() return true end
Device.hasKeys = function() return true end
Device.hasKeyboard = function() return true end
Device.hasScreenKB = function() return false end
Device.hasClipboard = function() return false end
local started = 0
Device.startTextInput = function() started = started + 1 end
package.loaded["ui/bidi"] = { mirroredUILayout = function() return false end }
local IC = require("ui/widget/container/inputcontainer")
IC._init = function() end
function IC:handleEvent(event)
    local method = self["on" .. event.name]
    if method then return method(self, unpack(event.args)) end
    return false
end
-- These dependencies are not used by the tap path under test.
for _, name in ipairs({ "ui/widget/checkbutton", "ui/widget/scrolltextwidget", "ui/widget/notification",
        "ui/widget/virtualkeyboard", "dbg" }) do package.loaded[name] = {} end
package.loaded["dbg"] = { guard = function() end }
local FocusManager = assert(loadfile("frontend/ui/widget/focusmanager.lua"))()
package.loaded["ui/widget/focusmanager"] = FocusManager
local InputText = assert(loadfile("frontend/ui/widget/inputtext.lua"))()
local last
local HeadlessInput = InputText:extend{
    init = function(self)
        self.charlist = { self.text }
        self._frame_textwidget = {}
        self:initEventListener()
        last = self
    end,
    getSize = function(self) return { w = self.width, h = 40 } end,
    paintTo = function() end,
    focus = function(self) self.focused = true end,
    unfocus = function(self) self.focused = false end,
    onShowKeyboard = function(self) self.keyboard_shown = true end,
    onCloseKeyboard = function(self) self.keyboard_shown = false end,
    onCloseWidget = function(self) self.closed = true end,
}
package.loaded["ui/widget/inputtext"] = HeadlessInput
local view = dofile(REPO .. "/ink/view.lua"):new{}
local checks, failures = 0, 0
local function ok(c, what)
    checks = checks + 1
    if not c then failures = failures + 1; print("FAIL: " .. what) end
end
local output
view.confirmReplace = function(_, path, done) output = path; done() end
local written = false
view:askExportPath{ title = "Export as PDF", name = "Comic", default = "Comic",
    dir = env.libraryDir(), ext = "pdf", on_path = function() written = true end }
local sheet, input = view._prompt, last
local success, err = pcall(input.onTapTextBox, input, nil, { pos = { x = 10, y = 10 } })
ok(success, "tapping the export filename on a DPad/desktop device does not crash: " .. tostring(err))
if success then
    local x, y = sheet:getFocusableWidgetXY(input)
    ok(x == 1 and y == 1 and input.focused and started == 1, "prompt owns and focuses its input with the host focus manager")
    ok(sheet.key_events.CloseMenu ~= nil, "prompt retains Back dismissal")
    input.enter_callback()
    ok(written and output == env.libraryDir() .. "/Comic.pdf", "Enter reaches the export callback with the filename")
    ok(view._prompt == nil and input.closed, "submitting closes the prompt and its keyboard")
end
view:promptText{ title = "Range", input = "1-3", ok_text = "Set", on_ok = function() end }
sheet, input = view._prompt, last
success, err = pcall(input.onTapTextBox, input, nil, { pos = { x = 10, y = 10 } })
ok(success, "other text prompts share safe focus handling: " .. tostring(err))
sheet.cancel_callback()
ok(view._prompt == nil and input.closed, "Cancel closes a focused prompt")
view:onCloseWidget()
env.cleanup()
print(("promptfocus: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
