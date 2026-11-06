-- The sync engine (ink/sync/engine.lua) against a pretend cloud: two readers
-- with their own folders share it. Every rule that keeps notebooks safe is
-- checked here. Needs KOReader's SHA-2 code (KO_SRC, default ~/koreader-emulator).
--   luajit tests/sync/engine.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
require("testenv")
local Engine = require("ink/sync/engine")
local Errors = require("ink/sync/errors")
local Project = require("ink/project")
local State = require("ink/sync/state")
local Storage = require("ink/storage")
local Mock = require("sync/mockcloud")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function write(path, data)
    os.execute("mkdir -p '" .. path:match("^(.*)/[^/]*$") .. "'")
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local BASE = (os.getenv("INKAWAY_TMP") or "/tmp") .. "/inkaway-sync-test-" .. os.time()
os.execute("rm -rf '" .. BASE .. "'; mkdir -p '" .. BASE .. "'")

-- a notebook file that reads back as one
local function doc(n, extra)
    return string.format('return {["w"]=600,["h"]=800,["pages"]={{["ops"]={},["n"]=%d}},%s}', n, extra or "")
end

local clock = 1000000
local function reader(cloud, name)
    local dir = BASE .. "/" .. name
    os.execute("mkdir -p '" .. dir .. "/lib' '" .. dir .. "/sync'")
    return { name = name, root = dir .. "/lib", sync = dir .. "/sync", backup = dir .. "/backup",
        provider = Mock.provider(cloud, name), state = State.load(dir .. "/sync") }
end
local function run(r, o)
    o = o or {}
    clock = clock + 100
    local ctx = { root = r.root, provider = r.provider, state = r.state, backup_dir = r.backup, device = r.name,
        now = function() return clock end, sleep = function(s) r.slept = (r.slept or 0) + s end,
        validate = function(rel, path)
            if not rel:match("%.inkaway$") then return true end
            if Project.load(path) then return true end
            return false, "not a notebook"
        end,
        stop = o.stop, skip = o.skip, dry = o.dry, allow_mass_delete = o.allow, rebase = o.rebase, limits = o.limits }
    if not ctx.stop then ctx.stop = function() return false end end
    return Engine.run(ctx)
