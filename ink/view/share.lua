--[[
Send to phone or computer: while its sheet is open, the reader serves a small
web page on the home Wi-Fi (see ink/share/), and a phone or computer on the
same network opens it from a QR code or the address under it. The page lists
the library's folders and documents with their pictures, and hands out each
one as a PDF, a PNG (a drawing) or its Ink Away file, plus the files already
exported. PDFs and PNGs are made when asked for, one at a time, and kept
until sharing stops. Nothing leaves the home network, and nothing can be
changed from the page. Sharing stops when the sheet closes, when the reader
sleeps, when Ink Away closes, or after a while with nothing asked for.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local logger = require("logger")
local _ = require("gettext")
local Export = require("ink/export")
local Folder = require("ink/folder")
local FolderLook = require("ink/folderlook")
local Http = require("ink/share/http")
local Library = require("ink/library")
local Net = require("ink/share/net")
local Page = require("ink/share/page")
local Storage = require("ink/storage")

local Screen = Device.screen
local function S(px) return Screen:scaleBySize(px) end

local IDLE_MINUTES = 15
local THUMB_W, THUMB_H = 240, 320

local InkAwayView = {}

local function deviceIs(name)
    local f = Device[name]
    if type(f) ~= "function" then return false end
    local ok, yes = pcall(f, Device)
    return ok and yes == true
end

local function hex(rgb)
    return rgb and string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3]) or nil
end

------------------------------------------------------------------------------
-- Starting and stopping
------------------------------------------------------------------------------

-- Open Send to phone or computer: Wi-Fi first (KOReader asks to turn it on,
-- then comes back here), then the server and its sheet.
function InkAwayView:openSend()
    if self._send then return self:showSendSheet() end
    local okn, NetworkMgr = pcall(require, "ui/network/manager")
    if okn and NetworkMgr and NetworkMgr.willRerunWhenConnected
            and NetworkMgr:willRerunWhenConnected(function() self:openSend() end) then
        return
    end
    self:leaveDocument()   -- the open document's latest changes go out too
    local ok, err = self:startSend()
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
    self:showSendSheet()
end

-- Start the server. Returns true, or false and what to tell the reader.
function InkAwayView:startSend()
    local oks, socket = pcall(require, "socket")
    if not oks then return false, _("This reader can't share over Wi-Fi.") end
    local ip = Net.localIP(socket)
    if not ip then
        return false, _("This reader has no address on a network yet. Connect it to Wi-Fi and try again.")
    end
    local Server = require("ink/share/server")
    local Event = require("ui/event")
    local send = { token = Http.token(Http.randomBytes(12), 12), ip = ip, sent = 0, last = os.time(),
        cache = Storage.join(Storage.cacheDir(), "send"), jobs = {} }
    Storage.ensureDir(send.cache)
    send.server = Server.new{
        socket = socket,
        handler = function(req, reply) self:sendRoute(req, reply) end,
        on_activity = function() send.last = os.time() end,
        make_event = function() return Event:new("InputEvent") end,   -- keeps the reader awake while in use
    }
    local port, perr = send.server:start()
    if not port then
        logger.warn("InkAway: send: no port:", perr)
        return false, _("Couldn't start sharing: no free port on this reader.") .. "\n" .. tostring(perr)
    end
    send.port = port
    send.url = string.format("http://%s:%d/%s/", ip, port, send.token)
    if deviceIs("isKindle") then Net.openFirewall(port) end
    UIManager:insertZMQ(send.server)
    self._send = send
    send.idle = function()
        if self._send ~= send then return end
        if os.time() - send.last >= IDLE_MINUTES * 60 and not send.server:busy() and not send.running then
            self:stopSend()
            self:closeSheet("_send_dialog")
            self:showNotice(_("Sharing stopped after a while with nothing sent"))
            return
        end
        UIManager:scheduleIn(60, send.idle)
    end
    UIManager:scheduleIn(60, send.idle)
    logger.info("InkAway: sharing at", ip, port)
    return true
end

-- Stop sharing: the server, its downloads, the firewall hole, and the PDFs
-- and PNGs made for it.
function InkAwayView:stopSend()
    local send = self._send
    if not send then return end
    self._send = nil
    UIManager:unschedule(send.idle)
    if send.status_tick then UIManager:unschedule(send.status_tick) end
    if send.job then pcall(send.job.cancel) end
    if send.spec_done then pcall(send.spec_done) end
    UIManager:removeZMQ(send.server)
    send.server:stop()
    if deviceIs("isKindle") then Net.closeFirewall(send.port) end
    for _i, e in ipairs(Storage.list(send.cache)) do os.remove(e.path) end
    logger.info("InkAway: sharing stopped")
