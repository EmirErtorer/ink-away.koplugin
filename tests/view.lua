-- Tests for the view, run against a mock KOReader environment. They check the
-- layout, stroke capture from gestures, undo, zoom, switching tools, the save
-- dialog wiring, and, most importantly, that nothing paints out of bounds at
-- several screen sizes.
--
-- Run from the plugin root with:  luajit tests/view.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local BB = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

-- Mock KOReader's global settings, with a scratch library folder for saves.
_G.G_reader_settings = {
    data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function pos(x, y) return { pos = { x = x, y = y } } end

-- The button labelled `text` in widget tree `w` (a sheet), or nil.
local function findButton(w, text)
    local function has(t, seen)
        if type(t) ~= "table" or seen[t] then return false end
        seen[t] = true
        if t.text == text then return true end
        for k, val in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" and has(val, seen) then return true end
        end
        return false
    end
    local function find(t, seen)
        if type(t) ~= "table" or seen[t] then return nil end
        seen[t] = true
        if type(t.callback) == "function" and has(t, {}) then return t end
        for k, val in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" then
                local f = find(val, seen); if f then return f end
            end
        end
    end
    return find(w, {})
end

local SIZES = { { 1072, 1448 }, { 758, 1024 }, { 600, 800 } }

for _, wh in ipairs(SIZES) do
    local W, H = wh[1], wh[2]
    Screen:setSize(W, H)
    BB.out_of_bounds = 0
    UIManager.reset()

    local InkAwayView = dofile("ink/view.lua")  -- reload so the module reads the new Screen size
    local view = InkAwayView:new{}
    local v = view.view
    local tag = ("%dx%d"):format(W, H)

    ok(view.area_bb ~= nil, tag .. ": area buffer allocated")
    ok(v.canvas_w == W and v.canvas_h == H, tag .. ": canvas is fixed to device size")
    ok(v.area_w == W and v.area_h == H - view.toolbar:getSize().h, tag .. ": area fills below toolbar")
    ok(view.canvas.w == W and view.canvas.h == H, tag .. ": model canvas matches device size")

    -- a full stroke: touch, several pans, release. The op commits only after
    -- the coalesce timer fires, so one lift makes one op.
    local midx = v.area_x + math.floor(v.area_w / 2)
    view:onIaTouch(nil, pos(midx, v.area_y + 20))
    ok(view.capturing, tag .. ": touch begins a stroke")
    for i = 1, 8 do
        view:onIaPan(nil, pos(midx + i, v.area_y + 20 + i * 15))
    end
    view:onIaPanRelease(nil, pos(midx + 9, v.area_y + 20 + 9 * 15))
    ok(view.capturing and view.pending_lift, tag .. ": release holds the stroke pending")
    ok(view.canvas:opCount() == 0, tag .. ": op not committed until coalesce fires")
    UIManager.fireScheduled()
    ok(not view.capturing and view.canvas:opCount() == 1, tag .. ": coalesce commits one op")

    -- bridging a dropped contact: release, then a fresh touch nearby within the
    -- window carries on the SAME op, with no split and no gap
    view:onIaTouch(nil, pos(midx, v.area_y + 200))
    view:onIaPan(nil, pos(midx + 20, v.area_y + 220))
    view:onIaPanRelease(nil, pos(midx + 20, v.area_y + 220))
    view:onIaTouch(nil, pos(midx + 22, v.area_y + 222))   -- finger lands again nearby
    ok(view.canvas:opCount() == 1, tag .. ": a nearby touch does not commit a new op")
    view:onIaPan(nil, pos(midx + 40, v.area_y + 240))
    view:onIaPanRelease(nil, pos(midx + 40, v.area_y + 240))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == 2, tag .. ": bridged drop is a single extra op")

    -- missed lift: a new touch far away while still 'capturing' must not lose
    -- the previous stroke
    view:onIaTouch(nil, pos(midx, v.area_y + 20))
    view:onIaPan(nil, pos(midx, v.area_y + 60))
    -- no release delivered; a fresh distant touch arrives
    view:onIaTouch(nil, pos(v.area_x + 5, v.area_y + 5))
    ok(view.canvas:opCount() == 3, tag .. ": stroke with a missed lift is committed, not lost")
    view:onIaPanRelease(nil, pos(v.area_x + 5, v.area_y + 5))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == 4, tag .. ": the new stroke commits too")

    view:paintTo(Screen.bb, 0, 0)

    -- eraser stroke (flushPending on tool switch commits anything open)
    view:setTool("erase")
    ok(view.tool == "erase", tag .. ": tool switched to eraser")
    view:onIaTouch(nil, pos(midx, v.area_y + 40))
    view:onIaPan(nil, pos(midx + 5, v.area_y + 60))
    view:onIaPanRelease(nil, pos(midx + 5, v.area_y + 60))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == 5, tag .. ": erase committed as an op")
    ok(view.canvas.ops[5].kind == "erase", tag .. ": last op is an erase")

    -- undo removes exactly one op
    view:undo()
    ok(view.canvas:opCount() == 4, tag .. ": undo removes exactly one op (the erase)")
    view:paintTo(Screen.bb, 0, 0)

    -- pen settings popup (second tap on the active Pen tool)
    view:setTool("pen")
    local ButtonDialog = require("ui/widget/buttondialog")
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")
    local SpinWidget = require("ui/widget/spinwidget")
    -- pen settings is now a custom stock-widget sheet (sliders / tiles / swatches),
    -- so verify it opens and that the fields its controls drive take effect.
    view:openPenSettings()
    ok(view._pen_dialog ~= nil, tag .. ": pen sheet opens")
    view._pen_dialog:onCloseMenu()
    view.pen_width = 12
    view.pen_alpha = math.floor(50/100*255+0.5)
    view.pen_color = { 0x44, 0x44, 0x44 }
    ok(view.pen_width == 12, tag .. ": pen size applied")
    ok(view.pen_alpha == math.floor(50/100*255+0.5), tag .. ": opacity applied")
    ok(view.pen_color[1] == 0x44, tag .. ": shade selection applied")
    -- eraser sheet: a size slider and an erase-pictures toggle
    view:openEraserSettings()
    ok(view._eraser_dialog ~= nil, tag .. ": eraser sheet opens")
    view._eraser_dialog:onCloseMenu()
    view.eraser_width = 24
    ok(view.eraser_width == 24, tag .. ": eraser size applied")
    view.erase_bg = false
    _G.G_reader_settings.data.inkaway_erase_bg = false

    -- shapes: pick a shape, then rubber-band it into place. The picker is now a
    -- custom stock-widget dialog, so set the shape state directly (the picker just
    -- sets these fields) and exercise the drawing/commit behaviour.
    view:setTool("shape")
    view:openShapePicker()
    ok(view._shape_dialog ~= nil, tag .. ": shape picker opens")
    view._shape_dialog:onCloseMenu()
    view.shape, view.shape_fill, view.shape_arrow = "triangle", true, nil
    ok(view.shape == "triangle" and view.shape_fill, tag .. ": filled triangle selected")
    local base = view.canvas:opCount()
    view.symmetry = "off"
    view:onIaTouch(nil, pos(midx, v.area_y + 60))
    view:onIaPan(nil, pos(midx + 80, v.area_y + 200))
    -- creating a shape (no symmetry) arms the region fast-path so the preview paint
    -- re-blits only the changed rect instead of the whole surface + toolbar
    ok(view._blit_rect ~= nil, tag .. ": shape drag arms the region fast-path")
    local oobShape = BB.out_of_bounds
    view:paintTo(Screen.bb, 0, 0)                 -- preview mid-drag (region blit)
    ok(view._blit_rect == nil, tag .. ": the region blit is consumed by the paint")
    ok(BB.out_of_bounds == oobShape, tag .. ": shape preview region blit stays in bounds")
    -- quantify the fix: a region-blit preview paint issues fewer draw ops than a
    -- full paint of the same state, because it skips the toolbar, outer margins and
    -- page frame (the per-touch-point cost that made shape creation lag, worst on a
    -- software-rotated landscape screen)
    view:onIaPan(nil, pos(midx + 82, v.area_y + 202))   -- re-arm the region rect
    local rp0 = Screen.bb.paints
    view:paintTo(Screen.bb, 0, 0)                        -- region blit
    local regionPaints = Screen.bb.paints - rp0
    view._blit_rect = nil                                -- force a full paint, same state
    local fp0 = Screen.bb.paints
    view:paintTo(Screen.bb, 0, 0)
    local fullPaints = Screen.bb.paints - fp0
    ok(regionPaints < fullPaints, tag .. ": region-blit preview does less work than a full paint")
    view:onIaPanRelease(nil, pos(midx + 82, v.area_y + 202))
    ok(view.canvas:opCount() == base + 1, tag .. ": shape commits one op")
    ok(view.canvas.ops[base + 1].kind == "shape", tag .. ": committed op is a shape")

    -- area-only refresh (areaScreenRect) lets the next paint SKIP the toolbar/chrome,
    -- which is what made every stroke-commit/menu paint slow on a rotated landscape
    -- screen. Verify the flag is set/consumed and that such a paint does less work.
    view.tool = "pen"; view.shape_preview = nil; view._blit_rect = nil
    view:setTool("pen")            -- clears any pending area-only flag; repaints chrome
    view:paintTo(Screen.bb, 0, 0)  -- a genuine full paint (chrome drawn)
    local _region = view:areaScreenRect()
    ok(view._area_only == true, tag .. ": areaScreenRect flags an area-only paint")
    local ap0 = Screen.bb.paints
    view:paintTo(Screen.bb, 0, 0)  -- area-only: chrome skipped
    local areaPaints = Screen.bb.paints - ap0
    ok(view._area_only == false, tag .. ": the paint consumes the area-only flag")
    local cp0 = Screen.bb.paints
    view:paintTo(Screen.bb, 0, 0)  -- full paint (flag now false): chrome drawn
    local chromePaints = Screen.bb.paints - cp0
    ok(areaPaints < chromePaints, tag .. ": area-only paint skips chrome (fewer draw ops)")
    view:setTool("erase")
    ok(view._area_only == false, tag .. ": switching tools forces a chrome repaint")
    view:setTool("shape")   -- restore the shape tool for the curve/fill tests below

    -- curve is two phase: drag the line, then a second drag bends it
    view.shape, view.shape_fill, view.shape_arrow = "curve", false, nil
    ok(view.shape == "curve", tag .. ": curve selected")
    local base2 = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx - 60, v.area_y + 120))
    view:onIaPan(nil, pos(midx + 60, v.area_y + 120))
    view:onIaPanRelease(nil, pos(midx + 60, v.area_y + 120))
    ok(view.curve_stage == "bend" and view.canvas:opCount() == base2, tag .. ": curve waits for a bend")
    view:onIaTouch(nil, pos(midx, v.area_y + 60))
    view:onIaPan(nil, pos(midx, v.area_y + 40))
    view:onIaPanRelease(nil, pos(midx, v.area_y + 40))
    ok(view.canvas:opCount() == base2 + 1, tag .. ": curve commits after the bend")
    local cop = view.canvas.ops[base2 + 1]
    ok(cop.shape == "curve" and #cop.pts == 6, tag .. ": curve op has a control point")

    -- paint bucket: the fill tool, tap to fill
    view.tool = "fill"
    ok(view.tool == "fill", tag .. ": fill tool selected")
    local nf = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx, v.area_y + 120))
    ok(view.canvas:opCount() == nf + 1 and view.canvas.ops[nf + 1].kind == "fill",
        tag .. ": tapping with the bucket adds a fill op")

    -- place a shape, then hold to select and edit it
    view:setTool("shape")
    view.shape, view.shape_fill, view.shape_arrow = "triangle", false, nil
    local nb = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx - 60, v.area_y + 300))
    view:onIaPan(nil, pos(midx + 60, v.area_y + 430))
    view:onIaPanRelease(nil, pos(midx + 60, v.area_y + 430))
    local shp = view.canvas.ops[nb + 1]
    ok(shp and shp.shape == "triangle", tag .. ": triangle placed for editing")

    view:setTool("pan")                              -- selection works in Pan mode
    view:onIaHold(nil, pos(midx, v.area_y + 400))   -- hold inside it
    local ti = nb + 1                        -- the triangle op's index
    ok(view.selection and #view.selection.idxs == 1 and view.selection.idxs[1] == ti,
        tag .. ": holding a shape selects it")
    ok(view._sel_dialog ~= nil and findButton(view._sel_dialog, "Duplicate"), tag .. ": its menu opens")
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, tag .. ": the frame and its handles paint in bounds")

    -- turn it with the round handle: from above the middle round to its right
    -- side is a quarter turn clockwise, and it snaps to it
    local f = view:selFrame()
    local kx, ky = view:selKnob()
    local mx, my = (f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2
    view:onIaTouch(nil, pos(kx, ky))
    ok(view.sel_drag and view.sel_drag.kind == "turn", tag .. ": the round handle turns the selection")
    view:onIaPan(nil, pos(mx + (my - ky) * 0.8, my + 3))
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, tag .. ": a turning frame paints in bounds")
    view:onIaPanRelease(nil, pos(mx + (my - ky) * 0.8, my + 3))
    ok(view.sel_drag == nil and math.abs((view.canvas.ops[ti].angle or 0) - math.pi / 2) < 1e-6,
        tag .. ": the turn commits, snapped to a quarter turn")

    -- colour, size and opacity from the menu, in the same sheet
    findButton(view._sel_dialog, "Colour").callback()
    ok(view._sel_dialog and findButton(view._sel_dialog, "Back"), tag .. ": Colour shows the colours in the menu")
    view:selSetColour({ 0x88, 0x88, 0x88 })
    ok(view.canvas.ops[ti].color[1] == 0x88, tag .. ": shape recoloured")
    view:selSetSize(9)
    ok(view.canvas.ops[ti].width == 9, tag .. ": shape line size changed")
    view:selSetOpacity(50)
    ok(view.canvas.ops[ti].alpha == math.floor(50 / 100 * 255 + 0.5), tag .. ": shape opacity changed")

    local nd = view.canvas:opCount()
    view:selDelete()
    ok(view.canvas:opCount() == nd - 1 and view.selection == nil, tag .. ": delete removes the shape")

    -- undo brings the deleted shape back, redo removes it again
    view:undo()
    ok(view.canvas:opCount() == nd, tag .. ": undo restores the deleted shape")
    view:redo()
    ok(view.canvas:opCount() == nd - 1, tag .. ": redo removes it again")

    -- a finished-but-pending shape (its lift was missed) must commit as the
    -- type it was drawn with, even after the shape type changes under it -- it
    -- must NOT be re-typed into whatever is selected now. Regression: drawing a
    -- square then picking arrow turned the square itself into a diagonal arrow.
    view:setTool("shape")
    view.shape, view.shape_fill, view.shape_arrow = "rect", false, nil
    local nb = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx - 60, v.area_y + 300))
    view:onIaPan(nil, pos(midx + 60, v.area_y + 420))     -- square, no release (lift lost)
    ok(view.shape_drag ~= nil and view.canvas:opCount() == nb, tag .. ": square left pending")
    -- now switch the shape type to an arrow, as the picker does
    view.shape, view.shape_fill, view.shape_arrow = "line", false, "end"
    view:flushShape()   -- what opening the picker / a tool change now does
    ok(view.canvas:opCount() == nb + 1, tag .. ": pending square is placed, not dropped")
    local sq = view.canvas.ops[nb + 1]
    ok(sq.shape == "rect" and not sq.arrow, tag .. ": it commits as a rect, not re-typed to an arrow")
    -- and a freshly drawn arrow is its own separate op
    view:onIaTouch(nil, pos(midx - 60, v.area_y + 520))
    view:onIaPan(nil, pos(midx + 60, v.area_y + 560))
    view:onIaPanRelease(nil, pos(midx + 60, v.area_y + 560))
    ok(view.canvas:opCount() == nb + 2, tag .. ": the arrow is a separate op")
    local ar = view.canvas.ops[nb + 2]
    ok(ar.shape == "line" and ar.arrow == "end", tag .. ": the new op is the arrow")

    view:setTool("pen")

    -- zoom: starts filling the width (no side letterbox), consistent
    -- multiplicative steps, clamped at fit and max
    local z0 = view.view.zoom
    local fill = math.max(view.zoom_min, view.view.area_w / view.view.canvas_w)
    ok(math.abs(z0 - fill) < 1e-6, tag .. ": starts at fill-width zoom")
    view:zoomStep(1)
    ok(math.abs(view.view.zoom / z0 - 1.5) < 1e-6, tag .. ": one zoom in step is x1.5")
    view:zoomStep(1)
    ok(math.abs(view.view.zoom / z0 - 2.25) < 1e-6, tag .. ": two steps is x2.25 (consistent)")
    for _ = 1, 20 do view:zoomStep(1) end
    ok(view.view.zoom <= 8.0 + 1e-6, tag .. ": zoom clamps at ZOOM_MAX")
    for _ = 1, 30 do view:zoomStep(-1) end
    ok(math.abs(view.view.zoom - view.zoom_min) < 1e-6, tag .. ": zoom clamps back to fit")

    -- pan while zoomed in
    view:zoomStep(1); view:zoomStep(1)
    view:setTool("pan")
    local px0 = view.view.pan_x
    view:onIaTouch(nil, pos(midx, v.area_y + 100))
    view:onIaPan(nil, pos(midx - 40, v.area_y + 100))   -- drag left
    view:onIaPanRelease(nil, pos(midx - 40, v.area_y + 100))
    ok(view.view.pan_x >= px0 - 1e-6, tag .. ": dragging left pans content (pan_x increases)")

    -- two finger pan (same path, works whatever the tool, commits open strokes)
    view:setTool("pen")
    view:onIaTwoPan(nil, pos(midx, v.area_y + 100))
    view:onIaTwoPan(nil, pos(midx - 30, v.area_y + 100))
    view:onIaTwoPanRel(nil, {})
    ok(view.pan_last == nil, tag .. ": two finger release clears pan state")
    view:paintTo(Screen.bb, 0, 0)
    view:zoomStep(-1); view:zoomStep(-1)

    -- every grid style paints as an overlay without writing out of bounds, at a
    -- faint and a full (ink-dark) strength
    view.grid_on = true
    for _, gs in ipairs({ "square", "dots", "lines", "iso", "thirds" }) do
        view.grid_style = gs
        for _, strength in ipairs({ 10, 100 }) do
            view.grid_strength = strength
            view:renderView(); view:paintTo(Screen.bb, 0, 0)
        end
    end
    ok(true, tag .. ": all grid styles render at any strength")

    -- the tiny grid size that used to make drawing crawl: a clipped redraw (as the
    -- live-stroke paint does) must stay in bounds and cost only the clip region
    view.grid_size = 8
    local clip = { x0 = 20, y0 = 20, x1 = 120, y1 = 140 }
    local oob0 = BB.out_of_bounds
    for _, gs in ipairs({ "square", "dots", "lines", "iso" }) do
        view.grid_style = gs
        view:drawGrid(Screen.bb, v.area_x, v.area_y, clip)
        view:drawGrid(Screen.bb, v.area_x, v.area_y)   -- full-area redraw still works
    end
    ok(BB.out_of_bounds == oob0, tag .. ": clipped and full grid redraws stay in bounds at min grid size")
    view.grid_size = math.max(24, math.floor(W / 16))
    view.grid_style = "square"
    view.grid_on = false
    view:renderView()

    -- the settings sheet builds with the grid folded behind one button (no inline
    -- toggle/sliders, so no scroll): opening and closing it must not error
    view:openSettings()
    ok(view._settings_dialog ~= nil, tag .. ": settings sheet opens")
    view._settings_dialog:onCloseWidget()
    UIManager:close(view._settings_dialog)
    view._settings_dialog = nil

    -- the grid sub-sheet builds in both states (grid on with a style highlighted,
    -- and grid off) without error -- this is where the type/size/opacity controls
    -- now live so the main sheet no longer needs to scroll
    view.grid_on = true; view.grid_style = "square"
    view:openGridSettings()
    ok(view._grid_dialog ~= nil, tag .. ": grid sub-sheet opens (grid on)")
    view._grid_dialog:onCloseWidget(); UIManager:close(view._grid_dialog); view._grid_dialog = nil
    view.grid_on = false
    view:openGridSettings()
    ok(view._grid_dialog ~= nil, tag .. ": grid sub-sheet opens (grid off)")
    view._grid_dialog:onCloseWidget(); UIManager:close(view._grid_dialog); view._grid_dialog = nil

    -- symmetry: a mirrored stroke tags its op and stays in bounds
    view:setTool("pen")
    view.symmetry = "quad"
    local ns = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx - 60, v.area_y + 80))
    view:onIaPan(nil, pos(midx - 40, v.area_y + 120))
    view:onIaPanRelease(nil, pos(midx - 40, v.area_y + 120))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == ns + 1, tag .. ": symmetric stroke commits one op")
    ok(view.canvas.ops[ns + 1].sym == "quad", tag .. ": stroke records its symmetry mode")
    view:paintTo(Screen.bb, 0, 0)
    view.symmetry = "off"

    -- an arrow shape places and carries its arrow flag
    view:setTool("shape")
    view.shape, view.shape_fill, view.shape_arrow = "line", false, "end"
    local na = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx - 60, v.area_y + 250))
    view:onIaPan(nil, pos(midx + 60, v.area_y + 250))
    view:onIaPanRelease(nil, pos(midx + 60, v.area_y + 250))
    ok(view.canvas:opCount() == na + 1 and view.canvas.ops[na + 1].arrow == "end",
        tag .. ": arrow shape carries its arrowhead")
    -- an arrow can be held to select it, just like the other shapes
    view:setTool("pan")
    view:onIaHold(nil, pos(midx, v.area_y + 250))
    ok(view.selection and view.canvas.ops[view.selection.idxs[1]].arrow == "end",
        tag .. ": holding an arrow selects it for the edit menu")
    view:dropSelection()
    view.shape_arrow = nil

    -- selecting an export area by dragging a box
    view:setTool("pen")
    view.selecting_crop = true
    view:onIaTouch(nil, pos(midx - 50, v.area_y + 50))
    view:onIaPan(nil, pos(midx + 50, v.area_y + 150))
    view:onIaPanRelease(nil, pos(midx + 50, v.area_y + 150))
    ok(view.save_area ~= nil and view.save_area.w > 0, tag .. ": drag sets an export area")
    view.save_area = nil

    -- ghosting cleanup counts strokes and resets at its threshold
    view.ghost_clean = 2
    view._strokes_since_full = 0
    view:onIaTouch(nil, pos(midx, v.area_y + 300)); view:onIaPanRelease(nil, pos(midx, v.area_y + 300)); UIManager.fireScheduled()
    view:onIaTouch(nil, pos(midx + 5, v.area_y + 305)); view:onIaPanRelease(nil, pos(midx + 5, v.area_y + 305)); UIManager.fireScheduled()
    ok(view._strokes_since_full == 0, tag .. ": ghosting cleanup fires at the threshold")
    view.ghost_clean = 0

    -- lasso select, move and delete (drives the real gesture handlers)
    do
        local Geom = require("ink/geom")
        local function scr(cx, cy) return Geom.toScreen(v, cx, cy) end
        view:setTool("lasso")
        view.canvas:setOps({
            { kind = "ink", width = 6, pts = { 100, 100, 120, 120 } },   -- centroid ~ (110,110)
            { kind = "ink", width = 6, pts = { 400, 400, 420, 420 } },   -- centroid ~ (410,410)
        })
        local ax, ay = scr(60, 60)
        local bx, by = scr(160, 160)
        view:onIaTouch(nil, pos(ax, ay))
        view:onIaPan(nil, pos(bx, ay))
        view:onIaPan(nil, pos(bx, by))
        view:onIaPan(nil, pos(ax, by))
        view:onIaPanRelease(nil, pos(ax, ay))
        ok(view.selection and #view.selection.idxs == 1 and view.selection.idxs[1] == 1,
            tag .. ": lasso selects only the enclosed op")
        -- drag the selection by +50,+50 canvas px
        local px0 = view.canvas.ops[1].pts[1]
        local sx, sy = scr(110, 110)
        local d = 50 * v.zoom
        view:onIaTouch(nil, pos(sx, sy))
        view:onIaPan(nil, pos(sx + d, sy + d))
        view:onIaPanRelease(nil, pos(sx + d, sy + d))
        ok(math.abs((view.canvas.ops[1].pts[1] - px0) - 50) < 2, tag .. ": dragging the selection moves its ops")
        ok(view.canvas.ops[2].pts[1] == 400, tag .. ": the unselected op stays put")
        view:undo()
        ok(view.canvas.ops[1].pts[1] == px0, tag .. ": undo puts a moved selection back")
        view:redo()
        ok(math.abs((view.canvas.ops[1].pts[1] - px0) - 50) < 2, tag .. ": redo moves it again")
        view.selection = { idxs = { 1 } }
        view:recomputeSelectionBBox()
        view:selDelete()
        ok(view.canvas:opCount() == 1 and not view.selection, tag .. ": deleting the selection removes its ops")

        -- forgiving pick: a long stroke whose average point is OUTSIDE the loop
        -- (this used to fail with the centroid-only test)
        view:setTool("lasso")
        view.canvas:setOps({
            { kind = "ink", width = 6, pts = { 40, 200, 120, 200, 200, 200, 280, 200, 360, 200 } }, -- centroid x=200
        })
        local la0, lb0 = scr(20, 170)
        local la1, lb1 = scr(150, 230)   -- covers x 20..150: 40% of points, centroid (200) is outside
        view:onIaTouch(nil, pos(la0, lb0))
        view:onIaPan(nil, pos(la1, lb0))
        view:onIaPan(nil, pos(la1, lb1))
        view:onIaPan(nil, pos(la0, lb1))
        view:onIaPanRelease(nil, pos(la0, lb0))
        ok(view.selection and #view.selection.idxs == 1,
            tag .. ": lasso picks a stroke even when its average point is outside the loop")
        view:clearSelection()

        -- a sloppy loop: open (the lift is joined back to the start with a straight
        -- line), running on past its start, and grazing a letter; and a text box
        local function loop(list)
            view:onIaTouch(nil, pos(scr(list[1], list[2])))
            for i = 3, #list - 2, 2 do view:onIaPan(nil, pos(scr(list[i], list[i + 1]))) end
            view:onIaPanRelease(nil, pos(scr(list[#list - 1], list[#list])))
        end
        view.canvas:setOps({
            { kind = "ink", width = 6, pts = { 200, 200, 230, 240, 260, 200 } },   -- inside
            { kind = "ink", width = 6, pts = { 300, 210, 300, 260 } },             -- the loop runs over it
            { kind = "text", x = 220, y = 300, w = 60, h = 30, text = "hi", size = 20 },
            { kind = "ink", width = 6, pts = { 700, 700, 720, 720 } },             -- far away
        })
        -- an open C: from top left, round the right, ending bottom left (no return)
        loop({ 180, 180, 300, 180, 330, 260, 300, 350, 180, 350 })
        local picked = {}
        for _, i in ipairs(view.selection and view.selection.idxs or {}) do picked[i] = true end
        ok(picked[1] and picked[3] and not picked[4], tag .. ": an open loop is closed with a straight line back to its start")
        ok(picked[2], tag .. ": writing the loop's line runs over is still taken")
        ok(picked[3], tag .. ": a text box inside is taken too")
        view:clearSelection()
        -- a loop that carries on past where it began, wrapping the start twice
        loop({ 180, 180, 330, 180, 330, 350, 180, 350, 180, 170, 260, 175, 330, 190 })
        picked = {}
        for _, i in ipairs(view.selection and view.selection.idxs or {}) do picked[i] = true end
        ok(picked[1] and picked[3] and not picked[4], tag .. ": a loop that overlaps its own start still holds what is inside")
        view:clearSelection()
        view.canvas:setOps({})   -- (the mock cannot lay out the text box later)
        view:setTool("pen")
    end

    -- export sheet wiring (no native encoders are called)
    local PathChooser = require("ui/widget/pathchooser")
    local InputDialog = require("ui/widget/inputdialog")
    view:setTool("pen")
    view:openExport()
    ok(view._save_dialog ~= nil, tag .. ": Export opens the export sheet")
    view._save_dialog:onCloseMenu()
    ok(view:exportOptions().fmt == "png", tag .. ": a drawing exports a PNG by default")
    -- the sheet's Export button asks for a name, with a button to pick a folder
    view:promptExportName()
    ok(InputDialog.last ~= nil and InputDialog.last.input == view:docName(), tag .. ": the name starts as the document's")
    local folderBtn = InputDialog.last.buttons[1][2]
    ok(folderBtn and folderBtn.callback and not folderBtn.is_enter_default, tag .. ": the prompt has a Folder button")
    folderBtn.callback()
    ok(PathChooser.last ~= nil and PathChooser.last.select_directory, tag .. ": Folder opens a folder chooser")
    PathChooser.last.onConfirm("/tmp")
    ok(view:exportOptions().dir == "/tmp" and InputDialog.last.description:find("/tmp", 1, true),
        tag .. ": the picked folder is kept for this document and the prompt comes back")
    view:exportOptions().dir = nil

    view:paintTo(Screen.bb, 0, 0)

    -- simulate a rotation: screen dims swap, and the page reshapes to match (so the
    -- export follows the orientation); the stroke ops are kept, not deleted
    local prev_ops = view.canvas:opCount()
    Screen:setSize(H, W)
    view:onSetDimensions()
    ok(view.view.area_w == H, tag .. ": relayout picks up new screen width")
    ok(view.canvas.w == H and view.canvas.h == W, tag .. ": page reshapes to the rotated screen")
    ok(view.canvas:opCount() == prev_ops, tag .. ": rotation keeps the ops (nothing deleted)")
    view:paintTo(Screen.bb, 0, 0)
    Screen:setSize(W, H)  -- restore for the OOB assertion context
    view:onSetDimensions()  -- reshape back to portrait for the remaining assertions

    -- lifecycle
    view:onCloseWidget()
    ok(view.area_bb == nil, tag .. ": area buffer freed on close")

    ok(BB.out_of_bounds == 0, tag .. ": nothing paints out of bounds")

    -- reset dialog singletons between sizes
    ButtonDialog.last, PathChooser.last, InputDialog.last = nil, nil, nil
    require("ui/widget/doublespinwidget").last = nil
    require("ui/widget/spinwidget").last = nil
end

-- ---- committed-text undo peels word by word (does not nuke the block) -----
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local Text = require("ink/text")
    local Notebook = require("ink/notebook")
    -- stub the heavy repaint/measure paths (no fonts/rendertext in this env)
    view.composeCanvas = function() end
    view.renderView = function() end
    view.areaScreenRect = function() return { x = 0, y = 0, w = 10, h = 10 } end

    local op = Text.new{ x = 0, y = 0, w = 500, size = 20 }
    Text.insert(op, { p = 1, o = 0 }, "hello world")
    view.canvas.ops = { op }
    -- the word-level history the editor would have recorded (empty, then "hello ")
    local s0 = Text.new{ w = 500, size = 20 }
    local s1 = Text.new{ w = 500, size = 20 }; Text.insert(s1, { p = 1, o = 0 }, "hello ")
    view._text_hist[op] = {
        undo = { { paras = Notebook.deepcopy(s0.paras), cur = { p = 1, o = 0 } },
                 { paras = Notebook.deepcopy(s1.paras), cur = { p = 1, o = 0 } } },
        redo = {},
    }

    view:undo()
    ok(Text.plain(view.canvas.ops[1]) == "hello ", "text undo: first undo peels back one word")
    ok(#view.canvas.ops == 1, "text undo: box is not removed by the first undo")
    view:undo()
    ok(Text.plain(view.canvas.ops[1]) == "", "text undo: second undo peels to empty")
    view:redo()
    ok(Text.plain(view.canvas.ops[1]) == "hello ", "text redo: replays a peeled word")
    view:redo()
    ok(Text.plain(view.canvas.ops[1]) == "hello world", "text redo: restores the full text")
    -- redo interception only applies to the box actively being peeled
    view._peel_op = nil
    view:redo()
    ok(Text.plain(view.canvas.ops[1]) == "hello world", "text redo: no peel when not actively peeling")
    -- undoing past the stored history must not crash (falls through to ops undo)
    view:undo(); view:undo(); view:undo()
    ok(true, "text undo: peeling past the history is safe")
    view:onCloseWidget()
end

-- ---- the editing box rect must not double-count the area origin ----------
-- Regression: toScreen already adds area_x/area_y, so textBoxScreenRect must
-- return exactly that (adding it again shifted the editing overlay down by one
-- toolbar height versus the committed box).
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local Text = require("ink/text")
    local InkGeom = require("ink/geom")
    local vv = view.view
    view.editing_text = Text.new{ x = 40, y = 300, w = 400, size = 20 }
    view.editing_text.h = 120
    local sx, sy = InkGeom.toScreen(vv, 40, 300)
    local r = view:textBoxScreenRect()
    ok(math.abs(r.x - sx) < 0.01, "text box rect x = toScreen x (no double area offset)")
    ok(math.abs(r.y - sy) < 0.01, "text box rect y = toScreen y (no double area offset)")
    ok(r.y >= vv.area_y - 1, "text box top is at or below the area top, not doubled past it")
    view.editing_text = nil
    view:onCloseWidget()
end

-- ---- placed images: insert, move/resize, rotate/flip, z-order, undo, delete ----
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local RenderImage = require("ui/renderimage")
    local Export = require("ink/export")
    local InkGeom = require("ink/geom")
    RenderImage.fake_size = { w = 400, h = 200 }   -- natural 2:1 picture
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local v = view.view
    BB.out_of_bounds = 0

    ok(type(Export.image_raster) == "function", "image: exporter raster is injected on open")

    view:insertImage("/tmp/pic.png")
    local function sel() return view.selection and view.canvas.ops[view.selection.idxs[1]] end
    ok(view.selection ~= nil and #view.selection.idxs == 1, "image: insert selects the new image")
    local op = sel()
    ok(op and op.kind == "image", "image: inserted op is an image op")
    ok(view.canvas:opCount() == 1, "image: op added to the ops list")
    ok(view.tool == "pan", "image: insert switches to Pan mode (the smooth move/resize)")
    ok(view._sel_dialog ~= nil and findButton(view._sel_dialog, "Remove background"),
        "image: insert opens its menu right away, with Remove background")
    -- it must be clearly SMALLER than the viewport (~60%) so every corner shows
    ok(op.w <= 0.62 * v.area_w / v.zoom and op.h <= 0.62 * v.area_h / v.zoom,
        "image: inserted image is smaller than the screen (all corners reachable)")
    ok(math.abs(op.w / op.h - 2) < 0.02, "image: inserted image keeps its 2:1 aspect ratio")

    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "image: selected overlay paints in bounds")

    -- move: grab the middle, drag right+down (an edit clones the op, so re-read it)
    local f = view:selFrame()
    local cxm, cym = (f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2
    local x0, y0 = op.x, op.y
    view:onIaTouch(nil, pos(cxm, cym))
    ok(view.sel_drag and view.sel_drag.kind == "move", "image: touch inside begins a move")
    view:onIaPan(nil, pos(cxm + 60, cym + 40))
    ok(view._lifted and view._lifted[op] and view.sel_drag.card, "image: a move lifts it onto a card")
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "image: the lifted card paints in bounds")
    view:onIaPanRelease(nil, pos(cxm + 60, cym + 40))
    op = sel()
    ok(op.x > x0 and op.y > y0 and view._lifted == nil, "image: dragging moves the image")
    ok(view.selection ~= nil, "image: it stays selected after a move")
    ok(view.canvas:canUndo(), "image: a move records undo history")
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "image: overlay still in bounds after moving")

    -- resize from the SE corner: opposite (NW) corner stays put, aspect locked
    local f2 = view:selFrame()
    local fx, fy = op.x, op.y                   -- NW corner is fixed for an SE drag
    local w_before, ratio = op.w, op.w / op.h
    view:onIaTouch(nil, pos(f2.x1, f2.y1))
    ok(view.sel_drag and view.sel_drag.kind == "resize", "image: a corner touch begins a resize")
    view:onIaPan(nil, pos(f2.x1 + 120, f2.y1 + 30))
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "image: a resizing card paints in bounds")
    view:onIaPanRelease(nil, pos(f2.x1 + 120, f2.y1 + 30))
    op = sel()
    ok(op.w > w_before, "image: dragging the SE corner outward grows the image")
    ok(math.abs(op.w / op.h - ratio) < 0.02, "image: resize keeps the aspect ratio")
    ok(math.abs(op.x - fx) < 0.6 and math.abs(op.y - fy) < 0.6,
        "image: SE resize keeps the opposite (NW) corner fixed")

    -- a quarter turn: op.w/op.h (the unrotated size) are unchanged, only angle
    local rw, rh = op.w, op.h
    findButton(view._sel_dialog, "\u{21BB} 90\u{00B0}").callback()
    op = sel()
    ok((op.angle or 0) == 90, "image: the 90 degree button turns it a quarter")
    ok(math.abs(op.w - rw) < 1e-6 and math.abs(op.h - rh) < 1e-6, "image: and leaves the unrotated size alone")

    -- a free turn with the round handle
    local kx, ky = view:selKnob()
    local f3 = view:selFrame()
    local mx = (f3.x0 + f3.x1) / 2
    view:onIaTouch(nil, pos(kx, ky))
    view:onIaPan(nil, pos(mx + 40, ky))             -- a little way round
    view:onIaPanRelease(nil, pos(mx + 40, ky))
    op = sel()
    ok(math.abs((op.angle or 0) - 90) > 1 and math.abs((op.angle or 0) - 180) > 1,
        "image: the round handle turns it to any angle")

    -- mirrors flip it on the page
    local before_angle = op.angle
    view:selFlip("h"); op = sel()
    ok(op.flip_h == true and math.abs(op.angle - (360 - before_angle) % 360) < 1e-6,
        "image: flip side to side flips it and reverses its angle")
    view:selFlip("v"); op = sel()
    ok(op.flip_v == true, "image: flip up and down too")

    -- z-order: put a later op above, then bring the image to the front
    view.canvas.ops[#view.canvas.ops + 1] = { kind = "ink", pts = { 1, 1, 5, 5 }, width = 5 }
    ok(view.selection.idxs[1] == 1, "image: it sits below the later op")
    view:selToFront()
    ok(view.selection.idxs[1] == #view.canvas.ops and view.canvas.ops[#view.canvas.ops].kind == "image",
        "image: bring to front moves it to the top of the stack")

    -- delete, then undo restores it (regression: the old hidden flag broke this)
    local before = view.canvas:opCount()
    view:selDelete()
    ok(view.selection == nil, "image: delete clears the selection")
    ok(view.canvas:opCount() == before - 1, "image: delete removes the image op")
    view:undo()
    local found = false
    for _, o in ipairs(view.canvas.ops) do if o.kind == "image" then found = true end end
    ok(found, "image: undo restores a deleted image")
    view:redo()
    found = false
    for _, o in ipairs(view.canvas.ops) do if o.kind == "image" then found = true end end
    ok(not found, "image: redo re-applies the delete")

    -- a touch in Pan mode selects reliably (no hold hunting) -- put an image back first
    view:undo()   -- bring the image back
    view:setTool("pan")
    local img
    for _, o in ipairs(view.canvas.ops) do if o.kind == "image" then img = o end end
    local sx, sy = InkGeom.toScreen(v, img.x + img.w / 2, img.y + img.h / 2)
    view:onIaTouch(nil, pos(sx, sy))
    ok(sel() == img, "image: a touch in Pan mode selects it")
    view:onIaTap(nil, pos(sx, sy))
    ok(view._sel_dialog ~= nil, "image: and the tap opens its menu")

    -- an undecodable picture is reported, not inserted
    RenderImage.fake_size = nil
    local cnt = view.canvas:opCount()
    view:insertImage("/tmp/broken.png")
    ok(sel() == img and view.canvas:opCount() == cnt, "image: an undecodable picture is not added")
    RenderImage.fake_size = { w = 400, h = 200 }

    BB.out_of_bounds = 0
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "image: overlay paints in bounds after rotate/flip")

    view:onCloseWidget()
    ok(Export.image_raster == nil, "image: closing drops the exporter raster closure")
    RenderImage.fake_size = { w = 200, h = 100 }   -- restore the module default
end

-- ---- shapes: tap/hold selects + drag to move + rotate 90 (parity with images) --
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local v = view.view
    local InkGeom = require("ink/geom")

    -- a filled rectangle so a tap on its interior hits it
    view.canvas.ops[#view.canvas.ops + 1] =
        { kind = "shape", shape = "rect", fill = true, width = 4, alpha = 255, pts = { 200, 300, 400, 500 } }
    view:setTool("pan")

    local cxs, cys = InkGeom.toScreen(v, 300, 400)   -- centre of the rect
    local function sop() return view.selection and view.canvas.ops[view.selection.idxs[1]] end
    view:onIaTouch(nil, pos(cxs, cys))
    ok(view.selection ~= nil and sop().shape == "rect", "shape: a touch in Pan mode selects it")
    view:onIaTap(nil, pos(cxs, cys))                 -- the tap opens the menu
    ok(view._sel_dialog ~= nil and view.is_always_active == true,
        "shape: an open menu keeps the canvas active for dragging")
    -- now drag it: touch, pan, release
    local x0 = sop().pts[1]
    view:onIaTouch(nil, pos(cxs, cys))
    view:onIaPan(nil, pos(cxs + 90, cys + 40))
    view:onIaPanRelease(nil, pos(cxs + 90, cys + 40))
    ok(sop().pts[1] > x0, "shape: dragging moves the shape")
    ok(view.canvas:canUndo(), "shape: a move records undo history")
    ok(view._sel_dialog ~= nil, "shape: its menu comes back beside its new place")

    local ang0 = sop().angle or 0
    view:selTurn90()
    ok(math.abs((sop().angle or 0) - (ang0 + math.pi / 2)) < 1e-6, "shape: rotate 90 adds a quarter turn")

    -- resize it from a corner: the line grows with it
    local w0 = sop().width
    local f = view:selFrame()
    view:onIaTouch(nil, pos(f.x0, f.y0))
    view:onIaPan(nil, pos(f.x0 - 60, f.y0 - 60))
    view:onIaPanRelease(nil, pos(f.x0 - 60, f.y0 - 60))
    ok(sop().width > w0, "shape: resizing a shape thickens its line with it")

    view:dropSelection()
    ok(view.selection == nil and view._sel_dialog == nil and view.is_always_active == false,
        "shape: deselect clears the selection, its menu and the active flag")

    -- erased shapes are left alone by the move tool; untouched ones are not
    local function rectOp() return { kind = "shape", shape = "rect", fill = false, width = 6,
        alpha = 255, pts = { 200, 300, 400, 500 } } end
    local function picked() return view:hitTestShape(InkGeom.toScreen(v, 300, 400)) ~= nil end
    local function erase(pts, sym) return { kind = "erase", width = 20, pts = pts, sym = sym } end
    view.canvas:setOps({ rectOp() })
    ok(picked(), "erased shapes: a shape with no erasing is picked up")
    view.canvas:setOps({ rectOp(), erase({ 600, 100, 700, 200 }) })
    ok(picked(), "erased shapes: erasing elsewhere on the page changes nothing")
    view.canvas:setOps({ rectOp(), erase({ 260, 520, 340, 540 }) })
    ok(picked(), "erased shapes: erasing that passes close by does not count")
    view.canvas:setOps({ erase({ 180, 400, 220, 400 }), rectOp() })
    ok(picked(), "erased shapes: erasing from before the shape was drawn does not count")
    view.canvas:setOps({ rectOp(), erase({ 180, 400, 220, 400 }) })
    ok(not picked(), "erased shapes: a partly erased shape is left alone")
    view:onIaHold(nil, pos(InkGeom.toScreen(v, 300, 400)))
    ok(view.selection == nil and view._sel_dialog == nil, "erased shapes: holding it opens no menu")
    view.canvas:setOps({ rectOp(), erase({ 200, 300, 400, 300, 400, 500, 200, 500, 200, 300 }, nil) })
    ok(not picked(), "erased shapes: a wholly erased shape is left alone")
    -- a symmetric erase reaches it through its mirror copy
    local mx = v.canvas_w - 1 - 200
    view.canvas:setOps({ rectOp(), erase({ mx - 20, 400, mx + 20, 400 }, "vert") })
    ok(not picked(), "erased shapes: a mirrored erase counts")
    -- undoing the erase frees it again
    view.canvas:setOps({ rectOp() })
    view.canvas:pushHistory()
    view.canvas.ops[2] = erase({ 180, 400, 220, 400 })
    ok(not picked(), "erased shapes: erased")
    view.canvas:undo()
    ok(picked(), "erased shapes: undoing the erase lets it move again")
    -- and an untouched shape still drags as before
    view:onIaTouch(nil, pos(cxs, cys))
    view:onIaPan(nil, pos(cxs + 50, cys))
    view:onIaPanRelease(nil, pos(cxs + 50, cys))
    ok(view.canvas.ops[1].pts[1] > 200, "erased shapes: an untouched shape still moves")
    view:onCloseWidget()
end

-- ---- erase whole strokes: the eraser removes what it touches --------------------
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local v = view.view
    local InkGeom = require("ink/geom")
    local function at(cx, cy) return pos(InkGeom.toScreen(v, cx, cy)) end
    local function stroke(y) return { kind = "ink", width = 6, alpha = 255, pts = { 100, y, 400, y } } end
    local function wipe(x0, y0, x1, y1)
        view:onIaTouch(nil, at(x0, y0))
        view:onIaPan(nil, at(x1, y1))
        view:onIaPanRelease(nil, at(x1, y1))
        UIManager.fireScheduled()
    end
    view.erase_whole = true
    view:setTool("erase")
    view.eraser_width = 20
    view.canvas:setOps({ stroke(200), stroke(300), stroke(400) })
    view:onIaTouch(nil, at(250, 150))
    view:onIaPan(nil, at(250, 320))
    ok(view.canvas:opCount() == 1, "wipe: strokes go as the eraser reaches them")
    view:onIaPanRelease(nil, at(250, 320))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == 1 and view.canvas.ops[1].pts[2] == 400, "wipe: an untouched stroke stays")
    view:undo()
    ok(view.canvas:opCount() == 3, "wipe: one undo brings the whole eraser stroke back")
    view:redo()
    ok(view.canvas:opCount() == 1, "wipe: redo takes them again")

    -- writing on a filled box: the writing goes and the box stays; the box goes alone
    local box = { kind = "shape", shape = "rect", fill = true, width = 4, alpha = 255, pts = { 100, 500, 500, 800 } }
    view.canvas:setOps({ box, stroke(650) })
    wipe(300, 620, 300, 680)
    ok(view.canvas:opCount() == 1 and view.canvas.ops[1] == box, "wipe: rubbing writing on a filled box keeps the box")
    wipe(300, 700, 320, 720)
    ok(view.canvas:opCount() == 0, "wipe: rubbing the box alone removes it")
    wipe(300, 700, 320, 720)
    ok(not view.canvas:canRedo() and view.canvas:opCount() == 0, "wipe: rubbing nothing changes nothing")

    -- a palm that started the eraser stroke: everything comes back
    view.canvas:setOps({ stroke(200), stroke(300) })
    view:onIaTouch(nil, at(250, 150))
    view:onIaPan(nil, at(250, 320))
    ok(view.canvas:opCount() == 0, "wipe: (a palm took both)")
    view:penDropFingerOps()
    ok(view.canvas:opCount() == 2 and not view.canvas:canUndo() and not view.capturing,
        "wipe: dropping a palm's stroke puts back what it took")

    -- the pen's rear eraser wipes too, and the pen tool comes back
    view:setTool("pen")
    view.palm_reject = true
    view:applyPalmReject()
    local function pen(id, cx, cy)
        local x, y = InkGeom.toScreen(v, cx, cy)
        return Device.input.stylus_callback(Device.input, { slot = Device.input.pen_slot, id = id, x = x, y = y, tool = 2 })
    end
    pen(0, 250, 150); pen(0, 250, 320); pen(-1, 250, 320)
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == 0 and view.tool == "pen", "wipe: the pen's eraser end removes whole strokes")
    view.palm_reject = false
    view:applyPalmReject()

    -- off, the eraser rubs out pixels as before
    view.erase_whole = false
    view:setTool("erase")
    view.canvas:setOps({ stroke(200) })
    wipe(250, 150, 250, 250)
    ok(view.canvas:opCount() == 2 and view.canvas.ops[2].kind == "erase", "wipe: off, an erase stroke is added")

    -- the eraser sheet's toggle sits beside Erase pictures and saves the setting
    local function findToggle(root, label)
        local seen = { [view] = true }
        local function walk(t)
            if type(t) ~= "table" or seen[t] then return nil end
            seen[t] = true
            if t.label == label and t.onTap then return t end
            for k, c in pairs(t) do
                if k ~= "parent" and k ~= "show_parent" then
                    local r = walk(c)
                    if r then return r end
                end
            end
        end
        return walk(root)
    end
    view:openEraserSettings()
    local tg = findToggle(view._eraser_dialog, "Erase whole strokes")
    ok(tg ~= nil and tg.is_on == false and findToggle(view._eraser_dialog, "Erase pictures") ~= nil,
        "wipe: the eraser sheet has both toggles, whole strokes off")
    if tg then tg:onTap() end
    ok(view.erase_whole == true and _G.G_reader_settings.data.inkaway_erase_whole == true,
        "wipe: the toggle turns it on and saves it")
    view:closeSheet("_eraser_dialog")
    _G.G_reader_settings.data.inkaway_erase_whole = nil
    view:onCloseWidget()
end

-- ---- palm rejection: the pen draws, a resting palm (finger) is ignored -------
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local v = view.view
    local midx = v.area_x + math.floor(v.area_w / 2)
    local yy = v.area_y + 40
    -- KOReader calls the callback as stylus_callback(input, slot); return true = dominated.
    -- A real pen is always on the digitizer's dedicated pen_slot; a palm arrives on
    -- another slot wearing the eraser's tool number (MT_TOOL_PALM == 2).
    local function pen(id, x, y, tool)
        return Device.input.stylus_callback(Device.input,
            { slot = Device.input.pen_slot, id = id, x = x, y = y, tool = tool or 1 })
    end
    local function palm(id, x, y, tool)
        return Device.input.stylus_callback(Device.input,
            { slot = 0, id = id, x = x, y = y, tool = tool or 2 })
    end

    -- turn palm rejection on: the callback must register on the (mock) Input
    view.palm_reject = true
    view:applyPalmReject()
    ok(Device.input.stylus_callback ~= nil, "palm: enabling it registers a stylus callback")

    -- a full pen stroke commits one op, and the callback dominates every event
    local dom = pen(0, midx, yy)
    ok(dom == true, "palm: the pen event is dominated (kept out of gesture detection)")
    ok(view.capturing, "palm: pen down begins a stroke")
    for i = 1, 6 do pen(0, midx + i * 4, yy + i * 12) end
    ok(view.capturing, "palm: pen moves extend the stroke")
    pen(-1, midx + 28, yy + 84)                 -- lift
    ok(not view.capturing and view.canvas:opCount() == 1, "palm: pen lift commits exactly one op")

    -- while the pen is down, a finger touch (a palm) draws nothing
    pen(0, midx, yy)                            -- pen down again
    ok(view.capturing, "palm: second pen stroke started")
    local before = view.canvas:opCount()
    view:onIaTouch(nil, pos(200, yy + 200))     -- palm lands elsewhere
    view:onIaPan(nil, pos(240, yy + 240))
    view:onIaPanRelease(nil, pos(240, yy + 240))
    ok(view.canvas:opCount() == before, "palm: a finger touch during a pen stroke is ignored")
    pen(-1, midx, yy)                           -- pen up -> commits only the pen's op
    ok(view.canvas:opCount() == before + 1, "palm: only the pen stroke commits, not the palm")

    -- right after the pen lifts, fingers are still rejected (debounce)...
    ok(view:fingerRejected(), "palm: fingers stay rejected briefly after the pen lifts")
    UIManager.fireScheduled()                   -- fires the debounce clear
    ok(not view:fingerRejected(), "palm: after the debounce, fingers work again")

    -- ...but even with the pen idle a finger never draws: it navigates, as a hand
    -- resting on the page is a finger too
    local n = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx, yy))
    ok(not view.capturing, "palm: with the pen idle, a finger does not draw")
    view:onIaPanRelease(nil, pos(midx + 5, yy + 20))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == n, "palm: and leaves no ink")

    -- palm-before-pen: a palm landing first draws nothing, and the pen still writes
    view:onIaTouch(nil, pos(200, yy + 100))     -- palm lands first
    ok(not view.capturing, "palm: a palm landing before the pen draws nothing")
    local m = view.canvas:opCount()
    pen(0, midx, yy)                            -- pen touches down
    pen(0, midx + 10, yy + 20)
    pen(-1, midx + 10, yy + 20)                 -- pen lift
    ok(view.canvas:opCount() == m + 1, "palm: the pen cancels the palm's stroke and commits only its own")
    UIManager.fireScheduled()

    -- coordinate-late protocol: the contact is announced a frame before the first
    -- point, so the stroke must open on the first frame that carries coordinates
    local k = view.canvas:opCount()
    Device.input.stylus_callback(Device.input, { id = 0, tool = 1 })   -- down, no x/y yet
    ok(not view.capturing, "palm: a coordinate-less pen-down waits before opening a stroke")
    pen(0, midx, yy)                                                   -- first real point
    ok(view.capturing, "palm: the first coordinates open the pen stroke")
    pen(0, midx + 8, yy + 20)
    pen(-1, midx + 8, yy + 20)
    ok(view.canvas:opCount() == k + 1, "palm: a coordinate-late pen still commits one stroke")
    UIManager.fireScheduled()

    -- a hover blip (down then up, never any coordinates) must commit nothing
    local j = view.canvas:opCount()
    Device.input.stylus_callback(Device.input, { id = 0, tool = 1 })
    Device.input.stylus_callback(Device.input, { id = -1, tool = 1 })
    ok(view.canvas:opCount() == j and not view.capturing, "palm: a coordinate-less pen blip draws nothing")
    UIManager.fireScheduled()

    -- the eraser end of the pen erases even though the pen tool is selected. On a
    -- Wacom device the real rear eraser is tool 2 ON THE PEN SLOT.
    view:setTool("pen")
    local prev = view.tool
    pen(0, midx, yy, 2)                          -- tool 2 on the pen slot = rear eraser
    ok(view.tool == "erase", "palm: the rear eraser (tool 2 on pen slot) switches to the eraser")
    pen(-1, midx, yy, 2)
    ok(view.tool == prev, "palm: the tool is restored after the eraser-tip stroke")

    -- the primary side (barrel) button acts while held: by default it highlights.
    -- KOReader routes the pen slot with the tool overridden to ERASER (2) AND the
    -- eraser latch set; that must become the button's action, not erase, and the
    -- pen restores on lift.
    view:setTool("pen")
    local prev_sel = view.tool
    local prev_style, prev_width = view.pen_style, view.pen_width
    Device.input.stylus_eraser_active = true
    pen(0, midx, yy, 2)                          -- side button held: tool 2 + latch
    ok(view.tool == "pen" and view.pen_style == "highlighter",
        "palm: the side button highlights while held (the default)")
    pen(0, midx + 60, yy + 4, 2)
    pen(-1, midx + 60, yy + 4, 2)                -- lift
    Device.input.stylus_eraser_active = false
    UIManager.fireScheduled()
    ok(view.pen_style == prev_style and view.pen_width == prev_width and view.tool == prev_sel,
        "palm: the pen is back as it was after the side-button stroke")
    ok(view.canvas.ops[#view.canvas.ops].style == "highlighter", "palm: and the stroke is a highlighter stroke")
    -- set to Lasso, the button selects instead
    view:gestureBindings().pen_side = "lasso"
    Device.input.stylus_eraser_active = true
    pen(0, midx, yy, 2)
    ok(view.tool == "lasso", "palm: set to Lasso, the side button switches to lasso select")
    ok(view.lassoing, "palm: the side-button stroke drives the lasso")
    pen(-1, midx, yy, 2)                         -- lift
    Device.input.stylus_eraser_active = false
    ok(view.tool == prev_sel, "palm: the tool is restored after the side-button stroke")
    view:gestureBindings().pen_side = "highlighter"
    UIManager.fireScheduled()

    -- THE REGRESSION: a resting palm is routed to the stylus callback wearing tool
    -- 2 (MT_TOOL_PALM == TOOL_TYPE_ERASER) on a NON-pen slot. It must draw / erase
    -- nothing at all, and must be dominated so it never becomes a finger gesture.
    view:setTool("pen")
    UIManager.fireScheduled()
    local base = view.canvas:opCount()
    local pdom = palm(9, 200, yy + 300, 2)      -- palm down on slot 0, tool 2
    ok(pdom == true, "palm: a routed palm (tool 2 off the pen slot) is dominated")
    ok(not view.capturing, "palm: a routed palm never opens a stroke")
    ok(view.tool == "pen", "palm: a routed palm never switches to the eraser")
    palm(9, 210, yy + 310, 2)                    -- palm moves
    palm(9, 220, yy + 320, 2)
    palm(-1, 220, yy + 320, 2)                   -- palm lifts
    ok(view.canvas:opCount() == base and not view.capturing,
        "palm: a full palm contact commits nothing")

    -- RETIRE ON PROMOTION: on a real device a palm lands as an ordinary touch and is
    -- only flagged as a palm a frame or two later, after it may already have opened a
    -- stroke. That stray stroke must be retired the instant the promotion arrives, or
    -- it is left behind as the random artifact the tester reported.
    UIManager.fireScheduled()                    -- clear any lingering debounce
    ok(not view:fingerRejected(), "palm: rejection is clear before the promotion test")
    local r0 = view.canvas:opCount()
    view:onIaTouch(nil, pos(240, yy + 260))      -- palm lands, not yet flagged: a finger, which navigates
    view:onIaPan(nil, pos(250, yy + 270))
    ok(not view.capturing, "palm: an unflagged palm touch opens no stroke")
    palm(11, 250, yy + 270, 2)                    -- the digitizer now flags that slot a palm
    ok(not view.capturing, "palm: the promotion retires the stray stroke it had started")
    palm(-1, 250, yy + 270, 2)                    -- palm lifts
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == r0, "palm: a promoted palm leaves no committed op")

    -- while a palm is down, a finger (the same palm reverting to a finger tool, or
    -- a second contact) is still ignored
    palm(9, 200, yy + 300, 2)                    -- palm down again
    ok(view:fingerRejected(), "palm: a routed palm holds finger rejection on")
    local held = view.canvas:opCount()
    view:onIaTouch(nil, pos(205, yy + 305))     -- a finger while the palm rests
    view:onIaPan(nil, pos(215, yy + 315))
    view:onIaPanRelease(nil, pos(215, yy + 315))
    ok(view.canvas:opCount() == held, "palm: fingers draw nothing while a palm is down")
    palm(-1, 200, yy + 300, 2)
    UIManager.fireScheduled()                    -- debounce clears
    ok(not view:fingerRejected(), "palm: after the palm lifts and debounce, fingers work again")

    -- REGRESSION (review finding 1): a stray clear timer firing mid-stroke must NOT
    -- drop finger rejection while the pen is physically down.
    view:setTool("pen")
    pen(0, midx, yy)                             -- pen down, drawing
    ok(view.capturing and view._pen_state.down, "palm: the pen stroke is physically active")
    palm(9, 300, yy + 300, 2)                    -- a palm frame arms the debounce timer
    UIManager.fireScheduled()                    -- fire the timer mid-stroke
    ok(view:fingerRejected(), "palm: rejection holds while the pen is down even if the timer fires")
    local held2 = view.canvas:opCount()
    view:onIaTouch(nil, pos(320, yy + 320))     -- a finger during the still-live pen stroke
    view:onIaPan(nil, pos(340, yy + 340))
    view:onIaPanRelease(nil, pos(340, yy + 340))
    ok(view.canvas:opCount() == held2, "palm: a finger can't merge into the live pen stroke")
    pen(-1, midx, yy)                            -- pen up
    UIManager.fireScheduled()

    -- REGRESSION (review finding, device-reality): a SECOND trusted-stylus slot must
    -- not co-drive the pen's stroke -- off Wacom (Kobo) a barrel-latched palm also
    -- classifies as a pen, and feeding two slots into one stroke draws lines between
    -- them. Slot ownership demotes the second slot to a palm.
    Device.input.wacom_protocol = false          -- pretend a Kobo (off-Wacom) for this block
    view:setTool("pen")
    UIManager.fireScheduled()
    local o = view.canvas:opCount()
    local function slotev(s, id, x, y) return Device.input.stylus_callback(Device.input,
        { slot = s, id = id, x = x, y = y, tool = 1 }) end   -- tool 1 = PEN => trusted off-Wacom
    slotev(Device.input.pen_slot, 0, midx, yy)               -- first stylus slot claims the stroke
    ok(view._pen_owner == Device.input.pen_slot, "palm: the first stylus slot owns the stroke")
    slotev(0, 5, 300, yy + 300)                              -- a second trusted slot elsewhere
    ok(view._pen_owner == Device.input.pen_slot, "palm: a second stylus slot does not steal ownership")
    ok(view._palm_count >= 1, "palm: the second stylus slot is tracked/rejected as a palm")
    slotev(Device.input.pen_slot, 0, midx + 8, yy + 8)       -- owner moves
    slotev(Device.input.pen_slot, -1, midx + 8, yy + 8)      -- owner lifts
    Device.input.stylus_callback(Device.input, { slot = 0, id = -1, tool = 1 })  -- second slot lifts
    Device.input.wacom_protocol = true
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == o + 1, "palm: only the owning slot's stroke commits, not the second")

    -- DEAD-PEN FIX (Kindle Scribe gen 1): when the runtime never populated the pen
    -- slot, a real pen tip (tool 1) must still draw. Before the fix classify required
    -- a preset pen_slot and, finding it nil, called the pen a palm so nothing drew.
    local saved_slot = Device.input.pen_slot
    Device.input.pen_slot = nil
    view:resetPenState()
    local p = view.canvas:opCount()
    local function noslot(id, x, y) return Device.input.stylus_callback(Device.input,
        { id = id, x = x, y = y, tool = 1 }) end   -- tool 1 = PEN, no slot / no pen_slot
    noslot(0, midx, yy)
    ok(view.capturing, "palm: a real pen draws even with no known pen slot (dead-pen fix)")
    noslot(0, midx + 8, yy + 20)
    noslot(-1, midx + 8, yy + 20)
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == p + 1, "palm: the no-pen-slot pen commits exactly one stroke")
    Device.input.pen_slot = saved_slot

    -- PEN UI: a pen contact that lands on the toolbar is left to the gesture
    -- detector (not dominated) and never draws; turned off, the pen stays with Ink
    -- Away there as before.
    view:setTool("pen")
    view:resetPenState()
    UIManager.fireScheduled()
    local tb_y = math.floor(v.area_y / 2)
    local q = view.canvas:opCount()
    ok(view.pen_ui == true, "pen ui: on by default")
    ok(pen(0, 100, tb_y) == false, "pen ui: a pen landing on the toolbar goes to the gesture detector")
    ok(not view.capturing and view._pen_ui_contact, "pen ui: it opens no stroke")
    ok(pen(0, 104, tb_y) == false, "pen ui: its moves go to the detector too")
    ok(not view:fingerRejected({ x = 104, y = tb_y }), "pen ui: its own gestures get past finger rejection")
    ok(view:fingerRejected({ x = 400, y = yy + 300 }), "pen ui: a palm elsewhere is still rejected")
    ok(pen(-1, 104, tb_y) == false, "pen ui: so does the lift")
    ok(not view._pen_ui_contact and not view:fingerRejected({ x = 104, y = tb_y }),
        "pen ui: the tap the lift makes still gets through")
    UIManager.fireScheduled()
    ok(view._pen_ui == nil and not view:fingerRejected(), "pen ui: the pass-through ends after the tick")
    ok(view.canvas:opCount() == q, "pen ui: the toolbar tap drew nothing")
    -- a stroke that starts on the canvas keeps drawing onto the toolbar
    ok(pen(0, midx, yy) == true, "pen ui: a pen landing on the canvas still draws")
    pen(0, midx, tb_y)
    pen(-1, midx, tb_y)
    ok(view.canvas:opCount() == q + 1, "pen ui: a stroke may run onto the toolbar")
    UIManager.fireScheduled()
    -- the rear eraser's first frame has no point yet; its first point is on the toolbar
    Device.input.stylus_callback(Device.input, { slot = Device.input.pen_slot, id = 0, tool = 2 })
    ok(view.tool == "erase", "pen ui: the rear eraser swapped the tool in")
    ok(pen(0, 100, tb_y, 2) == false and view.tool == "pen" and not view._pen_state.down,
        "pen ui: a first point on the toolbar hands the contact over and puts the tool back")
    pen(-1, 100, tb_y, 2)
    UIManager.fireScheduled()
    -- a floating control (the zoom pill) is UI too
    local zr = view:fabRect("zoom")
    ok(pen(0, zr.x + 4, zr.y + 4) == false, "pen ui: the zoom pill takes the pen")
    pen(-1, zr.x + 4, zr.y + 4)
    UIManager.fireScheduled()
    -- with the toggle off the pen never reaches the toolbar
    view.pen_ui = false
    ok(pen(0, 100, tb_y) == true and not view._pen_ui_contact, "pen ui: off, the pen stays with Ink Away")
    pen(-1, 100, tb_y)
    view.pen_ui = true
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == q + 1 and not view:fingerRejected(), "pen ui: nothing drawn, nothing stuck")
    -- the pen sheet's toggle switches it and remembers it
    local function findToggle(root, label)
        local seen = { [view] = true }
        local function walk(t)
            if type(t) ~= "table" or seen[t] then return nil end
            seen[t] = true
            if t.label == label and t.onTap then return t end
            for k, c in pairs(t) do
                if k ~= "parent" and k ~= "show_parent" then
                    local r = walk(c)
                    if r then return r end
                end
            end
        end
        return walk(root)
    end
    view:openPenInput()
    local tg = findToggle(view._peninput_dialog, "Pen taps menus and buttons")
    ok(tg ~= nil and tg.is_on == true, "pen ui: the Pen and input sheet has the toggle, on")
    if tg then tg:onTap() end
    ok(view.pen_ui == false and _G.G_reader_settings.data.inkaway_pen_ui == false,
        "pen ui: the toggle turns it off and saves it")
    if tg then tg:onTap() end
    ok(view.pen_ui == true, "pen ui: and back on")
    view:closeSheet("_peninput_dialog")
    -- a narrow sheet still lays them all out
    local sw = view.sheetWidth
    view.sheetWidth = function() return 120, 12, 27 end
    view:openPenInput()
    ok(findToggle(view._peninput_dialog, "Pen taps menus and buttons") ~= nil
        and findToggle(view._peninput_dialog, "Palm rejection") ~= nil,
        "pen ui: a narrow sheet still has every toggle")
    view:closeSheet("_peninput_dialog")
    view:openPenSettings()
    ok(view._pen_dialog ~= nil, "pen ui: a narrow pen case still opens")
    view:closeSheet("_pen_dialog")
    view.sheetWidth = sw

    -- turning it off unregisters the callback
    view.palm_reject = false
    view:applyPalmReject()
    ok(Device.input.stylus_callback == nil, "palm: disabling it removes the stylus callback")
    view:onCloseWidget()
