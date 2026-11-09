-- The colours a tap on a highlight offers (ink/reader/hlpalette.lua) and giving a
-- highlight one (Book:setHighlightColour), headless, against a stand-in reader.
--   luajit tests/hlpalette.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local P = require("ink/reader/hlpalette")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- the list: the reader's colours until the person sets their own, then theirs cleaned
local store = {}
local function get(k) return store[k] end
ok(#P.list(get) == #P.DEFAULT and P.isDefault(get), "a palette not set is the reader's colours")
store[P.SETTING] = { "blue", "#ff8800", "blue", "nonsense", 7, "#12AB34", "gray" }
ok(same(P.list(get), { "blue", "#FF8800", "#12AB34", "gray" }), "a set palette drops unknown and repeated entries")
ok(not P.isDefault(get), "a set palette is not the default")
store[P.SETTING] = "junk"
ok(#P.list(get) == #P.DEFAULT, "a setting of the wrong kind falls back to the default")
local many = {}
for i = 1, 40 do many[i] = string.format("#%06X", i * 1000) end
store[P.SETTING] = many
ok(#P.list(get) == P.MAX, "the palette is capped")
ok(#P.list(nil) == #P.DEFAULT, "no settings at all is fine")

-- adding and removing
local l = { "red", "blue" }
ok(same(P.added(l, "#112233"), { "red", "blue", "#112233" }), "added puts a colour last")
ok(P.added(l, "red") == l, "a colour already there is not added twice")
ok(P.added(l, "bogus") == l, "an unknown entry is not added")
ok(same(P.removed(l, "red"), { "blue" }) and #l == 2, "removed leaves the original list alone")

-- colours
ok(P.hex("#ff8800") == "#FF8800" and P.hex("ff8800") == nil and P.hex(5) == nil, "hex reads one form only")
ok(P.fromRgb({ 255, 136, 0 }) == "#FF8800", "rgb to hex")
local r, g, b = P.toRgb("#12ab34")
ok(r == 0x12 and g == 0xAB and b == 0x34, "hex to rgb")
ok(P.keyFor("#12AB34") == "ia_12ab34", "a custom colour's name in the reader")

-- the name a highlight gets
local custom = {}
ok(P.nameFor("red", custom) == "red" and next(custom) == nil, "the reader's own name goes as it is")
ok(P.nameFor("gray", nil) == "gray", "gray goes as it is")
ok(P.nameFor("#ff8800", custom) == "orange" and next(custom) == nil, "an exact colour the reader has by name uses that name")
ok(P.nameFor("#12AB34", custom) == "ia_12ab34" and custom.ia_12ab34.code == "#12AB34", "an own colour is kept as a custom colour")
ok(P.nameFor("#12AB34", custom) == "ia_12ab34", "and once")
ok(P.nameFor("#12AB34", nil) == nil, "a reader with no custom colours cannot keep one: nil, nothing raised")
ok(P.nameFor("bogus", custom) == nil and P.nameFor(nil, custom) == nil, "nothing for an unknown entry")
ok(P.hexOf("ia_12ab34", custom) == "#12AB34" and P.hexOf("red", custom) == "#FF3300", "the colour a name stands for")
custom.red = { code = "#AA0000" }
ok(P.hexOf("red", custom) == "#AA0000", "the person's own setting of a reader colour wins")
ok(P.hexOf("gray", custom) == nil and P.hexOf(nil, custom) == nil, "gray and nothing have no fixed colour")
ok(P.entryOf("ia_12ab34", custom) == "#12AB34" and P.entryOf("blue", custom) == "blue", "the entry a name belongs to")

-- Book:setHighlightColour against a stand-in reader
package.loaded["ui/event"] = package.loaded["ui/event"] or { new = function(_, n, ...) return { name = n, args = { ... } } end }
local Book = require("ink/reader/book")
local function reader(paging, withPdf)
    local item = { color = "yellow", note = "n" }
    local ui = { paging = paging and {} or nil, annotation = { annotations = { item } }, events = {}, log = {} }
    ui.highlight = { custom_colors = {} }
    if withPdf then
        function ui.highlight:writePdfAnnotation(what) ui.log[#ui.log + 1] = what end
    end
    ui.view = { reset = 0, resetHighlightBoxesCache = function(v) v.reset = v.reset + 1 end }
    function ui:handleEvent(e) self.events[#self.events + 1] = e.name end
    return setmetatable({ ui = ui }, { __index = Book }), item, ui
end

local book, item, ui = reader(false, false)
ok(book:setHighlightColour(item, "blue") and item.color == "blue", "a reflowing book's highlight is recoloured")
ok(ui.view.reset == 1 and ui.events[1] == "AnnotationsModified", "the reader is told, its boxes dropped")
ok(not book:setHighlightColour({}, "red"), "an item that is not the book's is refused")
ok(book:setHighlightColour(item, nil, true) and item.color == nil, "clear puts back a highlight with no colour")
ok(not book:setHighlightColour(item, nil), "no colour, no clear: refused")

book, item, ui = reader(true, true)
ok(book:setHighlightColour(item, "green"), "a PDF's highlight is recoloured")
ok(table.concat(ui.log, ",") == "delete,save,content", "its PDF annotation is written again, with its note")

-- a reader without the extras raises nothing
book, item, ui = reader(false, false)
ui.view.resetHighlightBoxesCache = nil
ui.handleEvent = nil
ok(book:setHighlightColour(item, "cyan") and item.color == "cyan", "an older reader (no cache reset, no events) still works")
ui.highlight.custom_colors = nil
ok(book:customColours() == nil, "no custom colours table is nil")
ok(not Book.setHighlightColour({ ui = {} }, item, "red"), "a book with no reader is refused")

-- labels: what each colour means (#81)
do
    local store2 = {}
    local get2 = function(k) return store2[k] end
    ok(P.label(get2, "yellow") == nil and not P.anyLabel(get2), "labels: none at first")
    store2[P.LABELS] = P.labelled(nil, "yellow", "  Look   this up ")
    ok(P.label(get2, "yellow") == "Look this up" and P.anyLabel(get2), "labels: kept, spaces tidied")
    store2[P.LABELS] = P.labelled(store2[P.LABELS], "#FF8800", string.rep("\195\169", 40))
    ok(#P.label(get2, "#FF8800") == 64, "labels: cut to 32 characters, not bytes")
    store2[P.LABELS] = P.labelled(store2[P.LABELS], "yellow", "   ")
    ok(P.label(get2, "yellow") == nil and P.label(get2, "#FF8800") ~= nil, "labels: an empty one taken off, the others kept")
    ok(P.labelled({ red = "x" }, "red", "") == nil, "labels: none left, nothing kept")
end

print(("hlpalette: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
