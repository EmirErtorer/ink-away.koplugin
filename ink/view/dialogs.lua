--[[
The everyday dialogs, on KOReader's own widgets: a message (InfoMessage), a
question to confirm (ConfirmBox), a line of text to type (InputDialog), a choice
from a list (Menu), a number (SpinWidget), a job's progress (ButtonDialog) and a
file or folder to pick (PathChooser). Every part of Ink Away asks through these,
so they look and behave like the rest of KOReader, and, being ordinary windows
above the view, leave KOReader's own gestures and keys alone.
Part of InkAwayView (see ink/view.lua).
]]

local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Storage = require("ink/storage")

local InkAwayView = {}

-- Keep `widget` in self[field] while it is open, so closeSheet(field) (and
-- closing the view) closes it, and show it. However it closes, the view is told
-- it was uncovered (its next paint must be a whole one) and `on_closed` runs.
local function present(self, field, widget, on_closed)
    self._sheet_fields = self._sheet_fields or {}
    self._sheet_fields[field] = true
    self[field] = widget
    local was = widget.onCloseWidget
    widget.onCloseWidget = function(w, ...)
        if self[field] == w then self[field] = nil end
        if was then was(w, ...) end
        if on_closed then on_closed() end
        self:uncovered()
    end
    UIManager:show(widget)
    return widget
end

-- (for the other native windows: see nativemenu.lua)
InkAwayView.presentNative = present

-- A window that is not kept in a field (a picker): the view is still told when
-- it goes.
local function uncoverOnClose(self, widget)
    local was = widget.onCloseWidget
    widget.onCloseWidget = function(w, ...)
        if was then was(w, ...) end
        self:uncovered()
    end
    return widget
end

-- A title above its text, as one string: KOReader's message and confirmation
-- boxes have no title of their own.
local function titled(title, text)
    if title and text and text ~= "" then return title .. "\n\n" .. text end
    return title or text or ""
end

-- A message. `o` may hold a title (put above the text), timeout (seconds until
-- it closes by itself), wait (a "working on it" note that a tap does not
-- close, closed by the caller) and field. Returns a function that closes it.
function InkAwayView:tell(text, o)
    o = o or {}
    local field = o.field or "_message"
    self:closeSheet(field)
    local InfoMessage = require("ui/widget/infomessage")
    present(self, field, InfoMessage:new{
        text = titled(o.title, text),
        timeout = o.timeout,
        dismissable = not o.wait,
    })
    return function() self:closeSheet(field) end
end

-- A question to confirm. `o` holds title, text, ok_text, on_ok(), and optional
-- cancel_text, on_cancel() (Cancel, a tap outside or Back) and field.
function InkAwayView:ask(o)
    local field = o.field or "_ask"
    self:closeSheet(field)
    local ConfirmBox = require("ui/widget/confirmbox")
    local function cancel()
        self:closeSheet(field)
        local f = o.on_cancel
        if f then f() end
    end
    local function ok()
        self:closeSheet(field)
        o.on_ok()
    end
    present(self, field, ConfirmBox:new{
        text = titled(o.title, o.text),
        ok_text = o.ok_text,
        cancel_text = o.cancel_text or _("Cancel"),
        ok_callback = ok,
        cancel_callback = cancel,
    })
end

-- "☑ label" / "☐ label": a switch on a button, which InputDialog has no field for.
local function switchLabel(label, on)
    return (on and "\u{2611} " or "\u{2610} ") .. label
end

