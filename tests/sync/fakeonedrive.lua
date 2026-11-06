-- A pretend OneDrive for the tests: the parts of Microsoft Graph that
-- ink/sync/providers/onedrive.lua uses, kept in memory, behind Http.transport.
local Json = require("ink/sync/json")

local Fake = {}

local function sha1(s) return require("ffi/sha2").sha1(s):upper() end
local function unescape(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
local function readFile(p) local f = io.open(p, "rb"); local s = f and f:read("*a"); if f then f:close() end return s end

function Fake.new()
    local self = { items = {}, log = {}, serial = 0, clock = 1700000000, page = 1000, calls = {}, sessions = {},
        root = { id = "ROOT" }, hashes = "sha1" }
    local function rec(f)
        local it = { id = f.id, name = f.name, parentReference = { id = f.parent }, lastModifiedDateTime = iso(f.mtime) }
        if f.folder then it.folder = { childCount = 0 }
        else
            it.file = { hashes = {} }
            if self.hashes == "sha1" then it.file.hashes.sha1Hash = sha1(f.data) else it.file.hashes.quickXorHash = require("ink/sync/hash").quickXorOfString(f.data) end
            it.size, it.eTag, it.cTag = #f.data, '"e' .. f.id .. "," .. f.v .. '"', '"c' .. f.id .. "," .. f.v .. '"'
        end
        return it
    end
    local function touch(f, deleted)
        self.clock = self.clock + 1
        f.mtime = self.clock
        local it = rec(f)
        if deleted then it = { id = f.id, deleted = {} } end
        self.log[#self.log + 1] = it
    end
    local function child(parent, name)
        for _id, f in pairs(self.items) do if f.parent == parent and f.name == name and not f.gone then return f end end
    end
    -- the item at a path (folders made on the way when `make` is true)
    local function at(path, make)
        local parent, cur = "ROOT", nil
        local parts = {}
        for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end
        for i, name in ipairs(parts) do
            cur = child(parent, name)
            if not cur and make and i < #parts then
                self.serial = self.serial + 1
                cur = { id = "d" .. self.serial, name = name, parent = parent, folder = true, v = 1 }
                self.items[cur.id] = cur
                touch(cur)
            end
            if not cur then return nil, parent, name end
            parent = cur.id
        end
        return cur, parent, parts[#parts]
    end
    local function put(path, data)
        local f, parent, name = at(path, true)
        if not f then
            self.serial = self.serial + 1
            f = { id = "f" .. self.serial, name = name, parent = parent, v = 0, versions = {} }
            self.items[f.id] = f
        end
        f.v = f.v + 1
        f.data = data
        f.versions[#f.versions + 1] = { id = tostring(f.v) .. ".0", data = data, mtime = self.clock }
        touch(f)
        return f
    end
    local function reply(code, v, headers) return { code = code, headers = headers or {}, body = v ~= nil and Json.encode(v) or "" } end
    local function err(code, g) return reply(code, { error = { code = g, message = g } }) end
    local function readBody(spec) return spec.body_file and readFile(spec.body_file) or spec.body or "" end

    function self.byPath(path) return (at(path)) end
    function self.content(path) local f = at(path); return f and f.data end
    function self.set(path, data) put(path, data) end
    function self.count(prefix) local n = 0 for _i, c in ipairs(self.calls) do if c:find(prefix, 1, true) then n = n + 1 end end return n end

    function self.transport(spec)
        local host, path, qs = spec.url:match("^https://([^/]+)([^?]*)%??(.*)$")
        path = unescape(path or "")
        local m = spec.method or "GET"
        self.calls[#self.calls + 1] = m .. " " .. host .. path
        if host == "graph.microsoft.com" then
            if path == "/v1.0/me" then return reply(200, { id = "u1", displayName = "Grace", mail = "g@x.org" }) end
            if path == "/v1.0/me/drive/special/approot" then return reply(200, { id = "ROOT" }) end
            if path == "/v1.0/me/drive/special/approot/delta" then
                local from = tonumber(qs:match("token=(%d+)")) or 0
                local list = {}
                for i = from + 1, math.min(#self.log, from + self.page) do list[#list + 1] = self.log[i] end
                if from == 0 then table.insert(list, 1, { id = "ROOT", root = {}, name = "root" }) end
                local nxt = from + self.page
                if nxt < #self.log then
                    return reply(200, { value = list, ["@odata.nextLink"] = "https://graph.microsoft.com/v1.0/me/drive/special/approot/delta?token=" .. nxt })
                end
                return reply(200, { value = list, ["@odata.deltaLink"] = "https://graph.microsoft.com/v1.0/me/drive/special/approot/delta?token=" .. #self.log })
            end
            local rel, more = path:match("^/v1%.0/me/drive/special/approot:/(.-):(.*)$")
            if rel then
                local f = at(rel)
                if more == "" and m == "GET" then
                    if not f or f.gone then return err(404, "itemNotFound") end
                    return reply(200, rec(f))
                elseif more == "" and m == "DELETE" then
                    if not f then return err(404, "itemNotFound") end
                    if spec.headers["If-Match"] and spec.headers["If-Match"] ~= rec(f).eTag then return err(412, "preconditionFailed") end
                    f.gone = true
                    touch(f, true)
                    return { code = 204, headers = {}, body = "" }
                elseif more == "/content" and m == "GET" then
                    if not f then return err(404, "itemNotFound") end
                    return { code = 302, headers = { location = "https://public.files.1drv.com/dl/" .. f.id }, body = "" }
                elseif more == "/content" and m == "PUT" then
                    local mode = qs:match("conflictBehavior=(%a+)")
                    if f and mode == "fail" then return err(409, "nameAlreadyExists") end
                    if f and spec.headers["If-Match"] and spec.headers["If-Match"] ~= rec(f).eTag then return err(412, "preconditionFailed") end
                    return reply(201, rec(put(rel, readBody(spec))))
                elseif more == "/createUploadSession" then
                    if f and spec.headers["If-Match"] and spec.headers["If-Match"] ~= rec(f).eTag then return err(412, "preconditionFailed") end
                    local sid = "S" .. #self.calls
                    self.sessions[sid] = { rel = rel, got = "" }
                    return reply(200, { uploadUrl = "https://api.onedrive.com/rup/" .. sid })
                elseif more == "/versions" then
                    if not f then return err(404, "itemNotFound") end
                    local out = {}
                    for i = #f.versions, 1, -1 do
                        out[#out + 1] = { id = f.versions[i].id, size = #f.versions[i].data, lastModifiedDateTime = iso(f.versions[i].mtime) }
                    end
                    return reply(200, { value = out })
                else
                    local vid = more:match("^/versions/([^/]+)/content$")
                    if vid and f then
                        for _i, v in ipairs(f.versions) do
                            if v.id == vid then return { code = 302, headers = { location = "https://public.files.1drv.com/ver/" .. f.id .. "/" .. vid }, body = "" } end
                        end
                    end
                end
            end
        elseif host == "public.files.1drv.com" then
            local fid, vid = path:match("^/ver/([^/]+)/(.+)$")
            local f = self.items[fid or path:match("^/dl/(.+)$")]
            local data = f and f.data
            if vid then for _i, v in ipairs(f.versions) do if v.id == vid then data = v.data end end end
            if not data then return err(404, "itemNotFound") end
            if self.corrupt then data = data .. "x" end
            local o = io.open(spec.sink_file, "wb"); o:write(data); o:close()
            return { code = 200, headers = {}, body = "" }
        elseif host == "api.onedrive.com" then
            local s = self.sessions[path:match("/rup/(.+)$")]
            s.got = s.got .. readBody(spec)
            local _a, b, total = tostring(spec.headers["Content-Range"] or ""):match("bytes (%d+)%-(%d+)/(%d+)")
            if tonumber(b) + 1 < tonumber(total) then
                return reply(202, { nextExpectedRanges = { tostring(tonumber(b) + 1) .. "-" } })
            end
            return reply(201, rec(put(s.rel, s.got)))
        end
        return err(404, "itemNotFound")
    end
    return self
end

return Fake
