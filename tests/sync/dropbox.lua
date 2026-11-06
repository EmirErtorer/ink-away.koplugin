-- The Dropbox provider (ink/sync/providers/dropbox.lua) against a pretend
-- network: what it sends, and how it reads every kind of answer.
--   luajit tests/sync/dropbox.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
require("testenv")
local Dropbox = require("ink/sync/providers/dropbox")
local Errors = require("ink/sync/errors")
local Hash = require("ink/sync/hash")
local Http = require("ink/sync/http")
local Json = require("ink/sync/json")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end

-- the pretend network: replies are queued per path suffix; every request is kept
local sent, replies = {}, {}
Http.transport = function(spec)
    sent[#sent + 1] = spec
    local key = spec.url:match("https://[^/]+(.*)$")
    local q = replies[key]
    local r = q and table.remove(q, 1)
    if not r then return nil, Errors.make("IA-S101", "no reply queued for " .. key) end
    if r.fail then return nil, r.fail end
    if spec.sink_file and r.file then
        local f = io.open(spec.sink_file, "wb"); f:write(r.file); f:close()
    end
    return { code = r.code or 200, headers = r.headers or {}, body = r.body or "" }
end
local function reply(path, r) replies[path] = replies[path] or {}; table.insert(replies[path], r) end
local function json(path, v, code) reply(path, { code = code or 200, body = Json.encode(v) }) end
local function last() return sent[#sent] end

local now = 1000
local saved
local function provider(expires)
    local acct = { refresh_token = "RT", access_token = "AT", expires_at = expires or now + 3600 }
    return Dropbox.new(acct, { app_key = "KEY", now = function() return now end, save = function(a) saved = a.access_token end }), acct
end

------------------------------------------------------------------------------
-- signing in
------------------------------------------------------------------------------
eq(Dropbox.base64url("\251\255"), "-_8", "base64url uses - and _")
eq(Dropbox.base64url("Man"), "TWFu", "base64url of three bytes")
eq(Dropbox.base64url("Ma"), "TWE", "no padding")
local a = Dropbox.beginAuth("APPKEY")
ok(a.url:find("client_id=APPKEY", 1, true), "the address names the app")
ok(a.url:find("code_challenge_method=S256", 1, true), "it asks for PKCE")
ok(a.url:find("token_access_type=offline", 1, true), "it asks for a refresh token")
ok(a.url:find("code_challenge=" .. Dropbox.base64url(Hash.sha256bin(a.verifier)), 1, true), "the challenge is the hash of the verifier")
ok(#a.verifier >= 43 and #a.verifier <= 128, "the verifier has an allowed length")
ok(Dropbox.beginAuth("APPKEY").verifier ~= a.verifier, "each sign-in has its own verifier")
eq(select(2, Dropbox.beginAuth("")).code, "IA-S204", "no app key is an error, not a broken address")

json("/oauth2/token", { access_token = "A1", refresh_token = "R1", expires_in = 14400, account_id = "dbid:1" })
local acct = Dropbox.finishAuth("KEY", " ab cd ", "VER")
eq(acct.refresh_token, "R1", "the refresh token is kept")
ok(last().body:find("code=abcd", 1, true) and last().body:find("code_verifier=VER", 1, true), "spaces in the typed code are dropped; the verifier is sent")
ok(not last().body:find("client_secret", 1, true), "no secret is sent")
reply("/oauth2/token", { code = 400, body = Json.encode({ error = "invalid_grant", error_description = "code is invalid" }) })
eq(select(2, Dropbox.finishAuth("KEY", "bad", "VER")).code, "IA-S203", "a wrong code is IA-S203")
eq(select(2, Dropbox.finishAuth("KEY", "", "VER")).code, "IA-S203", "an empty code is IA-S203")

------------------------------------------------------------------------------
-- tokens
------------------------------------------------------------------------------
local p, ac = provider(now + 10)       -- about to expire
json("/oauth2/token", { access_token = "A2", expires_in = 14400 })
json("/2/users/get_current_account", { account_id = "dbid:1", name = { display_name = "Ada" }, email = "a@x.org" })
local who = p:accountInfo()
eq(who.name, "Ada", "account name")
eq(last().headers["Authorization"], "Bearer A2", "the renewed token is used")
eq(saved, "A2", "the renewed token is handed back to be kept")

p, ac = provider()
reply("/2/users/get_current_account", { code = 401, body = Json.encode({ error_summary = "expired_access_token/" }) })
json("/oauth2/token", { access_token = "A3", expires_in = 14400 })
json("/2/users/get_current_account", { account_id = "x", name = { display_name = "B" }, email = "" })
eq(p:accountInfo().name, "B", "a 401 renews the token once and retries")

p = provider(now - 5)
reply("/oauth2/token", { code = 400, body = Json.encode({ error = "invalid_grant" }) })
eq(select(2, p:accountInfo()).code, "IA-S202", "a revoked sign-in is IA-S202")

------------------------------------------------------------------------------
-- listing
------------------------------------------------------------------------------
p = provider()
json("/2/files/list_folder", { entries = {
    { [".tag"] = "file", path_display = "/Math.inkaway", rev = "r1", size = 5, content_hash = "h1" },
    { [".tag"] = "folder", path_display = "/School" },
}, cursor = "C1", has_more = true })
json("/2/files/list_folder/continue", { entries = {
    { [".tag"] = "file", path_display = "/School/Bio é.inkaway", rev = "r2", size = 7, content_hash = "h2" },
    { [".tag"] = "deleted", path_display = "/Gone.inkaway" },
}, cursor = "C2", has_more = false })
local l = p:list(nil)
eq(#l.entries, 3, "files and deletions are listed, folders are not")
eq(l.entries[2].rel, "School/Bio é.inkaway", "the path loses its first slash")
eq(l.entries[3].deleted, true, "a deleted entry")
eq(l.cursor, "C2", "the last cursor")
ok(l.reset, "a full listing replaces what was known")
json("/2/files/list_folder/continue", { entries = {}, cursor = "C3", has_more = false })
l = p:list("C2")
eq(l.reset, false, "a change list does not")
reply("/2/files/list_folder/continue", { code = 409, body = Json.encode({ error_summary = "reset/..", error = { [".tag"] = "reset" } }) })
json("/2/files/list_folder", { entries = {}, cursor = "C9", has_more = false })
l = p:list("OLD")
ok(l.reset and l.cursor == "C9", "a cursor Dropbox forgot starts a full listing")

------------------------------------------------------------------------------
-- download and upload
------------------------------------------------------------------------------
local tmp = os.tmpname()
reply("/2/files/download", { file = "HELLO", headers = { ["dropbox-api-result"] = Json.encode({ rev = "r5", size = 5, content_hash = "hh", path_display = "/A.inkaway" }) } })
local m = p:download("A.inkaway", nil, tmp)
eq(m.rev, "r5", "download gives the revision")
eq(Json.decode(last().headers["Dropbox-API-Arg"]).path, "/A.inkaway", "the path is sent in the header")
local f = io.open(tmp, "rb"); eq(f:read("*a"), "HELLO", "and the file is written"); f:close()
reply("/2/files/download", { file = "HELLO", headers = { ["dropbox-api-result"] = Json.encode({ rev = "r5", size = 5 }) } })
p:download("A.inkaway", "r5", tmp)
eq(Json.decode(last().headers["Dropbox-API-Arg"]).path, "rev:r5", "a revision is asked for by its number")
ok(not last().headers["Dropbox-API-Arg"]:find("[\128-\255]"), "the header is plain ASCII")
reply("/2/files/download", { code = 409, file = Json.encode({ error_summary = "path/not_found/.." }) })
local nm, ne = p:download("Missing.inkaway", nil, tmp)
eq(ne.code, "IA-S307", "a missing file is IA-S307")
ok(not io.open(tmp, "rb"), "and no file is left")

local src = os.tmpname()
f = io.open(src, "wb"); f:write("DATA"); f:close()
json("/2/files/upload", { path_display = "/Up é.inkaway", rev = "r6", size = 4, content_hash = "x" })
m = p:upload(src, "Up é.inkaway", nil)
eq(m.rev, "r6", "upload gives the new revision")
local arg = Json.decode(last().headers["Dropbox-API-Arg"])
eq(arg.mode[".tag"], "add", "a new file must not exist yet")
eq(arg.autorename, false, "it never renames behind our back")
eq(last().body_file, src, "the file goes from disk")
json("/2/files/upload", { path_display = "/Up.inkaway", rev = "r7", size = 4 })
p:upload(src, "Up.inkaway", "r6")
arg = Json.decode(last().headers["Dropbox-API-Arg"])
eq(arg.mode[".tag"], "update", "an edit builds on a revision")
eq(arg.mode.update, "r6", "the one it was made from")
reply("/2/files/upload", { code = 409, body = Json.encode({ error_summary = "path/conflict/file/.." }) })
eq(select(2, p:upload(src, "Up.inkaway", "r1")).code, "IA-S305", "a stale revision is refused: IA-S305")
reply("/2/files/upload", { code = 409, body = Json.encode({ error_summary = "path/insufficient_space/.." }) })
eq(select(2, p:upload(src, "Up.inkaway", nil)).code, "IA-S301", "a full account is IA-S301")
reply("/2/files/upload", { code = 429, headers = { ["retry-after"] = "12" }, body = "{}" })
local _, re = p:upload(src, "Up.inkaway", nil)
eq(re.code, "IA-S302", "too many requests is IA-S302")
eq(re.retry_after, 12, "with the wait Dropbox asked for")
reply("/2/files/upload", { code = 503, body = "" })
eq(select(2, p:upload(src, "Up.inkaway", nil)).code, "IA-S303", "a server error is IA-S303")
reply("/2/files/upload", { code = 403, body = Json.encode({ error_summary = "no_permission" }) })
eq(select(2, p:upload(src, "Up.inkaway", nil)).code, "IA-S204", "a refusal is IA-S204")
reply("/2/files/upload", { fail = Errors.make("IA-S102") })
eq(select(2, p:upload(src, "Up.inkaway", nil)).code, "IA-S102", "a timeout comes through")
reply("/2/files/upload", { body = "not json" })
eq(select(2, p:upload(src, "Up.inkaway", nil)).code, "IA-S304", "a reply that is not understood is IA-S304")

-- a big file goes in pieces
local big = os.tmpname()
f = io.open(big, "wb"); f:write(string.rep("a", 25)); f:close()
Dropbox.SINGLE_MAX, Dropbox.CHUNK = 10, 10
json("/2/files/upload_session/start", { session_id = "S1" })
json("/2/files/upload_session/append_v2", {})
json("/2/files/upload_session/finish", { path_display = "/Big.inkaway", rev = "r8", size = 25 })
local before = #sent
m = p:upload(big, "Big.inkaway", nil)
eq(m and m.rev, "r8", "a big file is sent in pieces and committed")
eq(#sent - before, 3, "start, one append, finish")
local fin = Json.decode(sent[#sent].headers["Dropbox-API-Arg"])
eq(fin.cursor.offset, 20, "the commit knows how much was sent")
eq(fin.commit.mode[".tag"], "add", "and carries the same mode")
ok(not io.open(big .. ".piece", "rb"), "no leftover piece")
Dropbox.SINGLE_MAX, Dropbox.CHUNK = 8 * 1024 * 1024, 4 * 1024 * 1024

------------------------------------------------------------------------------
-- delete, versions
------------------------------------------------------------------------------
json("/2/files/delete_v2", { metadata = {} })
ok(p:delete("A.inkaway", "r5"), "delete")
eq(Json.decode(last().body).parent_rev, "r5", "only if it is still the revision we know")
reply("/2/files/delete_v2", { code = 409, body = Json.encode({ error_summary = "path_lookup/not_found/.." }) })
eq(select(2, p:delete("A.inkaway", "r5")).code, "IA-S307", "delete of a missing file is IA-S307")
json("/2/files/list_revisions", { entries = {
    { rev = "r9", size = 9, server_modified = "2026-11-03T10:00:00Z" }, { rev = "r8", size = 8, server_modified = "2026-11-02T10:00:00Z" } } })
local revs = p:revisions("A.inkaway")
eq(#revs, 2, "versions")
eq(revs[1].current, true, "the newest is the current one")
eq(revs[2].mtime, Dropbox.parseTime("2026-11-02T10:00:00Z"), "with their dates")
eq(Dropbox.parseTime("1970-01-02T00:00:01Z"), 86401, "the date is read as UTC")
eq(Dropbox.parseTime("2026-11-03T00:00:00Z") - Dropbox.parseTime("2026-11-02T00:00:00Z"), 86400, "a day is a day")
json("/2/files/restore", { path_display = "/A.inkaway", rev = "r10", size = 8 })
eq(p:restore("A.inkaway", "r8").rev, "r10", "restoring makes a new revision")

------------------------------------------------------------------------------
-- the network layer itself
------------------------------------------------------------------------------
Http.transport = function() error("must not be reached") end
local _, he = Http.request({ url = "https://evil.example.com/x", hosts = Dropbox.HOSTS })
eq(he.code, "IA-S503", "a host that is not Dropbox's is never spoken to")
_, he = Http.request({ url = "http://api.dropboxapi.com/x", hosts = Dropbox.HOSTS })
eq(he.code, "IA-S503", "a plain-text address is never used")
eq(Http.classify("timeout").code, "IA-S102", "a timeout")
eq(Http.classify("certificate verify failed").code, "IA-S103", "a certificate problem")
eq(Http.classify("connection refused").code, "IA-S101", "anything else is no connection")

os.remove(tmp); os.remove(src); os.remove(big)
print(string.format("dropbox: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
