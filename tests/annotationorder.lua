-- KOReader's fix for sorting highlights that point at nothing (#15994), put into
-- older KOReader by ink/reader/annotationorder.lua: a book with such a highlight
-- opens instead of stopping with "invalid order function for sorting".
package.path = "./?.lua;" .. package.path
local AnnotationOrder = require("ink/reader/annotationorder")

local pass, fail = 0, 0
local function check(cond, what)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. what) end
end

-- xpointers "/x<n>" are in the book (n = position); "/bad..." are not
local function pos(xp) return tonumber(xp:match("^/x(%d+)")) end
local document = {
    isXPointerInDocument = function(_, xp) return pos(xp) ~= nil end,
    getPageFromXPointer = function(_, xp) local p = pos(xp); return p and math.floor(p / 10) or 1 end,
    compareXPointers = function(_, a, b)
        local x, y = pos(a), pos(b)
        if not (x and y) then return nil end
        return x < y and 1 or (x > y and -1 or 0)
    end,
}

-- KOReader v2025.10's order: invalid xpointers make it answer true both ways
local function oldOrder(self, a, b)
    local a_page = self.document:getPageFromXPointer(a.page)
    local b_page = self.document:getPageFromXPointer(b.page)
    if a_page == b_page then
        if (not a.drawer) ~= (not b.drawer) then return not a.drawer end
        local compare_xp = self.document:compareXPointers(a.page, b.page)
        if compare_xp then
            if a.drawer and compare_xp == 0 then
                compare_xp = self.document:compareXPointers(a.pos1, b.pos1)
                if compare_xp then return compare_xp > 0 end
                return true
            end
            return compare_xp > 0
        end
        return true
    end
    return a_page < b_page
end

local function items()
    local list = {}
    for i = 1, 30 do
        local bad = i % 3 == 0
        local p = bad and ("/bad" .. i) or ("/x" .. (12 + (i * 7) % 5))
        list[#list + 1] = { page = p, pos0 = p, pos1 = bad and p or ("/x" .. (30 - i % 4)), drawer = "lighten",
            datetime = string.format("2026-11-15 15:%02d:00", i) }
    end
    return list
end

local function sortWith(RA)
    local self = setmetatable({ document = document }, { __index = RA })
    local list = items()
    local ok, err = pcall(table.sort, list, function(a, b) return RA.isItemInPositionOrderRolling(self, a, b) end)
    return ok, err, list
end

-- the old order fails as on the reporter's reader
local Old = { isItemInPositionOrderRolling = oldOrder }
local ok_old, err_old = sortWith(Old)
check(not ok_old and tostring(err_old):find("invalid order function") ~= nil, "v2025.10's order fails on invalid xpointers: " .. tostring(err_old))

-- with the fix put in: sorted, the invalid ones first by time, the rest in place order
local Patched = { isItemInPositionOrderRolling = oldOrder }
check(AnnotationOrder.install(Patched) == true, "the fix goes into a KOReader without it")
local ok, err, list = sortWith(Patched)
check(ok, "sorted with the fix: " .. tostring(err))
local seen_valid, order_ok, prev = false, true, nil
for _, a in ipairs(list) do
    local valid = pos(a.page) ~= nil
    if valid then seen_valid = true elseif seen_valid then order_ok = false end
    if valid and prev and pos(prev.page) and pos(prev.page) > pos(a.page) then order_ok = false end
    if valid then prev = a end
end
check(order_ok, "highlights that point at nothing go first, the others by place")

-- a KOReader that has the fix keeps its own
local Fixed = { getInvalidXPointersOrder = function() end, isItemInPositionOrderRolling = oldOrder }
check(AnnotationOrder.install(Fixed) == false and Fixed.isItemInPositionOrderRolling == oldOrder, "a KOReader with the fix is left alone")

print(string.format("annotationorder: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