end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end return f ~= nil end
local function count(list, prefix) local n = 0 for _i, c in ipairs(list) do if c:sub(1, #prefix) == prefix then n = n + 1 end end return n end
local function clone(r) return State.load(r.sync) end

------------------------------------------------------------------------------
-- 1. a first sync sends everything; a second one does nothing
------------------------------------------------------------------------------
local cloud = Mock.cloud()
local A = reader(cloud, "A")
write(A.root .. "/Math.inkaway", doc(1))
write(A.root .. "/School/Bio.inkaway", doc(2))
write(A.root .. "/.inkaway-folder", "return {}")
local r = run(A)
eq(r.fatal, nil, "first run has no fatal error")
eq(r.uploaded, 3, "first run sends the three files")
ok(cloud.files["math.inkaway"] and cloud.files["school/bio.inkaway"], "the cloud has them under their own paths")
ok(cloud.files[".inkaway-sync.json"], "the cloud's layout version is written")
eq(#r.errors, 0, "no errors")
local moved = count(cloud.calls, "upload") + count(cloud.calls, "download")
r = run(A)
eq(r.uploaded + r.downloaded + r.conflicts + r.deleted, 0, "a second run changes nothing")
eq(count(cloud.calls, "upload") + count(cloud.calls, "download"), moved, "and moves no file (the layout file is not asked for again)")

------------------------------------------------------------------------------
-- 2. the other reader gets it, then an edit travels
------------------------------------------------------------------------------
local B = reader(cloud, "B")
r = run(B)
for _i, e in ipairs(r.errors) do print("  B error", e.rel, e.err.code, e.err.detail) end
eq(r.downloaded, 3, "reader B downloads the three files")
eq(read(B.root .. "/Math.inkaway"), doc(1), "same bytes")
eq(read(B.root .. "/School/Bio.inkaway"), doc(2), "same bytes in a folder")
write(A.root .. "/Math.inkaway", doc(11, '["note"]="written on A",'))
r = run(A)
eq(r.uploaded, 1, "A sends its edit")
r = run(B)
eq(r.downloaded, 1, "B gets the edit")
eq(read(B.root .. "/Math.inkaway"), doc(11, '["note"]="written on A",'), "B has A's version")
eq(r.conflicts, 0, "no conflict")
ok(exists(B.backup) and #(io.popen("ls '" .. B.backup .. "'"):read("*a")) > 0, "B's old file was backed up before it was replaced")

------------------------------------------------------------------------------
-- 3. both change the same file: both are kept
------------------------------------------------------------------------------
write(A.root .. "/Math.inkaway", doc(21, '["by"]="A",'))
write(B.root .. "/Math.inkaway", doc(22, '["by"]="B, longer text",'))
r = run(A)
eq(r.uploaded, 1, "A sends first")
r = run(B)
eq(r.conflicts, 1, "B finds a conflict")
eq(read(B.root .. "/Math.inkaway"), doc(21, '["by"]="A",'), "the name holds the version already in the cloud")
local copy
for _i, c in ipairs(B.state.data.conflicts) do copy = c.copy end
ok(copy and copy:match("^Math %(conflict B %d+%-%d+%-%d+%)%.inkaway$"), "the copy is named for the reader and the day")
eq(read(B.root .. "/" .. copy), doc(22, '["by"]="B, longer text",'), "the copy holds B's version")
ok(cloud.files[copy:lower()], "the copy is in the cloud too")
r = run(A)
eq(read(A.root .. "/" .. copy), doc(22, '["by"]="B, longer text",'), "A receives the copy, nothing was lost")
eq(read(A.root .. "/Math.inkaway"), doc(21, '["by"]="A",'), "A keeps its own")

------------------------------------------------------------------------------
-- 4. deletions: they travel, and never beat an edit
------------------------------------------------------------------------------
write(A.root .. "/Old.inkaway", doc(30))
run(A); run(B)
os.remove(A.root .. "/Old.inkaway")
r = run(A)
eq(r.deleted, 1, "A deletes it in the cloud")
r = run(B)
eq(r.deleted, 1, "B removes its copy")
ok(not exists(B.root .. "/Old.inkaway"), "gone on B")
local found = io.popen("find '" .. B.backup .. "' -name Old.inkaway"):read("*l")
ok(found and found ~= "", "a copy of what B removed is in the backup folder")

write(A.root .. "/Keep.inkaway", doc(40))
run(A); run(B)
os.remove(A.root .. "/Keep.inkaway")
write(B.root .. "/Keep.inkaway", doc(41, '["edited"]=true,'))
run(A)           -- A tells the cloud it is deleted
r = run(B)       -- B has an edit: the file must survive and be sent again
ok(exists(B.root .. "/Keep.inkaway"), "an edited file is not deleted")
ok(cloud.files["keep.inkaway"], "and it is back in the cloud")
eq(r.errors[1], nil, "without an error")

------------------------------------------------------------------------------
-- 5. a download that arrives damaged is thrown away
------------------------------------------------------------------------------
write(A.root .. "/Fresh.inkaway", doc(50))
run(A)
cloud.corrupt_download = true
r = run(B)
ok(r.errors[1] and r.errors[1].err.code == "IA-S403", "a damaged download is IA-S403")
ok(not exists(B.root .. "/Fresh.inkaway"), "nothing half-written is left")
ok(not exists(B.root .. "/Fresh.inkaway" .. Engine.TMP), "and no temporary file")
r = run(B)
eq(read(B.root .. "/Fresh.inkaway"), doc(50), "it comes right the next time")

-- a file that is not a notebook is refused by the check
Mock.put(cloud, "Broken.inkaway", "this is not a notebook")
r = run(B)
ok(not exists(B.root .. "/Broken.inkaway"), "a file that does not read as a notebook is not installed")
ok(r.errors[1] and r.errors[1].err.code == "IA-S403", "and says so")
Mock.provider(cloud):delete("Broken.inkaway")
run(B)

------------------------------------------------------------------------------
-- 6. a file open in the editor, or changed during the run, is left alone
------------------------------------------------------------------------------
write(A.root .. "/Busy.inkaway", doc(60))
run(A); run(B)
write(A.root .. "/Busy.inkaway", doc(61, '["a"]=1,'))
run(A)
r = run(B, { skip = function(key) return key == "busy.inkaway" end })
eq(r.waiting, 1, "an open notebook waits")
eq(read(B.root .. "/Busy.inkaway"), doc(60), "and is not replaced")
r = run(B)
eq(read(B.root .. "/Busy.inkaway"), doc(61, '["a"]=1,'), "it arrives once closed")

write(A.root .. "/Race.inkaway", doc(70))
run(A); run(B)
write(A.root .. "/Race.inkaway", doc(71, '["a"]=1,'))
run(A)
cloud.hook = function(op, rel)   -- the person saves on B while the download runs
    if op == "download" and rel == "Race.inkaway" then write(B.root .. "/Race.inkaway", doc(72, '["b"]=2,')) end
end
r = run(B)
cloud.hook = nil
eq(read(B.root .. "/Race.inkaway"), doc(72, '["b"]=2,'), "a save made during the download is not overwritten")
eq(r.waiting, 1, "the file is marked busy")
r = run(B)
eq(r.conflicts, 1, "next time it is a conflict, both versions kept")

------------------------------------------------------------------------------
-- 7. failures: retried when they pass, stop the run when they cannot
------------------------------------------------------------------------------
write(A.root .. "/Net.inkaway", doc(80))
cloud.faults.upload = { Errors.make("IA-S302", "slow down", 3), "pass" }
r = run(A)
eq(r.uploaded, 1, "a rate limit is waited out and retried")
ok((A.slept or 0) >= 3, "it waited as long as the cloud asked")
write(A.root .. "/Net2.inkaway", doc(81))
cloud.faults.upload = { Errors.make("IA-S101"), Errors.make("IA-S101"), Errors.make("IA-S101") }
r = run(A)
eq(r.fatal and r.fatal.code, "IA-S101", "no connection stops the run")
eq(r.uploaded, 0, "nothing was claimed as sent")
cloud.faults.upload = nil
r = run(A)
eq(r.uploaded, 1, "the next run carries on")
write(A.root .. "/Full.inkaway", doc(82))
cloud.faults.upload = { Errors.make("IA-S301") }
r = run(A)
eq(r.fatal and r.fatal.code, "IA-S301", "a full cloud stops the run")
cloud.faults.upload = nil
run(A)

cloud.faults.list = { Errors.make("IA-S202") }
r = run(A)
eq(r.fatal and r.fatal.code, "IA-S202", "a refused sign-in stops the run before touching files")

------------------------------------------------------------------------------
-- 8. a run cut short carries on
------------------------------------------------------------------------------
for i = 1, 5 do write(A.root .. "/Batch" .. i .. ".inkaway", doc(100 + i)) end
local done = 0
r = run(A, { stop = function() done = done + 1; return done > 4 end })
ok(r.fatal and r.fatal.code == "IA-S502", "stopping is reported")
ok(r.uploaded >= 1 and r.uploaded < 5, "some files went")
r = run(A)
for _i, e in ipairs(r.errors) do print("  resume error", e.rel, e.err.code, e.err.detail) end
eq(r.errors[1], nil, "resuming has no errors")
for i = 1, 5 do ok(cloud.files["batch" .. i .. ".inkaway"], "batch " .. i .. " reached the cloud") end
eq(run(A).uploaded, 0, "and nothing is sent twice")

------------------------------------------------------------------------------
-- 9. safety nets
------------------------------------------------------------------------------
-- a cloud written by a newer Ink Away is not touched
local N = Mock.cloud()
Mock.put(N, ".inkaway-sync.json", '{"schema":99}')
Mock.put(N, "X.inkaway", doc(1))
local C = reader(N, "C")
write(C.root .. "/Mine.inkaway", doc(2))
r = run(C)
eq(r.fatal and r.fatal.code, "IA-S501", "a newer layout stops the run")
ok(not exists(C.root .. "/X.inkaway") and not N.files["mine.inkaway"], "and nothing moved")

-- a dry run only says what it would do
local D = reader(cloud, "D")
write(D.root .. "/Own.inkaway", doc(3))
local before = #cloud.calls
r = run(D, { dry = true })
eq(r.fatal, nil, "dry run works")
ok(r.plan and #r.plan > 3, "it lists the plan")
ok(not exists(D.root .. "/Math.inkaway"), "and downloads nothing")
ok(not cloud.files["own.inkaway"], "and sends nothing")
eq(count(cloud.calls, "upload") - count({ unpack(cloud.calls, 1, before) }, "upload"), 0, "no upload calls")

-- unsafe names from the cloud are ignored
Mock.put(cloud, "../escape.inkaway", doc(9))
Mock.put(cloud, "/abs.inkaway", doc(9))
Mock.put(cloud, "a/../../b.inkaway", doc(9))
r = run(B)
ok(not exists(BASE .. "/B/escape.inkaway") and not exists(BASE .. "/B/lib/../escape.inkaway"), "a name that climbs out of the library is ignored")
ok(not exists("/abs.inkaway"), "an absolute name is ignored")

-- many deletions at once: stopped
local E = reader(cloud, "E")
for i = 1, 8 do write(E.root .. "/Many" .. i .. ".inkaway", doc(200 + i)) end
run(E)
for i = 1, 8 do os.remove(E.root .. "/Many" .. i .. ".inkaway") end
r = run(E)
eq(r.deleted, 0, "a run that would delete most of the library deletes nothing")
ok(r.errors[1] and r.errors[1].err.code == "IA-S505", "and says IA-S505")
ok(cloud.files["many1.inkaway"], "the cloud still has them")
r = run(E, { allow = true })
eq(r.deleted, 8, "unless the person has confirmed")

-- the library folder moved
local F = reader(cloud, "F")
write(F.root .. "/Z.inkaway", doc(5))
run(F)
F.root = F.root .. "2"
os.execute("mkdir -p '" .. F.root .. "'")
r = run(F)
eq(r.fatal and r.fatal.code, "IA-S506", "a different library folder is not synced as if nothing happened")
ok(cloud.files["z.inkaway"], "and the cloud keeps its file")

-- both sides already hold the same file: no conflict
local G = reader(cloud, "G")
write(G.root .. "/Same.inkaway", doc(77))
Mock.put(cloud, "Same.inkaway", doc(77))
r = run(G)
eq(r.conflicts, 0, "identical files on both sides are adopted, not duplicated")
local moved_same = false
for _i, it in ipairs(r.items) do if it.rel == "Same.inkaway" and it.action ~= "adopt" then moved_same = true end end
ok(not moved_same, "without moving a byte")

-- a name differing only in capitals
local H = reader(cloud, "H")
write(H.root .. "/Case.inkaway", doc(1))
write(H.root .. "/CASE.inkaway", doc(3))
local n_case = 0
for _i, e in ipairs(Storage.list(H.root)) do if e.name:lower() == "case.inkaway" then n_case = n_case + 1 end end
if n_case == 2 then   -- (a case-insensitive disk, like a Mac's, cannot hold both)
    r = run(H)
    ok(#r.warnings >= 1 and r.warnings[1].err.code == "IA-S404", "two names that differ only in capitals are reported")
end

------------------------------------------------------------------------------
-- 10. pictures and PDFs a notebook uses
------------------------------------------------------------------------------
local I = reader(cloud, "I")
write(I.root .. "/Images/pic.png", "PNGDATA-inside")
write(BASE .. "/I/outside/photo.png", "PNGDATA-outside")
write(I.root .. "/Pics.inkaway", doc(1, string.format('["x"]={["kind"]="image",["path"]="%s/Images/pic.png"},["y"]={["kind"]="image",["path"]="%s"},',
    I.root, BASE .. "/I/outside/photo.png")))
r = run(I)
ok(cloud.files["images/pic.png"], "a picture inside the library goes with the notebook")
local Portable = require("ink/sync/portable")
local att = Portable.attachRel(BASE .. "/I/outside/photo.png")
ok(cloud.files[att:lower()], "a picture outside the library is brought into .attachments and sent")
ok(exists(I.root .. "/" .. att), "its copy is kept on the reader")
eq(read(BASE .. "/I/outside/photo.png"), "PNGDATA-outside", "the original is untouched")
local J = reader(cloud, "J")
r = run(J)
ok(exists(J.root .. "/Images/pic.png") and exists(J.root .. "/" .. att), "the other reader receives both")
local data = Project.load(J.root .. "/Pics.inkaway")
local pics = {}
local tmpdoc = BASE .. "/J/pics-read.lua"
write(tmpdoc, read(J.root .. "/Pics.inkaway"))
local raw = assert(loadfile(tmpdoc))()
raw.pages[1].ops = { raw.x, raw.y }
local still = raw.x.path
Portable.apply(raw, J.root)
eq(raw.x.path, still, "(a path that exists here is left as it is)")
os.execute("rm -rf '" .. I.root .. "' '" .. BASE .. "/I/outside'")   -- as if I were another device
raw = assert(loadfile(tmpdoc))()
raw.pages[1].ops = { raw.x, raw.y }
Portable.apply(raw, J.root)
eq(raw.pages[1].ops[1].path, J.root .. "/Images/pic.png", "a picture inside the library is found under this reader's folder")
eq(raw.pages[1].ops[2].path, J.root .. "/" .. att, "a picture from elsewhere is found among the attachments")
ok(data ~= nil, "the notebook reads on the other reader")

print(string.format("engine: %d checks, %d failed", checks, fails))
os.execute("rm -rf '" .. BASE .. "'")
os.exit(fails == 0 and 0 or 1)
