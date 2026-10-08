-- The pen case model (ink/penset.lua): each kind of pen remembers how it was
-- set, saved pens switch everything at once, the previous pen can be swapped
-- back, and it all survives a restart, including from 4.0's single setting.
--   luajit tests/penset.lua
package.path = "./?.lua;" .. package.path
local Penset = require("ink/penset")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function store()
    local data = {}
    return data, function(k) return data[k] end, function(k, v) data[k] = v end
end
local opts = { colour = true, pxmm = 11.8 }

-- ---- a new reader -----------------------------------------------------------
do
    local _d, get = store()
    local st = Penset.load(get, opts)
    ok(st.cur.style == "solid" and st.cur.width == 5, "new: a 0.4 mm fineliner in hand (" .. st.cur.width .. " px)")
    ok(#st.favs == 5 and st.favs[4].style == "highlighter", "new: five starting pens, a highlighter among them")
    local grey = Penset.new({ colour = false, pxmm = 11.8 })
    ok(#grey.favs == 4 and grey.favs[3].color[1] == 200, "new: on grey, no red pen and a light grey highlighter")
end

-- ---- each kind remembers how it was set ------------------------------------------
do
    local _d, get = store()
    local st = Penset.load(get, opts)
    Penset.set(st, "width", 9)
    Penset.choose(st, "highlighter")
    ok(st.cur.style == "highlighter" and st.cur.width == 59 and st.cur.color[2] == 235,
        "choose: the highlighter starts wide and yellow")
    Penset.set(st, "color", { 120, 220, 255 })
    Penset.choose(st, "solid")
    ok(st.cur.width == 9, "choose: back to the fineliner as it was left (9 px)")
    Penset.choose(st, "highlighter")
    ok(st.cur.color[1] == 120, "choose: and the highlighter keeps its blue")
    ok(st.prev.style == "solid", "choose: the fineliner is the previous pen")
    Penset.swap(st)
    ok(st.cur.style == "solid" and st.prev.style == "highlighter", "swap: back and forth between two pens")
end

-- ---- saved pens -------------------------------------------------------------------
do
    local _d, get = store()
    local st = Penset.load(get, opts)
    local n = #st.favs
    ok(Penset.addFav(st) == 1, "fav: the pen in hand is already saved (the first)")
    Penset.set(st, "width", 20)
    ok(Penset.addFav(st) == n + 1 and #st.favs == n + 1, "fav: a new one goes at the end")
    ok(Penset.moveFav(st, n + 1, -1) and st.favs[n].width == 20, "fav: moved left")
    ok(not Penset.moveFav(st, 1, -1), "fav: not past the start")
    Penset.use(st, st.favs[2])
    ok(Penset.same(st.cur, st.favs[2]), "fav: a tap takes it up")
    ok(Penset.removeFav(st, 1) and #st.favs == n, "fav: removed")
    for _i = 1, 10 do Penset.set(st, "width", 30 + _i); Penset.addFav(st) end
    ok(#st.favs == Penset.FAV_CAP, "fav: never more than " .. Penset.FAV_CAP)
end

-- ---- saved and loaded ----------------------------------------------------------------
do
    local _d, get, set = store()
    local st = Penset.load(get, opts)
    Penset.choose(st, "fountain")
    Penset.set(st, "width", 14)
    Penset.save(st, set)
    local back = Penset.load(get, opts)
    ok(back.cur.style == "fountain" and back.cur.width == 14, "save: the pen in hand comes back after a restart")
    ok(back.types.solid ~= nil and back.prev ~= nil, "save: and so do the kinds and the previous pen")
    -- a made brush that was deleted is dropped
    local gone = Penset.load(get, opts, function(s) return s ~= "fountain" end)
    ok(gone.cur.style == "solid", "save: a pen whose style is gone starts fresh")
end

-- ---- 4.0's single setting --------------------------------------------------------------
do
    local d, get = store()
    d.inkaway_pen_style = "pencil"
    local st = Penset.load(get, opts)
    ok(st.cur.style == "pencil", "migrate: 4.0's pencil is the pen in hand")
    d.inkaway_pen_style = "user:Dry"
    st = Penset.load(get, opts, function() return true end)
    ok(st.cur.style == "user:Dry", "migrate: a made brush too")
end

ok(Penset.mmText(5, 11.8) == "0.4 mm" and Penset.mmText(130, 11.8) == "11 mm", "mm: as a reader reads it")

print(("penset: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