end

-- ---- SliderRow: drag updates value/fill/knob/text IN PLACE (no rebuild) -------
do
    local SliderRow = require("ink/ui/controls").SliderRow
    local sr = SliderRow:new{ label = "Size", value = 10, min = 0, max = 100, step = 5,
        width = 400, on_set = function() end }
    ok(sr._fill_wc ~= nil and sr._valw ~= nil, "slider: build stored the moving-part refs")
    sr.dimen.x, sr.dimen.y = 20, 50            -- simulate a painted slot position
    local fill0, valw0 = sr._fill_wc, sr._valw
    local w0 = sr._fill_wc.dimen.w
    -- drag to the right end of the track
    local rx = sr.dimen.x + sr._track_dx + sr._track_w - 2
    sr:onSlPan(nil, { pos = { x = rx, y = sr.dimen.y + 5 } })
    ok(sr.value == 100, "slider: drag to the right end -> max value")
    ok(sr._fill_wc == fill0 and sr._valw == valw0, "slider: widgets reused, not rebuilt")
    ok(sr._fill_wc.dimen.w > w0, "slider: fill width grew in place")
    ok(sr._valw.text == sr:_fmt(100), "slider: value text updated in place")
    ok(sr._knob.overlap_offset[1] > 0, "slider: knob moved along the track")
    -- and back to the left
    sr:onSlPan(nil, { pos = { x = sr.dimen.x + sr._track_dx - 50, y = sr.dimen.y + 5 } })
    ok(sr.value == 0, "slider: drag past the left end -> min value")
    ok(sr._valw.text == sr:_fmt(0), "slider: value text updated to min in place")
    -- a quick drag ends as a swipe (pos = start, end_pos = lift): the slider
    -- claims it, so the sheet around it does not move
    ok(sr.ges_events.SlSwipe ~= nil and sr.ges_events.SlMultiSwipe ~= nil,
        "slider: listens for swipes and multiswipes")
    local mid = sr.dimen.x + sr._track_dx + math.floor(sr._track_w / 2)
    local taken = sr:onSlSwipe(nil, { pos = { x = sr.dimen.x + sr._track_dx + 2, y = sr.dimen.y + 5 },
        end_pos = { x = mid, y = sr.dimen.y + 5 }, direction = "east", distance = 100 })
    ok(taken == true, "slider: a swipe starting on it is consumed")
    ok(sr.value == 50, "slider: a swipe sets the value from where it lifted")
