--[[
The notebook model: an ordered list of pages over a fixed page size, plus the
ruling template shared by every page. Each page is just an ops list, exactly
like the single canvas, so a page draws, undoes and exports through the same
engine. The view keeps the current page loaded in the canvas and syncs it back
here on navigation, so only one page is ever composed into a bitmap at a time.

A page is a table { ops = {...}, src = <source PDF page number, or nil> }. The
`src` lets a page stay tied to its page in an imported PDF even after pages are
inserted, duplicated, reordered or deleted; a blank inserted page has src = nil.

Plain Lua, no KOReader, so it drives from the headless tests.
]]

local Notebook = {}
Notebook.__index = Notebook

local function newPage(src) return { ops = {}, src = src } end

-- Deep copy a value (ops lists hold nested tables: pts, color, sym...), so a
-- duplicated page never shares mutable state with the page it came from.
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepcopy(val) end
    return out
end
Notebook.deepcopy = deepcopy

-- w,h: fixed page size. template: { style = "lines"|"grid"|"dots"|"blank", size = px }.
function Notebook.new(w, h, template)
    return setmetatable({
        w = w,
        h = h,
        template = template or { style = "lines", size = 40 },
        pages = { newPage() },   -- start with one blank page
        index = 1,
    }, Notebook)
end

-- Normalise a loaded page. Back-compat: the first notebook format stored each
-- page as a bare ops array; the current format stores { ops = ..., src = ... }.
local function normPage(p)
    if type(p) ~= "table" then return newPage() end
    if p.ops ~= nil or p.src ~= nil then return { ops = p.ops or {}, src = p.src } end
    return { ops = p, src = nil }   -- old format: the table IS the ops array
end

-- Rebuild a notebook from a parsed project (Project.deserialize output, v2).
function Notebook.fromData(data)
    local nb = Notebook.new(data.w, data.h, data.template)
    if type(data.pages) == "table" and #data.pages > 0 then
        local pages = {}
        for i = 1, #data.pages do pages[i] = normPage(data.pages[i]) end
        nb.pages = pages
    end
    nb.index = 1
    return nb
end

function Notebook:count() return #self.pages end
function Notebook:currentPage() return self.pages[self.index] end
function Notebook:currentOps() return self.pages[self.index].ops end
function Notebook:setCurrentOps(ops) self.pages[self.index].ops = ops or {} end
function Notebook:currentSrc() return self.pages[self.index].src end
function Notebook:srcOf(i) return self.pages[i] and self.pages[i].src end

-- Move to page i (1-based). Returns true if it moved.
function Notebook:gotoPage(i)
    if not i or i < 1 or i > #self.pages or i == self.index then return false end
    self.index = i
    return true
end

-- Insert a blank page after the current one and move to it. Returns the index.
function Notebook:addPage()
    table.insert(self.pages, self.index + 1, newPage())
    self.index = self.index + 1
    return self.index
end

-- Duplicate the current page (ink and source), place it after, and move to it.
function Notebook:duplicatePage()
    local p = self.pages[self.index]
    table.insert(self.pages, self.index + 1, { ops = deepcopy(p.ops), src = p.src })
    self.index = self.index + 1
    return self.index
end

-- Move the current page one step earlier (-1) or later (+1). Returns the index.
function Notebook:movePage(dir)
    local j = self.index + (dir or 0)
    if j < 1 or j > #self.pages or j == self.index then return self.index end
    self.pages[self.index], self.pages[j] = self.pages[j], self.pages[self.index]
    self.index = j
    return self.index
end

-- Remove the current page (never below one page). Returns the new index.
function Notebook:deletePage()
    if #self.pages <= 1 then
        self.pages[1] = newPage()
        self.index = 1
    else
        table.remove(self.pages, self.index)
        if self.index > #self.pages then self.index = #self.pages end
    end
    return self.index
end

return Notebook
