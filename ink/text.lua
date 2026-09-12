--[[
Rich text model, layout and rendering for the note text box.

A text op is one entry in a page's ops list, so it saves, undoes and exports
through the same engine as everything else:

    { kind = "text",
      x, y, w, h,          -- box rect in canvas pixels (h auto-grows unless set)
      auto_h = true,       -- height follows the content until the user resizes
      font = <name|nil>,   -- nil uses the default font
      size = <px>,         -- base glyph size
      align = "left"|"center"|"right",
      grid_snap = false,   -- snap each line to the ruling
      paras = {            -- paragraphs (a newline starts a new paragraph)
        { bullet = nil|"disc"|"number",
          spans = { { t = "text", b=, i=, u=, s=, hl=, sz= }, ... } },
        ...
      } }

A span is a maximal run of one style. Style flags: b bold, i italic, u
underline, s strikethrough, hl highlight; sz is a size multiplier (nil = 1).

Layout and the edit operations are pure Lua and take an injected `ctx` for any
measuring, so they run under the headless tests. Only render() touches KOReader
(RenderText), and it is loaded lazily.
]]

local Text = {}

-- ---------------------------------------------------------------------------
-- UTF-8 helpers (LuaJIT has no utf8 library). One pattern matches one glyph's
-- bytes: an ASCII/lead byte followed by any continuation bytes.
-- ---------------------------------------------------------------------------
local UTF8 = "[%z\1-\127\194-\253][\128-\191]*"

