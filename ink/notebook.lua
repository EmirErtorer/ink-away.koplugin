--[[
The notebook model: an ordered list of pages of one size, plus the ruling
template they share. A page is { id, ops, src, created, modified }, and may have
a title, a star and its own paper style: its ops work like a drawing's, `src`
keeps it tied to its page of an imported PDF through inserts, duplicates, moves
and deletes (a blank inserted page has none), and the rest stays with the page
wherever it moves. The view keeps the current
page in its canvas and syncs it back on navigation. Plain Lua, so the headless
tests drive it.
]]

local Notebook = {}
Notebook.__index = Notebook

-- The clock pages are stamped with (replaced in the tests).
Notebook.now = os.time

-- Deep copy a value (ops hold nested tables), so a duplicated page shares no
-- state with the page it came from.
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepcopy(val) end
    return out
end
Notebook.deepcopy = deepcopy

-- A blank page with the next free id, tied to PDF page `src` if given.
function Notebook:newPage(src)
    local id = self.next_id or 1
    self.next_id = id + 1
    local t = Notebook.now()
    return { id = id, ops = {}, src = src, created = t, modified = t }
end

-- A new notebook of w x h pages; template is { style = "lines"|"grid"|"dots"|"blank", size = px }.
function Notebook.new(w, h, template)
    local nb = setmetatable({
        w = w,
        h = h,
        template = template or { style = "lines", size = 40 },
        index = 1,
        next_id = 1,
    }, Notebook)
    nb.pages = { nb:newPage() }   -- start with one blank page
    return nb
end

-- A notebook over an imported PDF: one blank ink layer per PDF page.
function Notebook.forPdf(w, h, template, count)
    local nb = Notebook.new(w, h, template)
    nb.next_id = 1
    local pages = {}
    for i = 1, count do pages[i] = nb:newPage(i) end
    nb.pages = pages
    return nb
end

-- The fields a page keeps besides its ops.
local PAGE_FIELDS = { "id", "src", "created", "modified", "title", "star", "paper" }

-- Normalise a loaded page: older files store a page as a bare ops array, newer
-- ones as { ops = ..., src = ... }, and only the newest carry ids and times.
local function normPage(p)
    if type(p) ~= "table" then return { ops = {} } end
    if p.ops == nil and p.src == nil and p.id == nil then return { ops = p } end   -- a bare ops array
    local page = { ops = p.ops or {} }
    for _, k in ipairs(PAGE_FIELDS) do page[k] = p[k] end
    return page
end

-- Rebuild a notebook from a parsed project (Project.deserialize output, v2).
-- Pages from older files get ids here.
function Notebook.fromData(data)
    local nb = Notebook.new(data.w, data.h, data.template)
    if type(data.pages) == "table" and #data.pages > 0 then
        local pages, top = {}, 0
        for i = 1, #data.pages do
            pages[i] = normPage(data.pages[i])
            if type(pages[i].id) == "number" and pages[i].id > top then top = pages[i].id end
        end
        nb.next_id = top + 1
        for _, page in ipairs(pages) do
            if type(page.id) ~= "number" then page.id = nb.next_id; nb.next_id = nb.next_id + 1 end
        end
        nb.pages = pages
    end
    nb.index = 1
    return nb
end

function Notebook:count() return #self.pages end
function Notebook:currentOps() return self.pages[self.index].ops end
function Notebook:setCurrentOps(ops) self.pages[self.index].ops = ops or {} end
function Notebook:currentSrc() return self.pages[self.index].src end
function Notebook:srcOf(i) return self.pages[i] and self.pages[i].src end

-- Stamp page i (the current page by default) as changed now.
function Notebook:touch(i)
    local page = self.pages[i or self.index]
    if page then page.modified = Notebook.now() end
end

-- Does any page hold ink, text or pictures?
function Notebook:hasInk()
    for _, page in ipairs(self.pages) do
        if page.ops and #page.ops > 0 then return true end
    end
    return false
end

-- Move to page i (1-based). Returns true if it moved.
function Notebook:gotoPage(i)
    if not i or i < 1 or i > #self.pages or i == self.index then return false end
    self.index = i
    return true
end

-- The ruling page i (the current page by default) is drawn with: the notebook's
-- template, or a view of it with the page's own paper style. The same table
-- comes back while nothing changes, so callers can compare it, and size and
-- strength still follow the notebook's.
function Notebook:pageTemplate(i)
    local page = self.pages[i or self.index]
    local style = page and page.paper
    if not style or style == self.template.style then return self.template end
    if self._views_for ~= self.template then self._views, self._views_for = {}, self.template end
    local view = self._views[style]
    if not view then
        view = setmetatable({ style = style }, { __index = self.template })
        self._views[style] = view
    end
    return view
end

-- Insert a blank page after the current one, on the same paper, and move to it.
-- Returns the index.
function Notebook:addPage()
    local page = self:newPage()
    page.paper = self.pages[self.index] and self.pages[self.index].paper
    table.insert(self.pages, self.index + 1, page)
    self.index = self.index + 1
    return self.index
end

-- Insert a blank page before the current one, on the same paper, and move to it.
-- Returns the index.
function Notebook:insertPageBefore()
    local page = self:newPage()
    page.paper = self.pages[self.index] and self.pages[self.index].paper
    table.insert(self.pages, self.index, page)
    return self.index
end

-- Duplicate the current page (ink, source, title and paper), place it after, and
-- move to it. The copy is a new page with its own id.
function Notebook:duplicatePage()
    local p = self.pages[self.index]
    local copy = self:newPage(p.src)
    copy.ops, copy.title, copy.paper = deepcopy(p.ops), p.title, deepcopy(p.paper)
    table.insert(self.pages, self.index + 1, copy)
    self.index = self.index + 1
    return self.index
end

-- Move the current page one step earlier (-1) or later (+1). Returns the index.
function Notebook:movePage(dir)
    return self:movePageTo(self.index + (dir or 0))
end

-- Move the current page to position n (kept within the notebook) and follow it.
-- Returns the index.
function Notebook:movePageTo(n)
    n = math.max(1, math.min(#self.pages, math.floor(n or self.index)))
    if n == self.index then return self.index end
    local page = table.remove(self.pages, self.index)
    table.insert(self.pages, n, page)
    self.index = n
    return n
end

-- Remove the current page (never below one page). Returns the new index.
function Notebook:deletePage()
    if #self.pages <= 1 then
        self.pages[1] = self:newPage()
        self.index = 1
    else
        table.remove(self.pages, self.index)
        if self.index > #self.pages then self.index = #self.pages end
    end
    return self.index
end

return Notebook
