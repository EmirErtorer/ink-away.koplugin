--[[
A tiny PDF writer: one JPEG image per page, at a fixed page size.

A notebook exports to PDF so it can be read on any device with real, fixed
pages (unlike an EPUB, which reflows). Each page is rendered to a JPEG and the
JPEG bytes are embedded verbatim as a /DCTDecode image, which is the one image
filter PDF understands natively, so nothing is re-encoded. The result is a plain,
widely compatible PDF that KOReader (and everything else) opens as a paged book.

No external dependencies: it just concatenates PDF objects and writes a correct
cross-reference table, the same approach as the project's small PNG test encoder.
Pages are added and encoded one at a time, so memory stays flat.

Object layout (1-based): 1 = Catalog, 2 = Pages, then for page i:
    image  = 3i      (the JPEG XObject)
    content= 3i + 1  (draws the image to fill the page)
    page   = 3i + 2
]]

local Pdf = {}
Pdf.__index = Pdf

function Pdf.new()
    return setmetatable({ pages = {} }, Pdf)
end

-- Add a page. `w`,`h` are the page box in points; `pxw`,`pxh` are the JPEG's
-- pixel dimensions (default to w,h). Keeping them separate lets a higher-
-- resolution image sit inside a page-sized box, so text stays crisp.
function Pdf:addJPEGPage(jpeg, w, h, pxw, pxh)
    self.pages[#self.pages + 1] = { jpeg = jpeg, w = w, h = h, pxw = pxw or w, pxh = pxh or h }
end

function Pdf:pageCount()
    return #self.pages
end

-- Assemble the whole document into one string.
function Pdf:build()
    local n = #self.pages
    local parts, pos, off = {}, 0, {}
    local function put(s)
        parts[#parts + 1] = s
        pos = pos + #s
    end
    local function startobj(num) off[num] = pos end

    -- header (the binary comment marks the file as containing binary data)
    put("%PDF-1.4\n%\226\227\207\211\n")

    -- 1: catalog
    startobj(1)
    put("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

    -- 2: page tree
    local kids = {}
    for i = 1, n do kids[i] = (3 * i + 2) .. " 0 R" end
    startobj(2)
    put("2 0 obj\n<< /Type /Pages /Kids [" .. table.concat(kids, " ") ..
        "] /Count " .. n .. " >>\nendobj\n")

    for i = 1, n do
        local p = self.pages[i]
        local img_n, con_n, pg_n = 3 * i, 3 * i + 1, 3 * i + 2

        -- image XObject: the JPEG, embedded as-is
        startobj(img_n)
        put(img_n .. " 0 obj\n<< /Type /XObject /Subtype /Image /Width " ..
            p.pxw .. " /Height " .. p.pxh ..
            " /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length " ..
            #p.jpeg .. " >>\nstream\n")
        put(p.jpeg)
        put("\nendstream\nendobj\n")

        -- content: scale the unit image up to the page box and paint it
        local content = string.format("q\n%d 0 0 %d 0 0 cm\n/Im0 Do\nQ\n", p.w, p.h)
        startobj(con_n)
        put(con_n .. " 0 obj\n<< /Length " .. #content .. " >>\nstream\n" ..
            content .. "endstream\nendobj\n")

        -- page: fixed MediaBox = the image size, in points
        startobj(pg_n)
        put(pg_n .. " 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " ..
            p.w .. " " .. p.h .. "] /Resources << /XObject << /Im0 " ..
            img_n .. " 0 R >> >> /Contents " .. con_n .. " 0 R >>\nendobj\n")
    end

    -- cross-reference table (each entry is exactly 20 bytes)
    local total = 2 + 3 * n
    local xref_pos = pos
    put("xref\n0 " .. (total + 1) .. "\n")
    put("0000000000 65535 f \n")
    for num = 1, total do
        put(string.format("%010d 00000 n \n", off[num] or 0))
    end
    put("trailer\n<< /Size " .. (total + 1) .. " /Root 1 0 R >>\nstartxref\n" ..
        xref_pos .. "\n%%EOF\n")

    return table.concat(parts)
end

-- Write the document to `path`. Returns ok, err.
function Pdf:save(path)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(self:build())
    f:close()
    return true
end

return Pdf
