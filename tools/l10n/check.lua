--[[
What a translation file must be before it ships: every message of the code translated
(none missing, empty or fuzzy), nothing the code no longer says, the same placeholders,
the same names, the same capitals and the same edges as the English. luajit
tools/l10n/lang.lua check lists the problems; tests/l10n.lua fails on any, so a new
message cannot ship before every language has it. Plain Lua.
]]

local Extract = require("tools/l10n/extract")
local Po = require("tools/l10n/po")
local TextCase = require("ink/textcase")

local Check = {}

-- Names that are never translated: a message that has one keeps it, as written.
Check.BRANDS = { "Ink Away", "KOReader", "Wi-Fi", "Boox", "Android", "Bookshelf", "GitHub", "PDF", "PNG", "QR", "OCR" }

-- A message's placeholders as one comparable string. %1 and %2 may move in a translation
-- (a set); %s, %d and %f may not (string.format fills them in order); and a bare % that is
-- not %% would break string.format.
function Check.placeholderKey(s)
    local numbered, printf = {}, {}
    for _i, p in ipairs(Extract.placeholders(s)) do
        if p:match("^%%%d$") then numbered[#numbered + 1] = p else printf[#printf + 1] = p end
    end
    table.sort(numbered)
    return table.concat(numbered, " ") .. " | " .. table.concat(printf, " ") .. " | " .. Extract.lonePercents(s)
end

-- Is the English all capitals (three capitals and no small letter, placeholders aside)?
local function shouting(s)
    local plain = s:gsub("%%[%.%d]*[%a%%]", "")
    return plain:find("%u%u%u") ~= nil and not plain:find("%l")
end

local function count(s, pattern)
    return select(2, s:gsub(pattern, ""))
end

-- The problems of a translation file's text for language `code`, as a list of
-- sentences, and how many messages it translates. `msgs` is Extract.messages().
function Check.language(text, code, msgs)
    local entries, header = Po.parse(text)
    local out, found = {}, {}
    local function bad(msg) out[#out + 1] = msg end
    if Po.field(header, "Language") ~= code then bad("header: Language: must be " .. code) end
    if not (Po.field(header, "Content-Type") or ""):find("charset=UTF-8", 1, true) then bad("header: needs charset=UTF-8") end

    local have = {}
    for _i, e in ipairs(entries) do have[e.id] = e end
    local ids = {}
    for id in pairs(msgs) do ids[#ids + 1] = id end
    table.sort(ids)

    local missing, fuzzy, done = {}, {}, 0
    for _i, id in ipairs(ids) do
        local e = have[id]
        if not e or e.str == "" then
            missing[#missing + 1] = id
        elseif e.fuzzy then
            fuzzy[#fuzzy + 1] = id
        else
            done = done + 1
            local str = e.str
            local function problem(what) bad(("%s in %q: %q"):format(what, id:sub(1, 60), str:sub(1, 60))) end
            if Check.placeholderKey(id) ~= Check.placeholderKey(str) then problem("placeholders differ") end
            if str:find("%%%d%$") then problem("positional placeholder") end
            if count(id, "\n") ~= count(str, "\n") then problem("line breaks differ") end
            if (id:find("^%s") ~= nil) ~= (str:find("^%s") ~= nil) or (id:find("%s$") ~= nil) ~= (str:find("%s$") ~= nil) then
                problem("leading or trailing space differs")
            end
            for _j, brand in ipairs(Check.BRANDS) do
                if id:lower():find(brand:lower(), 1, true) and not str:lower():find(brand:lower(), 1, true)
                    and not (brand == "Wi-Fi" and code == "de" and str:lower():find("wlan", 1, true)) then
                    problem("the name " .. brand .. " must stay")
                end
            end
            if count(str, "Ink Away") < count(id, "Ink Away") then problem("Ink Away must stay exactly as written") end
            if shouting(id) and not TextCase.isUpper((str:gsub("%%[%.%d]*[%a%%]", "")), code) then
                problem("capitals expected")
            end
        end
        found[id] = true
    end
    local leftover = {}
    for _i, e in ipairs(entries) do if not found[e.id] then leftover[#leftover + 1] = e.id end end
    if #missing > 0 then bad(("%d of %d messages not translated, e.g. %q"):format(#missing, #ids, missing[1])) end
    if #fuzzy > 0 then bad(("%d fuzzy messages need a look, e.g. %q"):format(#fuzzy, fuzzy[1])) end
    if #leftover > 0 then bad(("%d left over, not in the template, e.g. %q"):format(#leftover, leftover[1])) end
    return out, done
end

return Check
