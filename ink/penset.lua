--[[
The pen case: the reader's saved pens, the pen in hand, the one before it, and
how each kind of pen was last set. A pen is { style, width (canvas px), alpha
(0-255), color {r,g,b}, nib (degrees, calligraphy only) }.

  * The pen in hand is usually one of the saved pens ("sel"): changing its size,
    opacity, colour or kind changes that saved pen, so there is nothing to save
    or replace.
  * "+" makes a new saved pen of a chosen kind and takes it up.
  * Choosing a kind from outside the pen case (the highlighter button, a
    gesture) takes up the first saved pen of that kind, or the kind as it was
    last set.
  * The pen before the current one is kept, so a gesture or a pen button can
    swap between two pens.
Everything is kept in KOReader's settings (inkaway_pens), so it survives closing
Ink Away and plugin updates. Plain Lua, so the headless tests drive it directly.
]]

local Penset = {}

local SETTING = "inkaway_pens"
Penset.FAV_CAP = 8

-- The kinds of pen, in the order the pen case shows them.
Penset.GROUPS = {
    { label = "Write", types = { "solid", "ballpoint", "fountain", "calligraphy", "pencil" } },
    { label = "Mark",  types = { "highlighter", "felttip" } },
    -- Acrylic and Stipple are no longer offered; strokes drawn with them still
    -- draw (their styles stay in ink/raster.lua)
    { label = "Paint", types = { "wash", "hatch", "smudge" } },
}
Penset.LABELS = {
    solid = "Fineliner", ballpoint = "Ballpoint", fountain = "Fountain", calligraphy = "Calligraphy",
    pencil = "Pencil", highlighter = "Highlighter", felttip = "Marker", wash = "Watercolor",
    acrylic = "Acrylic", hatch = "Hatch", stipple = "Stipple", smudge = "Smudge",
}

-- How each kind of pen starts: its width in mm, opacity, and colour (on a colour
-- screen; `grey` on a greyscale one, black when absent). Sized to read well on
-- e-ink, where a hairline looks faint.
Penset.DEFAULTS = {
    solid       = { mm = 0.6, alpha = 255, color = { 0, 0, 0 } },
    ballpoint   = { mm = 0.8, alpha = 255, color = { 25, 45, 130 }, grey = { 0, 0, 0 } },
    fountain    = { mm = 1.4, alpha = 255, color = { 0, 0, 0 } },
    calligraphy = { mm = 3.2, alpha = 255, color = { 0, 0, 0 }, nib = 45 },
    pencil      = { mm = 1.0, alpha = 255, color = { 40, 40, 40 } },
    highlighter = { mm = 6.0, alpha = 255, color = { 255, 235, 59 }, grey = { 200, 200, 200 } },
    felttip     = { mm = 3.0, alpha = 190, color = { 210, 40, 40 }, grey = { 70, 70, 70 } },
    wash        = { mm = 10.0, alpha = 160, color = { 40, 120, 220 }, grey = { 90, 90, 90 } },
    acrylic     = { mm = 1.4, alpha = 255, color = { 0, 0, 0 } },
    hatch       = { mm = 2.5, alpha = 255, color = { 0, 0, 0 } },
    stipple     = { mm = 2.0, alpha = 255, color = { 0, 0, 0 } },
    smudge      = { mm = 6.0, alpha = 255, color = { 0, 0, 0 } },
}

-- Kinds that mark over other ink: a black pen turned into one of these takes
-- the kind's own colour instead (a black highlighter would hide the text).
local MARKING = { highlighter = true, felttip = true, wash = true }

