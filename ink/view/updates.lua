--[[
Updates, on screen: the Updates button in Settings, the Updates sheet (the
release and, apart from it, the prerelease, each with its notes), installing
one, and telling the reader when the once-a-day check found something new: a
small dot on the toolbar's Settings button until the sheet has been opened,
and a toast at the top, once per version, that goes at the first touch and
lets that touch through. The checking and installing are ink/update/*.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local GeomUI = require("ui/geometry")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Policy = require("ink/update/policy")
local Updater = require("ink/update/updater")

local Screen = Device.screen
local function S(px) return Screen:scaleBySize(px) end

-- A translated text with %1, %2... filled in (as KOReader's template).
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

local InkAwayView = {}

-- The version running, from the plugin's own _meta.lua.
function InkAwayView:inkVersion()
    if not self._ink_version then self._ink_version = Updater.version(self:pluginDir()) or "0.0.0" end
    return self._ink_version
end

-- The plugin folder, without a trailing slash.
function InkAwayView:pluginFolder()
    return (self:pluginDir():gsub("/+$", ""))
end

-- A release's date as a reader reads it ("12 Oct 2026"), or "".
local function dateText(iso)
    local y, m, d = tostring(iso or ""):match("^(%d+)%-(%d+)%-(%d+)")
    if not y then return "" end
    return os.date("%d %b %Y", os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

local function sizeText(n)
    return n and (n >= 1024 * 1024 and string.format("%.1f MB", n / 1024 / 1024)
        or string.format("%d KB", math.floor(n / 1024 + 0.5))) or ""
end

------------------------------------------------------------------------------
-- Opening: tidying after an update, and the once-a-day check
------------------------------------------------------------------------------

-- When the canvas opens: remove the copy an update replaced (once the new
-- version runs), show the dot if there is news not yet looked at, and if a
-- check is due, run one a little later (so opening never waits on it). Not
-- over a book.
function InkAwayView:updatesOnOpen()
    if self.reader_mode or self.floating then return end
    local cur = self:inkVersion()
    Updater.cleanup(self:pluginFolder(), cur)
    self._update_dot = Updater.unseen(cur)
    if not Updater.due() then return end
    self._update_check_cb = self._update_check_cb or function() self:autoCheckUpdates() end
    UIManager:scheduleIn(10, self._update_check_cb)
end

function InkAwayView:autoCheckUpdates()
    if self.closing then return end
    Updater.autoCheck(self:inkVersion(), function(v)
        if self.closing then return end   -- the dot shows next time
        self._update_dot = true
        self:refreshToolbarStrip()
        self:showNotice(T(_("Ink Away %1 is available: Settings, Updates."), v), 6)
    end)
end

-- Stop a check waiting to start (the canvas is closing). One already running
-- finishes on its own and is remembered.
function InkAwayView:updatesOnClose()
    if self._update_check_cb then UIManager:unschedule(self._update_check_cb) end
end

-- Repaint the toolbar strip (the dot came or went).
function InkAwayView:refreshToolbarStrip()
    if self.closing or not self.view then return end
    self._area_only = false
    UIManager:setDirty(self, "ui", GeomUI:new{ x = 0, y = 0, w = self.screen_w, h = self.view.area_y })
end

-- The dot on the Settings button: news not yet looked at.
function InkAwayView:paintUpdateDot(bb, ox, oy)
    self._update_dot_rect = nil
    if not (self._update_dot and self._btn_w and self._bar_h and self._toolbar_icons) or self._toolbar_hidden then return end
    local idx
    for i, e in ipairs(self._toolbar_icons) do if e.id == "menu" then idx = i end end
    if not idx then return end
    local isz = self._icon_sz or math.floor(self._bar_h * 0.6)
    local d = math.max(6, S(8))
    local cx = ox + self._btn_w * (idx - 1) + math.floor((self._btn_w + isz) / 2) - math.floor(d / 2)
    local cy = oy + math.floor((self._bar_h - isz) / 2) - math.floor(d / 4)
    cx, cy = math.min(cx, ox + self._btn_w * idx - d - 1), math.max(oy + 1, cy)
    Accent.paintRounded(bb, cx, cy, d, d, math.floor(d / 2))
    self._update_dot_rect = { x = cx, y = cy, w = d, h = d, r = math.floor(d / 2) }
end

------------------------------------------------------------------------------
-- Settings and the Updates sheet
------------------------------------------------------------------------------

-- What the Updates button says when there is news (an update found, or one
-- installed and waiting for a restart), or nil.
function InkAwayView:updateNews()
    if self.reader_mode or self.floating then return nil end
    if Updater.installed then return T(_("Restart KOReader to use %1"), Updater.installed) end
    local v = Updater.available(self:inkVersion())
    return v and T(_("Update available: %1"), v) or nil
end

-- The Updates button for Settings, w wide: the news, filled, or a plain
-- Updates.
function InkAwayView:updatesButton(w, before)
    local news = self:updateNews()
    return self:actionButton(news or _("Updates"), w, function()
        if before then before() end
        self:openUpdates()
    end, news ~= nil, nil, "update")
end

-- Start a check now, asking KOReader to connect first if it is offline, and
-- show the sheet again when it ends.
function InkAwayView:checkUpdatesNow()
    local cur = self:inkVersion()
    local function run()
        local started = Updater.check(cur, function()
            self:refreshUpdates()
        end, true)
        if not started and not Updater.busy then
            Updater.error = Updater.error or _("a check could not start")
        end
        self:refreshUpdates()
    end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then NetworkMgr:runWhenOnline(run) else run() end
end

-- Redraw the Updates panel, when it is open, after something changed.
function InkAwayView:refreshUpdates()
    if self._updates and self._updates.refresh then self._updates.refresh() end
end

-- A release's rows: its kind, version and date (a long press tells more), What's
-- new, and its action (none for the one installed).
local function releaseRows(self, rows, kind, rel, action, notes_of)
    local head = rel.version .. ((rel.date and rel.date ~= "") and ("  \u{00B7}  " .. dateText(rel.date)) or "")
    local line
    if action == "update" then line = T(_("A newer release, %1 to download."), sizeText(rel.size))
    elseif action == "back" then line = T(_("Go back from this version to the latest release (%1)."), sizeText(rel.size))
    elseif action == "try" then line = T(_("A test build before the next release: newer things, maybe rough edges. You can go back to the release here any time. %1."), sizeText(rel.size))
    elseif action == "current" then line = _("You have this version.") end
    rows[#rows + 1] = { text = kind, value = head, help = line, action = function() end }
    rows[#rows + 1] = { text = _("What's new"), submenu = function() self:openReleaseNotes(notes_of, kind) end }
    if action ~= "current" then
        local label = (action == "back" and _("Go back to it")) or (action == "try" and _("Try it")) or _("Install")
        rows[#rows + 1] = { text = label, action = function() self:confirmUpdate(rel, action) end }
    end
end

-- The Updates panel: the version and what the check found in its heading, a
-- release's rows, the two switches and Check now.
function InkAwayView:openUpdates()
    self:closeSheet("_settings_dialog")
    local cur = self:inkVersion()
    -- opening the panel is looking at the news: the dot goes
    local avail = Updater.available(cur)
    if avail then Updater.set("seen", avail) end
    if self._update_dot then self._update_dot = false; self:refreshToolbarStrip() end
    local function heading()
        local o = Updater.offers
        local kind = o and o.on_pre and (o.pre and Policy.compare(o.pre.version, cur) == 0 and _("a prerelease")
            or _("a test build")) or _("a release")
        local lines = { T(_("Ink Away %1"), cur) .. (o and ("  \u{00B7}  " .. kind) or "") }
        if Updater.installed then
            lines[#lines + 1] = T(_("%1 is installed. Restart KOReader to use it."), Updater.installed)
        elseif Updater.busy == "installing" then
            lines[#lines + 1] = _("Downloading and checking the update…")
        elseif Updater.busy == "checking" then
            lines[#lines + 1] = _("Asking GitHub what there is…")
        elseif o then
            if not o.stable then lines[#lines + 1] = _("No release found on GitHub.") end
        elseif Updater.error then
            lines[#lines + 1] = T(_("Could not check: %1."), Updater.error)
        end
        local last = Updater.get("last")
        lines[#lines + 1] = last and T(_("Last checked %1."), os.date("%d %b, %H:%M", last)) or _("Not checked yet.")
        return table.concat(lines, "\n")
    end
    self:openNativeMenu{ field = "_updates", title = function() return _("Updates") .. "\n\n" .. heading() end,
        items = function()
            local rows = {}
            local o = Updater.offers
            if Updater.installed then
                rows[#rows + 1] = { text = _("Restart KOReader"), action = function() UIManager:askForRestart() end }
            elseif not Updater.busy and o then
                if o.stable then
                    releaseRows(self, rows, _("Release"), o.stable, o.stable_action,
                        (o.stable_action == "update" and #o.since > 0) and o.since or { o.stable })
                end
                if o.pre then releaseRows(self, rows, _("Prerelease"), o.pre, o.pre_action, { o.pre }) end
            end
            rows[#rows + 1] = { text = _("Check once a day"),
                help = _("On its own Ink Away looks once a day, when it opens on Wi-Fi; it never turns Wi-Fi on."),
                toggle = { get = Updater.autoOn, set = function(on) Updater.set("auto", on) end } }
            rows[#rows + 1] = { text = _("Tell me about prereleases"),
                toggle = { get = Updater.preOn, set = function(on) Updater.set("pre", on) end } }
            if not Updater.busy and not Updater.installed then
                rows[#rows + 1] = { text = _("Check now"), action = function() self:checkUpdatesNow() end }
            end
            return rows
        end }
    -- nothing known this session: look now when already online
    if not Updater.offers and not Updater.busy and not Updater.installed then
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        if ok and NetworkMgr and NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then self:checkUpdatesNow() end
    end
end

-- Release notes, newest first: each release's version and date, then its
-- notes, in KOReader's own text viewer over the Updates panel.
function InkAwayView:openReleaseNotes(list, kind)
    local out = {}
    for i, rel in ipairs(list) do
        if i > 1 then out[#out + 1] = "" end
        out[#out + 1] = rel.version .. ((rel.date and rel.date ~= "") and ("  \u{00B7}  " .. dateText(rel.date)) or "")
        if rel.pre then out[#out + 1] = kind or _("Prerelease") end
        local blocks = Policy.notes(rel.notes)
        if #blocks == 0 then out[#out + 1] = _("No notes for this version.") end
        for _j, b in ipairs(blocks) do
            if b.kind == "h" then
                out[#out + 1] = ""; out[#out + 1] = b.text
            elseif b.kind == "li" then
                out[#out + 1] = string.rep("   ", b.depth or 0) .. "\u{2022}  " .. b.text
            else
                out[#out + 1] = ""; out[#out + 1] = b.text
            end
        end
    end
    local TextViewer = require("ui/widget/textviewer")
    self:presentNative("_release_notes", TextViewer:new{ title = _("What's new"), text = table.concat(out, "\n"),
        justified = false })
end

-- Ask before installing `rel` (offered as `action`), then install it.
function InkAwayView:confirmUpdate(rel, action)
    local title = (action == "back" and T(_("Go back to %1?"), rel.version))
        or (action == "try" and T(_("Try %1?"), rel.version)) or T(_("Install %1?"), rel.version)
    local text = T(_("Ink Away downloads it from GitHub (%1) and checks it before it replaces this version; then KOReader restarts to use it. Your drawings, notebooks and settings stay as they are."), sizeText(rel.size))
    if action == "try" then
        text = text .. "\n\n" .. _("A prerelease is a test build. You can go back to the latest release from Settings, Updates.")
    end
    self:ask{ field = "_update_confirm", title = title, text = text,
        ok_text = (action == "back" and _("Go back")) or _("Install"), on_ok = function() self:installUpdate(rel) end }
end

function InkAwayView:installUpdate(rel)
    local function show()
        if self._updates then self:refreshUpdates() else self:openUpdates() end
    end
    Updater.install(rel, self:pluginFolder(), function(ok, why)
        if ok then
            show()
            UIManager:askForRestart(T(_("Ink Away %1 is installed. Restart KOReader to use it."), rel.version))
        else
            self:tell(T(_("The update was not installed: %1.\n\nNothing was changed."), tostring(why)),
                { title = _("Not installed"), field = "_update_failed" })
        end
    end)
    show()
end

return InkAwayView
