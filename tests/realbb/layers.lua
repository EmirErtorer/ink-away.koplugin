-- Layers on KOReader's REAL blitter, grey (BB8) and colour (RGB32): a layered
-- page is its ops drawn in layer order; a stroke, a see-through pen and a smudge
-- on a lower layer stay under the layers above while they are drawn and come out
-- exactly as a fresh compose; the eraser cuts only the active layer and shows the
-- others as it goes; hidden layers are left out of the page and the export;
-- merging and turning layers off change no pixel; the caches are made only when
-- needed and freed; and a saved drawing opens with its layers.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/layers.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
_G.G_reader_settings = { data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end, nilOrTrue = function() return true end }
local Device = require("device")
local UIManager = require("ui/uimanager")
local Export = require("ink/export")
local Layers = require("ink/layers")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local function world(typ)
    local W, H = 1072, 1448
    Device.screen.bb = BB.new(W, H, typ)
    Device.screen:setSize(W, H)
    Device.hasColorScreen = function() return typ == BB.TYPE_BBRGB32 end
    Device.input.wacom_protocol = false
    UIManager.reset()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    local clock = 0
    view.nowMs = function() return clock end
    return view, function(ms) clock = clock + ms end
end

local function rgb(bb, x, y)
    local c = bb:getPixel(x, y):getColorRGB32()
    return c.r, c.g, c.b
end
local function same(a, b, x, y)
    local r1, g1, b1 = rgb(a, x, y)
    local r2, g2, b2 = rgb(b, x, y)
    return r1 == r2 and g1 == g2 and b1 == b2
end

-- pixels where the master differs from a buffer made by fn(buffer)
local function diffWith(view, fn)
    local W, H = view.view.canvas_w, view.view.canvas_h
    local fresh = BB.new(W, H, view.canvas_bb:getType())
    fn(fresh)
    local d = 0
    for y = 0, H - 1, 2 do
        for x = 0, W - 1, 2 do
            if not same(view.canvas_bb, fresh, x, y) then d = d + 1 end
        end
    end
    fresh:free()
    return d
end
-- ... a fresh compose of the drawn ops
local function vsCompose(view)
    return diffWith(view, function(fresh)
        local saved = view.canvas_bb
        view.canvas_bb = fresh
        view:composeCanvas()
        view.canvas_bb = saved
    end)
end
-- ... the whole list drawn in order, as a drawing without layers would be
local function vsFlat(view, ops)
    return diffWith(view, function(fresh)
        view:composeInto(fresh, ops or view.canvas.ops, nil, nil, nil, nil, false)
    end)
end

