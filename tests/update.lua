-- Updates (ink/update/*), headless:
--   * the rules: versions, which releases may be offered (only the newest
--     release, never an older one; a prerelease only when newer than it; from
--     a prerelease or a test build only back to the newest release), what is
--     unpacked, the notes;
--   * private: a request carries Ink Away's own User-Agent and nothing else
--     about the reader or the device, goes only to GitHub over HTTPS, and
--     follows no redirect elsewhere;
--   * efficient: an automatic check at most once a day, never without Wi-Fi,
--     one request a check, and nothing left running when it is over or stuck.
--   luajit tests/update.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local Policy = require("ink/update/policy")

-- ---- versions -------------------------------------------------------------------------
do
    local C = Policy.compare
    ok(C("v4.1.0", "4.0.9") == 1 and C("4.0.0", "v4.0.0") == 0 and C("3.10.0", "3.9.9") == 1, "version: numbers compare as numbers")
    ok(C("4.1.0-beta.2", "4.1.0") == -1 and C("4.1.0", "4.1.0-rc.1") == 1, "version: a prerelease comes before its release")
    ok(C("4.1.0-beta.10", "4.1.0-beta.9") == 1 and C("4.1.0-alpha", "4.1.0-beta") == -1
        and C("4.1.0-beta", "4.1.0-beta.1") == -1 and C("4.1.0-1", "4.1.0-alpha") == -1, "version: prerelease parts in order")
    ok(Policy.parse("4.1") == nil and Policy.parse("latest") == nil and Policy.parse("4.1.0 beta") == nil
        and Policy.parse(nil) == nil and C("x", "4.0.0") == nil, "version: what is not a version is nil")
end

-- ---- a release list, as GitHub gives it --------------------------------------------------
local function rel(tag, pre, opts)
    opts = opts or {}
    local name = "ink-away.koplugin-" .. tag .. ".zip"
    return { tag_name = tag, prerelease = pre or false, draft = opts.draft or false,
        published_at = opts.date or "2026-10-01T10:00:00Z", body = opts.body or ("## " .. tag),
        assets = { { name = opts.name or name, state = "uploaded", size = opts.size or 700000,
            digest = opts.digest or ("sha256:" .. string.rep("ab", 32)),
            browser_download_url = opts.url or ("https://github.com/EmirErtorer/ink-away.koplugin/releases/download/"
                .. tag .. "/" .. name) } } }
end
-- as on GitHub on 9 Oct 2026, prereleases and all
local REAL = { rel("v3.3.0"), rel("v3.2.0"), rel("v3.1.3", true), rel("v3.1.2", true), rel("v3.1.1", true),
    rel("v3.1.0"), rel("v3.0.0"), rel("v2.2.0"), rel("v2.1.1"), rel("v2.1.0") }
local function with(list, ...)
    local out = {}
    for _i, r in ipairs(list) do out[#out + 1] = r end
    for _i, r in ipairs({ ... }) do out[#out + 1] = r end
    return out
end
local function versions(t)
    local out = {}
    for i, r in ipairs(t) do out[i] = r.version end
    return table.concat(out, ",")
end

-- ---- which releases may be used ---------------------------------------------------------
do
    ok(Policy.release(rel("v3.3.0")) ~= nil, "release: a published one with its zip and digest")
    ok(not Policy.release(rel("v3.4.0", false, { draft = true })), "release: never a draft")
    ok(not Policy.release(rel("v3.4.0", false, { name = "other.zip" })), "release: only Ink Away's own zip")
    ok(not Policy.release(rel("v3.4.0", false, { url = "https://evil.example/ink-away.koplugin-v3.4.0.zip" })),
        "release: only from GitHub's release downloads")
    ok(not Policy.release(rel("v3.4.0", false, { url = "http://github.com/EmirErtorer/ink-away.koplugin/releases/download/v3.4.0/ink-away.koplugin-v3.4.0.zip" })),
        "release: only over HTTPS")
    ok(not Policy.release(rel("v3.4.0", false, { digest = "sha1:abcd" })), "release: only with a SHA-256 digest")
    ok(not Policy.release(rel("v3.4.0", false, { size = 64 * 1024 * 1024 })), "release: not an outsized zip")
    ok(not Policy.release(rel("nightly")), "release: only a version tag")
end

-- ---- what is offered ----------------------------------------------------------------------
do
    local o = Policy.offers(REAL, "3.2.0")
    ok(o.stable.version == "3.3.0" and o.stable_action == "update" and o.pre == nil and not o.on_pre,
        "offer: an older install gets the newest release, and no older prerelease")
    ok(versions(o.since) == "3.3.0", "offer: its notes")
    o = Policy.offers(REAL, "2.1.0")
    ok(o.stable.version == "3.3.0" and o.stable_action == "update", "offer: from far behind, only the newest release")
    ok(versions(o.since) == "3.3.0,3.2.0,3.1.0,3.0.0,2.2.0,2.1.1", "offer: with every release's notes since, newest first ("
        .. versions(o.since) .. ")")
    o = Policy.offers(REAL, "3.3.0")
    ok(o.stable_action == "current" and o.pre_action == nil, "offer: the newest release installed: nothing to do")

    local list = with(REAL, rel("v4.1.0-beta.1", true), rel("v4.0.0-beta.3", true))
    o = Policy.offers(list, "3.3.0")
    ok(o.pre and o.pre.version == "4.1.0-beta.1" and o.pre_action == "try" and o.stable_action == "current",
        "offer: a prerelease newer than the release, apart from it")
    o = Policy.offers(list, "4.1.0-beta.1")
    ok(o.on_pre and o.stable.version == "3.3.0" and o.stable_action == "back" and o.pre_action == "current",
        "offer: on a prerelease, back to the newest release")
    o = Policy.offers(with(REAL, rel("v3.4.0", true)), "3.4.0")
    ok(o.on_pre and o.stable_action == "back" and o.stable.version == "3.3.0",
        "offer: a prerelease without a beta suffix is known by GitHub's flag")
    o = Policy.offers(REAL, "4.0.0")
    ok(o.on_pre and o.stable_action == "back" and o.stable.version == "3.3.0",
        "offer: a test build newer than any release: back to the newest release")
    -- never an older release, whatever is installed
    for _i, cur in ipairs({ "2.0.0", "3.1.2", "3.3.0", "4.0.0", "4.1.0-beta.1" }) do
        o = Policy.offers(list, cur)
        ok(o.stable.version == "3.3.0", "offer: from " .. cur .. " only 3.3.0 is the release offered")
        ok(not o.pre or Policy.compare(o.pre.version, o.stable.version) == 1,
            "offer: from " .. cur .. " a prerelease only when newer than it")
    end
    o = Policy.offers(with(REAL, rel("v9.0.0", false, { draft = true })), "3.3.0")
    ok(o.stable.version == "3.3.0", "offer: a draft is never offered")
    o = Policy.offers({}, "3.3.0")
    ok(o.stable == nil and o.stable_action == nil, "offer: nothing published, nothing offered")
end

-- ---- when an automatic check is due ---------------------------------------------------------
do
    local now = 1000000000
    ok(Policy.due(now, nil, nil), "due: never checked")
    ok(not Policy.due(now, now - 2 * 3600, nil), "due: not within a day of the last check")
    ok(Policy.due(now, now - 25 * 3600, nil), "due: a day after it")
    ok(not Policy.due(now, now - 25 * 3600, now - 600), "due: not within an hour of a try that failed")
    ok(Policy.due(now, now + 3600, nil), "due: a clock set back does not stop the checks")
end

-- ---- what may be unpacked ------------------------------------------------------------------------
do
    local E = Policy.entry
    ok(E("ink-away.koplugin/", "directory") == "" and E("ink-away.koplugin/ink/view.lua", "file") == "ink/view.lua"
        and E("ink-away.koplugin/ink/icons/", "directory") == "ink/icons", "unpack: the plugin's own files and folders")
    for _i, bad in ipairs({ "../evil.lua", "ink-away.koplugin/../evil.lua", "/etc/passwd", "other.koplugin/main.lua",
            "ink-away.koplugin/ink/../../x.lua", "ink-away.koplugin\\main.lua", "ink-away.koplugin/a\nb",
            "ink-away.koplugin//main.lua", "ink-away.koplugin/./main.lua", "ink-away.koplugin" }) do
        ok(E(bad, "file") == nil, "unpack: refused " .. bad:gsub("\n", "\\n"))
    end
    ok(E("ink-away.koplugin/link", "symlink") == nil and E("ink-away.koplugin/x", "other") == nil,
        "unpack: no links or devices")
end

-- ---- release notes -----------------------------------------------------------------------------
do
    local b = Policy.notes("## New\n\n- **Bold** pen and [a link](https://x)\n  carried on\n  - nested `code`\n"
        .. "![shot](https://img)\n\nPlain text\nmore text\n\n---\n1. First")
    ok(b[1].kind == "h" and b[1].text == "New", "notes: a heading")
    ok(b[2].kind == "li" and b[2].text == "Bold pen and a link carried on" and b[2].depth == 0,
        "notes: a bullet, emphasis and links taken out, its next line carried on (" .. tostring(b[2].text) .. ")")
    ok(b[3].kind == "li" and b[3].depth == 1 and b[3].text == "nested code", "notes: a nested bullet")
    ok(b[4].kind == "p" and b[4].text == "Plain text more text", "notes: a paragraph, pictures left out")
    ok(b[5].kind == "li" and b[5].text == "First", "notes: a numbered line")
    ok(#Policy.notes("") == 0 and #Policy.notes(nil) == 0, "notes: none")
end

-- ---- private: what a request sends, and where ------------------------------------------------
do
    local requests = {}
    local responses = {}
    package.loaded["socket.http"] = { request = function(req)
        requests[#requests + 1] = req
        local r = table.remove(responses, 1) or { 200, {}, "x" }
        if r[3] then req.sink(r[3]); req.sink(nil) end
        return 1, r[1], r[2], "status"
    end }
    package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
    package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }
    local Net = require("ink/update/net")
    local tmp = os.tmpname()

    responses = { { 200, {}, "[]" } }
    local got = Net.fetch(Policy.API, tmp, 1000)
    local req = requests[1]
    ok(got == true and req.url == Policy.API and req.url:match("^https://api%.github%.com/"), "private: the list comes from GitHub's API, over HTTPS")
    local names = {}
    for k in pairs(req.headers or {}) do names[#names + 1] = k:lower() end
    table.sort(names)
    ok(table.concat(names, ",") == "accept,user-agent" and req.headers["User-Agent"] == "Ink-Away-KOReader-plugin",
        "private: only Ink Away's own User-Agent and an Accept header (" .. table.concat(names, ",") .. ")")
    ok(not tostring(req.headers["User-Agent"]):find("KOReader/") and not tostring(req.headers["User-Agent"]):find("Kindle"),
        "private: not KOReader's own, which names the device")
    ok(req.redirect == false and req.method == "GET" and req.source == nil, "private: a plain GET that sends nothing, redirects checked")

    -- a redirect to GitHub's download host is followed, one elsewhere is not
    requests = {}
    responses = { { 302, { location = "https://release-assets.githubusercontent.com/x/y.zip" } }, { 200, {}, "zip" } }
    got = Net.fetch("https://github.com/EmirErtorer/ink-away.koplugin/releases/download/v1/a.zip", tmp, 1000)
    ok(got == true and #requests == 2 and requests[2].url:match("^https://release%-assets%.githubusercontent%.com/"),
        "private: GitHub's own download host is followed")
    requests = {}
    responses = { { 302, { location = "https://evil.example/steal" } } }
    local bad, why = Net.fetch(Policy.API, tmp, 1000)
    ok(bad == nil and #requests == 1 and tostring(why):find("not a GitHub address"), "private: a redirect elsewhere is never followed")
    requests = {}
    responses = { { 302, { location = "http://api.github.com/x" } } }
    bad = Net.fetch(Policy.API, tmp, 1000)
    ok(bad == nil and #requests == 1, "private: nor one to plain HTTP")
    requests = {}
    bad = Net.fetch("https://example.com/x", tmp, 1000)
    ok(bad == nil and #requests == 0, "private: nothing is asked of anyone but GitHub")
    -- efficient: a download stops at its size
    requests = {}
    responses = { { 200, {}, string.rep("z", 5000) } }
    bad, why = Net.fetch(Policy.API, tmp, 1000)
    local f = io.open(tmp, "rb")
    ok(bad == nil and not f, "efficient: a download larger than expected stops and leaves nothing (" .. tostring(why) .. ")")
    if f then f:close() end
    os.remove(tmp)

    -- ---- efficient: a background request, polled only while it runs ----------------------------
    local UIManager = require("ui/uimanager")
    local scheduled = {}
    local orig_scheduleIn, orig_unschedule = UIManager.scheduleIn, UIManager.unschedule
    UIManager.scheduleIn = function(_self, t, fn) scheduled[#scheduled + 1] = { t = t, fn = fn } end
    local function runScheduled()
        local n = 0
        while #scheduled > 0 do
            local s = table.remove(scheduled, 1)
            s.fn(); n = n + 1
            if n > 1000 then break end
        end
        return n
    end
    local children = {}
    package.loaded["ffi/util"] = {
        runInSubProcess = function(fn)
            local c = { fn = fn, done = false, killed = false }
            children[#children + 1] = c
            return #children
        end,
        isSubProcessDone = function(pid) return children[pid].done end,
        terminateSubProcess = function(pid) children[pid].killed = true; children[pid].done = true end,
    }
    package.loaded["datastorage"] = { getDataDir = function() return os.getenv("TMPDIR") or "/tmp" end }
    -- a request that ends: the child writes, the parent stops looking
    requests = {}
    responses = { { 200, {}, "[]" } }
    local result
    ok(Net.get(Policy.API, 1000, 40, function(p, w) result = { p, w } end), "efficient: a request starts in the background")
    ok(#requests == 0, "efficient: nothing is fetched by Ink Away itself (the background process does it)")
    local polls = 0
    for _k = 1, 3 do polls = polls + #scheduled; local s = table.remove(scheduled, 1); if s then s.fn() end end
    local c = children[#children]
    c.fn(); c.done = true
    runScheduled()
    ok(result and result[1] and #scheduled == 0, "efficient: once it ends nothing is left polling")
    if result and result[1] then os.remove(result[1]) end
    -- a request that hangs is stopped at its deadline
    result = nil
    Net.get(Policy.API, 1000, 2, function(p, w) result = { p, w } end)
    local polled = runScheduled()
    ok(result and result[1] == nil and result[2] == "timed out" and children[#children].killed,
        "efficient: a stuck request is stopped at its deadline (" .. polled .. " looks in 2 s)")
    ok(polled <= 6 and #scheduled == 0, "efficient: and then nothing runs")
    -- a background process that ends without reporting (a system that stops it):
    -- a request the reader asked for is made right here instead; the daily one
    -- is not
    for _i, inline in ipairs({ true, false }) do
        result = nil
        requests = {}
        responses = { { 200, {}, "[]" } }
        Net.get(Policy.API, 1000, 40, function(p, w) result = { p, w } end, inline)
        children[#children].done = true   -- gone, nothing written
        runScheduled()
        if inline then
            ok(result and result[1] and #requests == 1, "fallback: a check the reader asked for is made right here")
            if result and result[1] then os.remove(result[1]) end
        else
            ok(result and result[1] == nil and #requests == 0, "fallback: the daily check never is (" .. tostring(result and result[2]) .. ")")
        end
        ok(#scheduled == 0, "fallback: nothing left running after")
    end

    -- ---- efficient: once a day, only on Wi-Fi ----------------------------------------------------
    local Updater = require("ink/update/updater")
    local settings = {}
    _G.G_reader_settings = { readSetting = function(_s, k) return settings[k] end,
        saveSetting = function(_s, k, v) settings[k] = v end, delSetting = function(_s, k) settings[k] = nil end }
    local wifi, connected = true, true
    package.loaded["ui/network/manager"] = { isWifiOn = function() return wifi end, isConnected = function() return connected end }
    local started = 0
    local orig_check = Updater.check
    Updater.check = function(cur, done) started = started + 1; return true end
    wifi = false
    ok(not Updater.autoCheck("3.3.0", function() end) and started == 0, "efficient: no check with Wi-Fi off (it is never turned on)")
    wifi, connected = true, false
    ok(not Updater.autoCheck("3.3.0", function() end) and started == 0, "efficient: nor when not connected")
    connected = true
    ok(Updater.autoCheck("3.3.0", function() end) and started == 1, "efficient: one check when due and online")
    settings.inkaway_update_last = os.time()
    ok(not Updater.autoCheck("3.3.0", function() end) and started == 1, "efficient: no second one the same day")
    settings.inkaway_update_last, settings.inkaway_update_tried = nil, os.time()
    ok(not Updater.autoCheck("3.3.0", function() end) and started == 1, "efficient: nor within an hour of a failed one")
    settings.inkaway_update_tried, settings.inkaway_update_auto = nil, false
    ok(not Updater.autoCheck("3.3.0", function() end) and started == 1, "efficient: none with the daily check off")
    Updater.check = orig_check

    -- the check itself: one request, its findings kept, told once
    settings = {}
    children = {}
    responses = { { 200, {}, '[{"tag_name":"v3.3.0","prerelease":false,"draft":false,"body":"x","published_at":"2026-10-05T16:02:51Z",'
        .. '"assets":[{"name":"ink-away.koplugin-v3.3.0.zip","state":"uploaded","size":589205,'
        .. '"digest":"sha256:b36ae3164ee82612a5812602347235bd8cecfe22e223f9ee8a525518920ce5c1",'
        .. '"browser_download_url":"https://github.com/EmirErtorer/ink-away.koplugin/releases/download/v3.3.0/ink-away.koplugin-v3.3.0.zip"}]}]' } }
    package.loaded["json"] = { decode = function(s)
        local ok2, dk = pcall(require, "dkjson")
        if ok2 then return dk.decode(s) end
        -- a tiny stand-in: the test's one release
        return { { tag_name = "v3.3.0", prerelease = false, draft = false, body = "x", published_at = "2026-10-05T16:02:51Z",
            assets = { { name = "ink-away.koplugin-v3.3.0.zip", state = "uploaded", size = 589205,
                digest = "sha256:b36ae3164ee82612a5812602347235bd8cecfe22e223f9ee8a525518920ce5c1",
                browser_download_url = "https://github.com/EmirErtorer/ink-away.koplugin/releases/download/v3.3.0/ink-away.koplugin-v3.3.0.zip" } } } }
    end }
    local told = {}
    requests = {}
    Updater.autoCheck("3.2.0", function(v) told[#told + 1] = v end)
    local ch = children[#children]
    ch.fn(); ch.done = true
    runScheduled()
    ok(#requests == 1, "efficient: a check is one request")
    ok(told[1] == "3.3.0" and Updater.available("3.2.0") == "3.3.0" and Updater.unseen("3.2.0"),
        "check: 3.3.0 found and told, the dot shown")
    settings.inkaway_update_last = nil
    told = {}
    Updater.autoCheck("3.2.0", function(v) told[#told + 1] = v end)
    ch = children[#children]
    ch.fn(); ch.done = true
    runScheduled()
    ok(#told == 0, "check: the same news is told once")
    settings.inkaway_update_seen = "3.3.0"
    ok(not Updater.unseen("3.2.0"), "check: the dot goes once the sheet is opened")
    ok(Updater.available("3.3.0") == nil, "check: nothing when that version is installed")
    UIManager.scheduleIn, UIManager.unschedule = orig_scheduleIn, orig_unschedule
end

print(("update: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
