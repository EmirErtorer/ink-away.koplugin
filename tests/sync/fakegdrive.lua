-- A pretend Google Drive for the tests: the parts of the Drive v3 API that
-- ink/sync/providers/gdrive.lua uses, kept in memory, behind Http.transport.
local Json = require("ink/sync/json")

local Fake = {}

local function md5(s) return require("ffi/sha2").md5(s) end
local function unescape(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end):gsub("%+", " ")) end
local function query(qs)
    local t = {}
    for k, v in (qs or ""):gmatch("([^&=]+)=([^&]*)") do t[unescape(k)] = unescape(v) end
    return t
end
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
local function readFile(p) local f = io.open(p, "rb"); local s = f and f:read("*a"); if f then f:close() end return s end

function Fake.new()
    local self = { files = {}, log = {}, serial = 0, clock = 1700000000, page = 1000, calls = {}, sessions = {} }
    local FOLDER = "application/vnd.google-apps.folder"

    local function rec(f)
        local folder = f.mime == FOLDER
        return { id = f.id, name = f.name, parents = { f.parent }, mimeType = f.mime, trashed = f.trashed or nil,
            md5Checksum = (not folder) and md5(f.data) or nil, size = (not folder) and tostring(#f.data) or nil,
            headRevisionId = (not folder) and f.rev or nil, modifiedTime = iso(f.mtime) }
    end
    local function touch(f, removed)
        self.clock = self.clock + 1
        f.mtime = self.clock
        self.log[#self.log + 1] = { fileId = f.id, removed = removed or false, file = rec(f) }
    end
    local function make(name, parent, mime, data)
        self.serial = self.serial + 1
        local f = { id = "id" .. self.serial, name = name, parent = parent, mime = mime, data = data or "", history = {} }
        if mime ~= FOLDER then f.rev = "rev" .. self.serial .. ".1"; f.history[1] = { id = f.rev, data = f.data } end
        self.files[f.id] = f
        touch(f)
        return f
    end
    local function setData(f, data)
        f.data = data
        local n = #f.history + 1
        f.rev = f.rev:gsub("%.%d+$", "") .. "." .. n
        f.history[n] = { id = f.rev, data = data }
        touch(f)
    end
    local function reply(code, v, headers) return { code = code, headers = headers or {}, body = v ~= nil and Json.encode(v) or "" } end
    local function notFound() return reply(404, { error = { code = 404, message = "File not found", errors = { { reason = "notFound" } } } }) end
    local function pageOf(list, token)
        local from = tonumber((token or ""):match("^p(%d+)$")) or 0
        local out = {}
        for i = from + 1, math.min(#list, from + self.page) do out[#out + 1] = list[i] end
        return out, (from + self.page < #list) and ("p" .. (from + self.page)) or nil
    end

    -- the pieces a test reaches for
    function self.byPath(path)
        local function child(parent, name)
            for _id, f in pairs(self.files) do
                if f.parent == parent and f.name == name and not f.trashed then return f end
            end
        end
        local root = child("root", "Ink Away")
        local cur = root
        for part in path:gmatch("[^/]+") do cur = cur and child(cur.id, part) end
        return cur
    end
    function self.content(path) local f = self.byPath(path); return f and f.data end
    function self.set(path, data) local f = self.byPath(path); setData(f, data) end
    function self.count(prefix) local n = 0 for _i, c in ipairs(self.calls) do if c:find(prefix, 1, true) then n = n + 1 end end return n end

    function self.transport(spec)
        local path, qs = spec.url:match("^https://www%.googleapis%.com([^?]*)%??(.*)$")
        local q = query(qs)
        local m = spec.method or "GET"
        self.calls[#self.calls + 1] = m .. " " .. tostring(path)
        local body = spec.body and Json.decode(spec.body) or nil
        if not path then return nil, { code = "IA-S101" } end
        local id = path:match("^/drive/v3/files/([^/]+)$") or path:match("^/upload/drive/v3/files/([^/]+)$")
        if path == "/drive/v3/about" then
            return reply(200, { user = { displayName = "Grace", emailAddress = "g@x.org", permissionId = "p1" } })
        elseif path == "/drive/v3/changes/startPageToken" then
            return reply(200, { startPageToken = tostring(#self.log) })
        elseif path == "/drive/v3/changes" then
            local from = tonumber(q.pageToken) or 0
            local list = {}
            for i = from + 1, math.min(#self.log, from + self.page) do list[#list + 1] = self.log[i] end
            if from + self.page < #self.log then return reply(200, { changes = list, nextPageToken = tostring(from + self.page) }) end
            return reply(200, { changes = list, newStartPageToken = tostring(#self.log) })
        elseif path == "/drive/v3/files" and m == "GET" then
            local want = q.q or ""
            local name = want:match("name='([^']*)'")
            local parent = want:match("'([^']+)' in parents")
            local mime = want:match("mimeType='([^']+)'")
            local list = {}
            for _id, f in pairs(self.files) do
                if not f.trashed and (not name or f.name == name) and (not parent or f.parent == parent) and (not mime or f.mime == mime) then
                    list[#list + 1] = f
                end
            end
            table.sort(list, function(a, b) return a.id < b.id end)
            local part, more = pageOf(list, q.pageToken)
            local out = {}
            for _i, f in ipairs(part) do out[#out + 1] = rec(f) end
            return reply(200, { files = out, nextPageToken = more })
        elseif path == "/drive/v3/files" and m == "POST" then
            return reply(200, rec(make(body.name, body.parents[1], body.mimeType or "application/octet-stream")))
        elseif id and path:find("^/drive/v3/files/") and m == "GET" and not path:find("/revisions") then
            local f = self.files[id]
            if not f then return notFound() end
            if q.alt == "media" then
                if spec.sink_file then local o = io.open(spec.sink_file, "wb"); o:write(self.corrupt and (f.data .. "x") or f.data); o:close() end
                return { code = 200, headers = {}, body = "" }
            end
            return reply(200, rec(f))
        elseif id and path:find("^/drive/v3/files/") and m == "PATCH" then
            local f = self.files[id]
            if not f then return notFound() end
            if body.trashed then f.trashed = true; touch(f) end
            return reply(200, rec(f))
        elseif path:match("^/drive/v3/files/[^/]+/revisions$") then
            local f = self.files[path:match("files/([^/]+)/")]
            if not f then return notFound() end
            local out = {}
            for _i, h in ipairs(f.history) do out[#out + 1] = { id = h.id, size = tostring(#h.data), modifiedTime = iso(f.mtime) } end
            return reply(200, { revisions = out })
        elseif path:match("^/drive/v3/files/[^/]+/revisions/[^/]+$") then
            local fid, rid = path:match("files/([^/]+)/revisions/([^/]+)$")
            local f = self.files[fid]
            local h
            for _i, x in ipairs(f and f.history or {}) do if x.id == rid then h = x end end
            if not h then return notFound() end
            if q.alt == "media" then
                local o = io.open(spec.sink_file, "wb"); o:write(h.data); o:close()
                return { code = 200, headers = {}, body = "" }
            end
            return reply(200, { id = h.id, md5Checksum = md5(h.data), size = tostring(#h.data) })
        elseif path:find("^/upload/drive/v3/files") and q.uploadType == "resumable" then
            local sid = "s" .. (#self.calls)
            self.sessions[sid] = { target = id, name = body and body.name, parent = body and body.parents and body.parents[1], got = "" }
            return reply(200, nil, { location = "https://www.googleapis.com/upload/session/" .. sid })
        elseif path:match("^/upload/session/") then
            local s = self.sessions[path:match("/session/(.+)$")]
            local data = spec.body_file and readFile(spec.body_file) or (spec.body or "")
            s.got = s.got .. data
            local a, b, total = tostring(spec.headers["Content-Range"] or ""):match("bytes (%d+)%-(%d+)/(%d+)")
            if a and tonumber(b) + 1 < tonumber(total) then
                return { code = 308, headers = { range = "bytes=0-" .. b }, body = "" }
            end
            local f
            if s.target then f = self.files[s.target]; setData(f, s.got) else f = make(s.name, s.parent, "application/octet-stream", s.got) end
            return reply(200, rec(f))
        end
        return reply(404, { error = { code = 404, message = "no such call " .. path, errors = { { reason = "notFound" } } } })
    end
    return self
end

return Fake