for _i, typ in ipairs({ BB.TYPE_BBRGB32, BB.TYPE_BB8 }) do
    local name = typ == BB.TYPE_BB8 and "grey" or "colour"
    local view, tick = world(typ)
    local v = view.view
    local c = view.canvas
    local function scr(cx, cy)
        local z = v.zoom
        return v.area_x + (cx - v.pan_x) * z, v.area_y + (cy - v.pan_y) * z
    end
    -- a stroke through the view as the pen draws it; `mid(i)` runs after each
    -- point, while the stroke is still live
    local function draw(pts, mid)
        local x, y = scr(pts[1], pts[2])
        view:onIaTouch(nil, { pos = { x = x, y = y } })
        local n = 0
        for i = 3, #pts - 1, 2 do
            tick(10)
            x, y = scr(pts[i], pts[i + 1])
            view:onIaPan(nil, { pos = { x = x, y = y } })
            n = n + 1
            if mid then mid(pts[i], pts[i + 1], n) end
        end
        view:onIaPanRelease(nil, { pos = { x = x, y = y } })
        UIManager.fireScheduled()
        view:flushPending()
    end
    local function line(x0, y0, x1, y1, n)
        local p = {}
        for k = 0, n do p[#p + 1] = x0 + (x1 - x0) * k / n; p[#p + 1] = y0 + (y1 - y0) * k / n end
        return p
    end
    local function pen(style, width, color, alpha)
        view:setTool("pen")
        view.pen_style, view.pen_width, view.pen_color, view.pen_alpha = style, width, color, alpha or 255
    end
    view.hold_straighten = false
    view.palm_reject = false
    view:composeCanvas(); view:renderView()

    -- ---- a drawing starts without layers; three of them ---------------------------
    ok(not view:layered() and view:fabRect("layers") == nil, name .. ": no layers and no strip at first")
    pen("solid", 30, { 0, 0, 0 })
    draw(line(300, 200, 300, 700, 20))                 -- black, down (layer 1)
    view:layersOn()
    ok(view:layered() and #c.layers == 1 and view:fabRect("layers") ~= nil, name .. ": turned on: one layer, the strip")
    view:layerAdd()
    pen("solid", 30, { 0, 160, 0 })
    draw(line(100, 450, 650, 450, 20))                 -- green, across (layer 2)
    local green_op = c.ops[#c.ops]
    view:layerAdd()
    pen("highlighter", 40, { 255, 235, 59 })
    draw(line(100, 560, 650, 560, 20))                 -- yellow highlighter (layer 3)
    ok(#c.layers == 3 and c.active_layer == c.layers[3].id, name .. ": three layers, the top one active")
    ok(vsCompose(view) == 0, name .. ": the live strokes equal the replay")
    ok(vsFlat(view) == 0, name .. ": the layered page is its ops drawn in order")
    local gx, gy = 500, 450
    local gr, gg, gb = rgb(view.canvas_bb, gx, gy)
    ok(gg > gr and gg > gb or (typ == BB.TYPE_BB8 and gr < 200), name .. ": the green line shows")

    -- ---- a stroke under the green line stays under it while it is drawn ----------
    view:layerSelect(c.layers[1].id)
    pen("solid", 26, { 220, 0, 0 })
    local under_ok, screen_ok = true, true
    draw(line(500, 300, 500, 620, 32), function(_x, y)
        if y > gy + 30 then
            -- the master and the screen at the crossing still show green
            if not (select(1, rgb(view.canvas_bb, gx, gy)) == gr and select(2, rgb(view.canvas_bb, gx, gy)) == gg) then
                under_ok = false
            end
            local ax, ay = view:toAreaLocal(gx, gy)
            local ar, ag = rgb(view.area_bb, math.floor(ax), math.floor(ay))
            if math.abs(ag - gg) > 8 or math.abs(ar - gr) > 8 then screen_ok = false end
        end
    end)
    ok(view._lay_above_key ~= nil and view._lay_above and view._lay_above.w < v.canvas_w,
        name .. ": what lies above is kept over its own box only")
    ok(under_ok, name .. ": while drawn, the stroke stays under the layer above (master)")
    ok(screen_ok, name .. ": ... and on the screen")
    local red = c.ops[2]
    ok(red.kind == "ink" and red.layer == nil and c.ops[3] == green_op, name .. ": the stroke went into layer 1, under layer 2's")
    ok(vsCompose(view) == 0, name .. ": after the lift the page equals the replay")
    ok(select(2, rgb(view.canvas_bb, gx, gy)) == gg, name .. ": the crossing is green")

    -- ---- a see-through pen and a smudge under it too ---------------------------
    pen("highlighter", 40, { 0, 120, 255 })
    local wash_ok = true
    draw(line(560, 300, 560, 620, 32), function(_x, y)
        if y > gy + 30 and select(2, rgb(view.canvas_bb, 560, gy)) ~= gg then wash_ok = false end
    end)
    ok(wash_ok, name .. ": a highlighter under the green line leaves it on top while drawn")
    ok(vsCompose(view) == 0, name .. ": ... and equals the replay after the lift")
    pen("smudge", 40, { 0, 0, 0 })
    draw(line(250, 380, 360, 520, 24))
    ok(vsCompose(view) == 0, name .. ": a smudge on a lower layer equals the replay")

    -- ---- the eraser cuts only the active layer ------------------------------------
    view:layerSelect(c.layers[2].id)
    view:setTool("erase")
    view.erase_whole, view.eraser_width = false, 40
    ok(view._lay_rest ~= nil, name .. ": picking the eraser makes the page without the active layer")
    local before = {}
    for _j, op in ipairs(c.ops) do if (op.layer or 1) ~= c.layers[2].id then before[op] = true end end
    local shows_under = true
    draw(line(300, 380, 300, 520, 20), function(_x, y)
        if y > 470 then
            -- where the green line was rubbed out, the black line under it shows at once
            local r1, g1 = rgb(view.canvas_bb, 300, gy)
            if r1 > 60 or g1 > 60 then shows_under = false end
        end
    end)
    ok(shows_under, name .. ": while erasing, the layer under shows through")
    local kept = 0
    for _j, op in ipairs(c.ops) do if before[op] then kept = kept + 1 end end
    local n_before = 0
    for _k in pairs(before) do n_before = n_before + 1 end
    ok(kept == n_before, name .. ": the other layers' ops are untouched (" .. kept .. "/" .. n_before .. ")")
    local greens = 0
    for _j, op in ipairs(c.ops) do if op.layer == c.layers[2].id then greens = greens + 1 end end
    ok(greens == 2, name .. ": the green line is cut in two (" .. greens .. ")")
    local br, bg = rgb(view.canvas_bb, 300, gy)
    ok(br < 60 and bg < 60, name .. ": the black line under it is still there")
    ok(vsCompose(view) == 0, name .. ": after erasing the page equals the replay")
    ok(not c.ops[#c.ops].kind or c.ops[#c.ops].kind ~= "erase", name .. ": no erase op is kept")
    view:setTool("pen")
    ok(view._lay_rest == nil, name .. ": the eraser's cache goes with the eraser")
    view:undo()
    greens = 0
    for _j, op in ipairs(c.ops) do if op.layer == c.layers[2].id then greens = greens + 1 end end
    ok(greens == 1 and vsCompose(view) == 0, name .. ": one undo brings the line back whole")

    -- ---- a watercolour scribble trimmed by the eraser keeps its look ---------------
    -- (cut into pieces drawn as washes of their own, they would glaze over each
    -- other where the scribble crossed itself)
    view:layerSelect(c.layers[3].id)
    pen("wash", 70, { 40, 110, 230 }, 160)
    view.stabilizer = 0
    local zig = {}
    for k = 0, 11 do   -- legs closer than the stroke is wide: neighbours overlap
        local x0, x1 = (k % 2 == 0) and 120 or 600, (k % 2 == 0) and 600 or 120
        for t = 0, 11 do
            zig[#zig + 1] = x0 + (x1 - x0) * t / 12; zig[#zig + 1] = 900 + k * 18 + 18 * t / 12
        end
    end
    draw(zig)
    local before_wash = BB.new(v.canvas_w, v.canvas_h, view.canvas_bb:getType())
    before_wash:blitFrom(view.canvas_bb, 0, 0, 0, 0, v.canvas_w, v.canvas_h)
    view:setTool("erase")
    view.erase_whole, view.eraser_width = false, 30
    draw(line(360, 850, 360, 1300, 20))   -- through the middle of every leg
    local wash_ops, breaks = 0, 0
    for _j, op in ipairs(c.ops) do
        if op.layer == c.layers[3].id and op.style == "wash" then
            wash_ops = wash_ops + 1
            breaks = breaks + (op.breaks and #op.breaks or 0)
        end
    end
    ok(wash_ops == 1 and breaks > 0, name .. ": the cut scribble stays one stroke, lifted where it was cut ("
        .. wash_ops .. " ops, " .. breaks .. " lifts)")
    local darker = 0
    for y = 860, 1260, 2 do
        for x = 120, 600, 2 do
          if math.abs(x - 360) > 80 then   -- (the eraser's path and the stroke's width round it)
            local r1, g1, b1 = rgb(before_wash, x, y)
            local r2, g2, b2 = rgb(view.canvas_bb, x, y)
            if math.abs(r1 - r2) > 24 or math.abs(g1 - g2) > 24 or math.abs(b1 - b2) > 24 then darker = darker + 1 end
          end
        end
    end
    local covered = 0
    for y = 910, 1100, 4 do
        local r1, g1, b1 = rgb(before_wash, 520, y)
        if not (r1 == 255 and g1 == 255 and b1 == 255) then covered = covered + 1 end
    end
    ok(covered >= 45, name .. ": the scribble's legs overlap (" .. covered .. "/48 rows painted)")
    ok(darker == 0, name .. ": away from the eraser the wash looks as it did (" .. darker .. " px changed)")
    ok(vsCompose(view) == 0, name .. ": and equals the replay")
    before_wash:free()
    view:undo()
    view:setTool("pen")

    -- ---- hidden layers ---------------------------------------------------------------
    view:layerToggleShown(c.layers[2].id)
    ok(not Layers.shown(c, c.layers[2].id), name .. ": layer 2 hidden")
    ok(vsCompose(view) == 0 and vsFlat(view, Layers.visible(c)) == 0, name .. ": the page is drawn without it")
    local hr, hg, hb = rgb(view.canvas_bb, 620, gy)
    ok(not (hg > 100 and hr < 80), name .. ": no green where the line was")
    if typ == BB.TYPE_BBRGB32 then
        local out, _n, ow = Export.buildRGB(view:drawnCanvas())
        local o = (gy * ow + 620) * 3
        ok(out[o] == hr and out[o + 1] == hg and out[o + 2] == hb, name .. ": the export leaves the hidden layer out too")
    end
    view:layerToggleShown(c.layers[2].id)
    if typ == BB.TYPE_BBRGB32 then
        local out, _n, ow = Export.buildRGB(view:drawnCanvas())
        local d = 0
        for y = 0, v.canvas_h - 1, 3 do for x = 0, v.canvas_w - 1, 3 do
            local r1, g1, b1 = rgb(view.canvas_bb, x, y)
            local o = (y * ow + x) * 3
            if r1 ~= out[o] or g1 ~= out[o + 1] or b1 ~= out[o + 2] then d = d + 1 end
        end end
        ok(d == 0, name .. ": the export equals the layered screen (" .. d .. " px differ)")
    end

    -- ---- moving, merging and turning off change no pixel (or the right ones) ------
    local snap = BB.new(v.canvas_w, v.canvas_h, view.canvas_bb:getType())
    snap:blitFrom(view.canvas_bb, 0, 0, 0, 0, v.canvas_w, v.canvas_h)
    local function vsSnap()
        return diffWith(view, function(fresh) fresh:blitFrom(snap, 0, 0, 0, 0, v.canvas_w, v.canvas_h) end)
    end
    view:layerMove(c.layers[3].id, -1)
    ok(vsCompose(view) == 0 and vsFlat(view) == 0, name .. ": a moved layer is drawn in its new place")
    view:undo()
    ok(vsSnap() == 0, name .. ": undoing the move gives the page back exactly")
    view:layerMergeDown(c.layers[3].id)
    ok(#c.layers == 2 and vsSnap() == 0, name .. ": merging down changes no pixel")
    view:layersOff()
    ok(not view:layered() and vsSnap() == 0, name .. ": turning layers off changes no pixel")
    ok(view._lay_above == nil and view._lay_rest == nil and view:fabRect("layers") == nil,
        name .. ": no caches and no strip without layers")
    view:undo()
    ok(view:layered() and #c.layers == 2 and vsSnap() == 0, name .. ": undo brings the layers back")

    -- ---- the strip ------------------------------------------------------------------------
    local r = view:fabRect("layers")
    ok(r and r.x + r.w <= v.area_x + v.area_w and math.abs((r.y + r.h / 2) - (v.area_y + v.area_h / 2)) < r.h,
        name .. ": the strip sits at the right, in the middle")
    -- a tap on the bottom chip picks layer 1; on the active one opens its menu
    local px, py = r.x + r.w / 2, r.y + r.h - r.pad - r.rh / 2
    ok(view:fabHit(px, py) == "layer1", name .. ": the bottom chip is layer 1")
    view:fabAction("layer1")
    ok(c.active_layer == c.layers[1].id, name .. ": a tap picks it")
    view:fabAction("layer1")
    ok(view._layer_menu ~= nil, name .. ": a tap on the active one opens its menu")
    view:closeSheet("_layer_menu")
    ok(view:fabHit(px, r.y + r.pad + r.rh / 2) == "layer+", name .. ": the plus on top")
    -- the strip painted, light and dark, with a hidden layer: the active chip in the accent
    view:layerToggleShown(c.layers[2].id)
    view:drawLayerStrip(Device.screen.bb, 0, 0, r)
    local cr, cg, cb = rgb(Device.screen.bb, math.floor(r.x + r.w / 2), math.floor(r.y + r.h - r.pad - r.rh / 2))
    local fr, fg, fb = rgb(Device.screen.bb, math.floor(r.x + 2), math.floor(r.y + r.h / 2))
    ok(not (cr == fr and cg == fg and cb == fb), name .. ": the active chip stands out from the strip")
    G_reader_settings:saveSetting(require("ink/ui/theme").SETTING, "dark")
    view:drawLayerStrip(Device.screen.bb, 0, 0, r)
    G_reader_settings:saveSetting(require("ink/ui/theme").SETTING, "light")
    view:layerToggleShown(c.layers[2].id)

    -- ---- saved and opened again ---------------------------------------------------------
    local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/inkaway_layers_test_" .. name .. ".inkaway"
    view:layerToggleShown(c.layers[2].id)
    view.doc_path, view.doc_written = tmp, false
    ok(view:saveDocument(true), name .. ": saved")
    local hidden_id = c.layers[2].id
    local snap2 = BB.new(v.canvas_w, v.canvas_h, view.canvas_bb:getType())
    snap2:blitFrom(view.canvas_bb, 0, 0, 0, 0, v.canvas_w, v.canvas_h)
    view:onCloseWidget()
    ok(view._lay_above == nil and view._lay_rest == nil, name .. ": closing frees the caches")
    local view2 = world(typ)
    ok(view2:openDocument(tmp), name .. ": opened again")
    local c2 = view2.canvas
    ok(view2:layered() and #c2.layers == 2 and not Layers.shown(c2, hidden_id), name .. ": with its layers, one hidden")
    local d = 0
    for y = 0, v.canvas_h - 1, 2 do for x = 0, v.canvas_w - 1, 2 do
        if not same(view2.canvas_bb, snap2, x, y) then d = d + 1 end
    end end
    ok(d == 0, name .. ": and looks as it did (" .. d .. " px differ)")
    -- the library's thumbnail leaves the hidden layer out too
    local thumb_ops = Layers.drawnOfFile(c2.ops, Layers.save(c2))
    ok(#thumb_ops < #c2.ops, name .. ": its thumbnail is drawn without the hidden layer")
    view2:onCloseWidget()
    os.remove(tmp)
    snap:free(); snap2:free()
end

print(("realbb layers: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
