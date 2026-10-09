-- The guide's cards (ink/guide.lua): every card is complete and short, its
-- icons exist, its Show me names something the view opens, and only the cards
-- that apply here are shown.
--   luajit tests/guide.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Guide = require("ink/guide")
local Actions = require("ink/actions")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end

-- what ink/view/guide.lua's guideAction can open
local SHOWS = { pens = true, pen_input = true, eraser = true, shapes = true, gestures = true, device_tips = true,
    appearance = true, paper_colour = true,
    library = true, trash = true, export = true, pen_test = true, book_ink = true }
local FEATURES = { annotate = true, booknotes = true }

-- ---- every topic and card is complete -----------------------------------------------
do
    local ids, ncards = {}, 0
    for _i, t in ipairs(Guide.TOPICS) do
        ok(t.id and not ids[t.id], "topic: a unique id (" .. tostring(t.id) .. ")")
        ids[t.id] = true
        ok(t.title and t.line and #t.line <= 40, t.id .. ": a title and a short line")
        ok(exists("ink/icons/" .. t.icon .. ".svg"), t.id .. ": its icon exists (" .. tostring(t.icon) .. ")")
        ok(t.when == nil or Guide.WHEN[t.when], t.id .. ": a known 'when'")
        ok(#t.cards >= 3 and #t.cards <= 9, t.id .. ": a handful of cards (" .. #t.cards .. ")")
        for k, c in ipairs(t.cards) do
            ncards = ncards + 1
            local tag = t.id .. " card " .. k
            ok(c.text and #c.text > 0 and #c.text <= Guide.MAX_TEXT, tag .. ": its text is short (" .. #(c.text or "") .. ")")
            ok(c.title or c.trigger, tag .. ": a title, or a trigger that names it")
            ok(c.glyph or c.icon, tag .. ": a glyph or an icon")
            if c.glyph then ok(c.glyph:match("^ges_") and exists("ink/icons/" .. c.glyph .. ".svg"), tag .. ": its glyph exists") end
            if c.icon then ok(exists("ink/icons/" .. c.icon .. ".svg"), tag .. ": its icon exists (" .. c.icon .. ")") end
            if c.show then ok(SHOWS[c.show], tag .. ": Show me opens something (" .. c.show .. ")") end
            if c.trigger then ok(Actions.trigger(c.trigger) ~= nil, tag .. ": a real trigger") end
            if c.gesture_of then ok(FEATURES[c.gesture_of], tag .. ": a book feature") end
            local whens = type(c.when) == "table" and c.when or { c.when }
            for _j, w in ipairs(whens) do ok(Guide.WHEN[w], tag .. ": a known 'when' (" .. tostring(w) .. ")") end
        end
    end
    ok(ncards <= 80, ("the guide stays short (%d cards)"):format(ncards))
end

-- ---- only what applies here ----------------------------------------------------------
local function ctx(t)
    local c = { bindings = Actions.load(function() return nil end), label = Actions.label,
        gesture = function(g) return { glyph = "ges_x", text = "how " .. g } end, placed = {} }
    for k, v in pairs(t) do c[k] = v end
    return c
end
local function has(list, pred) for _i, x in ipairs(list) do if pred(x) then return true end end; return false end
local function topicIds(c) local out = {}; for _i, t in ipairs(Guide.topics(c)) do out[t.id] = true end; return out end
do
    -- a finger-only grey reader, on the canvas
    local kindle = ctx({ canvas = true })
    local ids = topicIds(kindle)
    ok(ids.pens and ids.notebooks and ids.library and ids.export, "kindle canvas: the canvas topics")
    ok(not ids.books, "kindle canvas: no book topic outside a book")
    local reader = Guide.cards(Guide.topic("reader"), kindle)
    ok(not has(reader, function(c) return c.title == "Colour" end), "grey: no colour card")
    ok(not has(reader, function(c) return c.title == "Palm rejection" end), "finger-only: no palm rejection card")
    ok(not has(reader, function(c) return c.title == "Faster drawing" end), "off Android: no device tips")
    local gest = Guide.cards(Guide.topic("gestures"), kindle)
    ok(has(gest, function(c) return c.title == "Undo" end), "gestures: titled with what they do now")
    ok(not has(gest, function(c) return c.glyph == "ges_pen_button" end), "finger-only: no pen buttons")

    -- a pen reader with palm rejection on, colour, Android, a Boox
    local boox = ctx({ canvas = true, pen_capable = true, pen = true, colour = true, android = true, boox = true })
    reader = Guide.cards(Guide.topic("reader"), boox)
    ok(has(reader, function(c) return c.title == "Colour" end), "colour: the colour card")
    ok(has(reader, function(c) return c.title == "Fast refresh on a Boox" end), "boox: its card")
    ok(has(reader, function(c) return c.title == "Faster drawing" end), "android: device tips")
    gest = Guide.cards(Guide.topic("gestures"), boox)
    ok(has(gest, function(c) return c.glyph == "ges_pen_button" and c.title == "Highlighter" end),
        "pen: the side button, titled with its action")

    -- a gesture set to Nothing has no card
    local b = Actions.load(function() return nil end)
    b.two_swipe_up = "nothing"
    gest = Guide.cards(Guide.topic("gestures"), ctx({ canvas = true, bindings = b }))
    ok(not has(gest, function(c) return c.glyph == "ges_two_swipe_up" end), "a gesture doing nothing is left out")

    -- over a book: the book topic, with the gestures the setup gave, and no canvas-only ones
    local book = ctx({ book = true, placed = { annotate = "two_finger_swipe_southwest" } })
    ids = topicIds(book)
    ok(ids.books and not ids.notebooks and not ids.library and not ids.export, "book: the book topic, not the canvas's")
    local bc = Guide.cards(Guide.topic("books"), book)
    ok(bc[1].glyph == "ges_x" and bc[1].how == "how two_finger_swipe_southwest", "book: annotating shows its own gesture")
    ok(bc[3].how == nil, "book: a feature without a gesture shows none")
    local around = Guide.cards(Guide.topic("around"), book)
    ok(not has(around, function(c) return c.title == "Zoom" end), "book: no zoom card over a book")
end

print(("guide: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
