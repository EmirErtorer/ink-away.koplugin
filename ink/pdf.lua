--[[
A small PDF writer: one JPEG image per page, at a fixed page size. Each JPEG is
embedded as-is (/DCTDecode, the image filter PDF reads natively), and pages are
written to disk as they are added, so memory stays flat however long the document.

Objects: 1 catalog, 2 page tree, then for page i: 3i image, 3i+1 content, 3i+2
page. The page tree goes last; the xref table records where each object sits.
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
    st.off[1] = st.pos
    st:put("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
    return st
end

function Stream:put(s)
    if self.failed then return false end
    if not self.f:write(s) then self.failed = true; return false end
    self.pos = self.pos + #s
    return true
end

-- Add one page from a JPEG file on disk, copied across in chunks (it is never held
-- in memory whole). `w`,`h` are the page box in points; `pxw`,`pxh` the JPEG's
-- pixel size. Returns ok, err.
function Stream:addJPEGFile(jpeg_path, w, h, pxw, pxh)
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
    self.off[pg_n] = self.pos
    self:put(pg_n .. " 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " ..
        w .. " " .. h .. "] /Resources << /XObject << /Im0 " ..
        img_n .. " 0 R >> >> /Contents " .. con_n .. " 0 R >>\nendobj\n")
    if self.failed then return false, "could not write the PDF (is the storage full?)" end
    return true
end

-- Write the page tree, cross-reference table and trailer, and close. Returns ok, err.
function Stream:finish()
    local n = self.n
    local kids = {}
    for i = 1, n do kids[i] = (3 * i + 2) .. " 0 R" end
    self.off[2] = self.pos
    self:put("2 0 obj\n<< /Type /Pages /Kids [" .. table.concat(kids, " ") ..
        "] /Count " .. n .. " >>\nendobj\n")
    local total = 2 + 3 * n
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
