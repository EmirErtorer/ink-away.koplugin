--[[
The translation tool. Run it from the repo root with LuaJIT:

    luajit tools/l10n/lang.lua extract                 rewrite ink/l10n/ink-away.pot from the code
    luajit tools/l10n/lang.lua sync                    extract, then bring every language up to date
                                                       (a new message is added empty)
    luajit tools/l10n/lang.lua check                   list what is wrong; exit 1 if anything is
    luajit tools/l10n/lang.lua new <code>              start a language listed in tools/l10n/langs.lua
    luajit tools/l10n/lang.lua export <code> [all]     the messages still to translate, numbered
    luajit tools/l10n/lang.lua import <code> <file>    lines "N<TAB>first 5 characters<TAB>translation"

Messages are numbered in the order of the template. In export and import a line break is
written \n, a tab \t and a backslash \\. tests/l10n.lua runs the same checks, so a message
cannot ship before every language has it. Plain LuaJIT, nothing to install.
]]

package.path = "./?.lua;" .. package.path
local Check = require("tools/l10n/check")
local Extract = require("tools/l10n/extract")
local Langs = require("tools/l10n/langs")
local Po = require("tools/l10n/po")

local POT = "ink/l10n/ink-away.pot"

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function pathOf(lang) return "ink/l10n/" .. lang.code .. ".po" end

local function langNamed(code)
    for _i, l in ipairs(Langs) do if l.code == code then return l end end
    error("unknown language " .. tostring(code) .. ": list it in tools/l10n/langs.lua first")
end

-- A message on one line: line breaks, tabs and backslashes escaped.
local function escape(s)
    return (s:gsub("[\\\n\t]", { ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t" }))
end

local function unescape(s)
    return (s:gsub("\\(.)", { n = "\n", t = "\t", ["\\"] = "\\" }))
end

-- The first five characters of a message (not bytes), as the lines of an import start them.
local function head(s)
    local out, n = "", 0
    for ch in escape(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out, n = out .. ch, n + 1
        if n == 5 then break end
    end
    return out
end

-- The messages in template order.
local function sortedIds(msgs)
    local ids = {}
    for id in pairs(msgs) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- The translations in a language's file as id -> { str, fuzzy }.
local function load(lang)
    local have = {}
    for _i, e in ipairs(Po.parse(read(pathOf(lang)) or "")) do have[e.id] = e end
    return have
end

-- Write a language's file for the messages `msgs` with the translations in `have`.
local function save(lang, msgs, have)
    write(pathOf(lang), Extract.format(msgs, function(id) return have[id] and have[id].str or "" end, lang,
        function(id) return have[id] and have[id].fuzzy end))
end

local command, msgs = arg[1], Extract.messages()

if command == "extract" then
    write(POT, Extract.pot())
    print(("%s: %d messages"):format(POT, #sortedIds(msgs)))
elseif command == "sync" then
    write(POT, Extract.pot())
    for _i, lang in ipairs(Langs) do save(lang, msgs, load(lang)) end
    print(("%d messages; %d languages synced"):format(#sortedIds(msgs), #Langs))
elseif command == "check" then
    local total = 0
    for _i, lang in ipairs(Langs) do
        local text = read(pathOf(lang))
        local problems, done = Check.language(text or "", lang.code, msgs)
        if not text then problems = { "no file " .. pathOf(lang) } end
        print(("%-6s %d / %d translated"):format(lang.code, done, #sortedIds(msgs)))
        for _j, p in ipairs(problems) do print("  " .. lang.code .. ": " .. p) end
        total = total + #problems
    end
    if read(POT) ~= Extract.pot() then
        print(POT .. " is out of date: run  luajit tools/l10n/lang.lua sync")
        total = total + 1
    end
    print(("l10n: %d messages, %d problems"):format(#sortedIds(msgs), total))
    os.exit(total == 0 and 0 or 1)
elseif command == "new" then
    local lang = langNamed(arg[2])
    save(lang, msgs, {})
    print("started " .. pathOf(lang))
elseif command == "export" then
    local have = load(langNamed(arg[2]))
    for i, id in ipairs(sortedIds(msgs)) do
        local e = have[id]
        if arg[3] == "all" or not e or e.str == "" or e.fuzzy then print(i .. "\t" .. escape(id)) end
    end
elseif command == "import" then
    local lang = langNamed(arg[2])
    local have, ids = load(lang), sortedIds(msgs)
    local done, bad = 0, 0
    for row in (read(arg[3]) or ""):gmatch("[^\n]+") do
        local n, prefix, str = row:match("^(%d+)\t([^\t]*)\t(.*)$")
        local id = n and ids[tonumber(n)]
        if id and head(id) == prefix and str ~= "" then
            have[id] = { str = unescape(str), fuzzy = false }
            done = done + 1
        else
            bad = bad + 1
            print("no match: " .. row:sub(1, 60))
        end
    end
    save(lang, msgs, have)
    print(("imported %d (%d refused)"):format(done, bad))
else
    print("usage: luajit tools/l10n/lang.lua extract | sync | check | new <code> | export <code> | import <code> <file>")
    os.exit(2)
end
