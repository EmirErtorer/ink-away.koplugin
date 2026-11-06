--[[
Room in a reflowing book: space the text moves out of, so stickers, pictures and
notes have somewhere to go. Nothing in the book's file changes. Ink Away adds a
few style rules to the book, next to KOReader's own style tweaks, and the book is
laid out again with the space in it.

  * a band across the page: empty space before a paragraph
    (its padding-top), { kind = "band", xp = <paragraph>, h = <px> };
  * space at a side: the paragraphs it covers are narrower on that side
    (their padding-left or padding-right), { kind = "side", side = "left" |
    "right", xps = { <paragraph>, ... }, w = <px> }.

Every room also has an id and xp (its first paragraph). Sizes are in screen pixels
and stay the same whatever the font: the rules are written in the book's own CSS
pixels, which KOReader's "Zoom (dpi)" setting scales (Rooms.css takes the scale).

Padding is the only thing used, as the prototype showed: a margin at the top of a
page is dropped, and a box or float added before a paragraph changes the book's
element tree, so KOReader asks to reload the whole book. Padding also works in every
render mode (legacy, flat, book, web), keeps its size at any font, and a band that
does not fit at the foot of a page moves whole to the next one.

crengine matches nothing above a book's DocFragment (the element KOReader puts
around each file of an EPUB), so a paragraph's rule names the path from there:
DocFragment:nth-of-type(9) > body:nth-of-type(1) > p:nth-of-type(10). The
xpointer gives that path already: p[10] is the tenth <p> among its parent's <p>s,
which is what :nth-of-type counts. This file is plain Lua; the book's side is in
ink/reader/book.lua.
]]

local Rooms = {}

-- Size limits, as fractions of the page's text area.
Rooms.MIN_H, Rooms.MAX_H = 0.04, 0.85   -- a band's height
Rooms.MIN_W, Rooms.MAX_W = 0.15, 0.6    -- a side room's width
Rooms.EDGE = 0.15                       -- a box this close to a side becomes side space
Rooms.WIDE = 0.6                        -- a box at least this wide becomes a band

-- Elements inside a paragraph: a room is made around the paragraph holding them.
local INLINE = {}
for w in ([[a abbr b bdi bdo big br cite code del dfn em font i img ins kbd mark nobr
    q rb rp rt rtc ruby s samp small span strike strong sub sup time tt u var wbr]]):gmatch("%S+") do
    INLINE[w] = true
end
-- Elements that hold a whole file or the book: never a room's paragraph.
local OUTER = { DocFragment = true, body = true, html = true, FictionBook = true }

