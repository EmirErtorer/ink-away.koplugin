--[[
Placed images (decoding, move, resize, rotate, flip, background removal and the
image menu) and the background image a drawing sits on.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ImageProc = require("ink/imageproc")
local InkGeom = require("ink/geom")
local IconMenu = require("ink/ui/iconmenu")

local Screen = Device.screen
local bbToRGBA = ImageProc.bbToRGBA
local bgRemovedRGBA = ImageProc.bgRemovedRGBA
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB
local resampleOriented = ImageProc.resampleOriented

local InkAwayView = {}

------------------------------------------------------------------------------
-- Symmetry, ghosting cleanup, and the background image.
------------------------------------------------------------------------------

-- Build a canvas-sized RGBA FFI buffer from the background (a BBRGB32 whose
-- memory is already r,g,b,alpha). One memcpy per row, not a million per-pixel
-- reads, so it is quick even on a Kindle. Alpha is kept, so a transparent PNG
-- stays transparent. Returns the buffer, or nil.
function InkAwayView:buildBgRGBA()
    return bbToRGBA(self.bg_bb, self.view.canvas_w, self.view.canvas_h)
end

-- Place an already-rendered source BlitBuffer as the background: fit it inside
-- the canvas keeping aspect (no stretching), centre it on a canvas-sized RGB32
-- buffer with white margins, and take ownership of `img` (it is freed here).
function InkAwayView:placeBackground(img, path)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local bg = fitIntoCanvasBB(img, W, H)
    if self.bg_bb then self.bg_bb:free() end
    self.bg_bb = bg
    self._bg_src = nil   -- a picture, not a cached PDF page
    self.bg_path = path
    self.export_bg = true
    self.bg_rgba = self:buildBgRGBA()
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

function InkAwayView:loadBackground(path)
    local RenderImage = require("ui/renderimage")
    local ok, img = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not ok or not img then
        UIManager:show(InfoMessage:new{ text = _("Could not open that image.") })
        return
    end
    self:placeBackground(img, path)
end


function InkAwayView:removeBackground()
    if self.bg_bb then self.bg_bb:free() end
    self.bg_bb, self.bg_rgba, self.bg_path, self._bg_src = nil, nil, nil, nil
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

function InkAwayView:chooseBackground()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:defaultDir(),
        onConfirm = function(path)
            local lower = path:lower()
            if lower:match("%.png$") or lower:match("%.jpe?g$") then
                self:loadBackground(path)
            else
                UIManager:show(InfoMessage:new{ text = _("Please choose a PNG or JPEG image.") })
            end
        end,
    })
end

------------------------------------------------------------------------------
-- Images: place a PNG/JPEG on the page, move/resize it with corner handles, and
-- rotate/flip/reorder it from a hold menu (mirrors the placed-shape menu). An
-- image is an op:
--   { kind="image", x, y, w, h (canvas px), path, natw, nath,
--     angle = 0|90|180|270, flip_h, flip_v }
-- The decoded pixels are cached by path and NEVER serialised, so a project file
-- stores just the path (+ box + orientation) and re-decodes on load. Images
-- compose into the master and export exactly like other ops, so every save
-- includes them. The selected image is skipped from the master by identity (not
-- a stored flag, so undo/redo snapshots stay clean) and drawn as a live overlay,
-- so moving and resizing never recompose the whole page.
------------------------------------------------------------------------------

local IMG_HANDLE = 44   -- touch target for the move / resize handles (screen px)
local IMG_MIN    = 24   -- smallest image side, in canvas px

-- Free every decoded / scaled / oriented / display image buffer and drop the
-- caches. Buffers can be shared (a scaled copy may BE its source when sizes
-- match), so a `seen` set frees each underlying buffer exactly once.
function InkAwayView:freeImageCache()
    local seen = {}
    local function drop(bb)
        if bb and bb.free and not seen[bb] then seen[bb] = true; pcall(function() bb:free() end) end
    end
    if self._img_disp then drop(self._img_disp.bb); self._img_disp = nil end
    if self._img_render then for _, e in pairs(self._img_render) do drop(e.bb) end; self._img_render = nil end
    if self._img_scaled then for _, e in pairs(self._img_scaled) do drop(e.bb) end; self._img_scaled = nil end
    if self._img_bb then for _, bb in pairs(self._img_bb) do drop(bb) end; self._img_bb = nil end
end

-- Free just the one screen-scaled display buffer (rebuilt on the next paint).
function InkAwayView:freeImageDisplay()
    local d = self._img_disp
    if d and d.bb and d.bb.free then pcall(function() d.bb:free() end) end
    self._img_disp = nil
end

-- A short signature of an op's orientation, used as a cache key so a rotate/flip
-- invalidates the oriented and scaled buffers.
local function orientSig(op)
    return ((op.angle or 0) % 360) .. "/" .. (op.flip_h and 1 or 0) .. "/" .. (op.flip_v and 1 or 0)
