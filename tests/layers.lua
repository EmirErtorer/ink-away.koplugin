-- Layers in a drawing (ink/layers.lua) and the canvas that keeps their ops in
-- one list, in the order they show: new ops go to the end of the active layer,
-- undo and redo put them back where they were, merging and turning layers off
-- keep the page as it looked, and the file keeps it all.
--   luajit tests/layers.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Canvas = require("ink/canvas")
local Layers = require("ink/layers")
local Project = require("ink/project")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function stroke(tag) return { kind = "ink", width = 4, alpha = 255, pts = { 0, 0, 10, 10 }, tag = tag } end
local function tags(ops)
    local t = {}
    for i, op in ipairs(ops) do t[i] = tostring(op.tag) .. "@" .. tostring(op.layer or 1) end
    return table.concat(t, " ")
end
-- the ops in the list are each layer's together, the layers bottom to top
local function grouped(c)
    if not c.layers then return true end
    local pos = {}
    for i, l in ipairs(c.layers) do pos[l.id] = i end
    local last = 0
    for _i, op in ipairs(c.ops) do
        local p = pos[op.layer or 1]
        if not p or p < last then return false end
        last = p
    end
    return true
end

-- ---- off by default; turned on, everything so far is the first layer -------------
do
    local c = Canvas.new(100, 100)
    ok(not Layers.on(c) and Layers.visible(c) == c.ops, "a new drawing has no layers")
    c:addOp(stroke("a"))
    c:addOp(stroke("b"))
    ok(tags(c.ops) == "a@1 b@1", "without layers ops are added at the end")
    ok(Layers.enable(c) and Layers.on(c) and #c.layers == 1 and c.active_layer == 1, "turned on: one layer, active")
    ok(not Layers.enable(c), "turning on twice does nothing")
    ok(Layers.editable(c, c.ops[1]), "the first layer's ops are editable")
end

-- ---- new ops go to the end of the active layer -----------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    local id2 = Layers.add(c)
    ok(id2 == 2 and c.active_layer == 2 and c.layers[2].name == "Layer 2", "a new layer above, active")
    c:addOp(stroke("b"))
    c.active_layer = 1
    c:addOp(stroke("c"))
    ok(tags(c.ops) == "a@1 c@1 b@2", "an op on the lower layer goes under the upper one: " .. tags(c.ops))
    ok(grouped(c), "still in layer order")
    ok(not Layers.editable(c, c.ops[3]) and Layers.editable(c, c.ops[2]), "only the active layer is editable")
    -- undo takes that op out where it was; redo puts it back there
    c:undo()
    ok(tags(c.ops) == "a@1 b@2", "undo takes it out of the middle: " .. tags(c.ops))
    c:redo()
    ok(tags(c.ops) == "a@1 c@1 b@2", "redo puts it back where it was: " .. tags(c.ops))
    -- an empty middle layer: its first op lands between the layers around it
    c.active_layer = 1
    local id3 = Layers.add(c)
    ok(Layers.pos(c, id3) == 2, "a layer added over layer 1 sits under layer 2")
    c:addOp(stroke("d"))
    ok(tags(c.ops) == "a@1 c@1 d@3 b@2" and grouped(c), "an empty middle layer's first op lands between: " .. tags(c.ops))
    -- the shapes and fills of the canvas use the same way in
    c:addShape("rect", false, { 0, 0, 5, 5 }, 2)
    c:addFillOp({ 0, 0, 3 }, { 0, 0, 0 })
    ok(c.ops[4].kind == "shape" and c.ops[5].kind == "fill" and c.ops[6].tag == "b" and grouped(c),
        "shapes and fills go to the active layer too")
end

-- ---- strokes finished through the canvas --------------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    Layers.add(c)
    c:addOp(stroke("top"))
    c.active_layer = 1
    c:startStroke("ink", 4, 255, nil, "solid")
    c:addPoint(1, 1); c:addPoint(20, 20)
    local op = c:finishStroke()
    ok(op and c.ops[2] == op and op.layer == nil and c.ops[3].tag == "top", "a finished stroke goes into the active layer")
end

-- ---- hiding --------------------------------------------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    Layers.add(c)
    c:addOp(stroke("b"))
    ok(Layers.visible(c) == c.ops, "nothing hidden: the list itself, no copy")
    ok(Layers.setHidden(c, 1, true), "hide layer 1")
    local vis = Layers.visible(c)
    ok(#vis == 1 and vis[1].tag == "b", "hidden layer's ops are not drawn")
    ok(Layers.visible(c) == vis, "the visible list is kept until something changes")
    c:addOp(stroke("b2"))
    ok(#Layers.visible(c) == 2, "a change makes it again")
    Layers.setHidden(c, 1, false)
    ok(Layers.visible(c) == c.ops, "shown again")
    -- what the view caches: the layers above the active one, and all but it
    c.active_layer = 1
    ok(#Layers.above(c) == 2 and #Layers.others(c) == 2, "above / others of layer 1")
    c.active_layer = 2
    ok(#Layers.above(c) == 0 and #Layers.others(c) == 1, "above / others of the top layer")
    Layers.setHidden(c, 1, true)
    ok(#Layers.others(c) == 0, "hidden layers are not among the others")
end

-- ---- moving a layer up or down --------------------------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    local id2 = Layers.add(c)
    c:addOp(stroke("b"))
    c:addOp(stroke("b2"))
    ok(Layers.move(c, id2, -1), "move layer 2 down")
    ok(c.layers[1].id == id2 and tags(c.ops) == "b@2 b2@2 a@1" and grouped(c), "its ops move under: " .. tags(c.ops))
    ok(not Layers.move(c, id2, -1), "nothing under the bottom")
    c:undo()
    ok(c.layers[1].id == 1 and tags(c.ops) == "a@1 b@2 b2@2", "undo puts the order back: " .. tags(c.ops))
    c:redo()
    ok(c.layers[1].id == id2 and grouped(c), "redo moves it again")
    c:undo()
    -- the first layer holds erasing from before layers were on: it stays at the bottom
    local d = Canvas.new(100, 100)
    d:addOp(stroke("a"))
    d:addOp({ kind = "erase", width = 10, alpha = 255, pts = { 0, 0, 5, 5 } })
    Layers.enable(d)
    local d2 = Layers.add(d)
    local can, why = Layers.canMove(d, d2, -1)
    ok(not can and why == "erase", "no layer goes under one with old erasing")
    ok(not Layers.canMove(d, 1, 1), "and it does not move up")
end

-- ---- merging down keeps the page as it was -----------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    local id2 = Layers.add(c)
    c:addOp(stroke("b"))
    local id3 = Layers.add(c)
    c:addOp(stroke("c"))
    local before = {}
    for i, op in ipairs(c.ops) do before[i] = op.tag end
    local orig_b = c.ops[2]
    Layers.setHidden(c, id2, true)
    ok(Layers.mergeDown(c, id3) == id2, "layer 3 merges into layer 2")
    ok(#c.layers == 2 and c.active_layer == id2 and Layers.shown(c, id2), "one layer less, the merged one active and shown")
    local same = #c.ops == 3
    for i, op in ipairs(c.ops) do same = same and op.tag == before[i] end
    ok(same and tags(c.ops) == "a@1 b@2 c@2", "the ops keep their order (the page looks the same): " .. tags(c.ops))
    ok(c.ops[2] == orig_b, "ops already on the layer are not copied")
    ok(Layers.mergeDown(c, id2) == 1 and tags(c.ops) == "a@1 b@1 c@1", "into the first layer: no label left")
    ok(Layers.mergeDown(c, 1) == nil, "nothing under the bottom layer")
    c:undo(); c:undo()
    ok(#c.layers == 3 and tags(c.ops) == "a@1 b@2 c@3", "undo brings the layers back: " .. tags(c.ops))
end

-- ---- deleting a layer ------------------------------------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    local id2 = Layers.add(c)
    c:addOp(stroke("b"))
    ok(Layers.remove(c, id2) and tags(c.ops) == "a@1" and c.active_layer == 1, "deleted with what was on it")
    ok(not Layers.remove(c, 1), "the last layer stays")
    c:undo()
    ok(#c.layers == 2 and tags(c.ops) == "a@1 b@2" and Layers.pos(c, c.active_layer), "undo brings it back")
end

-- ---- turning layers off merges them all --------------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    local id2 = Layers.add(c)
    c:addOp(stroke("b"))
    Layers.setHidden(c, id2, true)
    ok(Layers.flatten(c) and not Layers.on(c), "turned off")
    ok(tags(c.ops) == "a@1 b@1" and Layers.visible(c) == c.ops, "every layer merged, hidden ones too, in order")
    c:undo()
    ok(Layers.on(c) and #c.layers == 2 and tags(c.ops) == "a@1 b@2", "undo turns them back on")
    c:addOp(stroke("x"))
    ok(c.layers and grouped(c), "and drawing goes on in layers")
end

-- ---- undo history across turning layers on --------------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    Layers.add(c)
    c:addOp(stroke("b"))
    c:undo(); c:undo(); c:undo()   -- the stroke, the new layer, turning on
    ok(not Layers.on(c) and tags(c.ops) == "a@1", "undo all the way: no layers")
    c:redo(); c:redo(); c:redo()
    ok(Layers.on(c) and #c.layers == 2 and tags(c.ops) == "a@1 b@2" and c.active_layer == 2, "redo all the way back")
end

-- ---- names, the cap ------------------------------------------------------------------------
do
    local c = Canvas.new(100, 100)
    Layers.enable(c)
    for _i = 2, Layers.MAX do ok(Layers.add(c) ~= nil, "add layer up to the cap") end
    ok(Layers.add(c) == nil and #c.layers == Layers.MAX, "no more than " .. Layers.MAX)
    ok(Layers.rename(c, c.layers[2].id, "  Ink  ") and c.layers[2].name == "Ink", "renamed (trimmed)")
    ok(not Layers.rename(c, c.layers[2].id, "   "), "an empty name is refused")
    Layers.remove(c, c.layers[3].id)
    ok(Layers.add(c) and c.layers[#c.layers].name ~= nil, "a free number is used again")
    local names = {}
    for _i, l in ipairs(c.layers) do
        ok(not names[l.name], "names are not repeated: " .. l.name)
        names[l.name] = true
    end
end

-- ---- the file keeps the layers --------------------------------------------------------
do
    local c = Canvas.new(100, 100)
    c:addOp(stroke("a"))
    Layers.enable(c)
    local id2 = Layers.add(c)
    c:addOp(stroke("b"))
    Layers.rename(c, id2, "Colour")
    Layers.setHidden(c, 1, true)
    c.active_layer = 1
    local str = Project.serialize(c, { layers = Layers.save(c) })
    local data = Project.deserialize(str)
    local d = Canvas.new(data.w, data.h)
    d:setOps(data.ops)
    Layers.load(d, data.layers)
    ok(Layers.on(d) and #d.layers == 2 and d.layers[2].name == "Colour", "layers read back")
    ok(d.active_layer == 1 and not Layers.shown(d, 1) and Layers.shown(d, id2), "active and hidden read back")
    ok(tags(d.ops) == "a@1 b@2" and grouped(d), "ops read back in layer order")
    -- a drawing without layers stays without
    local e = Canvas.new(100, 100)
    e:addOp(stroke("a"))
    local de = Project.deserialize(Project.serialize(e, { layers = Layers.save(e) }))
    local f = Canvas.new(100, 100)
    f:setOps(de.ops)
    Layers.load(f, de.layers)
    ok(not Layers.on(f), "no layers saved, none read")
    -- a damaged list: unknown ids join the first layer, bad entries are dropped
    local g = Canvas.new(100, 100)
    g:setOps({ stroke("x"), { kind = "ink", pts = { 0, 0 }, width = 1, layer = 9, tag = "y" } })
    Layers.load(g, { list = { { id = 1, name = "A" }, { id = "bad" }, { id = 2 } }, active = 7, hidden = { 2, 5 } })
    ok(#g.layers == 2 and g.active_layer == 2 and not g.hidden_layers[5], "damaged list: cleaned")
    ok(tags(g.ops) == "x@1 y@1", "an op of an unknown layer joins the first")
end

-- ---- ops pasted from a layered drawing ----------------------------------------------------
do
    local c = Canvas.new(100, 100)
    local pasted = stroke("p"); pasted.layer = 4
    c:pushHistory()
    c:placeOp(pasted)
    ok(pasted.layer == nil, "pasted into a drawing without layers: no layer label left")
    local d = Canvas.new(100, 100)
    d.ops = { { kind = "ink", width = 1, alpha = 255, pts = { 0, 0, 1, 1 }, layer = 3, tag = "x" } }
    Layers.enable(d)
    ok(tags(d.ops) == "x@1" and Layers.editable(d, d.ops[1]), "turning layers on takes a stray label into the first layer")
end

-- ---- loading resets ------------------------------------------------------------------------
do
    local c = Canvas.new(100, 100)
    Layers.enable(c)
    c:setOps({})
    ok(not Layers.on(c), "another document loaded: no layers until it has them")
end

print(("layers: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
