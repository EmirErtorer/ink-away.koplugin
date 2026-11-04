--[[
Settings as KOReader's own widgets: a compact panel (a ButtonDialog) by default,
the way the old sheets read at a glance, or a full-screen list (a Menu) when
asked for with `style = "list"`.

    self:openNativeMenu{ field = "_settings_dialog", title = _("Settings"),
        tabs = { { "look", _("Appearance") }, ... },   -- optional
        items = function() return { ...rows... } end }

`items` is called again after every change, so a row always shows what is set
now. A row is a table with `text` and one of:

    toggle  = { get = fn, set = fn(on) }         ☑ or ☐, a tap flips it
    choice  = { options = { { value, label } }, get = fn, set = fn(value), title }
                                                 a few short options show as a
                                                 row of buttons, the chosen
                                                 one bold; more open a list
    number  = { min, max, step, get = fn, set = fn(value), format = fn }
                                                 − and + step it, a tap on the
                                                 value asks for a number
    value   = string or fn                       shown beside the text
    action  = fn, close = true                   runs fn (after closing the
                                                 panel with `close`)
    submenu = fn                                 runs fn and shows › (it opens
                                                 another window)

`title` may be a function, called again with the rows, for a panel whose heading
reports a state (a check in progress). plus optional `tab` (the id of the tab it is on, when there are tabs), `help`
(a longer note, shown on a long press), `separator` and `dim`. `back` (a
function) runs when the panel is closed from its Close button or by a tap
outside, to return to what it was opened from. `tab` starts it on that tab.
Part of InkAwayView (see ink/view.lua).
]]

local _ = require("ink/l10n")

local InkAwayView = {}

local CHECKED, UNCHECKED, MORE, TICK = "\u{2611}", "\u{2610}", "\u{203A}", "\u{2713} "

-- The label of the option `value` in `options` ({ value, label } pairs), or nil.
local function labelOf(options, value)
    for _i, o in ipairs(options) do if o[1] == value then return o[2] end end
end

-- The Menu entries for the rows `items`; `refresh()` redraws the menu after a
-- change.
local function entries(self, field, items, refresh)
    local out = {}
    for _i, it in ipairs(items) do
        local e = { text = it.text, separator = it.separator, dim = it.dim }
        if it.help then e.hold_callback = function() self:tell(it.help, { field = field .. "_help" }) end end
        if it.toggle then
            local t = it.toggle
            e.mandatory = t.get() and CHECKED or UNCHECKED
            e.callback = function() t.set(not t.get()); refresh() end
        elseif it.choice then
            local c = it.choice
            local cur = c.get()
            e.mandatory = labelOf(c.options, cur)
            e.callback = function()
                local list = {}
                for _j, o in ipairs(c.options) do
                    list[#list + 1] = { label = (o[1] == cur and TICK or "") .. o[2],
                        cb = function() c.set(o[1]); refresh() end }
                end
                self:chooseFromList{ field = field .. "_choice", title = c.title or it.text, items = list }
            end
        elseif it.number then
            local n = it.number
            local v = n.get()
            e.mandatory = n.format and n.format(v) or tostring(v)
            e.callback = function()
                self:askNumber{ field = field .. "_number", title = it.text, value = v, min = n.min, max = n.max,
                    step = n.step, format = n.format, on_done = function(nv) n.set(nv); refresh() end }
            end
        elseif it.submenu then
            e.mandatory = it.value and (type(it.value) == "function" and it.value() or it.value) or MORE
            e.callback = it.submenu
        else
            if it.value ~= nil then e.mandatory = type(it.value) == "function" and it.value() or it.value end
            local act = it.action
            e.callback = function()
                if it.close then self:closeSheet(field) end
                if act then act() end
                if not it.close then refresh() end
            end
        end
        out[#out + 1] = e
    end
    return out
end

-- Is this choice short enough to be a row of buttons? (up to four options, and
-- the whole row of text no longer than fits a small screen)
local function segmented(it)
    local c = it.choice
    if #c.options > 4 then return false end
    local chars = 0
    for _i, o in ipairs(c.options) do chars = chars + #o[2] end
    return chars <= 30, chars
end

-- The button rows of the panel for the rows `items` (those on `tab`, if any).
local function panelRows(self, field, items, tab, refresh)
    local out = {}
    for _i, it in ipairs(items) do
        if not it.tab or it.tab == tab then
            local hold = it.help and function() self:tell(it.help, { field = field .. "_help" }) end or nil
            if it.toggle then
                local t = it.toggle
                out[#out + 1] = { { text = (t.get() and CHECKED or UNCHECKED) .. "  " .. it.text, hold_callback = hold,
                    callback = function() t.set(not t.get()); refresh() end } }
            elseif it.choice and segmented(it) then
                local c = it.choice
                local cur = c.get()
                local cells, chars = {}, select(2, segmented(it))
                -- the caption shares the row when it fits, else it has a row of its own
                local inline = #c.options <= 3 and chars + #it.text <= 30
                if inline then cells[1] = { text = it.text, enabled = false, hold_callback = hold } end
                local caption = not inline and { { text = it.text, enabled = false, hold_callback = hold } } or nil
                for _j, o in ipairs(c.options) do
                    cells[#cells + 1] = { text = o[2], bold = o[1] == cur, hold_callback = hold,
                        callback = function() c.set(o[1]); refresh() end }
                end
                if caption then out[#out + 1] = caption end
                out[#out + 1] = cells
            elseif it.choice then
                local c = it.choice
                local cur = c.get()
                out[#out + 1] = { { text = it.text .. ": " .. (labelOf(c.options, cur) or "") .. "  " .. MORE,
                    hold_callback = hold, callback = function()
                        local list = {}
                        for _j, o in ipairs(c.options) do
                            list[#list + 1] = { label = (o[1] == cur and TICK or "") .. o[2],
                                cb = function() c.set(o[1]); refresh() end }
                        end
                        self:chooseFromList{ field = field .. "_choice", title = c.title or it.text, items = list }
                    end } }
            elseif it.number then
                local n = it.number
                local v = n.get()
                local step = n.step or 1
                local function put(nv)
                    n.set(math.max(n.min, math.min(n.max, nv))); refresh()
                end
                out[#out + 1] = {
                    { text = "\u{2212}", enabled = v > n.min, callback = function() put(v - step) end },
                    { text = it.text .. ": " .. (n.format and n.format(v) or tostring(v)), hold_callback = hold,
                        callback = function()
                            self:askNumber{ field = field .. "_number", title = it.text, value = v, min = n.min,
                                max = n.max, step = step, format = n.format, on_done = put }
                        end },
                    { text = "+", enabled = v < n.max, callback = function() put(v + step) end },
                }
            else
                local value = it.value
                if type(value) == "function" then value = value() end
                local text = it.text .. (value ~= nil and value ~= "" and (": " .. value) or "")
                if it.submenu then text = text .. "  " .. MORE end
                local act = it.submenu or it.action
                out[#out + 1] = { { text = text, enabled = not it.dim, hold_callback = hold, callback = function()
                    if it.close then self:closeSheet(field) end
                    if act then act() end
                    if not it.close and not it.submenu then refresh() end
                end } }
            end
        end
    end
    return out
