--[[
Ink Away, a drawing canvas and notebook for e-ink readers. This file only plugs
it into KOReader (the Tools menu entry and the gesture actions) and opens the
view; everything else lives under ink/. In the reader it also brings the open
book's ink (ink/reader/): shown over the pages, and drawn in the annotation mode.
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local InkAway = WidgetContainer:extend{
    name = "inkaway",
    is_doc_only = false,
}

function InkAway:onDispatcherRegisterActions()
    Dispatcher:registerAction("inkaway_open", {
        category = "none",
        event = "InkAwayOpen",
        title = _("Open Ink Away"),
        general = true,
    })
    Dispatcher:registerAction("inkaway_library", {
        category = "none",
        event = "InkAwayLibrary",
        title = _("Ink Away library"),
        general = true,
    })
    -- in a book: draw on it; book notes, or Ink Away itself outside a book
    Dispatcher:registerAction("inkaway_annotate", {
        category = "none",
        event = "InkAwayAnnotate",
        title = _("Ink Away: annotate the book"),
        reader = true,
    })
    Dispatcher:registerAction("inkaway_booknotes", {
        category = "none",
        event = "InkAwayBookNotes",
        title = _("Ink Away: book notes (Ink Away outside a book)"),
        general = true,
    })
end

function InkAway:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Ink Away's gesture actions reach it even when another window covers the
    -- file browser (a home screen plugin): KOReader gives such windows' unused
    -- events to the modules listed here, as it does for screenshots
    if type(self.ui.active_widgets) == "table" then table.insert(self.ui.active_widgets, self) end
    -- book ink follows its book when KOReader moves, copies or deletes it
    local bok, BookInk = pcall(require, "ink/reader/bookink")
    if bok then BookInk.installFollow() end
    -- in the reader: the book's ink, painted over its pages (a book without ink
    -- costs a file check here and nothing per page)
    if self.ui.document and self.ui.view and self.ui.view.registerViewModule then
        local ok, Book = pcall(require, "ink/reader/book")
        if ok then
            self.book = Book.new(self.ui)
            self.book.plugin = self
            self.ui.view:registerViewModule("inkaway", self.book:overlay())
        end
    end
    -- the book gestures, once, after every plugin (the gesture manager too) is up
    if not G_reader_settings:readSetting("inkaway_gestures_setup") then
        UIManager:nextTick(function() self:setupEntryGestures() end)
    end
    -- emulator hook: INKAWAY_AUTOOPEN opens the canvas straight away, once; the
    -- variable is never set on a device
    if os.getenv("INKAWAY_AUTOOPEN") and not InkAway._autoopened then
        InkAway._autoopened = true
        UIManager:scheduleIn(1.2, function() self:openCanvas() end)
    end
end

function InkAway:addToMainMenu(menu_items)
    if self.book then
        menu_items.inkaway = {
            text = _("Ink Away"),
            sorting_hint = "tools",
            sub_item_table = {
                { text = _("Annotate the book"), keep_menu_open = false,
                  callback = function() self:onInkAwayAnnotate() end },
                { text = _("Book notes"), keep_menu_open = false,
                  callback = function() self:onInkAwayBookNotes() end },
                { text = _("Open Ink Away"), keep_menu_open = false,
                  callback = function() self:openCanvas() end },
            },
        }
        return
    end
    menu_items.inkaway = {
        text = _("Ink Away (drawing canvas)"),
        sorting_hint = "tools",   -- top level of the Tools tab, not buried in "More tools"
        keep_menu_open = false,
        callback = function() self:openCanvas() end,
    }
end

-- Set the book gestures in KOReader's gesture manager, where they are free
-- (see ink/reader/entrygestures.lua). Gestures already in use are kept, and
-- listed in a note for the next time Ink Away opens.
function InkAway:setupEntryGestures()
    if G_reader_settings:readSetting("inkaway_gestures_setup") then return end
    local g = self.ui and self.ui.gestures
    if not (g and type(g.data) == "table") then return end   -- the gesture manager is off
    local EntryGestures = require("ink/reader/entrygestures")
    local set, taken = EntryGestures.apply(g.data)
    if #set > 0 then
        g.updated = true
        pcall(g.onFlushSettings, g)
    end
    G_reader_settings:saveSetting("inkaway_gestures_setup", 1)
    if #taken > 0 then
        local names = {
            one_finger_swipe_right_edge_up = _("Swipe up along the right edge"),
            one_finger_swipe_right_edge_down = _("Swipe down along the right edge"),
        }
        local lines, seen = {}, {}
        for _i, t in ipairs(taken) do
            local key = t.want.ges
            if not seen[key] then
                seen[key] = true
                local what = ""
                pcall(function() what = Dispatcher:menuTextFunc(t.current) end)
                lines[#lines + 1] = "\u{2022} " .. names[key] .. (what ~= "" and (": " .. what) or "")
            end
        end
        G_reader_settings:saveSetting("inkaway_gesture_notice", table.concat({
            _("Ink Away left these gestures as they are, as they already do something:"),
            table.concat(lines, "\n"),
            _("Ink Away uses swipe up along the right edge for book notes, and swipe down for annotating the book. To use them, change them in Settings \u{2192} Taps and gestures \u{2192} Gesture manager \u{2192} One-finger swipe; the actions are \u{201C}Ink Away: book notes\u{201D} and \u{201C}Ink Away: annotate the book\u{201D}."),
        }, "\n\n"))
    end
end

-- The note about the book gestures, the first time Ink Away opens after it.
function InkAway:gestureNotice()
    local text = G_reader_settings:readSetting("inkaway_gesture_notice")
    if not text then return end
    G_reader_settings:delSetting("inkaway_gesture_notice")
    UIManager:scheduleIn(0.4, function()
        UIManager:show(require("ui/widget/infomessage"):new{ text = text })
    end)
end

-- Draw on the book being read (does nothing outside a book).
function InkAway:onInkAwayAnnotate()
    if self.book then
        self.book:annotate()
        self:gestureNotice()
    end
    return true
end

-- The book's notes in a book; anywhere else, Ink Away as its settings open it.
function InkAway:onInkAwayBookNotes()
    if self.book and self.book.openNotes then
        self.book:openNotes()
        self:gestureNotice()
    else self:openCanvas() end
    return true
end

-- The book is closing: leave nothing of ours open over it.
function InkAway:onCloseDocument()
    if self.book then self.book:close() end
end

-- The gesture actions, when a gesture is mapped to Ink Away or its library.
function InkAway:onInkAwayOpen()
    self:openCanvas()
    return true
end

function InkAway:onInkAwayLibrary()
    self:openCanvas(true)
    return true
end

-- Open the canvas, with the library on top when `library` is set.
function InkAway:openCanvas(library)
    -- Close any Ink Away view still open before opening a fresh one: a buried
    -- copy would keep painting and running its timers, and a reopen should start
    -- clean even if one got stuck. The stack is copied, as close() changes it.
    local stack = UIManager._window_stack or {}
    local existing = {}
    for i = 1, #stack do
        local w = stack[i] and stack[i].widget
        if w and w.name == "inkaway_view" then existing[#existing + 1] = w end
    end
    for _, w in ipairs(existing) do UIManager:close(w) end
    local InkAwayView = require("ink/view")
    UIManager:show(InkAwayView:new{ show_library = library or nil })
    self:gestureNotice()
end

return InkAway
