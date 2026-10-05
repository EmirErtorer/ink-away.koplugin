--[[
Ink Away, a drawing canvas and notebook for e-ink readers. This file only plugs
it into KOReader (the Tools menu entry and two gesture actions) and opens the view;
everything else lives under ink/.
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
end

function InkAway:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- emulator hook: INKAWAY_AUTOOPEN opens the canvas straight away, once; the
    -- variable is never set on a device
    if os.getenv("INKAWAY_AUTOOPEN") and not InkAway._autoopened then
        InkAway._autoopened = true
        UIManager:scheduleIn(1.2, function() self:openCanvas() end)
    end
end

function InkAway:addToMainMenu(menu_items)
    menu_items.inkaway = {
        text = _("Ink Away (drawing canvas)"),
        sorting_hint = "tools",   -- top level of the Tools tab, not buried in "More tools"
        keep_menu_open = false,
        callback = function() self:openCanvas() end,
    }
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
end

return InkAway
