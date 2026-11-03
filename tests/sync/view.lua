-- The cloud sync screens (ink/view/sync.lua) in the mock KOReader: every sheet
-- builds, says what it should, and its buttons do what they say. The sync itself
-- is replaced by a small stand-in (ink/sync/manager.lua is tested apart).
--   luajit tests/sync/view.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
local TestEnv = require("testenv")
local BASE = (os.getenv("INKAWAY_TMP") or "/tmp") .. "/inkaway-sync-view-" .. os.time()
os.execute("rm -rf '" .. BASE .. "'; mkdir -p '" .. BASE .. "/data'")
package.loaded["datastorage"] = { getDataDir = function() return BASE .. "/data" end, getSettingsDir = function() return BASE .. "/data/settings" end }
_G.G_reader_settings = {
    data = TestEnv.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local UIManager = require("ui/uimanager")
local Manager = require("ink/sync/manager")
local Account = require("ink/sync/account")
local State = require("ink/sync/state")
local Errors = require("ink/sync/errors")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function findButton(w, text)
    local function has(t, seen)
        if type(t) ~= "table" or seen[t] then return false end
        seen[t] = true
        if t.text == text then return true end
        for k, val in pairs(t) do if k ~= "show_parent" and k ~= "parent" and has(val, seen) then return true end end
        return false
    end
    local function find(t, seen)
        if type(t) ~= "table" or seen[t] then return nil end
        seen[t] = true
        if type(t.callback) == "function" and has(t, {}) then return t end
        for k, val in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" then local f = find(val, seen); if f then return f end end
        end
    end
    return find(w, {})
end
local function textIn(w)
    local out, seen = {}, {}
    local function walk(t)
        if type(t) ~= "table" or seen[t] then return end
        seen[t] = true
        if type(t.text) == "string" then out[#out + 1] = t.text end
        for k, v in pairs(t) do if k ~= "show_parent" and k ~= "parent" then walk(v) end end
    end
    walk(w)
    return table.concat(out, "\n")
end
local function press(w, text)
    local b = w and findButton(w, text)
    if b then b.callback() end
    return b ~= nil
end

local InkAwayView = dofile("ink/view.lua")
local view = InkAwayView:new{}

------------------------------------------------------------------------------
-- not connected
------------------------------------------------------------------------------
view:openSync()
local sheet = view._sync
ok(sheet ~= nil, "the Cloud sync sheet opens")
local t = textIn(sheet)
ok(t:find("Cloud sync", 1, true), "it has a title")
ok(findButton(sheet, "Connect Dropbox"), "it offers to connect Dropbox")
ok(t:find("Nothing is replaced or removed without a safety copy", 1, true), "it says plainly what is kept safe")
ok(not findButton(sheet, "Sync now"), "no sync button before connecting")

-- connecting with no app key: asks for one instead of a broken QR code
press(sheet, "Connect Dropbox")
ok(view._sync_key ~= nil, "without an app key it explains and offers to enter one")
ok(textIn(view._sync_key):find("not registered with Dropbox yet", 1, true), "in words")
view:closeSheet("_sync_key")

-- with a key, the QR sheet
G_reader_settings.data.inkaway_sync_dropbox_key = "abcdefgh12345678"
press(view._sync, "Connect Dropbox")
local si = view._sync_signin
ok(si ~= nil, "with an app key the sign-in sheet opens")
local st = textIn(si)
ok(st:find("1. Scan this", 1, true) and st:find("2. Sign in to Dropbox and tap Allow", 1, true)
    and st:find("3. Dropbox shows a code", 1, true), "three numbered steps")
ok(st:find("https://www.dropbox.com/oauth2/authorize", 1, true), "the address is there for a reader with no camera")
ok(findButton(si, "Type the code"), "the code is typed on the reader")
press(si, "Type the code")
ok(view._prompt ~= nil, "typing the code opens the keyboard sheet")
ok(textIn(view._prompt):find("Type the code Dropbox showed", 1, true), "with its instruction")
view:closeSheet("_prompt")
view:closeSheet("_sync_signin")
G_reader_settings.data.inkaway_sync_dropbox_key = nil

-- the other services are offered too, and sign in by showing a code on the reader
ok(findButton(sheet, "Connect Google Drive") and findButton(sheet, "Connect OneDrive"), "Google Drive and OneDrive are offered")
press(sheet, "Connect Google Drive")
ok(view._sync_key ~= nil and textIn(view._sync_key):find("not registered with Google Drive yet", 1, true), "Google Drive without a registration asks for one")
press(view._sync_key, "Enter details")
ok(view._prompt ~= nil and textIn(view._prompt):find("The Client ID of your Google Drive app", 1, true), "first the client id")
view:closeSheet("_prompt")
view:closeSheet("_sync_key")
G_reader_settings.data.inkaway_sync_gdrive_key = "1234567890-abcdefgh.apps.googleusercontent.com"
G_reader_settings.data.inkaway_sync_gdrive_secret = "GOCSPX-abcdefgh"
local Http = require("ink/sync/http")
local Json = require("ink/sync/json")
local real_transport, sent = Http.transport, {}
Http.transport = function(spec)
    sent[#sent + 1] = spec
    if spec.url:find("/device/code", 1, true) then
        return { code = 200, headers = {}, body = Json.encode({ device_code = "DC", user_code = "ABCD-EFGH",
            verification_url = "https://www.google.com/device", interval = 5, expires_in = 900 }) }
    end
    if spec.url:find("/token", 1, true) then
        if #sent < 4 then return { code = 428, headers = {}, body = Json.encode({ error = "authorization_pending" }) } end
        return { code = 200, headers = {}, body = Json.encode({ access_token = "A", refresh_token = "R", expires_in = 3600 }) }
    end
    if spec.url:find("/about", 1, true) then
        return { code = 200, headers = {}, body = Json.encode({ user = { displayName = "Grace", emailAddress = "g@x.org", permissionId = "p1" } }) }
    end
    return { code = 404, headers = {}, body = "{}" }
end
press(view._sync, "Connect Google Drive")
local gi = view._sync_signin
ok(gi ~= nil, "with a registration the Google Drive sign-in sheet opens")
local gt = textIn(gi)
ok(gt:find("ABCD-EFGH", 1, true), "the code to type on the phone is shown")
ok(gt:find("2. Sign in to Google Drive and type this code", 1, true) and gt:find("3. Tap Allow. This screen carries on by itself", 1, true), "the steps say what to do")
ok(gt:find("https://www.google.com/device", 1, true), "with the address for a reader with no camera")
ok(not findButton(gi, "Type the code"), "no code to type on the reader")
ok(view._sync_pending ~= nil, "the reader waits for the phone")
UIManager.fireScheduled()
ok(view._sync_signin ~= nil and view._sync_pending ~= nil, "not allowed yet: it keeps waiting")
UIManager.fireScheduled()
ok(view._sync_signin ~= nil, "still waiting on the second ask")
UIManager.fireScheduled()
ok(Account.load(Manager.dir()) ~= nil and Account.load(Manager.dir()).provider == "gdrive", "once allowed, the account is kept")
ok(view._sync_signin == nil and view._sync_pending == nil, "the waiting sheet closes by itself")
Manager.signOut()
Manager.live.result, Manager.live.running = nil, false
-- cancelling stops the asking
sent = {}
press(view._sync, "Connect Google Drive")
press(view._sync_signin, "Cancel")
ok(view._sync_pending == nil and view._sync_signin == nil, "Cancel stops waiting")
local before = #sent
UIManager.fireScheduled()
ok(#sent == before, "nothing is asked after Cancel")
G_reader_settings.data.inkaway_sync_gdrive_key = nil
G_reader_settings.data.inkaway_sync_gdrive_secret = nil
Http.transport = real_transport

------------------------------------------------------------------------------
-- connected
------------------------------------------------------------------------------
local dir = Manager.dir()
Account.save(dir, { provider = "dropbox", refresh_token = "RT", name = "Ada Lovelace", email = "a@x.org" })
local state = State.load(dir)
state.data.last = { at = os.time() - 300, uploaded = 2, downloaded = 1, conflicts = 0, errors = 0 }
state:save()
view:closeSheet("_sync")
view:openSync()
sheet = view._sync
t = textIn(sheet)
ok(t:find("Dropbox", 1, true) and t:find("Ada Lovelace", 1, true), "the account is shown")
ok(t:find("Synced 5 min ago", 1, true), "when it last synced, in words")
ok(findButton(sheet, "Sync now"), "Sync now")
ok(findButton(sheet, "After closing a notebook"), "the automatic choices are labelled")
ok(findButton(sheet, "Get the latest when opening one") and findButton(sheet, "When the reader goes to sleep"), "all of them")
ok(findButton(sheet, "Allow turning on Wi-Fi"), "Wi-Fi is the person's choice")
for _i, label in ipairs({ "Notebooks and drawings", "Book notes", "Ink on book pages", "Imported PDFs and pictures", "Exports", "Screen clips", "Pens, colours and preferences" }) do
    ok(findButton(sheet, label), label .. " can be turned on or off on its own")
end
ok(t:find("What to sync", 1, true) and t:find("KOReader's own highlights are not included", 1, true), "each part says what it holds")
local parts = Manager.areas()
ok(#parts == 7 and parts[1].on and parts[2].on and not parts[3].on, "the parts start as they always were, the new ones off")
Manager.setArea("exports", true)
ok(Manager.areas()[5].on == true, "turning a part on is remembered")
Manager.setArea("exports", false)
ok(t:find("After I stop drawing", 1, true) and t:find("Also every", 1, true), "the timer choices")
ok(findButton(sheet, "Disconnect") and findButton(sheet, "Sync log"), "log and disconnect")
ok(not findButton(sheet, "Conflicts (1)"), "no conflicts line when there are none")

-- a timer choice is remembered
press(sheet, "1 min")
ok(G_reader_settings.data.inkaway_sync_pause == 60, "the pause after drawing is remembered")
press(view._sync, "30m")
ok(G_reader_settings.data.inkaway_sync_interval == 30, "so is the timer")
press(view._sync, "Off")
G_reader_settings.data.inkaway_sync_pause = nil
G_reader_settings.data.inkaway_sync_interval = nil

-- an error on the sheet, with its code
Manager.live.result = { fatal = { code = "IA-S101" } }
view:rebuildSheet("_sync")
t = textIn(view._sync)
ok(t:find("Stopped: No connection", 1, true), "a stopped sync says why")
ok(t:find("Code IA-S101", 1, true), "with its code")
ok(findButton(view._sync, "Details"), "and what to do about it")
press(view._sync, "Details")
local es = view._sync_error
t = textIn(es)
ok(t:find("No connection", 1, true) and t:find("Turn on Wi-Fi", 1, true) and t:find("Code IA-S101", 1, true), "the error sheet: title, advice, code")
ok(findButton(es, "Try again"), "a retryable error offers to try again")
view:closeSheet("_sync_error")
Manager.live.result = nil

-- every error in the catalogue builds a sheet, with a code in the right form
local n = 0
for code, info in pairs(Errors.CATALOGUE) do
    n = n + 1
    ok(code:match("^IA%-S%d%d%d$"), code .. " has a proper code")
    ok(info.title ~= "" and info.what ~= "" and info.fix ~= "", code .. " says what happened and what to do")
    view:syncErrorSheet(code)
    ok(view._sync_error ~= nil and textIn(view._sync_error):find(code, 1, true), code .. " shows its code")
    view:closeSheet("_sync_error")
end
ok(n >= 25, "the catalogue is complete")

-- the sheets for the special errors have their own actions
view:syncErrorSheet("IA-S505")
ok(findButton(view._sync_error, "Delete anyway\u{2026}"), "many deletions can be confirmed, never by accident")
view:closeSheet("_sync_error")
view:syncErrorSheet("IA-S506")
ok(findButton(view._sync_error, "Sync this folder as a new library"), "a moved library can be started afresh")
view:closeSheet("_sync_error")
view:syncErrorSheet("IA-S202")
ok(findButton(view._sync_error, "Connect again"), "a lost sign-in offers to connect again")
view:closeSheet("_sync_error")

-- the result of a sync
view:syncShowResult({ uploaded = 2, downloaded = 3, conflicts = 1, deleted = 0, waiting = 1, errors = { { rel = "School/Bio.inkaway", code = "IA-S403" } }, warnings = {} })
local rs = view._sync_result
t = textIn(rs)
ok(t:find("2 sent to the cloud", 1, true) and t:find("2 received", 1, true) and t:find("1 kept in two versions", 1, true), "counts in words")
ok(t:find("IA-S403", 1, true) and t:find("Bio.inkaway", 1, true), "a problem names its code and the notebook")
ok(findButton(rs, "Look at the conflicts"), "conflicts are one tap away")
view:closeSheet("_sync_result")
view:syncShowResult({ uploaded = 0, downloaded = 0, conflicts = 0, errors = {}, warnings = {} })
ok(textIn(view._sync_result):find("Everything is already in sync", 1, true), "nothing to do says so")
view:closeSheet("_sync_result")

------------------------------------------------------------------------------
-- conflicts
------------------------------------------------------------------------------
local root = Manager.root()
os.execute("mkdir -p '" .. root .. "'")
local function put(rel, s) local f = assert(io.open(root .. "/" .. rel, "wb")); f:write(s); f:close() end
local function get(rel) local f = io.open(root .. "/" .. rel, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
put("Cx.inkaway", "ORIG"); put("Cx (conflict B 2026-11-03).inkaway", "COPY")
state = State.load(dir)
state.data.conflicts = { { orig = "Cx.inkaway", copy = "Cx (conflict B 2026-11-03).inkaway", at = os.time(), device = "B" } }
state:save()
view:closeSheet("_sync")
view:openSync()
ok(findButton(view._sync, "Conflicts (1)"), "a conflict shows on the sheet")
press(view._sync, "Conflicts (1)")
local cs = view._sync_conflicts
ok(cs ~= nil and findButton(cs, "Cx"), "the conflict list names the notebook")
press(cs, "Cx")
local c1 = view._sync_conflict
t = textIn(c1)
ok(findButton(c1, "Use the copy") and findButton(c1, "Keep the original") and findButton(c1, "Keep both"), "three ways to settle it")
ok(t:find("backup folder", 1, true), "the safety copy is promised in words")
press(c1, "Use the copy")
ok(get("Cx.inkaway") == "COPY", "using the copy does it")
ok(get("Cx (conflict B 2026-11-03).inkaway") == nil, "and the copy is no longer there twice")

------------------------------------------------------------------------------
-- log, rename, disconnect, hooks
------------------------------------------------------------------------------
Manager.log("hello from the test")
view:syncLog()
ok(textIn(view._sync_log):find("hello from the test", 1, true), "the log shows its lines")
view:closeSheet("_sync_log")
press(view._sync, "Name: " .. Manager.deviceName())
ok(view._prompt ~= nil, "the reader's name can be changed")
view:closeSheet("_prompt")
press(view._sync, "Disconnect")
local ask = view._ask
ok(ask ~= nil and textIn(ask):find("stay as they are", 1, true), "disconnecting says the notebooks stay")
ask.ok_callback()
ok(not Manager.connected(), "disconnected: the account is gone")
ok(G_reader_settings.data.inkaway_sync_enabled == false, "and syncing is off")
ok(findButton(view._sync, "Connect Dropbox"), "the sheet goes back to offering to connect")

-- the library menu has the entry
view:closeSheet("_sync")
view:libraryMenu()
ok(findButton(view._library_menu, "Cloud sync\u{2026}"), "the library menu has Cloud sync")
view:closeSheet("_library_menu")

-- pre-open does nothing unless sync is on and connected
local opened = false
ok(view:syncPreOpen(root .. "/x.inkaway", function() opened = true end) == false, "no check before a notebook opens when not connected")

os.execute("rm -rf '" .. BASE .. "'")
print(string.format("sync view: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
