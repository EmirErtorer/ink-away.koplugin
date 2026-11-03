--[[
Cloud sync, on screen: the Cloud sync sheet (connect, status, when to sync, this
reader's name), the sign-in with a QR code and a code to type, the preview of a
first sync, the result of a sync with its error codes, conflicts, earlier
versions, the log, and disconnecting. The syncing itself is ink/sync/*; this
file only shows it. Everything is done on the reader: no PC is needed.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("ink/l10n")
local Errors = require("ink/sync/errors")
local Manager = require("ink/sync/manager")
local Providers = require("ink/sync/providers")
local Schedule = require("ink/sync/schedule")
local Storage = require("ink/storage")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local GREY = Blitbuffer.COLOR_DARK_GRAY

local function S(px) return Screen:scaleBySize(px) end
local function vspan(px) return VerticalSpan:new{ width = S(px) } end
-- A translated text with %1, %2... filled in.
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

local InkAwayView = {}

local SHEET = "_sync"

-- "5 min ago" for a time `at`.
local function ago(at)
    local d = os.time() - at
    if d < 60 then return _("just now") end
    if d < 3600 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 86400 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return os.date("%d %b", at)
end

-- A line for an error: "IA-S101  No connection".
local function codeLine(code) return Errors.line(code) end

local function para(self, text, width, size, grey)
    return TextBoxWidget:new{ text = text, width = width, face = Font:getFace("cfont", size or 16),
        fgcolor = grey and GREY or nil }
end

------------------------------------------------------------------------------
-- How things stand, in words
------------------------------------------------------------------------------

-- What the sync is doing now, as a sentence.
function InkAwayView:syncProgressText(p)
    if not p then return _("Starting\u{2026}") end
    if p.phase == "check" then return _("Checking the cloud\u{2026}") end
    if p.phase == "cloud" then return _("Looking for changes\u{2026}") end
    if p.phase == "reader" then return _("Looking at this reader\u{2026}") end
    if p.phase == "files" then
        return T(_("%1 of %2: %3"), (p.done or 0) + 1, p.total or 0, Storage.baseName(p.rel or ""))
    end
    return _("Finishing\u{2026}")
end

-- Where things stand, in one or two sentences: { text, error = code }.
function InkAwayView:syncStatusLine(s)
    if s.running then return { text = self:syncProgressText(s.progress) } end
    local r = s.result
    if r and r.fatal then
        return { text = T(_("Stopped: %1"), Errors.info(r.fatal.code).title), error = r.fatal.code }
    end
    if s.last then
        local line
        if s.last.errors and s.last.errors > 0 then
            line = T(_("Synced %1, with %2 problem(s)"), ago(s.last.at), s.last.errors)
        else
            line = T(_("Synced %1"), ago(s.last.at))
        end
        if s.dirty then line = line .. "\n" .. _("Changes are waiting to be sent.") end
        return { text = line, error = s.last.errors and s.last.errors > 0 and s.last.first_error or nil }
    end
    return { text = s.dirty and _("Changes are waiting to be sent.") or _("Not synced yet.") }
end

-- A short line for the library menu's hint.
function InkAwayView:syncMenuHint()
    local s = Manager.status()
    if not s.connected then
        return _("Keep your notebooks the same on all your readers, through your own cloud account.")
    end
    return T(_("%1, %2"), s.provider_name, self:syncStatusLine(s).text:gsub("\n.*", ""))
end

-- Watch the sync: when something changes, rebuild the open sheet (at most every
-- couple of seconds, as e-ink redraws the sheet).
function InkAwayView:syncWatch()
    Manager.onChange(function()
        if self.closing or not self[SHEET] or self._sync_tick then return end
        self._sync_tick = function()
            self._sync_tick = nil
            if self[SHEET] then self:rebuildSheet(SHEET) end
        end
        UIManager:scheduleIn(Manager.live.running and 1.5 or 0.2, self._sync_tick)
    end)
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

local PAUSES = { { 0, _("Off") }, { 30, _("30 s") }, { 60, _("1 min") }, { 120, _("2 min") }, { 300, _("5 min") } }
local EVERY = { { 0, _("Off") }, { 15, _("15m") }, { 30, _("30m") }, { 60, _("1h") }, { 180, _("3h") },
    { 720, _("12h") }, { 1440, _("Day") } }

function InkAwayView:openSync()
    self:syncWatch()
    self:closeSheet(SHEET)
    local content_w, gap = self:sheetWidth()
    local function close() self:closeSheet(SHEET) end
    local build = function(menu)
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Cloud sync"), content_w, _("Done"), close) }
        local function add(w) table.insert(g, w) end
        local s = Manager.status()
        add(vspan(10))
        if not s.connected then
            add(para(self, _("Keep your notebooks and drawings the same on all your readers."), content_w, 17))
            add(vspan(8))
            add(self:sheetHint(_("Each notebook is copied to your own cloud account, and the latest version comes to a reader when you open it there. Nothing is replaced or removed without a safety copy, and when two readers change the same notebook, both versions are kept."), content_w, 14))
            add(vspan(14))
            for _i, p in ipairs(Providers.list()) do
                add(self:actionButton(T(_("Connect %1"), p.name), content_w, function() self:syncSignIn(p.id) end, true, nil, "cloud"))
                add(vspan(6))
            end
            add(self:sheetHint(_("Ink Away only uses its own folder in your account and cannot see anything else in it. Syncing stays off until you connect."), content_w, 13))
            return g
        end
        -- the account and how things stand
        add(self:sheetLabel(s.provider_name, true))
        add(vspan(2))
        add(para(self, (s.name ~= "" and s.name or s.email), content_w, 17))
        add(vspan(8))
        local line = self:syncStatusLine(s)
        add(para(self, line.text, content_w, 15, not line.error))
        if line.error then
            add(vspan(2))
            add(para(self, T(_("Code %1"), line.error), content_w, 14, true))
        end
        add(vspan(10))
        if s.running then
            add(self:actionButton(_("Stop"), content_w, function() Manager.stop() end))
        else
            local half = math.floor((content_w - gap) / 2)
            if line.error then
                add(HorizontalGroup:new{ align = "center",
                    self:actionButton(_("Sync now"), half, function() self:syncNow() end, true, nil, "refresh"),
                    HorizontalSpan:new{ width = gap },
                    self:actionButton(_("Details"), half, function() self:syncErrorSheet(line.error) end) })
            else
                add(self:actionButton(_("Sync now"), content_w, function() self:syncNow() end, true, nil, "refresh"))
            end
        end
        -- when it runs by itself
        local o = Manager.options()
        add(vspan(16))
        add(self:sheetLabel(_("Sync automatically"), true))
        add(vspan(6))
        add(ToggleRow:new{ label = _("After closing a notebook"), is_on = o.on_close, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_on_close", on) end })
        add(vspan(4))
        add(ToggleRow:new{ label = _("Get the latest when opening one"), is_on = o.on_open, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_on_open", on) end })
        add(vspan(4))
        add(ToggleRow:new{ label = _("When the reader goes to sleep"), is_on = o.on_sleep, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_on_sleep", on) end })
        add(vspan(10))
        add(self:sheetLabel(_("After I stop drawing")))
        add(vspan(6))
        add(self:segmentedRow(PAUSES, o.pause_s, content_w, function(v)
            Manager.set("inkaway_sync_pause", v); self:rebuildSheet(SHEET)
        end))
        add(vspan(10))
        add(self:sheetLabel(_("Also every")))
        add(vspan(6))
        add(self:segmentedRow(EVERY, o.interval_min, content_w, function(v)
            Manager.set("inkaway_sync_interval", v); Manager.armInterval(); self:rebuildSheet(SHEET)
        end))
        add(vspan(10))
        add(ToggleRow:new{ label = _("Allow turning on Wi-Fi"), is_on = o.wifi_on, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_wifi_on", on) end })
        add(vspan(6))
        add(self:sheetHint(_("Syncing by itself uses Wi-Fi only when it is already on, unless you allow this. \"Sync now\" may always turn it on."), content_w, 13))
        -- this reader, conflicts, versions, log, disconnect
        add(vspan(16))
        add(self:sheetLabel(_("This reader"), true))
        add(vspan(6))
        add(self:actionButton(T(_("Name: %1"), s.device), content_w, function() self:syncRename() end, nil, nil, "rename"))
        if s.conflicts > 0 then
            add(vspan(8))
            add(self:actionButton(T(_("Conflicts (%1)"), s.conflicts), content_w, function() self:syncConflicts() end, true))
            add(vspan(4))
            add(self:sheetHint(_("Notebooks changed on two readers. Both versions are kept."), content_w, 13))
        end
        if self.doc_path and Manager.relOf(self.doc_path) then
            add(vspan(8))
            add(self:actionButton(_("Earlier versions of this notebook"), content_w, function() self:syncVersions() end, nil, nil, "page"))
        end
        add(vspan(8))
        add(self:actionButton(_("Sync log"), content_w, function() self:syncLog() end, nil, nil, "file"))
        add(vspan(8))
        add(self:actionButton(_("Disconnect"), content_w, function() self:syncDisconnect() end, nil, nil, "exit"))
        return g
    end
    self:showSheet(SHEET, build)
end

------------------------------------------------------------------------------
-- Signing in
------------------------------------------------------------------------------

-- Connect to service `id`: a QR code to open on a phone, then the code to type.
function InkAwayView:syncSignIn(id)
    local pending, err = Manager.beginSignIn(id)
    if not pending then
        if err and err.code == "IA-S204" then return self:syncAskAppKey(id) end
        return self:syncErrorSheet(err and err.code or "IA-S503")
    end
    local name = Providers.name(id)
    local field = "_sync_signin"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field) end
    local build = function()
        local g = VerticalGroup:new{ align = "center", self:sheetTitle(T(_("Connect %1"), name), content_w, _("Cancel"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        add(para(self, T(_("1. Scan this with your phone's camera."), name), content_w, 16))
        add(vspan(10))
        local side = math.floor(math.min(content_w * 0.7, math.min(Screen:getWidth(), Screen:getHeight()) * 0.55))
        local okq, QRWidget = pcall(require, "ui/widget/qrwidget")
        if okq and QRWidget then
            add(CenterContainer:new{ dimen = Geom:new{ w = content_w, h = side },
                QRWidget:new{ text = pending.url, width = side, height = side } })
        end
        add(vspan(10))
        add(para(self, T(_("2. Sign in to %1 and tap Allow."), name), content_w, 16))
        add(vspan(6))
        add(para(self, T(_("3. %1 shows a code. Type it here."), name), content_w, 16))
        add(vspan(12))
        add(self:actionButton(_("Type the code"), content_w, function()
            close()
            self:syncAskCode(pending)
        end, true, nil, "text"))
        add(vspan(8))
        add(self:sheetHint(_("No camera? Open this address in any browser:") .. "\n" .. pending.url, content_w, 11))
        return g
    end
    self:showSheet(field, build)
end

-- The code from the cloud service, typed on the reader's keyboard.
function InkAwayView:syncAskCode(pending)
    local name = Providers.name(pending.provider)
    self:promptText{
        title = T(_("%1 code"), name),
        description = T(_("Type the code %1 showed after you tapped Allow."), name),
        ok_text = _("Connect"),
        on_cancel = function() end,
        on_ok = function(text)
            local close_wait = self:tell(T(_("Connecting to %1\u{2026}"), name), { wait = true, field = "_sync_wait" })
            UIManager:scheduleIn(0.3, function()
                local who, err = Manager.finishSignIn(pending, text)
                close_wait()
                if not who then
                    return self:syncErrorSheet(err and err.code or "IA-S503", { again = function() self:syncSignIn(pending.provider) end })
                end
                self:syncPreview()
            end)
        end,
    }
end

-- This copy of Ink Away has no app key for the service: the person can enter their own.
function InkAwayView:syncAskAppKey(id)
    local name = Providers.name(id)
    self:ask{
        title = T(_("%1 is not set up here"), name), field = "_sync_key",
        text = T(_("This copy of Ink Away has no %1 app key. Make an app at the %1 developer site (App folder access), and enter its app key to continue."), name),
        ok_text = _("Enter app key"),
        on_ok = function()
            self:promptText{
                title = _("App key"), description = T(_("The app key of your %1 app."), name), ok_text = _("Save"),
                on_ok = function(text)
                    text = (text or ""):gsub("%s", "")
                    if not text:match("^%w+$") or #text < 8 then
                        return self:tell(_("That does not look like an app key. It is letters and digits only."))
                    end
                    Manager.set(require("ink/sync/config").KEY_SETTING, text)
                    self:syncSignIn(id)
                end,
            }
        end,
    }
end

------------------------------------------------------------------------------
-- Syncing, and what it says
------------------------------------------------------------------------------

-- Sync now, with the result shown when it ends.
function InkAwayView:syncNow(extra)
    self:leaveDocument()   -- the open notebook's latest changes go out too
    local o = extra or {}
    o.on_done = function(res) self:syncShowResult(res) end
    if not Manager.run("manual", o) then self:syncShowResult({ fatal = { code = "IA-S201" }, errors = {}, warnings = {}, plan = {} }) end
    if self[SHEET] then self:rebuildSheet(SHEET) end
end

-- The first sync, looked at before it is done: what would go where.
function InkAwayView:syncPreview()
    self:openSync()
    local close_wait = self:tell(_("Looking at what there is to sync\u{2026}"), { wait = true, field = "_sync_wait" })
    Manager.run("manual", { dry = true, on_done = function(res)
        close_wait()
        if res.fatal then return self:syncErrorSheet(res.fatal.code) end
        local n = { upload = 0, download = 0, conflict = 0, delete_remote = 0, delete_local = 0 }
        for _i, p in ipairs(res.plan or {}) do if n[p.action] then n[p.action] = n[p.action] + 1 end end
        local field = "_sync_preview"
        local content_w, gap = self:sheetWidth()
        local function close() self:closeSheet(field) end
        local total = n.upload + n.download + n.conflict + n.delete_remote + n.delete_local
        self:showSheet(field, function()
            local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Ready to sync"), content_w, _("Not now"), close) }
            local function add(w) table.insert(g, w) end
            add(vspan(12))
            if total == 0 then
                add(para(self, _("Everything is already the same here and in the cloud."), content_w, 17))
            else
                if n.upload > 0 then add(para(self, T(_("%1 to send to the cloud"), n.upload), content_w, 17)); add(vspan(4)) end
                if n.download > 0 then add(para(self, T(_("%1 to download to this reader"), n.download), content_w, 17)); add(vspan(4)) end
                if n.conflict > 0 then
                    add(para(self, T(_("%1 changed in both places: both versions are kept"), n.conflict), content_w, 17)); add(vspan(4))
                end
                if n.delete_remote + n.delete_local > 0 then
                    add(para(self, T(_("%1 removed, with a safety copy"), n.delete_remote + n.delete_local), content_w, 17)); add(vspan(4))
                end
                add(vspan(6))
                add(self:sheetHint(_("Nothing on this reader is replaced or removed without a safety copy first."), content_w, 14))
            end
            add(vspan(16))
            add(self:actionButton(total == 0 and _("Done") or _("Start syncing"), content_w, function()
                close()
                if total > 0 then self:syncNow() end
            end, true))
            return g
        end)
    end })
end

-- The result of a sync that was asked for.
function InkAwayView:syncShowResult(res)
    if self.closing then return end
    self:closeSheet("_sync_wait")
    if res.fatal then return self:syncErrorSheet(res.fatal.code, { detail = res.fatal.detail }) end
    local field = "_sync_result"
    local content_w, gap = self:sheetWidth()
    local function close() self:closeSheet(field); if self[SHEET] then self:rebuildSheet(SHEET) end end
    local errs = res.errors or {}
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(#errs > 0 and _("Synced, with problems") or _("Synced"), content_w, _("Done"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(12))
        local any = false
        local function line(n, text) if n and n > 0 then any = true; add(para(self, T(text, n), content_w, 17)); add(vspan(4)) end end
        line(res.uploaded, _("%1 sent to the cloud"))
        line((res.downloaded or 0) - (res.conflicts or 0), _("%1 received"))
        line(res.conflicts, _("%1 kept in two versions"))
        line(res.deleted, _("%1 removed"))
        line(res.waiting, _("%1 will wait until closed"))
        if not any and #errs == 0 then add(para(self, _("Everything is already in sync."), content_w, 17)) end
        if #errs > 0 then
            add(vspan(8))
            add(self:sheetLabel(_("Problems"), true))
            add(vspan(4))
            for i, e in ipairs(errs) do
                if i > 6 then add(self:sheetHint(T(_("and %1 more, see the sync log"), #errs - 6), content_w, 13)); break end
                add(para(self, codeLine(e.code) .. (e.rel ~= "" and ("\n" .. Storage.baseName(e.rel)) or ""), content_w, 14))
                add(vspan(4))
            end
            add(vspan(4))
            add(self:sheetHint(_("Each one is tried again at the next sync. Tap Details on the sync sheet for what to do."), content_w, 13))
        end
        if res.blocked_deletes then
            add(vspan(8))
            add(self:actionButton(_("Delete anyway\u{2026}"), content_w, function()
                close(); self:syncErrorSheet("IA-S505")
            end))
        end
        if (res.conflicts or 0) > 0 then
            add(vspan(10))
            add(self:actionButton(_("Look at the conflicts"), content_w, function() close(); self:syncConflicts() end, true))
        end
        return g
    end)
end

-- What an error means and what to do about it. `o`: again (a function for a retry), detail.
function InkAwayView:syncErrorSheet(code, o)
    o = o or {}
    local info = Errors.info(code)
    local field = "_sync_error"
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local function close() self:closeSheet(field); if self[SHEET] then self:rebuildSheet(SHEET) end end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(info.title, content_w, _("Close"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        add(para(self, info.what, content_w, 17))
        add(vspan(10))
        add(self:sheetLabel(_("What to do"), true))
        add(vspan(4))
        add(para(self, info.fix, content_w, 16))
        add(vspan(12))
        add(para(self, T(_("Code %1"), code), content_w, 14, true))
        if o.detail and o.detail ~= "" then add(self:sheetHint(tostring(o.detail):sub(1, 160), content_w, 11)) end
        add(vspan(14))
        if code == "IA-S505" then
            add(self:actionButton(_("Delete anyway\u{2026}"), content_w, function()
                close()
                self:ask{ title = _("Delete anyway?"), ok_text = _("Delete"), ok_icon = "trash",
                    text = _("A large part of your notebooks will be removed in the cloud or on this reader. A safety copy is kept on this reader for 30 days."),
                    on_ok = function() self:syncNow{ allow_mass_delete = true } end }
            end))
        elseif code == "IA-S506" then
            add(self:actionButton(_("Sync this folder as a new library"), content_w, function()
                close(); self:syncNow{ rebase = true }
            end))
        elseif code == "IA-S202" or code == "IA-S204" then
            add(self:actionButton(_("Connect again"), content_w, function()
                close(); Manager.signOut(); self:openSync()
            end, true))
        elseif o.again or info.retry then
            add(self:actionButton(o.again and _("Start again") or _("Try again"), content_w, function()
                close()
                if o.again then o.again() else self:syncNow() end
            end, true))
        end
        return g
    end)
end

------------------------------------------------------------------------------
-- This reader, conflicts, earlier versions, the log, disconnecting
------------------------------------------------------------------------------

function InkAwayView:syncRename()
    self:promptText{
        title = _("Name of this reader"), input = Manager.deviceName(),
        description = _("Shown in the names of conflict copies, so you can tell which reader a version came from."),
        ok_text = _("Save"),
        on_ok = function(text)
            text = (text or ""):gsub("[/\\:%c]", ""):sub(1, 24)
            if text == "" then text = nil end
            Manager.set("inkaway_sync_device", text)
            if self[SHEET] then self:rebuildSheet(SHEET) end
        end,
    }
end

-- The conflicts to settle, one button each.
function InkAwayView:syncConflicts()
    local field = "_sync_conflicts"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field); if self[SHEET] then self:rebuildSheet(SHEET) end end
    local list = Manager.conflicts()
    if #list == 0 then close(); return self:showNotice(_("No conflicts.")) end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Conflicts"), content_w, _("Done"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(8))
        add(self:sheetHint(_("These notebooks were changed on two readers. Both versions were kept: the one already in the cloud under its own name, and the one from this reader as a copy."), content_w, 14))
        for _i, c in ipairs(Manager.conflicts()) do
            add(vspan(10))
            add(self:actionButton(Storage.stem(c.orig), content_w, function() self:syncConflict(c) end, nil, nil, "notebook"))
        end
        return g
    end)
end

-- One conflict: use the copy, keep the original, or keep both.
function InkAwayView:syncConflict(c)
    local field = "_sync_conflict"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field) end
    local function settle(how)
        close()
        local ok, err = Manager.resolveConflict(c.copy, how)
        if not ok then return self:syncErrorSheet(err and err.code or "IA-S503") end
        self:refreshLibrary()
        self:syncConflicts()
    end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(Storage.stem(c.orig), content_w, _("Back"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(8))
        add(para(self, T(_("Changed on %1 and on another reader. The copy from %1 is called %2."), c.device or "?", Storage.stem(c.copy)), content_w, 15))
        add(vspan(14))
        add(self:actionButton(_("Use the copy"), content_w, function() settle("copy") end, true))
        add(vspan(4))
        add(self:sheetHint(_("It replaces the original. The original is kept in the backup folder."), content_w, 13))
        add(vspan(10))
        add(self:actionButton(_("Keep the original"), content_w, function() settle("original") end))
        add(vspan(4))
        add(self:sheetHint(_("The copy is removed. It is kept in the backup folder."), content_w, 13))
        add(vspan(10))
        add(self:actionButton(_("Keep both"), content_w, function() settle("both") end))
        add(vspan(4))
        add(self:sheetHint(_("Nothing changes. The copy stays as a notebook of its own."), content_w, 13))
        return g
    end)
end

-- The earlier versions of the open notebook.
function InkAwayView:syncVersions()
    local rel = Manager.relOf(self.doc_path)
    if not rel then return end
    local close_wait = self:tell(_("Asking the cloud\u{2026}"), { wait = true, field = "_sync_wait" })
    UIManager:scheduleIn(0.2, function()
        local list, err = Manager.versions(rel)
        close_wait()
        if not list then return self:syncErrorSheet(err and err.code or "IA-S503") end
        local field = "_sync_versions"
        local content_w = self:sheetWidth()
        local function close() self:closeSheet(field) end
        self:showSheet(field, function()
            local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Earlier versions"), content_w, _("Done"), close) }
            local function add(w) table.insert(g, w) end
            add(vspan(8))
            add(self:sheetHint(Storage.baseName(rel), content_w, 15))
            if #list == 0 then add(vspan(10)); add(para(self, _("The cloud has no other versions."), content_w, 16)) end
            for _i, v in ipairs(list) do
                add(vspan(8))
                local label = (v.mtime and os.date("%d %b %Y, %H:%M", v.mtime) or v.rev) .. (v.current and ("  \u{00B7}  " .. _("now")) or "")
                add(self:actionButton(label, content_w, function()
                    if v.current then return self:showNotice(_("This is the version you have.")) end
                    close()
                    self:ask{ title = _("Bring back this version?"), ok_text = _("Bring it back"),
                        text = T(_("The notebook becomes the version from %1. What is on this reader now is saved in the backup folder first."),
                            v.mtime and os.date("%d %b %Y, %H:%M", v.mtime) or v.rev),
                        on_ok = function()
                            local m, rerr = Manager.restoreVersion(rel, v.rev)
                            if not m then return self:syncErrorSheet(rerr and rerr.code or "IA-S503") end
                            self:syncNow()
                        end }
                end, nil, "small"))
            end
            return g
        end)
    end)
end

function InkAwayView:syncLog()
    local field = "_sync_log"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field) end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Sync log"), content_w, _("Done"), close) }
        table.insert(g, vspan(8))
        local lines = Manager.logTail(20)
        table.insert(g, TextBoxWidget:new{ text = #lines > 0 and table.concat(lines, "\n") or _("Nothing yet."),
            width = content_w, face = Font:getFace("cfont", 12) })
        return g
    end)
end

function InkAwayView:syncDisconnect()
    local name = Manager.status().provider_name or ""
    self:ask{
        title = T(_("Disconnect %1?"), name), ok_text = _("Disconnect"), ok_icon = "exit",
        text = _("Notebooks on this reader and in the cloud stay as they are. This reader stops syncing. You can connect again at any time."),
        on_ok = function()
            Manager.signOut()
            self:closeSheet(SHEET)
            self:openSync()
        end,
    }
end

------------------------------------------------------------------------------
-- Hooks from the rest of Ink Away
------------------------------------------------------------------------------

-- The open notebook was saved.
function InkAwayView:syncNoteSaved()
    pcall(Manager.noteChanged)
end

-- A notebook is no longer open (it was saved just before).
function InkAwayView:syncNoteLeft()
    pcall(Manager.setOpen, {})
    pcall(Manager.noteClosed)
end

-- A notebook is open.
function InkAwayView:syncNoteOpened(path)
    local rel = Manager.relOf(path)
    pcall(Manager.setOpen, rel and { rel } or {})
end

-- A notebook was tapped in the library: look for a newer version of it first
-- (a few seconds at most), then open it. Returns whether the opening was taken over.
function InkAwayView:syncPreOpen(path, open)
    local opts = Manager.options()
    if not (opts.enabled and opts.on_open and Manager.connected() and Manager.relOf(path)) then return false end
    local close_wait = self:tell(_("Looking for a newer version\u{2026}"), { wait = true, field = "_sync_wait" })
    Manager.preOpen(path, function()
        close_wait()
        if not self.closing then open() end
    end)
    return true
end

return InkAwayView