end

-- Decode (once, cached by path) the source picture for an op as a BBRGB32 that
-- keeps its alpha. The resident copy is capped to the canvas size: an image is
-- never shown or exported larger than the page, so keeping a full-resolution
-- decode (a high-megapixel photo is tens of MB in RGBA) would only waste memory.
-- We downscale once, preserving aspect, and never upscale. Returns the buffer or
-- nil. A `false` entry caches a decode failure so we do not retry every frame.
-- Decode a picture file into a BBRGB32 (keeping alpha), capped to the canvas size
-- (an image is never shown or exported larger than the page, and a full-resolution
-- decode of a big photo would waste memory). Returns the buffer or nil. Not cached
-- -- imageSrc caches per op.path; the background remover uses this directly on the
-- original file.
function InkAwayView:decodeCapped(path)
    if not path then return nil end
    local ok, img = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not (ok and img) then return nil end
    local iw, ih = img:getWidth(), img:getHeight()
    local W, H = self.view.canvas_w, self.view.canvas_h
    local cap = math.min(1, W / iw, H / ih)          -- <=1: only ever shrink
    local sw = math.max(1, math.floor(iw * cap + 0.5))
    local sh = math.max(1, math.floor(ih * cap + 0.5))
    local source = img
    if sw ~= iw or sh ~= ih then
        local sok, s = pcall(function() return RenderImage:scaleBlitBuffer(img, sw, sh, false) end)
        if sok and s then source = s end
    end
    -- Normalise to a BBRGB32 with a transparent ground, so the on-screen alpha-blit
    -- and the raw-bytes export both see a uniform r,g,b,a layout.
    local n = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
    n:fill(Blitbuffer.ColorRGB32(0, 0, 0, 0))
    pcall(function() n:blitFrom(source, 0, 0, 0, 0, sw, sh) end)
    if source ~= img and source.free then source:free() end
    if img.free then img:free() end
    return n
end

function InkAwayView:imageSrc(op)
    if not op or not op.path then return nil end
    self._img_bb = self._img_bb or {}
    local c = self._img_bb[op.path]
    if c ~= nil then return c or nil end
    local norm = self:decodeCapped(op.path) or false
    self._img_bb[op.path] = norm
    return norm or nil
end

-- Build a copy of `src` with the flips and a quarter-turn rotation baked in, by an
-- exact pixel permutation (no interpolation, no gaps). A quarter turn swaps the
-- dimensions. Returns the new buffer, or nil if the pixels could not be read.
-- The axis-aligned bounding box (canvas coords) of an image op at its angle,
-- computed analytically (no buffer): op.w/op.h are the unrotated size, the box
-- grows as it turns. Returns x, y, w, h.
local function imageBBox(op)
    local a = math.rad((op.angle or 0) % 360)
    local c, s = math.abs(math.cos(a)), math.abs(math.sin(a))
    local bw = op.w * c + op.h * s
    local bh = op.w * s + op.h * c
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    return cx - bw / 2, cy - bh / 2, bw, bh
end

-- The picture scaled to the op's on-page size (canvas px), UNROTATED. One copy is
-- kept per path, rebuilt only on a size change, so a resize drag never piles up
-- buffers and a move drag reuses the cached scale.
function InkAwayView:imageScaled(op)
    local src = self:imageSrc(op)
    if not src then return nil end
    local w = math.max(1, math.floor(op.w + 0.5))
    local h = math.max(1, math.floor(op.h + 0.5))
    self._img_scaled = self._img_scaled or {}
    local e = self._img_scaled[op.path]
    if e and e.w == w and e.h == h then return e.bb or nil end
    if e and e.bb and e.bb ~= src and e.bb.free then pcall(function() e.bb:free() end) end
    local scaled
    if w == src:getWidth() and h == src:getHeight() then
        scaled = src
    else
        local ok, s = pcall(function() return RenderImage:scaleBlitBuffer(src, w, h, false) end)
        scaled = (ok and s) or false
    end
    self._img_scaled[op.path] = { w = w, h = h, bb = scaled or false }
    return scaled or nil
end