end

-- The panel: tabs (when there are any), the rows of the current tab, Close.
local function openPanel(self, o)
    local field = o.field
    local ButtonDialog = require("ui/widget/buttondialog")
    local tab = o.tab or (o.tabs and o.tabs[1][1])
    local dialog
    local function leave()
        local was_open = self[field] == dialog
        self:closeSheet(field)
        if was_open and o.back then o.back() end
    end
    local refresh
    local function build()
        local buttons = {}
        if o.tabs and #o.tabs > 1 then
            local row = {}
            for _i, t in ipairs(o.tabs) do
                row[#row + 1] = { text = t[2], bold = t[1] == tab, callback = function() tab = t[1]; refresh() end }
            end
            buttons[1] = row
        end
        for _i, r in ipairs(panelRows(self, field, o.items(), tab, refresh)) do buttons[#buttons + 1] = r end
        buttons[#buttons + 1] = { { text = _("Close"), callback = leave } }
        return ButtonDialog:new{ title = type(o.title) == "function" and o.title() or o.title,
            title_align = "center", buttons = buttons,
            tap_close_callback = function() if self[field] == dialog then leave() end end }
    end
    refresh = function()
        if self[field] ~= dialog then return end
        local old = dialog
        dialog = build()
        dialog.refresh, dialog.tab = refresh, function() return tab end
        self:presentNative(field, dialog)
        require("ui/uimanager"):close(old)
    end
    dialog = build()
    dialog.refresh, dialog.tab = refresh, function() return tab end
    self:presentNative(field, dialog)
    return dialog
end

-- Show the settings list described in the header. Opening it again replaces the
-- one in `o.field`. Returns the Menu, and `menu.refresh()` redraws it.
function InkAwayView:openNativeMenu(o)
    local field = o.field
    self:closeSheet(field)
    if o.style ~= "list" then return openPanel(self, o) end
    local Menu = require("ui/widget/menu")
    local menu
    local function refresh()
        if self[field] == menu and menu.switchItemTable then
            -- (-1: stay on the page being read)
            menu:switchItemTable(nil, entries(self, field, o.items(), refresh), -1)
        end
    end
    menu = Menu:new{
        title = o.title, subtitle = o.note, item_table = entries(self, field, o.items(), refresh),
        is_borderless = true, is_popout = false, covers_fullscreen = true,
        close_callback = function()
            local was_open = self[field] == menu
            self:closeSheet(field)
            if was_open and o.back then o.back() end
        end,
    }
    menu.refresh = refresh
    self:presentNative(field, menu)
    return menu
end

-- The tick the options list puts before the current option, for those who build
-- a list of their own.
InkAwayView.CHOSEN = TICK

-- A "pick one" list: `options` is a list of { value, label }; the current one
-- is ticked; onpick(value) runs after the list closes.
function InkAwayView:openChooserSheet(title, options, current, onpick)
    local list = {}
    for _i, o in ipairs(options) do
        list[#list + 1] = { label = (current == o[1] and TICK or "") .. o[2], cb = function() onpick(o[1]) end }
    end
    self:chooseFromList{ field = "_chooser_dialog", title = title, items = list }
end

return InkAwayView
