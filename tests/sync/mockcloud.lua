-- A pretend cloud for the sync tests: the same calls as a real provider (see
-- ink/sync/providers.lua), kept in memory, with revisions, a change list that
-- cursors read, the refusal of an upload built on an old revision, and faults
-- the tests switch on. Several providers can share one cloud (several readers).
local Errors = require("ink/sync/errors")
local Hash = require("ink/sync/hash")

local Mock = {}

function Mock.cloud()
    return { files = {}, changes = {}, serial = 0, calls = {}, faults = {}, hook = nil }
end

local P = {}
P.__index = P

function Mock.provider(cloud, name)
    return setmetatable({ cloud = cloud, name = name or "mock" }, P)
end

local function lower(s) return s:lower() end

local function enter(self, op, rel)
    local c = self.cloud
    c.calls[#c.calls + 1] = op .. " " .. tostring(rel)
    if c.hook then c.hook(op, rel) end
    local f = c.faults[op]
    if f and #f > 0 then
        local e = table.remove(f, 1)
        if e ~= "pass" then return e end
    end
end

local function meta(f) return { rev = f.rev, size = #f.data, hash = f.hash, rel = f.rel } end

function P:list(cursor)
    local c = self.cloud
    local fault = enter(self, "list", cursor)
    if fault then return nil, fault end
    local n = tonumber(cursor)
    local reset = false
    if cursor and (not n or n > #c.changes) then reset = true; n = nil end
    local out = {}
    if not n then
        for _k, f in pairs(c.files) do out[#out + 1] = meta(f) end
    else
        local seen = {}
        for i = n + 1, #c.changes do
            local rel = c.changes[i]
            if not seen[lower(rel)] then
                seen[lower(rel)] = true
                local f = c.files[lower(rel)]
                out[#out + 1] = f and meta(f) or { rel = rel, deleted = true }
            end
        end
    end
    table.sort(out, function(a, b) return a.rel < b.rel end)
    return { entries = out, cursor = tostring(#c.changes), reset = reset }
end

function P:download(rel, rev, dest)
    local c = self.cloud
    local fault = enter(self, "download", rel)
    if fault then return nil, fault end
    local f = c.files[lower(rel)]
    if not f then return nil, Errors.make("IA-S307", rel) end
    local data = f.data
    if rev and rev ~= f.rev then
        data = f.history[rev]
        if not data then return nil, Errors.make("IA-S307", rel .. "@" .. rev) end
    end
    if c.corrupt_download then
        data = data:sub(1, math.max(1, #data - 3)) .. "XX"
        c.corrupt_download = nil
    end
    local out = io.open(dest, "wb")
    if not out then return nil, Errors.make("IA-S402") end
    out:write(data)
    out:close()
    return meta(f)
end

function P:upload(src, rel, expect)
    local c = self.cloud
    local fault = enter(self, "upload", rel)
    if fault then return nil, fault end
    local inf = io.open(src, "rb")
    if not inf then return nil, Errors.make("IA-S401") end
    local data = inf:read("*a")
    inf:close()
    local old = c.files[lower(rel)]
    if expect == nil then
        if old then return nil, Errors.make("IA-S305", rel) end
    else
        if not old or old.rev ~= expect then return nil, Errors.make("IA-S305", rel) end
    end
    c.serial = c.serial + 1
    local f = { rel = rel, data = data, rev = "r" .. c.serial, hash = Hash.dropboxOfString(data), history = old and old.history or {} }
    f.history[f.rev] = data
    c.files[lower(rel)] = f
    c.changes[#c.changes + 1] = rel
    return meta(f)
end

function P:delete(rel, rev)
    local c = self.cloud
    local fault = enter(self, "delete", rel)
    if fault then return nil, fault end
    local f = c.files[lower(rel)]
    if not f then return nil, Errors.make("IA-S307", rel) end
    if rev and rev ~= f.rev then return nil, Errors.make("IA-S305", rel) end
    c.files[lower(rel)] = nil
    c.changes[#c.changes + 1] = rel
    return true
end

function P:revisions(rel)
    local f = self.cloud.files[lower(rel)]
    if not f then return nil, Errors.make("IA-S307", rel) end
    local out = {}
    for rev, data in pairs(f.history) do out[#out + 1] = { rev = rev, size = #data, current = rev == f.rev } end
    table.sort(out, function(a, b) return tonumber(a.rev:sub(2)) > tonumber(b.rev:sub(2)) end)
    return out
end

function P:restore(rel, rev)
    local c = self.cloud
    local f = c.files[lower(rel)]
    if not f or not f.history[rev] then return nil, Errors.make("IA-S307", rel) end
    c.serial = c.serial + 1
    local nf = { rel = rel, data = f.history[rev], rev = "r" .. c.serial, history = f.history }
    nf.hash = Hash.dropboxOfString(nf.data)
    nf.history[nf.rev] = nf.data
    c.files[lower(rel)] = nf
    c.changes[#c.changes + 1] = rel
    return meta(nf)
end

-- Put a file into the cloud as if another reader had sent it.
function Mock.put(cloud, rel, data)
    local p = Mock.provider(cloud, "other")
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb"); f:write(data); f:close()
    local old = cloud.files[lower(rel)]
    local m = p:upload(tmp, rel, old and old.rev or nil)
    os.remove(tmp)
    return m
end

return Mock