-- The fully oriented (flipped + rotated) bitmap at on-page size, plus its top-left
-- in CANVAS coords -- which shifts away from op.x/op.y once the picture is rotated,
-- since the bounding box grows. Cached per path; rebuilt only when the size or
-- orientation changes (never per drag frame). With no orientation it returns the
-- plain scaled buffer at op.x/op.y, so the common case allocates nothing extra.
function InkAwayView:imageRendered(op)
    local scaled = self:imageScaled(op)
    if not scaled then return nil end
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    if orientSig(op) == "0/0/0" then return scaled, op.x, op.y end
    local sig = orientSig(op)
    local w, h = math.max(1, math.floor(op.w + 0.5)), math.max(1, math.floor(op.h + 0.5))
    self._img_render = self._img_render or {}
    local e = self._img_render[op.path]
    if not (e and e.sig == sig and e.w == w and e.h == h and e.bb) then
        if e and e.bb and e.bb ~= scaled and e.bb.free then pcall(function() e.bb:free() end) end
        local bb = resampleOriented(scaled, (op.angle or 0) % 360, op.flip_h, op.flip_v)
        e = { sig = sig, w = w, h = h, bb = bb or false }
        self._img_render[op.path] = e
    end
    if not e.bb then return nil end
    return e.bb, cx - e.bb:getWidth() / 2, cy - e.bb:getHeight() / 2
end

-- The rendered picture scaled to on-SCREEN size and its screen top-left, for the
-- live overlay, so the selected image is exactly the size and place it will occupy
-- once committed (no jump on Done). Returns bb, sx, sy (area-relative).
function InkAwayView:imageDisplayScaled(op)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return nil end
    local v = self.view
    local sx, sy = InkGeom.toScreen(v, ox, oy)
    local dw = math.max(1, math.floor(bb:getWidth() * v.zoom + 0.5))
    local dh = math.max(1, math.floor(bb:getHeight() * v.zoom + 0.5))
    if bb:getWidth() == dw and bb:getHeight() == dh then return bb, sx, sy end
    local sig = orientSig(op) .. ":" .. dw .. "x" .. dh
    local e = self._img_disp
    if e and e.path == op.path and e.sig == sig and e.bb then return e.bb, sx, sy end
    if e and e.bb and e.bb.free then pcall(function() e.bb:free() end) end
    local ok, s = pcall(function() return RenderImage:scaleBlitBuffer(bb, dw, dh, false) end)
    self._img_disp = { path = op.path, sig = sig, bb = (ok and s) or false }
    return (ok and s) or nil, sx, sy
end

-- RGBA byte buffer for export: the oriented picture at on-page size. Returns
-- buf, w, h, ox, oy (canvas top-left). Injected into Export as Export.image_raster.
function InkAwayView:exportImageRaster(op)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    local buf = bbToRGBA(bb, w, h)
    if not buf then return nil end
    return buf, w, h, ox, oy
end

-- Blit an image op into the canvas-space master `dst`, at its (rotated) top-left,
-- clipped to the canvas.
function InkAwayView:blitImageInto(dst, op)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local sw, sh = bb:getWidth(), bb:getHeight()
    local dx, dy = math.floor(ox + 0.5), math.floor(oy + 0.5)
    local sx0 = dx < 0 and -dx or 0
    local sy0 = dy < 0 and -dy or 0
    local cx0 = math.max(0, dx)
    local cy0 = math.max(0, dy)
    local cw = math.min(sw - sx0, W - cx0)
    local ch = math.min(sh - sy0, H - cy0)
    if cw > 0 and ch > 0 then
        pcall(function() dst:alphablitFrom(bb, cx0, cy0, sx0, sy0, cw, ch) end)
    end
end

-- The selected image's on-screen rectangle: the (rotated) bounding box, so the
-- frame and handles wrap the whole picture whatever its angle.
function InkAwayView:imageScreenRect()
    local op, v = self.active_image.op, self.view
    local bb, ox, oy = self:imageRendered(op)
    local bw = (bb and bb:getWidth() or op.w) * v.zoom
    local bh = (bb and bb:getHeight() or op.h) * v.zoom
    local sx, sy = InkGeom.toScreen(v, ox or op.x, oy or op.y)
    return { x = sx, y = sy, w = bw, h = bh }
end

-- Which part of the selected image a screen point falls on: a corner ("nw"/"ne"/
-- "sw"/"se") to resize, "move" inside, or "outside".
function InkAwayView:imageZone(sx, sy)
    local r = self:imageScreenRect()
    local function near(hx, hy)
        return sx >= hx - IMG_HANDLE and sx <= hx + IMG_HANDLE
           and sy >= hy - IMG_HANDLE and sy <= hy + IMG_HANDLE
    end
    if near(r.x, r.y) then return "nw" end
    if near(r.x + r.w, r.y) then return "ne" end
    if near(r.x, r.y + r.h) then return "sw" end
    if near(r.x + r.w, r.y + r.h) then return "se" end
    if sx >= r.x and sx <= r.x + r.w and sy >= r.y and sy <= r.y + r.h then return "move" end
    return "outside"
end

