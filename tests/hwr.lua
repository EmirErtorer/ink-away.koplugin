-- Tests for the pure handwriting recogniser (ink/hwr): the $P point-cloud matcher,
-- its normalisation, and that it is order/scale/position tolerant while still
-- telling distinct shapes apart. Pure Lua under luajit.
--
--   luajit tests/hwr.lua

package.path = "./?.lua;" .. package.path
local Hwr = require("ink/hwr")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- Build a stroke {x=,y=} list from a flat {x1,y1,x2,y2,...} list.
local function stroke(flat)
    local s = {}
    for i = 1, #flat, 2 do s[#s + 1] = { x = flat[i], y = flat[i + 1] } end
    return s
end
local function G(...) return { ... } end   -- a gesture = list of strokes

-- A small alphabet of distinct synthetic shapes.
local VBAR = G(stroke{ 5, 0, 5, 10 })                        -- vertical line
local HBAR = G(stroke{ 0, 5, 10, 5 })                        -- horizontal line
local SLASH = G(stroke{ 0, 10, 10, 0 })                      -- /
local BACKSLASH = G(stroke{ 0, 0, 10, 10 })                  -- \
local PLUS = G(stroke{ 0, 5, 10, 5 }, stroke{ 5, 0, 5, 10 }) -- + (two strokes)
local EX = G(stroke{ 0, 0, 10, 10 }, stroke{ 0, 10, 10, 0 }) -- X (two strokes)
local BOX = G(stroke{ 0, 0, 10, 0, 10, 10, 0, 10, 0, 0 })    -- square

-- ---- normalisation -----------------------------------------------------------
do
    local c = Hwr.normalize(BOX)
    ok(#c == Hwr.N, "normalize: resamples to N points")
    local cx, cy = 0, 0
    for i = 1, #c do cx = cx + c[i].x; cy = cy + c[i].y end
    cx, cy = cx / #c, cy / #c
    ok(math.abs(cx) < 1e-6 and math.abs(cy) < 1e-6, "normalize: centroid at the origin")
    local within = true
    for i = 1, #c do if math.abs(c[i].x) > 0.75 or math.abs(c[i].y) > 0.75 then within = false end end
    ok(within, "normalize: scaled into a unit-ish box")

    ok(Hwr.normalize(G(stroke{})) ~= nil, "normalize: empty gesture does not crash")
    ok(#Hwr.normalize(G(stroke{ 3, 3 })) == 0 or #Hwr.normalize(G(stroke{ 3, 3 })) >= 0,
        "normalize: a single-point dot does not crash")
end

-- ---- recognition -------------------------------------------------------------
local rec = Hwr.Recognizer.new()
rec:add("I", VBAR)
rec:add("-", HBAR)
rec:add("/", SLASH)
rec:add("\\", BACKSLASH)
rec:add("+", PLUS)
rec:add("X", EX)
rec:add("O", BOX)

do
    ok(rec:count() == 7, "recognizer: holds all templates")
    -- identity: each template recognises as itself
    local function best(g) local l = rec:recognize(g); return l end
    ok(best(VBAR) == "I", "recognize: vertical bar -> I")
    ok(best(HBAR) == "-", "recognize: horizontal bar -> -")
    ok(best(SLASH) == "/", "recognize: forward slash -> /")
    ok(best(BACKSLASH) == "\\", "recognize: back slash -> \\")
    ok(best(BOX) == "O", "recognize: square -> O")
    ok(best(PLUS) == "+", "recognize: plus -> +")
    ok(best(EX) == "X", "recognize: ex -> X")

    -- orientation matters ($P is not rotation-invariant): a slash is not a backslash
    ok(best(SLASH) ~= "\\", "recognize: / is distinguished from \\")
    ok(best(VBAR) ~= "-", "recognize: vertical is distinguished from horizontal")
end

-- ---- invariances -------------------------------------------------------------
do
    -- scaled + translated square is still O
    local big = G(stroke{ 100, 200, 300, 200, 300, 400, 100, 400, 100, 200 })
    ok(rec:recognize(big) == "O", "recognize: position + scale invariant (big square -> O)")

    -- a slightly noisy square is still O
    local noisy = G(stroke{ 0, 1, 5, 0, 10, 1, 11, 5, 10, 10, 5, 11, 0, 10, -1, 5, 0, 0 })
    ok(rec:recognize(noisy) == "O", "recognize: tolerant of noise (wobbly square -> O)")

    -- + drawn with the two strokes in the other order is still +
    local plus_rev = G(stroke{ 5, 0, 5, 10 }, stroke{ 0, 5, 10, 5 })
    ok(rec:recognize(plus_rev) == "+", "recognize: stroke order independent (+)")

    -- X drawn bottom-up / swapped strokes is still X
    local x_swapped = G(stroke{ 10, 0, 0, 10 }, stroke{ 10, 10, 0, 0 })
    ok(rec:recognize(x_swapped) == "X", "recognize: stroke order + direction independent (X)")
end

-- ---- confidence + guards -----------------------------------------------------
do
    local label, score, ranked = rec:recognize(VBAR)
    ok(label == "I" and score > 0.5, "recognize: a clean match scores high")
    ok(type(ranked) == "table" and #ranked == 7 and ranked[1].label == "I",
        "recognize: returns a ranked list, best first")
    ok(ranked[1].score >= ranked[2].score, "recognize: ranking is ordered by score")

    ok(Hwr.Recognizer.new():recognize(VBAR) == nil, "recognize: no templates -> nil")
    ok(rec:recognize(G(stroke{})) == nil, "recognize: empty gesture -> nil")
end

-- ---- segmentation: strokes -> characters / spaces / newlines -----------------
do
    -- an H made of three strokes, all overlapping in x (0..10), height 10
    local function H_at(x0, y0)
        return { stroke{ x0, y0, x0, y0 + 10 }, stroke{ x0 + 10, y0, x0 + 10, y0 + 10 },
                 stroke{ x0, y0 + 5, x0 + 10, y0 + 5 } }
    end
    local function I_at(x0, y0) return { stroke{ x0 + 5, y0, x0 + 5, y0 + 10 } } end
    local function flatten(...)
        local all = {}
        for _, g in ipairs({ ... }) do for _, s in ipairs(g) do all[#all + 1] = s end end
        return all
    end
    local function kinds(tokens)
        local k = {}
        for i = 1, #tokens do k[i] = tokens[i].kind end
        return table.concat(k, ",")
    end

    -- a single multi-stroke H -> one char token holding all three strokes
    local t1 = Hwr.segment(H_at(0, 0))
    ok(#t1 == 1 and t1[1].kind == "char" and #t1[1].strokes == 3,
        "segment: overlapping strokes group into one character")

    -- H then a nearby character (gap between char_gap and space_gap) -> two chars
    local t2 = Hwr.segment(flatten(H_at(0, 0), I_at(15, 0)))
    ok(kinds(t2) == "char,char", "segment: a small gap splits characters, no space")

    -- H then a far character -> a space between
    local t3 = Hwr.segment(flatten(H_at(0, 0), I_at(25, 0)))
    ok(kinds(t3) == "char,space,char", "segment: a wide gap inserts a space")

    -- two vertically separated groups -> a newline between them
    local t4 = Hwr.segment(flatten(H_at(0, 0), I_at(0, 40)))
    ok(kinds(t4) == "char,newline,char", "segment: a second line inserts a newline")

    ok(#Hwr.segment({}) == 0, "segment: no strokes -> no tokens")
end

print(string.format("hwr: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
