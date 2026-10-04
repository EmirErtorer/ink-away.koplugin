-- A stand-in for KOReader's lfs, through the shell: enough of attributes, dir,
-- mkdir and rmdir for Storage, on macOS and Linux.
local lfs = {}

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function sh(cmd)
    local p = io.popen("{ " .. cmd .. "; } 2>/dev/null")
    local out = p:read("*a")
    p:close()
    return out
end

function lfs.attributes(path, field)
    local out = sh("if [ -d " .. q(path) .. " ]; then echo directory; elif [ -e " .. q(path) .. " ]; then echo file; fi; "
        .. "stat -f '%m %z' " .. q(path) .. " || stat -c '%Y %s' " .. q(path))
    local mode, mtime, size = out:match("^(%a+)\n(%d+) (%d+)")
    if not mode then return nil end
    local attr = { mode = mode, modification = tonumber(mtime), size = tonumber(size) }
    if field then return attr[field] end
    return attr
end

function lfs.mkdir(path)
    sh("mkdir " .. q(path))
    return lfs.attributes(path, "mode") == "directory" or nil
end

function lfs.rmdir(path)
    sh("rmdir " .. q(path))
    return lfs.attributes(path, "mode") == nil or nil
end

function lfs.dir(path)
    local names = { ".", ".." }
    for name in sh("ls -A " .. q(path)):gmatch("[^\n]+") do names[#names + 1] = name end
    local i = 0
    return function()
        i = i + 1
        return names[i]
    end
end

return lfs
