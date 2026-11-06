-- The hashes of the cloud sync (ink/sync/hash.lua). Needs KOReader's SHA-2 code
-- from the checkout (KO_SRC, default ~/koreader-emulator).
--   luajit tests/sync/hash.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;" .. KO .. "/base/?.lua;" .. package.path
local Hash = require("ink/sync/hash")
local checks, fails = 0, 0
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end
local function write(path, data) local f = io.open(path, "wb"); f:write(data); f:close() end

eq(Hash.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 known value")
eq(Hash.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 of nothing")
eq(#Hash.sha256bin("abc"), 32, "binary digest is 32 bytes")

local tmp = os.tmpname()
write(tmp, "abc")
local h, n = Hash.file(tmp)
eq(h, Hash.sha256("abc"), "file hash is the string hash")
eq(n, 3, "file size")
-- a file bigger than one read chunk hashes the same as the whole string
local big = string.rep("0123456789abcdef", 40000)   -- 640000 bytes
write(tmp, big)
eq((Hash.file(tmp)), Hash.sha256(big), "chunked file hash")

-- Dropbox: one block is sha256 of the block's sha256
eq(Hash.dropboxOfString("abc"), Hash.sha256(Hash.sha256bin("abc")), "content hash of a small file")
eq(Hash.dropboxOfString(""), Hash.sha256(""), "content hash of an empty file")
local d1 = Hash.dropbox(tmp)
eq(d1, Hash.dropboxOfString(big), "content hash of a file equals that of its text")
-- two blocks: hash of the two block digests
local two = string.rep("x", Hash.BLOCK) .. "yz"
write(tmp, two)
eq((Hash.dropbox(tmp)), Hash.sha256(Hash.sha256bin(two:sub(1, Hash.BLOCK)) .. Hash.sha256bin("yz")), "content hash over two blocks")

eq(Hash.file("/nonexistent/x"), nil, "a missing file is nil")
write(tmp, "a")
local q1 = Hash.quick(tmp)
write(tmp, "b")
local q2 = Hash.quick(tmp)
eq(q1 ~= q2, true, "quick id differs for different content")
os.remove(tmp)

print(string.format("hash: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
