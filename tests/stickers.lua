-- Stickers (ink/stickers.lua, ink/stickerdata.lua): every recipe builds, a sticker is
-- one group of shapes, what begins on it joins it and moves with it, a copy is a
-- sticker of its own. Plain Lua, no KOReader.
--   luajit tests/stickers.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Stickers = require("ink/stickers")
local Canvas = require("ink/canvas")
local Project = require("ink/project")
local Transform = require("ink/transform")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what) ok(a == b, what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end

------------------------------------------------------------------------------
-- the catalogue
------------------------------------------------------------------------------
local ids, cats, total = {}, {}, 0
for _, s in ipairs(Stickers.list) do
    ok(not ids[s.id], s.id .. ": the id is new")
    ids[s.id] = true
    cats[s.cat] = (cats[s.cat] or 0) + 1
    ok(s.w > 0 and s.h > 0, s.id .. ": has a size")
    local ops, h = Stickers.build(s.id, nil, 10, 20, 200)
    ok(ops and #ops >= 1, s.id .. ": builds")
    ok(math.abs(h - 200 * s.h / s.w) < 1e-6, s.id .. ": keeps its proportions")
    local group, finite, minx, miny, maxx, maxy = ops[1].group, true, 1e9, 1e9, -1e9, -1e9
    for _, op in ipairs(ops) do
        eq(op.group, group, s.id .. ": one group")
        ok(op.kind == "shape" and op.shape == "poly" and op.stk == s.id, s.id .. ": a poly shape marked as the sticker's")
        ok(#op.pts >= 4 and #op.pts % 2 == 0, s.id .. ": has points")
        ok(op.width and op.width >= 1, s.id .. ": has a line width")
        ok(op.color and op.color[1], s.id .. ": has a colour")
        for i = 1, #op.pts do
            if op.pts[i] ~= op.pts[i] or math.abs(op.pts[i]) == math.huge then finite = false end
        end
        for i = 1, #op.pts, 2 do
            minx, maxx = math.min(minx, op.pts[i]), math.max(maxx, op.pts[i])
            miny, maxy = math.min(miny, op.pts[i + 1]), math.max(maxy, op.pts[i + 1])
        end
    end
    ok(finite, s.id .. ": every point is a number")
    -- (a stroke's round ends and the shadow reach a little past the box)
    ok(minx >= 10 - 25 and miny >= 20 - 25 and maxx <= 210 + 25 and maxy <= 20 + h + 25, s.id .. ": stays about its box")
    local has_body = false
    for _, op in ipairs(ops) do if op.sbody then has_body = true end end
    ok(has_body or s.cat == "marks" or s.id == "clip" or s.id == "pushpin" or s.id == "bulb" or s.id == "tape_slant" or s.id == "tape_corner",
        s.id .. ": has a body to write on, or is a mark")
    total = total + #Project.encode(ops)
end
ok(#Stickers.list >= 36, "at least 36 built-in stickers (" .. #Stickers.list .. ")")
for _, c in ipairs(Stickers.CATEGORIES) do ok((cats[c] or 0) >= 4, c .. ": has stickers (" .. tostring(cats[c]) .. ")") end
ok(total < 400 * 1024, "all of them as saved ops are small (" .. total .. " bytes)")
local recipe_bytes = 0
do
    local f = io.open("ink/stickerdata.lua", "rb"); recipe_bytes = #f:read("*a"); f:close()
end
ok(recipe_bytes < 24 * 1024, "the recipes are a few kilobytes of code (" .. recipe_bytes .. " bytes)")
ok(Stickers.get("postit") and not Stickers.get("nope"), "a sticker is found by id")
eq(#Stickers.inCategory("notes"), cats.notes, "a category lists its stickers")

------------------------------------------------------------------------------
-- colours
------------------------------------------------------------------------------
local yellow, pink = Stickers.COLOURS.pastel[1], Stickers.COLOURS.pastel[2]
local a = Stickers.build("postit", yellow, 0, 0, 100)
local b = Stickers.build("postit", pink, 0, 0, 100)
local body_a, body_b
for _, op in ipairs(a) do if op.sbody then body_a = op end end
for _, op in ipairs(b) do if op.sbody then body_b = op end end
eq(body_a.fill_color[1], yellow[1], "the body takes the chosen colour")
eq(body_b.fill_color[2], pink[2], "and another colour another time")
ok(body_a.color[1] < body_a.fill_color[1], "its edge is a darker shade of it")
ok(a[1].group ~= b[1].group, "each sticker is a group of its own")
ok(Stickers.defaultColour("strong")[1] == Stickers.COLOURS.strong[1][1], "the default colour is the palette's first")

------------------------------------------------------------------------------
-- on a page
------------------------------------------------------------------------------
local c = Canvas.new(1000, 1400)
local ops = Stickers.build("postit", yellow, 100, 100, 300)
for _, op in ipairs(ops) do c:placeOp(op) end
eq(#c.ops, #ops, "the sticker's shapes are on the page")
local gid = ops[1].group
eq(Stickers.groupAt(c.ops, 200, 200), gid, "a point on the body is on the sticker")
eq(Stickers.groupAt(c.ops, 20, 20), nil, "a point off it is not")
eq(Stickers.groupAt(c.ops, 395, 395), nil, "nor the cut corner")

-- a stroke begun on it joins it, one begun beside it does not
local on = { kind = "ink", pts = { 150, 150, 160, 170, 600, 600 }, width = 4 }
c:placeOp(on)
eq(on.group, gid, "a pen stroke begun on the note belongs to it (it may end off the note)")
local off = { kind = "ink", pts = { 700, 700, 710, 710 }, width = 4 }
c:placeOp(off)
eq(off.group, nil, "a stroke begun elsewhere does not")
local text = { kind = "text", x = 120, y = 120, w = 100, h = 40, paras = {} }
c:placeOp(text)
eq(text.group, gid, "a text box on the note belongs to it")
local erase = { kind = "erase", pts = { 130, 130, 140, 140 }, width = 10 }
c:placeOp(erase)
eq(erase.group, gid, "an erase begun on it belongs to it, so it moves with it")
local img = { kind = "image", path = "x.png", x = 120, y = 120, w = 50, h = 50 }
c:placeOp(img)
eq(img.group, nil, "a picture does not join")
local pre = { kind = "ink", pts = { 150, 150, 160, 160 }, width = 4, group = "other" }
c:placeOp(pre)
eq(pre.group, "other", "an op that has a group keeps it")

-- selecting any part gives the whole group
local idx_on
for i, op in ipairs(c.ops) do if op == on then idx_on = i end end
local sel = Stickers.expand(c.ops, { idx_on })
eq(#sel, #ops + 3, "the stroke selects the note and everything written on it (" .. #sel .. ")")
local seen = {}
for _, i in ipairs(sel) do ok(not seen[i], "no index twice"); seen[i] = true end
local lone = Stickers.expand(c.ops, { #c.ops - 1 })
ok(#lone >= 1, "an op outside any group selects itself")

-- moving the group moves what is written on it
local before = { on.pts[1], on.pts[2] }
for _, i in ipairs(sel) do
    local o = c:cloneOp(c.ops[i]); Transform.scale(o, 100, 100, 2); c:replaceOp(i, o)
end
local after
for _, op in ipairs(c.ops) do if op.group == gid and op.kind == "ink" then after = op end end
ok(after.pts[1] == 100 + (before[1] - 100) * 2, "a resize carries the writing with the note")
eq(Stickers.groupAt(c.ops, 500, 500), gid, "and the note's body grew with it")

-- a copy is a sticker of its own
local copies = {}
for _, i in ipairs(sel) do copies[#copies + 1] = c:cloneOp(c.ops[i]) end
Stickers.rekey(copies)
ok(copies[1].group ~= gid, "a copy has a new group")
for _, o in ipairs(copies) do eq(o.group, copies[1].group, "its parts share it") end

-- it survives saving and loading
local saved = Project.decode(Project.encode(c.ops[2]))
eq(saved.group, gid, "the group is saved")
eq(saved.stk, "postit", "and the sticker's id")
ok(saved.sbody == true, "and which part is the body")

print(string.format("stickers: %d checks, %d failures", checks, fails))
os.exit(fails == 0 and 0 or 1)