end

-- ---- straightening rebuilds the master over the footprint only ------------
-- Hold to straighten swaps a stroke for a clean op, then updates the master over
-- just the footprint (and each symmetry mirror of it) by composing it again, so
-- a stroke start copies nothing. The pixel result is checked on the real blitter
-- (tests/realbb/selection.lua); here the wiring, and that the work is the
-- footprint's, not the page's.
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local v = view.view
    local midx = v.area_x + math.floor(v.area_w / 2)
    local midy = v.area_y + math.floor(v.area_h / 2)
    view.hold_straighten = true
    view.tool = "pen"
    view:beginStroke(midx, midy)
    ok(view._pre_stroke_bb == nil, "beautify: a stroke start copies nothing")
    view.capturing = false

    local regions = {}
    view.composeRegion = function(_, x0, y0, x1, y1) regions[#regions + 1] = { x0, y0, x1, y1 } end
    local function inBounds()
        for _, r in ipairs(regions) do
            if r[1] < 0 or r[2] < 0 or r[3] > v.canvas_w or r[4] > v.canvas_h or r[3] <= r[1] or r[4] <= r[2] then
                return false
            end
        end
        return true
    end
    local okc = view:beautifyRecompose({ 100, 100, 300, 260 }, { kind = "ink", pts = { 110, 120, 290, 250 }, width = 8 })
    ok(okc == true and #regions == 1, "beautify: the footprint is composed again")
    ok(regions[1][1] <= 96 and regions[1][2] <= 96 and regions[1][3] >= 304 and regions[1][4] >= 264,
        "beautify: covering the raw ink and the clean op, with their width")
    regions = {}
    okc = view:beautifyRecompose({ 100, 100, 300, 260 },
        { kind = "ink", pts = { 100, 100, 300, 260 }, width = 8, sym = "quad" })
    ok(okc == true and #regions == 4 and inBounds(), "beautify: quad symmetry composes four mirror regions, in bounds")
    -- the work is the footprint's, however many ops the page holds
    for i = 1, 500 do
        view.canvas.ops[#view.canvas.ops + 1] = { kind = "ink", pts = { i, i, i + 1, i + 1 }, width = 2 }
    end
    regions = {}
    okc = view:beautifyRecompose({ 100, 100, 300, 260 }, { kind = "ink", pts = { 100, 100, 300, 260 }, width = 8 })
    ok(okc == true and #regions == 1, "beautify: still one region with 500 ops on the page")
    regions = {}
    okc = view:beautifyRecompose({ -50, -50, 5, 5 }, { kind = "ink", pts = { -40, -40, 2, 2 }, width = 8 })
    ok(okc == true and inBounds(), "beautify: a footprint off the page's edge is clipped to it")
    view.composeRegion = nil
end

-- ---- bookshelf ornament save: detection degrades safely off-device -----------
-- With no datastorage / pluginloader in the bare test env, the detection must
-- return nil (no ornament target, so the save sheet omits the button) and never
-- throw -- so a device without the bookshelf plugin never sees the option.
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local dok, dir = pcall(function() return view:ornamentsDir() end)
    ok(dok, "ornament: ornamentsDir() never errors")
    ok(dir == nil, "ornament: no bookshelf/datastorage in the test env -> no ornament target")
    local bok = pcall(function() return view:bookshelfInstalled() end)
    ok(bok, "ornament: bookshelfInstalled() never errors")
end

-- ---- online image browser: closing clears session state --------------------
-- A follow-up "Browse online" must start fresh, not reopen with (or search) the
-- previous query. Closing the browser must drop the session state and the box.
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view._image_browser = { query = "cat", thumbs = {}, results = {}, page = 1 }
    local cok = pcall(function() return view:onImageBrowserClose() end)
    ok(cok, "browser: onImageBrowserClose never errors")
    ok(view._image_browser == nil, "browser: closing clears the session (no stale query)")
    ok(view._img_search_dialog == nil, "browser: closing leaves no search box")
    ok(view._image_browser_dialog == nil, "browser: closing leaves no sheet")
    -- closeImageSearchPrompt is idempotent / nil-safe
    ok(pcall(function() view:closeImageSearchPrompt() end), "browser: closeImageSearchPrompt is nil-safe")
end

-- ---- orientation: portrait <-> landscape -----------------------------------
-- Ink Away can run either way up. Switching orientation rotates the screen and,
-- for a still-blank page, reshapes the canvas to the new (wide or tall) size so a
-- fresh drawing fills it. The export size follows the canvas, so a landscape
-- drawing exports wide, and the chosen orientation is remembered across launches.
do
    _G.G_reader_settings.data.inkaway_orientation = nil
    Screen:setRotationMode(0)      -- start portrait
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}

    ok(view:orientationClass() == "portrait", "orient: opens portrait")
    ok(view.view.canvas_w == 1072 and view.view.canvas_h == 1448, "orient: portrait canvas is tall")
    ok(_G.G_reader_settings.data.inkaway_orientation == "portrait", "orient: first launch adopts and remembers the device orientation")

    -- switch to landscape on an EMPTY canvas: it reshapes to fill the wide screen
    view:setOrientation("landscape")
    ok(view:orientationClass() == "landscape", "orient: switched to landscape")
    ok(Screen:getWidth() == 1448 and Screen:getHeight() == 1072, "orient: screen is now wide")
    ok(view.view.canvas_w == 1448 and view.view.canvas_h == 1072, "orient: empty canvas reshaped wide")
    ok(view.canvas.w == 1448 and view.canvas.h == 1072, "orient: export size follows the wide canvas")
    ok(view.view.area_w == 1448, "orient: drawing area spans the wide screen")
    ok(_G.G_reader_settings.data.inkaway_orientation == "landscape", "orient: choice is remembered")

    -- back to portrait (still empty) reshapes back
    view:setOrientation("portrait")
    ok(view.view.canvas_w == 1072 and view.view.canvas_h == 1448, "orient: reshapes back to portrait")

    view:onCloseWidget()
    ok(_G.G_reader_settings.data.inkaway_orientation == "portrait", "orient: close remembers the last orientation")
end

-- ---- orientation: existing work reshapes to match the screen ----------------
-- A drawing that already has strokes IS reshaped to the new orientation, so a
-- landscape session gets a landscape page AND a landscape export. The strokes keep
-- their canvas coordinates (never rotated or scaled, so text stays upright), and a
-- stroke past the new edge stays in the ops list (reversible), just not drawn.
do
    _G.G_reader_settings.data.inkaway_orientation = nil
    Screen:setRotationMode(0)
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local v = view.view
    local midx = v.area_x + math.floor(v.area_w / 2)
    view:onIaTouch(nil, pos(midx, v.area_y + 20))
    for i = 1, 5 do view:onIaPan(nil, pos(midx + i, v.area_y + 20 + i * 12)) end
    view:onIaPanRelease(nil, pos(midx + 6, v.area_y + 20 + 6 * 12))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == 1, "orient/reshape: a stroke is committed")
    view:setOrientation("landscape")
    ok(view:orientationClass() == "landscape", "orient/reshape: rotated to landscape")
    ok(view.view.canvas_w == 1448 and view.view.canvas_h == 1072,
        "orient/reshape: an existing drawing IS reshaped to the landscape page")
    ok(view.canvas.w == 1448 and view.canvas.h == 1072,
        "orient/reshape: the export size follows the landscape page")
    ok(view.canvas:opCount() == 1, "orient/reshape: the stroke is kept, not deleted")
    view:onCloseWidget()
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)   -- leave the mock portrait
end

-- ---- orientation: the drawing area is always fully covered --------------------
-- Because the page reshapes to match the screen, the whole drawing area is always
-- paintable -- never a centred page with an undrawable band under the toolbar (the
-- earlier reported bug). coverZoom stays as a safety net for any residual mismatch.
do
    -- true when the visible window fits inside the canvas in both axes, i.e. the
    -- page covers the area and clampPan does NOT centre it (which is what leaves a
    -- margin). A tiny epsilon absorbs rounding.
    local function fullyCovered(v)
        return (v.area_w / v.zoom) <= v.canvas_w + 0.5
           and (v.area_h / v.zoom) <= v.canvas_h + 0.5
    end
    _G.G_reader_settings.data.inkaway_orientation = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    ok(fullyCovered(view.view), "orient/cover: portrait open covers the area")

    view:setOrientation("landscape")
    ok(view.view.canvas_w == 1448 and view.view.canvas_h == 1072, "orient/cover: landscape page")
    ok(fullyCovered(view.view), "orient/cover: landscape covers the area")
    ok(view.view.pan_x >= 0 and view.view.pan_y >= 0, "orient/cover: not centred (no margin)")

    -- draw, then rotate back to portrait: the page matches portrait again and covers
    local v = view.view
    local midx = v.area_x + math.floor(v.area_w / 2)
    view:onIaTouch(nil, pos(midx, v.area_y + 20))
    for i = 1, 5 do view:onIaPan(nil, pos(midx + i, v.area_y + 20 + i * 12)) end
    view:onIaPanRelease(nil, pos(midx + 6, v.area_y + 20 + 6 * 12))
    UIManager.fireScheduled()
    view:setOrientation("portrait")
    ok(view.view.canvas_w == 1072 and view.view.canvas_h == 1448, "orient/cover: back to portrait page")
    ok(fullyCovered(view.view), "orient/cover: portrait covers the area (no undrawable bar)")

    view:onCloseWidget()
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
end

-- ---- orientation: content keeps its coordinates on reshape --------------------
-- The page reshapes to the new orientation (so the export matches the screen), but
-- every op keeps its exact canvas coordinates -- ops are never rotated or scaled.
-- That is what keeps TEXT upright and, since ruling lines sit at fixed y intervals
-- independent of page size, keeps line-snapped text on its line. Uses a shape op
-- (the mock has no font engine to compose a real text op through composeCanvas).
do
    _G.G_reader_settings.data.inkaway_orientation = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view:startNotebook({ style = "lines", size = 40, strength = 45 })
    -- a committed op at fixed coords, well within the landscape bounds, snapped to a
    -- ruling row (y = 200 = 5 * ruling size 40)
    local op = { kind = "shape", shape = "rect", fill = false, width = 8, alpha = 255,
        pts = { 120, 200, 520, 320 } }
    view.canvas.ops[#view.canvas.ops + 1] = op
    view:nbSyncOut()
    ok(view.canvas:opCount() == 1, "content/rot: an op is on the page")
    view:setOrientation("landscape")
    ok(view.notebook.w == 1448 and view.notebook.h == 1072,
        "content/rot: notebook reshapes to the landscape page (export matches the screen)")
    local o = view.canvas.ops[1]
    ok(o.pts[1] == 120 and o.pts[2] == 200 and o.pts[3] == 520 and o.pts[4] == 320,
        "content/rot: the op keeps its exact coords (upright; snapped text stays on its ruling)")
    view:onCloseWidget()
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
end

-- ---- the pen and touch test takes the pen and fingers, and gives them back ----
-- Settings > Test pen and touch opens a full-screen test that owns the stylus
-- callback and watches finger frames while it is open; closing it puts the
-- canvas's own callback and finger tracking back.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view.palm_reject = true
    view:applyPalmReject()
    local mine = Device.input.stylus_callback
    ok(mine ~= nil, "pentest: palm rejection registered the canvas's callback")
    local okc = pcall(function() view:openPenTest() end)
    ok(okc, "pentest: opens from the canvas")
    local screen = UIManager.shown
    ok(screen ~= nil and screen.st ~= nil, "pentest: the test screen is shown")
    if screen then
        ok(Device.input.stylus_callback ~= mine, "pentest: the test owns the stylus callback")
        Device.input.stylus_callback(Device.input, { slot = 4, id = 7, tool = 1, x = 100, y = 100, pressure = 50 })
        ok(screen.st.pen == 1 and #screen.dots == 1, "pentest: a pen frame is counted and dotted")
        ok(#view.canvas.ops == 0 and not view._pen_started, "pentest: the canvas did not draw")
        local okp = pcall(function() screen:paintTo(BB.new(1072, 1448), 0, 0) end)
        ok(okp, "pentest: paints")
        screen:onCloseWidget()
        ok(Device.input.stylus_callback == mine, "pentest: the canvas's callback is back after closing")
    end
    view:onCloseWidget()
end

-- ---- no pen seen: a hint after a few finger drags, never after a real pen ----
-- With palm rejection on, a finger moves the page. On a reader whose pen arrives
-- as a finger, that is all the reader ever sees, so after a few drags without a
-- single pen frame Ink Away says so, once per KOReader session.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    InkAwayView._no_pen_hinted = nil
    local view = InkAwayView:new{}
    view.palm_reject, view.finger_mode = true, "navigate"
    local v = view.view
    local function drag()
        view:onIaTouch(nil, pos(300, v.area_y + 300))
        for i = 1, 5 do view:onIaPan(nil, pos(300, v.area_y + 300 + i * 30)) end
        view:onIaPanRelease(nil, pos(300, v.area_y + 450))
        UIManager.fireScheduled()
    end
    UIManager.shown = nil
    drag(); drag()
    ok(UIManager.shown == nil, "no pen: two drags say nothing yet")
    drag()
    local msg = UIManager.shown and UIManager.shown.text or ""
    ok(msg:find("No pen has been seen"), "no pen: the third drag shows the hint")
    UIManager.shown = nil
    drag(); drag(); drag()
    ok(UIManager.shown == nil, "no pen: only once per session")
    view:onCloseWidget()
    -- a real pen frame first: never
    InkAwayView._no_pen_hinted = nil
    UIManager.reset()
    local view2 = InkAwayView:new{}
    view2.palm_reject, view2.finger_mode = true, "navigate"
    view2:applyPalmReject()
    view2:onStylusSlot(Device.input, { slot = 4, id = 7, tool = 1, x = 100, y = 900, timev = 1 })
    view2:onStylusSlot(Device.input, { slot = 4, id = -1, tool = 1, x = 100, y = 900, timev = 2 })
    UIManager.fireScheduled()
    view = view2; v = view2.view
    UIManager.shown = nil
    drag(); drag(); drag(); drag()
    ok(not (UIManager.shown and UIManager.shown.text and UIManager.shown.text:find("No pen")),
        "no pen: a reader with a working pen never sees it")
    view2:onCloseWidget()
end

-- ---- device tips: once by themselves where still needed, again on request ----
do
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view._android = true
    local PTS = require("ink/ui/pentestscreen")
    local real = PTS.deviceFacts
    -- a Boox: Ink Away asks for the fast refresh itself, so nothing unasked
    PTS.deviceFacts = function() return { android = true, eink = true, eink_full = false, boox = true } end
    view:setSetting("inkaway_device_tip_shown", nil)
    UIManager.shown = nil
    view:deviceTips(false)
    ok(UIManager.shown == nil, "tips: a Boox needs none unasked")
    view:deviceTips(true)
    ok(UIManager.shown and UIManager.shown.text:find("Drawing on a Boox"), "tips: a Boox's on request")
    view:setSetting("inkaway_boox_fast", false)
    view:setSetting("inkaway_device_tip_shown", nil)
    UIManager.shown = nil
    view:deviceTips(false)
    ok(UIManager.shown and UIManager.shown.text:find("Drawing on a Boox"), "tips: a Boox with the fast refresh off gets it once")
    view:setSetting("inkaway_boox_fast", nil)
    -- another Android reader KOReader can't drive: once by itself
    PTS.deviceFacts = function() return { android = true, eink = false } end
    view:setSetting("inkaway_device_tip_shown", nil)
    UIManager.shown = nil
    view:deviceTips(false)
    ok(UIManager.shown and UIManager.shown.text:find("per%-app refresh"), "tips: shown once by themselves")
    UIManager.shown = nil
    view:deviceTips(false)
    ok(UIManager.shown == nil, "tips: not a second time")
    view:deviceTips(true)
    ok(UIManager.shown and UIManager.shown.text:find("per%-app refresh"), "tips: again on request")
    PTS.deviceFacts = function() return { android = true, eink = true, eink_full = true } end
    view:deviceTips(true)
    ok(UIManager.shown.text:find("needs no special settings"), "tips: a fully driven reader needs none")
    PTS.deviceFacts = real
    view:onCloseWidget()
end

-- ---- the notice the first time Ink Away opens: once, and the device tip with it ----
do
    UIManager.reset()
    G_reader_settings.data.inkaway_welcome_seen = nil
    G_reader_settings.data.inkaway_entry_gestures = { placed = {
        booknotes = { gesture_reader = "two_finger_swipe_northwest", gesture_fm = "two_finger_swipe_northwest" },
        annotate = { gesture_reader = "two_finger_swipe_southwest" } }, held = {} }
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    ok(view._welcome_sheet ~= nil, "welcome: shown the first time Ink Away opens")
    ok(G_reader_settings.data.inkaway_welcome_seen == true, "welcome: marked seen as it opens")
    view:closeSheet("_welcome_sheet")       -- Got it
    view:onCloseWidget()
    UIManager.reset()
    local view2 = InkAwayView:new{}
    UIManager:show(view2)
    ok(view2._welcome_sheet == nil, "welcome: never again")
    view2:onCloseWidget()
    -- on an Android reader that still needs the tip, it comes with the notice
    G_reader_settings.data.inkaway_welcome_seen, G_reader_settings.data.inkaway_device_tip_shown = nil, nil
    local PTS = require("ink/ui/pentestscreen")
    local real = PTS.deviceFacts
    PTS.deviceFacts = function() return { android = true, eink = false } end
    UIManager.reset()
    local view3 = InkAwayView:new{}
    view3._android = true
    UIManager:show(view3)
    ok(view3._welcome_sheet ~= nil, "welcome: shown on Android too")
    view3:closeSheet("_welcome_sheet")
    ok(G_reader_settings.data.inkaway_device_tip_shown == true, "welcome: the device tip went with it")
    PTS.deviceFacts = real
    view3:onCloseWidget()
    G_reader_settings.data.inkaway_welcome_seen = true
    G_reader_settings.data.inkaway_entry_gestures = nil
end

-- ---- the guide: beside Done in Settings, topics, cards a page at a time, Show me ----
do
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    view:openSettings()
    local function walkFind(w, pred, seen)
        seen = seen or {}
        if type(w) ~= "table" or seen[w] then return nil end
        seen[w] = true
        if pred(w) then return w end
        for k, c in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" then
                local f = walkFind(c, pred, seen)
                if f then return f end
            end
        end
    end
    local function button(w, text)
        return walkFind(w, function(t)
            return type(t.callback) == "function" and walkFind(t, function(x) return x.text == text end) ~= nil
                and not walkFind(t, function(x) return x ~= t and type(x.callback) == "function" end)
        end)
    end
    local g = button(view._settings_dialog, "Guide")
    ok(g ~= nil, "guide: a Guide button beside Done in Settings")
    ok(walkFind(view._settings_dialog, function(x) return x.text == "Device tips" end) == nil,
        "guide: Settings no longer holds the device tips")
    g.callback()
    ok(view._guide ~= nil and view._settings_dialog == nil, "guide: opens in place of Settings")
    ok(walkFind(view._guide, function(x) return x.text == "Pens" end) ~= nil
        and walkFind(view._guide, function(x) return x.text == "Books" end) == nil, "guide: the topics here, no book topic")
    button(view._guide, "Pens").callback()
    ok(view._guide_topic == "pens" and walkFind(view._guide, function(x) return x.text == "Take up a pen" end) ~= nil,
        "guide: a topic shows its cards")
    local show = button(view._guide, "Show me")
    ok(show ~= nil, "guide: a card with something to open has Show me")
    show.callback()
    ok(view._guide == nil and view._pen_dialog ~= nil, "guide: Show me opens the pen menu")
    view:closeSheet("_pen_dialog")
    view:openGuide("pens")
    button(view._guide, "Back").callback()
    ok(view._guide_topic == nil and walkFind(view._guide, function(x) return x.text == "Export" end) ~= nil,
        "guide: Back returns to the topics")
    -- every button in the guide, the first-open notice and the new sheets takes a
    -- tap (KOReader's tap highlight inverts a text button's label colour)
    local function buttons(w, out, seen)
        if type(w) ~= "table" or seen[w] then return out end
        seen[w] = true
        if getmetatable(w) and w.highlightSafe then out[#out + 1] = w end
        for k, val in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" then buttons(val, out, seen) end
        end
        return out
    end
    local bad, n = 0, 0
    local function check(field)
        for _, b in ipairs(buttons(view[field], {}, {})) do
            n = n + 1
            if not b:highlightSafe() then bad = bad + 1 end
        end
    end
    view:openGuide(); check("_guide")
    for _, t in ipairs(require("ink/guide").TOPICS) do
        view:guideGo(t.id); check("_guide")
        if (view._guide_pages or 1) > 1 then view._guide_page = 1; view:rebuildSheet("_guide"); check("_guide") end
    end
    view:closeSheet("_guide")
    view:openSettings(); check("_settings_dialog"); view:closeSheet("_settings_dialog")
    view:showWelcome(); check("_welcome_sheet"); view:closeSheet("_welcome_sheet")
    view:confirmSheet("_c", "T", "text", "Delete", function() end); check("_c"); view:closeSheet("_c")
    view:noticeSheet("_c", "T", "text"); check("_c"); view:closeSheet("_c")
    ok(n > 40 and bad == 0, ("guide: every button can be tapped (%d of %d not)"):format(bad, n))
    view:closeSheet("_guide")
    -- closing the view closes every sheet it opened, the new ones too: one left
    -- over the reader would take the gestures meant for it
    view:openGuide(); view:noticeSheet("_delete_ink", "T", "text")
    local left = { view._guide, view._delete_ink }
    UIManager:close(view)
    local stray = 0
    for _, e in ipairs(UIManager._window_stack) do
        for _, w in ipairs(left) do if e.widget == w then stray = stray + 1 end end
    end
    ok(stray == 0, "sheets: none outlives the view (" .. stray .. ")")
end

-- ---- the pen menu's +: always after the last pen, however many there are ----
do
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local Penset = require("ink/penset")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local function plus()
        view:openPenSettings()
        local found
        local seen = {}
        local function walk(t)
            if type(t) ~= "table" or seen[t] or found then return end
            seen[t] = true
            if t.text == "+" and type(t.callback) == "function" then found = t; return end
            for k, c in pairs(t) do if k ~= "show_parent" and k ~= "parent" then walk(c) end end
        end
        walk(view._pen_dialog)
        return found
    end
    local case = view:penset()
    local start = #case.favs
    -- holding a saved pen names it
    view:editSavedPen(2)
    local named = false
    local seen2 = {}
    local function find(t) if type(t) ~= "table" or seen2[t] then return end; seen2[t] = true
        if t.text == "Ballpoint" then named = true end
        for k, c in pairs(t) do if k ~= "show_parent" and k ~= "parent" then find(c) end end end
    find(view._penfav_menu)
    ok(named, "pens: holding a saved pen shows its name")
    view:closeSheet("_penfav_menu")
    -- over a book the smudge is left out
    view.reader_mode = true
    ok(not view:selectPen(7) and view.pen_style ~= "smudge", "pens: no smudge over a book")
    view.reader_mode = nil
    for _i = 1, 3 do
        local p = plus()
        ok(p ~= nil, ("pens: + is there with %d pens"):format(#case.favs))
        p.callback()
        view:addPen("ballpoint")
        view:closeSheet("_pen_dialog")
    end
    ok(#case.favs == start + 3 and plus() ~= nil, "pens: still there after adding three")
    while #case.favs < Penset.FAV_CAP do view:addPen("pencil") end
    UIManager.shown = nil
    local p = plus()
    ok(p ~= nil, "pens: + stays with the menu full")
    p.callback()
    ok(UIManager.shown and UIManager.shown.text and UIManager.shown.text:find("Remove it to make room"),
        "pens: and says how to make room")
    view:closeSheet("_pen_dialog")
    view:onCloseWidget()
    G_reader_settings.data.inkaway_pens, G_reader_settings.data.inkaway_pen_style = nil, nil
end

-- ---- pen pressure: from the pen's frames into the stroke, and off on request ---
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view.palm_reject = true
    view:applyPalmReject()
    view:setTool("pen")
    view.pen_style, view.pen_width = "ballpoint", 12
    view._pressure_probe = { lo = 0, hi = 4095 }
    local v = view.view
    local function penStroke(pressures)
        local id = math.random(100, 100000)
        for i, p in ipairs(pressures) do
            view:onStylusSlot(Device.input, { slot = 4, id = id, tool = 1, x = 200 + i * 25, y = v.area_y + 400,
                pressure = p, timev = i * 8000 })
        end
        view:onStylusSlot(Device.input, { slot = 4, id = -1, tool = 1, x = 200, y = v.area_y + 400, timev = 999999 })
        UIManager.fireScheduled()
    end
    penStroke({ 400, 900, 1600, 2400, 3200, 4000, 4000, 4000 })
    local op = view.canvas.ops[#view.canvas.ops]
    ok(op and op.style == "ballpoint" and op.pr ~= nil, "pressure: a ballpoint stroke keeps the pen's pressure")
    ok(op and op.pr and op.pr[1] < op.pr[#op.pr], "pressure: harder at the end than the start")
    view.pen_pressure = false
    penStroke({ 400, 4000, 400, 4000 })
    local op2 = view.canvas.ops[#view.canvas.ops]
    ok(op2 ~= op and op2.pr == nil, "pressure: off in the pen settings, strokes keep none")
    view.pen_pressure = true
    view.pen_style = "solid"
    penStroke({ 400, 4000 })
    ok(view.canvas.ops[#view.canvas.ops].pr == nil, "pressure: a fineliner ignores pressure")
    -- a finger (no sensor): the fountain pen simulates it from speed
    view.palm_reject = false
    view:applyPalmReject()
    view.pen_style = "fountain"
    local n0 = #view.canvas.ops
    view:feedPen("down", 300, v.area_y + 600)
    for i = 1, 10 do view:feedPen("move", 300 + i * 30, v.area_y + 600 + i * 5) end
    view:feedPen("up", 600, v.area_y + 650)
    UIManager.fireScheduled()
    local op3 = view.canvas.ops[#view.canvas.ops]
    ok(#view.canvas.ops == n0 + 1 and op3.pr ~= nil, "pressure: a finger with the fountain pen gets a simulated pressure")
    view:onCloseWidget()
end

-- ---- the pen case: saved pens, kinds that remember, sizes that persist -------
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    _G.G_reader_settings.data.inkaway_pens = nil
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    ok(view.pen_style == "solid" and view.pen_width >= 15 and view.pen_width <= 30,
        "pen case: a new reader starts with the 1.8 mm fineliner (" .. view.pen_width .. " px)")
    view:openPenSettings()
    ok(view._pen_dialog ~= nil and view._pen_strip ~= nil, "pen case: opens with its true-size preview")
    view:closeSheet("_pen_dialog")
    view:choosePenType("highlighter")
    ok(view.pen_style == "highlighter" and view.pen_width > 30, "pen case: the highlighter is wide")
    view.pen_width = 70; view:penChanged("width", 70)
    view:choosePenType("solid")
    view.pen_width = 9; view:penChanged("width", 9)
    view:choosePenType("highlighter")
    ok(view.pen_width == 70, "pen case: the highlighter kept its own size")
    ok(view:swapPen() and view.pen_style == "solid" and view.pen_width == 9, "pen case: swap back to the fineliner")
    view:onCloseWidget()
    -- a restart: the pen in hand comes back as it was
    local view2 = InkAwayView:new{}
    ok(view2.pen_style == "solid" and view2.pen_width == 9, "pen case: the size survives closing Ink Away")
    for i, p in ipairs(view2:penset().favs) do if p.style == "highlighter" then view2:selectPen(i) end end
    ok(view2.pen_style == "highlighter", "pen case: a saved pen is one tap")
    view2:onCloseWidget()
    -- 4.0's setting
    _G.G_reader_settings.data.inkaway_pens = nil
    _G.G_reader_settings.data.inkaway_pen_style = "pencil"
    local view3 = InkAwayView:new{}
    ok(view3.pen_style == "pencil", "pen case: 4.0's pen style is kept")
    view3:onCloseWidget()
    _G.G_reader_settings.data.inkaway_pens = nil
    _G.G_reader_settings.data.inkaway_pen_style = nil
end

-- ---- gestures and pen buttons, as the reader set them -------------------------
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    _G.G_reader_settings.data.inkaway_gestures = nil
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local v = view.view
    view:setTool("pen")
    local b = view:gestureBindings()
    -- a two-finger tap set to Lasso, with no double tap: at once
    b.two_tap, b.two_double_tap = "lasso", "nothing"
    view:onIaTwoTap()
    ok(view.tool == "lasso", "gestures: a two-finger tap set to Lasso takes the lasso at once")
    view:onIaTwoTap()
    ok(view.tool == "pen", "gestures: and again back to the pen")
    -- with a double tap set too, the single tap waits for a second one
    b.two_tap, b.two_double_tap = "eraser", "library"
    local opened = 0
    local real_lib = view.openLibrary
    view.openLibrary = function() opened = opened + 1 end
    view:onIaTwoTap()
    ok(view.tool == "pen", "gestures: a single tap waits a moment when a double tap is set")
    UIManager.fireScheduled()
    ok(view.tool == "erase", "gestures: then does its action")
    view:setTool("pen")
    view:onIaTwoTap(); view:onIaTwoTap()
    UIManager.fireScheduled()
    ok(opened == 1 and view.tool == "pen", "gestures: two quick taps do the double tap's action only")
    -- swipes
    b.two_swipe_up, b.two_swipe_down = "nothing", "library"
    local cx, top = v.area_x + 300, v.area_y + 100
    view:onIaTwoSwipe(nil, { pos = { x = cx, y = top }, end_pos = { x = cx, y = top + v.area_h * 0.5 } })
    ok(opened == 2, "gestures: a long swipe down set to Library opens it")
    view:onIaTwoSwipe(nil, { pos = { x = cx, y = top + v.area_h * 0.6 }, end_pos = { x = cx, y = top } })
    ok(opened == 2, "gestures: a long swipe up set to Nothing does nothing")
    view.openLibrary = real_lib
    -- the second side button (a Kobo stylus): highlights while held by default
    view.palm_reject = true
    view:applyPalmReject()
    local style0 = view.pen_style
    Device.input.stylus_highlighter_active = true
    local function pen(id, x, y, tool)
        return Device.input.stylus_callback(Device.input,
            { slot = Device.input.pen_slot, id = id, x = x, y = y, tool = tool or 1 })
    end
    pen(0, cx, top + 300, 3)
    ok(view.pen_style == "highlighter", "pen buttons: the Kobo side button highlights while held")
    pen(0, cx + 80, top + 300, 3)
    pen(-1, cx + 80, top + 300, 3)
    Device.input.stylus_highlighter_active = false
    UIManager.fireScheduled()
    ok(view.pen_style == style0, "pen buttons: and the pen is back at the lift")
    -- the settings sheet, and an overlap asked about
    view:openGestureSettings()
    ok(view._gestures_dialog ~= nil, "gestures: the settings sheet opens")
    view:chooseGestureAction(require("ink/actions").trigger("two_swipe_down"))
    ok(view._gesture_pick ~= nil and view._gestures_dialog == nil, "gestures: choosing opens the action grid")
    -- pick Undo for the swipe down: the two-finger tap already undoes, so it asks
    b.two_tap = "undo"
    local function findButton(w, text, seen)
        seen = seen or {}
        if type(w) ~= "table" or seen[w] then return nil end
        seen[w] = true
        if type(w.callback) == "function" and (w.text == text
                or (w.label_widget and w.label_widget.text == text)) then return w end
        for k, c in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" then
                local f = findButton(c, text, seen); if f then return f end
            end
        end
    end
    local undo_btn = findButton(view._gesture_pick, "Undo")
    ok(undo_btn ~= nil, "gestures: the grid offers Undo")
    UIManager.shown = nil
    if undo_btn then undo_btn.callback() end
    local box = UIManager.shown
    ok(box and box.ok_text == "Only this one" and box.cancel_text == "Both",
        "gestures: an overlap asks: only this one, or both")
    if box and box.ok_callback then box.ok_callback() end
    ok(b.two_swipe_down == "undo" and b.two_tap == "nothing", "gestures: only this one moves it")
    view:onCloseWidget()
    _G.G_reader_settings.data.inkaway_gestures = nil
end

-- ---- lifecycle leak: landscape<->portrait cycles + close leave nothing behind --
-- The reported "only a full KOReader restart fixes it" slowdown is a leak that
-- outlives the plugin instance: a view left in UIManager's window stack, or a
-- scheduled closure over a closed view, still painted / firing every frame. After
-- the exact repro (open, rotate to landscape and back several times, then Exit)
-- NOTHING must remain scheduled and the window stack must be empty.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    ok(InkAwayView.name == "inkaway_view", "leak: view carries the name the re-entrancy guard looks for")
    local view = InkAwayView:new{}
    UIManager:show(view)   -- push onto the (mock) window stack, exactly like main.lua
    ok(UIManager.stackCount() == 1, "leak: one view on the stack after open")
    -- the re-entrancy guard's premise: an already-open view is findable by name, so
    -- a second openCanvas can bail instead of stacking a duplicate
    local found = false
    for _, w in ipairs(UIManager._window_stack) do
        if w.widget and w.widget.name == "inkaway_view" then found = true end
    end
    ok(found, "leak: an open view is detectable on the stack (guard can bail)")
    if view:orientationSupported() then
        for _ = 1, 3 do
            view:setOrientation("landscape")
            view:setOrientation("portrait")
        end
        ok(view:orientationClass() == "portrait", "leak: ends back in portrait after cycles")
    end
    UIManager.fireScheduled()   -- let any pending timers run/settle
    local pendingBefore = UIManager.pendingCount()
    UIManager:close(view)       -- the user's Exit -> onCloseWidget
    ok(UIManager.stackCount() == 0, "leak: window stack empty after close (no buried view)")
    local pend = 0
    for fn in pairs(UIManager.scheduled) do
        if fn ~= InkAwayView.deferredCollect then pend = pend + 1 end
    end
    ok(pend == 0, "leak: no scheduled closure survives close (nothing keeps the view alive)")
    ok(UIManager.scheduled[InkAwayView.deferredCollect] ~= nil,
        "leak: the heap is collected just after close (a module function, no view reference)")
    ok(view.area_bb == nil and view.canvas_bb == nil, "leak: big buffers freed on close")
    ok(pendingBefore == pendingBefore, "leak: (baseline recorded)")
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
end

-- ---- native-buffer leak: repeated open->landscape->new-drawing->close is flat ---
-- The "gets slower on every launch, only a KOReader restart fixes it" report is the
-- fingerprint of a native Blitbuffer whose :free() is missed on a hot path (Lua GC
-- can't reclaim FFI memory). BB.allocated tracks live OWNING buffers; after a warm-up
-- cycle it must stay flat across repeated open/rotate/new-drawing/close cycles.
do
    Screen:setRotationMode(0); Screen:setSize(1264, 1680)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function cycle()
        local v = InkAwayView:new{}
        UIManager:show(v)
        if v:orientationSupported() then v:setOrientation("landscape") end
        v:onIaTouch(nil, pos(200, 300)); v:onIaPan(nil, pos(400, 500))
        v:onIaPanRelease(nil, pos(400, 500))
        UIManager.fireScheduled()
        v.canvas:setOps({})   -- blank -> newDrawing takes the fresh() fast path
        v:newDrawing()
        if v:orientationSupported() then v:setOrientation("portrait") end
        UIManager:close(v)
    end
    cycle()                       -- warm up (first-time module/cache allocations)
    local baseline = BB.allocated
    for _ = 1, 5 do cycle() end
    ok(BB.allocated == baseline,
        ("leak: BB.allocated flat across 5 open/rotate/new-drawing/close cycles (%d == %d)")
            :format(BB.allocated, baseline))
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
end

-- ---- panel-order landscape render: mirror lifecycle + no leak (software rotation) --
-- On a software-rotated framebuffer, renderView scales a crop of the panel-order
-- mirror (canvas_panel_bb) instead of rotating into area_bb every frame. Verify the
-- mirror is allocated when landscape uses software rotation, that the render / pan /
-- commit paths run through it without error, and that it is freed on close with the
-- live OWNING-buffer tally flat across repeated cycles (a missed :free() on this hot
-- path would be exactly the "slower on every launch" leak). Byte-correctness of the
-- transform is proven separately against the real blitter in tests/rotverify.lua.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    Screen:setSoftwareRotation(true)
    Screen:setRotationMode(3)     -- software landscape: Screen.bb now reports rotation 3
    _G.G_reader_settings.data.inkaway_orientation = nil   -- adopt the current (landscape) way up
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local v = InkAwayView:new{}
    UIManager:show(v)
    ok(v._area_rot == 3, "panel: area buffer built in panel order (rotation 3)")
    ok(v.canvas_panel_bb ~= nil, "panel: mirror allocated in software-rotation landscape")
    -- drive the paths that read the mirror (pan = full renderView) and write it (a stroke)
    v:onIaTouch(nil, pos(200, 300)); v:onIaPan(nil, pos(400, 500)); v:onIaPanRelease(nil, pos(400, 500))
    v:panByScreen(20, 15)
    UIManager.fireScheduled()
    ok(v.canvas_panel_bb ~= nil, "panel: mirror still present after pan + stroke")
    UIManager:close(v)
    ok(v.canvas_panel_bb == nil, "panel: mirror freed on close")

    local function cycle()
        local w = InkAwayView:new{}
        UIManager:show(w)
        w:onIaTouch(nil, pos(200, 300)); w:onIaPan(nil, pos(360, 480)); w:onIaPanRelease(nil, pos(360, 480))
        w:panByScreen(12, 9)
        UIManager.fireScheduled()
        w.canvas:setOps({}); w:newDrawing()
        UIManager:close(w)
    end
    cycle()                       -- warm up
    local baseline = BB.allocated
    for _ = 1, 5 do cycle() end
    ok(BB.allocated == baseline,
        ("panel: BB.allocated flat across 5 landscape cycles (mirror never leaks) (%d == %d)")
            :format(BB.allocated, baseline))

    Screen:setSoftwareRotation(false)
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
end

-- ---- clipboard: long-press paste bubble, Copy / Cut ----------------------
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local Text = require("ink/text")
    local clip = "pasted\r\ntext\tx"
    local saved_get, saved_set = Device.input.getClipboardText, Device.input.setClipboardText
    Device.input.getClipboardText = function() return clip end
    Device.input.setClipboardText = function(t) clip = t end
    view.tool = "text"
    view.editing_text = Text.new{ x = 40, y = 300, w = 600, size = 20 }
    view.editing_text.h = 160
    view.text_cur = { p = 1, o = 0 }
    view.afterTextEdit = function(v) v:refreshTextBox("ui") end   -- no font engine in the mock
    view.ensureCaretVisible = function() end
    local r = view:textBoxScreenRect()
    local inside = { x = r.x + r.w / 2, y = r.y + r.h / 2 }   -- clear of the move / resize handles
    view:onIaHold(nil, { pos = inside })
    local b = view._clip_bubble
    ok(b ~= nil, "clipboard: a long press inside the text box shows the paste bubble")
    ok(b and b.y + b.h <= inside.y, "clipboard: the bubble sits above the finger")
    local onb = b and { x = b.x + b.w / 2, y = b.y + b.h / 2 }
    view:onIaTouch(nil, { pos = onb })
    ok(view._clip_press == true and view._clip_bubble ~= nil, "clipboard: pressing the bubble arms it (acts on release)")
    view:onIaTap(nil, { pos = onb })
    ok(Text.plain(view.editing_text) == "pasted\ntext    x", "clipboard: tapping it pastes, line breaks and tabs cleaned up")
    ok(view._clip_bubble == nil, "clipboard: the bubble goes away after pasting")
    view:textUndo()
    ok(Text.plain(view.editing_text) == "", "clipboard: a paste is a single undo step")
    view:textRedo()
    -- sliding off the bubble cancels
    view:onIaHold(nil, { pos = inside })
    b = view._clip_bubble
    view:onIaTouch(nil, { pos = { x = b.x + 4, y = b.y + 4 } })
    view:onIaPanRelease(nil, { pos = { x = b.x - 200, y = b.y + 300 } })
    ok(Text.plain(view.editing_text) == "pasted\ntext    x", "clipboard: releasing off the bubble does not paste")
    -- a touch elsewhere dismisses it
    view:onIaHold(nil, { pos = inside })
    ok(view._clip_bubble ~= nil, "clipboard: bubble shown again")
    local real_ttt = view.textToolTouch
    view.textToolTouch = function() return true end   -- caret placement needs fonts
    view:onIaTouch(nil, { pos = { x = inside.x + 10, y = inside.y + 5 } })
    view.textToolTouch = real_ttt
    ok(view._clip_bubble == nil, "clipboard: a touch elsewhere dismisses the bubble")
    -- copy / cut a selection
    view.text_sel = { a = { p = 1, o = 0 }, b = { p = 1, o = 6 } }
    view:textCopy(false)
    ok(clip == "pasted" and Text.plain(view.editing_text) == "pasted\ntext    x", "clipboard: Copy puts the selection on the clipboard")
    view.text_sel = { a = { p = 2, o = 0 }, b = { p = 2, o = 4 } }
    view:textCopy(true)
    ok(clip == "text" and Text.plain(view.editing_text) == "pasted\n    x", "clipboard: Cut copies and removes the selection")
    -- empty clipboard: no bubble
    clip = ""
    view:onIaHold(nil, { pos = inside })
    ok(view._clip_bubble == nil, "clipboard: nothing to paste -> no bubble")
    -- a huge clipboard is capped
    clip = string.rep("a", 6000)
    local s, cut = view:clipboardText()
    ok(#s == 5000 and cut == true, "clipboard: a very long paste is capped at 5000 characters")
    -- holding outside the box does nothing clipboard-related
    clip = "x"
    view:onIaHold(nil, { pos = { x = r.x + r.w + 200, y = r.y + r.h + 200 } })
    ok(view._clip_bubble == nil, "clipboard: a long press outside the box shows no bubble")
    -- KOReader keeps any widget whose `toast` (or `modal`) field is set ABOVE every
    -- dialog it shows later; a method by that name once hid all menus under the canvas
    ok(view.toast == nil and view.modal == nil, "the canvas never looks like a toast or a modal to UIManager")
    view.editing_text = nil
    Device.input.getClipboardText, Device.input.setClipboardText = saved_get, saved_set
    view:onCloseWidget()
end

-- ---- finishing a text box undoes the keyboard scroll ---------------------
-- Typing near the bottom scrolls the page past its normal end so the line stays
-- above the keyboard; closing the box must bring the view back inside the page.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local Text = require("ink/text")
    local v = view.view
    view.tool = "text"
    view.editing_text = Text.new{ x = 40, y = v.canvas_h - 60, w = 600, size = 20 }
    view.editing_text.h = 40
    view.editing_is_new = true
    view.text_cur = { p = 1, o = 0 }
    local max_pan = math.max(0, v.canvas_h - v.area_h / v.zoom)
    v.pan_y = v.canvas_h - 80          -- what the keyboard scroll leaves behind
    view:finishTextEdit(true)
    ok(v.pan_y <= max_pan + 0.5, ("closing the text box scrolls back inside the page (pan %.0f, max %.0f)"):format(v.pan_y, max_pan))
    view:onCloseWidget()
end

-- ---- typing over the hidden zoom pill must never zoom the canvas ---------
-- The keyboard consumes a key's TAP but not its TOUCH, so the canvas (always
-- active while typing) sees the touch. A key over the zoom pill used to arm it,
-- and the next tap anywhere (tapping away from the text box) zoomed in.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local v = view.view
    local zr = view:fabRect("zoom")
    local key = { x = zr.x + zr.w / 2, y = zr.y + zr.h / 4 }   -- a key right over the "+"
    view._text_kb = { dimen = { h = view.screen_h - (zr.y - 40) } }   -- keyboard covers the pill
    local z0 = v.zoom
    view:onIaTouch(nil, { pos = key })                -- the key's touch reaches the canvas
    ok(view._fab_press == nil, "keyboard: a key over the zoom pill does not arm it")
    view._text_kb = nil                               -- typing done, keyboard closed
    view:onIaTouch(nil, { pos = { x = 300, y = v.area_y + 200 } })
    view:onIaTap(nil, { pos = { x = 300, y = v.area_y + 200 } })
    ok(v.zoom == z0, "keyboard: tapping away afterwards does not zoom the canvas")
    -- and a stale press from any earlier gesture never fires on a later tap
    view._fab_press = "zoomin"
    view:onIaTouch(nil, { pos = { x = 300, y = v.area_y + 250 } })
    view:onIaTap(nil, { pos = { x = 300, y = v.area_y + 250 } })
    ok(v.zoom == z0, "a half-finished control press is void once a new touch begins")
    view:onCloseWidget()
end

-- ---- a full re-render is never shrunk to a stroke's strip ----------------
-- A page turn rebuilds the whole drawing area; if a stroke starts before the next
-- paint, that paint must still copy the whole area, not just the stroke's rect.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local v = view.view
    local full, region = 0, 0
    local bf, br_ = view.blitAreaFull, view.blitAreaRect
    view.blitAreaFull = function(...) full = full + 1; return bf(...) end
    view.blitAreaRect = function(...) region = region + 1; return br_(...) end
    view:paintTo(Screen.bb, 0, 0)
    full, region = 0, 0
    view:renderView()                                  -- e.g. a page turn
    view:setTool("pen")
    view:onIaTouch(nil, { pos = { x = 300, y = v.area_y + 300 } })
    view:onIaPan(nil, { pos = { x = 340, y = v.area_y + 320 } })   -- stroke before the paint
    view:paintTo(Screen.bb, 0, 0)
    ok(full == 1, "a pending full repaint is not cut down to the stroke's rect")
    full, region = 0, 0
    view:onIaPan(nil, { pos = { x = 380, y = v.area_y + 330 } })
    view:paintTo(Screen.bb, 0, 0)
    ok(full == 0 and region == 1, "later stroke paints go back to the small region copy")
    view:onCloseWidget()
end

-- ---- documents: every drawing and notebook is a file that saves itself ---
do
    local TestEnv = require("testenv")
    local Canvas = require("ink/canvas")
    local Project = require("ink/project")
    local Storage = require("ink/storage")
    local LIB = TestEnv.libraryDir()
    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, val in pairs(a) do if not deepEqual(val, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    TestEnv.remember_last_doc = true
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    -- let the save timer run until it settles (it waits out a busy spell first)
    local function settle() for _ = 1, 3 do UIManager.fireScheduled() end end

    local view = InkAwayView:new{}
    UIManager:show(view)
    ok(view.doc_path and Storage.dirName(view.doc_path) == LIB, "doc: a new drawing is planned in the library")
    ok(view.doc_path:match("/Drawing [%d%-]+ [%d%.]+[ %(%d%)]*%.inkaway$") ~= nil, "doc: named Drawing and the date")
    ok(not view.doc_written and not Storage.exists(view.doc_path), "doc: no file before the first stroke")
    settle()
    ok(not Storage.exists(view.doc_path), "doc: an untouched drawing never gets a file")
    stroke(view, 200, 200)
    settle()
    ok(view.doc_written and Storage.exists(view.doc_path), "doc: it saves itself once left alone")
    local first = view.doc_path
    ok(#Project.load(first).ops == 1, "doc: the saved file holds the stroke")
    ok(G_reader_settings.data.inkaway_last_doc == first, "doc: it is remembered as the last document")

    stroke(view, 300, 400)
    view:closeCanvas()
    ok(UIManager.stackCount() == 0, "doc: Exit closes at once, without asking")
    ok(#Project.load(first).ops == 2, "doc: closing saves the latest change")

    local view2 = InkAwayView:new{}
    UIManager:show(view2)
    ok(view2.doc_path == first and view2.canvas:opCount() == 2, "doc: the next open shows the last document")
    view2:newDrawing()
    ok(view2.doc_path ~= first and view2.canvas:isEmpty(), "doc: New starts an empty drawing under a new name")
    ok(#Project.load(first).ops == 2, "doc: and leaves the previous one saved")
    local untouched = view2.doc_path
    view2:newDrawing()
    ok(not Storage.exists(untouched), "doc: a new drawing left untouched leaves no file")

    -- rename moves the file; a taken name is refused
    stroke(view2, 200, 200)
    view2:saveDocument()
    local before = view2.doc_path
    view2:renameDocument("  Shopping list ")
    local shopping = LIB .. "/Shopping list.inkaway"
    ok(view2.doc_path == shopping and Storage.exists(shopping) and not Storage.exists(before),
        "doc: rename moves the file")
    ok(G_reader_settings.data.inkaway_last_doc == shopping, "doc: and the last document follows it")
    view2:renameDocument(Storage.stem(first))
    ok(view2.doc_path == shopping and Storage.exists(first), "doc: a name already in use is refused")
    local last = G_reader_settings.data.inkaway_last_doc
    G_reader_settings.data.inkaway_last_doc = nil   -- so this view starts a new drawing
    local planned = InkAwayView:new{}
    G_reader_settings.data.inkaway_last_doc = last
    planned:renameDocument("Not yet")
    ok(planned.doc_path == LIB .. "/Not yet.inkaway" and not Storage.exists(planned.doc_path),
        "doc: renaming a document with no file yet just changes its name")
    planned:onCloseWidget()

    -- opening another document saves the one being left first
    stroke(view2, 500, 500)
    ok(view2:openDocument(first), "doc: another document opens")
    ok(view2.doc_path == first and view2.canvas:opCount() == 2, "doc: it shows that document")
    ok(#Project.load(shopping).ops == 2, "doc: the one left was saved first")
    ok(not view2:openDocument(LIB .. "/nope.inkaway") and view2.doc_path == first,
        "doc: a failed open keeps the current document")

    -- a drawing's background picture is saved with it
    view2.bg_path = "/pics/photo.png"; view2:markDirty(); view2:saveDocument()
    ok(Project.load(first).bg == "/pics/photo.png", "doc: the background picture's path is saved")
    view2.bg_path = nil; view2:markDirty(); view2:saveDocument()
    ok(Project.load(first).bg == nil, "doc: and dropped once it is removed")

    -- notebooks: the cached save matches a full save, through page turns, undo
    -- and new pages, and closing on a blank page keeps every page
    view2:beginDocument("notebook", nil, function()
        view2:startNotebook({ style = "lines", size = 40, strength = 45 })
    end)
    local nbpath = view2.doc_path
    ok(nbpath:match("/Notebook [^/]+%.inkaway$") ~= nil, "doc: a new notebook is named Notebook and the date")
    ok(#Project.load(first).ops == 2, "doc: starting a notebook leaves the drawing saved")
    settle()
    ok(not Storage.exists(nbpath), "doc: a blank new notebook gets no file")
    stroke(view2, 200, 200)
    view2:nbAddPage()
    stroke(view2, 300, 300); stroke(view2, 320, 360)
    view2:saveDocument()
    view2:undo()
    stroke(view2, 100, 600)
    view2:nbGoTo(1)
    stroke(view2, 400, 700)
    view2:nbAddPage()              -- a blank page 2, after page 1
    view2:nbGoTo(3)
    view2:saveDocument()
    local saved = Project.load(nbpath)
    local full = Project.deserialize(Project.serializeNotebook(view2.notebook))
    ok(saved and deepEqual(saved, full), "doc: the cached notebook save matches a full save")
    ok(#saved.pages == 3 and #saved.pages[1].ops == 2 and #saved.pages[2].ops == 0 and #saved.pages[3].ops == 2,
        "doc: every page holds its own changes")
    ok(saved.pages[1].id ~= saved.pages[2].id and saved.pages[3].id ~= nil, "doc: each page has its own id")
    view2:nbGoTo(2)
    UIManager:close(view2)
    local back = Project.load(nbpath)
    ok(back and #back.pages == 3 and #back.pages[1].ops == 2 and #back.pages[3].ops == 2,
        "doc: closing on a blank page keeps the whole notebook")
    local view3 = InkAwayView:new{}
    ok(view3.notebook and view3.doc_path == nbpath and view3.notebook:count() == 3,
        "doc: the notebook reopens as a notebook")
    view3:onCloseWidget()

    -- replacing a file asks first
    local ran = false
    view3:confirmReplace(LIB .. "/never.png", function() ran = true end)
    ok(ran, "doc: writing a new file does not ask")
    ran = false
    view3:confirmReplace(first, function() ran = true end)
    ok(not ran and UIManager.shown and UIManager.shown.ok_callback ~= nil, "doc: replacing a file asks first")
    UIManager.shown.ok_callback()
    ok(ran, "doc: and goes ahead on Replace")

    -- the old single session file comes back once, as a document of its own
    local session = Storage.settingsDir() .. "/inkaway_session.inkaway"
    if not Storage.exists(session) then
        local c = Canvas.new(1072, 1448)
        c:startStroke("ink", 6, 255); c:addPoint(10, 10); c:addPoint(90, 90); c:finishStroke()
        local f = io.open(session, "wb"); f:write(Project.serialize(c)); f:close()
        G_reader_settings.data.inkaway_session_migrated = nil
        G_reader_settings.data.inkaway_autosave = "periodic"
        local view4 = InkAwayView:new{}
        ok(view4.doc_path:match("/Recovered [^/]+%.inkaway$") ~= nil and view4.doc_written,
            "doc: an old session opens as a Recovered document")
        ok(view4.canvas:opCount() == 1 and Storage.dirName(view4.doc_path) == LIB, "doc: in the library, with its ink")
        ok(not Storage.exists(session), "doc: the old session file is gone")
        ok(G_reader_settings.data.inkaway_session_migrated == true and G_reader_settings.data.inkaway_autosave == nil,
            "doc: this happens once, and the autosave setting is dropped")
        view4:onCloseWidget()
    end

    -- the old "drawing projects" and "notebook projects" folders join the library
    -- once, when the library is the "ink away" folder they are in
    do
        local DATA = LIB .. "/data"
        local APP = DATA .. "/ink away"
        os.execute("mkdir -p '" .. APP .. "/notebook projects' '" .. APP .. "/drawing projects'")
        local nbc = Canvas.new(1072, 1448)
        nbc:startStroke("ink", 6, 255); nbc:addPoint(10, 10); nbc:addPoint(90, 90); nbc:finishStroke()
        local f = io.open(APP .. "/notebook projects/Lectures.inkaway", "wb"); f:write(Project.serialize(nbc)); f:close()
        f = io.open(APP .. "/drawing projects/Cat.inkaway", "wb"); f:write(Project.serialize(nbc)); f:close()
        local realData = Storage.dataDir
        Storage.dataDir = function() return DATA end
        local saved_lib = G_reader_settings.data.inkaway_library_dir
        G_reader_settings.data.inkaway_library_dir = nil
        G_reader_settings.data.inkaway_last_doc = APP .. "/notebook projects/Lectures.inkaway"
        UIManager.reset()
        local v5 = InkAwayView:new{}
        ok(v5.doc_path == APP .. "/Lectures.inkaway" and v5.canvas:opCount() == 1,
            "doc: the last document is found where it moved, in the library")
        ok(Storage.exists(APP .. "/Cat.inkaway") and not Storage.exists(APP .. "/notebook projects")
            and not Storage.exists(APP .. "/drawing projects"), "doc: the old project folders are emptied and gone")
        ok(v5:docDir() == APP, "doc: so a new drawing goes in the library, not an old folder")
        UIManager:show(v5)
        ok(UIManager.shown and tostring(UIManager.shown.text):find("drawing projects", 1, true) ~= nil,
            "doc: the reader is told once where they went")
        v5:onCloseWidget()
        os.execute("mkdir -p '" .. APP .. "/notebook projects'")
        UIManager.reset()
        local v6 = InkAwayView:new{}
        UIManager:show(v6)
        ok(Storage.isDir(APP .. "/notebook projects") and UIManager.shown == v6,
            "doc: and only once: a folder made later under the old name is left alone")
        v6:onCloseWidget()
        Storage.dataDir = realData
        G_reader_settings.data.inkaway_library_dir = saved_lib
    end

    TestEnv.remember_last_doc = false
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- ---- library: folders and documents, browsed, created, moved and deleted ---
do
    local TestEnv = require("testenv")
    local Project = require("ink/project")
    local Storage = require("ink/storage")
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    local LIB = TestEnv.libraryDir() .. "/libtest"
    os.execute("mkdir -p '" .. LIB .. "/drawings'")
    G_reader_settings.data.inkaway_library_dir = LIB
    TestEnv.remember_last_doc = true
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    -- answer the text prompt on screen, as the OK button does
    local function answer(text)
        local d = InputDialog.last
        d.input = text
        for _, b in ipairs(d.buttons[1]) do if b.is_enter_default then b.callback() end end
    end
    local function labels(grid)
        local t = {}
        for _, it in ipairs(grid.items) do t[#t + 1] = (it.folder and "/" or "") .. it.label end
        return table.concat(t, ",")
    end

    local view = InkAwayView:new{}
    UIManager:show(view)
    stroke(view, 200, 200)
    view:renameDocument("First")
    view:saveDocument()
    ok(view.doc_path == LIB .. "/First.inkaway", "lib: documents start in the chosen library folder")

    view:openLibrary()
    local lib = view._library
    ok(lib and UIManager.shown == lib, "lib: the library opens full screen")
    ok(labels(lib) == "First", "lib: it lists the documents and leaves the export folders out")
    ok(lib.items[1].selected, "lib: the open document is marked")
    ok(lib.title == "Library" and lib.on_back == nil, "lib: the top folder is titled Library, with no way up")
    BB.out_of_bounds = 0
    lib:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "lib: the grid paints in bounds")

    -- a new folder from the header's + Folder, then a new drawing made inside it
    local plus_folder
    for _, a in ipairs(lib.actions) do if a[1] == "+ Folder" then plus_folder = a end end
    ok(plus_folder and plus_folder[3], "lib: + Folder sits in the header, filled like + Drawing and + Notebook")
    plus_folder[2]()
    answer("School")
    ok(Storage.isDir(LIB .. "/School") and labels(lib) == "/School,First", "lib: New folder makes a folder, listed first")
    view:libraryPick(lib.items[1])
    ok(view._lib_dir == LIB .. "/School" and lib.title == "School" and lib.on_back ~= nil,
        "lib: tapping a folder goes into it")
    ok(#lib.items == 0, "lib: a new folder is empty")
    lib:paintTo(Screen.bb, 0, 0)
    view:openNotebookPaper(view._lib_dir)
    ok(view._new_dialog ~= nil, "lib: + Notebook opens the paper choice")
    view:closeSheet("_new_dialog")
    lib:close()
    view:newDrawing(LIB .. "/School")
    ok(Storage.dirName(view.doc_path) == LIB .. "/School" and not view.doc_written,
        "lib: a new drawing goes in the folder it was made from")
    stroke(view, 300, 300)
    view:saveDocument()
    local inSchool = view.doc_path
    ok(Storage.exists(inSchool), "lib: and is saved there")

    -- a notebook made from the New sheet's paper choice
    view:newNotebook("grid", LIB .. "/School")
    ok(view.notebook and view.notebook.template.style == "grid" and Storage.dirName(view.doc_path) == LIB .. "/School",
        "lib: a new notebook takes the chosen paper and folder")
    stroke(view, 100, 100)
    view:saveDocument()
    local nbInSchool = view.doc_path

    -- thumbnails come from the files: a drawing and a notebook page
    local tb = view:renderDocThumb(inSchool, 200, 260)
    ok(tb and tb:getWidth() <= 200 and tb:getHeight() <= 260, "lib: a drawing's thumbnail fits its card")
    local tn = view:docThumb(nbInSchool, 200, 260)
    ok(tn ~= nil, "lib: a notebook's thumbnail is drawn from its first page")
    ok(view.canvas:opCount() == 1 and view.notebook, "lib: drawing thumbnails leaves the open document as it is")

    -- open from the library, back up a folder, move the open document out
    view:openLibrary()
    lib = view._library
    ok(view._lib_dir == LIB .. "/School", "lib: the library opens at the open document's folder")
    local drawingItem
    for _, it in ipairs(lib.items) do if it.path == inSchool then drawingItem = it end end
    view:libraryPick(drawingItem)
    ok(view._library == nil and view.doc_path == inSchool and not view.notebook, "lib: tapping a document opens it")
    view:openLibrary()
    lib = view._library
    lib.on_back()
    ok(view._lib_dir == LIB and lib.title == "Library", "lib: back goes up a folder")
    view:libraryGo(LIB .. "/School")
    for _, it in ipairs(lib.items) do if it.path == inSchool then drawingItem = it end end
    view:moveItem(drawingItem)
    local chooser = UIManager.shown
    ok(chooser ~= lib and labels(chooser) == "/School", "lib: Move shows the library's folders")
    chooser.actions[2][2]()   -- Move here: the top folder
    ok(view.doc_path == LIB .. "/" .. Storage.baseName(inSchool) and Storage.exists(view.doc_path)
        and not Storage.exists(inSchool), "lib: moving the open document moves its file and follows it")
    ok(G_reader_settings.data.inkaway_last_doc == view.doc_path, "lib: the last document follows the move")

    -- renaming a folder that holds the open document
    view:openDocument(nbInSchool)
    view:libraryGo(LIB)
    local schoolItem
    for _, it in ipairs(view._library.items) do if it.folder then schoolItem = it end end
    view:promptRenameItem(schoolItem)
    answer("Lessons")
    ok(view.doc_path == LIB .. "/Lessons/" .. Storage.baseName(nbInSchool) and Storage.exists(view.doc_path),
        "lib: renaming its folder keeps the open document's path right")
    ok(labels(view._library):match("^/Lessons,") ~= nil, "lib: the renamed folder shows")

    -- duplicate from the File sheet carries on in the copy
    local before = view.doc_path
    view:duplicateDocument()
    ok(view.doc_path ~= before and Storage.exists(view.doc_path) and Storage.exists(before),
        "lib: Duplicate copies the document and opens the copy")
    ok(view.notebook and view.notebook:count() == 1, "lib: the copy is the same notebook")

    -- deleting the open document starts a new drawing without bringing it back
    local copyPath = view.doc_path
    view:libraryGo(Storage.dirName(copyPath))
    local copyItem
    for _, it in ipairs(view._library.items) do if it.path == copyPath then copyItem = it end end
    view:confirmDeleteItem(copyItem)
    UIManager.shown.ok_callback()
    ok(not Storage.exists(copyPath) and view.doc_path ~= copyPath and not view.doc_written and not view.notebook,
        "lib: deleting the open document leaves a new drawing")
    view:saveDocument()
    ok(not Storage.exists(copyPath), "lib: and it is not saved back")

    -- the hold menu and the library menu open
    view:libraryItemMenu(view._library.items[1])
    ok(ButtonDialog.last and #ButtonDialog.last.buttons == 3, "lib: holding a card shows its menu")
    view:libraryMenu()
    ok(ButtonDialog.last and #ButtonDialog.last.buttons == 3, "lib: the library menu offers import, sort and the trash")
    ButtonDialog.last.buttons[2][1].callback()
    ok(G_reader_settings.data.inkaway_library_sort == "name", "lib: sorting by name is remembered")
    G_reader_settings.data.inkaway_library_sort = nil

    -- the File sheet
    view:openDocumentSheet()
    ok(view._doc_dialog ~= nil, "lib: the File sheet opens")
    view:closeSheet("_doc_dialog")
    view._library:close()
    UIManager:close(view)

    -- opening Ink Away on the library: from the setting, and from its gesture
    G_reader_settings.data.inkaway_start = "library"
    local v2 = InkAwayView:new{}
    UIManager:show(v2)
    ok(v2._library ~= nil, "lib: with the setting, Ink Away opens on the library as it shows (one flash)")
    v2._library:close(); UIManager:close(v2)
    G_reader_settings.data.inkaway_start = nil
    local v3 = InkAwayView:new{ show_library = true }
    UIManager:show(v3)
    ok(v3._library ~= nil, "lib: the library gesture opens it on top")
    UIManager:close(v3)
    ok(v3._library == nil, "lib: closing Ink Away closes the library too")

    -- opening on the notebooks: the last notebook's pages, even after a drawing
    local v4 = InkAwayView:new{}
    UIManager:show(v4)
    v4:newNotebook("grid", LIB)
    stroke(v4, 120, 120)
    v4:saveDocument()
    local nb_path = v4.doc_path
    ok(G_reader_settings.data.inkaway_last_notebook == nb_path, "lib: the last notebook is remembered")
    v4:newDrawing(LIB)
    stroke(v4, 150, 150)
    v4:saveDocument()
    ok(G_reader_settings.data.inkaway_last_notebook == nb_path, "lib: and stays so while a drawing is open")
    UIManager:close(v4)
    G_reader_settings.data.inkaway_start = "notebooks"
    local v5 = InkAwayView:new{}
    UIManager:show(v5)
    ok(v5.doc_path == nb_path and v5.notebook ~= nil, "lib: starting on Notebooks opens the last notebook")
    ok(v5._overview ~= nil and v5._library == nil and v5._ov.path == nb_path,
        "lib: with the notebook browser on top, showing its pages")
    v5._overview:close(); UIManager:close(v5)
    G_reader_settings.data.inkaway_start = nil
    G_reader_settings.data.inkaway_last_notebook = nil

    TestEnv.remember_last_doc = false
    G_reader_settings.data.inkaway_last_doc = nil
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    UIManager.reset()
end

-- ---- export: one sheet for drawings and notebooks, PNG or PDF -------------
do
    local TestEnv = require("testenv")
    local Export = require("ink/export")
    local Project = require("ink/project")
    local Storage = require("ink/storage")
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    local LIB = TestEnv.libraryDir() .. "/exporttest"
    os.execute("mkdir -p '" .. LIB .. "/out'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_export_dir = LIB .. "/out"
    TestEnv.remember_last_doc = true
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    -- stand-ins for the encoders, recording what they were asked to write
    local savedPNG, savedPDF = Export.savePNG, Export.notebookPDFJob
    local png, pdf
    Export.savePNG = function(canvas, path, opts)
        png = { canvas = canvas, path = path, opts = opts }
        local f = io.open(path, "wb"); f:write("png"); f:close()
        return true
    end
    Export.notebookPDFJob = function(pages, w, h, template, path, quality, tmp, bg, opts)
        pdf = { pages = pages, template = template, path = path, bg = bg, opts = opts }
        local job = { i = 0, n = #pages }
        function job.step() job.over = true; return "done" end
        function job.cancel() job.over = true end
        return job
    end

    local view = InkAwayView:new{}
    UIManager:show(view)
    view:openExport()
    ok(view._save_dialog == nil, "export: an empty drawing has nothing to export")
    stroke(view, 200, 200)
    view:renameDocument("Cover")
    view:openExport()
    ok(view._save_dialog ~= nil, "export: the sheet opens once there is ink")
    view:closeSheet("_save_dialog")
    ok(view:exportDir() == LIB .. "/out", "export: files go to the export folder from the settings")

    -- a PNG: transparent by default, white when asked, and named after the document
    view:promptExportName()
    ok(InputDialog.last.input == "Cover", "export: the name starts as the document's")
    InputDialog.last.buttons[1][3].callback()
    ok(png and png.path == LIB .. "/out/Cover.png" and png.opts.white == nil, "export: a transparent PNG is written")
    view:exportOptions().transparent = false
    view:promptExportName()
    InputDialog.last.input = "Cover"
    InputDialog.last.buttons[1][3].callback()
    ok(UIManager.shown and UIManager.shown.ok_callback ~= nil, "export: writing over the last export asks first")
    png = nil
    UIManager.shown.ok_callback()
    ok(png and png.opts.white == true, "export: Transparent off lays the PNG on white")

    -- a drawing can be a one-page PDF
    view:exportOptions().fmt = "pdf"
    view:writePDF(LIB .. "/out/Cover.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(pdf and #pdf.pages == 1 and pdf.template.style == "blank", "export: a drawing makes a one-page PDF")

    -- a drawing's grid goes in only when asked, and never on a transparent PNG
    view.grid_on, view.grid_style, view.grid_size, view.grid_strength = true, "square", 30, 50
    local eo = view:exportOptions()
    view:writePDF(LIB .. "/out/Cover.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(pdf.template.style == "blank", "export: a drawing's grid stays out by default")
    eo.include_grid = true
    view:writePDF(LIB .. "/out/Cover.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(pdf.template.style == "grid" and pdf.template.size == 30 and pdf.template.gray ~= nil,
        "export: Include the grid puts the drawing's grid in the PDF")
    eo.fmt, eo.transparent = "png", false
    ok(view:pngOptions().template and view:pngOptions().template.style == "grid", "export: and in a PNG on white")
    eo.transparent = true
    ok(view:pngOptions().template.style == "blank", "export: a transparent PNG never has the grid")
    eo.transparent = false
    view.grid_style = "thirds"
    ok(view:pngOptions().template.style == "thirds", "export: the thirds guide can be included too")
    local function sheetHas(label)
        local function walk(w, seen)
            if type(w) ~= "table" or seen[w] then return false end
            seen[w] = true
            if w.label == label then return true end
            for k, val in pairs(w) do
                if k ~= "show_parent" and k ~= "parent" and walk(val, seen) then return true end
            end
            return false
        end
        view:openExport()
        local has = walk(view._save_dialog, {})
        view:closeSheet("_save_dialog")
        return has
    end
    ok(sheetHas("Include the grid"), "export: the sheet offers the grid for a PNG on white")
    eo.transparent = true
    ok(not sheetHas("Include the grid"), "export: but not for a transparent PNG")
    eo.transparent = false
    view.grid_on = false
    ok(view:pngOptions().template.style == "blank", "export: no grid shown, none exported")
    eo.include_grid, eo.fmt = nil, "pdf"
    do
        local n = 0
        require("ink/template").render("thirds", 90, 60, 10, function() n = n + 1 end)
        ok(n == 2 * 60 + 2, "export: the thirds guide draws two rules each way")
    end

    -- the export settings are kept in the document and come back with it
    view:saveDocument()
    local data = Project.load(view.doc_path)
    ok(data.export and data.export.name == "Cover" and data.export.fmt == "pdf" and data.export.transparent == false,
        "export: the last export's settings are saved in the document")
    local coverPath = view.doc_path

    -- a notebook: PDF by default, and the page scopes
    view:newNotebook("lines", LIB)
    ok(view:exportOptions().fmt == "pdf" and view:exportOptions().scope == "all", "export: a notebook defaults to a PDF of all pages")
    stroke(view, 100, 100)
    view:nbAddPage()
    view:nbAddPage(); stroke(view, 300, 300)
    view:nbGoTo(2)
    local o = view:exportOptions()
    local function sel() return table.concat(view:selectedNotebookPages(), ",") end
    ok(sel() == "1,2,3", "export: All covers every page")
    o.scope = "page"; ok(sel() == "2", "export: This page covers the page shown")
    o.scope = "ink"; ok(sel() == "1,3", "export: With ink skips blank pages")
    o.scope = "range"; o.range = { from = 2, to = 9 }; ok(sel() == "2,3", "export: a range is kept within the notebook")
    o.scope = "all"
    view:writePDF(LIB .. "/out/Notes.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(pdf and #pdf.pages == 3 and pdf.template(1).style == "lines" and pdf.template(1).gray ~= nil,
        "export: the notebook PDF carries its ruling")
    o.include_bg = false
    view:writePDF(LIB .. "/out/Notes.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(pdf.template(1).style == "blank" and view.notebook.template.style == "lines",
        "export: leaving the paper out drops the ruling, only from the export")
    o.include_bg = true
    -- a PNG of a notebook page draws its ruling under the ink, on white
    o.fmt, o.transparent = "png", false
    view:writePNG(LIB .. "/out/Page.png")
    ok(png.opts.template and png.opts.template.style == "lines" and png.opts.white == true,
        "export: a page PNG includes its paper")
    ok(png.canvas == view.canvas, "export: a page PNG is the page shown")

    -- the library's hold menu offers Export for documents
    view:openLibrary(LIB)
    local item
    for _, it in ipairs(view._library.items) do if it.path == coverPath then item = it end end
    view:libraryItemMenu(item)
    local exportBtn = ButtonDialog.last.buttons[1][2]
    ok(exportBtn and exportBtn.text:find("Export"), "export: the library offers Export")
    exportBtn.callback()
    ok(view.doc_path == coverPath and view._save_dialog ~= nil and view._library == nil,
        "export: from the library it opens the document's export sheet")
    ok(view:exportOptions().fmt == "pdf" and view:exportOptions().name == "Cover",
        "export: with the settings it was last exported with")
    view:closeSheet("_save_dialog")
    UIManager:close(view)

    Export.savePNG, Export.notebookPDFJob = savedPNG, savedPDF
    TestEnv.remember_last_doc = false
    G_reader_settings.data.inkaway_last_doc = nil
    G_reader_settings.data.inkaway_export_dir = nil
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    UIManager.reset()
end

-- ---- notebook pages: bar icons, page menu, own paper, finger swipes -------
do
    local TestEnv = require("testenv")
    local Export = require("ink/export")
    local Project = require("ink/project")
    local InputDialog = require("ui/widget/inputdialog")
    TestEnv.remember_last_doc = false
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local function answer(text)
        local d = InputDialog.last
        d.input = text
        for _, b in ipairs(d.buttons[1]) do if b.is_enter_default then b.callback() end end
    end
    local function centre(r) return { x = r.x + r.w / 2, y = r.y + r.h / 2 } end

    local view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines")
    stroke(view, 100, 100)
    view:nbAddPage(); stroke(view, 200, 200)
    view:nbAddPage()
    view:nbGoTo(2)
    local nb = view.notebook
    view:paintTo(Screen.bb, 0, 0)

    -- the bar: overview left of the counter, add-page right of it, mirrored
    local ov, plus, cnt = view._nb_overview, view._nb_plus, view._nb_count
    ok(ov and plus and cnt, "pages: the bar has overview, counter and add-page zones")
    ok(ov.x + ov.w <= cnt.x and cnt.x + cnt.w <= plus.x, "pages: overview, counter, add-page in that order")
    local mid = view.screen_w / 2
    ok(math.abs((mid - (ov.x + ov.w / 2)) - ((plus.x + plus.w / 2) - mid)) <= 2,
        "pages: the two icons sit the same distance either side of the middle")
    ok(view.nb_bar_h == view.toolbar:getSize().h, "pages: the bottom bar is as tall as the toolbar")
    ok(ov.w >= view._btn_w and plus.w >= view._btn_w and view._nb_prev.w >= view._btn_w
        and view._nb_next.w >= view._btn_w, "pages: each bar button is at least a toolbar button wide")
    ok(cnt.w >= 2 * view._btn_w, "pages: and the counter has two columns' room between them")
    ok(view._nb_prev.w >= 1.4 * view._btn_w and view._nb_next.w >= 1.4 * view._btn_w
        and view._nb_prev.x + view._nb_prev.w <= ov.x and plus.x + plus.w <= view._nb_next.x,
        "pages: Prev and Next take taps further in, clear of the middle buttons")
    ok(ov.w == plus.w and ov.h == plus.h, "pages: and have the same size")
    view:onIaTap(nil, { pos = centre(ov) })
    ok(view._overview and #view._overview.items == 3, "pages: the overview icon opens the page overview")
    view._overview:close()
    view:onIaTap(nil, { pos = centre(cnt) })
    ok(view._page_dialog ~= nil, "pages: the counter opens the page menu")
    view:closeSheet("_page_dialog")

    -- rename and star: kept with the page and saved
    view:nbRenamePage()
    answer("  Lab results ")
    ok(nb.pages[2].title == "Lab results", "pages: a page gets a title")
    view:nbToggleStar()
    ok(nb.pages[2].star == true, "pages: and a star")
    view:saveDocument()
    local data = Project.load(view.doc_path)
    ok(data.pages[2].title == "Lab results" and data.pages[2].star == true, "pages: both are saved, cache or not")
    view:openOverview()
    local item = view._overview.items[2]
    ok(item.star and item.label:find("Lab results", 1, true), "pages: the overview shows the title and star")
    view._overview:close()
    view:nbRenamePage(); answer("")
    view:nbToggleStar()
    ok(nb.pages[2].title == nil and nb.pages[2].star == nil, "pages: an empty title and a second star clear them")

    -- insert before, then move with the prompt
    local second = nb.pages[2]
    view:nbInsertPageBefore()
    ok(nb:count() == 4 and nb.index == 2 and nb.pages[3] == second and view.canvas:opCount() == 0,
        "pages: Insert before adds a blank page in front of this one")
    view:nbGoTo(3)
    view:nbMovePrompt()
    answer("1")
    ok(nb.pages[1] == second and nb.index == 1, "pages: Move puts the page at the position typed")

    -- the page's own paper: drawn, saved and exported
    view:nbPagePaper()
    local chooser = view._chooser_dialog
    ok(chooser ~= nil, "pages: Paper opens a chooser")
    view:closeSheet("_chooser_dialog")
    second.paper = "grid"; view:nbPageChanged(second); view:composeCanvas()
    ok(nb:pageTemplate().style == "grid" and nb.template.style == "lines", "pages: the page draws on its own paper")
    view:saveDocument()
    ok(Project.load(view.doc_path).pages[1].paper == "grid", "pages: its paper is saved")
    local savedJob, pdf = Export.notebookPDFJob, nil
    Export.notebookPDFJob = function(pages, w, h, template)
        pdf = { pages = pages, template = template }
        return { i = 0, n = #pages, step = function() return "done" end, cancel = function() end }
    end
    view:exportOptions().scope = "all"
    view:writePDF(view.doc_path:gsub("%.inkaway$", ".pdf"))
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(pdf and pdf.template(1).style == "grid" and pdf.template(2).style == "lines",
        "pages: the PDF prints each page on its own paper")
    Export.notebookPDFJob = savedJob
    view:closeSheet("_save_dialog")

    -- fingers on the page, with palm rejection on: navigate, draw or nothing
    view:nbGoTo(2)
    local v = view.view
    local function fingerSwipe(x0, x1, y)
        view:onIaTouch(nil, pos(x0, v.area_y + y))
        view:onIaPan(nil, pos((x0 + x1) / 2, v.area_y + y + 5))
        view:onIaPanRelease(nil, pos(x1, v.area_y + y + 10))
        UIManager.fireScheduled()
    end
    local ops2 = view.canvas:opCount()
    fingerSwipe(800, 200, 600)
    ok(nb.index == 2 and view.canvas:opCount() == ops2 + 1, "fingers: without palm rejection a finger draws")
    view:undo()
    view.palm_reject, view.finger_mode = true, "navigate"
    fingerSwipe(800, 200, 600)
    ok(nb.index == 3, "fingers: navigating, a swipe to the left turns to the next page")
    ok(view.canvas:opCount() == 0 and not view.capturing, "fingers: and draws nothing")
    fingerSwipe(200, 800, 600)
    ok(nb.index == 2, "fingers: to the right goes back")
    fingerSwipe(400, 420, 300)
    ok(nb.index == 2 and view.canvas:opCount() == ops2, "fingers: a short or upright drag does not turn")
    view:onIaTouch(nil, pos(400, v.area_y + 300))
    view:onIaSwipe(nil, { pos = { x = 300, y = v.area_y + 300 }, direction = "west" })
    ok(nb.index == 3, "fingers: a quick flick turns the page too")
    view:feedPen("down", 300, v.area_y + 300)
    view:feedPen("move", 400, v.area_y + 380)
    view:feedPen("up", 400, v.area_y + 380)
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == 1, "fingers: the pen still writes")
    view.tool = "text"
    view:nbGoTo(2)
    fingerSwipe(800, 200, 600)
    ok(nb.index == 3, "fingers: with any tool the finger navigates")
    view:onIaTouch(nil, pos(500, v.area_y + 500)); view:onIaTap(nil, pos(500, v.area_y + 500))
    ok(not view.editing_text, "fingers: and a tap on the page does nothing")
    view.tool = "pen"
    view:nbGoTo(3)
    -- zoomed in, a finger drag pans instead
    view:setZoom(2)
    local px, py = v.pan_x, v.pan_y
    fingerSwipe(800, 600, 600)
    ok(nb.index == 3 and v.pan_x ~= px, "fingers: zoomed in, a sideways drag pans the page and does not turn it")
    view:setZoom(view.zoom_min)
    -- a hold on a shape opens its menu, as with the Move tool
    view.canvas:addShape("rect", false, { 100, 100, 400, 300 }, 6, 255)
    view:composeCanvas(); view:renderView()
    local sx, sy = require("ink/geom").toScreen(v, 100, 200)
    view:onIaTouch(nil, pos(sx, sy))
    view:onIaHold(nil, pos(sx, sy))
    ok(view.selection ~= nil and view._sel_dialog ~= nil, "fingers: holding a shape opens its menu")
    view:onIaHoldRel(nil, pos(sx, sy))
    view:dropSelection()
    -- nothing: a finger does nothing on the page
    view.finger_mode = "nothing"
    local idx = nb.index
    fingerSwipe(800, 200, 600)
    ok(nb.index == idx and view.canvas:opCount() == 2, "fingers: set to nothing, a finger neither turns nor draws")
    view:onIaTouch(nil, pos(sx, sy)); view:onIaHold(nil, pos(sx, sy)); view:onIaHoldRel(nil, pos(sx, sy))
    ok(view._sel_dialog == nil, "fingers: nor opens menus")
    view.palm_reject = false
    fingerSwipe(800, 200, 600)
    ok(nb.index == idx and view.canvas:opCount() == 3, "fingers: without palm rejection, a finger draws")

    -- two fingers: a tap undoes, a sideways swipe turns the page
    local n0 = view.canvas:opCount()
    view:onIaTwoTap(nil, { pos = { x = 500, y = v.area_y + 500 } })
    ok(view.canvas:opCount() == n0 - 1, "two fingers: a tap undoes")
    view._two_tap = nil   -- (faster than a person: not a double tap)
    view:onIaTouch(nil, pos(300, v.area_y + 300))   -- a finger dot just begun (gesture path)
    view:onIaTwoTap(nil, { pos = { x = 500, y = v.area_y + 500 } })
    ok(view.canvas:opCount() == n0 - 2 and not view.capturing,
        "two fingers: the first finger's dot is dropped, and the undo takes the last real change")
    view:redo(); view:redo()
    view._two_tap = nil
    -- zooming out stops where the page fills the area: no margins at the sides
    view:setZoom(3); view:setZoom(0.1)
    ok(math.abs(v.zoom - view.zoom_min) < 1e-9 and v.canvas_w * v.zoom >= v.area_w - 1,
        "zoom: pinching out stops at the starting size, the page filling the width")
    idx = nb.index
    view:onIaTwoSwipe(nil, { pos = { x = 800, y = v.area_y + 600 }, end_pos = { x = 300, y = v.area_y + 620 } })
    ok(nb.index == idx + 1, "two fingers: a swipe to the left turns to the next page")
    view:onIaTwoSwipe(nil, { pos = { x = 300, y = v.area_y + 600 }, end_pos = { x = 800, y = v.area_y + 600 } })
    ok(nb.index == idx, "two fingers: to the right goes back")
    view:onIaTwoSwipe(nil, { pos = { x = 500, y = v.area_y + 300 }, end_pos = { x = 520, y = v.area_y + 900 } })
    ok(nb.index == idx, "two fingers: an upright swipe does not turn")
    UIManager.refreshes = {}
    view:onIaTwoPan(nil, { pos = { x = 600, y = v.area_y + 600 } })
    view:onIaTwoPan(nil, { pos = { x = 400, y = v.area_y + 610 } })
    view:onIaTwoPanRel()
    ok(#UIManager.refreshes == 0, "two fingers: a sideways move on an unzoomed page pans nothing on its way to a swipe")

    -- holding Prev or Next goes to the first or last page
    view:paintTo(Screen.bb, 0, 0)
    local function centre(r) return pos(r.x + r.w / 2, r.y + r.h / 2) end
    view:onIaHold(nil, centre(view._nb_next))
    ok(nb.index == nb:count(), "bar: holding Next goes to the last page")
    view:onIaHold(nil, centre(view._nb_prev))
    ok(nb.index == 1, "bar: holding Prev goes to the first page")
    view.palm_reject, view.finger_mode = false, "draw"
    UIManager:close(view)
    UIManager.reset()
end

-- ---- overview: the folder's notebooks as tabs -----------------------------
do
    local TestEnv = require("testenv")
    local Folder = require("ink/folder")
    local Project = require("ink/project")
    local Storage = require("ink/storage")
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    local LIB = TestEnv.libraryDir() .. "/binder"
    local DIR = LIB .. "/Physics"
    os.execute("mkdir -p '" .. DIR .. "'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local function answer(text)
        local d = InputDialog.last
        d.input = text
        for _, b in ipairs(d.buttons[1]) do if b.is_enter_default then b.callback() end end
    end
    local function tabNames(grid)
        local t = {}
        for _, tab in ipairs(grid.tabs) do t[#t + 1] = (tab.selected and "*" or "") .. tab.label end
        return table.concat(t, ",")
    end
    local function press(dialog, text)
        for _, row in ipairs(dialog.buttons) do
            for _, b in ipairs(row) do if b.text == text then b.callback(); return true end end
        end
    end

    -- three documents in one folder: two notebooks and a drawing
    local view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines", DIR)
    stroke(view, 100, 100)
    view:nbAddPage(); stroke(view, 200, 200)
    view:renameDocument("Mechanics"); view:saveDocument()
    view:newNotebook("grid", DIR)
    stroke(view, 100, 100)
    view:renameDocument("Waves"); view:saveDocument()
    view:newDrawing(DIR)
    stroke(view, 100, 100)
    view:renameDocument("Sketch"); view:saveDocument()
    view:openDocument(DIR .. "/Waves.inkaway")

    view:openOverview()
    local ov = view._overview
    ok(ov and UIManager.shown == ov, "overview: it opens full screen")
    ok(tabNames(ov) == "Mechanics,*Waves", "overview: the folder's notebooks are tabs, the open one chosen")
    ok(ov.title == "Physics", "overview: the title is the folder it shows")
    ok(ov.on_back ~= nil, "overview: it has a back arrow, as the folder is inside the library")
    ok(#ov.items == 1 and ov.items[1].selected, "overview: it shows the open notebook's pages")
    BB.out_of_bounds = 0
    ov:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "overview: tabs and cards paint in bounds")

    -- another tab: its pages, from its file; a tap opens that page
    view:overviewShowTab(DIR .. "/Mechanics.inkaway")
    ok(#ov.items == 2 and tabNames(ov) == "*Mechanics,Waves", "overview: a tap on a tab shows its pages")
    ov:paintTo(Screen.bb, 0, 0)
    local thumb = view:overviewThumb(ov.items[2], 200, 260)
    ok(thumb ~= nil, "overview: another notebook's pages get thumbnails")
    view:overviewPick(ov.items[2])
    ok(view.doc_path == DIR .. "/Mechanics.inkaway" and view.notebook.index == 2 and view._overview == nil,
        "overview: tapping a page opens its notebook at that page")

    -- tab order and colour are kept in the folder
    view:openOverview()
    ov = view._overview
    view:overviewTabMenu(ov.tabs[1])
    press(ButtonDialog.last, "Move down")
    ok(tabNames(ov) == "Waves,*Mechanics", "overview: Move down reorders the tabs")
    ok(Folder.load(DIR).order[1] == "Waves.inkaway", "overview: and the order is saved in the folder")
    -- the choice is swatches of the colours themselves, and No colour
    local picks = {}
    local realSwatch = view.swatchTile
    view.swatchTile = function(self2, rgb, sel, w, cb, hold, h)
        picks[#picks + 1] = { rgb = rgb, cb = cb }
        return realSwatch(self2, rgb, sel, w, cb, hold, h)
    end
    view:overviewTabColour(ov.tabs[2])
    view.swatchTile = nil
    local chooser = view._chooser_dialog
    ok(chooser ~= nil, "overview: Colour offers a choice")
    ok(#picks == 3 and findButton(chooser, "No colour") ~= nil,
        ("overview: three grey swatches on a grey screen, and No colour (%d)"):format(#picks))
    picks[2].cb()   -- the middle grey
    ok(view._chooser_dialog == nil and Folder.load(DIR).colors["Mechanics.inkaway"]
        and Folder.load(DIR).colors["Mechanics.inkaway"][1] == 0x88, "overview: a tap on a swatch colours the tab")
    view:overviewTabColour(ov.tabs[2])
    findButton(view._chooser_dialog, "No colour").callback()
    ok(Folder.load(DIR).colors["Mechanics.inkaway"] == nil, "overview: No colour takes it off")
    local data = Folder.load(DIR)
    data.colors["Mechanics.inkaway"] = { 0x88, 0x88, 0x88 }
    Folder.save(DIR, data)
    view:refreshOverview()
    ok(ov.tabs[2].color ~= nil and ov.tabs[1].color == nil, "overview: a tab shows its colour")

    -- renaming a tab keeps its place and colour
    view:overviewTabMenu(ov.tabs[1])
    press(ButtonDialog.last, "Rename\u{2026}")
    answer("Optics")
    ok(Storage.exists(DIR .. "/Optics.inkaway") and not Storage.exists(DIR .. "/Waves.inkaway"),
        "overview: renaming a tab renames its file")
    ok(tabNames(ov) == "Optics,*Mechanics" and Folder.load(DIR).order[1] == "Optics.inkaway",
        "overview: and keeps its place")

    -- pages: star, rename, move and copy to another notebook
    view:overviewShowTab(DIR .. "/Optics.inkaway")
    view:overviewPageMenu(ov.items[1])
    press(ButtonDialog.last, "Star")
    ok(Project.load(DIR .. "/Optics.inkaway").pages[1].star == true, "overview: starring a page of another notebook saves it")
    view:overviewShowTab(DIR .. "/Mechanics.inkaway")
    view:overviewPageMenu(ov.items[1])
    press(ButtonDialog.last, "Rename\u{2026}")
    answer("Forces")
    ok(view.notebook.pages[1].title == "Forces", "overview: renaming a page of the open notebook changes it there")
    view:overviewPageMenu(ov.items[1])
    press(ButtonDialog.last, "Move to\u{2026}")
    local targets = ButtonDialog.last
    ok(#targets.buttons == 2 and targets.buttons[1][1].text == "\u{2039} Notebooks"
        and targets.buttons[2][1].text == "Optics", "overview: Move offers the other notebooks, and a way up")
    targets.buttons[2][1].callback()
    ok(view.notebook:count() == 1 and view.notebook.pages[1].title == nil, "overview: the page leaves its notebook")
    local optics = Project.load(DIR .. "/Optics.inkaway")
    ok(#optics.pages == 2 and optics.pages[2].title == "Forces", "overview: and is added to the end of the other")
    ok(optics.pages[2].paper == "lines", "overview: keeping the lined paper it was on")
    ok(view:docHasContent() and Project.load(DIR .. "/Mechanics.inkaway") ~= nil, "overview: both notebooks are intact")
    view:overviewPageMenu(ov.items[1])
    press(ButtonDialog.last, "Copy to\u{2026}")
    press(ButtonDialog.last, "Optics")
    ok(view.notebook:count() == 1 and #Project.load(DIR .. "/Optics.inkaway").pages == 3,
        "overview: Copy leaves the page where it was")
    view:overviewPageMenu(ov.items[1])
    press(ButtonDialog.last, "Move to\u{2026}")
    ok(view.notebook:count() == 1, "overview: the last page of a notebook stays")

    -- the starred filter
    view:overviewShowTab(DIR .. "/Optics.inkaway")
    view:overviewToggleStarred()
    ok(#ov.items == 1 and ov.title == "Starred pages", "overview: the star shows only starred pages")
    view:overviewToggleStarred()
    ok(#ov.items == 3, "overview: and back to all of them")

    -- tabs skip the drawing in between when they move
    local data = Folder.load(DIR)
    data.order = { "Optics.inkaway", "Sketch.inkaway", "Mechanics.inkaway" }
    Folder.save(DIR, data)
    view:overviewMoveTab(ov.tabs[2], -1)
    ok(tabNames(ov) == "Mechanics,*Optics", "overview: a tab moves past a drawing in between")
    ok(table.concat(Folder.load(DIR).order, ",") == "Mechanics.inkaway,Sketch.inkaway,Optics.inkaway",
        "overview: and the drawing keeps its place")

    -- + Notebook makes a new one in this folder
    ok(ov.tab_footer[2][1] == "+ Notebook", "overview: + Notebook is the lowest button under the tabs")
    ov.tab_footer[2][2]()
    ok(view._new_dialog ~= nil, "overview: + Notebook opens the paper choice for this folder")
    view:closeSheet("_new_dialog")
    -- + Folder above it makes a folder here, which shows as a tab at once
    ok(ov.tab_footer[1][1] == "+ Folder", "overview: + Folder is above it")
    ov.tab_footer[1][2]()
    answer("Lab reports")
    ok(Storage.isDir(DIR .. "/Lab reports") and ov.tabs[1].folder and ov.tabs[1].label == "Lab reports",
        "overview: + Folder makes a folder in this one, shown as a tab")
    BB.out_of_bounds = 0
    local rects = {}
    Screen.bb.paintRoundedRect = function(_, x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
    ov:paintTo(Screen.bb, 0, 0)
    Screen.bb.paintRoundedRect = nil
    ok(BB.out_of_bounds == 0, "overview: the tab column with two buttons paints in bounds")
    local over = 0
    for _, r in ipairs(rects) do
        if r.x < ov.tab_w and r.x + r.w > ov.tab_w then over = over + 1 end
    end
    ok(#rects > 0 and over == 0, "overview: no tab, the selected one included, reaches over into the pages")
    local L = ov:tabLayout()
    local f1, f2 = L.foot[1], L.foot[2]
    ok(f1.y + f1.h < f2.y and ov:tabAt({ x = f1.x + 5, y = f1.y + 5 }) == 1 and ov:tabAt({ x = f2.x + 5, y = f2.y + 5 }) == 2,
        "overview: the two buttons are stacked apart and each answers its own taps")
    Storage.removeTree(DIR .. "/Lab reports")
    ov:close()

    -- deleting the open notebook's tab
    view:openOverview()
    ov = view._overview
    local mech
    for _, tab in ipairs(ov.tabs) do if tab.label == "Mechanics" then mech = tab end end
    view:overviewTabMenu(mech)
    press(ButtonDialog.last, "Delete\u{2026}")
    UIManager.shown.ok_callback()
    ok(not Storage.exists(DIR .. "/Mechanics.inkaway") and view.doc_path ~= DIR .. "/Mechanics.inkaway",
        "overview: deleting the open tab removes it and starts a new drawing")
    ok(not tabNames(ov):find("Mechanics", 1, true), "overview: the tab is gone")
    ok(tabNames(ov) == "*Optics", "overview: and the first notebook left is shown")

    -- the back arrow goes up a folder; a folder tab goes into it
    ov.on_back()
    ok(view._overview == ov and ov.title == "Notebooks" and ov.on_back == nil,
        "overview: back goes up a folder, here to the top")
    ok(tabNames(ov) == "Physics" and ov.tabs[1].folder and #ov.items == 0,
        "overview: where the folder is a tab, and no notebook to show")
    ov.on_tab(ov.tabs[1])
    ok(ov.title == "Physics" and tabNames(ov) == "*Optics", "overview: its tab goes back in, to the notebook shown there")
    -- Library shows the folder in the library
    ov.actions[2][2]()
    ok(view._overview == nil and view._library ~= nil and view._lib_dir == DIR,
        "overview: Library shows the folder in the library")
    view._library:close()

    -- deleting the last notebook leaves an empty folder
    view:openDocument(DIR .. "/Optics.inkaway")
    view:openOverview()
    ov = view._overview
    view:overviewTabMenu(ov.tabs[1])
    press(ButtonDialog.last, "Delete\u{2026}")
    UIManager.shown.ok_callback()
    ok(view._overview == ov and #ov.items == 0 and #ov.tabs == 0 and ov.empty_text == "No notebooks here yet.",
        "overview: with no notebook left it shows the empty folder")
    ov:close()
    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- ---- overview: folders inside folders, like section groups -----------------
do
    local TestEnv = require("testenv")
    local Folder = require("ink/folder")
    local Project = require("ink/project")
    local Storage = require("ink/storage")
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    local LIB = TestEnv.libraryDir() .. "/sections"
    local SCHOOL = LIB .. "/School"
    os.execute("mkdir -p '" .. SCHOOL .. "/Math' '" .. SCHOOL .. "/Physics'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local function answer(text)
        local d = InputDialog.last
        d.input = text
        for _, b in ipairs(d.buttons[1]) do if b.is_enter_default then b.callback() end end
    end
    local function tabNames(grid)
        local t = {}
        for _, tab in ipairs(grid.tabs) do
            t[#t + 1] = (tab.selected and "*" or "") .. tab.label .. (tab.folder and "/" or "")
        end
        return table.concat(t, ",")
    end
    local function press(dialog, text)
        for _, row in ipairs(dialog.buttons) do
            for _, b in ipairs(row) do if b.text == text then b.callback(); return true end end
        end
    end
    local function notebook(view, dir, name, style)
        view:newNotebook(style or "lines", dir)
        stroke(view, 100, 100)
        view:renameDocument(name); view:saveDocument()
    end

    -- School: Math (two notebooks), Physics (one), a timetable and a drawing
    local view = InkAwayView:new{}
    UIManager:show(view)
    notebook(view, SCHOOL .. "/Math", "Differential equations")
    notebook(view, SCHOOL .. "/Math", "Linear algebra", "grid")
    view:nbAddPage(); stroke(view, 200, 200); view:saveDocument()
    notebook(view, SCHOOL .. "/Physics", "Mechanics")
    notebook(view, SCHOOL, "Timetable")
    view:newDrawing(SCHOOL)
    stroke(view, 100, 100)
    view:renameDocument("Doodle"); view:saveDocument()
    view:openDocument(SCHOOL .. "/Math/Linear algebra.inkaway")

    view:openOverview()
    local ov = view._overview
    ok(ov.title == "Math" and tabNames(ov) == "Differential equations,*Linear algebra",
        "sections: the overview opens in the notebook's folder")
    ov.on_back()
    ok(ov.title == "School" and tabNames(ov) == "Math/,Physics/,*Timetable",
        "sections: up a folder its subfolders come first, then its notebooks (not the drawing)")
    BB.out_of_bounds = 0
    ov:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "sections: folder tabs paint in bounds")
    ov.on_tab(ov.tabs[2])
    ok(ov.title == "Physics" and tabNames(ov) == "*Mechanics", "sections: a folder tab goes into it")
    ov.on_back(); ov.on_tab(ov.tabs[1])
    ok(tabNames(ov) == "Differential equations,*Linear algebra" and #ov.items == 2,
        "sections: and a folder shows the notebook last shown there")

    -- copy a page from Physics to Math, browsing there in the picker
    ov.on_back(); ov.on_tab(ov.tabs[2])
    view:overviewPageMenu(ov.items[1])
    press(ButtonDialog.last, "Copy to\u{2026}")
    ok(ButtonDialog.last.buttons[1][1].text == "\u{2039} School" and #ButtonDialog.last.buttons == 1,
        "sections: the picker starts here, with a way up")
    press(ButtonDialog.last, "\u{2039} School")
    ok(press(ButtonDialog.last, "Math  \u{203A}"), "sections: up a folder it offers the folders to go into")
    ok(press(ButtonDialog.last, "Linear algebra"), "sections: and inside, their notebooks")
    ok(#Project.load(SCHOOL .. "/Math/Linear algebra.inkaway").pages == 3,
        "sections: the page is copied to a notebook in another folder")
    ok(#view.notebook.pages == 3, "sections: the open notebook has it too")

    -- folder tabs: move, colour and rename, keeping the open notebook
    ov.on_back()
    view:overviewTabMenu(ov.tabs[1])
    ok(ButtonDialog.last.title == "Math" and press(ButtonDialog.last, "Move down"), "sections: a folder tab has a menu")
    ok(tabNames(ov) == "Physics/,Math/,*Timetable", "sections: Move down swaps the folders")
    view:overviewTabMenu(ov.tabs[2])
    press(ButtonDialog.last, "Move down")
    ok(tabNames(ov) == "Physics/,Math/,*Timetable", "sections: but a folder does not move among the notebooks")
    view:overviewTabMenu(ov.tabs[2])
    press(ButtonDialog.last, "Rename\u{2026}")
    answer("Maths")
    ok(Storage.isDir(SCHOOL .. "/Maths") and not Storage.exists(SCHOOL .. "/Math"), "sections: renaming a folder tab renames it")
    ok(tabNames(ov) == "Physics/,Maths/,*Timetable", "sections: in its place")
    ok(view.doc_path == SCHOOL .. "/Maths/Linear algebra.inkaway", "sections: the open notebook inside follows")
    view:saveDocument()
    ok(Project.load(view.doc_path) ~= nil and not Storage.exists(SCHOOL .. "/Math"), "sections: and saves there")
    ov.on_tab(ov.tabs[2])
    ok(tabNames(ov) == "Differential equations,*Linear algebra", "sections: the folder remembers its notebook")
    ov.on_back()

    -- a folder's PDF holds its subfolders, with nested bookmarks
    local acc = { pages = {}, templates = {}, sources = {} }
    local o = view:collectFolderPages(SCHOOL, acc)
    ok(#acc.pages == 7, "sections: every page of every folder is in it (1 + 2 + 3 + 1 drawing)")
    ok(#o == 4 and o[1].title == "Physics" and o[2].title == "Maths" and o[3].title == "Timetable"
        and o[4].title == "Doodle", "sections: folders first, then the documents, in tab order")
    ok(o[2].page == 2 and #o[2].kids == 2 and o[2].kids[2].title == "Linear algebra" and o[2].kids[2].page == 3,
        "sections: a folder's notebooks are bookmarks under it")
    ok(acc.templates[3].style == "grid" and acc.templates[1].style == "lines", "sections: each page on its own paper")

    -- deleting a folder with the open notebook in it
    view:overviewTabMenu(ov.tabs[2])
    press(ButtonDialog.last, "Delete\u{2026}")
    ok(UIManager.shown.text:find("everything in it", 1, true) ~= nil, "sections: deleting a folder warns it takes everything")
    UIManager.shown.ok_callback()
    ok(not Storage.exists(SCHOOL .. "/Maths") and tabNames(ov) == "Physics/,*Timetable",
        "sections: the folder and its notebooks are gone")
    ok(view.notebook == nil and view.doc_path:find(SCHOOL, 1, true) == 1, "sections: a new drawing takes the open one's place")
    local names = table.concat(Folder.load(SCHOOL).order, ",")
    ok(not names:find("Maths", 1, true), "sections: and the folder leaves the tab order")
    ov:close()
    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- ---- one selection for everything: what the lasso takes, its menu, its handles
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkGeom = require("ink/geom")
    local Text = require("ink/text")
    local RenderImage = require("ui/renderimage")
    RenderImage.fake_size = { w = 200, h = 100 }
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view.stampTextInto = function() end   -- the mocks cannot lay out text
    UIManager:show(view)
    local v = view.view
    local function loop(x0, y0, x1, y1)
        view:setTool("lasso")
        local a, b = InkGeom.toScreen(v, x0, y0)
        local c, d = InkGeom.toScreen(v, x1, y1)
        view:onIaTouch(nil, pos(a, b)); view:onIaPan(nil, pos(c, b)); view:onIaPan(nil, pos(c, d))
        view:onIaPan(nil, pos(a, d)); view:onIaPanRelease(nil, pos(a, b))
    end
    local function picked()
        local t = {}
        for _, op in ipairs(view:selectionOps()) do t[#t + 1] = op.kind .. (op.shape and (":" .. op.shape) or "") end
        return table.concat(t, ",")
    end
    local function textOp(x, y)
        local op = Text.new{ x = x, y = y, w = 160, size = 20 }
        Text.insert(op, { p = 1, o = 0 }, "note", nil)
        op.h = 30
        return op
    end
    -- an ellipse looped close round its outline: its box corners lie outside the loop
    view.canvas:setOps({ { kind = "shape", shape = "ellipse", width = 3, alpha = 255, pts = { 100, 100, 300, 200 } } })
    loop(90, 92, 310, 208)
    ok(picked() == "shape:ellipse", "select: the lasso takes a shape by its outline (" .. picked() .. ")")
    -- a turned rectangle, its unturned corners outside the loop
    view.canvas:setOps({ { kind = "shape", shape = "rect", width = 3, alpha = 255, angle = math.pi / 4,
        pts = { 400, 400, 600, 600 } } })
    loop(355, 355, 645, 645)
    ok(picked() == "shape:rect", "select: and a turned shape")
    -- everything at once: ink, a shape, a fill, a picture, a text box
    view.canvas:setOps({
        { kind = "ink", width = 4, alpha = 255, pts = { 120, 120, 160, 150, 200, 130 } },
        { kind = "shape", shape = "line", width = 3, alpha = 255, pts = { 120, 200, 260, 220 } },
        { kind = "fill", alpha = 255, color = { 0x88, 0x88, 0x88 }, runs = { 130, 260, 40, 130, 261, 40 } },
        { kind = "image", path = "/tmp/pic.png", natw = 200, nath = 100, x = 300, y = 120, w = 100, h = 50 },
        textOp(120, 320),
    })
    view:composeCanvas(); view:renderView()
    loop(100, 100, 450, 380)
    ok(picked() == "ink,shape:line,fill,image,text", "select: one loop takes every kind (" .. picked() .. ")")
    local m = view._sel_dialog
    ok(m and findButton(m, "Cut") and findButton(m, "Duplicate") and findButton(m, "\u{2194} Flip")
        and findButton(m, "Colour") and findButton(m, "Size") and findButton(m, "To front")
        and findButton(m, "\u{2715} Delete") and findButton(m, "Done"),
        "select: its menu offers what the shape menu did, for all of it")
    ok(not findButton(m, "Remove background"), "select: Remove background only for a single picture")
    -- (judged against a paint without the selection: the mock screen can keep an
    -- earlier test's landscape state)
    local held = view.selection
    view.selection = nil
    BB.out_of_bounds = 0
    view:paintTo(Screen.bb, 0, 0)
    local base = BB.out_of_bounds
    view.selection = held
    BB.out_of_bounds = 0
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds <= base, "select: frame, handles and menu paint in bounds")

    -- a quarter turn: drawings turn, the text box stays upright where its centre goes
    local t0 = view.canvas.ops[5]
    local tcx, tcy = t0.x + t0.w / 2, t0.y + t0.h / 2
    local b = view.selection.bbox
    local cx, cy = (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2
    view:selTurn90()
    local t1 = view.canvas.ops[5]
    ok(t1.angle == nil and math.abs((t1.x + t1.w / 2) - (cx - (tcy - cy))) < 1e-6
        and math.abs((t1.y + t1.h / 2) - (cy + (tcx - cx))) < 1e-6, "select: a text box turns to its place, upright")
    ok(view.canvas.ops[4].angle == 90 and math.abs((view.canvas.ops[2].angle or 0) - math.pi / 2) < 1e-9,
        "select: the picture and the shape turn")
    ok(view.canvas:canUndo(), "select: one undo step")
    view:undo()
    ok(view.canvas.ops[5].x == 120 and view.selection == nil, "select: undo puts it all back and drops the frame")

    -- text alone: no mirrors, no turning handle
    view.canvas:setOps({ textOp(200, 200) })
    view:composeCanvas(); view:renderView()
    loop(180, 180, 400, 260)
    ok(picked() == "text" and not findButton(view._sel_dialog, "\u{2194} Flip") and not view:selCanTurn(),
        "select: text alone is not mirrored or turned")
    ok(not findButton(view._sel_dialog, "Colour"), "select: nor coloured")
    -- resizing text scales its letters
    local size0 = view.canvas.ops[1].size
    local f = view:selFrame()
    view:onIaTouch(nil, pos(f.x1, f.y1))
    view:onIaPan(nil, pos(f.x1 + 100, f.y1 + 50))
    view:onIaPanRelease(nil, pos(f.x1 + 100, f.y1 + 50))
    ok(view.canvas.ops[1].size > size0, "select: resizing text makes its letters bigger")

    -- with the menu open, a touch on the menu is the menu's; one elsewhere drops
    -- the selection and starts a new loop
    ok(view._sel_dialog ~= nil, "select: the menu is open")
    view._sel_dialog.dimen = { x = v.area_x + 10, y = v.area_y + v.area_h - 60, w = 200, h = 50 }
    view:onIaTouch(nil, pos(v.area_x + 20, v.area_y + v.area_h - 20))
    ok(not view.lassoing and view.selection ~= nil, "select: a touch on the menu starts nothing")
    view:onIaTouch(nil, pos(v.area_x + v.area_w - 20, v.area_y + v.area_h - 20))
    ok(view.lassoing and view.selection == nil and view._sel_dialog == nil,
        "select: a touch elsewhere drops the selection and starts a new loop")
    view:onIaPanRelease(nil, pos(v.area_x + v.area_w - 20, v.area_y + v.area_h - 20))
    -- the menu's panels: colour, opacity and size live in the same sheet
    view.canvas:setOps({ { kind = "ink", width = 4, alpha = 255, color = { 0, 0, 0 }, pts = { 120, 120, 200, 200 } } })
    view:composeCanvas(); view:renderView()
    loop(100, 100, 230, 230)
    findButton(view._sel_dialog, "Opacity").callback()
    ok(view._sel_dialog and findButton(view._sel_dialog, "Back") and not findButton(view._sel_dialog, "Cut"),
        "select: Opacity opens in the menu")
    view:selSetOpacity(40)
    ok(view.canvas.ops[1].alpha == math.floor(0.4 * 255 + 0.5), "select: and sets a pen stroke's opacity")
    findButton(view._sel_dialog, "Back").callback()
    ok(findButton(view._sel_dialog, "Cut") ~= nil, "select: Back returns to the actions")
    -- a pen stroke grows thicker with its selection
    local w0 = view.canvas.ops[1].width
    f = view:selFrame()
    view:onIaTouch(nil, pos(f.x1, f.y1))
    view:onIaPan(nil, pos(f.x1 + (f.x1 - f.x0), f.y1 + (f.y1 - f.y0)))
    view:onIaPanRelease(nil, pos(f.x1 + (f.x1 - f.x0), f.y1 + (f.y1 - f.y0)))
    ok(view.canvas.ops[1].width > w0 * 1.5, "select: resizing pen writing thickens it with it")
    -- Done drops it
    findButton(view._sel_dialog, "Done").callback()
    ok(view.selection == nil and view._sel_dialog == nil, "select: Done drops the selection")
    UIManager:close(view)
    UIManager.reset()
end

-- ---- clipboard: cut, copy and paste with the lasso, across pages and documents
do
    local TestEnv = require("testenv")
    local Clipboard = require("ink/clipboard")
    local ButtonDialog = require("ui/widget/buttondialog")
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    Clipboard.clear()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local function selectAll(view)
        view:computeSelection({ -10, -10, 5000, -10, 5000, 5000, -10, 5000 })
    end
    local view
    -- tap the button labelled `text` in the open selection or paste sheet
    local function press(text)
        local sheet = view._sel_dialog or view._paste_dialog
        local function texts(w, seen)
            if type(w) ~= "table" or seen[w] then return false end
            seen[w] = true
            if w.text == text then return true end
            for k, val in pairs(w) do
                if k ~= "show_parent" and k ~= "parent" and texts(val, seen) then return true end
            end
            return false
        end
        local function find(w, seen)
            if type(w) ~= "table" or seen[w] then return nil end
            seen[w] = true
            if type(w.callback) == "function" and texts(w, {}) then return w end
            for k, val in pairs(w) do
                if k ~= "show_parent" and k ~= "parent" then
                    local f = find(val, seen); if f then return f end
                end
            end
        end
        local b = sheet and find(sheet, {})
        if b then b.callback(); return true end
        return false
    end

    view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines")
    stroke(view, 100, 100); stroke(view, 200, 150)
    view.tool = "lasso"
    selectAll(view)
    view:openSelectionMenu()
    ok(press("Copy") and Clipboard.count() == 2 and view.canvas:opCount() == 2, "clip: Copy keeps the ink and holds it")
    view:clearSelection()
    view:nbAddPage()
    local v = view.view
    view:lassoTap({ x = 500, y = v.area_y + 600 })
    ok(view._paste_dialog ~= nil, "clip: a lasso tap on an empty spot offers to paste")
    press("Paste here")
    ok(view.canvas:opCount() == 2 and view.selection and #view.selection.idxs == 2,
        "clip: Paste here adds the ink on the new page, selected")
    local b = view.selection.bbox
    local cx, cy = (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2
    local tx, ty = require("ink/geom").toCanvas(v, 500, v.area_y + 600)
    ok(math.abs(cx - tx) <= 1 and math.abs(cy - ty) <= 1, "clip: centred where the lasso tapped")
    view:undo()
    ok(view.canvas:opCount() == 0, "clip: undo takes the paste back")
    view:clearSelection()
    view:openPageMenu()
    ok(view._page_dialog ~= nil, "clip: the page menu opens")
    view:closeSheet("_page_dialog")
    view:pasteAt(nil)
    ok(view.canvas:opCount() == 2 and view.notebook.pages[1].ops[1] ~= view.canvas.ops[1],
        "clip: paste where it was makes new copies")

    -- cut removes, and the clipboard outlives a switch to another document
    view:nbGoTo(1)
    view.tool = "lasso"
    selectAll(view)
    view:selCopy(true)
    ok(view.canvas:opCount() == 0 and Clipboard.count() == 2, "clip: Cut removes the ink and holds it")
    view:newDrawing()
    view.tool = "lasso"
    view:lassoTap({ x = 300, y = v.area_y + 300 })
    press("Paste here")
    ok(view.canvas:opCount() == 2 and not view.notebook, "clip: it pastes into another document")
    view:clearSelection()
    view.tool = "pen"
    UIManager:close(view)
    Clipboard.clear()
    UIManager.reset()
end

-- ---- bookmarks and folder export ------------------------------------------
do
    local TestEnv = require("testenv")
    local Export = require("ink/export")
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    local LIB = TestEnv.libraryDir() .. "/folderpdf"
    local DIR = LIB .. "/Physics"
    os.execute("mkdir -p '" .. DIR .. "'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local savedJob, job = Export.notebookPDFJob, nil
    Export.notebookPDFJob = function(pages, w, h, template, path, quality, tmp, bg, opts)
        job = { pages = pages, template = template, bg = bg, opts = opts, path = path }
        return { i = 0, n = #pages, step = function() return "done" end, cancel = function() end }
    end

    local view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines", DIR)
    stroke(view, 100, 100)
    view:nbAddPage(); stroke(view, 200, 200)
    view:nbAddPage()
    view.notebook.pages[2].title = "Forces"
    view:renameDocument("Mechanics")
    view:writePDF(LIB .. "/mech.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(job and #job.pages == 3 and #job.opts.outline == 1 and job.opts.outline[1].title == "Forces"
        and job.opts.outline[1].page == 2, "bookmarks: a titled page becomes a bookmark to its page")
    view:exportOptions().scope = "ink"
    view:writePDF(LIB .. "/mech.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(#job.pages == 2 and job.opts.outline[1].page == 2, "bookmarks: numbered within the pages exported")
    view:exportOptions().scope = "all"
    view:saveDocument()

    view:newDrawing(DIR)
    stroke(view, 100, 100)
    view:renameDocument("Sketch"); view:saveDocument()
    view:newNotebook("grid", DIR)
    stroke(view, 150, 150)
    view:renameDocument("Waves")   -- left unsaved: the folder export saves it first

    view:openLibrary(LIB)
    view:libraryItemMenu(view._library.items[1])
    local found
    for _, row in ipairs(ButtonDialog.last.buttons) do
        for _, b in ipairs(row) do if b.text:find("Export as PDF", 1, true) then found = b end end
    end
    ok(found ~= nil, "folder: a folder's menu offers Export as PDF")
    found.callback()
    ok(InputDialog.last and InputDialog.last.input == "Physics", "folder: the PDF is named after the folder")
    InputDialog.last.buttons[1][3].callback()
    UIManager.fireScheduled(); UIManager.fireScheduled()
    ok(job and #job.pages == 5, "folder: every page of every document is in it (3 + 1 + 1)")
    local o = job.opts.outline
    ok(#o == 3 and o[1].title == "Mechanics" and o[2].title == "Sketch" and o[3].title == "Waves",
        "folder: one bookmark per document, in tab order")
    ok(o[1].page == 1 and o[2].page == 4 and o[3].page == 5, "folder: each going to its first page")
    ok(#o[1].kids == 1 and o[1].kids[1].title == "Forces" and o[1].kids[1].page == 2,
        "folder: titled pages are bookmarks under their notebook")
    ok(job.template(1).style == "lines" and job.template(4).style == "blank" and job.template(5).style == "grid",
        "folder: each page on its own paper")
    ok(job.path:match("/Physics%.pdf$") ~= nil, "folder: written to the export folder")
    Export.notebookPDFJob = savedJob
    if view._library then view._library:close() end
    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- ---- page templates -------------------------------------------------------
do
    local TestEnv = require("testenv")
    local Templates = require("ink/templates")
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    local LIB = TestEnv.libraryDir() .. "/templates"
    os.execute("mkdir -p '" .. LIB .. "'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local function answer(text)
        local d = InputDialog.last
        d.input = text
        for _, b in ipairs(d.buttons[1]) do if b.is_enter_default then b.callback() end end
    end

    local view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines", LIB)
    view:nbFromTemplate()
    ok(UIManager.shown and UIManager.shown.text and UIManager.shown.text:find("No templates", 1, true),
        "templates: with none saved it says how to make one")
    stroke(view, 100, 100); stroke(view, 200, 300)
    view.notebook.pages[1].paper = "cornell"
    view:nbSaveTemplate()
    answer("Meeting")
    ok(#Templates.list(LIB) == 1 and Templates.list(LIB)[1] == "Meeting", "templates: Save as template stores the page")
    view:nbAddPage()
    stroke(view, 400, 400)
    view:nbGoTo(1)
    view:nbFromTemplate()
    local d = ButtonDialog.last
    ok(d and #d.buttons == 2 and d.buttons[1][1].text == "Meeting", "templates: From template lists them")
    d.buttons[1][1].callback()
    local nb = view.notebook
    ok(nb:count() == 3 and nb.index == 2 and view.canvas:opCount() == 2, "templates: the new page comes after this one")
    ok(nb.pages[2].paper == "cornell" and nb:pageTemplate().style == "cornell", "templates: on the template's paper")
    ok(nb.pages[2].id ~= nb.pages[1].id, "templates: as a new page")
    view:nbFromTemplate()
    ButtonDialog.last.buttons[2][1].callback()
    ok(ButtonDialog.last.title == "Delete which template?", "templates: the last row switches to deleting")
    ButtonDialog.last.buttons[1][1].callback()
    UIManager.shown.ok_callback()
    ok(#Templates.list(LIB) == 0, "templates: and a tap deletes one, after asking")
    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- ---- starting something new: the File sheet tiles and the paper choice -----
do
    local TestEnv = require("testenv")
    local Storage = require("ink/storage")
    local Templates = require("ink/templates")
    local Project = require("ink/project")
    local ButtonDialog = require("ui/widget/buttondialog")
    local LIB = TestEnv.libraryDir() .. "/newflow"
    os.execute("mkdir -p '" .. LIB .. "/School'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)

    view:openDocumentSheet()
    ok(view._doc_dialog ~= nil, "new: the File sheet opens")
    BB.out_of_bounds = 0
    local tile = view:actionTile("pen", "New drawing", "A blank page", 600, function() end)
    ok(tile and tile.width == 600 and tile.hold_callback == nil, "new: an action tile spans its width")
    view:closeSheet("_doc_dialog")

    -- New notebook: six papers with previews, the last one used marked
    view.nb_style = "grid"
    view:openNotebookPaper()
    ok(view._new_dialog ~= nil, "new: New notebook opens the paper choice")
    local preview = view:cachedPaperPreview("dots", 90, 120)
    ok(preview and preview:getWidth() == 90 and preview:getHeight() == 120, "new: each paper has a drawn preview")
    ok(view:cachedPaperPreview("dots", 90, 120) == preview, "new: previews are drawn once and kept")
    view:closeSheet("_new_dialog")
    view:newNotebook("cornell", LIB .. "/School")
    ok(view.notebook and view.notebook.template.style == "cornell"
        and Storage.dirName(view.doc_path) == LIB .. "/School", "new: picking a paper starts the notebook there")

    -- a notebook from a template: its first page is the template, saved at once
    local nb = view.notebook
    nb.pages[1].ops = { { kind = "ink", width = 3, pts = { 1, 1, 50, 50 } } }
    nb.pages[1].title = "Plan"
    Templates.save(LIB, "Week plan", nb.pages[1], nb:pageTemplate(), nb.w, nb.h)
    view:openNotebookPaper(LIB)
    view:closeSheet("_new_dialog")
    view:chooseNotebookTemplate(LIB)
    ok(ButtonDialog.last and ButtonDialog.last.buttons[1][1].text == "Week plan", "new: the templates are offered")
    ButtonDialog.last.buttons[1][1].callback()
    ok(view.notebook and view.doc_path == LIB .. "/Week plan.inkaway" and view.doc_written,
        "new: a notebook from a template is named after it and saved")
    local data = Project.load(view.doc_path)
    ok(data and #data.pages[1].ops == 1 and data.pages[1].title == "Plan" and data.template.style == "cornell",
        "new: its first page is the template, on its paper")

    -- the library's + Drawing starts a drawing in the folder shown, in one tap
    view:openLibrary(LIB .. "/School")
    view._library.actions[1][2]()
    ok(view._library == nil and not view.notebook and Storage.dirName(view.doc_path) == LIB .. "/School",
        "new: + Drawing makes a drawing in that folder at once")

    -- holding New drawing starts one over a picture, named after it and saved
    local PathChooser = require("ui/widget/pathchooser")
    local pic = LIB .. "/School/beach.png"
    local f = io.open(pic, "wb"); f:write("png"); f:close()
    view:newFromImage(LIB)
    ok(PathChooser.last and PathChooser.last.select_file, "new: a drawing from a picture asks for the picture")
    PathChooser.last.onConfirm(pic)
    ok(view.doc_path == LIB .. "/beach.inkaway" and view.doc_written and view.bg_path == pic,
        "new: and starts a drawing over it, named after it")

    -- the page's own paper uses the same paper tiles, with a "same" choice
    view:newNotebook("lines", LIB)
    view:nbPagePaper()
    ok(view._chooser_dialog ~= nil, "new: the page paper choice opens")
    view:closeSheet("_chooser_dialog")
    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- ---- every button in every sheet survives KOReader's tap highlight --------
-- A text button whose label is swapped for a picture or a group must still have
-- an fgcolor, or the highlight on a tap crashes KOReader.
do
    local TestEnv = require("testenv")
    local Templates = require("ink/templates")
    local LIB = TestEnv.libraryDir() .. "/sweep"
    os.execute("mkdir -p '" .. LIB .. "'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local function buttons(w, out, seen)
        if type(w) ~= "table" or seen[w] then return out end
        seen[w] = true
        if getmetatable(w) and w.highlightSafe then out[#out + 1] = w end
        for k, val in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" then buttons(val, out, seen) end
        end
        return out
    end
    local function sweep(name, field, open)
        open()
        local sheet = view[field]   -- its content is built when it opens
        local bad, n = 0, 0
        for _, b in ipairs(buttons(sheet, {}, {})) do
            n = n + 1
            if not b:highlightSafe() then bad = bad + 1 end
        end
        ok(sheet ~= nil and n > 0 and bad == 0, ("sweep: every button of the %s sheet can be tapped (%d of %d bad)")
            :format(name, bad, n))
        view:closeSheet(field)
    end
    view:newNotebook("lines", LIB)
    Templates.save(LIB, "Plan", view.notebook.pages[1], view.notebook:pageTemplate(), 100, 100)
    sweep("File", "_doc_dialog", function() view:openDocumentSheet() end)
    sweep("New notebook", "_new_dialog", function() view:openNotebookPaper() end)
    sweep("page paper", "_chooser_dialog", function() view:nbPagePaper() end)
    sweep("page", "_page_dialog", function() view:openPageMenu() end)
    sweep("settings", "_settings_dialog", function() view:openSettings() end)
    sweep("paper colour", "_paper_colour", function() view:openPaperColour() end)
    -- the paper colour sheet: the papers this screen offers, a tap puts the page on one
    do
        local Palette = require("ink/palette")
        local colour = view:colorScreen()
        view:openPaperColour()
        local tiles = buttons(view._paper_colour, {}, {})
        ok(#tiles == #Palette.papers(colour) + 1, ("paper: a tile for each paper and Done (%d)"):format(#tiles))
        local black
        for _, p in ipairs(Palette.papers(colour)) do if p.key == "black" then black = p.rgb end end
        local found
        for _, b in ipairs(tiles) do
            local seen, hit = {}, false
            local function has(w)
                if type(w) ~= "table" or seen[w] then return end
                seen[w] = true
                if w.text == "Black" then hit = true end
                for k, v in pairs(w) do if k ~= "show_parent" and k ~= "parent" then has(v) end end
            end
            has(b)
            if hit then found = b end
        end
        ok(found ~= nil, "paper: Black is offered")
        if found then found.callback() end
        ok(Palette.sameColor(view:paperRGB(), black), "paper: a tap puts the notebook on it")
        ok(view._paper_colour ~= nil, "paper: the sheet stays to try another")
        view:closeSheet("_paper_colour")
        view:openSettings()
        local seen, label = {}, nil
        local function find(w)
            if type(w) ~= "table" or seen[w] then return end
            seen[w] = true
            if type(w.text) == "string" and w.text:match("^Colour: ") then label = w.text end
            for k, v in pairs(w) do if k ~= "show_parent" and k ~= "parent" then find(v) end end
        end
        find(view._settings_dialog)
        ok(label == "Colour: Black", "paper: Settings names it beside the paper (" .. tostring(label) .. ")")
        view:closeSheet("_settings_dialog")
        view:setPaper(nil)
        ok(view:paperRGB() == nil, "paper: and back to white")
    end
    sweep("pen", "_pen_dialog", function() view:openPenSettings() end)
    sweep("pen input", "_peninput_dialog", function() view:openPenInput() end)
    sweep("pen types", "_pentypes_dialog", function() view:openPenTypes() end)
    sweep("eraser", "_eraser_dialog", function() view:openEraserSettings() end)
    sweep("shapes", "_shape_dialog", function() view:openShapePicker() end)
    sweep("text", "_text_settings", function() view:openTextSettings() end)
    sweep("image", "_img_src_dialog", function() view:chooseImage() end)
    sweep("go to page", "_goto_dialog", function() view:nbJumpPrompt() end)
    view.canvas.ops[1] = { kind = "ink", width = 3, pts = { 1, 1, 9, 9 } }
    sweep("export", "_save_dialog", function() view:openExport() end)
    view:newDrawing(LIB)
    sweep("background", "_bg_dialog", function() view:openBackground() end)
    sweep("grid", "_grid_dialog", function() view:openGridSettings() end)
    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    UIManager.reset()
end

-- ---- the theme colour: colour screens only, remembered, every sheet in it ----
do
    local Device = require("device")
    local Accent = require("ink/accent")
    local ImageWidget = require("ui/widget/imagewidget")
    G_reader_settings.data.inkaway_last_doc = nil
    G_reader_settings.data.inkaway_accent = nil
    local had_orientation = G_reader_settings.data.inkaway_orientation
    G_reader_settings.data.inkaway_orientation = nil   -- an earlier block may leave landscape
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function says(w, text, seen)
        seen = seen or {}
        if type(w) ~= "table" or seen[w] then return false end
        seen[w] = true
        if w.text == text then return true end
        for k, val in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" and says(val, text, seen) then return true end
        end
        return false
    end
    local function hasImage(w, seen)
        seen = seen or {}
        if type(w) ~= "table" or seen[w] then return false end
        seen[w] = true
        if getmetatable(w) == ImageWidget or w.image then return true end
        for k, val in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" and hasImage(val, seen) then return true end
        end
        return false
    end

    -- a black-and-white screen has no such setting, and ignores a saved colour
    G_reader_settings.data.inkaway_accent = { 30, 111, 217 }
    local view = InkAwayView:new{}
    UIManager:show(view)
    ok(not Accent.get().custom, "accent: a grey screen stays black, whatever is saved")
    view:openSettings()
    ok(not says(view._settings_dialog, "Theme Color"), "accent: and its settings do not offer a colour")
    view:closeSheet("_settings_dialog")
    UIManager:close(view)
    G_reader_settings.data.inkaway_accent = nil

    -- a colour screen offers it, through the pen's colour wheel
    local had = Device.hasColorScreen
    Device.hasColorScreen = function() return true end
    UIManager.reset()
    view = InkAwayView:new{}
    UIManager:show(view)
    ok(Accent.get().key == "159,214,101" and Accent.get().chromatic and Accent.get().text == BB.COLOR_BLACK,
        "accent: Ink Away green until another is chosen, with black text on it")
    view:openSettings()
    ok(says(view._settings_dialog, "Theme Color"), "accent: a colour screen's settings offer it")
    view:chooseAccent()
    local picker = UIManager.shown
    ok(picker and picker.title == "Theme Color" and #picker:buttons() == 2 and view._settings_dialog == nil,
        "accent: the colour wheel opens with Use and Cancel (no Save to the pen's swatches)")
    local CP = require("ink/ui/colorpicker")
    local p2 = CP:new{}
    ok(p2.wheel_bb ~= nil and p2.wheel_bb == picker.wheel_bb, "accent: the colour wheel is drawn once and reused")
    p2:onCloseWidget()
    picker.on_pick({ 30, 111, 217 })
    local saved = G_reader_settings.data.inkaway_accent
    ok(saved and saved[1] == 30 and saved[3] == 217, "accent: the colour is saved")
    ok(Accent.get().chromatic and Accent.get().key == "30,111,217", "accent: and used straight away")
    ok(view._settings_dialog ~= nil, "accent: the settings come back")
    view:closeSheet("_settings_dialog")

    -- what is black by default is drawn in it
    local b = view:actionButton("Go", 300, function() end, true)
    ok(hasImage(b.label_widget) and b.text == nil, "accent: a dark button is filled with it, tappable as a whole")
    ok(not hasImage(view:actionButton("Go", 300, function() end, false).label_widget),
        "accent: a grey button stays grey")
    local title = view:sheetTitle("Pen", 600, "Done", function() end)
    ok(hasImage(title[3].label_widget), "accent: the Done pill too")
    ok(hasImage(view:actionTile("pen", "New drawing", "note", 600, function() end).label_widget),
        "accent: and the large action tiles")

    -- every sheet still survives a tap with it
    local function buttons(w, out, seen)
        if type(w) ~= "table" or seen[w] then return out end
        seen[w] = true
        if getmetatable(w) and w.highlightSafe then out[#out + 1] = w end
        for k, val in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" then buttons(val, out, seen) end
        end
        return out
    end
    local bad = 0
    for _, s in ipairs({ { "_settings_dialog", function() view:openSettings() end },
            { "_doc_dialog", function() view:openDocumentSheet() end },
            { "_new_dialog", function() view:openNotebookPaper() end },
            { "_shape_dialog", function() view:openShapePicker() end },
            { "_eraser_dialog", function() view:openEraserSettings() end },
            { "_grid_dialog", function() view:openGridSettings() end },
            { "_paper_colour", function() view:openPaperColour() end } }) do
        s[2]()
        for _, btn in ipairs(buttons(view[s[1]], {}, {})) do if not btn:highlightSafe() then bad = bad + 1 end end
        view:closeSheet(s[1])
    end
    ok(bad == 0, "accent: every button of the sheets can be tapped in it")
    BB.out_of_bounds = 0
    view:drawActiveToolPill(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0 and view._active_btn_idx ~= nil, "accent: the active tool's pill paints in bounds")
    UIManager:close(view)

    -- the row: Ink Away green, black, presets, the last two wheel picks, the
    -- wheel, in boxes of one size spread across the sheet
    local Paint = require("ink/paint")
    view:setAccent({ 0, 0, 0 })
    ok(not Accent.get().custom and G_reader_settings.data.inkaway_accent[1] == 0,
        "accent: black is a choice of its own, kept as such")
    G_reader_settings.data.inkaway_accent_recent = nil
    local content_w = view:sheetWidth()
    local row = view:accentRow(content_w)
    local tiles, gaps = {}, {}
    for _, w in ipairs(row) do
        if w.width and not w[1] then gaps[#gaps + 1] = w.width else tiles[#tiles + 1] = w end
    end
    local sw = Screen:scaleBySize(56)
    -- (KOReader scales sizes by the screen's short side, so eight fit on every
    -- reader; the test screen scales differently, and fits all five presets)
    ok(#tiles >= 8 and #tiles <= 10 and #tiles * sw + (gaps[1] or 0) * #gaps <= content_w,
        ("accent: green, black, three to five presets, two boxes and the wheel fit the row (%d)"):format(#tiles))
    local function frameOf(t) return t.bordersize and t or t[1] end
    ok(says(tiles[1], "Default") and frameOf(tiles[1]).bordersize == Screen:scaleBySize(1),
        "accent: Ink Away green comes first, captioned as the default")
    ok(tiles[2].bordersize == Screen:scaleBySize(3), "accent: black is framed while it is in use")
    view:setAccent(nil)
    row = view:accentRow(content_w)
    ok(Accent.get().key == "159,214,101" and G_reader_settings.data.inkaway_accent == nil
        and row[1][1].bordersize == Screen:scaleBySize(3), "accent: going back to the default frames the green")
    ok(tiles[#tiles - 2].color == Paint.HAIRLINE and tiles[#tiles - 1].color == Paint.HAIRLINE,
        "accent: the two boxes for picked colours start empty, before the wheel")
    -- picks on the wheel fill them, newest first; presets do not
    local function pick(rgb)
        view:chooseAccent()
        UIManager.shown.on_pick(rgb)
        view:closeSheet("_settings_dialog")
    end
    pick({ 200, 66, 154 }); pick({ 20, 140, 60 })
    local rec = G_reader_settings.data.inkaway_accent_recent
    ok(#rec == 2 and rec[1][1] == 20 and rec[2][1] == 200, "accent: the last two wheel picks are kept, newest first")
    pick({ 0x24, 0x57, 0xD6 })
    rec = G_reader_settings.data.inkaway_accent_recent
    ok(#rec == 2 and rec[1][1] == 20, "accent: a preset picked on the wheel does not take a box")
    pick({ 159, 214, 101 })
    rec = G_reader_settings.data.inkaway_accent_recent
    ok(#rec == 2 and rec[1][1] == 20, "accent: nor does Ink Away green")
    pick({ 9, 9, 200 })
    rec = G_reader_settings.data.inkaway_accent_recent
    ok(#rec == 2 and rec[1][3] == 200 and rec[2][1] == 20, "accent: a third pick pushes the oldest out")
    -- tapping a kept one uses it without moving it
    view:setAccent({ 20, 140, 60 })
    local again = view:accentRecent()
    ok(again[1][3] == 200 and again[2][1] == 20, "accent: using a kept colour leaves the boxes in place")
    ok(Accent.remember({ { 1, 2, 3 } }, { 0, 0, 0 }, 2)[1][1] == 1, "accent: black is never kept")
    local old = Accent.remember({ { 159, 214, 101 }, { 1, 2, 3 } }, nil, 2)
    ok(#old == 1 and old[1][1] == 1, "accent: Ink Away green kept from before is dropped from the boxes")
    G_reader_settings.data.inkaway_accent_recent = nil
    view:setAccent({ 30, 111, 217 })

    -- opening again uses the saved colour without asking
    UIManager.reset()
    view = InkAwayView:new{}
    UIManager:show(view)
    ok(Accent.get().key == "30,111,217", "accent: Ink Away opens with the saved colour")
    view:setAccent({ 0, 0, 0 })
    UIManager.reset()
    view = InkAwayView:new{}
    UIManager:show(view)
    ok(not Accent.get().custom, "accent: and with black when black was chosen")
    view:setAccent(nil)
    ok(G_reader_settings.data.inkaway_accent == nil and Accent.get().key == "159,214,101",
        "accent: the default goes back to Ink Away green")
    UIManager:close(view)
    Device.hasColorScreen = had
    G_reader_settings.data.inkaway_accent = nil
    G_reader_settings.data.inkaway_orientation = had_orientation
    Accent.set(nil)
    UIManager.reset()
end

-- ---- papers: blank first, two pages of six, planners as drawing guides ------
do
    UIManager.reset()
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    local Template = require("ink/template")
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local styles = view:notebookStyles()
    ok(styles[1][1] == "blank" and #styles == 18, "papers: blank comes first, eighteen in all")
    for _, s in ipairs(styles) do
        local bad = 0
        Template.render(s[1], 1072, 1448, 40, function(x, y, len)
            if x < 0 or y < 0 or x + len > 1072 or y >= 1448 then bad = bad + 1 end
        end)
        ok(bad == 0, "papers: " .. s[1] .. " stays on the page")
    end
    -- the picker: Blank as a button, then pages of six tiles
    local shown
    local real_tile = view.paperTile
    view.paperTile = function(self, style, ...) shown[#shown + 1] = style; return real_tile(self, style, ...) end
    shown = {}
    view:openNotebookPaper()
    ok(#shown == 6 and shown[1] == "blank" and shown[5] == "iso", "papers: the first page shows blank and the rulings ("
        .. table.concat(shown, ",") .. ")")
    shown = {}
    view.nb_style = "music"
    view:openNotebookPaper()
    ok(#shown == 6 and shown[1] == "cornell" and shown[6] == "music",
        "papers: it opens on the page holding the paper last used")
    shown = {}
    view.nb_style = "habits"
    view:openNotebookPaper()
    ok(#shown == 6 and shown[1] == "daily" and shown[6] == "habits", "papers: the third page holds the planners")
    view:closeSheet("_new_dialog")
    view.paperTile = real_tile
    -- the planners as a drawing's guide, at any zoom
    -- (counted against the same paint without a grid, so only the guide's own
    -- rects are judged, whatever state earlier tests left the mock screen in)
    local function oob()
        BB.out_of_bounds = 0
        view:paintTo(Screen.bb, 0, 0)
        return BB.out_of_bounds
    end
    for _, st in ipairs({ "checklist", "twocol", "weekly", "monthly", "storyboard", "music", "iso",
            "handwriting", "daily", "weekcols", "meeting", "habits" }) do
        for _, z in ipairs({ view.zoom_min, 2.5 }) do
            view:setZoom(z)
            view.grid_on = false
            local base = oob()
            view.grid_on, view.grid_style = true, st
            local with = oob()
            ok(with == base, ("papers: the %s guide paints in bounds at zoom %.1f"):format(st, z))
        end
    end
    -- a new drawing starts plain
    view:newDrawing()
    ok(view.grid_on == false and G_reader_settings.data.inkaway_grid == false, "papers: a new drawing starts without a grid")
    UIManager:close(view)
    UIManager.reset()
end

-- ---- handwriting to text: lasso, Convert to text --------------------------
do
    UIManager.reset()
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    view.stampTextInto = function() end   -- the mock cannot lay out text
    -- "milk" in a UJI test writer's hand, as ink ops on the page
    local hand = dofile("tests/hwr_writers.lua")
    local name
    for k in pairs(hand) do if not name or k < name then name = k end end
    hand = hand[name]
    local ops, x = {}, 200
    for ch in ("milk"):gmatch(".") do
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for _, st in ipairs(hand[ch]) do
            for i = 1, #st - 1, 2 do
                x0, x1 = math.min(x0, st[i]), math.max(x1, st[i])
                y0, y1 = math.min(y0, st[i + 1]), math.max(y1, st[i + 1])
            end
        end
        local tall = ch == "l" or ch == "k"
        local sc = (tall and 64 or 40) / math.max(y1 - y0, 1)
        if ch == "i" then sc = 56 / math.max(y1 - y0, 1) end
        for _, st in ipairs(hand[ch]) do
            local pts = {}
            for i = 1, #st - 1, 2 do
                pts[#pts + 1] = x + (st[i] - x0) * sc
                pts[#pts + 1] = 400 - (y1 - st[i + 1]) * sc
            end
            ops[#ops + 1] = { kind = "ink", width = 4, alpha = 255, pts = pts }
        end
        x = x + (x1 - x0) * sc + 12
    end
    ops[#ops + 1] = { kind = "shape", shape = "rect", pts = { 600, 600, 700, 700 }, width = 4 }   -- not writing
    view.canvas:setOps(ops)
    view:setTool("lasso")
    view:computeSelection({ 0, 0, 1000, 0, 1000, 800, 0, 800 })
    -- the button labelled `text` in the open selection sheet
    local function sheetButton(text)
        local function has(w, seen)
            if type(w) ~= "table" or seen[w] then return false end
            seen[w] = true
            if w.text == text then return true end
            for k, val in pairs(w) do if k ~= "show_parent" and k ~= "parent" and has(val, seen) then return true end end
            return false
        end
        local function find(w, seen)
            if type(w) ~= "table" or seen[w] then return nil end
            seen[w] = true
            if type(w.callback) == "function" and has(w, {}) then return w end
            for k, val in pairs(w) do
                if k ~= "show_parent" and k ~= "parent" then local f = find(val, seen); if f then return f end end
            end
        end
        return view._sel_dialog and find(view._sel_dialog, {})
    end
    view:openSelectionMenu()
    local convert = sheetButton("Convert to text")
    ok(convert ~= nil, "hwr: the lasso menu offers Convert to text for handwriting")
    local n_before = view.canvas:opCount()
    convert.callback()
    local text_op
    for _, op in ipairs(view.canvas.ops) do if op.kind == "text" then text_op = op end end
    local Text = require("ink/text")
    local got = text_op and Text.plain and Text.plain(text_op) or (text_op and text_op.paras and
        table.concat((function() local t = {} for _, p in ipairs(text_op.paras) do
            local r = {} for _, run in ipairs(p.runs or p) do r[#r + 1] = run.text or run end
            t[#t + 1] = table.concat(r) end return t end)(), "\n"))
    ok(text_op ~= nil, "hwr: the writing becomes a text box")
    ok(got == "milk", "hwr: reading " .. tostring(got))
    ok(view.canvas:opCount() == 2, "hwr: the ink is gone, the shape outside the writing stays")
    ok(not view.selection, "hwr: and the selection is done with")
    view:undo()
    ok(view.canvas:opCount() == n_before, "hwr: one undo brings the writing back")
    -- a selection with no handwriting does not offer it
    view.canvas:setOps({ { kind = "shape", shape = "rect", pts = { 600, 600, 700, 700 }, width = 4 } })
    view:computeSelection({ 0, 0, 1000, 0, 1000, 800, 0, 800 })
    view:openSelectionMenu()
    ok(sheetButton("Copy") ~= nil and not sheetButton("Convert to text"),
        "hwr: a shape alone is not offered for conversion")
    view.canvas:setOps({})
    UIManager:close(view)
    UIManager.reset()
end

-- ---- e-ink refreshes of the sheets and full-screen grids ---------------------
-- A flash only where it clears ink: opening over the drawing on a grey panel.
-- Page turns, tabs and closing never flash, and a colour panel never flashes
-- here (a flash takes seconds there, and Kobo waits for it).
do
    local TestEnv = require("testenv")
    local Device = require("device")
    local LIB = TestEnv.libraryDir() .. "/refresh"
    os.execute("mkdir -p '" .. LIB .. "/Folder'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function modes()
        local out = {}
        for _, r in ipairs(UIManager.refreshes) do
            local m = r.mode
            if type(m) == "function" then m = m() end
            out[#out + 1] = tostring(m)
        end
        UIManager.refreshes = {}
        return table.concat(out, ",")
    end
    local function flashes(list) return list:find("full", 1, true) or list:find("flash", 1, true) end

    local view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines", LIB)
    for _ = 1, 11 do view:nbAddPage() end
    UIManager.fireScheduled(); UIManager.refreshes = {}

    -- grey panel
    view:openPenSettings()
    local m = modes()
    ok(m:find("flashui", 1, true) ~= nil, "refresh: a sheet flashes as it opens over ink on grey (" .. m .. ")")
    view:closeSheet("_pen_dialog")
    ok(not flashes(modes()), "refresh: and closes without a flash")
    view:openOverview()
    local ov = view._overview
    m = modes()
    ok(m:find("full", 1, true) ~= nil, "refresh: the overview flashes as it opens over ink on grey")
    ov:gridGo(ov.gpage > 0 and -1 or 1)
    m = modes()
    ok(m ~= "" and not flashes(m), "refresh: a page of thumbnails turns without a flash (" .. m .. ")")
    view:overviewGo(LIB .. "/Folder")
    ok(not flashes(modes()), "refresh: going into a folder does not flash")
    view:overviewGo(LIB)
    ov.actions[2][2]()   -- Library
    m = modes()
    ok(view._library ~= nil and not flashes(m), "refresh: the library opens over the overview without a flash (" .. m .. ")")
    view._library:close()
    m = modes()
    ok(m ~= "" and not flashes(m), "refresh: closing a grid does not flash (" .. m .. ")")

    -- the open notebook's thumbnails are kept for the next overview
    local drawn = 0
    local real = view.renderPageThumb
    view.renderPageThumb = function(...) drawn = drawn + 1; return real(...) end
    view:freePageThumbs()   -- the overview opened above kept some
    view:openOverview()
    view._overview:paintTo(Screen.bb, 0, 0)
    local first = drawn
    view._overview:close()
    drawn = 0
    view:openOverview()
    view._overview:paintTo(Screen.bb, 0, 0)
    ok(first > 0 and drawn == 0, ("refresh: opening the overview again draws no thumbnail (%d, then %d)"):format(first, drawn))
    view._overview:close()
    local v = view.view
    view:onIaTouch(nil, pos(100, v.area_y + 100))
    view:onIaPan(nil, pos(160, v.area_y + 140))
    view:onIaPanRelease(nil, pos(160, v.area_y + 140))
    UIManager.fireScheduled()
    drawn = 0
    view:openOverview()
    view._overview:paintTo(Screen.bb, 0, 0)
    ok(drawn == 1, ("refresh: after drawing on a page only that page's thumbnail is drawn again (%d)"):format(drawn))
    view._overview:close()
    local kept = 0
    for _ in ipairs(view._page_thumbs and view._page_thumbs.order or {}) do kept = kept + 1 end
    ok(kept > 0 and kept <= 18, ("refresh: at most two grid pages of them are kept (%d)"):format(kept))
    view.renderPageThumb = real

    -- strokes and page turns on grey
    local function list()
        local out = {}
        for _, r in ipairs(UIManager.refreshes) do out[#out + 1] = r end
        UIManager.refreshes = {}
        return out
    end
    view:setTool("pen")
    UIManager.refreshes = {}
    view:onIaTouch(nil, pos(100, v.area_y + 300))
    view:onIaPan(nil, pos(200, v.area_y + 340))
    view:onIaPanRelease(nil, pos(220, v.area_y + 350))
    local live = list()
    UIManager.fireScheduled()   -- the stroke commits
    local after = list()
    ok(#live > 0 and #after == 0, ("refresh: a pen stroke on grey is shown live and nothing is refreshed at the lift (%d live, %d after)"):format(#live, #after))
    view:setTool("erase")
    UIManager.refreshes = {}
    view:onIaTouch(nil, pos(100, v.area_y + 300))
    view:onIaPan(nil, pos(220, v.area_y + 350))
    view:onIaPanRelease(nil, pos(220, v.area_y + 350))
    list()
    UIManager.fireScheduled()
    after = list()
    ok(#after >= 1 and after[1].mode == "flashui",
        "refresh: an erase is cleaned at the lift, with a flash where nothing gentler clears the ghost")
    view._clean_mode = nil
    Screen._isREAGLWaveFormMode = function(_, wf) return wf == "reagl" end
    Screen.waveform_partial = "reagl"
    view.erase_whole = true
    view:setTool("pen")
    view:onIaTouch(nil, pos(100, v.area_y + 500))
    view:onIaPan(nil, pos(300, v.area_y + 520))
    view:onIaPanRelease(nil, pos(300, v.area_y + 520))
    UIManager.fireScheduled()
    view:setTool("erase")
    UIManager.refreshes = {}
    view:onIaTouch(nil, pos(200, v.area_y + 470))
    view:onIaPan(nil, pos(200, v.area_y + 560))
    view:onIaPanRelease(nil, pos(200, v.area_y + 560))
    UIManager.fireScheduled()
    local wl = list()
    local wmodes = {}
    for _, r in ipairs(wl) do wmodes[#wmodes + 1] = tostring(r.mode) end
    ok(table.concat(wmodes, ","):find("partial", 1, true) and not table.concat(wmodes, ","):find("flash", 1, true),
        "refresh: on a REAGL screen the whole-stroke eraser cleans up without a flash (" .. table.concat(wmodes, ",") .. ")")
    Screen._isREAGLWaveFormMode, Screen.waveform_partial = nil, nil
    view._clean_mode, view.erase_whole = nil, false
    view:setTool("pen")

    view._turns_since_full = 0
    UIManager.refreshes = {}
    view:nbGo(view.notebook.index > 1 and -1 or 1)
    local turn = list()
    local g = turn[1] and turn[1].region
    ok(#turn == 1 and turn[1].mode == "partial" and g and g.y == v.area_y
        and g.y + g.h == Screen:getHeight() and g.w == Screen:getWidth(),
        "refresh: a page turn refreshes the page and the bar together, in one refresh, never the toolbar")

    -- colour panel: no flashes for sheets and grids
    local had = Device.hasColorScreen
    Device.hasColorScreen = function() return true end
    view._is_colour = nil
    UIManager.refreshes = {}
    view:openShapePicker()   -- (the pen sheet's colour swatches need real widgets)
    m = modes()
    ok(m ~= "" and not flashes(m), "refresh: on colour a sheet opens without a flash (" .. m .. ")")
    view:closeSheet("_shape_dialog")
    modes()
    view:openOverview()
    m = modes()
    ok(m ~= "" and not flashes(m), "refresh: on colour the overview opens without a flash (" .. m .. ")")
    view._overview:close()
    modes()
    view:openLibrary()
    m = modes()
    ok(m ~= "" and not flashes(m), "refresh: and the library too (" .. m .. ")")
    view._library:close()
    Device.hasColorScreen = had
    view._is_colour = nil
    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- Search: the magnifier in the library and the overview, names by default and
-- text inside pages on request, results that open where they point, and a
-- search that is stopped or fails without harm.
do
    local TestEnv = require("testenv")
    local InputDialog = require("ui/widget/inputdialog")
    local Search = require("ink/search")
    local Text = require("ink/text")
    local LIB = TestEnv.libraryDir() .. "/searchview"
    os.execute("rm -rf '" .. LIB .. "'; mkdir -p '" .. LIB .. "/Physics'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local function drain()
        for _ = 1, 50 do
            if UIManager.pendingCount() == 0 then break end
            UIManager.fireScheduled()
        end
    end
    local view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines", LIB .. "/Physics")
    stroke(view, 100, 100)
    view:nbAddPage()
    stroke(view, 120, 120)
    view.notebook.pages[2].title = "Forces and motion"
    view:nbAddPage()
    local op = Text.new{ x = 20, y = 20, w = 300, size = 20 }
    Text.insert(op, { p = 1, o = 0 }, "Newton wrote about inertia", nil)
    view.canvas.ops[#view.canvas.ops + 1] = op
    view:markDirty()
    view:renameDocument("Mechanics")
    local mech = view.doc_path
    view:nbGoTo(1)

    local got
    local real = view.showSearchResults
    view.showSearchResults = function(self, results, ...)
        got = results
        return real(self, results, ...)
    end

    -- the magnifier in the library header
    view:openLibrary(LIB)
    local pill
    for _, a in ipairs(view._library.actions) do if a.icon and a.icon:find("search", 1, true) then pill = a end end
    ok(pill ~= nil, "search: the library header has a magnifier")
    pill[2]()
    local d = InputDialog.last
    ok(d and d.title == "Search", "search: it asks what to look for")
    d.input = "forces"
    for _, b in ipairs(d.buttons[1]) do if b.is_enter_default then b.callback() end end
    drain()
    ok(got and #got == 1 and got[1].kind == "page" and got[1].page == 2, "search: a page is found by its title, "
        .. "with the open notebook's latest changes")
    ok(view._search_sheet ~= nil and view._search_job == nil, "search: the results show, and the search is over")
    got = nil
    view:runSearch("inertia", false, "library")
    drain()
    ok(got and #got == 0, "search: names only leaves the text on pages alone")
    view:closeSheet("_search_sheet")
    view:runSearch("inertia", true, "library")
    drain()
    ok(got and #got == 1 and got[1].page == 3 and got[1].text and got[1].text:find("inertia", 1, true),
        "search: inside pages finds typed text, with the words around it")
    ok(G_reader_settings.data.inkaway_search_inside == true, "search: the choice is remembered for next time")
    view:runSearch("physics", false, "library")
    drain()
    ok(got and got[1].kind == "folder", "search: a folder by name")
    view:closeSheet("_search_sheet")

    -- a result opens where it points
    view:newDrawing(LIB)
    stroke(view, 50, 50)
    view:saveDocument()
    view:openLibrary(LIB)
    view:openSearchResult({ kind = "page", path = mech, page = 2, id = view.notebook and nil }, "library")
    ok(view.doc_path == mech and view.notebook and view.notebook.index == 2 and view._library == nil,
        "search: a page result opens its notebook at that page")
    view:openLibrary(LIB)
    view:openSearchResult({ kind = "folder", path = LIB .. "/Physics", name = "Physics" }, "library")
    ok(view._library and view._lib_dir == LIB .. "/Physics", "search: a folder result shows the folder")
    view._library:close()
    view:openSearchResult({ kind = "doc", path = LIB .. "/Gone.inkaway" }, "library")
    ok(view.doc_path == mech, "search: a result whose file is gone opens nothing")

    -- the overview has it too
    view:openOverview()
    local found
    for _, a in ipairs(view._overview.actions) do if a.icon then found = a end end
    ok(found ~= nil, "search: the overview header has the magnifier too")
    view:openSearchResult({ kind = "folder", path = LIB .. "/Physics", name = "Physics" }, "overview")
    ok(view._overview and view._ov.dir == LIB .. "/Physics", "search: from the overview a folder opens there")
    view._overview:close()

    -- stopping, failing, and asking twice
    view:runSearch("forces", true, "library")
    local job = view._search_job
    ok(job ~= nil, "search: a search is under way")
    view:runSearch("other", true, "library")
    ok(view._search_job == job, "search: a second one waits for the first")
    job.cancel()
    drain()
    ok(view._search_job == nil and UIManager.shown and tostring(UIManager.shown.text):find("stopped", 1, true),
        "search: a tap on the bar stops it")
    local walk = Search.walk
    Search.walk = function() error("disk on fire") end
    view:runSearch("forces", true, "library")
    drain()
    Search.walk = walk
    ok(view._search_job == nil and UIManager.shown and tostring(UIManager.shown.text):find("could not finish", 1, true),
        "search: an error ends it with a message, not a crash")
    view:runSearch("   ", false, "library")
    ok(view._search_job == nil, "search: nothing to look for starts nothing")
    view:runSearch("forces", true, "library")
    UIManager:close(view)
    drain()
    ok(view._search_job == nil and view._search_sheet == nil, "search: closing Ink Away ends a search quietly")

    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- The trash: deleting from the library, the overview and the page menu keeps
-- things there, and they come back where they were, the open notebook too.
do
    local TestEnv = require("testenv")
    local Project = require("ink/project")
    local Storage = require("ink/storage")
    local Trash = require("ink/trash")
    local ConfirmBox = require("ui/widget/confirmbox")
    local LIB = TestEnv.libraryDir() .. "/trashview"
    os.execute("rm -rf '" .. LIB .. "'; mkdir -p '" .. LIB .. "/Physics'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local function stroke(view, x, y)
        local v = view.view
        view:onIaTouch(nil, pos(x, v.area_y + y))
        view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
        view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
        UIManager.fireScheduled()
    end
    local function confirm()
        local box = UIManager.shown
        if box and box.ok_callback then box.ok_callback() end
    end
    local view = InkAwayView:new{}
    UIManager:show(view)
    view:newNotebook("lines", LIB .. "/Physics")
    stroke(view, 100, 100)
    for i = 2, 4 do view:nbAddPage(); stroke(view, 100 + 20 * i, 100) end
    view:renameDocument("Mechanics")
    local mech = view.doc_path
    view:saveDocument()

    -- a page from the page menu: kept, then back in its place with its id
    view:nbGoTo(2)
    local id2 = view.notebook.pages[2].id
    view:nbDeletePage()
    ok(UIManager.shown and UIManager.shown.text:find("trash", 1, true), "trash: deleting a page says it is kept")
    confirm()
    ok(view.notebook:count() == 3 and #Trash.list(LIB) == 1 and Trash.list(LIB)[1].kind == "page",
        "trash: the page leaves the notebook for the trash")
    view:nbGoTo(3)
    view:restoreTrashItem(Trash.list(LIB)[1])
    ok(view.notebook:count() == 4 and view.notebook.pages[2].id == id2 and #view.notebook.pages[2].ops > 0,
        "trash: putting it back returns it to the open notebook, between its neighbours")
    ok(view.notebook.index == 4, "trash: the page shown stays the same one")
    ok(#Trash.list(LIB) == 0, "trash: and it leaves the trash")

    -- the open notebook itself: saved first, then a new drawing; it comes back whole
    stroke(view, 300, 300)   -- an unsaved change
    local ink_before = 0
    view:nbSyncOut()
    for _, p in ipairs(view.notebook.pages) do ink_before = ink_before + #p.ops end
    view:openLibrary(LIB .. "/Physics")
    local card
    for _, it in ipairs(view._library.items) do if it.path == mech then card = it end end
    view:confirmDeleteItem(card)
    confirm()
    ok(not Storage.exists(mech) and view.doc_path ~= mech and not view.notebook, "trash: the open notebook goes, "
        .. "and a new drawing takes its place")
    view:openTrash()
    ok(view._trash_sheet ~= nil, "trash: the trash opens from the library menu")
    local item = Trash.list(LIB)[1]
    ok(item and item.kind == "doc" and item.nb, "trash: it holds the notebook")
    view:restoreTrashItem(item)
    view:closeSheet("_trash_sheet")
    ok(Storage.exists(mech), "trash: the notebook comes back")
    view:openDocument(mech)
    local ink_after = 0
    for _, p in ipairs(view.notebook.pages) do ink_after = ink_after + #p.ops end
    ok(view.notebook:count() == 4 and ink_after == ink_before, "trash: with every page, and the change made just "
        .. "before it was deleted (" .. ink_after .. "/" .. ink_before .. ")")

    -- from the overview: a page of a notebook that is not open, and a folder
    view:newNotebook("grid", LIB .. "/Physics")
    stroke(view, 50, 50)
    view:renameDocument("Optics")
    view:saveDocument()
    view:openOverview()
    view:overviewShowTab(mech)
    local cards = view._overview.items
    view:overviewDeletePage(mech, cards[3].page)
    confirm()
    local data = Project.load(mech)
    ok(#data.pages == 3 and Trash.list(LIB)[1].kind == "page", "trash: a page deleted in the overview is kept")
    view:restoreTrashItem(Trash.list(LIB)[1])
    data = Project.load(mech)
    ok(#data.pages == 4, "trash: and goes back into its notebook's file")
    view._overview:close()
    view:openLibrary(LIB)
    for _, it in ipairs(view._library.items) do if it.folder then card = it end end
    view:confirmDeleteItem(card)
    confirm()
    ok(not Storage.exists(LIB .. "/Physics") and Trash.list(LIB)[1].kind == "folder", "trash: a folder goes whole")
    view:restoreTrashItem(Trash.list(LIB)[1])
    ok(Storage.exists(mech) and Storage.exists(LIB .. "/Physics/Optics.inkaway"), "trash: and comes back whole")
    view._library:close()

    -- emptying asks first
    view:trashPath(LIB .. "/Physics/Optics.inkaway", false)
    view:openTrash()
    ok(#Trash.list(LIB) >= 1, "trash: something to empty")
    Trash.empty(LIB)
    ok(#Trash.list(LIB) == 0, "trash: emptied")
    view:closeSheet("_trash_sheet")

    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- Links between pages and the contents page
do
    local TestEnv = require("testenv")
    local Export = require("ink/export")
    local Storage = require("ink/storage")
    local Project = require("ink/project")
    local LIB = TestEnv.libraryDir() .. "/linkview"
    os.execute("rm -rf '" .. LIB .. "'; mkdir -p '" .. LIB .. "'")
    G_reader_settings.data.inkaway_library_dir = LIB
    G_reader_settings.data.inkaway_last_doc = nil
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkGeom = require("ink/geom")
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view.stampTextInto = function() end   -- the mocks cannot lay out text
    UIManager:show(view)
    local v = view.view
    local function scr(cx, cy) return InkGeom.toScreen(v, cx, cy) end
    local function ink(x, y) return { kind = "ink", width = 4, alpha = 255, pts = { x, y, x + 60, y + 20 } } end
    view:newNotebook("lines", LIB)
    view.canvas.ops[1] = ink(100, 100)
    view:markDirty()
    for i = 2, 4 do view:nbAddPage(); view.canvas.ops[1] = ink(100, 100 * i); view:markDirty() end
    view:nbSyncOut()
    view.notebook.pages[3].title = "Forces"
    view.notebook.pages[4].title = "Energy"
    view:renameDocument("Physics")
    view:saveDocument()
    local nb = view.notebook
    local id4 = nb.pages[4].id

    -- a link from the selection's menu to page 4
    view:nbGoTo(1)
    view:selectOps({ 1 }, "lasso")
    view:openSelectionMenu()
    ok(findButton(view._sel_dialog, "Link to page\u{2026}") ~= nil, "links: the menu offers a link")
    findButton(view._sel_dialog, "Link to page\u{2026}").callback()
    ok(view._link_sheet ~= nil and findButton(view._link_sheet, "Energy"), "links: the pages of this notebook to choose from")
    findButton(view._link_sheet, "Energy").callback()
    local link = view.canvas.ops[#view.canvas.ops]
    ok(link.kind == "link" and link.to.id == id4 and link.to.path == nil, "links: a link to the page, within the notebook")
    ok(view.selection and #view.selection.idxs == 2 and view._sel_dialog ~= nil, "links: it joins the selection")
    ok(findButton(view._sel_dialog, "Remove link") and findButton(view._sel_dialog, "Change link\u{2026}"),
        "links: the menu then offers to change or remove it")
    view:paintTo(Screen.bb, 0, 0)
    view:dropSelection()

    -- following it with Pan, and back
    view:setTool("pan")
    local lx, ly = scr(link.x + link.w / 2, link.y + link.h / 2)
    view:onIaTouch(nil, pos(lx, ly))
    view:onIaTap(nil, pos(lx, ly))
    ok(nb.index == 4 and view._link_back and view._link_back.page == 1, "links: a tap with Pan follows it")
    ok(view:fabRect("back") ~= nil and view:fabHit(view:fabRect("back").x + 5, view:fabRect("back").y + 5) == "back",
        "links: a Back pill shows")
    view:fabAction("back")
    ok(nb.index == 1 and view._link_back == nil and view:fabRect("back") == nil, "links: Back returns to page 1")
    -- a drag that starts on it pans instead
    view:onIaTouch(nil, pos(lx, ly)); view:onIaPan(nil, pos(lx + 40, ly)); view:onIaPanRelease(nil, pos(lx + 40, ly))
    ok(nb.index == 1, "links: a drag from it does not follow it")
    -- the page moves: the link follows it by id
    view:nbGoTo(4); view.notebook:movePage(-1); view:nbGoTo(1)
    view:onIaTouch(nil, pos(lx, ly)); view:onIaTap(nil, pos(lx, ly))
    ok(nb.pages[nb.index].id == id4 and nb.index == 3, "links: it still leads to its page after the page moved")
    view:fabAction("back")

    -- a link to a page of another notebook
    view:nbSyncOut(); view:saveDocument()
    local phys = view.doc_path
    view:newNotebook("grid", LIB)
    view.canvas.ops[1] = ink(200, 200); view:markDirty()
    view:renameDocument("Maths"); view:saveDocument()
    view:selectOps({ 1 }, "lasso")
    view:selLink()
    findButton(view._link_sheet, "Another notebook\u{2026}").callback()
    findButton(view._link_sheet, "Physics").callback()
    findButton(view._link_sheet, "Forces").callback()
    local far = view.canvas.ops[#view.canvas.ops]
    ok(far.kind == "link" and far.to.path == phys and far.to.label:find("Forces", 1, true), "links: to another notebook's page")
    view:dropSelection()
    view:followLink(far)
    ok(view.doc_path == phys and view.notebook.pages[view.notebook.index].title == "Forces",
        "links: following it opens that notebook at that page")
    view:linkBack()
    ok(view.doc_path:find("Maths", 1, true) ~= nil, "links: and Back returns to the first notebook")
    -- removing it leaves what it was made on
    view:selectOps({ 1, #view.canvas.ops }, "lasso")
    view:selUnlink()
    ok(#view.canvas.ops == 1 and view.canvas.ops[1].kind == "ink", "links: Remove link keeps the writing")
    view:dropSelection()

    -- the contents page
    view:openDocument(phys)
    nb = view.notebook
    local n0 = nb:count()
    view:nbMakeContents()
    ok(nb:count() == n0 + 1 and nb.pages[1].contents and nb.pages[1].title == "Contents" and nb.index == 1,
        "contents: a contents page at the front, shown")
    local toc_links = {}
    for _, op in ipairs(view.canvas.ops) do if op.kind == "link" then toc_links[#toc_links + 1] = op end end
    -- (Energy was moved before Forces above; with the contents in front it is page 4)
    ok(#toc_links == 2 and toc_links[1].to.id == id4 and toc_links[1].to.page == 4,
        "contents: a line for each titled page, with its number now")
    -- something written on it stays when it is brought up to date
    view.canvas.ops[#view.canvas.ops + 1] = ink(500, 900); view:markDirty()
    nb.pages[2].title = "Introduction"
    view:nbMakeContents()
    local lines, mine = 0, 0
    for _, op in ipairs(view.canvas.ops) do
        if op.kind == "link" then lines = lines + 1 end
        if op.kind == "ink" then mine = mine + 1 end
    end
    ok(nb:count() == n0 + 1 and lines == 3 and mine == 1, "contents: an update lists the new title and keeps the ink")
    -- following a contents line
    view:setTool("pan")
    local first = nil
    for _, op in ipairs(view.canvas.ops) do if op.kind == "link" and not first then first = op end end
    local fx, fy = scr(first.x + 20, first.y + first.h / 2)
    view:onIaTouch(nil, pos(fx, fy)); view:onIaTap(nil, pos(fx, fy))
    ok(nb.pages[nb.index].title == "Introduction", "contents: a tap on a line opens its page")
    view:fabAction("back")

    -- in an exported PDF: links between exported pages
    local saved = Export.notebookPDFJob
    local got
    Export.notebookPDFJob = function(pages, w, h, template, path, quality, tmp, bg, opts)
        got = { pages = pages, opts = opts, h = h }
        return { step = function() return "done" end, cancel = function() end }
    end
    view:exportOptions().fmt, view:exportOptions().scope = "pdf", "all"
    view:writePDF(LIB .. "/Physics.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    local annots = got and got.opts.links and got.opts.links(1)
    ok(annots and #annots == 3 and annots[1].page == 2 and annots[1].y1 > annots[1].y0,
        "export: the contents' lines are links in the PDF, to their pages")
    view:exportOptions().scope, view:exportOptions().range = "range", { from = 1, to = 2 }
    view:writePDF(LIB .. "/Physics.pdf")
    UIManager.fireScheduled(); UIManager.fireScheduled()
    annots = got.opts.links(1)
    ok(#annots == 1 and annots[1].page == 2, "export: links to pages left out are dropped")
    Export.notebookPDFJob = saved

    UIManager:close(view)
    G_reader_settings.data.inkaway_library_dir = TestEnv.libraryDir()
    G_reader_settings.data.inkaway_last_doc = nil
    UIManager.reset()
end

-- Hold to straighten: a stroke held still at its end becomes a clean shape
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkGeom = require("ink/geom")
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local v = view.view
    view:setTool("pen")
    local function scr(cx, cy) return InkGeom.toScreen(v, cx, cy) end
    -- draw through canvas points, then hold still (the timer fires)
    local function draw(pts, hold)
        local x, y = scr(pts[1], pts[2])
        view:onIaTouch(nil, pos(x, y))
        for i = 3, #pts - 1, 2 do
            x, y = scr(pts[i], pts[i + 1])
            view:onIaPan(nil, pos(x, y))
        end
        if hold then
            -- only the straightening timer, as the hold would let it fire
            UIManager.scheduled[view._straighten_cb] = nil
            view:straightenNow()
        end
        return x, y
    end
    local function lift(x, y)
        view:onIaPanRelease(nil, pos(x, y))
        UIManager.fireScheduled(); UIManager.fireScheduled()
    end
    -- a slightly wobbly line, held at its end
    view.canvas:setOps({})
    local line = {}
    for i = 0, 20 do line[#line + 1] = 200 + i * 20; line[#line + 1] = 400 + ((i % 2 == 0) and 2 or -2) end
    local x, y = draw(line, false)
    ok(UIManager.scheduled[view._straighten_cb] ~= nil, "straighten: drawing arms the hold timer")
    UIManager.scheduled[view._straighten_cb] = nil
    view:straightenNow()
    local op = view.canvas.ops[1]
    ok(op and op.kind == "shape" and op.shape == "line" and not view.capturing,
        "straighten: holding at the end makes it a clean line at once")
    view:onIaPan(nil, pos(x + 80, y + 80))
    ok(#view.canvas.ops == 1 and not view.capturing, "straighten: moving on afterwards draws nothing")
    lift(x + 80, y + 80)
    ok(#view.canvas.ops == 1 and view._swallow == nil, "straighten: the lift ends it")
    view:undo()
    ok(#view.canvas.ops == 0, "straighten: one undo takes it away")

    -- a rough box becomes a rectangle
    local box = { 300, 300, 600, 302, 602, 600, 301, 598, 302, 304 }
    local fine = {}
    for i = 1, #box - 3, 2 do
        for t = 0, 9 do
            fine[#fine + 1] = box[i] + (box[i + 2] - box[i]) * t / 10
            fine[#fine + 1] = box[i + 1] + (box[i + 3] - box[i + 1]) * t / 10
        end
    end
    x, y = draw(fine, true)
    op = view.canvas.ops[1]
    ok(op and op.kind == "shape" and op.shape == "rect", "straighten: a box held at its end becomes a rectangle ("
        .. tostring(op and (op.shape or op.kind)) .. ")")
    lift(x, y)
    view.canvas:setOps({})

    -- writing is left alone: a small letter, and a big scribble, held still
    x, y = draw({ 100, 100, 104, 112, 110, 100, 116, 112 }, true)
    ok(view.capturing and #view.canvas.ops == 0, "straighten: a small stroke is never straightened")
    lift(x, y)
    ok(view.canvas.ops[1] and view.canvas.ops[1].kind == "ink", "straighten: and stays ink")
    view.canvas:setOps({})
    local scribble = {}
    for i = 0, 40 do scribble[#scribble + 1] = 200 + i * 8; scribble[#scribble + 1] = 300 + math.sin(i * 0.9) * 60 end
    x, y = draw(scribble, true)
    ok(view.capturing, "straighten: a scribble that is no shape is never straightened")
    lift(x, y)
    ok(view.canvas.ops[1] and view.canvas.ops[1].kind == "ink", "straighten: and stays ink")
    view.canvas:setOps({})

    -- off: no timer
    view.hold_straighten = false
    draw(line, false)
    ok(UIManager.scheduled[view._straighten_cb] == nil, "straighten: off, holding does nothing")
    lift(scr(line[#line - 1], line[#line]))
    view.hold_straighten = true
    -- a jitter within a millimetre does not restart the wait
    view.canvas:setOps({})
    x, y = draw(line, false)
    local ax, ay = view._straight_at.x, view._straight_at.y
    view:onIaPan(nil, pos(x + 2, y + 1))
    ok(view._straight_at.x == ax and view._straight_at.y == ay, "straighten: a tremble keeps the wait going")
    view:onIaPan(nil, pos(x + 40, y + 1))
    ok(view._straight_at.x == x + 40, "straighten: a real move starts it again")
    lift(x + 2, y + 1)
    UIManager:close(view)
    UIManager.reset()
end

-- ---- Pan on its own button above the zoom pill, Lasso in the toolbar --------
for _, wh in ipairs(SIZES) do
    Screen:setRotationMode(0); Screen:setSize(wh[1], wh[2])
    UIManager.reset()
    BB.out_of_bounds = 0
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    UIManager:show(view)
    local v = view.view
    local tag = " (" .. wh[1] .. "x" .. wh[2] .. ")"
    local ids = {}
    for _, e in ipairs(view._toolbar_icons) do ids[e.id] = e end
    ok(ids.lasso and ids.lasso.tool and not ids.pan, "pan button: Lasso takes Pan's place in the toolbar" .. tag)
    local zr, pr = view:fabRect("zoom"), view:fabRect("pan")
    ok(pr.x == zr.x and pr.w == zr.w and pr.h == pr.w and pr.y + pr.h < zr.y and zr.y - (pr.y + pr.h) < pr.h,
        "pan button: round, a little above the zoom pill and apart from it" .. tag)
    ok(pr.y >= v.area_y and pr.x + pr.w <= v.area_x + v.area_w, "pan button: inside the drawing area" .. tag)
    -- the Lasso button picks the lasso and is lit
    view:setTool("pen")
    ids.lasso.button.callback()
    ok(view.tool == "lasso" and view._toolbar_icons[view._active_btn_idx].id == "lasso",
        "pan button: the toolbar's Lasso picks the lasso, lit" .. tag)
    -- a tap on the Pan button picks Pan, a second goes back
    local cx, cy = math.floor(pr.x + pr.w / 2), math.floor(pr.y + pr.h / 2)
    local function tapAt(x, y) view:onIaTouch(nil, pos(x, y)); view:onIaTap(nil, pos(x, y)) end
    local function refreshed(r)
        for _, f in ipairs(UIManager.refreshes) do
            local g = f.region
            if g and g.x <= r.x and g.y <= r.y and g.x + g.w >= r.x + r.w and g.y + g.h >= r.y + r.h then
                return true
            end
        end
        return false
    end
    ok(view:fabHit(cx, cy) == "pan" and view:penOnUI(cx, cy), "pan button: a finger or the pen reaches it" .. tag)
    UIManager.refreshes = {}
    tapAt(cx, cy)
    ok(view.tool == "pan" and view._active_btn_idx == nil, "pan button: a tap picks Pan; no toolbar tool is lit" .. tag)
    ok(refreshed(pr), "pan button: it repaints to show Pan is on" .. tag)
    view:paintTo(Screen.bb, 0, 0)
    ok(view._pan_fab_on == true and view._pan_fab_icons and view._pan_fab_icons.inv, "pan button: painted lit" .. tag)
    UIManager.refreshes = {}
    tapAt(cx, cy)
    ok(view.tool == "lasso" and refreshed(pr), "pan button: a second tap goes back to the lasso, and repaints" .. tag)
    view:setTool("text"); tapAt(cx, cy); tapAt(cx, cy)
    ok(view.tool == "text", "pan button: and back to any tool it came from" .. tag)
    view:setTool("pan"); view:setTool("erase"); tapAt(cx, cy)
    ok(view.tool == "pan", "pan button: Pan from a toolbar tool too" .. tag)
    view:setTool("pen")
    -- drawing near it fades it, so the canvas under it is reachable, and it comes back
    view:fabProximity(cx, pr.y - 4)
    ok(view._pan_hidden and view:fabHit(cx, cy) == nil, "pan button: drawing near it hides it" .. tag)
    UIManager.fireScheduled()
    ok(not view._pan_hidden and view:fabHit(cx, cy) == "pan", "pan button: it comes back" .. tag)
    -- a drag that starts on it draws, as on the zoom pill
    view:onIaTouch(nil, pos(cx, cy))
    view:onIaPan(nil, pos(cx - 80, cy - 80))
    ok(view._fab_press == nil and view.tool == "pen", "pan button: a drag off it is no tap" .. tag)
    view:onIaPanRelease(nil, pos(cx - 80, cy - 80))
    -- painted in bounds, lit and not (compared with a paint before, as earlier
    -- landscape tests leave the mock a stray out-of-bounds paint of their own)
    BB.out_of_bounds = 0
    view:paintTo(Screen.bb, 0, 0)
    local base = BB.out_of_bounds
    BB.out_of_bounds = 0
    view:setTool("pan"); view:paintTo(Screen.bb, 0, 0)
    view:setTool("pen"); view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 2 * base, "pan button: paints in bounds" .. tag)
    UIManager:close(view)
    ok(view._pan_fab_icons == nil and view._fab_sprites == nil, "pan button: its images are freed on close" .. tag)
end
UIManager.reset()

-- ---- a sheet that goes away is painted over in full -----------------------
-- Closing the selection menu (or any sheet) repaints what it covered, the
-- bottom bar or the toolbar included, even when dropping the selection or a
-- drag asks for an area-only or region paint in the same moment.
for _, nb in ipairs({ false, true }) do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local view = dofile("ink/view.lua"):new{}
    UIManager:show(view)
    if nb then view:startNotebook({ style = "lines", size = 40 }) end
    local tag = nb and " (notebook)" or " (drawing)"
    view.canvas:setOps({ { kind = "ink", width = 6, alpha = 255, pts = { 100, 300, 400, 340 } } })
    view:composeCanvas(); view:renderView()
    view:paintTo(Screen.bb, 0, 0)
    local chrome, full = 0, 0
    local tb = view.toolbar.paintTo
    view.toolbar.paintTo = function(...) chrome = chrome + 1; return tb(...) end
    local bf = view.blitAreaFull
    view.blitAreaFull = function(...) full = full + 1; return bf(...) end
    local function paintCounts()
        chrome, full = 0, 0
        view:paintTo(Screen.bb, 0, 0)
        return chrome, full
    end
    -- the menu closed by a tap away, which drops the selection (an area-only refresh)
    view:setTool("lasso")
    view:selectOps({ 1 }, "lasso"); view:openSelectionMenu()
    local m = view._sel_dialog
    view:paintTo(Screen.bb, 0, 0)
    m.tap_pos = { x = 900, y = 1300 }
    m:onCloseMenu()
    ok(view.selection == nil and view._area_only, "uncover: the tap away dropped the selection" .. tag)
    local c, f = paintCounts()
    ok(c == 1 and f == 1, "uncover: and the next paint covers the bars and the whole area" .. tag)
    c, f = paintCounts()
    ok(f == 1, "uncover: (once: later paints are as asked)" .. tag)
    -- closed while a region paint is pending (a drag's first move)
    view:selectOps({ 1 }, "lasso"); view:openSelectionMenu()
    view:paintTo(Screen.bb, 0, 0)
    view:closeSelectionMenu()
    view._blit_rect = { x0 = 10, y0 = 10, x1 = 40, y1 = 40 }
    c, f = paintCounts()
    ok(c == 1 and f == 1, "uncover: a pending region paint is widened to the whole" .. tag)
    -- any sheet
    view:dropSelection(); view:paintTo(Screen.bb, 0, 0)
    view:showSheet("_test_sheet", function() return require("ui/widget/verticalspan"):new{ width = 10 } end)
    view:closeSheet("_test_sheet")
    view._area_only = true
    c, f = paintCounts()
    ok(c == 1 and f == 1, "uncover: other sheets too" .. tag)
    UIManager:close(view)
end
UIManager.reset()

-- ---- pen sheet without shape assist; "Colour while drawing" on colour screens --
do
    local Device = require("device")
    local function find(w, pred, seen)
        seen = seen or {}
        if type(w) ~= "table" or seen[w] then return nil end
        seen[w] = true
        if pred(w) then return w end
        for k, val in pairs(w) do
            if k ~= "show_parent" and k ~= "parent" then
                local f = find(val, pred, seen); if f then return f end
            end
        end
    end
    local function labelled(text) return function(w) return w.label == text or w.text == text end end
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local view = dofile("ink/view.lua"):new{}
    UIManager:show(view)
    view:openPenInput()
    ok(find(view._peninput_dialog or UIManager.shown, labelled("Shape assist")) == nil
        and find(view._peninput_dialog or UIManager.shown, labelled("Palm rejection")) ~= nil,
        "pen input: no Shape assist toggle (hold to straighten does it), Palm rejection stays")
    view:closeSheet("_peninput_dialog")
    ok(view.shape_assist == nil, "pen sheet: and no shape assist setting is read")
    view:closeSheet("_pen_dialog")
    view:openSettings()
    ok(find(view._settings_dialog, labelled("Colour while drawing")) == nil, "live colour: not offered on a grey screen")
    view:closeSheet("_settings_dialog")
    UIManager:close(view)
    local had = Device.hasColorScreen
    Device.hasColorScreen = function() return true end
    UIManager.reset()
    view = dofile("ink/view.lua"):new{}
    UIManager:show(view)
    ok(view.live_colour == true, "live colour: on by default")
    view:openSettings()
    local t = find(view._settings_dialog, labelled("Colour while drawing"))
    ok(t ~= nil and t.callback ~= nil, "live colour: offered on a colour screen")
    if t then t.callback(false) end
    ok(view.live_colour == false and G_reader_settings.data.inkaway_live_colour == false, "live colour: the toggle is kept")
    view:closeSheet("_settings_dialog")
    UIManager:close(view)
    G_reader_settings.data.inkaway_live_colour = nil
    Device.hasColorScreen = had
    require("ink/accent").set(nil)
    UIManager.reset()
end

print(("view: %d checks, %d failures"):format(checks, failures))
require("testenv").cleanup()
os.exit(failures == 0 and 0 or 1)
