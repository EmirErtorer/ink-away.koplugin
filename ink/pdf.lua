--[[
A small PDF writer: one JPEG image per page. Each JPEG is embedded as it is
(/DCTDecode) and written to disk as the page is added, so memory stays flat
however long the document. An optional outline (bookmarks) is added at the end.

Objects: 1 catalog, 2 page tree, then for page i: 3i image, 3i+1 content, 3i+2
page, then the outline. The catalog and page tree go last, once everything they
point to is known; the xref table records where each object sits.
]]

local Pdf = {}

local Stream = {}
Stream.__index = Stream

-- Open `path` for streaming. Returns the writer, or nil, err.
function Pdf.openStream(path)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local st = setmetatable({ f = f, path = path, pos = 0, off = {}, n = 0, sizes = {} }, Stream)
    if not st:put("%PDF-1.4\n%\226\227\207\211\n") then st:abort(); return nil, "write failed" end
    return st
end

-- A PDF text string: plain ASCII as a literal string, anything else as UTF-16
-- (big-endian, with its byte order mark) in hex, so any title reads right.
function Pdf.text(s)
    if not s:find("[^\32-\126]") then
        return "(" .. s:gsub("[\\()]", "\\%0") .. ")"
    end
    local out = { "<FEFF" }
    local function unit(u) out[#out + 1] = string.format("%04X", u) end
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local cp, len
        if c < 0x80 then cp, len = c, 1
        elseif c >= 0xF0 then cp, len = c % 0x08, 4
        elseif c >= 0xE0 then cp, len = c % 0x10, 3
        elseif c >= 0xC0 then cp, len = c % 0x20, 2
        else cp, len = 0xFFFD, 1 end
        for k = 1, len - 1 do cp = cp * 64 + ((s:byte(i + k) or 0x80) % 64) end
        if cp >= 0x10000 then
            cp = cp - 0x10000
            unit(0xD800 + math.floor(cp / 1024)); unit(0xDC00 + cp % 1024)
        else
            unit(cp)
        end
        i = i + len
    end
    out[#out + 1] = ">"
    return table.concat(out)
end

function Stream:put(s)
    if self.failed then return false end
    if not self.f:write(s) then self.failed = true; return false end
    self.pos = self.pos + #s
    return true
end

-- Add one page from a JPEG file on disk, copied in chunks so it is never held in
-- memory whole. `w`, `h` are the page box in points and `pxw`, `pxh` the JPEG's
-- pixel size. `links` (optional) are areas that lead to other pages of the
-- file: { x0, y0, x1, y1 (points, y up), page = its number from 1 }. Returns
-- ok, err.
function Stream:addJPEGFile(jpeg_path, w, h, pxw, pxh, links)
    local jf = io.open(jpeg_path, "rb")
    if not jf then return false, "could not read rendered page" end
    local len = jf:seek("end")
    jf:seek("set", 0)
    self.n = self.n + 1
    local i = self.n
    local img_n, con_n, pg_n = 3 * i, 3 * i + 1, 3 * i + 2
    pxw, pxh = pxw or w, pxh or h
    self.off[img_n] = self.pos
    self:put(img_n .. " 0 obj\n<< /Type /XObject /Subtype /Image /Width " ..
        pxw .. " /Height " .. pxh ..
        " /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length " ..
        len .. " >>\nstream\n")
    while true do
        local chunk = jf:read(262144)
        if not chunk then break end
        self:put(chunk)
    end
    jf:close()
    self:put("\nendstream\nendobj\n")
    local content = string.format("q\n%d 0 0 %d 0 0 cm\n/Im0 Do\nQ\n", w, h)
    self.off[con_n] = self.pos
    self:put(con_n .. " 0 obj\n<< /Length " .. #content .. " >>\nstream\n" ..
        content .. "endstream\nendobj\n")
    -- a page's object number is 3 * its number + 2, so a link can name a page
    -- not written yet
    local annots = ""
    if links and #links > 0 then
        local a = {}
        for _, l in ipairs(links) do
            a[#a + 1] = string.format("<< /Type /Annot /Subtype /Link /Rect [%.2f %.2f %.2f %.2f] /Border [0 0 0]"
                .. " /Dest [%d 0 R /Fit] >>", l.x0, l.y0, l.x1, l.y1, 3 * l.page + 2)
        end
        annots = " /Annots [" .. table.concat(a, " ") .. "]"
    end
    self.off[pg_n] = self.pos
    self:put(pg_n .. " 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " ..
        w .. " " .. h .. "] /Resources << /XObject << /Im0 " ..
        img_n .. " 0 R >> >> /Contents " .. con_n .. " 0 R" .. annots .. " >>\nendobj\n")
    if self.failed then return false, "could not write the PDF (is the storage full?)" end
    return true
end

-- Write the outline items `items` (a list of { title, page, kids }) under
-- parent object `parent`, numbering from self.next. Returns the first and last
-- object numbers and how many items show (all of them: they start open).
function Stream:writeOutline(items, parent)
    local nums = {}
    for i = 1, #items do nums[i] = self.next; self.next = self.next + 1 end
    local shown = #items
    for i, it in ipairs(items) do
        local first, last, count
        if it.kids and #it.kids > 0 then first, last, count = self:writeOutline(it.kids, nums[i]) end
        local page = math.max(1, math.min(self.n, it.page or 1))
        local parts = { nums[i] .. " 0 obj\n<< /Title " .. Pdf.text(it.title or "") ..
            " /Parent " .. parent .. " 0 R /Dest [" .. (3 * page + 2) .. " 0 R /Fit]" }
        if i > 1 then parts[#parts + 1] = " /Prev " .. nums[i - 1] .. " 0 R" end
        if i < #items then parts[#parts + 1] = " /Next " .. nums[i + 1] .. " 0 R" end
        if first then
            parts[#parts + 1] = " /First " .. first .. " 0 R /Last " .. last .. " 0 R /Count " .. count
            shown = shown + count
        end
        parts[#parts + 1] = " >>\nendobj\n"
        self.off[nums[i]] = self.pos
        self:put(table.concat(parts))
    end
    return nums[1], nums[#nums], shown
end

-- Write the outline (if any), page tree, catalog, cross-reference table and
-- trailer, and close. `outline` is an optional list of { title, page, kids }
-- with pages counted from 1. Returns ok, err.
function Stream:finish(outline)
    local n = self.n
    local kids = {}
    for i = 1, n do kids[i] = (3 * i + 2) .. " 0 R" end
    self.next = 3 * n + 3
    local outline_ref = ""
    if outline and #outline > 0 and n > 0 then
        local root = self.next
        self.next = self.next + 1
        local first, last, count = self:writeOutline(outline, root)
        self.off[root] = self.pos
        self:put(root .. " 0 obj\n<< /Type /Outlines /First " .. first .. " 0 R /Last " .. last ..
            " 0 R /Count " .. count .. " >>\nendobj\n")
        outline_ref = " /Outlines " .. root .. " 0 R /PageMode /UseOutlines"
    end
    self.off[2] = self.pos
    self:put("2 0 obj\n<< /Type /Pages /Kids [" .. table.concat(kids, " ") ..
        "] /Count " .. n .. " >>\nendobj\n")
    self.off[1] = self.pos
    self:put("1 0 obj\n<< /Type /Catalog /Pages 2 0 R" .. outline_ref .. " >>\nendobj\n")
    local total = self.next - 1
    local xref_pos = self.pos
    local xref = { "xref\n0 " .. (total + 1) .. "\n", "0000000000 65535 f \n" }
    for num = 1, total do
        xref[#xref + 1] = string.format("%010d 00000 n \n", self.off[num] or 0)
    end
    self:put(table.concat(xref))
    self:put("trailer\n<< /Size " .. (total + 1) .. " /Root 1 0 R >>\nstartxref\n" ..
        xref_pos .. "\n%%EOF\n")
    local failed = self.failed
    self.f:close()
    self.f = nil
    if failed then os.remove(self.path); return false, "could not write the PDF (is the storage full?)" end
    return true
end

-- Give up: close and delete the partial file.
function Stream:abort()
    if self.f then self.f:close(); self.f = nil end
    os.remove(self.path)
end

return Pdf
