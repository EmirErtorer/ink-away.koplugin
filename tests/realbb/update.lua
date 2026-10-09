-- Installing an update (ink/update/install.lua) with KOReader's REAL zip and
-- SHA-256 code, into a throwaway plugin folder: a good release replaces the
-- plugin and keeps the old one until the new version runs; anything wrong (a
-- download that does not match GitHub's digest or size, another version
-- inside, a path that leaves the plugin folder, a broken Lua file, a partial
-- plugin, a development copy) is refused, writes nothing outside the staging
-- folder, and leaves the plugin exactly as it was.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/update.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
package.path = REPO .. "/?.lua;" .. package.path
local lfs = require("libs/libkoreader-lfs")
local Archiver = require("ffi/archiver")
local Install = require("ink/update/install")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local root = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/inkaway-update-test-" .. os.time()
local plugins = root .. "/plugins"
local plugin = plugins .. "/ink-away.koplugin"
local stage, backup = Install.paths(plugin)

local function write(path, s) local f = assert(io.open(path, "wb")); f:write(s); f:close() end
local function read(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function exists(path) return lfs.symlinkattributes(path) ~= nil end
local function meta(v) return 'return { name = "inkaway", version = "' .. v .. '" }\n' end

-- the installed plugin: version 4.0.0
local function fresh()
    Install.removeTree(root)
    lfs.mkdir(root); lfs.mkdir(plugins); lfs.mkdir(plugin); lfs.mkdir(plugin .. "/ink")
    write(plugin .. "/_meta.lua", meta("4.0.0"))
    write(plugin .. "/main.lua", "return {}\n")
    write(plugin .. "/ink/view.lua", "return 'old'\n")
end
local function intact()
    return read(plugin .. "/_meta.lua") == meta("4.0.0") and read(plugin .. "/ink/view.lua") == "return 'old'\n"
        and not exists(stage)
end

-- a zip of `files` ({ path, content }), and the release GitHub would list for it
local zip = root .. "-dl.zip"
local function makeZip(files, version, fudge)
    os.remove(zip)
    local w = Archiver.Writer:new()
    assert(w:open(zip, "zip"))
    for _i, f in ipairs(files) do assert(w:addFileFromMemory(f[1], f[2], os.time())) end
    w:close()
    local sum, size = Install.digest(zip)
    return { version = version, size = size + ((fudge == "size") and 1 or 0),
             digest = (fudge == "digest") and string.rep("0", 64) or sum }
end
local function plugin_files(v, extra)
    local t = { { "ink-away.koplugin/_meta.lua", meta(v) }, { "ink-away.koplugin/main.lua", "return {}\n" },
                { "ink-away.koplugin/ink/view.lua", "return 'new'\n" }, { "ink-away.koplugin/ink/icons/pen.svg", "<svg/>" } }
    for _i, e in ipairs(extra or {}) do t[#t + 1] = e end
    return t
end

-- (run inside pcall, so a crash still clears the throwaway folder)
local ran, crash = pcall(function()
-- ---- a good release ----------------------------------------------------------------------
fresh()
local rel = makeZip(plugin_files("9.9.9"), "9.9.9")
local good, why = Install.prepare(zip, stage, rel)
ok(good, "good: the release is checked and unpacked (" .. tostring(why) .. ")")
ok(read(plugin .. "/ink/view.lua") == "return 'old'\n", "good: the plugin is untouched until the swap")
ok(Install.swap(plugin, stage, backup), "good: swapped in")
ok(read(plugin .. "/_meta.lua") == meta("9.9.9") and read(plugin .. "/ink/view.lua") == "return 'new'\n"
    and read(plugin .. "/ink/icons/pen.svg") == "<svg/>", "good: the new version is in the plugin folder")
ok(read(backup .. "/_meta.lua") == meta("4.0.0") and not exists(stage), "good: the old version kept aside, nothing staged left")
ok(not Install.cleanup(plugin, "4.0.0", "9.9.9") and exists(backup), "good: kept while the old version still runs (no restart yet)")
ok(Install.cleanup(plugin, "9.9.9", "9.9.9") and not exists(backup), "good: gone once the new version runs")

-- ---- a download that is not what GitHub lists ------------------------------------------------
for _i, fudge in ipairs({ "digest", "size" }) do
    fresh()
    rel = makeZip(plugin_files("9.9.9"), "9.9.9", fudge)
    local res, err = Install.prepare(zip, stage, rel)
    ok(not res and tostring(err):find("does not match") and intact(), "refused: a " .. fudge .. " that differs from GitHub's")
end

-- ---- what is inside ----------------------------------------------------------------------------
local cases = {
    { "another version inside", plugin_files("9.9.8"), "9.9.9" },
    { "a path out of the folder", plugin_files("9.9.9", { { "ink-away.koplugin/../evil.lua", "return 1\n" } }), "9.9.9", plugins .. "/evil.lua" },
    { "a path out from deeper", plugin_files("9.9.9", { { "ink-away.koplugin/ink/../../evil2.lua", "return 1\n" } }), "9.9.9", plugins .. "/evil2.lua" },
    { "an absolute path", plugin_files("9.9.9", { { root .. "/evil3.lua", "return 1\n" } }), "9.9.9", root .. "/evil3.lua" },
    { "another plugin's files", plugin_files("9.9.9", { { "other.koplugin/main.lua", "return 1\n" } }), "9.9.9", plugins .. "/other.koplugin" },
    { "a broken Lua file", plugin_files("9.9.9", { { "ink-away.koplugin/ink/bad.lua", "return (" } }), "9.9.9" },
    { "a partial plugin", { { "ink-away.koplugin/_meta.lua", meta("9.9.9") }, { "ink-away.koplugin/ink/x.lua", "return 1\n" } }, "9.9.9" },
}
for _i, c in ipairs(cases) do
    fresh()
    rel = makeZip(c[2], c[3])
    local res, err = Install.prepare(zip, stage, rel)
    ok(not res and intact(), ("refused: %s (%s)"):format(c[1], tostring(err)))
    if c[4] then ok(not exists(c[4]), "refused: " .. c[1] .. ", and nothing written there") end
end

-- ---- swapping ----------------------------------------------------------------------------------
fresh()
rel = makeZip(plugin_files("9.9.9"), "9.9.9")
assert(Install.prepare(zip, stage, rel))
lfs.mkdir(plugin .. "/.git")
local res, err = Install.swap(plugin, stage, backup)
ok(not res and tostring(err):find("development copy") and read(plugin .. "/_meta.lua") == meta("4.0.0"),
    "swap: a development copy (with .git) is never replaced")
lfs.rmdir(plugin .. "/.git")
Install.removeTree(stage)
res = Install.swap(plugin, stage, backup)
ok(not res and read(plugin .. "/_meta.lua") == meta("4.0.0") and not exists(backup), "swap: nothing staged, nothing moved")
-- an old backup left behind is replaced, not in the way
fresh()
lfs.mkdir(backup); write(backup .. "/stale", "x")
rel = makeZip(plugin_files("9.9.9"), "9.9.9")
assert(Install.prepare(zip, stage, rel))
ok(Install.swap(plugin, stage, backup) and read(backup .. "/_meta.lua") == meta("4.0.0") and not exists(backup .. "/stale"),
    "swap: an old leftover backup gives way to this version")
-- anything staged and left (a power cut) goes at the next start
fresh()
lfs.mkdir(stage); write(stage .. "/half", "x")
Install.cleanup(plugin, "4.0.0", nil)
ok(not exists(stage) and intact(), "start: a half-staged update is cleared, the plugin as it was")

end)
ok(ran, "the test ran to its end (" .. tostring(crash) .. ")")
-- ---- private, on KOReader's own HTTP code: what a check sends ------------------------------
do
    package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }
    -- KOReader's own LuaSocket, found where KOReader finds it
    package.path = "common/?.lua;" .. package.path
    package.cpath = "common/?.so;common/?.dylib;libs/?.so;" .. package.cpath
    local http = require("socket.http")
    http.USERAGENT = "KOReader/2026.07 (Kindle PaperWhite4; Linux; arm) LuaSocket"   -- as KOReader sets it
    local sent = {}
    local real_open = http.open
    http.open = function(host, port)
        local h = { host = host, port = port }
        function h:sendrequestline(method, uri) sent.line = method .. " " .. uri end
        function h:sendheaders(t) sent.headers = t; sent.host, sent.port = host, port end
        function h:sendbody() sent.body = true end
        function h:receivestatusline() return 200, "HTTP/1.1 200 OK" end
        function h:receiveheaders() return { ["content-length"] = "2" } end
        function h:receivebody(_hd, sink) sink("[]"); sink(nil); return 1 end
        function h:close() end
        return h
    end
    local Net = require("ink/update/net")
    local Policy = require("ink/update/policy")
    local out = root .. "-feed"
    local got = Net.fetch(Policy.API, out, 1000)
    http.open = real_open
    local hd = sent.headers or {}
    local names = {}
    for k in pairs(hd) do names[#names + 1] = k:lower() end
    table.sort(names)
    ok(got and read(out) == "[]", "private: a check fetched through KOReader's own HTTP code")
    ok(sent.host == "api.github.com" and sent.port == 443, "private: to GitHub's API, on the HTTPS port")
    ok(hd["user-agent"] == "Ink-Away-KOReader-plugin", "private: Ink Away's own User-Agent (" .. tostring(hd["user-agent"]) .. ")")
    local all = table.concat(names, " ") .. " " .. table.concat((function()
        local vals = {}
        for _k, val in pairs(hd) do vals[#vals + 1] = tostring(val) end
        return vals end)(), " ")
    ok(not all:find("Kindle") and not all:find("KOReader/") and not all:find("Linux"),
        "private: nothing about the device or KOReader is sent")
    ok(not hd["cookie"] and not hd["authorization"] and not hd["proxy-authorization"] and not sent.body,
        "private: no cookies, no credentials, no body")
    ok(table.concat(names, ",") == "accept,connection,host,te,user-agent",
        "private: only the headers HTTP needs (" .. table.concat(names, ",") .. ")")
    os.remove(out)
end

os.remove(zip)
Install.removeTree(root)
ok(not exists(root), "the test leaves nothing behind")
print(("realbb update: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
