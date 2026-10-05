-- The handwriting model in Lua (ink/hwrnet.lua) against the training project's
-- own output (tests/hwr_vectors.lua, made by inkaway-handwriting-model/export.py):
-- the same strokes must render to the same image and score the same.
-- Run from the plugin root with:  luajit tests/hwrnet.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local HwrNet = require("ink/hwrnet")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local net, err = HwrNet.load("ink/data/hwr_en.bin")
ok(net ~= nil, "the model loads (" .. tostring(err) .. ")")
ok(net and #net.classes == 47 and table.concat(net.classes):sub(1, 12) == "0123456789AB", "with its 47 classes")
ok(net and math.abs(net.fit - 19.5) < 1e-6 and math.abs(net.radius - 1.6) < 1e-6, "and the renderer settings")

-- ARM readers (Kindle, Kobo) stop the whole program on an unaligned float
-- load, which a laptop never shows: the loader must not read numbers through a
-- typed pointer into the file's bytes.
do
    local f = assert(io.open("ink/hwrnet.lua", "r"))
    local src = f:read("*a")
    f:close()
    local typed = 0
    for t in src:gmatch('ffi%.cast%("([%w_]+)%*", buf') do if t ~= "int8_t" and t ~= "uint8_t" then typed = typed + 1 end end
    ok(typed == 0, ("the model file is read without typed pointers into its bytes (%d found)"):format(typed))
end

local vectors = dofile("tests/hwr_vectors.lua")
local worst_img, worst_logit, agree = 0, 0, 0
for _, v in ipairs(vectors) do
    local img = HwrNet.render(v.strokes, net.fit, net.radius)
    for i = 1, 784 do worst_img = math.max(worst_img, math.abs(img[i - 1] - v.image[i])) end
    -- score the reference image, so a rendering difference cannot hide a network one
    local ref = require("ffi").new("float[784]", v.image)
    local z = net:logits(ref)
    local best, bi, rbest, ri = -math.huge, 0, -math.huge, 0
    for i = 1, 47 do
        worst_logit = math.max(worst_logit, math.abs(z[i] - v.logits[i]))
        if z[i] > best then best, bi = z[i], i end
        if v.logits[i] > rbest then rbest, ri = v.logits[i], i end
    end
    if bi == ri then agree = agree + 1 end
end
ok(worst_img < 2e-3, ("rendering matches the training renderer (worst pixel off by %.5f)"):format(worst_img))
ok(worst_logit < 2e-3, ("the network matches the exported model (worst score off by %.5f)"):format(worst_logit))
ok(agree == #vectors, ("the same answer for all %d characters (%d)"):format(#vectors, agree))

-- end to end on the strokes, and how long a character takes
local right = 0
local t0 = os.clock()
local reps = 5
for _ = 1, reps do
    for _, v in ipairs(vectors) do
        local lp = net:classify(v.strokes)
        local bi, best = 1, -math.huge
        for i = 1, 47 do if lp[i] > best then best, bi = lp[i], i end end
        local want = v.ch
        if ("cijklmopsuvwxyz"):find(want, 1, true) then want = want:upper() end
        if net.classes[bi] == want then right = right + 1 end
    end
end
local ms = (os.clock() - t0) * 1000 / (reps * #vectors)
print(("hwrnet: %.2f ms per character on this machine; %d of %d test characters right"):format(
    ms, right / reps, #vectors))
ok(right / reps >= #vectors * 0.75, "most test characters come out right")

print(("hwrnet: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
