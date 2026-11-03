--[[
The books the cloud sync knows (see ink/sync/areas.lua, "Ink on book pages"): each
book by its checksum (the same on every reader, whatever the file is called or
where it is kept), with the folder on this reader that holds its ink. The sync
only ever touches a book's own ink file and pictures in that folder, and only
for books listed here. A book is listed when it is opened with Ink Away, and when
the sync looks through the reading history.

Kept in the sync's own folder as books.json. Plain Lua (the folder and the
questions to KOReader are passed in), so the headless tests drive it.
]]

local Json = require("ink/sync/json")
local Storage = require("ink/storage")

local BookIndex = {}

BookIndex.FILE = "books.json"
BookIndex.SCAN_EVERY = 3600   -- seconds between looks through the history

local function path(dir) return Storage.join(dir, BookIndex.FILE) end

-- The index in `dir`: { books = { [md5] = { dir, file } }, scanned = time }.
function BookIndex.load(dir)
    local f = io.open(path(dir), "rb")
    local t
    if f then
        t = Json.decode(f:read("*a") or "")
        f:close()
    end
    if type(t) ~= "table" or type(t.books) ~= "table" then t = { books = {} } end
    return t
end

function BookIndex.save(dir, index)
    return Storage.writeAtomic(path(dir), Json.encode(index))
end

local function validMd5(md5) return type(md5) == "string" and md5:match("^%x+$") ~= nil and #md5 >= 8 and #md5 <= 64 end

-- Note a book: its checksum, the folder of its ink here, its file. Writes only
-- when something changed. Returns whether the book is listed now.
function BookIndex.note(dir, md5, sidecar, file)
    if not (validMd5(md5) and sidecar and sidecar ~= "") then return false end
    md5 = md5:lower()
    local index = BookIndex.load(dir)
    local cur = index.books[md5]
    if cur and cur.dir == sidecar and cur.file == file then return true end
    index.books[md5] = { dir = sidecar, file = file }
    BookIndex.save(dir, index)
    return true
end

-- The listed books as { [md5] = { dir, file } }.
function BookIndex.list(dir)
    return BookIndex.load(dir).books
end

-- Look through `files` (paths of books, from the reading history) and list those
-- that exist. `md5Of(file)` and `dirOf(file)` ask KOReader. Done at most once per
-- SCAN_EVERY unless `force`. Returns how many were listed.
function BookIndex.scan(dir, files, md5Of, dirOf, now, force)
    local index = BookIndex.load(dir)
    if not force and index.scanned and now - index.scanned < BookIndex.SCAN_EVERY then return 0 end
    local n = 0
    for i, file in ipairs(files) do
        if i > 1000 then break end
        if Storage.exists(file) then
            local ok, md5 = pcall(md5Of, file)
            local okd, bdir = pcall(dirOf, file)
            if ok and okd and validMd5(md5) and bdir and bdir ~= "" then
                local cur = index.books[md5:lower()]
                if not cur or cur.dir ~= bdir or cur.file ~= file then
                    index.books[md5:lower()] = { dir = bdir, file = file }
                    n = n + 1
                end
            end
        end
    end
    index.scanned = now
    BookIndex.save(dir, index)
    return n
end

return BookIndex
