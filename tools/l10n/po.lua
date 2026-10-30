--[[
Reading and writing the translation files for tools/l10n/lang.lua. Unlike the loader
in ink/l10n.lua, which keeps only what it can show, this keeps every entry, fuzzy
ones too, so the tool can sync and check them. Plain Lua.
]]

local Po = {}

local UNESCAPE = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }

local function unquote(line)
    local s = line:match('^%s*"(.*)"%s*$')
    return s and (s:gsub("\\(.)", function(c) return UNESCAPE[c] or c end))
end

-- The entries of a .po text as { id, str, fuzzy } in order, and its header as
-- { { name, value } } in order.
function Po.parse(text)
    local entries, header = {}, {}
    local e, field = {}, nil
    local function flush()
        if e.id == "" then
            for name, value in (e.str or ""):gmatch("([%w%-]+): ?([^\n]*)") do header[#header + 1] = { name, value } end
        elseif e.id then
            entries[#entries + 1] = { id = e.id, str = e.str or "", fuzzy = e.fuzzy or false }
        end
        e, field = {}, nil
    end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        if line:match("^%s*$") then
            flush()
        elseif line:match("^#") then
            if e.str then flush() end
            if line:match("^#,") and line:find("fuzzy", 1, true) then e.fuzzy = true end
        elseif line:match('^%s*"') then
            local piece = unquote(line)
            if piece and field then e[field] = e[field] .. piece end
        else
            local kw, rest = line:match("^%s*(%S+)%s*(.*)$")
            if kw == "msgid" then
                if e.str then flush() end
                e.id, field = unquote(rest) or "", "id"
            elseif kw == "msgstr" then
                e.str, field = unquote(rest) or "", "str"
            else
                field = nil
            end
        end
    end
    flush()
    return entries, header
end

-- The value of a header field, or nil.
function Po.field(header, name)
    for _i, h in ipairs(header) do if h[1] == name then return h[2] end end
end

return Po
