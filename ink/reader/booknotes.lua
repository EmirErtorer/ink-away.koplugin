--[[
Book notes: one notebook per book, in the library's "Book notes" folder, named
after the book, with a page (or a run of pages) per chapter in the book's
order. Opening the notes in a chapter goes to that chapter's last page; a
chapter without one gets a new page titled with its name, put where the
chapter comes in the book, so the notebook's contents are the book's chapters.

Each chapter page remembers its chapter as page.book = { toc = <the chapter's
place in the book's contents>, md5 = <the book's checksum> }; pages added by
hand belong to the chapter page before them. Plain Lua: the headless tests
drive it.
]]

local BookNotes = {}

BookNotes.FOLDER = "Book notes"

-- A file name for a book title: no path separators or characters some file
-- systems refuse, no leading dot, not too long.
function BookNotes.fileName(title)
    local s = tostring(title or ""):gsub("[%c/\\:%*%?\"<>|]", " "):gsub("%s+", " ")
    s = s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if #s > 80 then
        -- cut at a character boundary
        local cut = 80
        while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        s = s:sub(1, cut):gsub("%s+$", "")
    end
    if s == "" then s = "Book" end
    return s
end

-- Is a notebook (its pages) another book's? Only when its chapter pages say so.
function BookNotes.otherBook(pages, md5)
    if not md5 then return false end
    for _i, p in ipairs(pages or {}) do
        if type(p.book) == "table" and p.book.md5 then return p.book.md5 ~= md5 end
    end
    return false
end

-- Where to write for chapter `key` (its place in the contents; nil when the
-- book has none): { index = n } for an existing page, or { insert = n } for a
-- new chapter page to put at n. A notebook that is just one empty page without
-- a chapter takes the chapter itself: { index = 1, claim = true }.
function BookNotes.placeFor(pages, key)
    local n = #pages
    if n == 0 then return { insert = 1 } end
    if n == 1 and not pages[1].book and #(pages[1].ops or {}) == 0 then
        return { index = 1, claim = true }
    end
    if key == nil then return { index = n } end
    -- each page's chapter: its own, or the chapter page's before it
    local last_of, insert_at, cur = nil, nil, nil
    for i, p in ipairs(pages) do
        if type(p.book) == "table" and type(p.book.toc) == "number" then cur = p.book.toc end
        if cur == key then last_of = i end
        if not insert_at and cur and cur > key then insert_at = i end
    end
    if last_of then return { index = last_of } end
    -- before the first page of a later chapter, else at the end
    return { insert = insert_at or (n + 1) }
end

return BookNotes