-- The widest each kind can be set, in canvas px (the size slider's end).
local MAX_PX = { highlighter = 160, wash = 200, smudge = 160, felttip = 120, calligraphy = 100 }
function Penset.maxWidth(style) return MAX_PX[style] or 60 end

local function copyColor(c) return c and { c[1], c[2], c[3] } or nil end
local function copyPen(p)
    return { style = p.style, width = p.width, alpha = p.alpha, color = copyColor(p.color), nib = p.nib }
end
Penset.copy = copyPen

-- The starting pen of a kind, for a screen with `pxmm` canvas pixels per mm.
function Penset.default(style, opts)
    opts = opts or {}
    local d = Penset.DEFAULTS[style] or Penset.DEFAULTS.solid
    local color = (not opts.colour and d.grey) or d.color
    local w = math.floor(d.mm * (opts.pxmm or 11.8) + 0.5)
    w = math.max(1, math.min(Penset.maxWidth(style), w))
    return { style = style, width = w, alpha = d.alpha, color = copyColor(color) or { 0, 0, 0 }, nib = d.nib }
end

-- Do two pens draw the same?
function Penset.same(a, b)
    if not (a and b) then return false end
    local ca, cb = a.color or { 0, 0, 0 }, b.color or { 0, 0, 0 }
    return a.style == b.style and a.width == b.width and a.alpha == b.alpha
        and ca[1] == cb[1] and ca[2] == cb[2] and ca[3] == cb[3] and (a.nib or 45) == (b.nib or 45)
end

local function pen(style, opts, color)
    local p = Penset.default(style, opts)
    if color and opts.colour then p.color = copyColor(color) end
    return p
end

-- The pens a new reader starts with: one of each everyday kind, each in its
-- own colour on a colour screen.
local function startingFavs(opts)
    return {
        pen("solid", opts), pen("ballpoint", opts), pen("fountain", opts),
        pen("pencil", opts), pen("felttip", opts), pen("highlighter", opts),
    }
end

-- The pens 4.0's first pen case started with (same kind in several colours,
-- thin): a case still exactly so was never chosen, and gets today's set.
local function firstFavs(opts)
    local function old(style, mm, color)
        local d = Penset.DEFAULTS[style]
        local c = (not opts.colour and d.grey) or color or d.color
        return { style = style, width = math.max(1, math.floor(mm * (opts.pxmm or 11.8) + 0.5)),
                 alpha = d.alpha, color = copyColor(c) }
    end
    local list = { old("solid", 0.4), old("ballpoint", 0.5, { 25, 45, 130 }) }
    if opts.colour then list[#list + 1] = old("solid", 0.4, { 210, 30, 40 }) end
    list[#list + 1] = old("highlighter", 5.0)
    list[#list + 1] = old("pencil", 0.6)
    return list
end

-- The index of the saved pen drawing like `p`, or nil.
local function indexOf(st, p)
    for i, f in ipairs(st.favs) do if Penset.same(f, p) then return i end end
    return nil
end

-- A fresh case, holding the first saved pen.
function Penset.new(opts)
    opts = opts or {}
    local favs = startingFavs(opts)
    local cur = copyPen(favs[1])
    return { cur = cur, prev = nil, sel = 1, types = { [cur.style] = copyPen(cur) }, favs = favs, opts = opts }
end

local function validPen(p, known)
    return type(p) == "table" and type(p.style) == "string" and type(p.width) == "number"
        and (not known or known(p.style))
end

-- The case from the settings, or a fresh one. `get(key)` reads a setting,
-- `known(style)` says whether a style exists (a deleted made brush does not).
-- Older versions kept only inkaway_pen_style: that becomes the pen in hand.
function Penset.load(get, opts, known)
    opts = opts or {}
    local saved = get(SETTING)
    local st
    if type(saved) == "table" and validPen(saved.cur, known) then
        st = { cur = copyPen(saved.cur), prev = validPen(saved.prev, known) and copyPen(saved.prev) or nil,
               types = {}, favs = {}, opts = opts }
        if type(saved.types) == "table" then
            for k, p in pairs(saved.types) do
                if validPen(p, known) then st.types[k] = copyPen(p) end
            end
        end
        if type(saved.favs) == "table" then
            for _i, p in ipairs(saved.favs) do
                if validPen(p, known) then st.favs[#st.favs + 1] = copyPen(p) end
            end
        end
        -- the first pen case's starting pens, never changed: today's instead
        local first = firstFavs(opts)
        local untouched = #st.favs == #first
        for i, p in ipairs(first) do untouched = untouched and Penset.same(p, st.favs[i]) end
        if untouched then
            st.favs = startingFavs(opts)
            if indexOf({ favs = first }, st.cur) then st.cur = copyPen(st.favs[1]) end
        end
        local sel = tonumber(saved.sel)
        if not (sel and st.favs[sel] and Penset.same(st.favs[sel], st.cur)) then sel = indexOf(st, st.cur) end
        st.sel = sel
    else
        st = Penset.new(opts)
        local old = get("inkaway_pen_style")
        if type(old) == "string" and (not known or known(old)) and old ~= "solid" then
            st.cur = Penset.default(Penset.DEFAULTS[old] and old or "solid", opts)
            st.cur.style = old
            st.types[old] = copyPen(st.cur)
            st.sel = indexOf(st, st.cur)
        end
    end
    return st
end

function Penset.save(st, set)
    local types = {}
    for k, p in pairs(st.types) do types[k] = copyPen(p) end
    local favs = {}
    for i, p in ipairs(st.favs) do favs[i] = copyPen(p) end
    set(SETTING, { cur = copyPen(st.cur), prev = st.prev and copyPen(st.prev) or nil, sel = st.sel,
                   types = types, favs = favs })
end

-- Make `p` the pen in hand (a switch: the one in hand becomes the previous one),
-- `sel` the saved pen it is, if one.
local function take(st, p, sel)
    if not Penset.same(st.cur, p) then st.prev = copyPen(st.cur) end
    st.cur = copyPen(p)
    st.sel = sel
    st.types[p.style] = copyPen(p)
    return st.cur
end

-- Take up saved pen i.
function Penset.select(st, i)
    local p = st.favs[i]
    if not p then return nil end
    return take(st, p, i)
end

-- Take up pen `p` (any pen: the one before, a kind as last set); it is the
-- saved pen it draws like, if there is one.
function Penset.use(st, p)
    if Penset.same(st.cur, p) then return st.cur end
    return take(st, p, indexOf(st, p))
end

-- Switch to a kind of pen from outside the pen case (the highlighter button, a
-- gesture): the first saved pen of that kind, else the kind as it was last set.
function Penset.choose(st, style)
    if st.cur.style == style then return st.cur end
    for i, f in ipairs(st.favs) do
        if f.style == style then return Penset.select(st, i) end
    end
    local p = copyPen(st.types[style] or Penset.default(style, st.opts))
    p.style = style
    return take(st, p, nil)
end

-- Keep the saved pen in hand in step with it.
local function sync(st)
    st.types[st.cur.style] = copyPen(st.cur)
    if st.sel and st.favs[st.sel] then st.favs[st.sel] = copyPen(st.cur) end
    return st.cur
end

-- Change the pen in hand: field is "width", "alpha", "color" or "nib". The saved
-- pen in hand changes with it.
function Penset.set(st, field, value)
    if field == "color" then value = copyColor(value) end
    st.cur[field] = value
    return sync(st)
end

-- Make the pen in hand another kind (from the pen case): it takes that kind's
-- size and opacity as last set and keeps its colour (a black pen made a
-- highlighter or marker takes that kind's colour). The saved pen in hand
-- changes with it.
function Penset.setKind(st, style)
    if st.cur.style == style then return st.cur end
    local p = copyPen(st.types[style] or Penset.default(style, st.opts))
    p.style = style
    local c = st.cur.color or { 0, 0, 0 }
    local dark = c[1] + c[2] + c[3] < 150
    if not (MARKING[style] and dark) and not MARKING[st.cur.style] then p.color = copyColor(c) end
    st.cur = p
    return sync(st)
end

-- A new saved pen of a kind, taken up: the pen in hand if it is that kind,
-- else the kind as it was last set. Returns its index, or nil when the case is
-- full.
function Penset.addNew(st, style)
    if #st.favs >= Penset.FAV_CAP then return nil end
    local p
    if st.cur.style == style then p = copyPen(st.cur)
    else
        p = copyPen(st.types[style] or Penset.default(style, st.opts))
        p.style = style
    end
    st.favs[#st.favs + 1] = p
    take(st, p, #st.favs)
    return #st.favs
end

-- A copy of saved pen i, put after it and taken up. Returns its index.
function Penset.duplicateFav(st, i)
    if not st.favs[i] or #st.favs >= Penset.FAV_CAP then return nil end
    table.insert(st.favs, i + 1, copyPen(st.favs[i]))
    if st.sel and st.sel > i then st.sel = st.sel + 1 end
    take(st, st.favs[i + 1], i + 1)
    return i + 1
end

-- Back to the pen before this one (a swap: this one becomes the previous).
function Penset.swap(st)
    if not st.prev then return nil end
    return take(st, st.prev, indexOf(st, st.prev))
end

function Penset.removeFav(st, i)
    if not st.favs[i] then return false end
    table.remove(st.favs, i)
    if st.sel == i then st.sel = nil
    elseif st.sel and st.sel > i then st.sel = st.sel - 1 end
    return true
end

-- Swap saved pen i with its neighbour (dir -1 left, 1 right).
function Penset.moveFav(st, i, dir)
    local j = i + dir
    if j < 1 or j > #st.favs or i < 1 or i > #st.favs then return false end
    st.favs[i], st.favs[j] = st.favs[j], st.favs[i]
    if st.sel == i then st.sel = j elseif st.sel == j then st.sel = i end
    return true
end

-- The width as a reader thinks of it: "0.4 mm".
function Penset.mmText(px, pxmm)
    local mm = px / (pxmm or 11.8)
    if mm < 10 then return string.format("%.1f mm", mm) end
    return string.format("%d mm", math.floor(mm + 0.5))
end

return Penset
