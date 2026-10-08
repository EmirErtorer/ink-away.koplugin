--[[
The pen case: the pen in hand, the one before it, how each kind of pen was last
set, and the reader's saved pens. A pen is { style, width (canvas px), alpha
(0-255), color {r,g,b} }.

  * Choosing a kind of pen brings back how it was last set: the highlighter stays
    wide and yellow, the fineliner thin and black.
  * Saved pens ("Your pens") switch everything at once with one tap.
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
    { label = "Paint", types = { "wash", "acrylic", "hatch", "stipple", "smudge" } },
}
Penset.LABELS = {
    solid = "Fineliner", ballpoint = "Ballpoint", fountain = "Fountain", calligraphy = "Calligraphy",
    pencil = "Pencil", highlighter = "Highlighter", felttip = "Marker", wash = "Watercolor",
    acrylic = "Acrylic", hatch = "Hatch", stipple = "Stipple", smudge = "Smudge",
}

-- How each kind of pen starts: its width in mm, opacity, and colour (on a colour
-- screen; `grey` on a greyscale one, black when absent).
Penset.DEFAULTS = {
    solid       = { mm = 0.4, alpha = 255, color = { 0, 0, 0 } },
    ballpoint   = { mm = 0.5, alpha = 255, color = { 25, 45, 130 }, grey = { 0, 0, 0 } },
    fountain    = { mm = 0.8, alpha = 255, color = { 0, 0, 0 } },
    calligraphy = { mm = 2.4, alpha = 255, color = { 0, 0, 0 } },
    pencil      = { mm = 0.6, alpha = 255, color = { 40, 40, 40 } },
    highlighter = { mm = 5.0, alpha = 255, color = { 255, 235, 59 }, grey = { 200, 200, 200 } },
    felttip     = { mm = 2.5, alpha = 150, color = { 30, 90, 220 }, grey = { 70, 70, 70 } },
    wash        = { mm = 8.0, alpha = 160, color = { 40, 120, 220 }, grey = { 90, 90, 90 } },
    acrylic     = { mm = 1.4, alpha = 255, color = { 0, 0, 0 } },
    hatch       = { mm = 2.0, alpha = 255, color = { 0, 0, 0 } },
    stipple     = { mm = 2.0, alpha = 255, color = { 0, 0, 0 } },
    smudge      = { mm = 5.0, alpha = 255, color = { 0, 0, 0 } },
}

