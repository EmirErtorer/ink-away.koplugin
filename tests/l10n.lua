-- Ink Away's own translations (ink/l10n.lua): the .po reader, finding the file for
-- KOReader's language, and falling back to KOReader's own translations.
--   luajit tests/l10n.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local L10n = require("ink/l10n")
local Extract = require("tools/l10n/extract")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- A throwaway folder for .po files.
local dir = io.popen("mktemp -d"):read("*l") .. "/"
local function write(name, text)
    local f = assert(io.open(dir .. name, "wb"))
    f:write(text)
    f:close()
end

-- A stand-in for KOReader's gettext: knows "Done", gives anything else back.
local function fakeGt(lang)
    local known = { Done = "KO:Hecho" }
    return setmetatable({ current_lang = lang }, { __call = function(_, s) return known[s] or s end })
end

-- ---- parse: plain, multi-line, escapes --------------------------------------------------
do
    local t = L10n.parse([[
msgid ""
msgstr ""
"Language: es\n"

msgid "a"
msgstr "b"

msgid "multi"
msgstr ""
"line one\n"
"line two"

msgid "esc"
msgstr "q\"uote \\ back\ttab"

msgid "k\n"
msgstr "newline key"

msgid "pct"
msgstr "100%% sure"
]])
    ok(t.a == "b", "parse: a plain entry")
    ok(t.multi == "line one\nline two", "parse: a string over several lines joins, \\n is a newline")
    ok(t.esc == 'q"uote \\ back\ttab', "parse: \\\" \\\\ \\t decode")
    ok(t["k\n"] == "newline key", "parse: a msgid is decoded too")
    ok(t.pct == "100%% sure", "parse: %% stays %%")
    ok(t[""] == nil, "parse: the header is not an entry")
end

-- ---- parse: skips ---------------------------------------------------------------------
do
    local t = L10n.parse([[
msgid "empty"
msgstr ""

#, fuzzy
msgid "fz"
msgstr "borroso"

#~ msgid "old"
#~ msgstr "viejo"

msgctxt "menu"
msgid "ctx"
msgstr "contexto"

msgid "kept"
msgstr "guardado"
]])
    ok(t.empty == nil, "skip: an empty msgstr")
    ok(t.fz == nil, "skip: a fuzzy entry")
    ok(t.old == nil, "skip: an obsolete entry")
    ok(t.ctx == nil, "skip: an entry with a context")
    ok(t.kept == "guardado", "skip: the entry after them is kept (no flag leaks on)")
end

-- ---- build: English ---------------------------------------------------------------------
for _i, lang in ipairs({ "C", "en_US", "en_GB" }) do
    local gt = fakeGt(lang)
    ok(rawequal(L10n.build(gt, dir), gt), "english: " .. lang .. " gives KOReader's own")
end
do
    local gt = fakeGt(nil)
    ok(rawequal(L10n.build(gt, dir), gt), "english: no language gives KOReader's own")
end

-- ---- build: translates ------------------------------------------------------------------
write("es.po", [[
msgid ""
msgstr ""
"Language: es\n"

msgid "Undo"
msgstr "Deshacer"
]])
do
    local _ = L10n.build(fakeGt("es"), dir)
    ok(_("Undo") == "Deshacer", "translates: a message in the file")
    ok(_("Done") == "KO:Hecho", "translates: a message only KOReader has keeps its translation")
    ok(_("My pen") == "My pen", "translates: an unknown message (a pen named by its owner) shows as typed")
end

-- ---- build: regional codes --------------------------------------------------------------
for _i, lang in ipairs({ "es_MX", "es_419", "es.utf8" }) do
    local _ = L10n.build(fakeGt(lang), dir)
    ok(_("Undo") == "Deshacer", "regional: " .. lang .. " finds es.po")
end
write("es_MX.po", 'msgid "Undo"\nmsgstr "Deshacer (MX)"\n')
ok(L10n.build(fakeGt("es_MX"), dir)("Undo") == "Deshacer (MX)", "regional: es_MX.po wins over es.po")
ok(L10n.build(fakeGt("es_419"), dir)("Undo") == "Deshacer", "regional: another region still uses es.po")

-- ---- build: bad files -------------------------------------------------------------------
write("fr.po", "")
write("de.po", "\0\1\2garbage\255\254 \"\"\" msgid msgid \\\n\n\nmsgstr \"")
for _i, lang in ipairs({ "pt", "fr", "de" }) do   -- no file, an empty one, random bytes
    local good, tr = pcall(L10n.build, fakeGt(lang), dir)
    ok(good, "bad file: " .. lang .. " raises nothing")
    ok(good and tr("Done") == "KO:Hecho" and tr("x") == "x", "bad file: " .. lang .. " behaves as KOReader's own")
end

-- ---- the module itself ------------------------------------------------------------------
ok(L10n("x") == "x", "module: under the English mock a message comes back as it is")
ok(type(L10n.parse) == "function" and type(L10n.build) == "function", "module: exposes parse and build")

-- ---- extract: the _() calls of a source ------------------------------------------------
do
    local got = Extract.calls([==[
local a = _("a")
local b = _([[b]])
local c = _("c" ..
    "d")
local d = _("e\n\u{201C}")
local e = foo_("x")
local f = T(_("y"), z)
-- _("commented")
local g = _(variable)
local h = _("half" .. x)
]==])
    ok(table.concat(got, "|") == "a|b|cd|e\n\u{201C}|y", "calls: found " .. table.concat(got, "|"))
