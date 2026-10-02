--[[
Files and folders: small helpers for the paths Ink Away saves to.
]]

local Storage = {}

-- Return `p` if it is an existing directory, else nil.
local function existingDir(p)
    if not p then return nil end
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (lok and lfs) or lfs.attributes(p, "mode") == "directory" then return p end
    return nil
end

Storage.existingDir = existingDir

return Storage