-- The widest each kind can be set, in canvas px (the size slider's end).
local MAX_PX = { highlighter = 160, wash = 200, smudge = 160, felttip = 120, calligraphy = 100 }
function Penset.maxWidth(style) return MAX_PX[style] or 60 end

local function copyColor(c) return c and { c[1], c[2], c[3] } or nil end
local function copyPen(p)
    return { style = p.style, width = p.width, alpha = p.alpha, color = copyColor(p.color) }
end
Penset.copy = copyPen

-- The starting pen of a kind, for a screen with `pxmm` canvas pixels per mm.
function Penset.default(style, opts)
    opts = opts or {}
    local d = Penset.DEFAULTS[style] or Penset.DEFAULTS.solid
    local color = (not opts.colour and d.grey) or d.color
    local w = math.floor(d.mm * (opts.pxmm or 11.8) + 0.5)
    w = math.max(1, math.min(Penset.maxWidth(style), w))
    return { style = style, width = w, alpha = d.alpha, color = copyColor(color) or { 0, 0, 0 } }
end

-- Do two pens draw the same?
function Penset.same(a, b)
    if not (a and b) then return false end
    local ca, cb = a.color or { 0, 0, 0 }, b.color or { 0, 0, 0 }
    return a.style == b.style and a.width == b.width and a.alpha == b.alpha
        and ca[1] == cb[1] and ca[2] == cb[2] and ca[3] == cb[3]
end

-- The pens a new reader starts with.
local function startingFavs(opts)
    local list = { Penset.default("solid", opts), Penset.default("ballpoint", opts) }
    if opts.colour then
        local red = Penset.default("solid", opts)
        red.color = { 210, 30, 40 }
        list[#list + 1] = red
    end
    list[#list + 1] = Penset.default("highlighter", opts)
    list[#list + 1] = Penset.default("pencil", opts)
    return list
end

-- A fresh case.
function Penset.new(opts)
    opts = opts or {}
    local cur = Penset.default("solid", opts)
    return { cur = cur, prev = nil, types = { solid = copyPen(cur) }, favs = startingFavs(opts), opts = opts }
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
    else
        st = Penset.new(opts)
        local old = get("inkaway_pen_style")
        if type(old) == "string" and (not known or known(old)) and old ~= "solid" then
            st.cur = Penset.default(Penset.DEFAULTS[old] and old or "solid", opts)
            st.cur.style = old
            st.types[old] = copyPen(st.cur)
        end
    end
    return st
end

function Penset.save(st, set)
    local types = {}
    for k, p in pairs(st.types) do types[k] = copyPen(p) end
    local favs = {}
    for i, p in ipairs(st.favs) do favs[i] = copyPen(p) end
    set(SETTING, { cur = copyPen(st.cur), prev = st.prev and copyPen(st.prev) or nil, types = types, favs = favs })
end

-- Take up pen `p` (a saved pen, the previous one): the one in hand becomes the
-- previous one, and its kind remembers how it is set.
function Penset.use(st, p)
    if Penset.same(st.cur, p) then return st.cur end
    st.prev = copyPen(st.cur)
    st.cur = copyPen(p)
    st.types[p.style] = copyPen(p)
    return st.cur
end

-- Switch to a kind of pen, set as it was last time (or as it starts).
function Penset.choose(st, style)
    if st.cur.style == style then return st.cur end
    local p = st.types[style] or Penset.default(style, st.opts)
    p = copyPen(p)
    p.style = style
    return Penset.use(st, p)
end

-- Change the pen in hand: field is "width", "alpha" or "color".
function Penset.set(st, field, value)
    if field == "color" then value = copyColor(value) end
    st.cur[field] = value
    st.types[st.cur.style] = copyPen(st.cur)
    return st.cur
end

-- Back to the pen before this one (a swap: this one becomes the previous).
function Penset.swap(st)
    if not st.prev then return nil end
    local p = st.prev
    st.prev = copyPen(st.cur)
    st.cur = copyPen(p)
    st.types[p.style] = copyPen(p)
    return st.cur
end

-- Save the pen in hand to Your pens. Returns its index, or nil when the case is
-- full; an identical saved pen is not added twice.
function Penset.addFav(st)
    for i, p in ipairs(st.favs) do if Penset.same(p, st.cur) then return i end end
    if #st.favs >= Penset.FAV_CAP then return nil end
    st.favs[#st.favs + 1] = copyPen(st.cur)
    return #st.favs
end

function Penset.removeFav(st, i)
    return table.remove(st.favs, i) ~= nil
end

-- Swap saved pen i with its neighbour (dir -1 left, 1 right).
function Penset.moveFav(st, i, dir)
    local j = i + dir
    if j < 1 or j > #st.favs or i < 1 or i > #st.favs then return false end
    st.favs[i], st.favs[j] = st.favs[j], st.favs[i]
    return true
end

-- Replace saved pen i with the pen in hand.
function Penset.replaceFav(st, i)
    if not st.favs[i] then return false end
    st.favs[i] = copyPen(st.cur)
    return true
end

-- The width as a reader thinks of it: "0.4 mm".
function Penset.mmText(px, pxmm)
    local mm = px / (pxmm or 11.8)
    if mm < 10 then return string.format("%.1f mm", mm) end
    return string.format("%d mm", math.floor(mm + 0.5))
end

return Penset
