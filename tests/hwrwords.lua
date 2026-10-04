-- The word decoder (ink/hwrwords.lua) against the training project's own
-- decoder (tests/hwr_word_vectors.lua, made by export_word_vectors.py): the
-- same letter scores must give the same word.
-- Run from the plugin root with:  luajit tests/hwrwords.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local HwrNet = require("ink/hwrnet")
local Words = require("ink/hwrwords")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local net = assert(HwrNet.load("ink/data/hwr_en.bin"))
local t0 = os.clock()
local dec, err = Words.load("ink/data/hwr_words_en.txt", net.classes)
local load_ms = (os.clock() - t0) * 1000
ok(dec ~= nil, "the word list loads (" .. tostring(err) .. ")")
local count = 0
for _, e in pairs(dec.by_len) do count = count + #e.words end
ok(count > 40000, ("it holds the whole list (%d words)"):format(count))

local function logSoftmax(z)
    local m = -math.huge
    for i = 1, #z do if z[i] > m then m = z[i] end end
    local s = 0
    for i = 1, #z do s = s + math.exp(z[i] - m) end
    local out, lse = {}, m + math.log(s)
    for i = 1, #z do out[i] = z[i] - lse end
    return out
end

local vectors = dofile("tests/hwr_word_vectors.lua")
local same, right, dict_right, n_dict = 0, 0, 0, 0
local t1 = os.clock()
for _, v in ipairs(vectors) do
    local lps = {}
    for p, z in ipairs(v.logits) do lps[p] = logSoftmax(z) end
    local text, used = dec:decode(lps)
    if text == v.text and used == v.dict then same = same + 1
    else print(("  differs: %s -> lua %s (%s), python %s (%s)"):format(v.word, text, tostring(used), v.text, tostring(v.dict))) end
    if text:lower() == v.word:lower() then right = right + 1 end
end
local per_word = (os.clock() - t1) * 1000 / #vectors
ok(same == #vectors, ("every word decodes as in the training project (%d of %d)"):format(same, #vectors))
print(("hwrwords: list loads in %.0f ms, %.2f ms per word; %d of %d test words right"):format(
    load_ms, per_word, right, #vectors))

-- a word the list does not know is kept as read when the letters are clear
local function sure(ch)
    local lp = {}
    for i = 1, #net.classes do lp[i] = (net.classes[i] == ch) and -0.01 or -12 end
    return lp
end
local text, used = dec:decode({ sure("B"), sure("5"), sure("2") })
ok(text == "B52" and not used, "a clear code (B52) stays as written (" .. text .. ")")
text, used = dec:decode({ sure("2"), sure("0"), sure("4") })
ok(text == "204" and not used, "a clear number stays a number")
text, used = dec:decode({ sure("C"), sure("a"), sure("t") })
ok(text == "cat" and used, "a clear word comes back from the list in small letters")

print(("hwrwords: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
