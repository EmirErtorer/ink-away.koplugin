--[[
Ink Away, a small finger drawing canvas for e-ink readers.

The plugin adds a menu entry that opens a blank fullscreen canvas. All the
drawing logic lives in the ink/ modules. This file only plugs Ink Away into
KOReader and opens the view.
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
end

function InkAway:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function InkAway:addToMainMenu(menu_items)
    menu_items.inkaway = {
        text = _("Ink Away (drawing canvas)"),
        sorting_hint = "more_tools",
        keep_menu_open = false,
        callback = function() self:openCanvas() end,
    }
end

-- Fires when the user maps a gesture to Ink Away in the gesture manager.
function InkAway:onInkAwayOpen()
    self:openCanvas()
    return true
end

function InkAway:openCanvas()
    local InkAwayView = require("ink/view")
    UIManager:show(InkAwayView:new{})
end

return InkAway
