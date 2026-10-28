--[[
Builds ink/l10n/ink-away.pot, the list of every message Ink Away shows: the template
each translation starts from. Run it from the repo root after adding or changing text:

    luajit tools/l10n/extract.lua

tests/l10n.lua fails while the file is behind the code. Plain LuaJIT, nothing to install.
]]

local Extract = {}

-- Files whose text reaches _() through a variable (the views call _(row.title) and
-- the like), so a scan for _("...") cannot see it: every string in them that starts
-- with a capital (or a "+") is taken as a message, except the ones in SKIP.
local DATA = {
    ["ink/guide.lua"] = true, ["ink/welcome.lua"] = true, ["ink/actions.lua"] = true,
    ["ink/penset.lua"] = true, ["ink/brushes.lua"] = true,
}
-- Capitalised strings in those files that no screen shows (Guide.WHEN's descriptions).
local SKIP = { ["KOReader can hand the pen to Ink Away"] = true, Android = true }

local ESCAPES = { ["\\"] = "\\\\", ['"'] = '\\"', ["\t"] = "\\t", ["\r"] = "\\r" }

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- The string literals of Lua source `src` as { value, s, e } (their text and where
-- they sit), leaving comments out.
local function literals(src)
    local out, pos, n = {}, 1, #src
    local function add(s, e)
        local chunk = loadstring("return " .. src:sub(s, e))
        local ok, value = pcall(chunk or error)
        if ok and type(value) == "string" then out[#out + 1] = { value = value, s = s, e = e } end
    end
    while true do
        pos = src:find("[%-\"'%[]", pos)
        if not pos then break end
        local c = src:sub(pos, pos)
        if c == "-" then
            if src:sub(pos, pos + 1) ~= "--" then
                pos = pos + 1
            else
                local eq = src:match("^%-%-%[(=*)%[", pos)
                if eq then
                    local _s, e = src:find("]" .. eq .. "]", pos, true)
                    pos = (e or n) + 1
                else
                    pos = (src:find("\n", pos, true) or n) + 1
                end
            end
        elseif c == "[" then
            local eq = src:match("^%[(=*)%[", pos)
            if not eq then
                pos = pos + 1
            else
                local _s, e = src:find("]" .. eq .. "]", pos, true)
                add(pos, e or n)
                pos = (e or n) + 1
            end
        else
            local e = pos + 1
            while e <= n do
                local ch = src:sub(e, e)
                if ch == "\\" then e = e + 2
                elseif ch == c or ch == "\n" then break
                else e = e + 1 end
            end
            add(pos, math.min(e, n))
            pos = e + 1
        end
    end
    return out
end

-- Literals joined by `..` as one, since the code shows them as one message.
local function chains(src)
    local out = {}
    for _i, t in ipairs(literals(src)) do
        local last = out[#out]
        if last and src:sub(last.e + 1, t.s - 1):match("^%s*%.%.%s*$") then
            last.value, last.e = last.value .. t.value, t.e
        else
            out[#out + 1] = { value = t.value, s = t.s, e = t.e }
        end
    end
    return out
end

-- The messages of the `_("...")` calls in `src`, in order. A call whose argument is
-- not only string literals is left out.
function Extract.calls(src)
    local out = {}
    for _i, c in ipairs(chains(src)) do
        local before = src:sub(math.max(1, c.s - 120), c.s - 1)
        local after = src:sub(c.e + 1, c.e + 120)
        if ("\n" .. before):match("[^%w_]_%(%s*$") and after:match("^%s*[,)]") then out[#out + 1] = c.value end
    end
    return out
end

-- The strings of `src` that start with a capital letter (or a "+"), in order.
function Extract.capitals(src)
    local out = {}
    for _i, c in ipairs(chains(src)) do
        if c.value:match("^[A-Z+]") then out[#out + 1] = c.value end
    end
    return out
end

-- The placeholders in a message (%1, %d, %.1f), a literal %% not counted.
function Extract.placeholders(s)
    local out, i = {}, 1
    s = s:gsub("%%%%", "")
    while true do
        local at = s:find("%", i, true)
        if not at then break end
        local ph = s:match("^%%[%.%d]*[sdfgxXcu]", at) or s:match("^%%%d", at)
        if ph then out[#out + 1] = ph end
        i = at + (ph and #ph or 1)
    end
    return out
end

-- main.lua and every Lua file of the plugin.
local function sourceFiles()
    local list = { "main.lua" }
    for f in io.popen("find ink -name '*.lua' | sort"):lines() do list[#list + 1] = f end
    return list
end

-- Every message of the plugin as msgid -> the files that use it.
function Extract.messages()
    local msgs = {}
    local function add(msgid, file)
        local refs = msgs[msgid] or {}
        msgs[msgid] = refs
        if refs[#refs] ~= file then refs[#refs + 1] = file end
    end
    for _i, file in ipairs(sourceFiles()) do
        local src = readFile(file)
        for _j, m in ipairs(Extract.calls(src)) do add(m, file) end
        if DATA[file] then
            for _j, m in ipairs(Extract.capitals(src)) do
                if not SKIP[m] then add(m, file) end
            end
        end
    end
    -- ink/pentest.lua writes a report for the pen test screen that is meant to be
    -- screenshotted into bug reports, so it stays English; only these three texts are
    -- translated by the views.
    local PenTest = dofile("ink/pentest.lua")
    add(PenTest.NO_PEN_HINT, "ink/pentest.lua")
    add(PenTest.androidTip({ android = true, boox = true }), "ink/pentest.lua")
    add(PenTest.androidTip({ android = true }), "ink/pentest.lua")
    return msgs
end

-- `name "text"` as .po lines: a text with newlines goes one line per newline, after an
-- empty first line.
local function field(name, s)
    local pieces, pos = {}, 1
    while pos <= #s do
        local e = s:find("\n", pos, true) or #s
        pieces[#pieces + 1] = '"' .. s:sub(pos, e):gsub('[\\"\t\r]', ESCAPES):gsub("\n", "\\n") .. '"'
        pos = e + 1
    end
    if #pieces == 0 then return name .. ' ""' end
    if #pieces == 1 then return name .. " " .. pieces[1] end
    return name .. ' ""\n' .. table.concat(pieces, "\n")
end

-- The .pot text for `msgs` (msgid -> list of files), sorted by message. `fill(msgid)`
-- gives each msgstr; without it they are empty.
function Extract.format(msgs, fill)
    local out = {
        "# Ink Away translation template, made by tools/l10n/extract.lua: do not edit it by hand.",
        "# To translate, copy it to ink/l10n/<language>.po and fill in the msgstr lines.",
        'msgid ""', 'msgstr ""',
        '"Project-Id-Version: Ink Away\\n"', '"MIME-Version: 1.0\\n"',
        '"Content-Type: text/plain; charset=UTF-8\\n"', '"Content-Transfer-Encoding: 8bit\\n"',
        '"Language: \\n"',
    }
    local ids = {}
    for id in pairs(msgs) do ids[#ids + 1] = id end
    table.sort(ids)
    for _i, id in ipairs(ids) do
        out[#out + 1] = ""
        local refs = { unpack(msgs[id]) }
        table.sort(refs)
        for _j, file in ipairs(refs) do out[#out + 1] = "#: " .. file end
        if #Extract.placeholders(id) > 0 then out[#out + 1] = "#, lua-format" end
        out[#out + 1] = field("msgid", id)
        out[#out + 1] = field("msgstr", fill and fill(id) or "")
    end
    return table.concat(out, "\n") .. "\n"
end

-- The template for the code as it is now.
function Extract.pot()
    return Extract.format(Extract.messages())
end

if arg and arg[0] == "tools/l10n/extract.lua" then
    os.execute("mkdir -p ink/l10n")
    local f = assert(io.open("ink/l10n/ink-away.pot", "wb"))
    f:write(Extract.pot())
    f:close()
    local n = 0
    for _id in pairs(Extract.messages()) do n = n + 1 end
    print(("ink/l10n/ink-away.pot: %d messages"):format(n))
end

return Extract
