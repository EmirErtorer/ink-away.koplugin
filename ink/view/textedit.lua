--[[
Editing a text box: opening and committing it, the keyboard, caret and typing,
per-box undo, and dragging to move, resize or select.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local GeomUI = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local InkGeom = require("ink/geom")
local Notebook = require("ink/notebook")
local Paint = require("ink/paint")
local Text = require("ink/text")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local TILE_BG = Paint.TILE_BG

local InkAwayView = {}

------------------------------------------------------------------------------
-- Undo / exit
------------------------------------------------------------------------------

-- Apply one stored word-level step to a COMMITTED text box (the op at ops[idx]),
-- without re-opening it or bringing up the keyboard. `from` is the stack to pop,
-- `to` the stack to push the current state onto (undo <-> redo). Uses clone +
-- replace, like a placed-shape edit, so canvas snapshots that still reference the
-- old op are never mutated. Returns true if a step was applied.
function InkAwayView:commitTextStep(idx, from, to)
    local ops = self.canvas.ops
    local op = ops[idx]
    local h = op and self._text_hist[op]
    if not (h and from and #from > 0) then return false end
    local snap = table.remove(from)
    to[#to + 1] = { paras = Notebook.deepcopy(op.paras), cur = { p = 1, o = 0 } }
    local nop = self.canvas:cloneOp(op)   -- shallow copy; shares nothing we mutate
    nop.paras = snap.paras                -- a fresh, deep-copied paragraph list
    ops[idx] = nop
    self._text_hist[nop] = h              -- carry the history onto the new identity
    self._text_hist[op] = nil
    self._peel_op = nop                   -- we are actively peeling this box
    self.dirty = true
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

-- Is the most recent op a committed text box that still has word-level history to
-- peel back (or, for redo, to replay)? Returns idx, hist or nil.
function InkAwayView:topTextHist()
    local ops = self.canvas.ops
    local top = ops[#ops]
    local h = top and top.kind == "text" and self._text_hist[top]
    if h then return #ops, h end
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Text notes: creating, editing and moving a text box. The box being edited is
-- kept off the ops list and drawn as a live overlay (like a shape preview), so
-- typing never recomposes the whole page -- only the box's rectangle refreshes.
-- On finish it is baked into the master bitmap and added to the ops, so it
-- saves, undoes and exports exactly like ink.
------------------------------------------------------------------------------

local TEXT_HANDLE = 40   -- touch target for the move / resize handles (screen px)

-- Lay the editing op out at the current zoom (so the overlay is crisp) and grow
-- an auto-height box to fit. Returns layout, ctx and the width-scaled proxy the
-- engine measured against.
-- Bump to invalidate the cached layout (call after any edit that changes the
-- text, the wrap width or the font/size).
function InkAwayView:invalidateLayout() self._lay_ver = (self._lay_ver or 0) + 1 end

-- Lay the editing op out at the current zoom, caching the result: the layout is
-- otherwise recomputed several times per keystroke (scroll-into-view, then the
-- paint, then the caret) which is O(text) each time. The cache is keyed on a
-- version bumped by edits, plus the op and zoom.
function InkAwayView:editTextLayout()
    local op = self.editing_text
    local zoom = self.view.zoom
    local ver = self._lay_ver or 0
    local c = self._lay_cache
    if c and c.op == op and c.ver == ver and c.zoom == zoom then
        return c.lay, c.ctx, c.proxy
    end
    local ctx = self:textCtx(op, zoom)
    local proxy = setmetatable({ w = op.w * zoom }, { __index = op })
    local lay = Text.layout(proxy, ctx)
    if op.auto_h then op.h = math.max(1, lay.height / zoom) end
    self._lay_cache = { op = op, ver = ver, zoom = zoom, lay = lay, ctx = ctx, proxy = proxy }
    return lay, ctx, proxy
end

-- The editing box rectangle on screen (clamped later by callers). InkGeom.toScreen
-- already includes the area origin, so we must NOT add area_x/area_y again -- doing
-- so shifted the editing overlay down by one toolbar height versus the committed
-- box (the "box jumps down a notch when reopened" bug).
function InkAwayView:textBoxScreenRect()
    local op, v = self.editing_text, self.view
    local sx, sy = InkGeom.toScreen(v, op.x, op.y)
    return { x = sx, y = sy, w = op.w * v.zoom, h = op.h * v.zoom }
end

-- Lay out the two edit buttons: [ Format ][ ✓ Done ] pinned to the top-right.
-- The label sizes depend only on the (constant) labels and DPI, so measure them
-- once and cache: this method runs on every overlay paint and every touch, and
-- building throwaway TextWidgets each time was needless work on e-ink.
function InkAwayView:textEditButtons()
    local v = self.view
    local m = self._text_btn_metrics
    if not m then
        -- the same look as the sheets: a grey rounded "Format" button and the black
        -- "Done" pill. The labels are built once and reused on every paint.
        local face = Font:getFace("cfont", 15)
        local fw = TextWidget:new{ text = _("Format"), face = face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local dw = TextWidget:new{ text = _("Done"), face = face, bold = true, fgcolor = WHITE }
        local fs, ds = fw:getSize(), dw:getSize()
        local hpad = Screen:scaleBySize(16)
        local h = math.max(Screen:scaleBySize(34), math.max(fs.h, ds.h) + Screen:scaleBySize(12))
        m = { fw = fw, dw = dw, h = h, fwid = fs.w + 2 * hpad,
              dwid = math.max(Screen:scaleBySize(84), ds.w + 2 * hpad),
              radius = Screen:scaleBySize(11), gap = Screen:scaleBySize(8) }
        self._text_btn_metrics = m
    end
    local edge = Screen:scaleBySize(8)
    local y = v.area_y + edge
    local dx = v.area_x + v.area_w - m.dwid - edge
    local fx = dx - m.fwid - m.gap
    return {
        done   = { x = dx, y = y, w = m.dwid, h = m.h, dark = true },
        format = { x = fx, y = y, w = m.fwid, h = m.h },
    }
end

-- Which part of the box a screen point falls on: "resize", "move", "inside" or
-- "outside".
function InkAwayView:textZone(sx, sy)
    local r = self:textBoxScreenRect()
    if sx >= r.x + r.w - TEXT_HANDLE and sx <= r.x + r.w + TEXT_HANDLE
       and sy >= r.y + r.h - TEXT_HANDLE and sy <= r.y + r.h + TEXT_HANDLE then
        return "resize"
    end
    -- the move handle is a strip just above the box's top-left
    if sx >= r.x - TEXT_HANDLE and sx <= r.x + TEXT_HANDLE
       and sy >= r.y - TEXT_HANDLE and sy <= r.y + TEXT_HANDLE then
        return "move"
    end
    if sx >= r.x and sx <= r.x + r.w and sy >= r.y and sy <= r.y + r.h then
        return "inside"
    end
    return "outside"
end

-- Refresh just the box's rectangle (plus a margin for the frame / handles).
function InkAwayView:refreshTextBox(mode)
    self:hideClipBubble()   -- any change to the box (typing, caret, selection) dismisses it
    local v = self.view
    local r = self:textBoxScreenRect()
    local pad = TEXT_HANDLE + 4
    local x0 = math.max(v.area_x, r.x - pad)
    local y0 = math.max(v.area_y, r.y - pad)
    local x1 = math.min(v.area_x + v.area_w, r.x + r.w + pad)
    local y1 = math.min(v.area_y + v.area_h, r.y + r.h + pad)
    if x1 > x0 and y1 > y0 then
        UIManager:setDirty(self, mode or "ui", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
    end
end

-- Every few edits, clear the fast-refresh ghosting the box leaves behind.
function InkAwayView:afterTextEdit()
    self:invalidateLayout()   -- the text just changed
    self:ensureCaretVisible()
    self._text_edits = (self._text_edits or 0) + 1
    if self._text_edits >= 24 then
        self._text_edits = 0
        self:refreshTextBox("flashui")
    else
        self:refreshTextBox("ui")
    end
end

-- Screen y of the top of the on-screen keyboard (or the screen bottom if none).
function InkAwayView:keyboardTop()
    local kb = self._text_kb
    if kb and kb.dimen and kb.dimen.h then return self.screen_h - kb.dimen.h end
    return self.screen_h
end

-- Scroll the page vertically so the caret line sits in the strip between the
-- toolbar and the keyboard (the keyboard otherwise hides the box you type in).
function InkAwayView:ensureCaretVisible()
    if not self.editing_text then return end
    local v = self.view
    local lay, ctx = self:editTextLayout()
    local c = Text.caret(self.editing_text, lay, self.text_cur, ctx)   -- op-local, scale=zoom
    local caret_top = self.editing_text.y + c.y / v.zoom               -- canvas coords
    local caret_bot = caret_top + c.h / v.zoom
    local margin = 12
    local top_lim = v.area_y + margin
    local bot_lim = self:keyboardTop() - margin
    local top_scr = v.area_y + (caret_top - v.pan_y) * v.zoom
    local bot_scr = v.area_y + (caret_bot - v.pan_y) * v.zoom
    local new_pan = v.pan_y
    if bot_scr > bot_lim then
        new_pan = caret_bot - (bot_lim - v.area_y) / v.zoom
    elseif top_scr < top_lim then
        new_pan = caret_top - (top_lim - v.area_y) / v.zoom
    end
    new_pan = math.max(0, math.min(math.max(0, v.canvas_h - 1), new_pan))
    if math.abs(new_pan - v.pan_y) >= 1 then
        v.pan_y = new_pan
        self:renderView()
        UIManager:setDirty(self, "ui")
    end
end

-- Default size and width for a new box on this device / page.
function InkAwayView:newTextAt(pos)
    local v = self.view
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    -- span the full page (the grid runs edge to edge) with only a small margin
    local margin = math.max(6, math.floor(v.canvas_w * 0.02))
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    local op = Text.new{ x = margin, y = cy, w = v.canvas_w - 2 * margin, size = size,
        font = self.text_font, align = "left", grid_snap = self.text_grid_snap }
    -- snap the box origin to the ruling if the user asked for grid alignment
    if self.text_grid_snap then self:snapTextBoxToGrid(op) end
    self:startTextEdit(op, { p = 1, o = 0 }, true, nil)
end

-- Build the on-screen keyboard and point it at this view's text methods.
function InkAwayView:showTextKeyboard()
    if self._text_kb then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local view = self
    local inputbox = {
        parent = self,
        addChars = function(_, s) view:textAddChars(s) end,
        delChar = function() view:textDelChar() end,
        delWord = function() view:textDelChar() end,
        delToStartOfLine = function() view:textDelToBOL() end,
        leftChar = function() view:textMove(-1, 0) end,
        rightChar = function() view:textMove(1, 0) end,
        upLine = function() view:textMove(0, -1) end,
        downLine = function() view:textMove(0, 1) end,
        goToStartOfLine = function() view:textHome() end,
        goToEndOfLine = function() view:textEnd() end,
        scrollUp = function() end,
        scrollDown = function() end,
    }
    self._text_kb = VirtualKeyboard:new{ keyboard_layer = 2, inputbox = inputbox }
    -- With the keyboard on top of the window stack, UIManager only delivers
    -- gestures to lower widgets that are is_always_active. Without this the
    -- toolbar and canvas would go dead while typing (no way to switch tool or
    -- dismiss). We turn it back off when editing ends.
    self.is_always_active = true
    UIManager:show(self._text_kb)
end

function InkAwayView:hideTextKeyboard()
    self.is_always_active = false
    if self._text_kb then
        UIManager:close(self._text_kb)
        self._text_kb = nil
    end
end

-- Enter edit mode on `op`. For an existing op we edit a deep copy and hide the
-- original, so an Undo after editing restores the text as it was.
function InkAwayView:startTextEdit(op, cur, is_new, idx, hit_pos)
    self:flushPending(); self:flushShape()
    if self.selection or self.lassoing then self:clearSelection() end
    if is_new then
        self.editing_text = op
    else
        self._text_orig = self.canvas.ops[idx]
        -- copy BEFORE hiding the original, so the editable copy is not itself
        -- marked hidden (that made the box vanish after committing an edit)
        self.editing_text = Notebook.deepcopy(op)
        self.editing_text.hidden = nil
        self._text_orig.hidden = true
        self:composeCanvas()
    end
    self.editing_idx = idx
    self.editing_is_new = is_new
    self.text_cur = cur or { p = 1, o = 0 }
    self.text_sel = nil
    self._text_edits = 0
    self._text_undo, self._text_redo, self._text_coalesce = {}, {}, nil
    -- Opened by a touch (the finger is still down): wait for it to lift before
    -- showing the keyboard. Otherwise a box placed low on the page brings the
    -- keyboard up under the finger, and lifting it typed whatever key was there.
    if self._kb_defer then self._kb_pending = true else self:showTextKeyboard() end
    -- Place the caret at the tapped point BEFORE the one scroll-into-view pass, so
    -- opening a box never pans (the tap is above the keyboard by construction) and
    -- there is no visible jump. We do not save/restore pan_y: leaving the scroll
    -- where the caret needs it means closing the keyboard never snaps back either.
    if hit_pos then
        local r = self:textBoxScreenRect()
        local lay = self:editTextLayout()
        self.text_cur = Text.hit(self.editing_text, lay, hit_pos.x - r.x, hit_pos.y - r.y,
            self:textCtx(self.editing_text, self.view.zoom))
    end
    self:ensureCaretVisible()           -- only pans if the caret is actually hidden
    self:renderView()
    self:refresh(self, "full")
end

-- Leave edit mode, baking the box in (commit) or dropping the edit (cancel).
function InkAwayView:finishTextEdit(commit)
    if not self.editing_text then return end
    self._kb_pending = nil
    self:hideClipBubble()
    if commit == nil then commit = true end
    local op = self.editing_text
    local committed_op   -- the op that ended up on the ops list (for undo history)
    if self.editing_is_new then
        if commit and not Text.isEmpty(op) then
            self.canvas:pushHistory()
            self.canvas.ops[#self.canvas.ops + 1] = op
            committed_op = op
        end
    else
        local orig = self._text_orig
        orig.hidden = nil
        if commit then
            if Text.isEmpty(op) then
                self.canvas:pushHistory()
                table.remove(self.canvas.ops, self.editing_idx)   -- emptied: delete it
            else
                op.hidden = nil   -- make sure the committed box is drawn
                self.canvas:pushHistory()
                self.canvas.ops[self.editing_idx] = op
                committed_op = op
            end
        end
    end
    -- Keep this box's word-level history alive so a later Undo peels it back a
    -- word at a time (see undo()), rather than deleting the whole block at once.
    if committed_op and self._text_undo and #self._text_undo > 0 then
        self._text_hist[committed_op] = { undo = self._text_undo, redo = self._text_redo or {} }
    end
    self._peel_op = nil
    self.editing_text, self._text_orig = nil, nil
    self.editing_idx, self.editing_is_new = nil, nil
    self.text_cur, self.text_sel = nil, nil
    self._text_pending_style = nil
    self._lay_cache = nil
    self:closeSheet("_text_fmt")
    self.dirty = true
    self:hideTextKeyboard()
    -- While typing, the page may have been scrolled past its normal end so the line
    -- stayed above the keyboard (see ensureCaretVisible). The keyboard is gone now,
    -- so bring the view back inside the page, as a pan would; otherwise the page's
    -- edge and the empty space beyond it stay on screen.
    InkGeom.clampPan(self.view)
    self:composeCanvas()
    self:renderView()
    self:refresh("all", "full")
end

-- ---- per-box undo / redo -------------------------------------------------
-- A text-local history so Undo/Redo work inside the box without recomposing the
-- whole page per keystroke. Snapshots coalesce: a run of typed letters is one
-- word, a run of deletions is one step, and each format change is its own step.
-- `kind` groups consecutive same-kind edits; a boundary (space/newline, a cursor
-- move, or a different kind) starts a new undo step.
function InkAwayView:pushTextHistory()
    if not self.editing_text then return end
    self._text_undo = self._text_undo or {}
    self._text_undo[#self._text_undo + 1] = {
        paras = Notebook.deepcopy(self.editing_text.paras),
        cur = { p = self.text_cur.p, o = self.text_cur.o },
    }
    if #self._text_undo > 80 then table.remove(self._text_undo, 1) end
    self._text_redo = {}
end

-- Call before a mutating edit. Pushes a snapshot only when a new undo step
-- should begin, so typing a word is a single step.
function InkAwayView:textMark(kind)
    if self._text_coalesce ~= kind then self:pushTextHistory() end
    self._text_coalesce = kind
end

function InkAwayView:textBreakCoalesce() self._text_coalesce = nil end

function InkAwayView:textRestore(stack, other)
    if not (self.editing_text and stack and #stack > 0) then return end
    other[#other + 1] = {
        paras = Notebook.deepcopy(self.editing_text.paras),
        cur = { p = self.text_cur.p, o = self.text_cur.o },
    }
    local snap = table.remove(stack)
    self.editing_text.paras = snap.paras
    local np = #self.editing_text.paras
    local cp = math.max(1, math.min(np, snap.cur.p))
    self.text_cur = { p = cp, o = math.min(snap.cur.o, Text.paraLen(self.editing_text.paras[cp])) }
    self.text_sel = nil
    self._text_coalesce = nil
    self:invalidateLayout()
    self:ensureCaretVisible()
    self:refreshTextBox("ui")
end

function InkAwayView:textUndo() self:textRestore(self._text_undo, self._text_redo) end
function InkAwayView:textRedo() self:textRestore(self._text_redo, self._text_undo) end

-- ---- text mutation (driven by the keyboard) ------------------------------
function InkAwayView:textDeleteSelIfAny()
    if self.text_sel and not Text.selEmpty(self.text_sel) then
        self.text_cur = Text.deleteRange(self.editing_text, self.text_sel)
        self.text_sel = nil
        return true
    end
    self.text_sel = nil
    return false
end

function InkAwayView:textAddChars(s)
    if not self.editing_text then return end
    -- a space / newline closes the current word so the next one is its own step
    self:textMark("type")
    if s == " " or s == "\n" then self._text_coalesce = nil end
    self:textDeleteSelIfAny()
    local style = self._text_pending_style or nil
    self.text_cur = Text.insert(self.editing_text, self.text_cur, s, style)
    self._text_pending_style = nil
    self:afterTextEdit()
end

function InkAwayView:textDelChar()
    if not self.editing_text then return end
    self:textMark("delete")
    if not self:textDeleteSelIfAny() then
        self.text_cur = Text.deleteBack(self.editing_text, self.text_cur)
    end
    self:afterTextEdit()
end

function InkAwayView:textDelToBOL()
    if not self.editing_text then return end
    self:textMark("delete")
    self.text_cur = Text.deleteRange(self.editing_text,
        { a = { p = self.text_cur.p, o = 0 }, b = self.text_cur })
    self.text_sel = nil
    self:afterTextEdit()
end

-- Move the caret. dx: -1/+1 by char; dy: -1/+1 by line.
function InkAwayView:textMove(dx, dy)
    if not self.editing_text then return end
    local op, cur = self.editing_text, self.text_cur
    self.text_sel = nil
    if dx ~= 0 then
        local o = cur.o + dx
        if o < 0 then
            if cur.p > 1 then cur = { p = cur.p - 1, o = Text.paraLen(op.paras[cur.p - 1]) } end
        elseif o > Text.paraLen(op.paras[cur.p]) then
            if cur.p < #op.paras then cur = { p = cur.p + 1, o = 0 } end
        else
            cur = { p = cur.p, o = o }
        end
    end
    if dy ~= 0 then
        local lay = self:editTextLayout()
        local c = Text.caret(op, lay, cur, self:textCtx(op, self.view.zoom))
        local ny = c.y + (dy > 0 and c.h * 1.5 or -c.h * 0.5)
        cur = Text.hit(op, lay, c.x, ny, self:textCtx(op, self.view.zoom))
    end
    self.text_cur = cur
    self:textBreakCoalesce()
    self:ensureCaretVisible()
    self:refreshTextBox("ui")
end

function InkAwayView:textHome()
    if not self.editing_text then return end
    self.text_cur = { p = self.text_cur.p, o = 0 }
    self.text_sel = nil
    self:refreshTextBox("ui")
end

function InkAwayView:textEnd()
    if not self.editing_text then return end
    self.text_cur = { p = self.text_cur.p, o = Text.paraLen(self.editing_text.paras[self.text_cur.p]) }
    self.text_sel = nil
    self:refreshTextBox("ui")
end

-- ---- touch handling for the text tool ------------------------------------
-- Find a committed text op under a canvas point (topmost first).
function InkAwayView:textOpAt(cx, cy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "text" and cx >= op.x and cx <= op.x + op.w
           and cy >= op.y and cy <= op.y + (op.h or 0) then
            return op, i
        end
    end
end

-- A gesture that lands on the on-screen keyboard must never reach the canvas.
-- The view is is_always_active while editing (so the toolbar keeps working), so
-- key taps the keyboard doesn't fully swallow would otherwise fall through here
-- and be treated as taps that create / commit boxes.
function InkAwayView:inKeyboard(pos)
    return self._text_kb ~= nil and pos ~= nil and pos.y >= self:keyboardTop()
end

function InkAwayView:textToolTouch(pos)
    if self:inKeyboard(pos) then return true end
    if self.editing_text then
        local function inRect(rr) return pos.x >= rr.x and pos.x <= rr.x + rr.w
            and pos.y >= rr.y and pos.y <= rr.y + rr.h end
        local btns = self:textEditButtons()
        if inRect(btns.done) then self:finishTextEdit(true); return true end
        if inRect(btns.format) then
            -- defer to release: opening on the final tap event (as the drag-select
            -- path already does) stops the same tap from immediately closing the
            -- menu as an outside-tap, which made the button flaky
            self._text_drag = { kind = "format" }
            return true
        end
        local zone = self:textZone(pos.x, pos.y)
        if zone == "resize" then
            self._text_drag = { kind = "resize", sx = pos.x, sy = pos.y,
                w0 = self.editing_text.w, h0 = self.editing_text.h }
            return true
        elseif zone == "move" then
            self._text_drag = { kind = "move", sx = pos.x, sy = pos.y,
                x0 = self.editing_text.x, y0 = self.editing_text.y }
            return true
        elseif zone == "inside" then
            -- place the caret; a following pan turns it into a selection
            local r = self:textBoxScreenRect()
            local lay = self:editTextLayout()
            local cur = Text.hit(self.editing_text, lay, pos.x - r.x, pos.y - r.y,
                self:textCtx(self.editing_text, self.view.zoom))
            self.text_cur = cur
            self.text_sel = nil
            self._text_drag = { kind = "select", anchor = cur }
            self:textBreakCoalesce()   -- typing at a new spot is a new undo step
            self:refreshTextBox("ui")
            return true
        else
            self:finishTextEdit(true)   -- tapped away: commit and leave
            -- fall through to maybe start a new box at this point
        end
    end
    -- not editing (or just finished): edit an existing box, or start a new one
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    local op, idx = self:textOpAt(cx, cy)
    self._kb_defer = true   -- the keyboard appears when this finger lifts
    if op then
        -- pass the tap so the caret lands there before the first scroll pass
        self:startTextEdit(op, { p = 1, o = 0 }, false, idx, pos)
    else
        self:newTextAt(pos)
    end
    self._kb_defer = nil
    return true
end

-- Show the keyboard a box was opened with, now that the opening finger has lifted,
-- and scroll the caret clear of it.
function InkAwayView:showPendingKeyboard()
    if not self._kb_pending then return end
    self._kb_pending = nil
    if self.editing_text then
        self:showTextKeyboard()
        self:ensureCaretVisible()
    end
end

function InkAwayView:textToolPan(pos)
    if self:inKeyboard(pos) and not self._text_drag then return true end
    local d = self._text_drag
    if not d then return true end
    if d.kind == "move" then
        local dx = (pos.x - d.sx) / self.view.zoom
        local dy = (pos.y - d.sy) / self.view.zoom
        local old = self:textBoxScreenRect()
        self.editing_text.x = d.x0 + dx
        self.editing_text.y = d.y0 + dy
        -- refresh the union of the old and new positions so no ghost is left
        local new = self:textBoxScreenRect()
        local v = self.view
        local pad = TEXT_HANDLE + 4
        local x0 = math.max(v.area_x, math.min(old.x, new.x) - pad)
        local y0 = math.max(v.area_y, math.min(old.y, new.y) - pad)
        local x1 = math.min(v.area_x + v.area_w, math.max(old.x + old.w, new.x + new.w) + pad)
        local y1 = math.min(v.area_y + v.area_h, math.max(old.y + old.h, new.y + new.h) + pad)
        if x1 > x0 and y1 > y0 then
            UIManager:setDirty(self, "fast", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
        end
    elseif d.kind == "resize" then
        local dw = (pos.x - d.sx) / self.view.zoom
        local old = self:textBoxScreenRect()
        -- only the width is dragged; height stays automatic so the box always
        -- grows to fit its (re-wrapped) text and the text can never overflow it
        self.editing_text.w = math.max(40, d.w0 + dw)
        self:invalidateLayout()   -- width changed -> re-wrap (and auto-grow height)
        self:editTextLayout()     -- recompute now so op.h reflects the new wrap
        -- refresh the union of the old and new box (shrinking would otherwise
        -- leave the old, larger outline and text behind as ghost pixels)
        local new = self:textBoxScreenRect()
        local v = self.view
        local pad = TEXT_HANDLE + 4
        local x0 = math.max(v.area_x, math.min(old.x, new.x) - pad)
        local y0 = math.max(v.area_y, math.min(old.y, new.y) - pad)
        local x1 = math.min(v.area_x + v.area_w, math.max(old.x + old.w, new.x + new.w) + pad)
        local y1 = math.min(v.area_y + v.area_h, math.max(old.y + old.h, new.y + new.h) + pad)
        if x1 > x0 and y1 > y0 then
            UIManager:setDirty(self, "fast", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
        end
    elseif d.kind == "select" then
        local r = self:textBoxScreenRect()
        local lay = self:editTextLayout()
        local cur = Text.hit(self.editing_text, lay, pos.x - r.x, pos.y - r.y,
            self:textCtx(self.editing_text, self.view.zoom))
        -- Only act when the caret actually lands somewhere new. A pen held on the
        -- glass sends a frame every few ms with a pixel of jitter; refreshing the
        -- box for each one was wasted e-ink work, and it dismissed the paste bubble
        -- the moment it appeared.
        local last = d.last or d.anchor
        if cur.p == last.p and cur.o == last.o then return true end
        d.last = cur
        self.text_cur = cur
        self.text_sel = { a = d.anchor, b = cur }
        self:refreshTextBox("ui")
    end
    return true
end

function InkAwayView:textToolRelease(pos)
    self:showPendingKeyboard()   -- the finger that opened the box has lifted
    if self:inKeyboard(pos) and not self._text_drag then return true end
    local d = self._text_drag
    self._text_drag = nil
    if not d then return true end
    if d.kind == "format" then
        -- open the format menu on release (not on touch) so the same tap can't be
        -- seen as an outside-tap on the just-shown menu, which would close it again
        self:openTextFormatMenu()
    elseif d.kind == "move" or d.kind == "resize" then
        -- re-align to the ruling once the drag ends (grid-snap boxes only); the
        -- small settle can leave A2 residue, so clear it with a flashing refresh
        if d.kind == "move" and self.editing_text and self.editing_text.grid_snap then
            self:snapTextBoxToGrid(self.editing_text)
            self:invalidateLayout()
            self:refreshTextBox("flashui")
        else
            self:refreshTextBox("ui")
        end
    elseif d.kind == "select" then
        if self.text_sel and Text.selEmpty(self.text_sel) then
            self.text_sel = nil
        elseif self:textHasSel() then
            self:openTextFormatMenu()   -- a real selection: offer the format menu
        end
    end
    return true
end

-- ---- overlay painting ----------------------------------------------------
function InkAwayView:paintTextOverlay(bb, x, y)
    local op = self.editing_text
    local lay, ctx = self:editTextLayout()
    local r = self:textBoxScreenRect()   -- area-relative screen rect
    local ox, oy = r.x + x, r.y + y      -- add the widget's paint origin
    local BLACKC = Blitbuffer.COLOR_BLACK
    -- selection highlight (behind the glyphs)
    if self.text_sel and not Text.selEmpty(self.text_sel) then
        local a, b = Text.orderSel(self.text_sel)
        for _, ln in ipairs(lay.lines) do
            local lo = (ln.para > a.p or (ln.para == a.p and ln.o_end >= a.o)) and true or false
            local hi = (ln.para < b.p or (ln.para == b.p and ln.o_start <= b.o)) and true or false
            if lo and hi and ln.para >= a.p and ln.para <= b.p then
                local xa = (ln.para == a.p) and math.max(ln.text_x, self:caretXHelper(ctx, ln, a)) or ln.text_x
                local xb = (ln.para == b.p) and self:caretXHelper(ctx, ln, b) or (ln.text_x + self:lineContentW(ln))
                if xb > xa then
                    bb:paintRect(math.floor(ox + xa), math.floor(oy + ln.top),
                        math.ceil(xb - xa), math.ceil(ln.height), Blitbuffer.COLOR_LIGHT_GRAY)
                end
            end
        end
    end
    -- the glyphs
    Text.render(op, lay, bb, ox, oy, ctx, { color = BLACKC })
    -- the frame
    local fx, fy, fw, fh = math.floor(ox), math.floor(oy), math.ceil(r.w), math.ceil(r.h)
    bb:paintRect(fx, fy, fw, 1, BLACKC); bb:paintRect(fx, fy + fh - 1, fw, 1, BLACKC)
    bb:paintRect(fx, fy, 1, fh, BLACKC); bb:paintRect(fx + fw - 1, fy, 1, fh, BLACKC)
    -- handles: move (top-left), resize (bottom-right)
    bb:paintRect(fx - 6, fy - 6, 12, 12, BLACKC)
    bb:paintRect(fx + fw - 6, fy + fh - 6, 12, 12, BLACKC)
    -- caret
    if not (self.text_sel and not Text.selEmpty(self.text_sel)) then
        local c = Text.caret(op, lay, self.text_cur, ctx)
        bb:paintRect(math.floor(ox + c.x), math.floor(oy + c.y), 2, math.ceil(c.h), BLACKC)
    end
    -- the always-visible Format and Done buttons (above the keyboard): rounded,
    -- Color8 fills so the corners are drawn in C, and labels cached in the metrics
    local btns = self:textEditButtons()
    local m = self._text_btn_metrics
    local function drawBtn(rr, label)
        local bx, by = rr.x + x, rr.y + y
        bb:paintRoundedRect(bx, by, rr.w, rr.h, rr.dark and BLACKC or TILE_BG, m.radius)
        local sz = label:getSize()
        label:paintTo(bb, math.floor(bx + (rr.w - sz.w) / 2), math.floor(by + (rr.h - sz.h) / 2))
    end
    drawBtn(btns.format, m.fw)
    drawBtn(btns.done, m.dw)
end

-- helpers used by the selection highlight above (ctx passed in to avoid
-- rebuilding the measuring context once per selected line)
function InkAwayView:caretXHelper(ctx, ln, cur)
    local x = ln.text_x
    for _, sg in ipairs(ln.segs) do
        local segEnd = sg.o0 + Text.ulen(sg.t)
        if cur.o >= segEnd then x = sg.x + sg.w
        elseif cur.o <= sg.o0 then return x
        else return sg.x + ctx.measure(Text.usub(sg.t, 0, cur.o - sg.o0), sg.style) end
    end
    return x
end

function InkAwayView:lineContentW(ln)
    local w = 0
    for _, sg in ipairs(ln.segs) do w = w + sg.w end
    return w
end

return InkAwayView
