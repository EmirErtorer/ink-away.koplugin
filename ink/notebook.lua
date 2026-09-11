--[[
The notebook model: an ordered list of pages over a fixed page size, plus the
ruling template shared by every page. Each page is just an ops list, exactly
like the single canvas, so a page draws, undoes and exports through the same
engine. The view keeps the current page loaded in the canvas and syncs it back
here on navigation, so only one page is ever composed into a bitmap at a time.

Plain Lua, no KOReader, so it drives from the headless tests.
]]

local Notebook = {}
Notebook.__index = Notebook

-- w,h: fixed page size. template: { style = "lines"|"grid"|"dots"|"blank", size = px }.
function Notebook.new(w, h, template)
    return setmetatable({
        w = w,
        h = h,
        template = template or { style = "lines", size = 40 },
        pages = { {} },   -- start with one blank page
        index = 1,
    }, Notebook)
end

-- Rebuild a notebook from a parsed project (Project.deserialize output, v2).
function Notebook.fromData(data)
    local nb = Notebook.new(data.w, data.h, data.template)
    if type(data.pages) == "table" and #data.pages > 0 then
        nb.pages = data.pages
    end
    nb.index = 1
    return nb
end

function Notebook:count() return #self.pages end
function Notebook:currentOps() return self.pages[self.index] end
function Notebook:setCurrentOps(ops) self.pages[self.index] = ops or {} end

-- Move to page i (1-based). Returns true if it moved.
function Notebook:gotoPage(i)
    if not i or i < 1 or i > #self.pages or i == self.index then return false end
    self.index = i
    return true
end

-- Insert a blank page after the current one and move to it. Returns the index.
function Notebook:addPage()
    table.insert(self.pages, self.index + 1, {})
    self.index = self.index + 1
    return self.index
end

-- Remove the current page (never below one page). Returns the new index.
function Notebook:deletePage()
    if #self.pages <= 1 then
        self.pages[1] = {}
        self.index = 1
    else
        table.remove(self.pages, self.index)
        if self.index > #self.pages then self.index = #self.pages end
    end
    return self.index
end

return Notebook