-- A line of text to type. `o` holds title, input (the text to start with),
-- hint, description, input_type, ok_text and on_ok(text, on) (`on`: the
-- toggle's state), plus optional on_cancel(), `default` (the text on_ok gets
-- when the field is left empty), `extra` ({ text, callback(text) }: a second
-- button that gets what was typed so far) and `toggle` ({ label, is_on }: a
-- switch above the buttons) and field. Enter does what the main button does,
-- unless `lines` asks for a taller field, where Enter starts a new line.
function InkAwayView:promptText(o)
    local field = o.field or "_prompt"
    self:closeSheet(field)
    local InputDialog = require("ui/widget/inputdialog")
    local toggle_on = o.toggle and o.toggle.is_on and true or false
    local dialog
    local function cancel()
        self:closeSheet(field)
        if o.on_cancel then o.on_cancel() end
    end
    local function ok()
        if self[field] ~= dialog then return end   -- (closed meanwhile)
        local text = dialog:getInputText()
        self:closeSheet(field)
        if o.default and (not text or text == "") then text = o.default end
        o.on_ok(text, toggle_on)
    end
    local row = { { text = _("Cancel"), id = "close", callback = cancel } }
    if o.extra then
        row[#row + 1] = { text = o.extra.text, callback = function()
            local text = dialog:getInputText()
            self:closeSheet(field)
            o.extra.callback(text)
        end }
    end
    row[#row + 1] = { text = o.ok_text, is_enter_default = not o.lines, callback = ok }
    local buttons = { row }
    if o.toggle then
        table.insert(buttons, 1, { { text = switchLabel(o.toggle.label, toggle_on), id = "toggle",
            callback = function()
                toggle_on = not toggle_on
                local b = dialog.button_table and dialog.button_table:getButtonById("toggle")
                if b then b:setText(switchLabel(o.toggle.label, toggle_on), b.width); b:refresh() end
            end } })
    end
    dialog = InputDialog:new{
        title = o.title, input = o.input or "", input_hint = o.hint, description = o.description,
        input_type = o.input_type, text_type = o.text_type,
        allow_newline = o.lines ~= nil, enter_callback = not o.lines and ok or nil,
        buttons = buttons,
        -- Back, or a tap on the close icon
        close_callback = function() if self[field] == dialog then cancel() end end,
    }
    present(self, field, dialog)
    -- (its two answers, for whoever holds the dialog)
    dialog.ok_callback, dialog.cancel_callback = ok, cancel
    dialog:onShowKeyboard()
end

-- A choice from a list, KOReader's own menu, a page at a time. `o` holds title,
-- items ({ label, cb, icon }, each closing the menu before its cb), and
-- optional note (shown under the title), empty (said when there are none),
-- footer (more entries after the list, the same shape), close_text (unused: the
-- title bar has its own close) and field.
function InkAwayView:chooseFromList(o)
    local field = o.field or "_list"
    self:closeSheet(field)
    local Menu = require("ui/widget/menu")
    local function entry(it)
        return { text = it.label, callback = function() self:closeSheet(field); it.cb() end }
    end
    local items = {}
    for _i, it in ipairs(o.items) do items[#items + 1] = entry(it) end
    if #items == 0 and o.empty then items[1] = { text = o.empty, dim = true, callback = function() end } end
    for _i, it in ipairs(o.footer or {}) do items[#items + 1] = entry(it) end
    local menu
    menu = Menu:new{
        title = o.title, subtitle = o.note, item_table = items,
        is_borderless = true, is_popout = false, covers_fullscreen = true,
        close_callback = function() self:closeSheet(field) end,
    }
    present(self, field, menu)
end

-- A number: KOReader's spin widget. `o` holds title, value, min, max, step,
-- on_done(value) (on Done), and optional note, label, format(v) (the value as
-- shown: what follows its number becomes the unit) and field.
function InkAwayView:askNumber(o)
    local field = o.field or "_number"
    self:closeSheet(field)
    local SpinWidget = require("ui/widget/spinwidget")
    local step = o.step or 1
    local unit
    if o.format then
        local shown = tostring(o.format(o.value))
        unit = shown:gsub("^[%d%.,%-]+%s*", "")
        if unit == "" then unit = nil end
    end
    local decimals = tostring(step):match("%.(%d+)")
    present(self, field, SpinWidget:new{
        title_text = o.title, info_text = o.note or (o.label ~= "" and o.label) or nil,
        value = o.value, value_min = o.min, value_max = o.max, value_step = step,
        value_hold_step = step * 5, precision = decimals and ("%." .. #decimals .. "f") or nil,
        unit = unit, ok_text = _("Done"),
        callback = function(spin)
            self:closeSheet(field)
            o.on_done(spin.value)
        end,
    })
end

-- A job's progress: its title and how far it is, with Stop. `o` holds title,
-- max, on_stop() and optional note, stop_ask (a question asked before
-- stopping) and field. Returns { report(n), close() }: how far the job got (up
-- to max), and its end. KOReader has no progress window to update in place, so
-- the percentage is redrawn (a few seconds apart at most, for the e-ink).
function InkAwayView:showProgress(o)
    local field = o.field or "_progress"
    local ButtonDialog = require("ui/widget/buttondialog")
    local handle, over, pct, shown_at = {}, false, 0, nil
    local show
    local function stopNow()
        handle.close()
        o.on_stop()
    end
    -- Stop: asked first when there is a question; "Keep going" goes on
    local function requestStop()
        if over then return end
        if not o.stop_ask then return stopNow() end
        self:closeSheet(field)
        self:ask{ field = field .. "_ask", title = _("Stop now?"), text = o.stop_ask,
            ok_text = _("Stop"), cancel_text = _("Keep going"),
            on_ok = stopNow, on_cancel = function() if not over and not self[field] then show() end end }
    end
    show = function()
        self:closeSheet(field)
        present(self, field, ButtonDialog:new{
            title = titled(o.title, o.note) .. string.format("\n\n%d%%", math.floor(pct * 100)),
            title_align = "center", dismissable = false,
            buttons = { { { text = _("Stop"), callback = requestStop } } },
        })
    end
    function handle.report(n)
        if over or type(n) ~= "number" then return end
        local p = math.max(0, math.min(1, n / math.max(1, o.max or 1)))
        local now = os.time()
        if p == pct or (shown_at and now - shown_at < 3 and p < 1) then return end
        pct, shown_at = p, now
        if self[field] then show() end
    end
    function handle.close()
        over = true
        self:closeSheet(field)
        self:closeSheet(field .. "_ask")
    end
    show()
    return handle
end

-- A message from where no Ink Away view is open (a book's ink, saved in the
-- background): the same message, from a stand-in for the view.
function InkAwayView.tellAnywhere(text)
    local host = setmetatable({}, { __index = require("ink/view") })
    host:tell(text)
end

local function isPicture(name)
    local l = name:lower()
    return l:match("%.png$") ~= nil or l:match("%.jpe?g$") ~= nil
end
InkAwayView.isPictureName = isPicture

-- KOReader's own file list for choosing a file, starting in folder `path`: its
-- sorting, without the .sdr folders, and a tap on a file picks it. `title` is
-- shown above the list.
function InkAwayView:browseKoreaderFiles(path, on_pick, accept, title)
    local PathChooser = require("ui/widget/pathchooser")
    local chooser
    chooser = PathChooser:new{
        title = title or true,
        path = (path and Storage.isDir(path)) and path or self:homeDir(),
        select_directory = false, select_file = true,
        file_filter = accept and function(full) return accept(Storage.baseName(full)) end or nil,
        onConfirm = function(file) on_pick(file) end,
    }
    local select = chooser.onMenuSelect
    chooser.onMenuSelect = function(this, item)
        local file = item and item.path
        if file and not Storage.isDir(file) then
            UIManager:close(this)
            on_pick(file)
            return true
        end
        return select(this, item)
    end
    UIManager:show(uncoverOnClose(self, chooser))
end

-- Let the reader pick a file, starting in folder `path`: only the files
-- accept(name) lets through are shown (all with none). The icon and empty-folder
-- note the old picker took are not needed by KOReader's list. `title` is shown
-- above it.
function InkAwayView:pickFile(path, on_pick, accept, _icon, _empty, title)
    self:browseKoreaderFiles(path, on_pick, accept, title)
end

-- Let the reader pick a folder, starting in `path`: KOReader's file list, with
-- its own "Choose this folder" button.
function InkAwayView:pickFolder(path, on_pick)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(uncoverOnClose(self, PathChooser:new{
        title = true,
        path = (path and Storage.isDir(path)) and path or self:homeDir(),
        select_directory = true, select_file = false, show_files = false,
        onConfirm = function(dir) on_pick(dir) end,
    }))
end

-- Run fn(), asking first when a file at `path` would be replaced.
function InkAwayView:confirmReplace(path, fn)
    if not Storage.exists(path) then fn(); return end
    self:ask{ title = _("Replace it?"),
        text = string.format(_("\u{201C}%s\u{201D} already exists. Replace it?"), Storage.baseName(path)),
        ok_text = _("Replace"), on_ok = fn }
end

return InkAwayView