end

-- KOReader puts the reader to sleep: sharing stops (its network goes too).
function InkAwayView:onSuspend()
    if self._send then
        self:stopSend()
        self:closeSheet("_send_dialog")
    end
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

function InkAwayView:sendStatus()
    local send = self._send
    if not send then return "" end
    if send.running then return string.format(_("Making %s\u{2026}"), send.running) end
    if send.sent == 0 then return _("Waiting for your phone or computer\u{2026}") end
    return send.sent == 1 and _("1 file sent") or string.format(_("%d files sent"), send.sent)
end

-- Show the status again (at most every few seconds, as e-ink redraws the sheet).
function InkAwayView:sendStatusChanged()
    local send = self._send
    if not send or send.status_tick then return end
    send.status_tick = function()
        send.status_tick = nil
        if self._send == send then self:rebuildSheet("_send_dialog") end
    end
    UIManager:scheduleIn(2, send.status_tick)
end

function InkAwayView:showSendSheet()
    local send = self._send
    if not send then return end
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_send_dialog") end
    local function para(text, size, bold, color)
        return TextBoxWidget:new{ text = text, face = Font:getFace("cfont", size or 16), bold = bold,
            fgcolor = color, width = content_w, alignment = "center" }
    end
    local build = function()
        local content = VerticalGroup:new{ align = "center" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Send to phone or computer"), content_w, _("Stop"), closeSelf))
        add(VerticalSpan:new{ width = S(10) })
        add(para(_("On a phone or computer on the same Wi-Fi, scan the code or open this address in a browser:")))
        add(VerticalSpan:new{ width = S(12) })
        local side = math.floor(math.min(content_w * 0.62, math.min(Screen:getWidth(), Screen:getHeight()) * 0.5))
        local okq, QRWidget = pcall(require, "ui/widget/qrwidget")
        if okq and QRWidget then
            add(CenterContainer:new{ dimen = Geom:new{ w = content_w, h = side },
                QRWidget:new{ text = send.url, width = side, height = side } })
            add(VerticalSpan:new{ width = S(12) })
        end
        add(para(send.url, 18, true))
        add(VerticalSpan:new{ width = S(14) })
        add(para(self:sendStatus(), 16, true, Blitbuffer.COLOR_DARK_GRAY))
        add(VerticalSpan:new{ width = S(10) })
        add(para(string.format(_("Your notebooks and drawings are there as PDF, PNG and Ink Away files. Sharing stops when you close this, or after %d minutes with nothing sent."), IDLE_MINUTES), 14, false, Blitbuffer.COLOR_DARK_GRAY))
        return content
    end
    self:showSheet("_send_dialog", build)
    -- sharing stops with the sheet, however it closes (Stop, Back, a tap
    -- outside, or Ink Away closing)
    local sheet = self._send_dialog
    local closed = sheet.onCloseWidget
    sheet.onCloseWidget = function(w, ...)
        if self._send_dialog == w or self._send_dialog == nil then self:stopSend() end
        if closed then return closed(w, ...) end
    end
end

------------------------------------------------------------------------------
-- The page's routes
------------------------------------------------------------------------------

-- The library folder or document at `rel` (see Http.safeRel), as a path, or
-- nil when it isn't one the page may show.
function InkAwayView:sendPath(rel, want_dir)
    rel = Http.safeRel(rel)
    if not rel then return nil end
    local root = self:libraryDir()
    local path = rel == "" and root or Storage.join(root, rel)
    -- the library's own folders (exports, legacy folders) are not part of it
    local first = rel:match("^[^/]+")
    if first and Library.INTERNAL[first] then return nil end
    if want_dir then return Storage.isDir(path) and path or nil end
    if not (Storage.exists(path) and not Storage.isDir(path) and Library.isDocument(Storage.baseName(path))) then
        return nil
    end
    return path
end

function InkAwayView:sendRoute(req, reply)
    local send = self._send
    if not send then return reply.send(503, Http.TYPES.txt, "Stopped") end
    local base = "/" .. send.token .. "/"
    if req.path:sub(1, #base) ~= base and req.path .. "/" ~= base then
        return reply.send(404, Http.TYPES.html, Page.gone())
    end
    local route = req.path:sub(#base + 1)
    local q = req.query
    if route == "" then return self:sendListing(q.d or "", reply) end
    if route == "export" then return self:sendExport(q.n, reply) end
    local path = self:sendPath(q.p)
    if not path then return reply.send(404, Http.TYPES.txt, "Not found") end
    if route == "file" then
        return reply.file(path, Http.TYPES.inkaway, Storage.baseName(path), function() self:sendCounted() end)
    elseif route == "thumb" then
        return self:sendThumb(path, reply)
    elseif route == "pdf" then
        return self:sendMade(path, "pdf", reply)
    elseif route == "png" then
        return self:sendMade(path, "png", reply)
    end
    reply.send(404, Http.TYPES.txt, "Not found")
end

function InkAwayView:sendCounted()
    if not self._send then return end
    self._send.sent = self._send.sent + 1
    self:sendStatusChanged()
end

-- The page for library folder `rel`.
function InkAwayView:sendListing(rel, reply)
    local send = self._send
    local dir = self:sendPath(rel, true)
    if not dir then return reply.send(404, Http.TYPES.html, Page.gone()) end
    rel = Http.safeRel(rel)
    local base = "/" .. send.token .. "/"
    local function here(sub) return rel == "" and sub or (rel .. "/" .. sub) end
    local folders, docs = Library.list(dir, self:libraryDir(), self:getSetting("inkaway_library_sort"))
    local looks = #folders > 0 and Folder.load(dir).folders or {}
    local o = { title = rel == "" and _("Library") or Storage.baseName(dir), folders = {}, docs = {},
        note = _("Served by your reader over your Wi-Fi. Close Send to phone or computer on the reader when you're done.") }
    -- the way back up
    if rel ~= "" then
        o.crumbs = { { label = _("Library"), href = base } }
        local acc = ""
        local parts = {}
        for part in rel:gmatch("[^/]+") do parts[#parts + 1] = part end
        for i, part in ipairs(parts) do
            acc = acc == "" and part or (acc .. "/" .. part)
            o.crumbs[#o.crumbs + 1] = { label = part, href = i < #parts and (base .. "?d=" .. Http.urlEncode(acc)) or nil }
        end
    end
    for _i, f in ipairs(folders) do
        local look = FolderLook.clean(looks[f.name])
        o.folders[#o.folders + 1] = { name = f.name, href = base .. "?d=" .. Http.urlEncode(here(f.name)),
            color = hex(look and FolderLook.rgb(look.color)) }
    end
    for _i, d in ipairs(docs) do
        local p = Http.urlEncode(here(d.name))
        local notebook = Library.isNotebookFile(d.path)
        local links = notebook
            and { { label = "PDF", href = base .. "pdf?p=" .. p, main = true } }
            or { { label = "PNG", href = base .. "png?p=" .. p, main = true }, { label = "PDF", href = base .. "pdf?p=" .. p } }
        links[#links + 1] = { label = _("Ink Away file"), href = base .. "file?p=" .. p }
        o.docs[#o.docs + 1] = { name = Storage.stem(d.name), thumb = base .. "thumb?p=" .. p,
            kind = (notebook and _("Notebook") or _("Drawing")) .. " · " .. os.date("%d %b %Y", d.mtime or 0),
            links = links }
    end
    if rel == "" then o.exports = self:sendExportsList(base) end
    reply.send(200, Http.TYPES.html, Page.render(o))
end

-- The folders exports are saved in: Ink Away's own, and the one chosen in
-- Settings when it is another.
function InkAwayView:sendExportDirs()
    local dirs, seen = {}, {}
    for _i, d in ipairs({ Storage.appDir("exports"), self:exportDir() }) do
        if d and not seen[d] and Storage.isDir(d) then seen[d] = true; dirs[#dirs + 1] = d end
    end
    return dirs
end

-- The PDFs and PNGs already exported, newest first.
function InkAwayView:sendExportsList(base)
    local files = {}
    for _i, dir in ipairs(self:sendExportDirs()) do
        for _j, e in ipairs(Storage.list(dir)) do
            local ext = e.name:match("%.(%w+)$")
            ext = ext and ext:lower()
            if e.mode == "file" and (ext == "pdf" or ext == "png") and e.name:sub(1, 1) ~= "." then
                files[#files + 1] = e
            end
        end
    end
    table.sort(files, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
    local out = {}
    for i = 1, math.min(#files, 40) do
        local e = files[i]
        local attr = Storage.size and Storage.size(e.path)
        out[i] = { name = e.name, href = base .. "export?n=" .. Http.urlEncode(e.name),
            size = attr and Http.size(attr) or nil }
    end
    return out
end

-- An exported file, by its name.
function InkAwayView:sendExport(name, reply)
    name = tostring(name or "")
    if name == "" or name:find("[/\\%z]") or name:sub(1, 1) == "." then
        return reply.send(404, Http.TYPES.txt, "Not found")
    end
    for _i, dir in ipairs(self:sendExportDirs()) do
        local path = Storage.join(dir, name)
        if Storage.exists(path) and not Storage.isDir(path) then
            return reply.file(path, Http.typeOf(name), name, function() self:sendCounted() end)
        end
    end
    reply.send(404, Http.TYPES.txt, "Not found")
end

-- A document's picture for the page, from the library's thumbnail cache.
function InkAwayView:sendThumb(path, reply)
    local file = Storage.join(Storage.cacheDir(), Library.thumbName(path, Storage.mtime(path), THUMB_W, THUMB_H))
    if not Storage.exists(file) then
        local ok, bb = pcall(self.docThumb, self, path, THUMB_W, THUMB_H)
        if ok and bb then bb:free() end
    end
    if not Storage.exists(file) then return reply.send(404, Http.TYPES.txt, "No picture") end
    reply.file(file, Http.TYPES.png, nil)
end

------------------------------------------------------------------------------
-- PDFs and PNGs, made when asked for
------------------------------------------------------------------------------

-- Send the document at `path` as a PDF or PNG (`kind`): the copy made for
-- this sharing when there is one, else made now, after any being made.
function InkAwayView:sendMade(path, kind, reply)
    local send = self._send
    local out = Storage.join(send.cache, string.format("%s-%d.%s", Library.pathCode(path), Storage.mtime(path) or 0, kind))
    local name = Storage.stem(Storage.baseName(path)) .. "." .. kind
    local function deliver()
        if not reply.open() then return end
        if Storage.exists(out) then
            reply.file(out, Http.TYPES[kind], name, function() self:sendCounted() end)
        else
            reply.send(500, Http.TYPES.txt, "Couldn't make the " .. kind:upper() .. " on the reader.")
        end
    end
    if Storage.exists(out) then return deliver() end
    reply.wait()
    send.jobs[#send.jobs + 1] = { path = path, kind = kind, out = out, name = name, deliver = deliver }
    self:sendNextJob()
end

-- Start the next PDF or PNG waiting, one at a time.
function InkAwayView:sendNextJob()
    local send = self._send
    if not send or send.running then return end
    local item = table.remove(send.jobs, 1)
    if not item then return end
    -- several asked for the same file: the first one makes it
    if Storage.exists(item.out) then item.deliver(); return self:sendNextJob() end
    send.running = item.name
    self:sendStatusChanged()
    local function finished()
        if self._send ~= send then return end
        send.running, send.job, send.spec_done = nil, nil, nil
        send.last = os.time()
        item.deliver()
        self:sendStatusChanged()
        UIManager:nextTick(function() self:sendNextJob() end)
    end
    if item.kind == "png" then
        -- a drawing at its full size, on its paper
        UIManager:nextTick(function()
            if self._send ~= send then return end
            local ok, err = pcall(function()
                local bb = self:renderDocThumb(item.path, self.view.canvas_w, self.view.canvas_h)
                if not bb then error("no picture") end
                bb:writePNG(item.out)
                bb:free()
            end)
            if not ok then logger.warn("InkAway: send: png failed:", err); os.remove(item.out) end
            finished()
        end)
        return
    end
    -- a PDF, one page per step so the reader keeps up
    local acc = { pages = {}, templates = {}, sources = {}, places = {} }
    local entry = self:collectDocumentPages(item.path, acc)
    if not entry or #acc.pages == 0 then return finished() end
    local spec = self:pagesPdfSpec(acc, { entry })
    local tmp = item.out .. ".part"
    local job, jerr = Export.notebookPDFJob(spec.pages, spec.w, spec.h, spec.template, tmp, 85,
        Storage.settingsDir(), spec.bg, { outline = spec.outline, links = spec.links })
    if not job then
        logger.warn("InkAway: send: pdf failed:", jerr)
        if spec.done then spec.done() end
        return finished()
    end
    send.job, send.spec_done = job, spec.done
    local function step()
        if self._send ~= send or send.job ~= job then return end
        local state, err = job.step()
        if state == "done" then
            if spec.done then spec.done() end
            send.spec_done = nil
            os.rename(tmp, item.out)
            return finished()
        elseif not state then
            logger.warn("InkAway: send: pdf failed:", err)
            if spec.done then spec.done() end
            send.spec_done = nil
            os.remove(tmp)
            return finished()
        end
        UIManager:scheduleIn(0.02, step)
    end
    UIManager:scheduleIn(0.02, step)
end

return InkAwayView
