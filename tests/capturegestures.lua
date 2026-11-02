-- Capture's dispatcher action and one-time shortcut migration, preserving
-- custom gestures, deliberately removed bindings and the existing setup record.
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local settings = {}
_G.G_reader_settings = {
    readSetting = function(_self, k) return settings[k] end,
    saveSetting = function(_self, k, v) settings[k] = v end,
}
local actions, opened = {}, {}
package.loaded["dispatcher"] = {
    registerAction = function(_self, id, spec) actions[id] = spec end,
    menuTextFunc = function() return "Existing action" end,
}
package.loaded["ink/reader/capture"] = { open = function(book) opened[#opened + 1] = book end }
local Plugin = dofile("main.lua")
local Entry = require("ink/reader/entrygestures")
local checks = 0
-- Fail at the first meaningful regression.
local function ok(c, why) checks = checks + 1; assert(c, why) end
-- A minimal reader plugin with a gesture manager that records saves.
local function host(data)
    local g = data and { data = data, saves = 0,
        onFlushSettings = function(self) self.saves = self.saves + 1 end } or nil
    return setmetatable({ ui = { gestures = g, document = { file = "book.epub" } } }, { __index = Plugin })
end
local p = host({ gesture_reader = {} })
p:onDispatcherRegisterActions()
local action = actions.inkaway_capture
ok(action and action.reader and action.event == "InkAwayCapture", "capture is registered as a reader gesture action")
ok(p["on" .. action.event](p) and #opened == 0, "outside a book the action is harmless")
p.book = {}
p["on" .. action.event](p)
ok(opened[1] == p.book, "the dispatcher event opens the quiet capture mode for this book")
local menu = {}
p:addToMainMenu(menu)
menu.inkaway.sub_item_table[2].callback()
ok(opened[2] == p.book, "the menu shares the same capture handler")
local SE, SW = "two_finger_swipe_southeast", "two_finger_swipe_southwest"
settings = {}
p:setupEntryGestures()
ok(p.ui.gestures.data.gesture_reader[SE].inkaway_capture, "fresh setup assigns the free two-finger southeast swipe")
ok(not p.ui.gestures.data.gesture_fm[SE], "capture is never bound in the file browser")
ok(settings.inkaway_gestures_setup == 3, "setup records the new version")
local prior = { placed = { annotate = { gesture_reader = SW } },
    held = { { feature = "annotate", what = "Existing binding" } } }
settings = { inkaway_gestures_setup = 2, inkaway_entry_gestures = prior }
local custom = { inkaway_annotate = true }
p = host({ gesture_reader = { [SW] = custom } })
p:setupEntryGestures()
local data = p.ui.gestures.data
ok(data.gesture_reader[SW] == custom and data.gesture_reader[SE].inkaway_capture,
    "upgrading preserves annotation and assigns a separate capture gesture")
ok(not data.gesture_reader.one_finger_swipe_right_edge_down and not data.gesture_reader.one_finger_swipe_right_edge_up,
    "upgrading does not restore deliberately removed old bindings")
local record = settings.inkaway_entry_gestures
ok(record.placed.annotate == prior.placed.annotate and record.held[1] == prior.held[1],
    "upgrading retains the original feature records")
ok(record.placed.capture.gesture_reader == SE and p.ui.gestures.saves == 1, "the new binding is saved once")
p:setupEntryGestures()
ok(p.ui.gestures.saves == 1, "subsequent setup calls do not rewrite bindings")
settings = { inkaway_gestures_setup = 2, inkaway_entry_gestures = prior }
local busy = { screenshot = true }
p = host({ gesture_reader = { [SE] = busy } })
p:setupEntryGestures()
ok(p.ui.gestures.data.gesture_reader[SE] == busy and p.ui.gestures.saves == 0,
    "an occupied shortcut is never overwritten")
ok(settings.inkaway_entry_gestures.held[2].feature == "capture", "an occupied shortcut is recorded for manual setup")
settings = { inkaway_gestures_setup = 2, inkaway_entry_gestures = prior }
p = host(nil)
p:setupEntryGestures()
ok(settings.inkaway_gestures_setup == 2 and settings.inkaway_entry_gestures == prior,
    "a disabled gesture manager leaves existing settings intact and allows a retry")
p.ui.gestures = { data = {} }
p:setupEntryGestures()
ok(p.ui.gestures.data.gesture_reader[SE].inkaway_capture, "setup retries when the gesture manager becomes available")
local only = {}
local placed, _, n = Entry.apply(only, { Entry.CAPTURE })
ok(n == 1 and placed.capture and not placed.annotate and not placed.booknotes,
    "the capture-only migration cannot modify the other features")
print("capture gestures: " .. checks .. " checks passed")
