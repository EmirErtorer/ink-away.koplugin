--[[
The web server behind Send to phone or computer: it runs on the reader itself,
on the home Wi-Fi, only while its sheet is open. KOReader's UI loop calls
waitEvent every few milliseconds (UIManager:insertZMQ, as for its own HTTP
tools), and each call does a little: it takes a new request and hands the
open downloads a few chunks each, so a big PDF never stops the reader from
drawing. A reply may also wait (a PDF still being written) and be sent later.
Only reads and sends files the page's handler chooses (see ink/view/share.lua).
]]

local Http = require("ink/share/http")

local Server = {}
Server.__index = Server

local CHUNK = 64 * 1024        -- read from a file at a time
local BUDGET = 512 * 1024      -- sent per download per poll, at most
local MAX_HEAD = 8 * 1024      -- a request's headers, at most
local HEAD_WAIT = 0.1          -- s, for a request's headers to arrive

-- A server for `o.handler(req, reply)`, on the first free port of `o.ports`.
-- `o.socket` is LuaSocket (tests pass their own).
function Server.new(o)
    local s = setmetatable({ handler = o.handler, ports = o.ports or { 8642, 8643, 8644, 8645, 8646 },
        socket = o.socket or require("socket"), sends = {}, waiting = {}, requests = 0, files_sent = 0,
        on_activity = o.on_activity, make_event = o.make_event }, Server)
    return s
end

-- Listen on all addresses. Returns the port, or nil and the error.
function Server:start()
    local err
    for _, port in ipairs(self.ports) do
        local srv, e = self.socket.bind("*", port)
        if srv then
            srv:settimeout(0)
            self.srv, self.port = srv, port
            return port
        end
        err = e
    end
    return nil, err
end

-- Close the server and every download still going.
function Server:stop()
    for i = #self.sends, 1, -1 do self:finish(self.sends[i]) end
    for client in pairs(self.waiting) do pcall(client.close, client) end
    self.waiting = {}
    if self.srv then pcall(self.srv.close, self.srv); self.srv = nil end
end

function Server:running() return self.srv ~= nil end

-- Read a request's headers from `client`, waiting up to HEAD_WAIT.
local function readHead(client)
    client:settimeout(HEAD_WAIT)
    local lines, size = {}, 0
    while true do
        local line, err = client:receive("*l")
        if not line then return nil, err end
        if line == "" then return table.concat(lines, "\r\n") end
        size = size + #line
        if size > MAX_HEAD then return nil, "too big" end
        lines[#lines + 1] = line
    end
end

-- A reply on `client`: send(code, type, body, extra headers), file(path,
-- type, name for a download or nil to show it, after) or wait() then either
-- of them later. `after()` runs once a file has gone out whole.
function Server:reply(client)
    local done = false
    local r = {}
    local function queue(item)
        if done then return end
        done = true
        self.waiting[client] = nil
        if not self.srv then pcall(client.close, client); return end   -- stopped meanwhile
        item.client = client
        client:settimeout(0)
        self.sends[#self.sends + 1] = item
    end
    function r.send(code, ctype, body, extra)
        body = body or ""
        queue{ buf = Http.header(code, ctype, #body, extra) .. body }
    end
    function r.file(path, ctype, name, after)
        local f = io.open(path, "rb")
        if not f then return r.send(404, Http.TYPES.txt, "Not found") end
        local size = f:seek("end")
        f:seek("set", 0)
        local extra = { Http.disposition(name or path:match("[^/]+$"), name == nil) }
        queue{ buf = Http.header(200, ctype or Http.typeOf(path), size, extra), file = f, after = after,
            counts = name ~= nil }
    end
    function r.wait() r.waiting = true; self.waiting[client] = true end
    function r.open() return not done end
    return r
end

-- Take one waiting request, if any.
function Server:acceptOne()
    local client = self.srv and self.srv:accept()
    if not client then return false end
    local head = readHead(client)
    local req = head and Http.parseRequest(head)
    local reply = self:reply(client)
    if not req then
        reply.send(400, Http.TYPES.txt, "Bad request")
    elseif req.method ~= "GET" and req.method ~= "HEAD" then
        reply.send(405, Http.TYPES.txt, "Only downloads here")
    else
        self.requests = self.requests + 1
        if self.on_activity then pcall(self.on_activity) end
        local ok, err = pcall(self.handler, req, reply)
        if not ok then
            reply.send(500, Http.TYPES.txt, "Something went wrong on the reader: " .. tostring(err))
        elseif not reply.waiting and reply.open() then
            reply.send(404, Http.TYPES.txt, "Not found")
        end
    end
    return true
end

function Server:finish(item)
    if item.file then pcall(item.file.close, item.file); item.file = nil end
    pcall(item.client.close, item.client)
    for i = #self.sends, 1, -1 do if self.sends[i] == item then table.remove(self.sends, i) end end
end

-- Send `item` up to BUDGET bytes now. Returns whether it is still going.
function Server:pump(item)
    local sent = 0
    while sent < BUDGET do
        if item.buf == "" and item.file then
            local chunk = item.file:read(CHUNK)
            if not chunk then
                item.file:close(); item.file = nil
            else
                item.buf = chunk
            end
        end
        if item.buf == "" then
            if item.counts then self.files_sent = self.files_sent + 1 end
            local after = item.after
            self:finish(item)
            if after then pcall(after) end
            return false
        end
        local last, err, partial = item.client:send(item.buf)
        local n = last or partial or 0
        item.buf = item.buf:sub(n + 1)
        sent = sent + n
        if not last then
            if err ~= "timeout" then self:finish(item); return false end   -- the browser went away
            return true   -- its buffer is full: more next time
        end
    end
    return true
end

-- One turn of KOReader's loop: a new request, then a little of each download.
-- Returns an event while in use (see make_event), then nothing.
function Server:waitEvent()
    -- KOReader asks again after an event: nothing more this turn
    if self.yielded then self.yielded = nil; return nil end
    if not self.srv then return nil end
    local active = false
    for _ = 1, 4 do
        if not self:acceptOne() then break end
        active = true
    end
    for i = #self.sends, 1, -1 do
        local item = self.sends[i]
        if item then self:pump(item); active = true end
    end
    -- an event while in use, which keeps the reader from going to sleep
    if active and self.make_event then
        self.yielded = true
        return self.make_event()
    end
    return nil
end

-- Downloads still going.
function Server:busy() return #self.sends > 0 end

return Server