-- Refresh the union of two area-relative rects (plus handle margin), clamped to
-- the drawing area, with the given refresh mode.
function InkAwayView:refreshImageUnion(a, b, mode)
    local v = self.view
    local pad = IMG_HANDLE + 4
    local x0 = math.max(v.area_x, math.min(a.x, b.x) - pad)
    local y0 = math.max(v.area_y, math.min(a.y, b.y) - pad)
    local x1 = math.min(v.area_x + v.area_w, math.max(a.x + a.w, b.x + b.w) + pad)
    local y1 = math.min(v.area_y + v.area_h, math.max(a.y + a.h, b.y + b.h) + pad)
    if x1 > x0 and y1 > y0 then
        UIManager:setDirty(self, mode or "fast", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
    end
end

-- Pick the image under a canvas point (topmost first). Uses the rotated bounding
-- box so a turned picture is still grabbable over its whole visible area.
function InkAwayView:hitTestImage(sx, sy)
    local cx, cy = self:toCanvasClamped(sx, sy)
    local ops = self.canvas.ops
    for i = #ops, 1, -1 do
        local op = ops[i]
        if op.kind == "image" then
            local bx, by, bw, bh = imageBBox(op)
            if cx >= bx and cx <= bx + bw and cy >= by and cy <= by + bh then
                return { op = op, idx = i }
            end
        end
    end
    return nil
end

-- Keep the canvas receiving gestures while a popup is on top (KOReader only
-- delivers events to a lower widget that is is_always_active), so the picture can
-- be dragged with its menu open. The previous value is restored on close.
function InkAwayView:setSelectionActive(on)
    if on then
        if self._sel_prev_active == nil then self._sel_prev_active = self.is_always_active or false end
        self.is_always_active = true
    elseif self._sel_prev_active ~= nil then
        self.is_always_active = self._sel_prev_active
        self._sel_prev_active = nil
    end
end

-- Select an image. It stays in the ops list and in the master (composeInto only
-- skips it while it is actively dragged), so picking it up changes NO pixels of
-- the drawing -- only a frame and corner handles are drawn over its own rectangle.
-- We therefore refresh just that rectangle, never the whole area: a full-area
-- flashing refresh on every pick was the black flash when moving in pan mode.
-- `fresh` = a just-inserted image that is not in the master yet, so bake it in
-- once (that single insert refresh is expected).
function InkAwayView:selectImage(sel, fresh)
    if self.active_image and self.active_image.op ~= sel.op then self:finishImageEdit() end
    self.active_image = sel
    self._img_drag = nil
    self:freeImageDisplay()
    if fresh then
        self:composeCanvas(); self:renderView()
        UIManager:setDirty(self, "ui", self:areaScreenRect())
    else
        self:refreshImageUnion(self:imageScreenRect(), self:imageScreenRect(), "ui")
    end
end

-- Finish editing: close the menu, drop the selection, and recompose so the image
-- is baked back into the master at its final spot. Safe to call more than once
-- (e.g. the menu's tap-outside close and a Done both route here).
function InkAwayView:finishImageEdit()
    if not (self.active_image or self.image_rotating or self._image_menu) then return end
    local menu = self._image_menu; self._image_menu = nil
    if menu then pcall(function() UIManager:close(menu) end) end
    self:setSelectionActive(false)
    self.active_image = nil
    self._img_drag = nil
    self.image_rotating = nil
    self:freeImageDisplay()
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:deleteActiveImage()
    local sel = self.active_image
    if not sel then return end
    local menu = self._image_menu; self._image_menu = nil
    if menu then pcall(function() UIManager:close(menu) end) end
    self:setSelectionActive(false)
    self.active_image = nil
    self._img_drag = nil
    self.image_rotating = nil
    self:freeImageDisplay()
    self.canvas:pushHistory()
    self.canvas:removeOp(sel.idx)
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Copy-on-write before mutating the selected image, so the pre-drag / pre-edit
-- state stays in the undo snapshot (older snapshots keep the original op). Call
-- once at the start of a change; returns the editable clone.
function InkAwayView:beginImageEdit()
    self.canvas:pushHistory()
    local sel = self.active_image
    local clone = self.canvas:cloneOp(sel.op)
    self.canvas:replaceOp(sel.idx, clone)
    sel.op = clone
    self.dirty = true
    return clone
end

-- Apply one discrete edit (rotate / flip / etc.) to the selected image through
-- copy-on-write, then recompose. Undo/redo restore the previous op.
function InkAwayView:applyImageEdit(sel, mutate)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    mutate(clone)
    self.canvas:replaceOp(sel.idx, clone)
    sel.op = clone
    self.dirty = true
    self:freeImageDisplay()   -- size / orientation may have changed
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Rotate a quarter turn clockwise about the image centre. op.w/op.h are the
-- UNROTATED size, so a quarter turn only bumps op.angle; the bounding box (and
-- the frame) follow from the angle.
function InkAwayView:rotateImage90(sel)
    self:applyImageEdit(sel, function(o) o.angle = ((o.angle or 0) + 90) % 360 end)
    self:openImageMenu(sel)   -- keep the menu up for repeated turns
end

function InkAwayView:flipImage(sel, axis)
    self:applyImageEdit(sel, function(o)
        if axis == "h" then o.flip_h = not o.flip_h else o.flip_v = not o.flip_v end
    end)
    self:openImageMenu(sel)
end

-- Move the image to the top of the stack, so later strokes/images no longer cover
-- it. Reordering the array is safe against snapshots (the op itself is untouched).
function InkAwayView:imageToFront(sel)
    local ops = self.canvas.ops
    if sel.idx >= #ops then self:openImageMenu(sel); return end
    self.canvas:pushHistory()
    local op = table.remove(ops, sel.idx)
    ops[#ops + 1] = op
    sel.idx = #ops
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openImageMenu(sel)
end

-- Duplicate the selected image, offset a little, and select the copy (mirrors the
-- shape Duplicate). The pixels are shared by path -- only the box is copied -- so a
-- duplicate costs no extra image memory.
function InkAwayView:duplicateImage(sel)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    local d = self.grid_on and self.grid_size or 14
    clone.x = clone.x + d; clone.y = clone.y + d
    self.canvas.ops[#self.canvas.ops + 1] = clone
    self.active_image = { op = clone, idx = #self.canvas.ops }
    self._img_drag = nil
    self:freeImageDisplay()
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openImageMenu(self.active_image)
end

-- Folder for pictures Ink Away has processed (e.g. background removed), kept beside
-- the online-images folder so they are easy to find and never overwrite an original.
function InkAwayView:processedImagesDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage) then return nil end
    local parent = DataStorage:getDataDir() .. "/ink away"
    local dir = parent .. "/processed images"
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lok and lfs then
        if lfs.attributes(parent, "mode") ~= "directory" then pcall(lfs.mkdir, parent) end
        if lfs.attributes(dir, "mode") ~= "directory" then pcall(lfs.mkdir, dir) end
        if lfs.attributes(dir, "mode") == "directory" then return dir end
    end
    return nil
end

-- Remove a placed image's background (first-pass, brightness based -- see
-- bgRemovedRGBA). The cut-out is written as a transparent PNG and the op is
-- repointed at it (keeping the original path in op.src_path so a re-run works from
-- the original and nothing is lost), which reuses the whole decode/export path with
-- no special cases. It is a copy-on-write op edit, so Undo brings the original back.
function InkAwayView:removeImageBackground(sel)
    local op = sel and sel.op
    if not op then return end
    local src_path = op.src_path or op.path
    local src = self:decodeCapped(src_path)
    if not src then
        UIManager:show(InfoMessage:new{ text = _("Couldn't read that image."), icon = "notice-warning" })
        return
    end
    local w, h = src:getWidth(), src:getHeight()
    local rgba = bgRemovedRGBA(src)
    if src.free then pcall(function() src:free() end) end
    if not rgba then
        UIManager:show(InfoMessage:new{ text = _("Couldn't process that image."), icon = "notice-warning" })
        return
    end
    local dir = self:processedImagesDir()
    if not dir then
        UIManager:show(InfoMessage:new{ text = _("Couldn't prepare a folder for the image."), icon = "notice-warning" })
        return
    end
    self._img_proc_seq = (self._img_proc_seq or 0) + 1
    local path = string.format("%s/nobg-%d-%d.png", dir, os.time(), self._img_proc_seq)
    local wok = pcall(function() require("ffi/png").encodeToFile(path, rgba, w, h, 4) end)
    if not wok then
        UIManager:show(InfoMessage:new{ text = _("Couldn't save the processed image."), icon = "notice-warning" })
        return
    end
    -- copy-on-write: repoint at the cut-out, remember the original for a re-run
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(op)
    clone.src_path = src_path
    clone.path = path
    clone.natw, clone.nath = w, h
    self.canvas:replaceOp(sel.idx, clone)
    sel.op = clone
    self.active_image = sel
    self._img_drag = nil
    self:freeImageCache()   -- the path changed: drop the old decode, decode the cut-out
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openImageMenu(sel)
end

-- Free rotation: like the shape rotate, drag anywhere to spin the picture to any
-- angle; a live preview follows the finger, and the angle is committed on lift.
function InkAwayView:beginImageRotate(sel)
    self.image_rotating = { base = sel.op.angle or 0, cur = sel.op.angle or 0 }
    self:composeCanvas(); self:renderView()   -- drop it from the master; preview draws it
    UIManager:show(InfoMessage:new{
        text = _("Drag to rotate the image; lift to finish."), timeout = 2 })
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:imageRotateTouch(pos)
    local op, v = self.active_image.op, self.view
    local cx, cy = InkGeom.toScreen(v, op.x + op.w / 2, op.y + op.h / 2)
    local r = self.image_rotating
    r.cx, r.cy = cx, cy
    r.grab = math.deg(math.atan2(pos.y - cy, pos.x - cx))
    return true
end

function InkAwayView:imageRotateMove(pos)
    local r = self.image_rotating
    if not r.grab then return self:imageRotateTouch(pos) end
    local a = math.deg(math.atan2(pos.y - r.cy, pos.x - r.cx))
    r.cur = r.base + (a - r.grab)
    UIManager:setDirty(self, "fast", self:areaScreenRect())   -- preview redraws
    return true
end

function InkAwayView:imageRotateEnd()
    local r = self.image_rotating
    if not r then return true end
    self.image_rotating = nil
    local sel = self.active_image
    if sel then
        self:applyImageEdit(sel, function(o) o.angle = (r.cur % 360 + 360) % 360 end)
        self:openImageMenu(sel)
    end
    return true
end

-- The hold/tap menu for a placed image, anchored beside it -- same ButtonDialog
-- look as the shape edit menu (free rotate, a 90-degree preset, flips, to front,
-- and the same delete glyph). The image stays draggable underneath (see
-- setSelectionActive); a tap outside the menu deselects and bakes it in.
function InkAwayView:openImageMenu(sel)
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._image_menu then UIManager:close(self._image_menu); self._image_menu = nil end
    self:setSelectionActive(true)
    local dlg
    local function close() if dlg then UIManager:close(dlg) end end
    dlg = ButtonDialog:new{
        shrink_unneeded_width = true,
        tap_close_callback = function() self:finishImageEdit() end,
        anchor = function()
            local r = self:imageScreenRect()
            return GeomUI:new{ x = math.floor(r.x), y = math.floor(r.y),
                               w = math.ceil(r.w), h = math.ceil(r.h) }
        end,
        buttons = {
            {
                { text = "\u{27F3} " .. _("Rotate"),  callback = function() close(); self:beginImageRotate(sel) end },
                { text = "\u{21BB} " .. _("90\u{00B0}"), callback = function() close(); self:rotateImage90(sel) end },
            },
            {
                { text = "\u{2194} " .. _("Flip H"),  callback = function() close(); self:flipImage(sel, "h") end },
                { text = "\u{2195} " .. _("Flip V"),  callback = function() close(); self:flipImage(sel, "v") end },
            },
            {
                { text = "\u{25B2} " .. _("To front"),  callback = function() close(); self:imageToFront(sel) end },
                { text = "\u{29C9} " .. _("Duplicate"), callback = function() close(); self:duplicateImage(sel) end },
            },
            {
                { text = "\u{2702} " .. _("Remove background"), callback = function() close(); self:removeImageBackground(sel) end },
            },
            {
                { text = "\u{2715} " .. _("Delete"), callback = function() close(); self:deleteActiveImage() end },
                { text = _("Done"), callback = function() close(); self:finishImageEdit() end },
            },
        },
    }
    self._image_menu = dlg
    UIManager:show(dlg)
end

function InkAwayView:imageTouch(pos)
    local op = self.active_image.op
    local zone = self:imageZone(pos.x, pos.y)
    if zone == "move" then
        self._img_drag = { kind = "move", sx = pos.x, sy = pos.y, x0 = op.x, y0 = op.y }
        return true
    elseif zone ~= "outside" then
        if ((op.angle or 0) % 360) ~= 0 then
            -- rotated: resize by scaling uniformly about the centre
            local cxC, cyC = op.x + op.w / 2, op.y + op.h / 2
            local ccx, ccy = self:toCanvasClamped(pos.x, pos.y)
            local d0 = math.max(1, math.sqrt((ccx - cxC) ^ 2 + (ccy - cyC) ^ 2))
            self._img_drag = { kind = "resize", rotated = true, cxC = cxC, cyC = cyC,
                               d0 = d0, w0 = op.w, h0 = op.h }
        else
            -- upright: keep the OPPOSITE corner fixed, aspect locked
            local ax = (zone == "nw" or zone == "sw") and (op.x + op.w) or op.x
            local ay = (zone == "nw" or zone == "ne") and (op.y + op.h) or op.y
            self._img_drag = { kind = "resize", corner = zone, ax = ax, ay = ay, w0 = op.w, h0 = op.h }
        end
        return true
    else
        -- Touched outside the picture. If the menu is open, leave it: this touch is
        -- almost certainly on a menu button, and the dialog's own tap-outside close
        -- handles a genuine tap away. Only deselect here when no menu is up.
        if not self._image_menu then self:finishImageEdit() end
        return true
    end
end

function InkAwayView:imagePan(pos)
    local d = self._img_drag
    if not d then return true end
    -- Take the undo snapshot on the FIRST real movement (a plain tap that never
    -- moves records no history), then edit a clone from here on. Recompose once so
    -- the master drops the image (now it is the live overlay) for a smooth drag.
    if not d.began then
        self:beginImageEdit(); d.began = true
        self:composeCanvas(); self:renderView()
    end
    local op, v = self.active_image.op, self.view
    local old = self:imageScreenRect()
    if d.kind == "move" then
        op.x = d.x0 + (pos.x - d.sx) / v.zoom
        op.y = d.y0 + (pos.y - d.sy) / v.zoom
    elseif d.kind == "resize" and d.rotated then
        local ccx, ccy = self:toCanvasClamped(pos.x, pos.y)
        local dn = math.sqrt((ccx - d.cxC) ^ 2 + (ccy - d.cyC) ^ 2)
        local scale = math.max(dn / d.d0, IMG_MIN / math.min(d.w0, d.h0))
        op.w, op.h = d.w0 * scale, d.h0 * scale
        op.x, op.y = d.cxC - op.w / 2, d.cyC - op.h / 2
    elseif d.kind == "resize" then
        local cx, cy = self:toCanvasClamped(pos.x, pos.y)
        local wp = math.abs(cx - d.ax)
        local hp = math.abs(cy - d.ay)
        local scale = math.max(wp / d.w0, hp / d.h0, IMG_MIN / d.w0)
        local nw, nh = d.w0 * scale, d.h0 * scale
        op.w, op.h = nw, nh
        op.x = (d.corner == "nw" or d.corner == "sw") and (d.ax - nw) or d.ax
        op.y = (d.corner == "nw" or d.corner == "ne") and (d.ay - nh) or d.ay
    end
    self:refreshImageUnion(old, self:imageScreenRect(), "fast")
    return true
end

function InkAwayView:imageRelease()
    -- keep the image selected so it can be adjusted again; settle the view and,
    -- if a menu is open, re-anchor it to the picture's new spot (like shapes do)
    if self._img_drag then
        local moved = self._img_drag.began
        self._img_drag = nil
        if moved then self:composeCanvas(); self:renderView() end   -- bake it back in
        self:refreshImageUnion(self:imageScreenRect(), self:imageScreenRect(), "ui")
        if moved and self._image_menu then self:openImageMenu(self.active_image) end
    end
    return true
end

-- Draw the selected image as a live overlay (it is skipped from the master while
-- selected), at its true on-screen size, plus its frame and corner handles. While
-- free-rotating, a rotated preview follows the finger instead.
function InkAwayView:paintImageOverlay(bb, x, y)
    local op, v = self.active_image.op, self.view
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    local BLACKC = Blitbuffer.COLOR_BLACK

    if self.image_rotating then
        -- live rotation preview: rotate a screen-scaled copy to the current angle
        local scaled = self:imageScaled(op)
        if scaled then
            local dw = math.max(1, math.floor(op.w * v.zoom + 0.5))
            local dh = math.max(1, math.floor(op.h * v.zoom + 0.5))
            pcall(function()
                local su = RenderImage:scaleBlitBuffer(scaled, dw, dh, false)
                local prev = resampleOriented(su, self.image_rotating.cur, op.flip_h, op.flip_v)
                if su ~= scaled and su.free then su:free() end
                if prev then
                    local ccx, ccy = InkGeom.toScreen(v, op.x + op.w / 2, op.y + op.h / 2)
                    local pw, ph = prev:getWidth(), prev:getHeight()
                    local ox = math.floor(ccx + x - pw / 2)
                    local oy = math.floor(ccy + y - ph / 2)
                    local dx0 = math.max(ox, ax0); local dy0 = math.max(oy, ay0)
                    local dx1 = math.min(ox + pw, ax1); local dy1 = math.min(oy + ph, ay1)
                    if dx1 > dx0 and dy1 > dy0 then
                        bb:alphablitFrom(prev, dx0, dy0, dx0 - ox, dy0 - oy, dx1 - dx0, dy1 - dy0)
                    end
                    if prev.free then prev:free() end
                end
            end)
        end
        return
    end

    local r = self:imageScreenRect()
    local ox, oy = math.floor(r.x + x), math.floor(r.y + y)
    -- The image is only drawn here while it is being dragged (then the master has
    -- dropped it). A still, selected image stays in the master, so we draw only the
    -- frame and handles over it -- picking or dropping never nudges it.
    if self._img_drag and self._img_drag.began then
        local scaled = self:imageDisplayScaled(op)
        if scaled then
            local sw, sh = scaled:getWidth(), scaled:getHeight()
            local dx0 = math.max(ox, ax0); local dy0 = math.max(oy, ay0)
            local dx1 = math.min(ox + sw, ax1); local dy1 = math.min(oy + sh, ay1)
            if dx1 > dx0 and dy1 > dy0 then
                pcall(function() bb:alphablitFrom(scaled, dx0, dy0, dx0 - ox, dy0 - oy, dx1 - dx0, dy1 - dy0) end)
            end
        end
    end
    local fx, fy = math.floor(math.max(ox, ax0)), math.floor(math.max(oy, ay0))
    local fw = math.floor(math.min(ox + r.w, ax1)) - fx
    local fh = math.floor(math.min(oy + r.h, ay1)) - fy
    if fw > 0 and fh > 0 then
        bb:paintRect(fx, fy, fw, 1, BLACKC); bb:paintRect(fx, fy + fh - 1, fw, 1, BLACKC)
        bb:paintRect(fx, fy, 1, fh, BLACKC); bb:paintRect(fx + fw - 1, fy, 1, fh, BLACKC)
    end
    -- corner handles (clamped into the area so they never draw over the toolbar)
    local hs = 12
    local function handle(hx, hy)
        local px = math.max(ax0, math.min(ax1 - hs, math.floor(hx - hs / 2)))
        local py = math.max(ay0, math.min(ay1 - hs, math.floor(hy - hs / 2)))
        bb:paintRect(px, py, hs, hs, BLACKC)
    end
    handle(ox, oy); handle(ox + r.w, oy); handle(ox, oy + r.h); handle(ox + r.w, oy + r.h)
end

-- Insert a new image from a file: fit it to ~60% of the visible area (so its
-- corners show for dragging), centre it in the viewport, and select it. The
-- picture lands in Pan mode with its edit menu already open (see the tail of this
-- function) so it can be moved, resized, duplicated or deleted straight away.
function InkAwayView:insertImage(path)
    local tmp = { kind = "image", path = path, x = 0, y = 0, w = 1, h = 1 }
    local src = self:imageSrc(tmp)
    if not src then
        UIManager:show(InfoMessage:new{ text = _("Could not open that image.") })
        return
    end
    local natw, nath = src:getWidth(), src:getHeight()
    local v = self.view
    local maxw = 0.6 * v.area_w / v.zoom
    local maxh = 0.6 * v.area_h / v.zoom
    local s = math.min(maxw / natw, maxh / nath)
    if s <= 0 then s = 1 end
    local op = { kind = "image", path = path, natw = natw, nath = nath,
                 w = math.max(IMG_MIN, natw * s), h = math.max(IMG_MIN, nath * s) }
    local ccx = v.pan_x + (v.area_w / 2) / v.zoom
    local ccy = v.pan_y + (v.area_h / 2) / v.zoom
    op.x = math.max(0, math.min(v.canvas_w - op.w, ccx - op.w / 2))
    op.y = math.max(0, math.min(v.canvas_h - op.h, ccy - op.h / 2))
    self.canvas:pushHistory()
    self.canvas.ops[#self.canvas.ops + 1] = op
    self.dirty = true
    -- Drop straight into Pan mode with the picture selected and its edit menu open,
    -- exactly as if the reader had tapped it there. Pan mode's move/resize is the
    -- smooth, responsive one, and it isn't obvious you have to switch to it -- so a
    -- freshly added image is immediately ready to move, resize, duplicate or delete.
    self:setTool("pan")
    self:selectImage({ op = op, idx = #self.canvas.ops }, true)   -- fresh: bake it in once
    self:openImageMenu(self.active_image)
end

-- The image tool now asks first: a local file, or browse online. Browsing is
-- entirely optional -- Ink Away never needs a connection -- so the local path is
-- the dark (primary) button and stays exactly as it always was.
function InkAwayView:chooseImage()
    self:finishImageEdit()
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._img_src_dialog then UIManager:close(self._img_src_dialog); self._img_src_dialog = nil end
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("Add image"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("Local file"), content_w, function()
            closeSelf(); self:chooseLocalImage() end, true))
        add(vspan(10))
        add(self:actionButton(_("Browse online"), content_w, function()
            closeSelf(); self:browseOnlineImages() end))
        add(vspan(8))
        add(TextBoxWidget:new{ text = _("Browsing needs Wi-Fi. Ink Away itself never requires a connection."),
            face = Font:getFace("cfont", 13), width = content_w,
            fgcolor = Blitbuffer.ColorRGB32(0x80, 0x80, 0x80, 0xFF) })
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._img_src_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._img_src_dialog = nil end }
    UIManager:show(self._img_src_dialog)
end

-- The original local-file picker, unchanged in behaviour.
function InkAwayView:chooseLocalImage()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:defaultDir(),
        onConfirm = function(path)
            local lower = path:lower()
            if lower:match("%.png$") or lower:match("%.jpe?g$") then
                self:insertImage(path)
            else
                UIManager:show(InfoMessage:new{ text = _("Please choose a PNG or JPEG image.") })
            end
        end,
    })
end

-- Remove any loaded background image (used when switching into notebook mode).
function InkAwayView:clearBackground()
    if self.bg_bb then pcall(function() self.bg_bb:free() end) end
    self.bg_bb, self.bg_rgba, self.bg_path, self._bg_src = nil, nil, nil, nil
    self.export_bg = true
end

return InkAwayView
