--[[
The cloud services the sync can use. A provider is a module with these
members (see ink/sync/providers/dropbox.lua, and tests/sync/mockcloud.lua for
a pretend one the tests use). Adding Google Drive or OneDrive means writing one
more module like it and listing it here; the engine, the settings and the
screens do not change.

    id, name                     "dropbox", "Dropbox"
    HOSTS                        the hosts it may speak to
    beginAuth(app_key)           -> { url, verifier }   (an address to open on a phone)
    finishAuth(app_key, code, verifier) -> account record   (what to keep)
    new(account, opts)           -> an instance, which has:
      :accountInfo()             -> { id, name, email }
      :list(cursor)              -> { entries, cursor, reset }; an entry is
                                    { rel, rev, size, hash } or { rel, deleted = true }
      :download(rel, rev, dest)  -> { rev, size, hash }
      :upload(src, rel, expect)  -> { rev, size, hash }; `expect` is the revision the
                                    file builds on (nil: it must not exist yet), and a
                                    file changed meanwhile is refused with IA-S305
      :delete(rel, rev)
      :revisions(rel)            -> { { rev, size, mtime, current } }
      :restore(rel, rev)         -> { rev, size, hash }

Every call returns its result, or nil and an error from ink/sync/errors.lua.
]]

local Providers = {}

local LIST = {
    { id = "dropbox", name = "Dropbox", module = "ink/sync/providers/dropbox" },
}

-- The services that can be chosen: { { id, name } }.
function Providers.list()
    local out = {}
    for _i, p in ipairs(LIST) do out[#out + 1] = { id = p.id, name = p.name } end
    return out
end

-- The module for service `id`, or nil.
function Providers.get(id)
    for _i, p in ipairs(LIST) do
        if p.id == id then
            local ok, mod = pcall(require, p.module)
            return ok and mod or nil
        end
    end
end

-- The display name of service `id`.
function Providers.name(id)
    for _i, p in ipairs(LIST) do if p.id == id then return p.name end end
    return tostring(id)
end

return Providers