local function chars(s)
    local t = {}
    for c in s:gmatch(UTF8) do t[#t + 1] = c end
    return t
end

local function ulen(s)
    local n = 0
    for _ in s:gmatch(UTF8) do n = n + 1 end
    return n
end

-- substring by character offsets [i, j) (0-based, j exclusive)
local function usub(s, i, j)
    local out, k = {}, 0
    for c in s:gmatch(UTF8) do
        if k >= i and (not j or k < j) then out[#out + 1] = c end
        k = k + 1
        if j and k >= j then break end
    end
    return table.concat(out)
end

Text.chars, Text.ulen, Text.usub = chars, ulen, usub

-- ---------------------------------------------------------------------------
-- Style helpers
-- ---------------------------------------------------------------------------
local STYLE_KEYS = { "b", "i", "u", "s", "hl", "sz" }

local function copyStyle(st)
    local o = {}
    if st then for _, k in ipairs(STYLE_KEYS) do o[k] = st[k] end end
    return o
end
Text.copyStyle = copyStyle

local function sameStyle(a, b)
    for _, k in ipairs(STYLE_KEYS) do
        if (a[k] or false) ~= (b[k] or false) then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Construction and normalisation
-- ---------------------------------------------------------------------------
local function emptyPara(bullet)
    return { bullet = bullet, spans = { { t = "" } } }
end

-- Build a fresh text op. opts: x, y, w, size, font, align, grid_snap.
function Text.new(opts)
    opts = opts or {}
    return {
        kind = "text",
        x = opts.x or 0, y = opts.y or 0,
        w = opts.w or 100, h = opts.h,
        auto_h = opts.h == nil,
        font = opts.font, size = opts.size or 32,
        align = opts.align or "left",
        grid_snap = opts.grid_snap or false,
        paras = { emptyPara() },
    }
end

-- Concatenated text of one paragraph.
local function paraText(p)
    local t = {}
    for _, sp in ipairs(p.spans) do t[#t + 1] = sp.t end
    return table.concat(t)
end
Text.paraText = paraText

function Text.paraLen(p) return ulen(paraText(p)) end

-- Merge neighbouring same-style spans and drop empties; keep one empty span so a
-- paragraph is never span-less.
local function normalizePara(p)
    local out = {}
    for _, sp in ipairs(p.spans) do
        if sp.t ~= "" then
            local last = out[#out]
            if last and sameStyle(last, sp) then
                last.t = last.t .. sp.t
            else
                out[#out + 1] = sp
            end
        end
    end
    if #out == 0 then out[1] = { t = "" } end
    p.spans = out
end
Text.normalizePara = normalizePara

-- The plain text of the whole op (for search / measuring emptiness).
function Text.plain(op)
    local t = {}
    for _, p in ipairs(op.paras) do t[#t + 1] = paraText(p) end
    return table.concat(t, "\n")
end

function Text.isEmpty(op)
    return #op.paras == 1 and paraText(op.paras[1]) == ""
end

-- ---------------------------------------------------------------------------
-- Cursor addressing. A cursor is { p = <paragraph idx>, o = <char offset> }.
-- Selections are { a = cur, b = cur }; orderSel returns them start..end.
-- ---------------------------------------------------------------------------
local function curLE(a, b)   -- a <= b ?
    if a.p ~= b.p then return a.p < b.p end
    return a.o <= b.o
end

function Text.orderSel(sel)
    if curLE(sel.a, sel.b) then return sel.a, sel.b end
    return sel.b, sel.a
end

function Text.selEmpty(sel)
    return sel.a.p == sel.b.p and sel.a.o == sel.b.o
end

-- Split a paragraph's spans at char offset `o`, returning left and right span
-- lists (each normalised, never empty). Styles are preserved on both sides.
local function splitSpans(p, o)
    local left, right = {}, {}
    local k = 0
    for _, sp in ipairs(p.spans) do
        local n = ulen(sp.t)
        if o >= k + n then
            left[#left + 1] = sp
        elseif o <= k then
            right[#right + 1] = sp
        else
            local cut = o - k
            local a = copyStyle(sp); a.t = usub(sp.t, 0, cut)
            local b = copyStyle(sp); b.t = usub(sp.t, cut)
            left[#left + 1] = a
            right[#right + 1] = b
        end
        k = k + n
    end
    if #left == 0 then left[1] = { t = "" } end
    if #right == 0 then right[1] = { t = "" } end
    return left, right
end

-- Style that new typing at the cursor should inherit: the style of the char just
-- before the cursor, else the first span's style.
function Text.styleAt(op, cur)
    local p = op.paras[cur.p]
    if not p then return {} end
    if cur.o == 0 then return copyStyle(p.spans[1]) end
    local k = 0
    for _, sp in ipairs(p.spans) do
        local n = ulen(sp.t)
        if cur.o <= k + n then return copyStyle(sp) end
        k = k + n
    end
    return copyStyle(p.spans[#p.spans])
end

-- ---------------------------------------------------------------------------
-- Editing operations. Each mutates op.paras and returns the new cursor.
-- ---------------------------------------------------------------------------

-- Delete a (non-empty) selection; returns the collapsed cursor.
function Text.deleteRange(op, sel)
    local a, b = Text.orderSel(sel)
    if a.p == b.p then
        local p = op.paras[a.p]
        local left = splitSpans(p, a.o)
        local _, right = splitSpans(p, b.o)
        local spans = {}
        for _, sp in ipairs(left) do spans[#spans + 1] = sp end
        for _, sp in ipairs(right) do spans[#spans + 1] = sp end
        p.spans = spans
        normalizePara(p)
        return { p = a.p, o = a.o }
    end
    -- multi-paragraph: keep head of first + tail of last, drop the middle
    local first, last = op.paras[a.p], op.paras[b.p]
    local head = splitSpans(first, a.o)
    local _, tail = splitSpans(last, b.o)
    local spans = {}
    for _, sp in ipairs(head) do spans[#spans + 1] = sp end
    for _, sp in ipairs(tail) do spans[#spans + 1] = sp end
    first.spans = spans
    normalizePara(first)
    for i = b.p, a.p + 1, -1 do table.remove(op.paras, i) end
    return { p = a.p, o = a.o }
end

-- Insert plain text (may contain newlines) at the cursor, all in one style
-- (defaults to the inherited style). Returns the cursor after the insert.
function Text.insert(op, cur, str, style)
    style = style or Text.styleAt(op, cur)
    local p = op.paras[cur.p]
    local left, right = splitSpans(p, cur.o)
    local pieces = {}
    do   -- split str on "\n" (keep empty trailing pieces)
        local start = 1
        while true do
            local nl = str:find("\n", start, true)
            if not nl then pieces[#pieces + 1] = str:sub(start); break end
            pieces[#pieces + 1] = str:sub(start, nl - 1)
            start = nl + 1
        end
    end
    if #pieces == 1 then
        local spans = {}
        for _, sp in ipairs(left) do spans[#spans + 1] = sp end
        if pieces[1] ~= "" then local sp = copyStyle(style); sp.t = pieces[1]; spans[#spans + 1] = sp end
        for _, sp in ipairs(right) do spans[#spans + 1] = sp end
        p.spans = spans
        normalizePara(p)
        return { p = cur.p, o = cur.o + ulen(pieces[1]) }
    end
    -- multi-line: first piece joins the head, last piece precedes the tail,
    -- middle pieces become their own paragraphs. New paragraphs inherit the
    -- bullet of the paragraph being split.
    local firstSpans = {}
    for _, sp in ipairs(left) do firstSpans[#firstSpans + 1] = sp end
    if pieces[1] ~= "" then local sp = copyStyle(style); sp.t = pieces[1]; firstSpans[#firstSpans + 1] = sp end
    p.spans = firstSpans
    normalizePara(p)
    local insertAt = cur.p
    for i = 2, #pieces - 1 do
        insertAt = insertAt + 1
        local np = { bullet = p.bullet, spans = {} }
        if pieces[i] ~= "" then np.spans[1] = { t = pieces[i], b = style.b, i = style.i,
            u = style.u, s = style.s, hl = style.hl, sz = style.sz } else np.spans[1] = { t = "" } end
        table.insert(op.paras, insertAt, np)
    end
    insertAt = insertAt + 1
    local lastSpans = {}
    local lastPiece = pieces[#pieces]
    if lastPiece ~= "" then local sp = copyStyle(style); sp.t = lastPiece; lastSpans[#lastSpans + 1] = sp end
    for _, sp in ipairs(right) do lastSpans[#lastSpans + 1] = sp end
    local np = { bullet = p.bullet, spans = lastSpans }
    normalizePara(np)
    table.insert(op.paras, insertAt, np)
    return { p = insertAt, o = ulen(lastPiece) }
end

-- Backspace one char (or join with the previous paragraph at the start).
function Text.deleteBack(op, cur)
    if cur.o > 0 then
        return Text.deleteRange(op, { a = { p = cur.p, o = cur.o - 1 }, b = cur })
    end
    if cur.p == 1 then return cur end   -- nothing before
    local prev = op.paras[cur.p - 1]
    local prevLen = Text.paraLen(prev)
    -- merge current paragraph's spans onto the previous one
    local spans = {}
    for _, sp in ipairs(prev.spans) do spans[#spans + 1] = sp end
    for _, sp in ipairs(op.paras[cur.p].spans) do spans[#spans + 1] = sp end
    prev.spans = spans
    normalizePara(prev)
    table.remove(op.paras, cur.p)
    return { p = cur.p - 1, o = prevLen }
end

-- Forward delete (Del key): delete the char after the cursor.
function Text.deleteForward(op, cur)
    local p = op.paras[cur.p]
    local len = Text.paraLen(p)
    if cur.o < len then
        return Text.deleteRange(op, { a = cur, b = { p = cur.p, o = cur.o + 1 } })
    end
    if cur.p >= #op.paras then return cur end
    -- join the next paragraph onto this one
    local nextp = op.paras[cur.p + 1]
    local spans = {}
    for _, sp in ipairs(p.spans) do spans[#spans + 1] = sp end
    for _, sp in ipairs(nextp.spans) do spans[#spans + 1] = sp end
    p.spans = spans
    normalizePara(p)
    table.remove(op.paras, cur.p + 1)
    return cur
end

-- Apply a style change across a selection. `key` is one of the style keys;
-- `value` the value to set (for a toggle, pass the new boolean). Returns nothing;
-- op.paras is edited in place with spans split at the range boundaries.
function Text.applyStyle(op, sel, key, value)
    local a, b = Text.orderSel(sel)
    local function styleParaRange(pi, o0, o1)
        local p = op.paras[pi]
        local left = splitSpans(p, o0)
        local mid, right
        do
            local _, afterLeft = splitSpans(p, o0)
            -- re-split the right part at (o1 - o0) within its own coordinates
            local tmp = { spans = afterLeft }
            mid, right = splitSpans(tmp, o1 - o0)
        end
        for _, sp in ipairs(mid) do sp[key] = value or nil end
        local spans = {}
        for _, sp in ipairs(left) do spans[#spans + 1] = sp end
        for _, sp in ipairs(mid) do spans[#spans + 1] = sp end
        for _, sp in ipairs(right) do spans[#spans + 1] = sp end
        p.spans = spans
        normalizePara(p)
    end
    if a.p == b.p then
        styleParaRange(a.p, a.o, b.o)
    else
        styleParaRange(a.p, a.o, Text.paraLen(op.paras[a.p]))
        for pi = a.p + 1, b.p - 1 do
            styleParaRange(pi, 0, Text.paraLen(op.paras[pi]))
        end
        styleParaRange(b.p, 0, b.o)
    end
end

-- Is `key` set on every char of the selection? (used to decide toggle direction)
function Text.styleCovers(op, sel, key)
    local a, b = Text.orderSel(sel)
    if Text.selEmpty(sel) then
        return Text.styleAt(op, a)[key] and true or false
    end
    local function paraCovered(pi, o0, o1)
        if o1 <= o0 then return true end
        local p = op.paras[pi]
        local k = 0
        for _, sp in ipairs(p.spans) do
            local n = ulen(sp.t)
            local lo, hi = math.max(o0, k), math.min(o1, k + n)
            if hi > lo and not sp[key] then return false end
            k = k + n
        end
        return true
    end
    if a.p == b.p then return paraCovered(a.p, a.o, b.o) end
    if not paraCovered(a.p, a.o, Text.paraLen(op.paras[a.p])) then return false end
    for pi = a.p + 1, b.p - 1 do
        if not paraCovered(pi, 0, Text.paraLen(op.paras[pi])) then return false end
    end
    return paraCovered(b.p, 0, b.o)
end

-- Set the bullet type of every paragraph the selection touches. `kind` is nil,
-- "disc" or "number". Toggling the same kind off is the caller's job.
function Text.setBullet(op, sel, kind)
    local a, b = Text.orderSel(sel)
    for pi = a.p, b.p do op.paras[pi].bullet = kind end
end

-- ---------------------------------------------------------------------------
-- Layout. `ctx` supplies all measuring so this stays pure:
--   ctx.measure(text, style)  -> pixel width of that text in that style
--   ctx.lineHeight(style)     -> line box height in px for that style
--   ctx.ascent(style)         -> baseline offset from the line top in px
--   ctx.bulletLabel(para, n)  -> "• " / "1. " string for a bulleted paragraph
--   ctx.gridStep, ctx.gridPhase (optional) -> snap each line onto the ruling
-- Returns { lines = {...}, width = op.w, height = <total px> }. Each line:
--   { para, first, top, height, baseline, text_x, o_start, o_end,
--     bullet = { text, style, x } | nil, segs = { {t, style, x, w, o0} } }
-- ---------------------------------------------------------------------------

-- Break one paragraph's spans into tokens split on spaces and style, each
-- carrying its char offset within the paragraph.
local function tokenize(p)
    local toks, off = {}, 0
    for _, sp in ipairs(p.spans) do
        -- split sp.t into maximal space / non-space chunks, keeping utf8 chars
        local buf, buf_is_space, buf_o = {}, nil, off
        local k = off
        for _, c in ipairs(chars(sp.t)) do
            local is_sp = (c == " ")
            if buf_is_space == nil then buf_is_space = is_sp; buf_o = k end
            if is_sp ~= buf_is_space then
                toks[#toks + 1] = { t = table.concat(buf), style = sp, sp = buf_is_space, o0 = buf_o }
                buf, buf_is_space, buf_o = {}, is_sp, k
            end
            buf[#buf + 1] = c
            k = k + 1
        end
        if #buf > 0 then
            toks[#toks + 1] = { t = table.concat(buf), style = sp, sp = buf_is_space, o0 = buf_o }
        end
        off = off + ulen(sp.t)
    end
    return toks, off
end

-- Merge a run of tokens into style segments with x offsets, from a start x.
local function segmentsFromTokens(toks, i0, i1, x0, ctx)
    local segs, x = {}, x0
    for i = i0, i1 do
        local tk = toks[i]
        local last = segs[#segs]
        if last and sameStyle(last.style, tk.style) then
            last.t = last.t .. tk.t
            last.w = last.w + ctx.measure(tk.t, tk.style)
        else
            segs[#segs + 1] = { t = tk.t, style = tk.style, o0 = tk.o0,
                                w = ctx.measure(tk.t, tk.style) }
        end
    end
    for _, sg in ipairs(segs) do sg.x = x; x = x + sg.w end
    return segs
end

function Text.layout(op, ctx)
    local lines = {}
    local y = 0
    for pi, p in ipairs(op.paras) do
        local indent, bulletLabel, bulletStyle = 0, nil, nil
        if p.bullet and ctx.bulletLabel then
            bulletLabel = ctx.bulletLabel(p, pi)
            bulletStyle = p.spans[1]
            indent = ctx.measure(bulletLabel, bulletStyle)
        end
        local avail = math.max(1, op.w - indent)
        local toks = tokenize(p)

        -- greedy wrap into runs of token indices [start..last]
        local function flush(i0, i1, is_first)
            -- trim a single trailing space token from the width used for align
            local segs = segmentsFromTokens(toks, i0, i1, 0, ctx)
            local content_w = 0
            for _, sg in ipairs(segs) do content_w = content_w + sg.w end
            local line_indent = indent
            local extra = 0
            if op.align == "center" then extra = math.max(0, (avail - content_w) / 2)
            elseif op.align == "right" then extra = math.max(0, avail - content_w) end
            local text_x = line_indent + extra
            for _, sg in ipairs(segs) do sg.x = sg.x + text_x end
            -- line metrics: tallest style on the line (or the paragraph style)
            local lh, asc = ctx.lineHeight(p.spans[1]), ctx.ascent(p.spans[1])
            for _, sg in ipairs(segs) do
                lh = math.max(lh, ctx.lineHeight(sg.style))
                asc = math.max(asc, ctx.ascent(sg.style))
            end
            local o_start = (i0 <= i1) and toks[i0].o0 or (lines[#lines] and lines[#lines].o_end or 0)
            local o_end = (i0 <= i1) and (toks[i1].o0 + ulen(toks[i1].t)) or o_start
            local line = {
                para = pi, first = is_first, top = y, height = lh, baseline = y + asc,
                text_x = text_x, o_start = o_start, o_end = o_end, segs = segs,
            }
            if is_first and bulletLabel then
                line.bullet = { text = bulletLabel, style = bulletStyle, x = 0 }
            end
            lines[#lines + 1] = line
            y = y + lh
        end

        if #toks == 0 then
            flush(1, 0, true)   -- empty paragraph: one empty line
        else
            local i0, cur_w, is_first = 1, 0, true
            for i = 1, #toks do
                local w = ctx.measure(toks[i].t, toks[i].style)
                if not toks[i].sp and cur_w > 0 and cur_w + w > avail then
                    flush(i0, i - 1, is_first); is_first = false
                    i0, cur_w = i, 0
                end
                cur_w = cur_w + w
            end
            flush(i0, #toks, is_first)
        end
    end
    -- if the very last paragraph ends with an explicit empty line handled above
    return { lines = lines, width = op.w, height = y }
end

-- Pixel x of the caret at char offset o on a given line.
local function caretXOnLine(line, o, ctx)
    local x = line.text_x
    for _, sg in ipairs(line.segs) do
        local segEnd = sg.o0 + ulen(sg.t)
        if o >= segEnd then
            x = sg.x + sg.w
        elseif o <= sg.o0 then
            return x
        else
            return sg.x + ctx.measure(usub(sg.t, 0, o - sg.o0), sg.style)
        end
    end
    return x
end

-- The line index a cursor sits on (the earliest line whose range contains o).
local function lineOfCursor(layout, cur)
    local fallback
    for i, ln in ipairs(layout.lines) do
        if ln.para == cur.p then
            fallback = i
            if cur.o <= ln.o_end then return i end
        end
    end
    return fallback or 1
end

-- Caret geometry {x, y, h} in op-local pixels for the cursor.
function Text.caret(op, layout, cur, ctx)
    local i = lineOfCursor(layout, cur)
    local ln = layout.lines[i] or { text_x = 0, top = 0, height = ctx.lineHeight(op.paras[1].spans[1]) }
    return { x = caretXOnLine(ln, cur.o, ctx), y = ln.top, h = ln.height }
end

-- Hit test: op-local (lx, ly) -> nearest cursor {p, o}.
function Text.hit(op, layout, lx, ly, ctx)
    local pick
    for _, ln in ipairs(layout.lines) do
        if ly < ln.top + ln.height then pick = ln; break end
    end
    pick = pick or layout.lines[#layout.lines]
    if not pick then return { p = 1, o = 0 } end
    -- walk chars on the line, choose the boundary nearest lx
    local best_o, best_dx = pick.o_start, math.abs(lx - pick.text_x)
    local x = pick.text_x
    for _, sg in ipairs(pick.segs) do
        local cs = chars(sg.t)
        local o = sg.o0
        for _, c in ipairs(cs) do
            x = x + ctx.measure(c, sg.style)
            o = o + 1
            local dx = math.abs(lx - x)
            if dx < best_dx then best_dx, best_o = dx, o end
        end
    end
    return { p = pick.para, o = best_o }
end

-- ---------------------------------------------------------------------------
-- Rendering. Draws the laid-out text into a blitbuffer at (ox, oy) in that
-- buffer's pixels. `rctx` supplies KOReader bits so layout stays testable:
--   rctx.face(style)   -> font face for a style
--   rctx.bold(style)   -> bold flag for RenderText
--   rctx.color         -> fg colour (Blitbuffer colour)
--   rctx.lineWidth     -> px thickness for underline / strike / bullet rules
-- Underline, strikethrough and highlight are drawn by us; bold/size come from
-- the face; italic uses an italic face when rctx.face provides one.
-- ---------------------------------------------------------------------------
function Text.render(op, layout, bb, ox, oy, ctx, rctx)
    local RenderText = require("ui/rendertext")
    local Blitbuffer = require("ffi/blitbuffer")
    local fg = rctx.color or Blitbuffer.COLOR_BLACK
    local hlcolor = rctx.highlight or Blitbuffer.COLOR_LIGHT_GRAY
    local lw = math.max(1, rctx.lineWidth or 2)
    local function drawSeg(sg, baseline)
        local face = ctx.face(sg.style)
        local bold = ctx.bold and ctx.bold(sg.style) or false
        local asc = ctx.ascent(sg.style)
        if sg.style.hl then
            local h = ctx.lineHeight(sg.style)
            bb:paintRect(math.floor(ox + sg.x), math.floor(oy + baseline - asc),
                math.ceil(sg.w), math.ceil(h), hlcolor)
        end
        if sg.style.i and sg.t ~= "" then
            -- Synthetic italic: render the run to a coverage buffer, then blit it
            -- one scanline at a time with a slant offset (no italic font needed,
            -- and only ~one blit per row, so it stays cheap on e-ink).
            local h = math.ceil(ctx.lineHeight(sg.style))
            local slant = 0.2
            local wseg = math.ceil(sg.w) + 2
            local tmp = Blitbuffer.new(wseg, h, Blitbuffer.TYPE_BB8)
            tmp:fill(Blitbuffer.COLOR_BLACK)   -- 0 = no coverage
            RenderText:renderUtf8Text(tmp, 0, asc, face, sg.t, true, bold, Blitbuffer.COLOR_WHITE)
            local top = baseline - asc
            for row = 0, h - 1 do
                local dx = math.floor(slant * (asc - row) + 0.5)
                bb:colorblitFrom(tmp, math.floor(ox + sg.x + dx), math.floor(oy + top + row),
                    0, row, wseg, 1, fg)
            end
            tmp:free()
        else
            RenderText:renderUtf8Text(bb, math.floor(ox + sg.x), math.floor(oy + baseline),
                face, sg.t, true, bold, fg)
        end
        if sg.style.u then
            local uy = math.floor(oy + baseline + math.max(1, ctx.ascent(sg.style) * 0.12))
            bb:paintRect(math.floor(ox + sg.x), uy, math.ceil(sg.w), lw, fg)
        end
        if sg.style.s then
            local sy = math.floor(oy + baseline - ctx.ascent(sg.style) * 0.32)
            bb:paintRect(math.floor(ox + sg.x), sy, math.ceil(sg.w), lw, fg)
        end
    end
    for _, ln in ipairs(layout.lines) do
        if ln.bullet then
            RenderText:renderUtf8Text(bb, math.floor(ox + ln.bullet.x), math.floor(oy + ln.baseline),
                ctx.face(ln.bullet.style), ln.bullet.text, true,
                ctx.bold and ctx.bold(ln.bullet.style) or false, fg)
        end
        for _, sg in ipairs(ln.segs) do drawSeg(sg, ln.baseline) end
    end
end

return Text
