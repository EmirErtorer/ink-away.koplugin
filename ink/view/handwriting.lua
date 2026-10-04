--[[
Handwriting to text: lasso some printed writing, then "Convert to text" in the
selection's menu. The strokes are split into lines, words and characters
(ink/hwr.lua), each character read by the small network in ink/hwrnet.lua,
each word checked against the English word list (ink/hwrwords.lua), and the
writing replaced by one text box in the current text style, in one undo step.
Everything runs on the reader; nothing is sent anywhere.
Part of InkAwayView (see ink/view.lua).
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Hwr = require("ink/hwr")
local Text = require("ink/text")

local InkAwayView = {}

-- The model and the word list, loaded on first use and kept until Ink Away
-- closes (see freeHandwriting). Returns net, words, or nil and a message.
function InkAwayView:hwrModels()
    if self._hwr_net and self._hwr_words then return self._hwr_net, self._hwr_words end
    local dir = self:pluginDir() .. "ink/data/"
    local HwrNet = require("ink/hwrnet")
    local net, err = HwrNet.load(dir .. "hwr_en.bin")
    if not net then
        logger.warn("InkAway: handwriting model:", err)
        return nil, _("The handwriting model could not be loaded.")
    end
    local Words = require("ink/hwrwords")
    local words, werr = Words.load(dir .. "hwr_words_en.txt", net.classes)
    if not words then
        logger.warn("InkAway: word list:", werr)
        return nil, _("The word list could not be loaded.")
    end
    self._hwr_net, self._hwr_words = net, words
    return net, words
end

function InkAwayView:freeHandwriting()
    self._hwr_net, self._hwr_words = nil, nil
end

-- The strokes of the ops at `idxs` that can be read as writing: pen ink, and the
-- lines shape assist may have made of single strokes. Returns the strokes (flat
-- point lists, in writing order) and their ops.
function InkAwayView:writingOf(idxs)
    local sorted = {}
    for i, idx in ipairs(idxs) do sorted[i] = idx end
    table.sort(sorted)
    local strokes, ops = {}, {}
    for _, idx in ipairs(sorted) do
        local op = self.canvas.ops[idx]
        if op and op.pts and #op.pts >= 2
                and (op.kind == "ink" or (op.kind == "shape" and op.shape == "line")) then
            strokes[#strokes + 1] = op.pts
            ops[#ops + 1] = op
        end
    end
    return strokes, ops
end

-- Does the selection hold anything that could be writing?
function InkAwayView:selectionHasWriting()
    if not self.selection then return false end
    local strokes = self:writingOf(self.selection.idxs)
    return #strokes > 0
end

-- Read `strokes` (flat point lists in writing order). Returns the text: words
-- joined by spaces, lines by new lines.
function InkAwayView:readWriting(strokes, net, words)
    local out_lines = {}
    for _, line in ipairs(Hwr.segment(strokes)) do
        -- read every character first: the line's x-height comes from them
        local all_chars, all_best, per_word = {}, {}, {}
        for wi, word in ipairs(line.words) do
            local lps = {}
            for ci, c in ipairs(word.chars) do lps[ci] = net:classify(c.strokes) end
            local text, _, best = words:decode(lps)
            per_word[wi] = { text = text, lps = lps }
            for ci, c in ipairs(word.chars) do
                all_chars[#all_chars + 1] = c
                all_best[#all_best + 1] = best[ci]
            end
        end
        local xh, base = Hwr.lineMetrics(all_chars, net.classes, all_best)
        local out = {}
        for wi, word in ipairs(line.words) do
            local r = per_word[wi]
            out[wi] = Hwr.cased(r.text, word.chars, r.lps, net.classes, xh, base)
        end
        out_lines[#out_lines + 1] = table.concat(out, " ")
    end
    return table.concat(out_lines, "\n")
end

-- Convert the selected writing to text. Shows a message when there is none, or
-- when something fails, rather than letting an error reach KOReader.
function InkAwayView:convertSelectionToText()
    local ok, err = xpcall(function() self:convertSelectionToTextNow() end, debug.traceback)
    if not ok then
        logger.warn("InkAway: converting handwriting failed:", err)
        UIManager:show(InfoMessage:new{ text = _("Something went wrong reading the writing.") })
    end
end

function InkAwayView:convertSelectionToTextNow()
    if not self.selection then return end
    local strokes, ops = self:writingOf(self.selection.idxs)
    if #strokes == 0 then
        UIManager:show(InfoMessage:new{ text = _("There is no handwriting in the selection."), timeout = 2 })
        return
    end
    local net, words = self:hwrModels()
    if not net then
        UIManager:show(InfoMessage:new{ text = words })
        return
    end
    -- a few lines take a second or two on a reader: say so first
    local note
    if #strokes > 12 then
        note = InfoMessage:new{ text = _("Reading the writing\u{2026}") }
        UIManager:show(note)
        if UIManager.forceRePaint then UIManager:forceRePaint() end
    end
    local ok, text = pcall(self.readWriting, self, strokes, net, words)
    if note then UIManager:close(note) end
    if not ok then
        logger.warn("InkAway: reading handwriting failed:", text)
        UIManager:show(InfoMessage:new{ text = _("Something went wrong reading the writing.") })
        return
    end
    if text:gsub("%s", "") == "" then
        UIManager:show(InfoMessage:new{ text = _("No writing could be read there."), timeout = 2 })
        return
    end
    local x0, y0 = math.huge, math.huge
    for _, pts in ipairs(strokes) do
        for i = 1, #pts - 1, 2 do
            if pts[i] < x0 then x0 = pts[i] end
            if pts[i + 1] < y0 then y0 = pts[i + 1] end
        end
    end
    self:resetLasso()
    self:replaceWithText(text, ops, x0, y0)
end

-- Replace the ops `ink_ops` with one text box holding `text`, its top left at
-- canvas (x, y), in the current text style. One undo step.
function InkAwayView:replaceWithText(text, ink_ops, x, y)
    self.canvas:pushHistory()
    local gone = {}
    for _, op in ipairs(ink_ops) do gone[op] = true end
    for i = #self.canvas.ops, 1, -1 do
        if gone[self.canvas.ops[i]] then table.remove(self.canvas.ops, i) end
    end
    local v = self.view
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    local margin = math.max(6, math.floor(v.canvas_w * 0.02))
    x = math.max(margin, math.min(math.floor(x), v.canvas_w - margin - 10))
    local op = Text.new{ x = x, y = math.floor(y), w = v.canvas_w - x - margin,
        size = size, font = self.text_font, align = "left", grid_snap = self.text_grid_snap }
    if self.text_grid_snap then self:snapTextBoxToGrid(op) end
    Text.insert(op, { p = 1, o = 0 }, text, nil)
    self.canvas.ops[#self.canvas.ops + 1] = op
    self:markDirty()
    self:composeCanvas(); self:renderView()
    self:refresh(self, "ui", self:areaScreenRect())
end

return InkAwayView
