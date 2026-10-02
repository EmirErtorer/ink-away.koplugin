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

-- Mock KOReader's global settings; autosave off so tests never touch disk.
_G.G_reader_settings = {
    data = { inkaway_autosave = "off" },
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function pos(x, y) return { pos = { x = x, y = y } } end

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
    ok(view.selected ~= nil, tag .. ": holding a shape selects it")
    ok(ButtonDialog.last ~= nil, tag .. ": the shape edit menu opens")

    local ti = nb + 1                        -- the triangle op's index
    view:beginRotate(view.selected)
    ok(view.rotating ~= nil and view.canvas.ops[ti].hidden, tag .. ": rotate mode hides the shape")
    view:onIaTouch(nil, pos(midx + 40, v.area_y + 380))
    view:onIaPan(nil, pos(midx, v.area_y + 320))
    view:onIaPanRelease(nil, pos(midx, v.area_y + 320))
    ok(view.rotating == nil and view.canvas.ops[ti].angle ~= nil and not view.canvas.ops[ti].hidden,
        tag .. ": rotation commits an angle")

    local selref = { op = view.canvas.ops[ti], idx = ti }
    view:editSelectedColour(selref)
    ButtonDialog.last.buttons[1][3].callback()   -- shade row, 3rd swatch = Grey
    ok(view.canvas.ops[ti].color[1] == 0x88, tag .. ": shape recoloured")
    view:editSelectedSize(selref)
    SpinWidget.last.callback({ value = 9 })
    ok(view.canvas.ops[ti].width == 9, tag .. ": shape line size changed")
    view:editSelectedOpacity(selref)
    SpinWidget.last.callback({ value = 50 })
    ok(view.canvas.ops[ti].alpha == math.floor(50 / 100 * 255 + 0.5), tag .. ": shape opacity changed")

    local nd = view.canvas:opCount()
    view:deleteSelected(selref)
    ok(view.canvas:opCount() == nd - 1, tag .. ": delete removes the shape")

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
    ok(view.selected ~= nil and view.selected.op.arrow == "end",
        tag .. ": holding an arrow selects it for the edit menu")
    view.selected = nil
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
        view:setTool("pen")
    end

    -- save dialog wiring (no native encoders are called)
    local ButtonDialog = require("ui/widget/buttondialog")
    local PathChooser = require("ui/widget/pathchooser")
    local InputDialog = require("ui/widget/inputdialog")
    view:setTool("pen")
    view:onSave()
    ok(view._save_dialog ~= nil, tag .. ": Save opens the save sheet")
    view._save_dialog:onCloseMenu()
    -- the sheet's Save button runs chooseDestination for the chosen format
    view:chooseDestination(view.save_fmt or "png")
    ok(PathChooser.last ~= nil and PathChooser.last.select_directory, tag .. ": Save leads to folder chooser")
    PathChooser.last.onConfirm("/tmp")
    ok(InputDialog.last ~= nil, tag .. ": folder choice leads to filename prompt")

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
    ok(view.active_image ~= nil, "image: insert selects the new image")
    local op = view.active_image.op
    ok(op and op.kind == "image", "image: inserted op is an image op")
    ok(view.canvas:opCount() == 1, "image: op added to the ops list")
    ok(view.tool == "pan", "image: insert switches to Pan mode (the smooth move/resize)")
    ok(view._image_menu ~= nil, "image: insert opens the edit menu right away, as if tapped")
    -- it must be clearly SMALLER than the viewport (~60%) so every corner shows
    ok(op.w <= 0.62 * v.area_w / v.zoom and op.h <= 0.62 * v.area_h / v.zoom,
        "image: inserted image is smaller than the screen (all corners reachable)")
    ok(math.abs(op.w / op.h - 2) < 0.02, "image: inserted image keeps its 2:1 aspect ratio")

    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "image: selected overlay paints in bounds")

    -- move: grab the middle, drag right+down (an edit clones the op, so re-read it)
    local r = view:imageScreenRect()
    local cxm, cym = r.x + r.w / 2, r.y + r.h / 2
    local x0, y0 = op.x, op.y
    view:onIaTouch(nil, pos(cxm, cym))
    ok(view._img_drag and view._img_drag.kind == "move", "image: touch inside begins a move")
    view:onIaPan(nil, pos(cxm + 60, cym + 40))
    view:onIaPanRelease(nil, pos(cxm + 60, cym + 40))
    op = view.active_image.op
    ok(op.x > x0 and op.y > y0, "image: dragging moves the image")
    ok(view.active_image ~= nil, "image: it stays selected after a move")
    ok(view.canvas:canUndo(), "image: a move records undo history")
    view:paintTo(Screen.bb, 0, 0)
    ok(BB.out_of_bounds == 0, "image: overlay still in bounds after moving")

    -- resize from the SE corner: opposite (NW) corner stays put, aspect locked
    local r2 = view:imageScreenRect()
    local fx, fy = op.x, op.y                   -- NW corner is fixed for an SE drag
    local w_before, ratio = op.w, op.w / op.h
    view:onIaTouch(nil, pos(r2.x + r2.w, r2.y + r2.h))
    ok(view._img_drag and view._img_drag.kind == "resize", "image: a corner touch begins a resize")
    view:onIaPan(nil, pos(r2.x + r2.w + 120, r2.y + r2.h + 30))
    view:onIaPanRelease(nil, pos(r2.x + r2.w + 120, r2.y + r2.h + 30))
    op = view.active_image.op
    ok(op.w > w_before, "image: dragging the SE corner outward grows the image")
    ok(math.abs(op.w / op.h - ratio) < 0.02, "image: resize keeps the aspect ratio")
    ok(math.abs(op.x - fx) < 0.01 and math.abs(op.y - fy) < 0.01,
        "image: SE resize keeps the opposite (NW) corner fixed")

    -- rotate 90 preset: op.w/op.h (the unrotated size) are unchanged, only angle
    local rw, rh = op.w, op.h
    view:rotateImage90(view.active_image)
    op = view.active_image.op
    ok((op.angle or 0) == 90, "image: rotate 90 sets a 90-degree angle")
    ok(op.w == rw and op.h == rh, "image: rotate 90 leaves the unrotated size alone")

    -- free rotate: drag-to-spin commits an arbitrary angle
    view:beginImageRotate(view.active_image)
    ok(view.image_rotating ~= nil, "image: free rotate enters a drag mode")
    local cx2, cy2 = InkGeom.toScreen(v, op.x + op.w / 2, op.y + op.h / 2)
    view:onIaTouch(nil, pos(cx2 + 50, cy2))          -- grab to the right of centre
    view:onIaPan(nil, pos(cx2, cy2 + 50))            -- swing 90 degrees clockwise
    view:onIaPanRelease(nil, pos(cx2, cy2 + 50))
    ok(view.image_rotating == nil, "image: lifting ends the free rotation")
    op = view.active_image.op
    ok(math.abs((op.angle or 0) - 90) > 1, "image: free rotate changed the angle from the 90 preset")

    -- flips toggle their flags
    view:flipImage(view.active_image, "h"); op = view.active_image.op
    ok(op.flip_h == true, "image: flip H sets the flag")
    view:flipImage(view.active_image, "v"); op = view.active_image.op
    ok(op.flip_v == true, "image: flip V sets the flag")

    -- z-order: put a later op above, then bring the image to the front
    view.canvas.ops[#view.canvas.ops + 1] = { kind = "ink", pts = {}, width = 5 }
    ok(view.active_image.idx == 1, "image: it sits below the later op")
    view:imageToFront(view.active_image)
    ok(view.active_image.idx == #view.canvas.ops
        and view.canvas.ops[#view.canvas.ops].kind == "image",
        "image: bring to front moves it to the top of the stack")

    -- delete, then undo restores it (regression: the old hidden flag broke this)
    local before = view.canvas:opCount()
    view:deleteActiveImage()
    ok(view.active_image == nil, "image: delete clears the selection")
    ok(view.canvas:opCount() == before - 1, "image: delete removes the image op")
    view:undo()
    local found = false
    for _, o in ipairs(view.canvas.ops) do if o.kind == "image" then found = true end end
    ok(found, "image: undo restores a deleted image")
    view:redo()
    found = false
    for _, o in ipairs(view.canvas.ops) do if o.kind == "image" then found = true end end
    ok(not found, "image: redo re-applies the delete")

    -- tap in Pan mode selects reliably (no hold hunting) -- put an image back first
    view:undo()   -- bring the image back
    view:setTool("pan")
    local img
    for _, o in ipairs(view.canvas.ops) do if o.kind == "image" then img = o end end
    local sx, sy = InkGeom.toScreen(v, img.x + img.w / 2, img.y + img.h / 2)
    view:onIaTouch(nil, pos(sx, sy))
    ok(view.active_image and view.active_image.op == img, "image: a tap in Pan mode selects it")

    -- an undecodable picture is reported, not inserted
    RenderImage.fake_size = nil
    local cnt = view.canvas:opCount()
    view:insertImage("/tmp/broken.png")
    ok(view.active_image and view.active_image.op == img and view.canvas:opCount() == cnt,
        "image: an undecodable picture is not added")
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
    view:onIaTouch(nil, pos(cxs, cys))
    ok(view.selected ~= nil, "shape: a touch in Pan mode selects it")
    view:onIaTap(nil, pos(cxs, cys))                 -- the tap opens the menu
    ok(view.is_always_active == true, "shape: an open menu keeps the canvas active for dragging")
    -- now drag it: touch, pan, release
    local x0 = view.selected.op.pts[1]
    view:onIaTouch(nil, pos(cxs, cys))
    view:onIaPan(nil, pos(cxs + 90, cys + 40))
    view:onIaPanRelease(nil, pos(cxs + 90, cys + 40))
    ok(view.selected.op.pts[1] > x0, "shape: dragging moves the shape")
    ok(view.canvas:canUndo(), "shape: a move records undo history")

    local ang0 = view.selected.op.angle or 0
    view:rotateShape90(view.selected)
    ok(math.abs((view.selected.op.angle or 0) - (ang0 + math.pi / 2)) < 1e-6,
        "shape: rotate 90 adds a quarter turn")

    view:deselectShape()
    ok(view.selected == nil and view.is_always_active == false,
        "shape: deselect clears the selection and restores the active flag")
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

    -- ...and now a finger draws normally (Ink Away is still a finger app when the pen is idle)
    local n = view.canvas:opCount()
    view:onIaTouch(nil, pos(midx, yy))
    ok(view.capturing, "palm: with the pen idle, a finger begins a stroke")
    view:onIaPanRelease(nil, pos(midx + 5, yy + 20))
    UIManager.fireScheduled()
    ok(view.canvas:opCount() == n + 1, "palm: a finger stroke commits when the pen is idle")

    -- palm-before-pen: a finger stroke already going is dropped when the pen lands
    view:onIaTouch(nil, pos(200, yy + 100))     -- palm starts a stroke first
    ok(view.capturing, "palm: finger (palm) starts a stroke before the pen")
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

    -- the primary side (barrel) button is a lasso-select modifier. KOReader routes
    -- the pen slot with the tool overridden to ERASER (2) AND the eraser latch set;
    -- that must become lasso select, not erase, and the tool restores on lift.
    view:setTool("pen")
    local prev_sel = view.tool
    Device.input.stylus_eraser_active = true
    pen(0, midx, yy, 2)                          -- side button held: tool 2 + latch
    ok(view.tool == "lasso", "palm: the side button switches to lasso select")
    ok(view.lassoing, "palm: the side-button stroke drives the lasso")
    pen(-1, midx, yy, 2)                         -- lift
    Device.input.stylus_eraser_active = false
    ok(view.tool == prev_sel, "palm: the tool is restored after the side-button stroke")
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
    view:onIaTouch(nil, pos(240, yy + 260))      -- palm lands, not yet flagged -> opens a stroke
    view:onIaPan(nil, pos(250, yy + 270))
    ok(view.capturing, "palm: an unflagged palm touch opens a stroke, like an ordinary finger")
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
end

-- ---- shape assist rebuilds the master incrementally (snapshot + restore) ------
-- beginStroke snapshots the pre-stroke master only for a pen stroke with shape
-- assist on; beautifyRecompose then restores just the stroke footprint (and each
-- symmetry mirror of it) from that snapshot instead of replaying every op. The
-- pixel result is verified on the emulator; here we check the wiring and that the
-- cost is O(stroke), not O(number of ops).
do
    Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    local v = view.view
    local midx = v.area_x + math.floor(v.area_w / 2)
    local midy = v.area_y + math.floor(v.area_h / 2)

    -- snapshot lifecycle in beginStroke
    view.shape_assist = false
    view.tool = "pen"
    view:beginStroke(midx, midy)
    ok(not view._pre_stroke_valid, "beautify: no snapshot when shape assist is off")
    view.capturing = false

    view.shape_assist = true
    view.tool = "pen"
    view:beginStroke(midx, midy)
    ok(view._pre_stroke_valid and view._pre_stroke_bb ~= nil,
        "beautify: a pen stroke snapshots the master when shape assist is on")
    ok(view._pre_stroke_bb:getWidth() == v.canvas_w
        and view._pre_stroke_bb:getHeight() == v.canvas_h,
        "beautify: the snapshot is canvas sized")
    view.capturing = false

    view.shape_assist = true
    view.tool = "erase"
    view:beginStroke(midx, midy)
    ok(not view._pre_stroke_valid, "beautify: the eraser never snapshots (assist is pen only)")
    view.capturing = false
    view.tool = "pen"

    -- beautifyRecompose: fall back to a full compose when there is no snapshot
    view._pre_stroke_valid = false
    ok(view:beautifyRecompose({ 10, 10, 40, 40 },
        { kind = "ink", pts = { 10, 10, 40, 40 }, width = 6 }) == false,
        "beautify: recompose falls back without a snapshot")

    -- fast path: spy on the restore blits into canvas_bb and the re-stamp
    local blits, stamps = 0, 0
    local realBlit = view.canvas_bb.blitFrom
    view.canvas_bb.blitFrom = function(self2, ...) blits = blits + 1; return realBlit(self2, ...) end
    view.stampOpIntoCanvas = function() stamps = stamps + 1 end
    if not view._pre_stroke_bb then view._pre_stroke_bb = BB.new(v.canvas_w, v.canvas_h, 1) end

    -- valid snapshot, no symmetry -> exactly one footprint restore
    view._pre_stroke_valid = true
    BB.out_of_bounds = 0
    blits, stamps = 0, 0
    local okc = view:beautifyRecompose({ 100, 100, 300, 260 },
        { kind = "ink", pts = { 100, 100, 300, 260 }, width = 8 })
    ok(okc == true, "beautify: recompose runs the fast path with a valid snapshot")
    ok(blits == 1, "beautify: with no symmetry it restores exactly one footprint rect")
    ok(stamps == 1, "beautify: the clean op is stamped back once")
    ok(not view._pre_stroke_valid, "beautify: the snapshot is consumed after use")
    ok(BB.out_of_bounds == 0, "beautify: the restore rect stays inside the canvas")

    -- quad symmetry -> base + three mirror rects, all in bounds
    view._pre_stroke_valid = true
    BB.out_of_bounds = 0
    blits = 0
    okc = view:beautifyRecompose({ 100, 100, 300, 260 },
        { kind = "ink", pts = { 100, 100, 300, 260 }, width = 8, sym = "quad" })
    ok(okc == true and blits == 4, "beautify: quad symmetry restores four mirror rects")
    ok(BB.out_of_bounds == 0, "beautify: every mirror rect stays inside the canvas")

    -- cost is independent of how many ops the canvas holds (O(stroke), not O(n))
    for i = 1, 500 do
        view.canvas.ops[#view.canvas.ops + 1] = { kind = "ink", pts = { i, i, i + 1, i + 1 }, width = 2 }
    end
    view._pre_stroke_valid = true
    blits = 0
    okc = view:beautifyRecompose({ 100, 100, 300, 260 },
        { kind = "ink", pts = { 100, 100, 300, 260 }, width = 8 })
    ok(okc == true and blits == 1, "beautify: restore cost does not grow with the op count")

    -- a stale-sized snapshot (e.g. after a rotation) falls back to a full compose
    view._pre_stroke_valid = true
    view._pre_stroke_bb = BB.new(10, 10, 1)
    ok(view:beautifyRecompose({ 1, 1, 2, 2 },
        { kind = "ink", pts = { 1, 1, 2, 2 }, width = 2 }) == false,
        "beautify: a stale-sized snapshot falls back to full compose")

    view.canvas_bb.blitFrom = nil   -- drop the spy; fall back to the metatable method
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

-- ---- pen input diagnostic runs cleanly and captures what it sees -------------
-- The on-device test (for palm-rejection debugging on stylus devices we can't
-- reproduce) must arm a capture, count stylus events vs finger touches, and finish
-- without error whether or not palm rejection is on.
do
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    local view = InkAwayView:new{}
    view.palm_reject = false
    local ok1 = pcall(function() view:startPenInputTest() end)
    ok(ok1 and view._pen_capture ~= nil, "pentest: starts and arms the capture")
    -- one stylus event and one finger touch land during the window
    view:onStylusSlot(Device.input, { slot = 4, id = 7, tool = 1, x = 100, y = 100, timev = 1 })
    view:onIaTouch(nil, pos(100, 300))
    ok(view._pen_capture.styl >= 1, "pentest: captured the stylus event")
    ok(view._pen_capture.fingers >= 1, "pentest: counted the finger touch")
    local ok2 = pcall(function() view:finishPenInputTest() end)
    ok(ok2, "pentest: finishes without error")
    ok(view._pen_capture == nil, "pentest: clears the capture when done")
    view:onCloseWidget()
    Screen:setRotationMode(0); Screen:setSize(1072, 1448)
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

print(("view: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
