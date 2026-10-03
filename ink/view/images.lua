--[[
Placed images (decoding, move, resize, rotate, flip, background removal and the
image menu) and the background image a drawing sits on.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local GeomUI = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local ImageProc = require("ink/imageproc")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Storage = require("ink/storage")

local Screen = Device.screen
local bbToRGBA = ImageProc.bbToRGBA
local bgRemovedRGBA = ImageProc.bgRemovedRGBA
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB
local resampleOriented = ImageProc.resampleOriented

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local IMG_HANDLE = 44   -- touch target for the move / resize handles (screen px)
local IMG_MIN    = 24   -- smallest image side, in canvas px
local IMG_PAD    = IMG_HANDLE + 4   -- refresh margin around the frame and handles

local InkAwayView = {}

------------------------------------------------------------------------------
-- Background image
------------------------------------------------------------------------------

-- Copy the background into a canvas-sized RGBA buffer for export. A BBRGB32 is
-- already r,g,b,a in memory, so this is one memcpy per row. Alpha is kept, so a
-- transparent PNG stays transparent. Returns the buffer, or nil.
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
    self:markDirty()
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

function InkAwayView:loadBackground(path)
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

-- Let the reader pick a PNG or JPEG, starting in the image folder.
function InkAwayView:pickImageFile(on_pick)
    self:pickFile(self:defaultDir(), function(path)
        local lower = path:lower()
        if lower:match("%.png$") or lower:match("%.jpe?g$") then
            on_pick(path)
        else
            UIManager:show(InfoMessage:new{ text = _("Please choose a PNG or JPEG image.") })
        end
    end)
end

function InkAwayView:chooseBackground()
    self:pickImageFile(function(path) self:loadBackground(path) end)
end

------------------------------------------------------------------------------
-- Placed images: a PNG or JPEG on the page, moved and resized with corner
-- handles and rotated, flipped or reordered from its menu. An image is an op:
--   { kind="image", x, y, w, h (canvas px), path, natw, nath,
--     angle = 0|90|180|270, flip_h, flip_v }
-- Decoded pixels are cached by path and never saved, so a project stores the
-- path, box and orientation and decodes again on load. Images compose into the
-- master and export like any other op. While dragged or rotated, the selected
-- image is skipped from the master by identity (no stored flag, so undo
-- snapshots stay clean) and drawn as a live overlay instead.
------------------------------------------------------------------------------

-- Free every decoded, scaled, oriented and display buffer and drop the caches.
-- Buffers can be shared (a scaled copy is its source when the sizes match), so a
-- `seen` set frees each one exactly once.
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

-- A short signature of an op's orientation, used as a cache key so a rotation or
-- flip invalidates the oriented and scaled buffers.
local function orientSig(op)
    return ((op.angle or 0) % 360) .. "/" .. (op.flip_h and 1 or 0) .. "/" .. (op.flip_v and 1 or 0)
end

-- Decode a picture file into a BBRGB32 (keeping alpha), shrunk to fit the canvas
-- with its aspect kept: an image is never shown or exported larger than the page,
-- and a full-resolution photo would take tens of MB. Returns the buffer or nil.
-- Not cached; imageSrc caches per path, and the background remover decodes the
-- original file directly.
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

-- The decoded picture for an op, cached by path. A `false` entry caches a failed
-- decode so it is not retried on every frame.
function InkAwayView:imageSrc(op)
    if not op or not op.path then return nil end
    self._img_bb = self._img_bb or {}
    local c = self._img_bb[op.path]
    if c ~= nil then return c or nil end
    local norm = self:decodeCapped(op.path) or false
    self._img_bb[op.path] = norm
    return norm or nil
end

-- The axis-aligned bounding box (canvas coords) of an image op at its angle,
-- computed without a buffer: op.w and op.h are the unrotated size and the box
-- grows as it turns. Returns x, y, w, h.
local function imageBBox(op)
    local a = math.rad((op.angle or 0) % 360)
    local c, s = math.abs(math.cos(a)), math.abs(math.sin(a))
    local bw = op.w * c + op.h * s
    local bh = op.w * s + op.h * c
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    return cx - bw / 2, cy - bh / 2, bw, bh
end

-- The picture scaled to the op's on-page size (canvas px), unrotated. One copy is
-- kept per path and rebuilt only on a size change, so a resize drag never piles
-- up buffers and a move drag reuses the cached scale.
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

-- The flipped and rotated bitmap at on-page size, and its top-left in canvas
-- coords (which moves away from op.x, op.y once rotated, as the box grows).
-- Cached per path and rebuilt only when the size or orientation changes. With no
-- orientation it is the plain scaled buffer at op.x, op.y, so the common case
-- allocates nothing extra.
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

-- The rendered picture at on-screen size and its top-left, for the live overlay,
-- so the selected image is exactly where it will be once committed (no jump on
-- Done). Returns bb, sx, sy (area-relative).
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
-- clipped to the canvas, or to `region` (a canvas rect) when given.
function InkAwayView:blitImageInto(dst, op, region)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return end
    local r = region or { x0 = 0, y0 = 0, x1 = self.view.canvas_w, y1 = self.view.canvas_h }
    local dx, dy = math.floor(ox + 0.5), math.floor(oy + 0.5)
    local cx0, cy0 = math.max(r.x0, dx), math.max(r.y0, dy)
    local cw = math.min(dx + bb:getWidth(), r.x1) - cx0
    local ch = math.min(dy + bb:getHeight(), r.y1) - cy0
    if cw > 0 and ch > 0 then
        pcall(function() dst:alphablitFrom(bb, cx0, cy0, cx0 - dx, cy0 - dy, cw, ch) end)
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
    if InkGeom.inRect(sx, sy, r) then return "move" end
    return "outside"
end

-- Refresh the selected image's rect, with room for its frame and handles.
function InkAwayView:refreshImageRect(mode)
    local r = self:imageScreenRect()
    self:refreshRectUnion(r, r, IMG_PAD, mode)
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

-- Select an image. It stays in the master (composeInto skips it only while it is
-- dragged), so selecting changes no pixels of the drawing: only the frame and
-- handles appear over its rectangle, and only that rectangle is refreshed.
-- `fresh` marks a just-inserted image that is not in the master yet; it is baked
-- in once.
function InkAwayView:selectImage(sel, fresh)
    if self.active_image and self.active_image.op ~= sel.op then self:finishImageEdit() end
    self.active_image = sel
    self._img_drag = nil
    self:freeImageDisplay()
    if fresh then
        self:recompose()
    else
        self:refreshImageRect("ui")
    end
end

-- Finish editing: close the menu, drop the selection, and recompose so the image
-- is baked back into the master at its final spot. Safe to call more than once
-- (the menu's tap-outside close and Done both end up here).
function InkAwayView:finishImageEdit()
    if not (self.active_image or self.image_rotating or self._image_menu) then return end
    self:clearImageSelection()
    self:recompose()
end

-- Drop the image selection: close its menu, release the gesture grab and forget
-- any drag or rotation, without repainting.
function InkAwayView:clearImageSelection()
    local menu = self._image_menu; self._image_menu = nil
    if menu then pcall(function() UIManager:close(menu) end) end
    self:setSelectionActive(false)
    self.active_image = nil
    self._img_drag = nil
    self.image_rotating = nil
    self:freeImageDisplay()
end

function InkAwayView:deleteActiveImage()
    local sel = self.active_image
    if not sel then return end
    self:clearImageSelection()
    self.canvas:pushHistory()
    self.canvas:removeOp(sel.idx)
    self:markDirty()
    self:recompose()
end

-- Copy-on-write before changing the selected image, so the undo snapshot keeps
-- the original op. Call once at the start of a change; returns the editable clone.
function InkAwayView:beginImageEdit()
    local sel = self.active_image
    sel.op = self:editOp(sel.idx, sel.op)
    return sel.op
end

-- Apply one discrete edit (a rotation, a flip) to the selected image through
-- copy-on-write, then recompose. Undo restores the previous op.
function InkAwayView:applyImageEdit(sel, mutate)
    sel.op = self:editOp(sel.idx, sel.op, mutate)
    self:freeImageDisplay()   -- size / orientation may have changed
    self:recompose()
end

-- Rotate a quarter turn clockwise about the image centre. op.w and op.h are the
-- unrotated size, so only op.angle changes; the bounding box and frame follow.
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

-- Move the image to the top of the stack, above later strokes and images.
function InkAwayView:imageToFront(sel)
    self:opToFront(sel)
    self:openImageMenu(sel)
end

-- Duplicate the selected image, offset a little, and select the copy. The pixels
-- are shared by path, so a duplicate costs no extra image memory.
function InkAwayView:duplicateImage(sel)
    self.active_image = self:duplicateOp(sel)
    self._img_drag = nil
    self:freeImageDisplay()
    self:recompose()
    self:openImageMenu(self.active_image)
end

-- Remove a placed image's background (see ImageProc.bgRemovedRGBA). The cut-out
-- is saved as a transparent PNG and the op points at it, so decoding and export
-- need no special case; op.src_path keeps the original for a re-run. It is a
-- copy-on-write edit, so Undo brings the original back.
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
    -- the cut-out goes beside the online images, never over the original
    local dir = Storage.appDir("processed images")
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
    sel.op = self:editOp(sel.idx, op, function(o)
        o.src_path = src_path
        o.path = path
        o.natw, o.nath = w, h
    end)
    self.active_image = sel
    self._img_drag = nil
    self:freeImageCache()   -- the path changed: drop the old decode, decode the cut-out
    self:recompose()
    self:openImageMenu(sel)
end

-- Free rotation: drag anywhere to spin the picture to any angle. A live preview
-- follows the finger and the angle is committed on lift.
function InkAwayView:beginImageRotate(sel)
    self.image_rotating = { base = sel.op.angle or 0, cur = sel.op.angle or 0 }
    self:composeCanvas(); self:renderView()   -- drop it from the master; preview draws it
    UIManager:show(InfoMessage:new{
        text = _("Drag to rotate the image; lift to finish."), timeout = 2 })
    self:refreshArea()
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

-- The menu for a placed image, anchored beside it like the shape edit menu. The
-- image stays draggable underneath (see setSelectionActive); a tap outside the
-- menu deselects it and bakes it in.
function InkAwayView:openImageMenu(sel)
    self:closeSheet("_image_menu")
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
            -- upright: keep the opposite corner fixed, aspect locked
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
    -- Take the undo snapshot on the first real movement (a plain tap records no
    -- history), then edit a clone. Recompose once so the master drops the image
    -- and the live overlay carries it for a smooth drag.
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
    self:refreshRectUnion(old, self:imageScreenRect(), IMG_PAD, "fast")
    return true
end

function InkAwayView:imageRelease()
    -- keep the image selected so it can be adjusted again; settle the view and,
    -- if a menu is open, re-anchor it to the picture's new spot (like shapes do)
    if self._img_drag then
        local moved = self._img_drag.began
        self._img_drag = nil
        if moved then self:composeCanvas(); self:renderView() end   -- bake it back in
        self:refreshImageRect("ui")
        if moved and self._image_menu then self:openImageMenu(self.active_image) end
    end
    return true
end

-- Alpha-blit `src` with its top-left at (ox, oy), clipped to the box (x0, y0)-(x1, y1).
local function blitClipped(bb, src, ox, oy, x0, y0, x1, y1)
    local dx0, dy0 = math.max(ox, x0), math.max(oy, y0)
    local dx1, dy1 = math.min(ox + src:getWidth(), x1), math.min(oy + src:getHeight(), y1)
    if dx1 > dx0 and dy1 > dy0 then
        bb:alphablitFrom(src, dx0, dy0, dx0 - ox, dy0 - oy, dx1 - dx0, dy1 - dy0)
    end
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
                    blitClipped(bb, prev, math.floor(ccx + x - prev:getWidth() / 2),
                        math.floor(ccy + y - prev:getHeight() / 2), ax0, ay0, ax1, ay1)
                    if prev.free then prev:free() end
                end
            end)
        end
        return
    end

    local r = self:imageScreenRect()
    local ox, oy = math.floor(r.x + x), math.floor(r.y + y)
    -- The image itself is drawn here only while dragged (the master has dropped
    -- it then). A still, selected image stays in the master and gets just the
    -- frame and handles, so selecting or dropping it never nudges it.
    if self._img_drag and self._img_drag.began then
        local scaled = self:imageDisplayScaled(op)
        if scaled then pcall(blitClipped, bb, scaled, ox, oy, ax0, ay0, ax1, ay1) end
    end
    local fx, fy = math.floor(math.max(ox, ax0)), math.floor(math.max(oy, ay0))
    local fw = math.floor(math.min(ox + r.w, ax1)) - fx
    local fh = math.floor(math.min(oy + r.h, ay1)) - fy
    if fw > 0 and fh > 0 then Paint.outline(bb, fx, fy, fw, fh, BLACKC) end
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
-- corners show for dragging), centre it in the viewport and select it.
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
    self:markDirty()
    -- Switch to Pan with the picture selected and its menu open, as if it had been
    -- tapped there, so a new image is ready to move, resize or delete at once.
    self:setTool("pan")
    self:selectImage({ op = op, idx = #self.canvas.ops }, true)   -- fresh: bake it in once
    self:openImageMenu(self.active_image)
end

-- Ask where a new image comes from: a local file (the primary button) or an
-- online search. Browsing is optional; Ink Away never needs a connection.
function InkAwayView:chooseImage()
    self:finishImageEdit()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_img_src_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
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
        return content
    end
    self:showSheet("_img_src_dialog", build)
end

-- Pick a local PNG or JPEG and insert it.
function InkAwayView:chooseLocalImage()
    self:pickImageFile(function(path) self:insertImage(path) end)
end

-- Remove any loaded background image (used when switching into notebook mode).
function InkAwayView:clearBackground()
    if self.bg_bb then pcall(function() self.bg_bb:free() end) end
    self.bg_bb, self.bg_rgba, self.bg_path, self._bg_src = nil, nil, nil, nil
    self.export_bg = true
end

return InkAwayView
