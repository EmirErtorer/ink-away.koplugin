-- Google Drive and OneDrive (ink/sync/providers/gdrive.lua, onedrive.lua) against
-- pretend services that behave as their APIs do (tests/sync/fakegdrive.lua,
-- fakeonedrive.lua): the sign-in, then the real sync engine run by two readers that
-- share one cloud, as the sync does it, with a new provider object every run.
--   luajit tests/sync/clouds.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
require("testenv")
local Engine = require("ink/sync/engine")
local Errors = require("ink/sync/errors")
local Hash = require("ink/sync/hash")
local Http = require("ink/sync/http")
local Json = require("ink/sync/json")
local Project = require("ink/project")
local State = require("ink/sync/state")

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
local function doc(n) return string.format('return {["w"]=600,["h"]=800,["pages"]={{["ops"]={},["n"]=%d}}}', n) end

local BASE = (os.getenv("INKAWAY_TMP") or "/tmp") .. "/inkaway-clouds-test-" .. os.time()
os.execute("rm -rf '" .. BASE .. "'; mkdir -p '" .. BASE .. "'")

local current
Http.transport = function(spec) return current.transport(spec) end
local function scripted(fn) local old = current; current = { transport = fn }; return function() current = old end end

local clock = 1000000
local function files(dir)
    local out = {}
    local p = io.popen("cd '" .. dir .. "' && find . -type f ! -name '.*' | sort")
    for l in p:lines() do out[#out + 1] = l:sub(3) end
    p:close()
    return out
end

------------------------------------------------------------------------------
-- the engine on a provider, two readers
------------------------------------------------------------------------------
local function suite(label, Provider, Fake, newAccount, expect_hash_prefix)
    local fake = Fake.new()
    current = fake
    local function reader(name)
        local dir = BASE .. "/" .. label .. "-" .. name
        os.execute("mkdir -p '" .. dir .. "/lib' '" .. dir .. "/sync'")
        local acct = newAccount()
        return { name = name, root = dir .. "/lib", sync = dir .. "/sync", backup = dir .. "/backup", acct = acct,
            state = State.load(dir .. "/sync") }
    end
    local function run(r, o)
        o = o or {}
        clock = clock + 100
        r.state = State.load(r.sync)
        local p = Provider.new(r.acct, { app_key = "KEY", app_secret = "SECRET", dir = r.sync, now = function() return clock end,
            save = function() end })
        return Engine.run({ root = r.root, provider = p, state = r.state, backup_dir = r.backup, device = r.name,
            now = function() return clock end, sleep = function() end, stop = function() return false end,
            validate = function(rel, path)
                if not rel:match("%.inkaway$") then return true end
                return Project.load(path) and true or false, "not a notebook"
            end })
    end
    local function errors(r, who)
        for _i, e in ipairs(r.errors or {}) do print("  " .. who .. " error", e.rel, e.err.code, e.err.detail) end
    end

    -- A sends three files, a second run does nothing
    local A, B = reader("A"), reader("B")
    write(A.root .. "/Math.inkaway", doc(1))
    write(A.root .. "/School/Bio.inkaway", doc(2))
    write(A.root .. "/.inkaway-folder", "return {}")
    local r = run(A)
    errors(r, "A")
    eq(r.fatal, nil, label .. ": first run has no fatal error")
    eq(r.uploaded, 3, label .. ": first run sends the three files")
    eq(#r.errors, 0, label .. ": no errors")
    ok(fake.content("Math.inkaway") == doc(1) and fake.content("School/Bio.inkaway") == doc(2), label .. ": the cloud has them under their own paths")
    local moved = fake.count("PUT") + fake.count("alt=media")
    r = run(A)
    eq(r.uploaded + r.downloaded + r.conflicts + r.deleted, 0, label .. ": a second run changes nothing")
    eq(fake.count("PUT") + fake.count("alt=media"), moved, label .. ": and sends nothing")

    -- the hidden areas folders (a book's ink and its readable label) go through the provider as any path
    do
        local p = Provider.new(A.acct, { app_key = "KEY", app_secret = "SECRET", dir = A.sync, now = function() return clock end,
            save = function() end })
        local tmp = BASE .. "/" .. label .. "-area.tmp"
        local deep = ".areas/books/0123456789abcdef0123456789abcdef"
        write(tmp, "return {}")
        local m1, e1 = p:upload(tmp, deep .. "/inkaway.lua")
        ok(m1, label .. ": a file deep in .areas goes up" .. (e1 and (" (" .. tostring(e1.code) .. ")") or ""))
        write(tmp, "Calculus - Spivak")
        local m2 = p:upload(tmp, deep .. "/inkaway-book-Calculus - Spivak.txt")
        ok(m2, label .. ": and so does its label, with spaces in the name")
        local listing = p:list(nil)
        local seen = {}
        for _i, e in ipairs(listing and listing.entries or {}) do seen[e.rel] = true end
        ok(seen[deep .. "/inkaway.lua"] and seen[deep .. "/inkaway-book-Calculus - Spivak.txt"], label .. ": both are listed under their paths")
        local got = BASE .. "/" .. label .. "-area.got"
        ok(p:download(deep .. "/inkaway-book-Calculus - Spivak.txt", m2 and m2.rev, got) and read(got) == "Calculus - Spivak",
            label .. ": the label comes back whole")
        ok(p:delete(deep .. "/inkaway.lua", m1 and m1.rev) and p:delete(deep .. "/inkaway-book-Calculus - Spivak.txt"),
            label .. ": and both can be removed")
    end

    -- B gets them, checked against the service's own hash
    r = run(B)
    errors(r, "B")
    eq(r.downloaded, 3, label .. ": the other reader downloads them")
    eq(read(B.root .. "/Math.inkaway"), doc(1), label .. ": the notebook arrived whole")
    eq(read(B.root .. "/School/Bio.inkaway"), doc(2), label .. ": and the one in a folder")

    -- an edit on A comes to B by the change feed, not a full listing
    local lists = fake.count("changes") + fake.count("delta")
    write(A.root .. "/Math.inkaway", doc(11))
    r = run(A)
    eq(r.uploaded, 1, label .. ": an edit is sent")
    r = run(B)
    eq(r.downloaded, 1, label .. ": the edit comes to the other reader")
    eq(read(B.root .. "/Math.inkaway"), doc(11), label .. ": with the new content")
    ok(fake.count("changes") + fake.count("delta") > lists, label .. ": it was found through the change feed")

    -- a deletion travels, and the file is kept in a backup on the reader that loses it
    os.remove(A.root .. "/School/Bio.inkaway")
    r = run(A)
    errors(r, "A")
    ok(fake.content("School/Bio.inkaway") == nil, label .. ": the file is gone from the cloud's folder (in its bin)")
    r = run(B)
    eq(r.deleted, 1, label .. ": the deletion reaches the other reader")
    ok(read(B.root .. "/School/Bio.inkaway") == nil, label .. ": the file is gone there")
    local saved = io.popen("find '" .. B.backup .. "' -name 'Bio.inkaway' | head -1"):read("*a")
    ok(saved:find("Bio.inkaway", 1, true), label .. ": a safety copy was made first")

    -- two edits of one notebook: both are kept
    write(A.root .. "/Math.inkaway", doc(21))
    write(B.root .. "/Math.inkaway", doc(22))
    r = run(A)
    r = run(B)
    eq(r.conflicts, 1, label .. ": the second reader sees a conflict")
    local n = 0
    for _i, f in ipairs(files(B.root)) do if f:find("^Math") then n = n + 1 end end
    eq(n, 2, label .. ": both versions are on the reader")
    eq(read(B.root .. "/Math.inkaway"), doc(21), label .. ": the cloud's version keeps the name")
    r = run(A)
    n = 0
    for _i, f in ipairs(files(A.root)) do if f:find("^Math") then n = n + 1 end end
    eq(n, 2, label .. ": the first reader gets the copy too")

    -- the map lost (a new reader state, or the file deleted): a full listing, same result
    os.remove(B.sync .. "/" .. Provider.id .. "-index.json")
    B.state:clear(); B.state:save()
    r = run(B)
    eq(r.fatal, nil, label .. ": without its map a reader lists everything again")
    eq(#r.errors, 0, label .. ": with no errors")

    -- a damaged download is thrown away
    write(A.root .. "/Fresh.inkaway", doc(31))
    run(A)
    fake.corrupt = true
    r = run(B)
    fake.corrupt = false
    eq(r.errors[1] and r.errors[1].err.code, "IA-S403", label .. ": a download that differs from the hash is IA-S403")
    ok(read(B.root .. "/Fresh.inkaway") == nil, label .. ": and nothing was written")
    r = run(B)
    eq(read(B.root .. "/Fresh.inkaway"), doc(31), label .. ": it comes right the next time")

    -- a change feed in several pages
    fake.page = 2
    for i = 1, 5 do write(A.root .. "/N" .. i .. ".inkaway", doc(40 + i)) end
    run(A)
    r = run(B)
    errors(r, "B")
    eq(r.downloaded, 5, label .. ": a feed in pages is read to its end")
    fake.page = 1000

    -- a very big file goes up and down in pieces
    local old_single, old_chunk = Provider.SINGLE_MAX or Provider.SIMPLE_MAX, Provider.CHUNK
    if Provider.SINGLE_MAX then Provider.SINGLE_MAX = 10 else Provider.SIMPLE_MAX = 10 end
    Provider.CHUNK = 7
    local p = Provider.new(A.acct, { app_key = "KEY", app_secret = "SECRET", dir = A.sync, now = function() return clock end })
    local src = BASE .. "/big.bin"
    write(src, "0123456789abcdefghijklmnopqrstuvwxyz-0123456789")
    local m, err = p:upload(src, "Deep/er/big.bin", nil)
    ok(m ~= nil, label .. ": a big file uploads in pieces " .. tostring(err and err.detail))
    eq(fake.content("Deep/er/big.bin"), read(src), label .. ": and arrives whole, in folders made on the way")
    local dest = BASE .. "/big.out"
    local got = p:download("Deep/er/big.bin", m and m.rev, dest)
    ok(got ~= nil and read(dest) == read(src), label .. ": and comes back whole")
    local again, aerr = p:upload(src, "Deep/er/big.bin", nil)
    eq(aerr and aerr.code, "IA-S305", label .. ": a file that must be new but is there is refused (IA-S305)")
    write(src, "changed once")
    local m2 = p:upload(src, "Deep/er/big.bin", m.rev)
    ok(m2 and m2.rev ~= m.rev, label .. ": an update on the known revision goes through")
    local stale, serr = p:upload(src, "Deep/er/big.bin", m.rev)
    eq(serr and serr.code, "IA-S305", label .. ": an update on an old revision is refused, nothing overwritten (IA-S305)")
    eq(fake.content("Deep/er/big.bin"), "changed once", label .. ": the newer content is still there")
    local ds, derr = p:delete("Deep/er/big.bin", m.rev)
    eq(derr and derr.code, "IA-S305", label .. ": a delete on an old revision is refused")
    ok(p:delete("Deep/er/big.bin", m2.rev), label .. ": a delete on the current one works")
    eq(select(2, p:download("Deep/er/big.bin", nil, dest)).code, "IA-S307", label .. ": a file that is gone is IA-S307")
    if Provider.SINGLE_MAX then Provider.SINGLE_MAX = old_single else Provider.SIMPLE_MAX = old_single end
    Provider.CHUNK = old_chunk

    -- earlier versions, and putting one back
    write(src, "version one")
    local v1 = p:upload(src, "Hist.txt", nil)
    write(src, "version two")
    p:upload(src, "Hist.txt", v1.rev)
    local revs = p:revisions("Hist.txt")
    ok(revs and #revs >= 2 and revs[1].current, label .. ": the versions are listed, the current first")
    local oldest = revs[#revs]
    local back, rerr = p:restore("Hist.txt", oldest.rev)
    ok(back ~= nil, label .. ": an earlier version can be put back " .. tostring(rerr and rerr.detail))
    eq(fake.content("Hist.txt"), "version one", label .. ": and is the content again")

    -- the hash of a local file is in the kind the service gives
    local sample = BASE .. "/sample.bin"
    write(sample, "hello")
    local h = p:hashFile(sample, fake.byPath("Hist.txt") and expect_hash_prefix or expect_hash_prefix)
    ok(h ~= nil, label .. ": a local hash can be made in the service's kind")
end

local Gdrive = require("ink/sync/providers/gdrive")
local Onedrive = require("ink/sync/providers/onedrive")
suite("gdrive", Gdrive, dofile("tests/sync/fakegdrive.lua"), function()
    return { provider = "gdrive", refresh_token = "R", access_token = "A", expires_at = 4e9 }
end, "")
suite("onedrive", Onedrive, dofile("tests/sync/fakeonedrive.lua"), function()
    return { provider = "onedrive", refresh_token = "R", access_token = "A", expires_at = 4e9 }
end, "sha1:")

------------------------------------------------------------------------------
-- OneDrive's other hash kind, and the quickXorHash itself
------------------------------------------------------------------------------
eq(Hash.quickXorOfString(""), "AAAAAAAAAAAAAAAAAAAAAAAAAAA=", "quickXorHash of nothing")
eq(Hash.quickXorOfString("J"), "SgAAAAAAAAAAAAAAAQAAAAAAAAA=", "quickXorHash of one byte (a published value)")
eq(Hash.quickXorOfString("\253\163\115\204\33\79\75\240"), "/RjFHJgRgicsAR4ACAAAAAAAAAA=", "quickXorHash of eight bytes (a published value)")
do
    local Fake = dofile("tests/sync/fakeonedrive.lua")
    local fake = Fake.new()
    fake.hashes = "qx"
    current = fake
    local acct = { provider = "onedrive", refresh_token = "R", access_token = "A", expires_at = 4e9 }
    local p = Onedrive.new(acct, { app_key = "KEY", dir = BASE })
    local src = BASE .. "/qx.txt"
    write(src, "quick xor data")
    local m = p:upload(src, "qx.txt", nil)
    ok(m and m.hash and m.hash:sub(1, 3) == "qx:", "a service that gives only the quickXorHash is handled")
    eq(p:hashFile(src, m.hash), m.hash, "and the same hash is made here")
    local listing = p:list(nil)
    eq(listing.entries[1].hash, m.hash, "the listing carries it too")
    eq(p:hashFile(src, "md5:abc"), nil, "a kind that is not known gives no hash (the download is then not checked by it)")
end

------------------------------------------------------------------------------
-- signing in, device flow
------------------------------------------------------------------------------
local function auth(label, Provider, begin_url, token_url, extra_check)
    local sent = {}
    local restore = scripted(function(spec)
        sent[#sent + 1] = spec
        if spec.url:find(begin_url, 1, true) then
            return { code = 200, headers = {}, body = Json.encode({ device_code = "DC", user_code = "WXYZ-1234",
                verification_url = "https://example.org/device", verification_uri = "https://example.org/link", interval = 5, expires_in = 900 }) }
        end
        return { code = 400, headers = {}, body = Json.encode({ error = "authorization_pending" }) }
    end)
    local pending = Provider.beginAuth("CLIENT-ID")
    eq(pending.kind, "device", label .. ": it is a device sign-in")
    eq(pending.user_code, "WXYZ-1234", label .. ": the code to show")
    ok(pending.url:find("^https://example%.org/"), label .. ": and the address for the phone")
    eq(pending.interval, 5, label .. ": how often to ask")
    ok(sent[1].body:find("client_id=CLIENT%-ID"), label .. ": the app is named")
    extra_check(sent[1])
    -- not yet
    local acct, err = Provider.pollAuth("CLIENT-ID", pending, "SEC")
    eq(err and err.code, "IA-S206", label .. ": not allowed yet is IA-S206 (keep waiting)")
    ok(sent[2].body:find("device_code=DC", 1, true) and sent[2].body:find("grant_type=urn%%3Aietf", 1), label .. ": the device code is sent with the device grant")
    -- the answers a phone can give
    local function answer(code, body)
        local r = scripted(function() return { code = code, headers = {}, body = Json.encode(body) } end)
        local a, e = Provider.pollAuth("CLIENT-ID", pending, "SEC")
        r()
        return a, e
    end
    eq(select(2, answer(400, { error = "slow_down" })).code, "IA-S206", label .. ": slow down means keep waiting")
    eq(select(2, answer(400, { error = "expired_token" })).code, "IA-S207", label .. ": an expired code is IA-S207")
    eq(select(2, answer(403, { error = "access_denied" })).code, "IA-S207", label .. ": a refusal is IA-S207")
    eq(select(2, answer(400, { error = "authorization_declined" })).code, "IA-S207", label .. ": a declined sign-in is IA-S207")
    local got = answer(200, { access_token = "AT", refresh_token = "RT", expires_in = 3600 })
    ok(got and got.refresh_token == "RT" and got.provider == Provider.id, label .. ": allowed gives the account record")
    eq(select(2, answer(200, { access_token = "AT" })).code, "IA-S304", label .. ": an answer with no refresh token is not trusted")
    pending.expires_at = os.time() - 1
    eq(select(2, Provider.pollAuth("CLIENT-ID", pending, "SEC")).code, "IA-S207", label .. ": a code past its time is not asked about")
    restore()
    eq(select(2, Provider.beginAuth("")).code, "IA-S204", label .. ": no client id is an error, not a broken screen")
end
auth("gdrive", Gdrive, "/device/code", "/token", function(spec)
    ok(spec.body:find("scope=https%%3A%%2F%%2Fwww.googleapis.com%%2Fauth%%2Fdrive.file"), "gdrive: only the drive.file permission is asked for")
end)
auth("onedrive", Onedrive, "/devicecode", "/token", function(spec)
    ok(spec.body:find("Files.ReadWrite.AppFolder", 1, true) and not spec.body:find("Files.ReadWrite.All", 1, true), "onedrive: only the app folder permission is asked for")
    ok(spec.url:find("/consumers/", 1, true), "onedrive: personal accounts only")
end)

------------------------------------------------------------------------------
-- tokens, and what errors mean
------------------------------------------------------------------------------
do
    local sent = {}
    local restore = scripted(function(spec)
        sent[#sent + 1] = spec
        if spec.url:find("/token", 1, true) then
            return { code = 200, headers = {}, body = Json.encode({ access_token = "NEW", refresh_token = "ROTATED", expires_in = 3600 }) }
        end
        return { code = 200, headers = {}, body = Json.encode({ user = { displayName = "G" }, id = "x", displayName = "G" }) }
    end)
    local saved
    local acct = { provider = "onedrive", refresh_token = "RT", access_token = "OLD", expires_at = 5 }
    local p = Onedrive.new(acct, { app_key = "KEY", now = function() return 100 end, save = function(a) saved = a.refresh_token end })
    p:accountInfo()
    eq(sent[#sent].headers["Authorization"], "Bearer NEW", "an expired token is renewed first")
    eq(saved, "ROTATED", "a refresh token the service replaces is kept")
    ok(sent[1].body:find("client_id=KEY", 1, true) and not sent[1].body:find("client_secret", 1, true), "OneDrive sends no secret")
    local g = Gdrive.new({ provider = "gdrive", refresh_token = "RT", access_token = "OLD", expires_at = 5 }, { app_key = "KEY", app_secret = "SEC", now = function() return 100 end })
    sent = {}
    g:accountInfo()
    ok(sent[1].body:find("client_secret=SEC", 1, true), "Google's app secret goes with a token renewal")
    restore()
end

local function code(P, status, body, headers)
    return P.replyError({ code = status, headers = headers or {}, body = Json.encode(body) }).code
end
eq(code(Gdrive, 403, { error = { errors = { { reason = "storageQuotaExceeded" } } } }), "IA-S301", "Drive: no room is IA-S301")
eq(code(Gdrive, 403, { error = { errors = { { reason = "userRateLimitExceeded" } } } }), "IA-S302", "Drive: a rate limit is IA-S302")
eq(code(Gdrive, 403, { error = { errors = { { reason = "insufficientPermissions" } } } }), "IA-S204", "Drive: a refusal is IA-S204")
eq(code(Gdrive, 401, {}), "IA-S202", "Drive: 401 asks to sign in again")
eq(code(Gdrive, 404, {}), "IA-S307", "Drive: 404 is IA-S307")
eq(code(Gdrive, 503, {}), "IA-S303", "Drive: 5xx is IA-S303")
eq(code(Gdrive, 400, { error = "invalid_grant" }), "IA-S202", "Drive: a refresh token that no longer works asks to sign in again")
eq(code(Onedrive, 429, {}, { ["retry-after"] = "7" }), "IA-S302", "OneDrive: 429 is IA-S302")
eq(Onedrive.replyError({ code = 429, headers = { ["retry-after"] = "7" }, body = "{}" }).retry_after, 7, "and says how long to wait")
eq(code(Onedrive, 507, {}), "IA-S301", "OneDrive: 507 is IA-S301")
eq(code(Onedrive, 412, {}), "IA-S305", "OneDrive: 412 (changed meanwhile) is IA-S305")
eq(code(Onedrive, 409, { error = { code = "nameAlreadyExists" } }), "IA-S305", "OneDrive: a name already there is IA-S305")
eq(code(Onedrive, 400, { error = { code = "invalidFileName" } }), "IA-S306", "OneDrive: a bad name is IA-S306")
eq(code(Onedrive, 404, { error = { code = "itemNotFound" } }), "IA-S307", "OneDrive: a missing item is IA-S307")
eq(code(Onedrive, 400, { error = "invalid_grant" }), "IA-S202", "OneDrive: a refresh token that no longer works asks to sign in again")
eq(code(Onedrive, 400, { error = "invalid_client" }), "IA-S204", "OneDrive: an unknown app is IA-S204")

-- only the service's own hosts are spoken to, and a link anywhere else is refused
ok(Http.hostAllowed(Onedrive.HOSTS, "public.sn.files.1drv.com"), "OneDrive's download hosts below 1drv.com are allowed")
ok(not Http.hostAllowed(Onedrive.HOSTS, "evil.example.com") and not Http.hostAllowed(Onedrive.HOSTS, "1drv.com.evil.org"), "other hosts, and look-alikes, are not")
do
    local Fake = dofile("tests/sync/fakeonedrive.lua")
    local fake = Fake.new()
    fake.transport0 = fake.transport
    fake.transport = function(spec)
        if spec.url:find("/approot:/x.inkaway:/content", 1, true) and (spec.method == "GET") then
            return { code = 302, headers = { location = "https://evil.example.com/steal" }, body = "" }
        end
        return fake.transport0(spec)
    end
    current = fake
    local p = Onedrive.new({ provider = "onedrive", refresh_token = "R", access_token = "A", expires_at = 4e9 }, { app_key = "KEY", dir = BASE })
    write(BASE .. "/x.in", "data")
    p:upload(BASE .. "/x.in", "x.inkaway", nil)
    local _m, e = p:download("x.inkaway", nil, BASE .. "/x.out")
    eq(e and e.code, "IA-S503", "a redirect to a host that is not OneDrive's is refused")
    ok(not (function() local f = io.open(BASE .. "/x.out"); if f then f:close() end return f end)(), "and no file is left")
end

------------------------------------------------------------------------------
-- the registrations people can enter, and the map of ids
------------------------------------------------------------------------------
do
    local Config = require("ink/sync/config")
    local function get(t) return function(k) return t[k] end end
    local gid, gsec = "1234567890-abcdefghijkl.apps.googleusercontent.com", "GOCSPX-abcdefgh12"
    local a, b = Config.appKey("gdrive", get({ inkaway_sync_gdrive_key = gid, inkaway_sync_gdrive_secret = gsec }))
    ok(a == gid and b == gsec, "Google needs a client id and a secret, and gives both")
    eq(Config.appKey("gdrive", get({ inkaway_sync_gdrive_key = gid })), nil, "an id with no secret is not enough")
    eq(Config.appKey("gdrive", get({ inkaway_sync_gdrive_key = "bad id!", inkaway_sync_gdrive_secret = gsec })), nil, "an id with odd characters is refused")
    local guid = "0a1b2c3d-4e5f-6789-abcd-ef0123456789"
    eq(Config.appKey("onedrive", get({ inkaway_sync_onedrive_key = guid })), guid, "OneDrive takes a GUID")
    eq(Config.appKey("onedrive", get({ inkaway_sync_onedrive_key = "not-a-guid" })), nil, "and nothing else")
    eq(#Config.fields("gdrive"), 2, "Google asks for two values")
    eq(#Config.fields("onedrive"), 1, "OneDrive for one")
    eq(#Config.fields("nothing"), 0, "an unknown service for none")

    local Index = require("ink/sync/providers/idindex")
    local path = BASE .. "/idx.json"
    os.remove(path)
    local ix = Index.load(path, "R")
    ix:put("f1", "Notes", "R", true)
    ix:put("f2", "a.inkaway", "f1", false)
    ix:put("f3", "a.inkaway", "elsewhere", false)
    eq(ix:relOf("f2"), "Notes/a.inkaway", "a path is built from the ids above it")
    eq(ix:relOf("f3"), nil, "an item outside the folder has no path")
    eq(ix:idOf("Notes/a.inkaway"), "f2", "an id is found from a path")
    eq(ix:idOf("Notes/missing"), nil, "a missing path has none")
    ix.cursor = "7"
    ix:save()
    local again = Index.load(path, "R")
    ok(again.cursor == "7" and again:relOf("f2") == "Notes/a.inkaway", "the map is kept between runs")
    eq(next(Index.load(path, "OTHER").map), nil, "a map of another folder is not used")
    write(path, "{ not json")
    eq(next(Index.load(path, "R").map), nil, "a damaged map starts empty")
end

print(string.format("clouds: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
