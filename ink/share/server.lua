--[[
The web server behind Send to phone or computer: it runs on the reader itself,
on the home Wi-Fi, only while its sheet is open. KOReader's UI loop calls
waitEvent every few milliseconds (UIManager:insertZMQ, as for its own HTTP
tools), and each call does a little and never waits: it reads what requests
have arrived so far, answers the ones complete, and hands the open downloads
a few chunks each, so neither a big file nor a slow or hostile browser can
stop the reader. A reply may also wait (a picture still being drawn) and be
sent later. Only sends files the page's handler chooses (see ink/view/share.lua).
]]

local Http = require("ink/share/http")

local Server = {}
Server.__index = Server

local CHUNK = 64 * 1024        -- read from a file at a time
local BUDGET = 512 * 1024      -- sent per download per poll, at most
local MAX_HEAD = 8 * 1024      -- a request's headers, at most
local MAX_CONN = 16            -- connections at once (reading, waiting and sending)

-- A server for `o.handler(req, reply)`, on the first free port of `o.ports`.
-- `o.socket` is LuaSocket (tests pass their own); `o.head_timeout` is how long
-- a request may take to arrive (s).
function Server.new(o)
    return setmetatable({ handler = o.handler, ports = o.ports or { 8642, 8643, 8644, 8645, 8646 },
        socket = o.socket or require("socket"), head_timeout = o.head_timeout or 5,
        reading = {}, sends = {}, waiting = {}, requests = 0, files_sent = 0,
        on_activity = o.on_activity, make_event = o.make_event }, Server)
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

local function close(c) pcall(c.close, c) end

-- Close the server and every connection, whatever it was doing.
function Server:stop()
    for i = #self.sends, 1, -1 do self:finish(self.sends[i]) end
    for _, r in ipairs(self.reading) do close(r.client) end
    self.reading = {}
    for client, reply in pairs(self.waiting) do reply.gone = true; close(client) end
    self.waiting = {}
    if self.srv then close(self.srv); self.srv = nil end
end

function Server:running() return self.srv ~= nil end

function Server:connections()
    local n = #self.reading + #self.sends
    for _ in pairs(self.waiting) do n = n + 1 end
    return n
end

-- A reply on `client`: send(code, type, body, extra headers), file(path,
-- type, name for a download or nil to show it, after) or wait() then either
-- of them later. `after()` runs once a file has gone out whole. `gone` turns
-- true when the browser leaves while it waits.
function Server:reply(client)
    local done = false
    local r = {}
    local function queue(item)
        if done then return end
        done = true
        self.waiting[client] = nil
        if not self.srv or r.gone then close(client); return end   -- stopped or left meanwhile
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
            counts = name ~= nil, name = name, total = size, sent = 0 }
    end
    function r.wait() r.waiting = true; self.waiting[client] = r end
    function r.open() return not done and not r.gone end
    return r
end

-- Answer the request in `head` (complete) from `client`.
function Server:dispatch(client, head)
    local req = Http.parseRequest(head)
    local reply = self:reply(client)
    if not req then
        return reply.send(400, Http.TYPES.txt, "Bad request")
    elseif req.method ~= "GET" then
        return reply.send(405, Http.TYPES.txt, "Only downloads here")
    end
    self.requests = self.requests + 1
    if self.on_activity then pcall(self.on_activity) end
    local ok, err = pcall(self.handler, req, reply)
    if not ok then
        reply.send(500, Http.TYPES.txt, "Something went wrong on the reader: " .. tostring(err))
    elseif not reply.waiting and reply.open() then
        reply.send(404, Http.TYPES.txt, "Not found")
    end
end

-- Take new connections, up to the limit; any more are closed at once.
function Server:acceptNew(now)
    local got = false
    for _ = 1, 8 do
        local client = self.srv:accept()
        if not client then break end
        got = true
        if self:connections() >= MAX_CONN then
            close(client)
        else
            client:settimeout(0)
            self.reading[#self.reading + 1] = { client = client, buf = "", deadline = now + self.head_timeout }
        end
    end
    return got
end

-- Read what has arrived of each request, without waiting; answer the complete
-- ones, drop the ones too big, too slow or gone.
function Server:readRequests(now)
    local active = false
    for i = #self.reading, 1, -1 do
        local r = self.reading[i]
        local data, err, partial = r.client:receive(4096)
        local got = data or partial
        if got and #got > 0 then r.buf = r.buf .. got; active = true end
        local head_end = r.buf:find("\r\n\r\n", 1, true)
        if (head_end or #r.buf) > MAX_HEAD then
            table.remove(self.reading, i)
            self:reply(r.client).send(400, Http.TYPES.txt, "Request too big")
        elseif head_end then
            table.remove(self.reading, i)
            self:dispatch(r.client, r.buf:sub(1, head_end - 1))
            active = true
        elseif err == "closed" or now > r.deadline then
            table.remove(self.reading, i)
            close(r.client)
        end
    end
    return active
end

-- Notice browsers that left while their reply waited.
function Server:checkWaiting()
    for client, reply in pairs(self.waiting) do
        local _, err = client:receive(0)
        if err == "closed" then
            reply.gone = true
            self.waiting[client] = nil
            close(client)
        end
    end
end

function Server:finish(item)
    if item.file then pcall(item.file.close, item.file); item.file = nil end
    close(item.client)
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
                if item.total then item.sent = item.sent + #chunk end
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

-- One turn of KOReader's loop, never waiting. Returns an event while in use
-- (see make_event, it keeps the reader awake), then nothing.
function Server:waitEvent()
    -- KOReader asks again after an event: nothing more this turn
    if self.yielded then self.yielded = nil; return nil end
    if not self.srv then return nil end
    local now = self.socket.gettime()
    local active = self:acceptNew(now)
    if self:readRequests(now) then active = true end
    self:checkWaiting()
    for i = #self.sends, 1, -1 do
        local item = self.sends[i]
        if item then self:pump(item); active = true end
    end
    if active and self.make_event then
        self.yielded = true
        return self.make_event()
    end
    return nil
end

-- The downloads going out: { name, sent, total } for each named file.
function Server:transfers()
    local out = {}
    for _, item in ipairs(self.sends) do
        if item.name and item.total then out[#out + 1] = { name = item.name, sent = item.sent, total = item.total } end
    end
    return out
end

-- Stop every download going out (the reader's Cancel).
function Server:cancelTransfers()
    for i = #self.sends, 1, -1 do
        if self.sends[i].name then self:finish(self.sends[i]) end
    end
end

-- Downloads still going.
function Server:busy() return #self.sends > 0 end

return Server
