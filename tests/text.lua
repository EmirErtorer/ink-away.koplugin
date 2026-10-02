-- Tests for the rich text model, edit operations, layout and cursor mapping.
-- Pure Lua: a mock measuring ctx stands in for fonts so this runs under luajit.
--
--   luajit tests/text.lua

package.path = "./?.lua;" .. package.path
local T = require("ink/text")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what) ok(a == b, (what or "") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

-- ---- model + edits -------------------------------------------------------
local op = T.new{ x = 0, y = 0, w = 1000, size = 10 }
eq(#op.paras, 1, "starts with one paragraph")
ok(T.isEmpty(op), "starts empty")

local cur = { p = 1, o = 0 }
cur = T.insert(op, cur, "Hello world")
eq(T.plain(op), "Hello world", "insert plain text")
eq(cur.o, 11, "cursor after insert")
ok(not T.isEmpty(op), "no longer empty")

-- newline splits into a new paragraph (enter)
cur = T.insert(op, cur, "\n")
eq(#op.paras, 2, "newline makes a second paragraph")
eq(cur.p, 2, "cursor moved to the new paragraph")
eq(cur.o, 0, "cursor at start of new paragraph")
cur = T.insert(op, cur, "second")
eq(T.plain(op), "Hello world\nsecond", "second paragraph text")

-- backspace at start of a paragraph joins it to the previous one
cur = { p = 2, o = 0 }
cur = T.deleteBack(op, cur)
eq(#op.paras, 1, "backspace at para start merges paragraphs")
eq(T.plain(op), "Hello worldsecond", "merged text")
eq(cur.p, 1, "cursor paragraph after merge")
eq(cur.o, 11, "cursor offset at the join")

-- delete a selection across the join point
op = T.new{ w = 1000, size = 10 }
cur = T.insert(op, { p = 1, o = 0 }, "abc\ndef\nghi")
eq(#op.paras, 3, "three paragraphs")
cur = T.deleteRange(op, { a = { p = 1, o = 1 }, b = { p = 3, o = 1 } })
eq(T.plain(op), "ahi", "multi-paragraph delete keeps head and tail")
eq(#op.paras, 1, "paragraphs collapsed")

-- ---- styling -------------------------------------------------------------
op = T.new{ w = 1000, size = 10 }
T.insert(op, { p = 1, o = 0 }, "abcdef")
-- bold chars 2..4 ("cd") -> should split into 3 spans a / cd(bold) wait: o are boundaries
T.applyStyle(op, { a = { p = 1, o = 2 }, b = { p = 1, o = 4 } }, "b", true)
local p = op.paras[1]
eq(#p.spans, 3, "styling the middle splits into three spans")
eq(p.spans[1].t, "ab", "first span text")
eq(p.spans[2].t, "cd", "styled span text")
ok(p.spans[2].b == true, "middle span is bold")
ok(not p.spans[1].b and not p.spans[3].b, "outer spans are not bold")
ok(T.styleCovers(op, { a = { p = 1, o = 2 }, b = { p = 1, o = 4 } }, "b"), "styleCovers true over the bold range")
ok(not T.styleCovers(op, { a = { p = 1, o = 0 }, b = { p = 1, o = 6 } }, "b"), "styleCovers false over the whole line")
-- toggling bold off across the same range merges spans back
T.applyStyle(op, { a = { p = 1, o = 2 }, b = { p = 1, o = 4 } }, "b", false)
eq(#op.paras[1].spans, 1, "removing the style merges spans back to one")

-- typing inherits the style at the cursor
op = T.new{ w = 1000, size = 10 }
T.insert(op, { p = 1, o = 0 }, "X")
T.applyStyle(op, { a = { p = 1, o = 0 }, b = { p = 1, o = 1 } }, "b", true)
local st = T.styleAt(op, { p = 1, o = 1 })
ok(st.b == true, "styleAt after a bold char is bold")

-- bullets: continuing carries the bullet to the next paragraph
op = T.new{ w = 1000, size = 10 }
T.insert(op, { p = 1, o = 0 }, "one")
T.setBullet(op, { a = { p = 1, o = 0 }, b = { p = 1, o = 0 } }, "disc")
cur = T.insert(op, { p = 1, o = 3 }, "\n")
ok(op.paras[2].bullet == "disc", "new paragraph inherits the bullet")
T.insert(op, cur, "two")
eq(T.plain(op), "one\ntwo", "bulleted paragraphs keep their text")

-- ---- layout + cursor mapping --------------------------------------------
-- mock ctx: every char is 10px wide, lines 12px tall, ascent 10px
local ctx = {
    measure = function(s) return T.ulen(s) * 10 end,
    lineHeight = function() return 12 end,
    ascent = function() return 10 end,
    bulletLabel = function() return "* " end,
}
op = T.new{ w = 100, size = 10 }   -- 100px wide -> 10 chars per line
T.insert(op, { p = 1, o = 0 }, "aaaaaaaaaa bbbbbbbbbb")   -- 10 + space + 10
local lay = T.layout(op, ctx)
ok(#lay.lines >= 2, "long text wraps to at least two lines")
eq(lay.lines[1].o_start, 0, "first line starts at 0")

-- caret at offset 0 sits at the box's left; caret at end is further right
local c0 = T.caret(op, lay, { p = 1, o = 0 }, ctx)
eq(c0.x, 0, "caret x at start is 0")
local cmid = T.caret(op, lay, { p = 1, o = 5 }, ctx)
ok(cmid.x == 50, "caret x at offset 5 is 50px")

-- hit test near x=30 on the first line lands on offset 3
local hit = T.hit(op, lay, 32, 2, ctx)
eq(hit.p, 1, "hit paragraph")
ok(hit.o == 3, "hit near 30px lands on offset 3 (got " .. hit.o .. ")")

-- a bulleted paragraph indents its text past the bullet label
op = T.new{ w = 1000, size = 10 }
T.insert(op, { p = 1, o = 0 }, "item")
T.setBullet(op, { a = { p = 1, o = 0 }, b = { p = 1, o = 0 } }, "disc")
lay = T.layout(op, ctx)
eq(lay.lines[1].text_x, 20, "text starts after the 2-char bullet indent")
ok(lay.lines[1].bullet ~= nil, "first line carries the bullet label")

-- ---- grid-line snapping --------------------------------------------------
-- With a ruling step supplied, each line occupies whole ruling rows and its
-- baseline rests on the ruling at the row bottom, regardless of text metrics.
do
    local gctx = {
        gridStep = 40,
        measure = function(s) return T.ulen(s) * 10 end,
        lineHeight = function() return 12 end,   -- natural line box < one row
        ascent = function() return 10 end,
        bulletLabel = function() return "* " end,
    }
    local gop = T.new{ w = 100, size = 10 }      -- 10 chars per line
    T.insert(gop, { p = 1, o = 0 }, "aaaaaaaaaa bbbbbbbbbb cccccccccc")  -- wraps to 3 lines
    local glay = T.layout(gop, gctx)
    ok(#glay.lines >= 3, "grid text wraps to three lines")
    eq(glay.lines[1].top, 0, "first grid line top is 0")
    eq(glay.lines[1].height, 40, "line height snapped to one ruling row")
    eq(glay.lines[1].baseline, 40, "first baseline sits on the ruling at row bottom")
    eq(glay.lines[2].top, 40, "second line starts on the next ruling")
    eq(glay.lines[2].baseline, 80, "second baseline on the second ruling")
    eq(glay.height, 120, "total height is a whole number of ruling rows")

    -- a tall line (bigger than one row) takes as many whole rows as it needs
    local bctx = {
        gridStep = 40,
        measure = function(s) return T.ulen(s) * 10 end,
        lineHeight = function() return 52 end,   -- taller than one 40px row
        ascent = function() return 44 end,
        bulletLabel = function() return "* " end,
    }
    local bop = T.new{ w = 1000, size = 10 }
    T.insert(bop, { p = 1, o = 0 }, "big")
    local blay = T.layout(bop, bctx)
    eq(blay.lines[1].height, 80, "a tall line spans two ruling rows")
    eq(blay.lines[1].baseline, 80, "tall line baseline still on a ruling")
end

-- ---- long-word wrapping --------------------------------------------------
-- A single word with no spaces must break across lines instead of overflowing.
do
    local wctx = {
        measure = function(s) return T.ulen(s) * 10 end,
        lineHeight = function() return 12 end,
        ascent = function() return 10 end,
        bulletLabel = function() return "* " end,
    }
    local wop = T.new{ w = 100, size = 10 }          -- 10 chars per line
    T.insert(wop, { p = 1, o = 0 }, "abcdefghijklmnopqrstuvwxyz")  -- 26 chars, no spaces
    local wlay = T.layout(wop, wctx)
    ok(#wlay.lines >= 3, "a long unbroken word wraps to multiple lines")
    for i, ln in ipairs(wlay.lines) do
        local w = 0
        for _, sg in ipairs(ln.segs) do w = w + sg.w end
        ok(ln.text_x + w <= 100 + 1, "wrapped line " .. i .. " stays within the box width")
    end
    -- the pieces still cover every character in order (offsets are contiguous)
    eq(wlay.lines[1].o_start, 0, "first piece starts at 0")
    local last = wlay.lines[#wlay.lines]
    eq(last.o_end, 26, "last piece ends at the word's end")
end

-- plainRange: the text of a selection, for Copy / Cut
do
    local op = T.new{ x = 0, y = 0, w = 300, size = 20 }
    T.insert(op, { p = 1, o = 0 }, "Hello world\nsecond line\nthird")
    eq(T.plainRange(op, { a = { p = 1, o = 6 }, b = { p = 1, o = 11 } }), "world", "plainRange within a paragraph")
    eq(T.plainRange(op, { a = { p = 2, o = 7 }, b = { p = 1, o = 6 } }), "world\nsecond ", "plainRange across paragraphs, reversed ends")
    eq(T.plainRange(op, { a = { p = 1, o = 0 }, b = { p = 3, o = 5 } }), "Hello world\nsecond line\nthird", "plainRange of everything")
    eq(T.plainRange(op, { a = { p = 2, o = 3 }, b = { p = 2, o = 3 } }), "", "plainRange of an empty selection")
end

print(("text: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
