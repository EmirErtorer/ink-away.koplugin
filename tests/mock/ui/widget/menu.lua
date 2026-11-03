-- KOReader's Menu, as far as the tests need it: it keeps its options and its
-- item_table, and a test picks an entry with M:pick(text).
local Menu = {}
Menu.__index = Menu
function Menu:new(o) o = o or {}; setmetatable(o, self); Menu.last = o; return o end
function Menu:pick(text)
    for _, it in ipairs(self.item_table or {}) do
        if it.text == text and it.callback then it.callback(); return true end
    end
    return false
end
function Menu:switchItemTable(title, items) if title then self.title = title end self.item_table = items; self.switched = (self.switched or 0) + 1 end
function Menu:onMenuSelect(item) if item.callback then item.callback() end return true end
function Menu:onClose() if self.close_callback then self.close_callback() end end
return Menu
