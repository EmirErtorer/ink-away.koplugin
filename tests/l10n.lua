-- Ink Away's own translations (ink/l10n.lua): the .po reader, finding the file for
-- KOReader's language, and falling back to KOReader's own translations.
--   luajit tests/l10n.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local L10n = require("ink/l10n")

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
