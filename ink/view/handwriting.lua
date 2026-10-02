--[[
Handwriting to text (unfinished, hidden unless show_handwriting is set): printed
pen strokes are recognised after a pause and replaced by a text box. The matcher
is ink/hwr.lua; its templates come from the font's own glyphs.
Part of InkAwayView (see ink/view.lua).
]]

local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local Notebook = require("ink/notebook")
local Text = require("ink/text")

local HWR_PAUSE = 1.1   -- idle seconds after the last pen stroke before recognising

local InkAwayView = {}

------------------------------------------------------------------------------
-- Handwriting recognition (offline). Templates are built once from the bundled
-- font's glyphs, so coverage follows the font (not just Latin); the pure matcher
-- lives in ink/hwr.lua.
------------------------------------------------------------------------------

-- Sample the OUTLINE of a rendered glyph into a point cloud. The outline (inked
-- pixels bordering blank ones) is a thin curve, so it lies in the same shape space
-- as a thin handwritten stroke -- which discriminates far better than the glyph's
-- solid fill (whose clouds all look alike to the matcher).
function InkAwayView:hwrGlyphCloud(face, charcode)
    local RenderText = require("ui/rendertext")
    local ok, glyph = pcall(function() return RenderText:getGlyph(face, charcode) end)
    if not ok or not glyph or not glyph.bb then return nil end
    local bb = glyph.bb
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 3 or h < 3 then return nil end
    -- scan the glyph into a boolean ink map once
    local map = {}
    for y = 0, h - 1 do
        local row = {}
        for x = 0, w - 1 do
            local okp, v = pcall(function()
                local c = bb:getPixel(x, y)
                if c and c.getColor8 then return c:getColor8().a end
                return 0
            end)
            row[x] = (okp and v and v > 128) and true or false
        end
        map[y] = row
    end
    -- keep inked pixels that touch a blank pixel (or the bitmap edge): the outline
    local pts = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if map[y][x] then
                local edge = x == 0 or x == w - 1 or y == 0 or y == h - 1
                    or not map[y][x - 1] or not map[y][x + 1]
                    or not map[y - 1][x] or not map[y + 1][x]
                if edge then pts[#pts + 1] = { x = x, y = y } end
            end
        end
    end
    return pts
end

-- Build the recogniser from font glyphs for the given character list. Cached.
function InkAwayView:hwrRecognizer(chars)
    if self._hwr_rec then return self._hwr_rec end
    local Hwr = require("ink/hwr")
    local rec = Hwr.Recognizer.new()
    local ok = pcall(function()
        local face = Font:getFace("cfont", 48)
        chars = chars or "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        for ch in chars:gmatch(".") do
            local pts = self:hwrGlyphCloud(face, string.byte(ch))
            if pts and #pts >= 8 then rec:add(ch, Hwr.normalizeCloud(pts), true) end
        end
    end)
    if ok and rec:count() > 0 then self._hwr_rec = rec end
    return self._hwr_rec
end

-- Buffer a just-committed pen stroke and (re)start the pause timer. When the pen
-- rests for HWR_PAUSE, hwrRecognizePending fires.
function InkAwayView:hwrCapture(op)
    self._hwr_ops = self._hwr_ops or {}
    self._hwr_ops[#self._hwr_ops + 1] = op
    if not self._hwr_cb then self._hwr_cb = function() self:hwrRecognizePending() end end
    UIManager:unschedule(self._hwr_cb)
    UIManager:scheduleIn(HWR_PAUSE, self._hwr_cb)
end

-- Drop any pending handwriting (timer + buffer). Called when the feature is turned
-- off, the tool changes, or the widget closes.
function InkAwayView:hwrCancel()
    if self._hwr_cb then UIManager:unschedule(self._hwr_cb) end
    self._hwr_ops = nil
end

-- The pause fired: recognise the buffered pen strokes and turn them into text.
function InkAwayView:hwrRecognizePending()
    local buf = self._hwr_ops
    self._hwr_ops = nil
    if not buf or #buf == 0 then return end
    if self.editing_text or self.capturing then return end   -- don't fight an open box / live stroke
    local Hwr = require("ink/hwr")
    local rec = self:hwrRecognizer()
    if not rec then return end
    -- keep only buffered ops that are still on the canvas (not undone / page-changed)
    local present = {}
    for i = 1, #self.canvas.ops do present[self.canvas.ops[i]] = true end
    local strokes, live_ops = {}, {}
    for _, op in ipairs(buf) do
        if present[op] and op.kind == "ink" and op.pts and #op.pts >= 2 then
            local s = {}
            for i = 1, #op.pts, 2 do s[#s + 1] = { x = op.pts[i], y = op.pts[i + 1] } end
            strokes[#strokes + 1] = s
            live_ops[#live_ops + 1] = op
        end
    end
    if #strokes == 0 then return end
    local out = {}
    for _, tk in ipairs(Hwr.segment(strokes)) do
        if tk.kind == "space" then out[#out + 1] = " "
        elseif tk.kind == "newline" then out[#out + 1] = "\n"
        elseif tk.kind == "char" then out[#out + 1] = rec:recognize(tk.strokes) or "" end
    end
    local text = table.concat(out)
    if text:gsub("%s", "") == "" then return end   -- nothing recognised; leave the ink alone
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, s in ipairs(strokes) do
        for _, p in ipairs(s) do
            if p.x < minx then minx = p.x end
            if p.x > maxx then maxx = p.x end
            if p.y < miny then miny = p.y end
            if p.y > maxy then maxy = p.y end
        end
    end
    self:hwrInsertText(text, live_ops, minx, miny, maxx, maxy)
end

-- Replace the recognised ink with a text box, in one undoable step. Appends to the
-- box the last recognition made when the new writing sits just below/beside it (so
-- writing line after line stays in one box); otherwise starts a fresh box. Uses
-- the current text font/size/grid-snap.
function InkAwayView:hwrInsertText(text, ink_ops, minx, miny, maxx, maxy)
    self.canvas:pushHistory()
    -- remove the recognised ink ops (highest index first)
    local idxs = {}
    for _, op in ipairs(ink_ops) do
        for i = #self.canvas.ops, 1, -1 do
            if self.canvas.ops[i] == op then idxs[#idxs + 1] = i; break end
        end
    end
    table.sort(idxs, function(a, b) return a > b end)
    for _, i in ipairs(idxs) do table.remove(self.canvas.ops, i) end

    local v = self.view
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    -- reuse the previous handwriting box if it is still around and the new writing
    -- sits within about a line of it (clone it so the history snapshot is untouched)
    local last = self._hwr_last
    local reuse_idx
    if last and last.op and miny >= last.top - size and miny <= last.bottom + 1.6 * size then
        for i = 1, #self.canvas.ops do if self.canvas.ops[i] == last.op then reuse_idx = i; break end end
    end
    if reuse_idx then
        local op = self.canvas.ops[reuse_idx]
        local nop = self.canvas:cloneOp(op)
        nop.paras = Notebook.deepcopy(op.paras)
        local cp = #nop.paras
        local join = (miny > last.bottom + 0.4 * size) and "\n" or " "
        Text.insert(nop, { p = cp, o = Text.paraLen(nop.paras[cp]) }, join .. text, nil)
        self.canvas.ops[reuse_idx] = nop
        self._hwr_last = { op = nop, top = last.top, bottom = math.max(last.bottom, maxy) }
    else
        local margin = math.max(6, math.floor(v.canvas_w * 0.02))
        local x = math.max(margin, math.min(math.floor(minx), v.canvas_w - margin - 10))
        local op = Text.new{ x = x, y = math.floor(miny), w = v.canvas_w - x - margin,
            size = size, font = self.text_font, align = "left", grid_snap = self.text_grid_snap }
        if self.text_grid_snap then self:snapTextBoxToGrid(op) end
        Text.insert(op, { p = 1, o = 0 }, text, nil)
        self.canvas.ops[#self.canvas.ops + 1] = op
        self._hwr_last = { op = op, top = miny, bottom = maxy }
    end
    self.dirty = true
    self:composeCanvas(); self:renderView()
    self:refresh(self, "ui", self:areaScreenRect())
end

return InkAwayView
