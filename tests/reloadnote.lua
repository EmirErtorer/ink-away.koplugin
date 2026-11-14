-- The note shown while a book is loaded again for rooms ("Preparing this book for
-- rooms") closes when the book is up, whether KOReader calls back or not: the Kobo
-- plugin wraps ReaderUI.showReader with fewer arguments and drops the callback, which
-- left the note over the book for ever. The new reader's own "ready" event (and, as a
-- last resort, a timer) closes it; what is to follow runs once.
--   luajit tests/reloadnote.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local UIManager = require("ui/uimanager")
local Book = require("ink/reader/book")
UIManager.forceRePaint = UIManager.forceRePaint or function() end
-- a tick runs at once; a timer waits for the test to fire it (its delay says which)
local timers = {}
UIManager.nextTick = function(_, fn) fn() end
UIManager.scheduleIn = function(_, sec, fn) timers[#timers + 1] = { sec = sec, fn = fn } end
UIManager.unschedule = function(_, fn)
    for i = #timers, 1, -1 do if timers[i].fn == fn then table.remove(timers, i) end end
end
local function fireShort()   -- the timers of a second or less, as the event loop would soon
    local due = {}
    for i = #timers, 1, -1 do if timers[i].sec <= 1 then due[#due + 1] = table.remove(timers, i) end end
    for _, t in ipairs(due) do t.fn() end
end
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local function notes()
    local n = 0
    for _, e in ipairs(UIManager._window_stack) do
        if type(e.widget.text) == "string" and e.widget.text:find("Preparing", 1, true) then n = n + 1 end
    end
    return n
end
-- a book whose reader loads it again, calling back (or not) as KOReader's reloadDocument does
local function make(calls_back)
    local ui = { paging = false, document = { invalidateCacheFile = function() end } }
    ui.reloadDocument = function(_self, _close, _seamless, after_open)
        ui.reloaded = true
        if calls_back then ui.new_ui = {}; Book.by_ui[ui.new_ui] = { name = "new book" }; after_open(ui.new_ui) end
    end
    return setmetatable({ ui = ui }, Book), ui
end

-- KOReader calls back: the note closes, and what follows runs once
do
    UIManager.reset(); timers = {}; Book.pending_reload = nil
    local b, ui = make(true)
    local ran = {}
    b:reloadForRooms(function(nb) ran[#ran + 1] = nb end)
    fireShort()
    ok(ui.reloaded and notes() == 0, "KOReader's callback closes the note")
    fireShort()
    ok(#ran == 1 and ran[1].name == "new book", "and what follows runs once, on the new book")
    Book.finishReload(ui.new_ui)
    fireShort()
    ok(#ran == 1, "a second finish does nothing")
end

-- the callback is dropped: the new reader's ready event does it
do
    UIManager.reset(); timers = {}; Book.pending_reload = nil
    local b, ui = make(false)
    local ran = {}
    b:reloadForRooms(function(nb) ran[#ran + 1] = nb end)
    fireShort()
    ok(ui.reloaded and notes() == 1, "without the callback the note is still there")
    local new_ui = {}
    Book.by_ui[new_ui] = { name = "new book" }
    Book.finishReload(new_ui)
    ok(notes() == 0, "the ready event closes the note")
    fireShort()
    ok(#ran == 1 and ran[1].name == "new book", "and what follows runs once, on the new book")
    ok(not Book.pending_reload, "nothing is left pending")
end

-- nothing reports: the timer closes the note
do
    UIManager.reset(); timers = {}; Book.pending_reload = nil
    local b = make(false)
    local ran = 0
    b:reloadForRooms(function() ran = ran + 1 end)
    fireShort()
    local pending = Book.pending_reload
    ok(pending and notes() == 1, "waiting")
    pending.watchdog()
    ok(notes() == 0 and not Book.pending_reload, "the timer closes the note")
    fireShort()
    ok(ran == 0, "and runs nothing for a book it never saw")
end

-- a ready event with nothing pending does nothing
do
    UIManager.reset(); timers = {}; Book.pending_reload = nil
    Book.finishReload({})
    ok(notes() == 0, "a ready event with nothing pending does nothing")
end

print(("reloadnote: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
