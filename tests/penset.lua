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
    local kinds = {}
    for i, p in ipairs(st.favs) do kinds[i] = p.style end
    ok(table.concat(kinds, ",") == "solid,ballpoint,pencil,calligraphy,highlighter,wash,smudge",
        "new: the starting pens (" .. table.concat(kinds, ",") .. ")")
    ok(st.sel == 1 and st.cur.style == "solid" and st.cur.width == 21, "new: the 1.8 mm fineliner in hand (" .. st.cur.width .. " px)")
    ok(st.favs[2].width == 15 and st.favs[3].width == 24 and st.favs[4].width == 31 and st.favs[5].width == 71,
        "new: ballpoint 1.3 mm, pencil 2 mm, calligraphy 2.6 mm, highlighter 6 mm")
    ok(st.favs[2].color[3] == 130 and st.favs[4].nib == 45, "new: a dark blue ballpoint, a 45 degree nib")
    local grey = Penset.new({ colour = false, pxmm = 11.8 })
    ok(#grey.favs == 7 and grey.favs[5].color[1] == 200 and grey.favs[2].color[3] == 0,
        "new: on grey a light grey highlighter and a black ballpoint")
end

-- ---- the saved pen in hand is edited directly ------------------------------------
do
    local _d, get = store()
    local st = Penset.load(get, opts)
    Penset.select(st, 2)
    Penset.set(st, "width", 12)
    ok(st.favs[2].width == 12 and st.sel == 2, "edit: a change to the pen in hand changes its saved pen")
    Penset.set(st, "color", { 0, 120, 0 })
    Penset.setKind(st, "fountain")
    ok(st.favs[2].style == "fountain" and st.favs[2].color[2] == 120, "edit: another kind, keeping its colour")
    Penset.select(st, 1)
    Penset.setKind(st, "highlighter")
    ok(st.favs[1].style == "highlighter" and st.favs[1].color[2] == 235, "edit: a black pen made a highlighter turns yellow")
end

-- ---- + makes a new saved pen of a kind ----------------------------------------------
do
    local _d, get = store()
    local st = Penset.load(get, opts)
    local n = #st.favs
    ok(Penset.addNew(st, "calligraphy") == n + 1 and st.sel == n + 1 and st.cur.style == "calligraphy",
        "new pen: added at the end and taken up")
    Penset.set(st, "width", 30)
    ok(st.favs[n + 1].width == 30 and st.favs[1].style == "solid", "new pen: edited on its own")
    ok(Penset.addNew(st, "calligraphy") == n + 2 and st.favs[n + 2].width == 30,
        "new pen: of the kind in hand, a copy of it")
    local fresh = Penset.load(function() end, opts)
    ok(Penset.duplicateFav(fresh, 1) == 2 and fresh.sel == 2 and #fresh.favs == n + 1
        and Penset.same(fresh.favs[1], fresh.favs[2]), "duplicate: a copy after it, taken up")
    for _i = 1, Penset.FAV_CAP do Penset.addNew(st, "solid") end
    ok(#st.favs == Penset.FAV_CAP and Penset.addNew(st, "solid") == nil, "new pen: never more than " .. Penset.FAV_CAP)
end

-- ---- choosing a kind from outside, swapping, moving and removing ---------------------
do
    local _d, get = store()
    local st = Penset.load(get, opts)
    Penset.choose(st, "highlighter")
    ok(st.sel == 5 and st.cur.style == "highlighter", "choose: the saved highlighter is taken up")
    Penset.choose(st, "felttip")
    ok(st.sel == nil and st.cur.style == "felttip", "choose: a kind with no saved pen, as last set, unsaved")
    Penset.set(st, "width", 50)
    ok(st.favs[5].style == "highlighter", "choose: an unsaved pen changes no saved one")
    Penset.swap(st)
    ok(st.cur.style == "highlighter" and st.sel == 5, "swap: back to the saved highlighter")
    ok(Penset.moveFav(st, 5, -1) and st.sel == 4, "move: the pen in hand moves with it")
    ok(Penset.removeFav(st, 1) and st.sel == 3, "remove: one before it shifts it")
    ok(Penset.removeFav(st, 3) and st.sel == nil and st.cur.style == "highlighter", "remove: the pen in hand stays, unsaved")
    ok(Penset.use(st, st.favs[1]) and st.sel == 1, "use: a pen drawing like a saved one is that one")
end

-- ---- saved and loaded ----------------------------------------------------------------
do
    local _d, get, set = store()
    local st = Penset.load(get, opts)
    Penset.select(st, 3)
    Penset.set(st, "width", 14)
    Penset.save(st, set)
    local back = Penset.load(get, opts)
    ok(back.cur.style == "pencil" and back.cur.width == 14 and back.sel == 3, "save: the pen in hand and its slot come back")
    ok(back.types.pencil ~= nil and back.prev ~= nil, "save: and so do the kinds and the previous pen")
    local gone = Penset.load(get, opts, function(s) return s ~= "pencil" end)
    ok(gone.cur.style == "solid", "save: a pen whose style is gone starts fresh")
end

-- ---- a case saved by a 4.0 test build starts once on today's pens ----------------------
do
    local d, get, set = store()
    local px = function(mm) return math.floor(mm * 11.8 + 0.5) end
    local function p(style, mm, color, alpha) return { style = style, width = px(mm), alpha = alpha or 255, color = color } end
    -- a test build's case, changed while testing (no version)
    d.inkaway_pens = {
        cur = p("pencil", 1.5, { 40, 40, 40 }), sel = 4, prev = p("solid", 0.6, { 0, 0, 0 }),
        types = { pencil = p("pencil", 1.5, { 40, 40, 40 }) },
        favs = { p("solid", 0.6, { 0, 0, 0 }), p("ballpoint", 0.8, { 25, 45, 130 }), p("fountain", 1.4, { 0, 0, 0 }),
                 p("pencil", 1.5, { 40, 40, 40 }), p("felttip", 3.0, { 210, 40, 40 }, 190) },
    }
    d.inkaway_pen_style = "fountain"
    local st = Penset.load(get, opts)
    local kinds = {}
    for i, f in ipairs(st.favs) do kinds[i] = f.style end
    ok(table.concat(kinds, ",") == "solid,ballpoint,pencil,calligraphy,highlighter,wash,smudge",
        "test build: today's seven pens (" .. table.concat(kinds, ",") .. ")")
    ok(st.sel == 1 and st.cur.style == "solid" and st.cur.width == px(1.8) and st.prev == nil,
        "test build: the 1.8 mm fineliner in hand, nothing older kept")
    Penset.save(st, set)
    ok(d.inkaway_pens.version == Penset.VERSION, "test build: saved with the version")
    -- once saved, the reader's own changes stay
    Penset.select(st, 3)
    Penset.set(st, "width", px(1.5))
    Penset.save(st, set)
    st = Penset.load(get, opts)
    ok(#st.favs == 7 and st.favs[3].width == px(1.5) and st.sel == 3, "test build: only once; changes after it stay")
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
