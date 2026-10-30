--[[
An editable PDF: a copy of the original PDF with the ink and the highlights
added as annotations (see ink/export/annots.lua), written with the MuPDF
KOReader already has. The original file is never touched and its pages stay as
they are, text and all, so the copy is about the original's size plus the ink.

The copy is made first and the annotations are appended to it as an incremental
update, so a long PDF is not written out again; a PDF MuPDF will not append to
is written out whole instead. The job works a page a step, so the progress
sheet can stop it, and removes the copy if it is stopped or fails.

  job = Pdfedit.job(src, dst, pages)
  pages: list of { page = n, groups = { ... } (Annots.convert), marks = { ... } }
  job.step() -> "page", i, n | "done" | nil, err        job.cancel()
A mark is a highlight of the reader's: { pboxes, drawer, color (hex), note }.
]]

local ffi = require("ffi")

local Pdfedit = {}

local CHUNK = 1048576   -- bytes copied per step

-- Can this KOReader write ink annotations? Its MuPDF must be there with the
-- call that makes them (older builds have only the highlights); the call is
-- found on a page of `path`, the PDF about to be written to.
function Pdfedit.available(path)
    local ok, yes = pcall(function()
        local M = require("ffi/mupdf")
        local doc = M.openDocument(path)
        local page = doc:openPage(1)
        local has = page.addInkAnnotation ~= nil
        page:close()
        doc:close()
        return has
    end)
    return ok and yes == true
end

-- "#RRGGBB" as { r, g, b } (0-255), or nil.
local function rgb(hex)
    local r, g, b = tostring(hex or ""):match("^#(%x%x)(%x%x)(%x%x)")
    if not r then return nil end
    return { r = tonumber(r, 16), g = tonumber(g, 16), b = tonumber(b, 16) }
end

-- The quad points of a highlight's boxes, in the order MuPDF wants (see
-- KOReader's own frontend/document/pdfdocument.lua).
local function quads(pboxes)
    local n = #pboxes
    local q = ffi.new("fz_quad[?]", n)
    for i = 1, n do
        local b = pboxes[i]
        q[i - 1].ll.x, q[i - 1].ll.y = b.x, b.y + b.h - 1
        q[i - 1].lr.x, q[i - 1].lr.y = b.x + b.w - 1, b.y + b.h - 1
        q[i - 1].ul.x, q[i - 1].ul.y = b.x, b.y
        q[i - 1].ur.x, q[i - 1].ur.y = b.x + b.w - 1, b.y
    end
    return q, n
end

-- Add one page's annotations to the open `doc`. Returns false, err when the
-- build cannot write ink.
local function addPage(doc, p)
    local page = doc:openPage(p.page)
    local ok, err = pcall(function()
        if #p.groups > 0 and not page.addInkAnnotation then error("no ink annotations in this KOReader") end
        for _i, g in ipairs(p.groups) do
            page:addInkAnnotation(g.strokes, g.color, g.width, g.opacity)
        end
        for _i, m in ipairs(p.marks or {}) do
            if m.pboxes and #m.pboxes > 0 then
                local q, n = quads(m.pboxes)
                -- one KOReader already wrote into the file ("Write highlights
                -- into PDF") is there once
                local have = page:getMarkupAnnotation(q, n)
                if not have then
                    local kind = ffi.C.PDF_ANNOT_HIGHLIGHT
                    if m.drawer == "underscore" then kind = ffi.C.PDF_ANNOT_UNDERLINE
                    elseif m.drawer == "strikeout" then kind = ffi.C.PDF_ANNOT_STRIKE_OUT end
                    page:addMarkupAnnotation(q, n, kind, rgb(m.color))
                    if m.note and m.note ~= "" then
                        local a = page:getMarkupAnnotation(q, n)
                        if a then page:updateMarkupAnnotation(a, m.note) end
                    end
                end
            end
        end
    end)
    page:close()
    return ok, err
end

-- Copy `src` to `dst` a chunk per call: returns a function giving true when done.
local function copier(src, dst)
    local fi, e1 = io.open(src, "rb")
    if not fi then return nil, e1 end
    local fo, e2 = io.open(dst, "wb")
    if not fo then fi:close(); return nil, e2 end
    return function()
        local chunk = fi:read(CHUNK)
        if chunk then
            if not fo:write(chunk) then fi:close(); fo:close(); return nil, "could not write the PDF (is the storage full?)" end
            return false
        end
        fi:close(); fo:close()
        return true
    end
end

function Pdfedit.job(src, dst, pages)
    local M = require("ffi/mupdf")
    local job = { i = 0, n = #pages }
    local copy, doc, finished
    local function drop()
        if doc then pcall(function() doc:close() end); doc = nil end
        os.remove(dst)
        job.over = true
    end
    local function fail(e)
        drop()
        return nil, e
    end
    -- the pages again on a handle of the original, then written out whole
    local function writeWhole()
        if doc then pcall(function() doc:close() end); doc = nil end
        os.remove(dst)
        local d = M.openDocument(src)
        local ok, err = pcall(function()
            for _i, p in ipairs(pages) do
                local ok2, e2 = addPage(d, p)
                if not ok2 then error(e2) end
            end
            d:writeDocument(dst)
        end)
        pcall(function() d:close() end)
        return ok, err
    end
    function job.step()
        if job.over then return nil, "finished" end
        if not copy then
            local c, e = copier(src, dst)
            if not c then return fail(e) end
            copy = c
        end
        if not doc then
            local done, e = copy()
            if done == nil then return fail(e) end
            if not done then return "page", 0, job.n end
            local ok, d = pcall(M.openDocument, dst)
            if not ok then return fail(d) end
            doc = d
        end
        if job.i < job.n then
            job.i = job.i + 1
            local ok, e = addPage(doc, pages[job.i])
            if not ok then return fail(e) end
            return "page", job.i, job.n
        end
        if not finished then
            finished = true
            local ok, err = pcall(function() doc:writeDocument(dst) end)
            if not ok then
                local ok2, err2 = writeWhole()
                if not ok2 then return fail(err2 or err) end
            end
            if doc then pcall(function() doc:close() end); doc = nil end
            job.over = true
            return "done"
        end
        return nil, "finished"
    end
    function job.cancel()
        if job.over then return end
        drop()
    end
    return job
end

return Pdfedit
