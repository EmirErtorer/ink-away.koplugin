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
    -- Dev hook: with INKAWAY_AUTOOPEN set (the emulator launcher does this) drop
    -- straight into the canvas so UI work needs no menu navigation. A no-op on a
    -- real device, where the env var is never set. Guarded so it fires once.
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

-- Fires when the user maps a gesture to Ink Away in the gesture manager.
function InkAway:onInkAwayOpen()
    self:openCanvas()
    return true
end

function InkAway:openCanvas()
    -- Close any Ink Away view that is still open before opening a fresh one. This
    -- (a) prevents stacking a duplicate when the open gesture / Tools entry is
    -- re-invoked while Ink Away is already up -- a buried InkAwayView would keep
    -- being painted and running its timers every frame, so the app gets slower with
    -- each extra copy until a KOReader restart -- and (b) guarantees a reopen always
    -- starts from a clean instance and can RECOVER a stuck/buried one, instead of
    -- being blocked by it. Iterate a copy of the stack since close() mutates it.
    local stack = UIManager._window_stack or {}
    local existing = {}
    for i = 1, #stack do
        local w = stack[i] and stack[i].widget
        if w and w.name == "inkaway_view" then existing[#existing + 1] = w end
    end
    for _, w in ipairs(existing) do UIManager:close(w) end
    local InkAwayView = require("ink/view")
    UIManager:show(InkAwayView:new{})
end

return InkAway