-- The steps of an xpointer's element path: { { name = "p", idx = 10 }, ... }
-- (idx nil when the xpointer names no index: the only, or first, of its name).
function Rooms.steps(xp)
    if type(xp) ~= "string" or xp:sub(1, 1) ~= "/" then return nil end
    local path = xp:gsub("/text%(%).*$", ""):gsub("%.%d+$", "")
    local out = {}
    for seg in path:gmatch("/([^/]+)") do
        local name, idx = seg:match("^([^%[]+)%[(%d+)%]$")
        if name then out[#out + 1] = { name = name, idx = tonumber(idx) }
        elseif seg:match("^[%w_:%-]+$") then out[#out + 1] = { name = seg }
        else return nil end
    end
    return #out > 0 and out or nil
end

local function join(steps, n)
    local o = {}
    for i = 1, n or #steps do
        local e = steps[i]
        o[i] = "/" .. e.name .. (e.idx and ("[" .. e.idx .. "]") or "")
    end
    return table.concat(o)
end

-- The paragraph (block element) holding the text at `xp`, as an element
-- xpointer, or nil when the text sits right in the book's body.
function Rooms.blockOf(xp)
    local s = Rooms.steps(xp)
    if not s then return nil end
    local n = #s
    while n > 0 and INLINE[s[n].name:lower()] do n = n - 1 end
    if n == 0 or OUTER[s[n].name] then return nil end
    return join(s, n)
end

-- The CSS selector for one paragraph (an element xpointer), or nil.
function Rooms.selector(elem_xp)
    local s = Rooms.steps(elem_xp)
    if not s then return nil end
    local first
    for i, e in ipairs(s) do if e.name == "DocFragment" then first = i; break end end
    -- (a book without DocFragment, FB2 or a plain HTML file: from under its root)
    first = first or 2
    if first > #s then return nil end
    local o = {}
    for i = first, #s do
        local e = s[i]
        if not e.name:match("^[%a_][%w_%-]*$") then return nil end
        o[#o + 1] = e.name .. ":nth-of-type(" .. (e.idx or 1) .. ")"
    end
    return table.concat(o, " > ")
end

-- A new room's id.
local seq = 0
function Rooms.newId(now)
    seq = seq + 1
    return string.format("r%d%03d", now or os.time(), seq % 1000)
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(v) return math.floor(v + 0.5) end

-- The style rules for `rooms`. `scale` is CSS pixels per screen pixel (96 / the
-- render dpi; 1 when KOReader does not scale). One rule per paragraph, so two
-- rooms on one paragraph (a band and side space) add up.
function Rooms.css(rooms, scale)
    scale = scale or 1
    local by, order = {}, {}
    local function prop(xp, name, px)
        local sel = Rooms.selector(xp)
        if not sel then return end
        local r = by[sel]
        if not r then r = {}; by[sel] = r; order[#order + 1] = sel end
        r[name] = math.max(r[name] or 0, px)
    end
    for _i, room in ipairs(rooms or {}) do
        if room.kind == "band" and room.xp and room.h then
            prop(room.xp, "padding-top", room.h)
        elseif room.kind == "side" and room.w then
            local name = room.side == "left" and "padding-left" or "padding-right"
            for _j, xp in ipairs(room.xps or { room.xp }) do prop(xp, name, room.w) end
        end
    end
    local out = {}
    for _i, sel in ipairs(order) do
        local parts = {}
        for _j, name in ipairs({ "padding-top", "padding-left", "padding-right" }) do
            local px = by[sel][name]
            if px then parts[#parts + 1] = string.format("%s: %dpx !important;", name, math.max(1, round(px * scale))) end
        end
        out[#out + 1] = sel .. " { " .. table.concat(parts, " ") .. " }"
    end
    return table.concat(out, "\n")
end

-- The paragraphs on a page, from its words in reading order (each
-- { xp, y, h }, y the top of its line on the screen): { { xp = <paragraph>,
-- y0, y1, starts = <its first line is on this page> }, ... }. The first one may
-- have begun on the page before: `starts_here(paragraph, first_word_xp)` says.
function Rooms.blocksFromWords(words, starts_here)
    local out, last = {}, nil
    for _i, w in ipairs(words) do
        local b = Rooms.blockOf(w.xp)
        if b then
            if not (last and last.xp == b) then
                last = { xp = b, y0 = w.y, y1 = w.y + (w.h or 0), starts = true }
                if #out == 0 and starts_here then last.starts = starts_here(b, w.xp) and true or false end
                out[#out + 1] = last
            else
                last.y1 = math.max(last.y1, w.y + (w.h or 0))
            end
        end
    end
    return out
end

-- What a box drawn on the page (`rect`, screen pixels) makes: a band before the
-- paragraph break nearest its top, or, for a box near a side and not too wide,
-- space at that side beside the paragraphs it covers. `blocks` are the page's
-- paragraphs (Rooms.blocksFromWords), `area` its text area { x0, y0, x1, y1 }.
-- Returns the room (without an id) and the box it will roughly take now, or nil
-- and why ("no_break", "no_text").
function Rooms.plan(rect, blocks, area)
    local cw, ch = area.x1 - area.x0, area.y1 - area.y0
    if cw <= 0 or ch <= 0 or not blocks or #blocks == 0 then return nil, "no_text" end
    local edge = Rooms.EDGE * cw
    local near_left = rect.x <= area.x0 + edge
    local near_right = rect.x + rect.w >= area.x1 - edge
    local band = rect.w >= Rooms.WIDE * cw or near_left == near_right
    if band then
        local best, bd
        for _i, b in ipairs(blocks) do
            if b.starts then
                local d = math.abs(b.y0 - rect.y)
                if not bd or d < bd then best, bd = b, d end
            end
        end
        if not best then return nil, "no_break" end
        local h = round(clamp(rect.h, Rooms.MIN_H * ch, Rooms.MAX_H * ch))
        return { kind = "band", xp = best.xp, h = h },
            { x = area.x0, y = best.y0, w = cw, h = h }
    end
    local side = near_left and "left" or "right"
    local w = side == "left" and (rect.x + rect.w - area.x0) or (area.x1 - rect.x)
    w = round(clamp(w, Rooms.MIN_W * cw, Rooms.MAX_W * cw))
    local xps, y0, y1 = {}, nil, nil
    for _i, b in ipairs(blocks) do
        if b.y1 > rect.y and b.y0 < rect.y + rect.h then
            xps[#xps + 1] = b.xp
            y0 = y0 and math.min(y0, b.y0) or b.y0
            y1 = y1 and math.max(y1, b.y1) or b.y1
        end
    end
    if #xps == 0 then return nil, "no_text" end
    return { kind = "side", side = side, w = w, xp = xps[1], xps = xps },
        { x = side == "left" and area.x0 or (area.x1 - w), y = y0, w = w, h = y1 - y0 }
end

-- A copy of a room (the same id), safe to change.
function Rooms.copy(room)
    local c = {}
    for k, v in pairs(room) do c[k] = v end
    if room.xps then
        c.xps = {}
        for i, x in ipairs(room.xps) do c.xps[i] = x end
    end
    return c
end

-- Two lists of rooms in one: every room of `a`, then those only `b` has (by id),
-- for the cloud sync and for ink brought together from two folders.
function Rooms.merge(a, b)
    local out, seen = {}, {}
    for _i, r in ipairs(a or {}) do
        if type(r) == "table" and r.id and not seen[r.id] then seen[r.id] = true; out[#out + 1] = r end
    end
    for _i, r in ipairs(b or {}) do
        if type(r) == "table" and r.id and not seen[r.id] then seen[r.id] = true; out[#out + 1] = r end
    end
    return out
end

-- Is it a room this version understands?
function Rooms.valid(r)
    if type(r) ~= "table" or type(r.id) ~= "string" or type(r.xp) ~= "string" then return false end
    if r.kind == "band" then return type(r.h) == "number" and r.h > 0 end
    if r.kind == "side" then
        return type(r.w) == "number" and r.w > 0 and (r.side == "left" or r.side == "right")
            and (r.xps == nil or type(r.xps) == "table")
    end
    return false
end

return Rooms