end

-- ---- extract: capitalised strings of a data file ------------------------------------------
do
    local got = Extract.capitals([==[
local a = "Hello there"
local b = "lower"
-- "Commented"
local c = "Joined " .. "chain"
local d = "Frag " .. x .. " rest"
]==])
    ok(table.concat(got, "|") == "Hello there|Joined chain|Frag ", "capitals: found " .. table.concat(got, "|"))
end

-- ---- extract: placeholders ----------------------------------------------------------------
do
    local P = Extract.placeholders
    ok(table.concat(P("shown at %d%%"), ",") == "%d", "placeholders: %d beside a literal %%")
    ok(table.concat(P("%1 and %2"), ",") == "%1,%2", "placeholders: %1 %2")
    ok(table.concat(P("%.1f mm"), ",") == "%.1f", "placeholders: %.1f")
    ok(#P("100%% sure, 5% of it") == 0, "placeholders: none in a literal percent")
end

-- ---- extract: the .pot text ---------------------------------------------------------------
do
    local pot = Extract.format({
        ['say "hi"\\'] = { "b.lua", "a.lua" }, ["two\nlines"] = { "a.lua" },
        ["%1 of %d"] = { "a.lua" }, Zed = { "z.lua" }, Alpha = { "a.lua" } })
    ok(pot:find('msgid "say \\"hi\\"\\\\"', 1, true), "pot: quotes and backslashes are escaped")
    ok(pot:find('msgid ""\n"two\\n"\n"lines"', 1, true), "pot: a message with a newline is split after it")
    ok(pot:find('#, lua-format\nmsgid "%1 of %d"', 1, true), "pot: a message with placeholders is flagged")
    ok(pot:find('#: a.lua\n#: b.lua\nmsgid "say', 1, true), "pot: references are sorted, one per line")
    ok(pot:find("Alpha", 1, true) < pot:find("Zed", 1, true), "pot: sorted by message")
    ok(pot:find("charset=UTF-8", 1, true) and pot:find('msgid ""\nmsgstr ""\n"Project-Id-Version', 1, true), "pot: a header")
end

-- ---- the committed template ---------------------------------------------------------------
do
    local f = io.open("ink/l10n/ink-away.pot", "rb")
    local committed = f and f:read("*a")
    if f then f:close() end
    ok(committed == Extract.pot(), "template: ink/l10n/ink-away.pot is current (run: luajit tools/l10n/extract.lua)")

    local msgs = Extract.messages()
    local n = 0
    for _id in pairs(msgs) do n = n + 1 end
    ok(n > 700, "template: holds the plugin's messages (" .. n .. ")")
    ok(next(L10n.parse(Extract.format(msgs))) == nil, "template: untranslated, it parses to nothing")
    local back, lost = L10n.parse(Extract.format(msgs, function(s) return s end)), nil
    for id in pairs(msgs) do if back[id] ~= id then lost = lost or id end end
    ok(lost == nil, "template: every message survives writing and reading (first lost: " .. tostring(lost) .. ")")

    -- the text the views translate through a variable is all in it
    local missing = {}
    local function need(s, where)
        if type(s) == "string" and s ~= "" and not msgs[s] then missing[#missing + 1] = where .. ": " .. s end
    end
    local Guide, Actions = require("ink/guide"), require("ink/actions")
    local Penset, Brushes = require("ink/penset"), require("ink/brushes")
    local PenTest, Welcome = require("ink/pentest"), require("ink/welcome")
    for _i, t in ipairs(Guide.TOPICS) do
        need(t.title, "guide"); need(t.line, "guide")
        for _j, c in ipairs(t.cards) do need(c.title, "guide card"); need(c.text, "guide card") end
    end
    for _i, a in ipairs(Actions.LIST) do need(a.label, "action") end
    for _i, t in ipairs(Actions.TRIGGERS) do need(t.label, "trigger") end
    for _i, note in ipairs(Actions.notes({ two_swipe_left = "next_page" }, "two_swipe_left")) do need(note, "note") end
    for _i, note in ipairs(Actions.notes({ two_tap = "redo", two_double_tap = "undo" }, "two_tap")) do need(note, "note") end
    for _i, g in ipairs(Penset.GROUPS) do need(g.label, "pen group") end
    for _style, label in pairs(Penset.LABELS) do need(label, "pen") end
    for _i, f in ipairs(Brushes.FIELDS) do need(f.label, "brush field") end
    need(PenTest.NO_PEN_HINT, "pen test")
    need(PenTest.androidTip({ android = true, boox = true }), "boox tip")
    need(PenTest.androidTip({ android = true }), "android tip")
    for _i, f in ipairs(Welcome.FEATURES) do need(f.title, "welcome"); need(f.text, "welcome") end
    for _k, g in pairs(Welcome.GESTURES) do need(g.text, "welcome gesture") end
    ok(#missing == 0, "template: holds the data modules' text (" .. #missing .. " missing, first: " .. tostring(missing[1]) .. ")")
end

-- ---- every file translates through the loader ---------------------------------------------
do
    local direct = {}
    for f in io.popen([[grep -rl --include='*.lua' 'require("gettext")' ink main.lua]]):lines() do
        direct[#direct + 1] = f
    end
    ok(#direct == 1 and direct[1] == "ink/l10n.lua",
        "call sites: only the loader requires gettext itself (found: " .. table.concat(direct, ", ") .. ")")
end

os.execute("rm -rf '" .. dir .. "'")
print(("l10n: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
