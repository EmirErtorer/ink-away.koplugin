-- The smart highlighter (ink/reader/snap.lua): which strokes become the reader's
-- own highlight of the text they run over, and of which text, on a stand-in page
-- of words, as a reflowing book finds them (only under the point) and as a PDF
-- does (the nearest word to any point); and the colour each pen gives.
--   luajit tests/snap.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Snap = require("ink/reader/snap")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- A page: lines of words 28 px tall every 40 px, from x = 60 to about 540.
local WIDTHS = { 70, 40, 95, 30, 60, 85, 45, 50 }
local lines = {}
for li = 1, 8 do
    local y = 100 + (li - 1) * 40
    local x, words = 60, {}
    for wi = 1, 7 do
        local w = WIDTHS[(li + wi) % #WIDTHS + 1]
        if x + w > 540 then break end
        words[#words + 1] = { line = li, n = wi, box = { x = x, y = y, w = w, h = 28 } }
        x = x + w + 10
    end
    lines[li] = words
end
local function word(li, wi) return lines[li][wi] end
local function lastOf(li) return lines[li][#lines[li]] end

-- As a reflowing book: the word under the point, if any.
local function under(x, y)
    for _li, ws in ipairs(lines) do
        for _wi, w in ipairs(ws) do
            local b = w.box
            if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then return w end
        end
    end
end
-- As a PDF: the nearest word, wherever the point is.
local function nearest(x, y)
    local best, bd
    for _li, ws in ipairs(lines) do
        for _wi, w in ipairs(ws) do
            local b = w.box
            local dx = math.max(b.x - x, 0, x - (b.x + b.w))
            local dy = math.max(b.y - y, 0, y - (b.y + b.h))
            local d = dx * dx + dy * dy
            if not bd or d < bd then best, bd = w, d end
        end
    end
    return best
end
local function key(w) return w.line * 100 + w.n end
local function before(a, b) return key(a) < key(b) end

local function stroke(pts, width) return { kind = "ink", style = "highlighter", width = width or 30, pts = pts } end
-- the text a stroke snaps to, as "line.word-line.word", or nil
local function snapped(op, finder)
    local words, share = Snap.hits(op, finder, (op.width or 30) * 0.5, key)
    if not Snap.snaps(words, share) then return nil, share end
    local a, b = Snap.ends(words, before)
    return a.line .. "." .. a.n .. "-" .. b.line .. "." .. b.n, share
end
local function midY(li) return 100 + (li - 1) * 40 + 14 end

for _i, case in ipairs({ { "book", under }, { "pdf", nearest } }) do
    local tag, find = case[1], case[2]
    local y3, l3 = midY(3), lines[3]
    local x_end = lastOf(3).box.x + lastOf(3).box.w

    -- along a line, its first word to its last
    local s = snapped(stroke({ 62, y3, x_end - 2, y3 }), find)
    ok(s == "3.1-3." .. #l3, tag .. ": a stroke along a line (" .. tostring(s) .. ")")
    -- overflowing into the margin at both ends
    s = snapped(stroke({ 10, y3 + 3, x_end + 70, y3 - 2 }), find)
    ok(s == "3.1-3." .. #l3, tag .. ": overflowing both ends still snaps to the line (" .. tostring(s) .. ")")
    -- from the middle of one word to the middle of another
    local w2, w5 = word(3, 2).box, word(3, 5).box
    s = snapped(stroke({ w2.x + w2.w / 2, y3, w5.x + w5.w / 2, y3 }), find)
    ok(s == "3.2-3.5", tag .. ": part of a line, the words it touches (" .. tostring(s) .. ")")
    -- a wobbly hand
    local pts = {}
    for x = 62, x_end, 12 do pts[#pts + 1] = x; pts[#pts + 1] = y3 + ((x / 12) % 2 == 0 and 8 or -8) end
    s = snapped(stroke(pts), find)
    ok(s == "3.1-3." .. #l3, tag .. ": a wobbly stroke snaps (" .. tostring(s) .. ")")
    -- drawn a little low, its centre near the bottom of the words
    s = snapped(stroke({ 62, y3 + 16, x_end - 2, y3 + 17 }), find)
    ok(s == "3.1-3." .. #l3, tag .. ": a little low still finds the line (" .. tostring(s) .. ")")
    -- right to left
    s = snapped(stroke({ x_end + 20, y3, 30, y3 }), find)
    ok(s == "3.1-3." .. #l3, tag .. ": right to left, the same (" .. tostring(s) .. ")")
    -- across lines: from the second word of line 2 to the third of line 4
    local a, b = word(2, 2).box, word(4, 3).box
    s = snapped(stroke({ a.x + 5, midY(2), (a.x + b.x) / 2, midY(3), b.x + b.w - 5, midY(4) }), find)
    ok(s == "2.2-4.3", tag .. ": across lines, the text from the first word to the last (" .. tostring(s) .. ")")
    -- down through the lines, where each has a word
    local cx
    for x = 60, 540 do
        local all = true
        for li = 2, 5 do if not under(x, midY(li)) then all = false end end
        if all then cx = x; break end
    end
    s = cx and snapped(stroke({ cx, midY(2), cx, midY(5) }), find)
    ok(s ~= nil and s:match("^2%.") and s:match("%-5%."), tag .. ": down through lines 2 to 5 (" .. tostring(s) .. ")")
    -- the space above the page
    s = snapped(stroke({ 60, 40, 500, 42 }), find)
    ok(s == nil, tag .. ": the space above the text stays ink")
    -- the margin beside the text, grazing a line's end
    local e = lastOf(3).box
    s = snapped(stroke({ e.x + e.w - 4, y3, e.x + e.w + 200, y3 }), find)
    ok(s == nil, tag .. ": grazing a line's end from the margin stays ink")
    -- a third over text, the rest beyond its end
    local wl = lastOf(3).box
    s = snapped(stroke({ wl.x + 2, y3, wl.x + wl.w + 2 * wl.w, y3 }), find)
    ok(s == "3." .. #l3 .. "-3." .. #l3, tag .. ": a third over a word is that word (" .. tostring(s) .. ")")
    -- a dab
    ok(Snap.hits(stroke({ 100, y3, 105, y3 }), find, 15, key) == nil, tag .. ": a dab is nothing")
    -- a stroke between two lines, nearer the lower one
    s = snapped(stroke({ 62, midY(3) + 21, x_end - 2, midY(3) + 21 }), find)
    ok(s ~= nil and (s:match("^3") or s:match("^4")), tag .. ": between lines, one of them (" .. tostring(s) .. ")")
end

-- a highlighter much thicker than the lines (a zoomed PDF: lines 15 px, the pen
-- 39 px): a stroke along one line stays on it, even where it crosses the gaps
-- between words and its band reaches the lines above and below
do
    local thin = {}
    for li = 1, 6 do
        local y, x, ws = 100 + (li - 1) * 18, 60, {}
        for wi = 1, 8 do
            local w = 30 + ((li * 7 + wi * 13) % 40)
            if x + w > 540 then break end
            ws[#ws + 1] = { line = li, n = wi, box = { x = x, y = y, w = w, h = 15 } }
            x = x + w + 8
        end
        thin[li] = ws
    end
    local function near(x, y)
        local best, bd
        for _li, ws in ipairs(thin) do
            for _wi, w in ipairs(ws) do
                local b = w.box
                local dx = math.max(b.x - x, 0, x - (b.x + b.w))
                local dy = math.max(b.y - y, 0, y - (b.y + b.h))
                if not bd or dx * dx + dy * dy < bd then best, bd = w, dx * dx + dy * dy end
            end
        end
        return best
    end
    local l3 = thin[3]
    local y = l3[1].box.y + 7.5
    local op = { kind = "ink", width = 39, pts = { l3[1].box.x + 2, y, l3[#l3].box.x + l3[#l3].box.w - 2, y } }
    local words, share = Snap.hits(op, near, 19.5, key)
    local a, b = Snap.ends(words, before)
    ok(Snap.snaps(words, share) and a.line == 3 and b.line == 3 and a.n == 1 and b.n == #l3,
        ("thick pen, thin lines: stays on its line (%s.%s-%s.%s)"):format(a and a.line, a and a.n, b and b.line, b and b.n))
    op.pts = { l3[2].box.x + 5, y + 4, l3[4].box.x + 5, y - 3 }
    words, share = Snap.hits(op, near, 19.5, key)
    a, b = Snap.ends(words, before)
    ok(a and a.line == 3 and b.line == 3 and a.n == 2 and b.n == 4, "thick pen, thin lines: part of the line")
    op.pts = { l3[2].box.x + 5, y, l3[2].box.x + 5, thin[5][1].box.y + 7 }
    words = Snap.hits(op, near, 19.5, key)
    a, b = Snap.ends(words, before)
    ok(a and b and a.line == 3 and b.line == 5, "thick pen, thin lines: going down the page spans the lines")
end

-- reading order on a fixed page
do
    local a = { box = { x = 300, y = 100, w = 40, h = 28 } }
    local b = { box = { x = 60, y = 140, w = 40, h = 28 } }
    local c = { box = { x = 120, y = 103, w = 40, h = 26 } }
    ok(Snap.pageBefore(a, b) and not Snap.pageBefore(b, a), "page order: a line above comes first")
    ok(Snap.pageBefore(c, a), "page order: on one line, left to right")
    local first, last = Snap.ends({ b, a, c }, Snap.pageBefore)
    ok(first == c and last == b, "page order: the ends of a run")
end

-- the colour each pen gives
do
    local NAMED = { red = "#FF3300", orange = "#FF8800", yellow = "#FFFF33", green = "#00AA66",
        olive = "#88FF77", cyan = "#00FFEE", blue = "#0066FF", purple = "#EE00FF" }
    local cases = {
        { { 208, 0, 0 }, "red", "the pen menu's red" },
        { { 224, 112, 0 }, "orange", "its orange" },
        { { 232, 192, 0 }, "yellow", "its yellow (not orange)" },
        { { 0, 144, 0 }, "green", "its green" },
        { { 0, 80, 208 }, "blue", "its blue" },
        { { 128, 0, 176 }, "purple", "its purple" },
        { { 255, 235, 59 }, "yellow", "the highlighter's own yellow" },
        { { 0, 200, 210 }, "cyan", "a picked cyan" },
        { { 170, 240, 170 }, "olive", "a pale green, KOReader's olive" },
        { { 30, 110, 30 }, "green", "a dark green" },
        { { 250, 240, 120 }, "yellow", "a pale yellow" },
        { { 255, 150, 40 }, "orange", "a light orange" },
        { { 90, 60, 220 }, "blue", "a violet blue" },
    }
    for _i, c in ipairs(cases) do
        local got = Snap.colourName(c[1], "gray", NAMED)
        ok(got == c[2], ("colour: %s is %s (%s)"):format(c[3], c[2], tostring(got)))
    end
    ok(Snap.colourName({ 136, 136, 136 }, "gray", NAMED) == "gray", "colour: a grey pen keeps the reader's own")
    ok(Snap.colourName({ 0, 0, 0 }, "yellow", NAMED) == "yellow", "colour: a black pen too")
    ok(Snap.colourName(nil, "gray", NAMED) == "gray", "colour: no colour, the reader's own")
    ok(Snap.colourName({ 0, 200, 210 }, "gray", { red = "#FF0000", blue = "#0000FF" }) == "blue",
        "colour: only colours the reader has")
end

print(("snap: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
