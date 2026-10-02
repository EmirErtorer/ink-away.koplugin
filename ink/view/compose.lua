--[[
The 1:1 master bitmap: rebuilding it from the ops (paper, background, ruling and
the buffers an eraser reveals), and stamping one committed op into it.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local GeomUI = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Export = require("ink/export")
local Paint = require("ink/paint")
local Symmetry = require("ink/symmetry")

local WHITE = Blitbuffer.COLOR_WHITE
local displayColor = Paint.displayColor
local spanWriter = Paint.spanWriter
local bgSpanWriter = Paint.bgSpanWriter
local paintPaper = Paint.paintPaper

local InkAwayView = {}

-- The colour a committed op is drawn with on screen (ink shade at its opacity,
-- or the background for an eraser).
function InkAwayView:opColor(op)
    if op.kind == "erase" then return WHITE end
    return displayColor(op.color, op.alpha or 255)
end

-- Compose a page into `dst` (a canvas-sized bitmap): white paper, optional
-- background picture, notebook ruling, then the ink ops. Shared by the live
-- master bitmap and by the page-overview thumbnails, so a thumbnail always
-- matches exactly what the page looks like.
-- `reveal_resolved` = the caller already ran the reveal-buffer detection (via
-- buildRevealPic/buildRevealText) and the reveal_pic/reveal_text it passed are
-- authoritative (nil means "not needed"). composeCanvas sets it so composeInto
-- skips two redundant full-ops scans; the thumbnail path leaves it off so
-- composeInto detects and builds its own reveal buffers.
function InkAwayView:composeInto(dst, ops, bg_bb, template, reveal_text, reveal_pic, reveal_resolved, bare)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local page_copy, owns_bare = nil, false
    if template then
        -- a notebook page composed on its own (page thumbnails): paper colour or the
        -- PDF page, then the ruling -- the same paper the live page shows
        local pic = bg_bb
        paintPaper(dst, W, H, template, pic)
        local has_soft, has_hard = false, false
        for _, op in ipairs(ops) do
            if op.kind == "erase" and not op.hidden then
                if op.ebg then has_hard = true else has_soft = true end
            end
        end
        local function pageCopy()
            if not page_copy then
                page_copy = Blitbuffer.new(W, H, dst:getType())
                page_copy:blitFrom(dst, 0, 0, 0, 0, W, H)
            end
            return page_copy
        end
        -- erasing reveals that paper (ruling included), never plain white; a hard
        -- erase reveals the bare paper, without the picture/PDF page
        if has_soft and not reveal_pic then bg_bb = pageCopy() end
        if has_hard and not bare then
            if pic then
                bare = Blitbuffer.new(W, H, dst:getType())
                paintPaper(bare, W, H, template, nil)
                owns_bare = true
            else
                bare = pageCopy()
            end
        end
    else
        dst:paintRect(0, 0, W, H, WHITE)
        if bg_bb then dst:blitFrom(bg_bb, 0, 0, 0, 0, W, H) end
    end
    -- reveal_pic = the plain page with placed images stamped on it, so a soft erase
    -- keeps the images (like it keeps the background). Built here from these ops
    -- when the caller did not pass one (e.g. page thumbnails), so it is always
    -- correct for whatever is being composed. dst currently holds the plain base.
    local owns_rp = false
    if not reveal_resolved and not reveal_pic then
        local has_img, has_soft = false, false
        for _, op in ipairs(ops) do
            if not op.hidden then
                if op.kind == "image" then has_img = true
                elseif op.kind == "erase" and not op.ebg then has_soft = true end
            end
        end
        if has_img and has_soft then
            reveal_pic = Blitbuffer.new(W, H, dst:getType())
            reveal_pic:blitFrom(dst, 0, 0, 0, 0, W, H)
            for _, op in ipairs(ops) do
                if not op.hidden and op.kind == "image" then self:blitImageInto(reveal_pic, op) end
            end
            owns_rp = true
        end
    end
    -- A text-protecting erase op (op.spare_text) reveals a copy of the page that
    -- INCLUDES the text (built once here if the caller didn't pass it), so it rubs
    -- out ink but leaves text; a normal erase reveals the plain page and removes
    -- both. Whether an erase spares text is baked into the op at draw time, so the
    -- setting is never retroactive. dst currently holds the plain base (paper /
    -- background / ruling), so a copy of it now is exactly the plain reveal.
    local owns_rt = false
    if not reveal_resolved and not reveal_text then
        local has_text, has_spare = false, false
        for _, op in ipairs(ops) do
            if not op.hidden then
                if op.kind == "text" then has_text = true
                elseif op.kind == "erase" and op.spare_text then has_spare = true end
            end
        end
        if has_text and has_spare then
            reveal_text = Blitbuffer.new(W, H, dst:getType())
            reveal_text:blitFrom(reveal_pic or dst, 0, 0, 0, 0, W, H)   -- keep images under it too
            for _, op in ipairs(ops) do
                if not op.hidden and op.kind == "text" then self:stampTextInto(reveal_text, op) end
            end
            owns_rt = true
        end
    end
    local refx, refy = Symmetry.canvasRefs(W, H)
    -- Only skip the selected image from the master while it is actively being
    -- dragged or rotated (then it is drawn live as the overlay). A merely selected,
    -- still image stays in the master so it renders through the exact same path as
    -- everything else -- no sub-pixel jump when it is picked or dropped.
    local dragging = (self._img_drag and self._img_drag.began) or self.image_rotating
    local skip = dragging and self.active_image and self.active_image.op or nil
    for _, op in ipairs(ops) do
        if not op.hidden and op ~= skip then   -- a shape being rotated is a preview
            if op.kind == "text" then
                self:stampTextInto(dst, op)   -- glyphs, drawn straight into dst (z-order)
            elseif op.kind == "image" then
                self:blitImageInto(dst, op)   -- placed picture, alpha-blended (z-order)
            else
                local put, fill_put
                if op.kind == "erase" and op.spare_text and reveal_text then
                    put = bgSpanWriter(dst, reveal_text, W, H, nil)  -- reveal page + text (+ images)
                elseif op.kind == "erase" and not op.ebg and (reveal_pic or bg_bb) then
                    put = bgSpanWriter(dst, reveal_pic or bg_bb, W, H, nil)  -- reveal page (+ images)
                elseif op.kind == "erase" and op.ebg and bare then
                    put = bgSpanWriter(dst, bare, W, H, nil)  -- notebook: bare paper, ruling kept
                else
                    put = spanWriter(dst, W, H, self:opColor(op), nil)
                end
                if op.kind == "shape" and op.fill_color and not op.fill then
                    fill_put = Symmetry.wrap(
                        spanWriter(dst, W, H, displayColor(op.fill_color, op.fill_alpha or 255), nil),
                        op.sym, refx, refy)
                end
                Export.paintGeom(op, Symmetry.wrap(put, op.sym, refx, refy), fill_put)
            end
        end
    end
    if owns_rt then reveal_text:free() end
    if owns_rp then reveal_pic:free() end
    if page_copy then page_copy:free() end
    if owns_bare then bare:free() end
end

-- The buffer the eraser reveals under the ink: in a notebook that is the paper
-- (colour + ruling + any PDF page), so erasing takes away ink but leaves the
-- ruling -- just like the drawing-mode grid, which the eraser also can't touch.
-- In plain drawing mode it is the optional background image (or nil = white).
function InkAwayView:eraseRevealBB()
    -- while protection is on, a live erase stroke spares text, so it reveals the
    -- page-with-text buffer; otherwise it reveals the plain page
    if self.text_erase_protect and self._reveal_text_bb then return self._reveal_text_bb end
    if self._reveal_pic_bb then return self._reveal_pic_bb end   -- keep placed images under a soft erase
    if self.notebook then return self._paper_bb end
    return self.bg_bb
end

-- Keep `_reveal_text_bb` (the plain page with the committed text stamped on top)
-- for the eraser to reveal when it must spare text -- for the live stroke and for
-- protecting erase ops. Built only when some erase spares text (or protection is
-- on, so the next stroke will) and text exists; freed otherwise.
function InkAwayView:buildRevealText(base_bb)
    if not self.canvas_bb then return end
    local has_text, has_spare = false, false
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden then
            if op.kind == "text" then has_text = true
            elseif op.kind == "erase" and op.spare_text then has_spare = true end
        end
    end
    if not (has_text and (self.text_erase_protect or has_spare)) then
        if self._reveal_text_bb then self._reveal_text_bb:free(); self._reveal_text_bb = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._reveal_text_bb and (self._reveal_text_bb:getWidth() ~= W or self._reveal_text_bb:getHeight() ~= H) then
        self._reveal_text_bb:free(); self._reveal_text_bb = nil
    end
    if not self._reveal_text_bb then
        self._reveal_text_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
    end
    local rt = self._reveal_text_bb
    if base_bb then rt:blitFrom(base_bb, 0, 0, 0, 0, W, H) else rt:paintRect(0, 0, W, H, WHITE) end
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden and op.kind == "text" then self:stampTextInto(rt, op) end
    end
end

-- Keep `_reveal_pic_bb` = the plain page (background / paper) with the placed
-- images stamped on it, so a soft eraser (the "Erase pictures" toggle off) rubs
-- out ink but reveals the images beneath instead of whitening them. Built only
-- when an image exists; freed otherwise.
function InkAwayView:buildRevealPic(base_bb)
    if not self.canvas_bb then return end
    local has_img = false
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden and op.kind == "image" then has_img = true; break end
    end
    if not has_img then
        if self._reveal_pic_bb then self._reveal_pic_bb:free(); self._reveal_pic_bb = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._reveal_pic_bb and (self._reveal_pic_bb:getWidth() ~= W or self._reveal_pic_bb:getHeight() ~= H) then
        self._reveal_pic_bb:free(); self._reveal_pic_bb = nil
    end
    if not self._reveal_pic_bb then
        self._reveal_pic_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
    end
    local rp = self._reveal_pic_bb
    if base_bb then rp:blitFrom(base_bb, 0, 0, 0, 0, W, H) else rp:paintRect(0, 0, W, H, WHITE) end
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden and op.kind == "image" then self:blitImageInto(rp, op) end
    end
end

-- What a "hard" erase (Erase pictures on) reveals in a notebook: the bare paper,
-- colour and ruling, without the picture or PDF page. The ruling belongs to the
-- paper, so no eraser ever removes it. Without a picture that is just the paper
-- buffer; with one, a second buffer is built on first use.
function InkAwayView:barePaperBB()
    if not (self.notebook and self.canvas_bb) then return nil end
    if not self.bg_bb then
        if self._bare_paper_bb then self._bare_paper_bb:free(); self._bare_paper_bb = nil end
        return self._paper_bb
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local bp = self._bare_paper_bb
    if bp and (bp:getWidth() ~= W or bp:getHeight() ~= H or self._bare_paper_for ~= self.notebook.template) then
        bp:free(); bp = nil
    end
    if not bp then
        bp = Blitbuffer.new(W, H, self.canvas_bb:getType())
        paintPaper(bp, W, H, self.notebook.template, nil)
        self._bare_paper_bb, self._bare_paper_for = bp, self.notebook.template
    end
    return bp
end

-- Build (once per compose) the notebook paper: paper colour or PDF page, then the
-- ruling on top. Kept as its own buffer so the eraser can restore it.
function InkAwayView:buildNotebookPaper()
    if not (self.notebook and self.canvas_bb) then
        if self._paper_bb then self._paper_bb:free(); self._paper_bb = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._paper_bb and (self._paper_bb:getWidth() ~= W or self._paper_bb:getHeight() ~= H) then
        self._paper_bb:free(); self._paper_bb = nil
    end
    if not self._paper_bb then
        self._paper_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
    end
    paintPaper(self._paper_bb, W, H, self.notebook.template, self.bg_bb)
    -- a template/paper change rebuilds the bare paper on next use
    if self._bare_paper_bb then self._bare_paper_bb:free(); self._bare_paper_bb = nil end
end

-- Rebuild the 1:1 master bitmap from the committed ops. Cost is proportional to
-- the ink drawn, not the zoom, and it only runs on open, undo, clear, or resize.
function InkAwayView:composeCanvas()
    if not self.canvas_bb then return end
    if self.notebook then
        -- paper (with ruling) is the base AND the erase-reveal source, so ruling
        -- lives under the ink and the eraser restores it instead of whitening it
        self:buildNotebookPaper()
        self:buildRevealPic(self._paper_bb)
        self:buildRevealText(self._reveal_pic_bb or self._paper_bb)   -- text reveal keeps images too
        local bare
        for _, op in ipairs(self.canvas.ops) do
            if op.kind == "erase" and op.ebg and not op.hidden then bare = self:barePaperBB(); break end
        end
        self:composeInto(self.canvas_bb, self.canvas.ops, self._paper_bb, nil,
            self._reveal_text_bb, self._reveal_pic_bb, true, bare)   -- reveal buffers already resolved
    else
        self:buildRevealPic(self.bg_bb)
        self:buildRevealText(self._reveal_pic_bb or self.bg_bb)
        self:composeInto(self.canvas_bb, self.canvas.ops, self.bg_bb, nil,
            self._reveal_text_bb, self._reveal_pic_bb, true)   -- reveal buffers already resolved
    end
    -- the whole master was rebuilt: resync the panel-order mirror on the next render
    self:markCanvasDirty(0, 0, self.view.canvas_w, self.view.canvas_h)
end

-- Stamp a committed op into the 1:1 master.
function InkAwayView:stampOpIntoCanvas(op)
    if not self.canvas_bb then return end
    if op.kind == "text" then
        self:stampTextInto(self.canvas_bb, op)
        -- glyph blits do not report a span bbox; resync the whole mirror (text is
        -- committed rarely, so the one full copy on the next render is cheap)
        self:markCanvasDirty(0, 0, self.view.canvas_w, self.view.canvas_h)
        return
    end
    -- shared acc grows over every span written (base AND symmetry mirrors), so the
    -- panel-order mirror is resynced over exactly the op's footprint
    local cacc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local put = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h,
        self:opColor(op), cacc)
    local fill_put
    if op.kind == "shape" and op.fill_color and not op.fill then
        fill_put = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h,
            displayColor(op.fill_color, op.fill_alpha or 255), cacc)
    end
    if op.sym and op.sym ~= "off" then
        local refx, refy = Symmetry.canvasRefs(self.view.canvas_w, self.view.canvas_h)
        put = Symmetry.wrap(put, op.sym, refx, refy)
        if fill_put then fill_put = Symmetry.wrap(fill_put, op.sym, refx, refy) end
    end
    Export.paintGeom(op, put, fill_put)
    self:markCanvasDirtyAcc(cacc)
end

-- After a committed op is stamped into canvas_bb, get it onto the on-screen area_bb.
-- A full renderView rebuilds the WHOLE area (a full-area rotated blit into the
-- panel-order area_bb -- tens of ms in landscape), but only the op's rectangle
-- changed, so re-render just that region. Mirrored (symmetry) ops land in several
-- places, so fall back to a full render there. sx0..sy1 are the op's SCREEN bounds.
function InkAwayView:renderCommittedOp(op, sx0, sy0, sx1, sy1)
    if op and op.sym and op.sym ~= "off" then
        self:renderView()
        UIManager:setDirty(self, "ui", self:areaScreenRect())
        return
    end
    local v = self.view
    local pad = (op and op.width or 1) + (op and op.head or 0) + 6
    local ax0 = math.min(sx0, sx1) - v.area_x - pad
    local ay0 = math.min(sy0, sy1) - v.area_y - pad
    local ax1 = math.max(sx0, sx1) - v.area_x + pad
    local ay1 = math.max(sy0, sy1) - v.area_y + pad
    self:renderViewRect(ax0, ay0, ax1, ay1)   -- small rotated write, not the whole area
    local rx0 = math.max(v.area_x, v.area_x + ax0)
    local ry0 = math.max(v.area_y, v.area_y + ay0)
    local rx1 = math.min(v.area_x + v.area_w, v.area_x + ax1)
    local ry1 = math.min(v.area_y + v.area_h, v.area_y + ay1)
    if rx1 > rx0 and ry1 > ry0 then
        UIManager:setDirty(self, "ui", GeomUI:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 })
    end
end

return InkAwayView
