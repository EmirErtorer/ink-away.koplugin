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

local MSGS = Extract.messages()

-- A message's placeholders as one comparable string. %1 and %2 may move in a translation
-- (a set); %s, %d and %f may not (string.format fills them in order); and a bare % that is
-- not %% would break string.format.
local function placeholderKey(s)
    local numbered, printf = {}, {}
    for _i, p in ipairs(Extract.placeholders(s)) do
        if p:match("^%%%d$") then numbered[#numbered + 1] = p else printf[#printf + 1] = p end
    end
    table.sort(numbered)
    return table.concat(numbered, " ") .. " | " .. table.concat(printf, " ") .. " | " .. Extract.lonePercents(s)
end

-- What is wrong with the text of a translation file, as a list of sentences: no language or
-- charset, a message the code no longer has, and a changed placeholder (T() or string.format
-- would print the wrong thing or fail).
local function translationProblems(text)
    local out = {}
    if not (text:find("Language: %a%a") and text:find("charset=UTF-8", 1, true)) then
        out[#out + 1] = "header: needs Language: and charset=UTF-8"
    end
    local have = L10n.parse(text)
    local leftover, changed = {}, {}
    for id, str in pairs(have) do
        if not MSGS[id] then leftover[#leftover + 1] = id
        elseif placeholderKey(id) ~= placeholderKey(str) then changed[#changed + 1] = id end
    end
    table.sort(leftover); table.sort(changed)
    if #leftover > 0 then out[#out + 1] = ("%d left over, not in the template, e.g. %q"):format(#leftover, leftover[1]) end
    if #changed > 0 then out[#out + 1] = ("%d with a different placeholder, e.g. %q"):format(#changed, changed[1]) end
    return out
end

-- How many messages a translation file leaves in English (missing, empty or fuzzy: the loader
-- skips those), and the first of them.
local function untranslated(text)
    local have, missing = L10n.parse(text), {}
    for id in pairs(MSGS) do if not have[id] then missing[#missing + 1] = id end end
    table.sort(missing)
    return #missing, missing[1]
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
    ok(Extract.lonePercents("5% of it") == 1 and Extract.lonePercents("100%% sure, %d%%") == 0
        and Extract.lonePercents("%1 and %.1f") == 0, "placeholders: a bare % is counted, %% and placeholders are not")
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

    local msgs = MSGS
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

-- ---- what a shipped translation must be --------------------------------------------------
-- (checked on made-up files first, so we know the checks can fail; then on ink/l10n/*.po)
do
    local ids = {}
    for id in pairs(MSGS) do ids[#ids + 1] = id end
    table.sort(ids)
    local function printfOf(id)
        local out = {}
        for _i, p in ipairs(Extract.placeholders(id)) do if not p:match("^%%%d$") then out[#out + 1] = p end end
        return out
    end
    local withPh, plain, twoPrintf, withPct
    for _i, id in ipairs(ids) do
        if not withPh and #Extract.placeholders(id) > 0 then withPh = id end
        if not plain and #Extract.placeholders(id) == 0 and #id > 3 then plain = id end
        local pf = printfOf(id)
        if not twoPrintf and #pf == 2 and pf[1] ~= pf[2] and not id:find("%%%d") then twoPrintf = id end
        if not withPct and id:find("%%%%") and #Extract.placeholders(id) > 0 then withPct = id end
    end
    local function make(fill)
        return (Extract.format(MSGS, fill):gsub('"Language: \\n"', '"Language: es\\n"'))
    end
    local function has(list, word)
        for _i, p in ipairs(list) do if p:find(word, 1, true) then return true end end
        return false
    end
    local function same(s) return s end
    local function only(id, text) return function(s) return s == id and text or s end end

    ok(twoPrintf and withPct, "po check: the template has messages to test with (two printf placeholders, a %%)")
    ok(#translationProblems(make(same)) == 0, "po check: a complete file passes")
    local partial = make(only(plain, ""))
    ok(#translationProblems(partial) == 0, "po check: a partial file passes")
    ok(untranslated(partial) == 1, "po check: an untranslated message is counted")
    ok(untranslated((make(same):gsub("\n(#: [^\n]+\n)", "\n%1#, fuzzy\n", 1))) == 1,
        "po check: a fuzzy message counts as untranslated")
    ok(has(translationProblems(make(only(withPh, "sin marcador"))), "placeholder"), "po check: a lost placeholder is found")
    local pf = printfOf(twoPrintf)
    ok(has(translationProblems(make(only(twoPrintf, pf[2] .. " " .. pf[1]))), "placeholder"),
        "po check: %s and %d swapped is found (string.format would fail)")
    ok(#translationProblems(make(only(twoPrintf, pf[1] .. " " .. pf[2]))) == 0,
        "po check: printf placeholders in their order pass")
    ok(has(translationProblems(make(only(withPct, (withPct:gsub("%%%%", "%%"))))), "placeholder"),
        "po check: a bare % where the code has %% is found (string.format would fail)")
    ok(#translationProblems(make(only("%1 and %2", "%2 y %1"))) == 0, "po check: %1 and %2 may be reordered")
    ok(has(translationProblems(make(same) .. '\nmsgid "Not in the template"\nmsgstr "x"\n'), "left over"),
        "po check: a message the code no longer has is found")
    ok(has(translationProblems((make(same):gsub('"Language: es\\n"\n', "", 1))), "header"),
        "po check: a file with no language is found")

    local langs = io.popen("ls ink/l10n/*.po 2>/dev/null")
    for path in langs:lines() do
        local f = assert(io.open(path, "rb"))
        local text = f:read("*a")
        f:close()
        local found = translationProblems(text)
        ok(#found == 0, path .. ": " .. table.concat(found, "; "):sub(1, 400))
        local n, first = untranslated(text)
        if n > 0 then
            print(("NOTE: %s leaves %d messages in English, e.g. %q"):format(path, n, first))
        end
    end
    langs:close()
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
