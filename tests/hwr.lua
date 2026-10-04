-- Handwriting to text without the view: splitting strokes into lines, words and
-- characters, choosing capitals, and the whole path end to end on real pen
-- strokes (tests/hwr_writers.lua: UJI test writers' letters, laid out here as
-- words on a line), through the model and the word list.
-- Run from the plugin root with:  luajit tests/hwr.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Hwr = require("ink/hwr")
local HwrNet = require("ink/hwrnet")
local Words = require("ink/hwrwords")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function shape(lines)
    local out = {}
    for _, line in ipairs(lines) do
        local ws = {}
        for _, w in ipairs(line.words) do
            local cs = {}
            for _, c in ipairs(w.chars) do cs[#cs + 1] = tostring(#c.strokes) end
            ws[#ws + 1] = table.concat(cs, ",")
        end
        out[#out + 1] = table.concat(ws, " ")
    end
    return table.concat(out, " / ")
end

------------------------------------------------------------------------------
-- Splitting: strokes into lines, words and characters
------------------------------------------------------------------------------
do
    -- an H in three strokes: two stems then the bar joining them
    local H = { { 0, 0, 0, 100 }, { 60, 0, 60, 100 }, { 0, 50, 60, 50 } }
    ok(shape(Hwr.segment(H)) == "3", "an H's bar joins its two stems into one character")
    -- "it" with the dot and the cross added after the word
    local it = { { 0, 40, 0, 100 }, { 40, 10, 40, 100 }, { 0, 20, 0, 22 }, { 25, 40, 60, 40 } }
    ok(shape(Hwr.segment(it)) == "2,2", "a late dot and a late cross find their letters (" .. shape(Hwr.segment(it)) .. ")")
    -- two words: the gap between them is wider than half a letter
    local two = { { 0, 0, 0, 100 }, { 40, 0, 40, 100 }, { 160, 0, 160, 100 }, { 200, 0, 200, 100 } }
    ok(shape(Hwr.segment(two)) == "1,1 1,1", "a wide gap is a space (" .. shape(Hwr.segment(two)) .. ")")
    -- two lines
    local lines = { { 0, 0, 0, 100 }, { 40, 0, 40, 100 }, { 0, 200, 0, 300 }, { 40, 200, 40, 300 } }
    ok(shape(Hwr.segment(lines)) == "1,1 / 1,1", "lines are found top to bottom")
    ok(#Hwr.segment({}) == 0, "no strokes, no lines")
    -- a crossbar that reaches into the next letter stays with its own (t then h)
    local th = { { 10, 0, 10, 100 }, { 0, 30, 34, 30 }, { 40, 0, 40, 100 }, { 40, 60, 60, 50, 70, 100 } }
    ok(shape(Hwr.segment(th)) == "2,2", "a t's cross reaching the next letter stays with the t (" .. shape(Hwr.segment(th)) .. ")")
end

------------------------------------------------------------------------------
-- Capitals
------------------------------------------------------------------------------
do
    local classes = {}
    for ch in ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabdefghnqrt"):gmatch(".") do classes[#classes + 1] = ch end
    local index = {}
    for i, c in ipairs(classes) do index[c] = i end
    local function lp(favour)   -- log probabilities favouring one class
        local t = {}
        for i = 1, #classes do t[i] = (classes[i] == favour) and -0.1 or -6 end
        return t
    end
    local function box(h) return { x0 = 0, y0 = 0, x1 = 10, y1 = h } end
    -- "hello": H read as a capital, the rest small
    local cased = Hwr.cased("hello", { box(30), box(20), box(30), box(30), box(20) },
        { lp("H"), lp("e"), lp("L"), lp("L"), lp("O") }, classes, 20)
    ok(cased == "Hello", "a capital first letter: " .. cased)
    cased = Hwr.cased("hello", { box(30), box(20), box(30), box(30), box(20) },
        { lp("h"), lp("e"), lp("L"), lp("L"), lp("O") }, classes, 20)
    ok(cased == "hello", "small letters stay small: " .. cased)
    -- "rate" in capitals: R A T E all read as capitals
    cased = Hwr.cased("rate", { box(30), box(30), box(30), box(30) },
        { lp("R"), lp("A"), lp("T"), lp("E") }, classes, nil)
    ok(cased == "RATE", "a word of capitals: " .. cased)
    -- "so": both look alike in either case; tall against the x-height means capitals
    ok(Hwr.cased("so", { box(30), box(30) }, { lp("S"), lp("O") }, classes, 20, 30) == "SO", "tall look-alikes are capitals")
    ok(Hwr.cased("so", { box(20), box(20) }, { lp("S"), lp("O") }, classes, 20, 20) == "so", "short ones are small")
    ok(Hwr.cased("so", { box(30), box(30) }, { lp("S"), lp("O") }, classes, nil, 30) == "so", "and without a guide, small")
    ok(Hwr.cased("B52", { box(30), box(30), box(30) }, { lp("B"), lp("5"), lp("2") }, classes, 20) == "B52",
        "a code keeps its capital and digits")
    local xh, base = Hwr.lineMetrics({ box(20), box(30), box(22) }, classes, { index["a"], index["H"], index["e"] })
    ok(xh == 20 and base == 22, "the x-height comes from the small a, e, n and r, the baseline from the bottoms")
    -- "buy": b read as small, u short, y hanging below the line: all small
    local function at(top, bottom) return { x0 = 0, y0 = top, x1 = 10, y1 = bottom } end
    ok(Hwr.cased("buy", { at(70, 100), at(80, 100), at(80, 112) }, { lp("b"), lp("U"), lp("Y") }, classes, 20, 100) == "buy",
        "a letter hanging below the line is small, not a capital: " ..
        Hwr.cased("buy", { at(70, 100), at(80, 100), at(80, 112) }, { lp("b"), lp("U"), lp("Y") }, classes, 20, 100))
    ok(Hwr.cased("buy", { at(68, 100), at(80, 100), at(80, 112) }, { lp("B"), lp("U"), lp("Y") }, classes, 20, 100) == "Buy",
        "a capital B starts the word")
end

------------------------------------------------------------------------------
-- End to end, on real pen strokes
------------------------------------------------------------------------------
do
    local net = assert(HwrNet.load("ink/data/hwr_en.bin"))
    local words = assert(Words.load("ink/data/hwr_words_en.txt", net.classes))
    local writers = dofile("tests/hwr_writers.lua")

    local function box(strokes)
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for _, s in ipairs(strokes) do
            for i = 1, #s - 1, 2 do
                x0, x1 = math.min(x0, s[i]), math.max(x1, s[i])
                y0, y1 = math.min(y0, s[i + 1]), math.max(y1, s[i + 1])
            end
        end
        return x0, y0, x1, y1
    end
    -- Write `text` in a writer's hand: letters side by side on a baseline, small
    -- letters an x-height tall, capitals and ascenders taller, descenders below.
    -- With `late`, i and j dots and t crosses are added after each word.
    local ASC, DESC, CAP = "bdfhklt", "gjpqy", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local function write(hand, text, late)
        local xh = 300                               -- 3 mm small letters
        local strokes, held = {}, {}
        local x = 0
        for ch in text:gmatch(".") do
            if ch == " " then
                for _, s in ipairs(held) do strokes[#strokes + 1] = s end
                held = {}
                x = x + 0.9 * xh
            else
                local src = hand[ch]
                local x0, y0, x1, y1 = box(src)
                local tall = CAP:find(ch, 1, true) or ASC:find(ch, 1, true)
                local h = tall and 1.6 * xh or xh
                if ch == "i" or ch == "j" then h = 1.4 * xh end
                local s = h / math.max(y1 - y0, 1)
                local bottom = DESC:find(ch, 1, true) and 0.5 * xh or 0
                if DESC:find(ch, 1, true) then s = 1.5 * xh / math.max(y1 - y0, 1) end
                for k, st in ipairs(src) do
                    local t = {}
                    for i = 1, #st - 1, 2 do
                        t[#t + 1] = x + (st[i] - x0) * s
                        t[#t + 1] = bottom - (y1 - st[i + 1]) * s
                    end
                    -- the last, short stroke of an i, j or t is its dot or cross
                    if late and k > 1 and k == #src and (ch == "i" or ch == "j" or ch == "t") then
                        held[#held + 1] = t
                    else
                        strokes[#strokes + 1] = t
                    end
                end
                x = x + (x1 - x0) * s + 0.3 * xh
            end
        end
        for _, s in ipairs(held) do strokes[#strokes + 1] = s end
        return strokes
    end
    local function read(strokes)
        local out_lines = {}
        for _, line in ipairs(Hwr.segment(strokes)) do
            local all_chars, all_best, per = {}, {}, {}
            for wi, w in ipairs(line.words) do
                local lps = {}
                for ci, c in ipairs(w.chars) do lps[ci] = net:classify(c.strokes) end
                local text, _, best = words:decode(lps)
                per[wi] = { text = text, lps = lps }
                for ci, c in ipairs(w.chars) do all_chars[#all_chars + 1] = c; all_best[#all_best + 1] = best[ci] end
            end
            local xh, base = Hwr.lineMetrics(all_chars, net.classes, all_best)
            local out = {}
            for wi, w in ipairs(line.words) do out[wi] = Hwr.cased(per[wi].text, w.chars, per[wi].lps, net.classes, xh, base) end
            out_lines[#out_lines + 1] = table.concat(out, " ")
        end
        return table.concat(out_lines, "\n")
    end

    local phrases = { "the quick brown fox jumps over the lazy dog", "buy milk and eggs",
        "meet me at noon", "notes from the lecture", "call mom today", "Hello world",
        "chapter one summary", "room 204", "write it down", "think twice" }
    local total, right, exact_lines, n_lines = 0, 0, 0, 0
    local names = {}
    for name in pairs(writers) do names[#names + 1] = name end
    table.sort(names)
    local t0 = os.clock()
    local chars_read = 0
    for _, name in ipairs(names) do
        for pi, phrase in ipairs(phrases) do
            local got = read(write(writers[name], phrase, pi % 2 == 0))
            for ch in phrase:gmatch("%S") do chars_read = chars_read + 1 end
            local want = {}
            for w in phrase:gmatch("%S+") do want[#want + 1] = w end
            local have = {}
            for w in got:gmatch("%S+") do have[#have + 1] = w end
            for i, w in ipairs(want) do
                total = total + 1
                if have[i] and have[i]:lower() == w:lower() then right = right + 1 end
            end
            n_lines = n_lines + 1
            if got:lower() == phrase:lower() then exact_lines = exact_lines + 1 end
            if os.getenv("V") then print(("  %s: %-44s -> %s"):format(name, phrase, got)) end
        end
    end
    local ms = (os.clock() - t0) * 1000 / chars_read
    print(("hwr: end to end, %d of %d words right (%.0f%%), %d of %d phrases exact, %.1f ms per character"):format(
        right, total, 100 * right / total, exact_lines, n_lines, ms))
    ok(right >= 0.8 * total, "most words written by unseen hands come out right")
    local got = read(write(writers[names[1]], "Hello world"))
    ok(got:sub(1, 1):match("%u") ~= nil and got:sub(2, 2):match("%l") ~= nil,
        "a capital first letter stays a capital, the rest small (" .. got .. ")")
end

print(("hwr: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
