--[[
Hashes for the cloud sync (see ink/sync/). A file is known by its SHA-256, and
Dropbox by its "content hash": the SHA-256 of the SHA-256s of the file's 4 MB
blocks. Both are read from the file a piece at a time, so a big notebook does not
fill the reader's memory. KOReader's own SHA-2 code is used (pure Lua, so a
large file takes a moment; the sync does it in the background).
]]

local Hash = {}

Hash.BLOCK = 4 * 1024 * 1024
Hash.CHUNK = 256 * 1024

local function sha() return require("ffi/sha2") end

-- Hex text as the bytes it stands for.
local function unhex(h)
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end
Hash.unhex = unhex

-- The SHA-256 of a string, as hex.
function Hash.sha256(s)
    return sha().sha256(s)
end

-- The SHA-256 of a string, as 32 raw bytes.
function Hash.sha256bin(s)
    return unhex(sha().sha256(s))
end

-- Read `path` in blocks of `size` bytes, calling fn(block) for each. Returns
-- the byte count, or nil and why not.
local function eachBlock(path, size, fn)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local total = 0
    while true do
        local block = f:read(size)
        if not block or block == "" then break end
        total = total + #block
        fn(block)
    end
    f:close()
    return total
end

-- The SHA-256 of the file at `path`, as hex, and its size. Or nil and why not.
function Hash.file(path)
    local s = sha()
    local ok, feed = pcall(s.sha256)   -- (a hasher that takes pieces: call it with the text, then with nil)
    if not ok or type(feed) ~= "function" then
        local f, err = io.open(path, "rb")
        if not f then return nil, err end
        local data = f:read("*a")
        f:close()
        return s.sha256(data), #data
    end
    local total, err = eachBlock(path, Hash.CHUNK, function(b) feed(b) end)
    if not total then return nil, err end
    return feed(), total
end

-- Dropbox's content hash of the file at `path`, as hex. Or nil and why not.
function Hash.dropbox(path)
    local parts = {}
    local total, err = eachBlock(path, Hash.BLOCK, function(b) parts[#parts + 1] = Hash.sha256bin(b) end)
    if not total then return nil, err end
    return Hash.sha256(table.concat(parts)), total
end

-- The same for a string held in memory (the tests, and small files).
function Hash.dropboxOfString(data)
    local parts = {}
    for i = 1, math.max(#data, 1), Hash.BLOCK do
        if #data == 0 and i > 1 then break end
        parts[#parts + 1] = Hash.sha256bin(data:sub(i, i + Hash.BLOCK - 1))
    end
    if #data == 0 then parts = {} end
    return Hash.sha256(table.concat(parts))
end

-- A short, cheap identity for a big file that is only needed to tell two files
-- apart (a PDF or picture a notebook uses): its size and a hash of its first and
-- last 64 KB. Or nil and why not.
function Hash.quick(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local size = f:seek("end")
    f:seek("set", 0)
    local head = f:read(65536) or ""
    local tail = ""
    if size > 131072 then
        f:seek("set", size - 65536)
        tail = f:read(65536) or ""
    end
    f:close()
    return string.format("%d-%s", size, Hash.sha256(head .. "|" .. tail):sub(1, 24)), size
end

return Hash
