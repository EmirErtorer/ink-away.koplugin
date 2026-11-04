-- The pieces around the sync engine: when it runs (schedule), the account file,
-- the background-process file protocol (runner), and what the manager does with
-- conflict copies and the log. Needs KOReader's SHA-2 code (KO_SRC).
--   luajit tests/sync/manager.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
require("testenv")
local BASE = (os.getenv("INKAWAY_TMP") or "/tmp") .. "/inkaway-sync-mgr-" .. os.time()
os.execute("rm -rf '" .. BASE .. "'; mkdir -p '" .. BASE .. "/data/ink away'")
package.loaded["datastorage"] = { getDataDir = function() return BASE .. "/data" end, getSettingsDir = function() return BASE .. "/data/settings" end }
local SETTINGS = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return SETTINGS[k] end,
    saveSetting = function(_, k, v) SETTINGS[k] = v end,
}

local Account = require("ink/sync/account")
local Config = require("ink/sync/config")
local Errors = require("ink/sync/errors")
local Manager = require("ink/sync/manager")
local Runner = require("ink/sync/runner")
local Schedule = require("ink/sync/schedule")
local State = require("ink/sync/state")
local Storage = require("ink/storage")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end
local function read(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function write(path, data)
    os.execute("mkdir -p '" .. path:match("^(.*)/[^/]*$") .. "'")
    local f = assert(io.open(path, "wb")); f:write(data); f:close()
end

------------------------------------------------------------------------------
-- schedule
------------------------------------------------------------------------------
local o = Schedule.options(function() return nil end)
eq(o.enabled, false, "off until switched on")
eq(o.on_close, true, "sends on closing by default")
eq(o.on_open, true, "checks on opening by default")
eq(o.wifi_on, false, "never turns Wi-Fi on by default")
eq(o.interval_min, 0, "no timer by default")
local on = { enabled = true, on_close = true, on_open = true, on_sleep = false, pause_s = 60, interval_min = 30 }
local NOW = 100000
eq(Schedule.due(on, "manual", NOW, {}), true, "manual always")
eq(Schedule.due({ enabled = false }, "manual", NOW, {}), true, "manual even when automatic is off")
eq(Schedule.due({ enabled = false, on_close = true }, "close", NOW, { dirty = true }), false, "nothing automatic when off")
eq(Schedule.due(on, "manual", NOW, { running = true }), false, "never two runs at once")
eq(Schedule.due(on, "close", NOW, { dirty = true }), true, "close with a change")
eq(Schedule.due(on, "close", NOW, { dirty = false }), false, "close with nothing to send")
eq(Schedule.due(on, "pause", NOW, { dirty = true }), true, "a pause after a change")
eq(Schedule.due({ enabled = true, pause_s = 0 }, "pause", NOW, { dirty = true }), false, "pause off")
eq(Schedule.due(on, "interval", NOW, { last = NOW - 1900 }), true, "interval overdue")
eq(Schedule.due(on, "interval", NOW, { last = NOW - 600 }), false, "interval not yet")
eq(Schedule.due(on, "close", NOW, { dirty = true, last = NOW - 10 }), false, "a gap between automatic runs")
eq(Schedule.due(on, "manual", NOW, { last = NOW - 1 }), true, "but not for the person")
eq(Schedule.due(on, "sleep", NOW, { dirty = true }), false, "sleep off")
eq(Schedule.due({ enabled = true, on_sleep = true }, "sleep", NOW, { dirty = true }), true, "sleep on, with a change")
eq(Schedule.backoff(0), 0, "no wait with no failures")
eq(Schedule.backoff(1), 60, "a minute after one failure")
eq(Schedule.backoff(3), 240, "longer after more")
eq(Schedule.backoff(30), 3600, "never more than an hour")
eq(Schedule.due(on, "close", NOW, { dirty = true, last = NOW - 100, failures = 3 }), false, "backs off after failures")
eq(Schedule.due(on, "close", NOW, { dirty = true, last = NOW - 300, failures = 3 }), true, "and tries again later")

------------------------------------------------------------------------------
-- account
------------------------------------------------------------------------------
local dir = Manager.dir()
eq(Account.load(dir), nil, "no account to begin with")
ok(Account.save(dir, { provider = "dropbox", refresh_token = "RT", name = "Ada" }), "saved")
eq(Account.load(dir).name, "Ada", "read back")
local mode = io.popen("ls -l '" .. dir .. "/account.lua'"):read("*l")
ok(mode:match("^%-rw%-%-%-%-%-%-%-"), "only the owner can read it")
write(dir .. "/account.lua", "return {provider=1}")
eq(Account.load(dir), nil, "a damaged file is no account")
Account.clear(dir)
ok(not read(dir .. "/account.lua"), "cleared")
ok(Account.defaultDeviceName() ~= "", "a device name")

------------------------------------------------------------------------------
-- config and signing in
------------------------------------------------------------------------------
eq(Config.appKey("dropbox", function() return nil end), nil, "no key is registered in this build")
eq(Config.appKey("dropbox", function() return "abcdefgh12345678" end), "abcdefgh12345678", "a key the person entered")
eq(Config.appKey("dropbox", function() return "bad key!" end), nil, "a key with odd characters is refused")
local _, e = Manager.beginSignIn("dropbox")
eq(e.code, "IA-S204", "no app key says so instead of opening a broken address")
SETTINGS.inkaway_sync_dropbox_key = "abcdefgh12345678"
local pending = Manager.beginSignIn("dropbox")
ok(pending and pending.url:find("client_id=abcdefgh12345678", 1, true), "with a key, an address to open")
eq(select(2, Manager.beginSignIn("nothing")).code, "IA-S503", "an unknown service")
SETTINGS.inkaway_sync_dropbox_key = nil

------------------------------------------------------------------------------
-- runner file protocol
------------------------------------------------------------------------------
do
    local started, why = Manager.run("manual", {})
    eq(started, false, "nothing runs without an account")
    eq(why, "account", "and it says why, so a busy reader is not called signed out")
end
local rd = BASE .. "/runner"
os.execute("mkdir -p '" .. rd .. "'")
local res = Runner.execute(rd, function(report, stop)
    report({ phase = "files", done = 1, total = 3, rel = "a" })
    return { uploaded = 2, stopped = stop() }
end)
eq(res.uploaded, 2, "the work's result comes back")
eq(Runner.readResult(rd).uploaded, 2, "and is in the result file")
eq(Runner.readProgress(rd).rel, "a", "progress is in its file")
Runner.requestStop(rd)
eq(Runner.stopRequested(rd), true, "a stop request is seen")
res = Runner.execute(rd, function(_, stop) return { stopped = stop() } end)
eq(res.stopped, true, "the work sees it")
-- a request left over from an earlier run never stops a later one
Runner.requestStop(rd, "run-1")
res = Runner.execute(rd, function(_, stop) return { stopped = stop() } end, "run-2")
eq(res.stopped, false, "a stop meant for another run is not obeyed")
res = Runner.execute(rd, function(_, stop) return { stopped = stop() } end, "run-1")
eq(res.stopped, true, "a stop for this run is")
os.remove(rd .. "/stop")
res = Runner.execute(rd, function() error("boom") end)
ok(res.crashed and res.crashed:find("boom"), "a crash in the work is a result, not silence")

------------------------------------------------------------------------------
-- conflicts
------------------------------------------------------------------------------
local root = Manager.root()
ok(root:find("ink away", 1, true), "the library folder is the default one")
write(root .. "/Math.inkaway", "ORIGINAL")
write(root .. "/Math (conflict B 2026-11-03).inkaway", "COPY")
local st = State.load(dir)
st.data.conflicts = { { orig = "Math.inkaway", copy = "Math (conflict B 2026-11-03).inkaway", at = 1, device = "B" } }
st:save()
local list = Manager.conflicts()
eq(#list, 1, "one conflict to settle")
eq(list[1].has_orig, true, "both files are there")
ok(Manager.resolveConflict("Math (conflict B 2026-11-03).inkaway", "copy"), "keep the copy")
eq(read(root .. "/Math.inkaway"), "COPY", "the copy replaced the original")
ok(not read(root .. "/Math (conflict B 2026-11-03).inkaway"), "and is gone under its old name")
local bk = io.popen("find '" .. Manager.backupDir() .. "' -name 'Math.inkaway'"):read("*l")
eq(read(bk), "ORIGINAL", "the replaced original is in the backup folder")
eq(#Manager.conflicts(), 0, "the conflict is settled")

write(root .. "/Bio.inkaway", "ORIG2")
write(root .. "/Bio (conflict B 2026-11-03).inkaway", "COPY2")
st = State.load(dir)
st.data.conflicts = { { orig = "Bio.inkaway", copy = "Bio (conflict B 2026-11-03).inkaway", at = 1, device = "B" } }
st:save()
ok(Manager.resolveConflict("Bio (conflict B 2026-11-03).inkaway", "original"), "keep the original")
eq(read(root .. "/Bio.inkaway"), "ORIG2", "the original stays")
ok(not read(root .. "/Bio (conflict B 2026-11-03).inkaway"), "the copy is gone")
bk = io.popen("find '" .. Manager.backupDir() .. "' -name 'Bio (conflict*'"):read("*l")
eq(read(bk), "COPY2", "but kept in the backup folder")

write(root .. "/Art.inkaway", "A")
write(root .. "/Art (conflict B 2026-11-03).inkaway", "B")
st = State.load(dir)
st.data.conflicts = { { orig = "Art.inkaway", copy = "Art (conflict B 2026-11-03).inkaway", at = 1, device = "B" } }
st:save()
ok(Manager.resolveConflict("Art (conflict B 2026-11-03).inkaway", "both"), "keep both")
eq(read(root .. "/Art.inkaway"), "A", "the original is untouched")
eq(read(root .. "/Art (conflict B 2026-11-03).inkaway"), "B", "so is the copy")
eq(#Manager.conflicts(), 0, "and the question is closed")
eq(select(2, Manager.resolveConflict("x", "nonsense")), nil, "an unknown copy is simply done")

------------------------------------------------------------------------------
-- paths, the open list and the log
------------------------------------------------------------------------------
eq(Manager.relOf(root .. "/School/Bio.inkaway"), "School/Bio.inkaway", "a path inside the library")
eq(Manager.relOf("/elsewhere/x.inkaway"), nil, "a path outside it")
Manager.setOpen({ "School/Bio.inkaway" })
eq(read(dir .. "/open.txt"), "school/bio.inkaway", "the open notebooks are listed in lower case")
for i = 1, 3000 do Manager.log(string.rep("x", 60) .. i) end
local logsize = Storage.size(dir .. "/log.txt")
ok(logsize < 110 * 1024, "the log stays small")
ok(#Manager.logTail(5) == 5 and Manager.logTail(5)[5]:find("3000"), "the tail has the newest lines")
local s = Manager.status()
eq(s.connected, false, "not connected")
eq(s.running, false, "not running")

-- preferences: settings into a file before a run, a file from another reader back into settings after
eq(Manager.writePrefs(), nil, "with the part off nothing is written")
SETTINGS.inkaway_sync_area_settings = true
SETTINGS.inkaway_accent = "green"
SETTINGS.inkaway_library_dir = "/mine"
local wrote = Manager.writePrefs()
ok(wrote and wrote:find("green", 1, true) and not wrote:find("/mine", 1, true), "the chosen preferences are written, not the reader's own folders")
local pf = io.open(Manager.prefsPath(), "wb"); pf:write('{"inkaway_accent":"blue","inkaway_library_dir":"/theirs"}'); pf:close()
Manager.readPrefs(wrote)
eq(SETTINGS.inkaway_accent, "blue", "a preference that came from another reader is applied")
eq(SETTINGS.inkaway_library_dir, "/mine", "a setting outside the list is never changed by a file")
local again = Manager.writePrefs()
ok(again and again:find("blue", 1, true), "and the next run writes what the settings now say")
SETTINGS.inkaway_sync_area_settings = nil

print(string.format("manager: %d checks, %d failed", checks, fails))
os.execute("rm -rf '" .. BASE .. "'")
os.exit(fails == 0 and 0 or 1)
