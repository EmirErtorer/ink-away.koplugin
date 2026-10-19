--[[
First-generation Elipsa display worker. ION's MAP_SHARED pixel buffer survives
fork(), so the child sees the parent's drawing without copying a screen per
sample. Driver structs and rotation are private snapshots: the caller must stop
the worker before changing layout or issuing any other kind of refresh.
]]
local Worker = {}

-- Start a worker using KOReader's fork helper. Loaded only on Kobo_europa.
function Worker.start(screen, refresh)
    local ffi = require("ffi")
    require("ffi/posix_h")
    local util = require("ffi/util")
    local C = ffi.C
    ffi.cdef[[
        int socketpair(int domain, int type, int protocol, int sv[2]);
        int shutdown(int sockfd, int how);
        int getppid(void);
    ]]
    local HANDWRITE = 0x4015 -- DISP_EINK_SET_NTX_HANDWRITE_ONOFF, FW 4.38.23429
    local NOSIGNAL, DONTWAIT = 0x4000, 0x40
    local timeout = 3000
    local sockets = ffi.new("int[2]")
    if C.socketpair(C.AF_UNIX, C.SOCK_SEQPACKET + 0x80000, 0, sockets) ~= 0 then -- SOCK_CLOEXEC
        return nil, "socketpair failed"
    end
    local parent, child = tonumber(sockets[0]), tonumber(sockets[1])
    local toggle = ffi.new("bool[1]", true)
    if C.ioctl(screen.fd, HANDWRITE, toggle) < 0 then
        C.close(parent); C.close(child)
        return nil, "handwriting ioctl failed: " .. ffi.errno()
    end
    local function disable()
        toggle[0] = false
        return C.ioctl(screen.fd, HANDWRITE, toggle) >= 0
    end
    local parent_pid = C.getpid()
    local started, pid, err = pcall(util.runInSubProcess, function()
        C.close(parent)
        -- The fork helper normally gives background jobs batch scheduling and
        -- nice +5. Drawing must compete normally with the input process.
        local param = ffi.new("struct sched_param")
        C.sched_setscheduler(0, 0, param) -- SCHED_OTHER (not declared by KOReader)
        C.setpriority(C.PRIO_PROCESS, 0, 0)
        local rect, reply = ffi.new("int32_t[4]"), ffi.new("uint32_t[2]")
        local incoming = ffi.new("struct pollfd[1]")
        incoming[0].fd, incoming[0].events = child, C.POLLIN
        pcall(function()
            while true do
                -- Other Lua subprocesses can inherit the socket too. Detect a
                -- dead parent even if their duplicate keeps our socket open.
                if C.getppid() ~= parent_pid then break end
                local ready = C.poll(incoming, 1, 1000)
                if ready < 0 and ffi.errno() ~= C.EINTR then break end
                if ready > 0 then
                    local n = C.recv(child, rect, ffi.sizeof(rect), DONTWAIT)
                    -- A signal consumes no command; return to the parent check.
                    if n >= 0 or ffi.errno() ~= C.EINTR then
                        if n ~= ffi.sizeof(rect) or rect[2] == 0 then break end
                        local ok = pcall(refresh, screen, false, false, screen.waveform_fast,
                            tonumber(rect[0]), tonumber(rect[1]), tonumber(rect[2]), tonumber(rect[3]))
                        reply[0], reply[1] = ok and 1 or 0, screen.marker_data[0]
                        if C.send(child, reply, ffi.sizeof(reply), NOSIGNAL) ~= ffi.sizeof(reply) or not ok then break end
                    end
                end
            end
        end)
        disable() -- also runs on EOF when the parent has gone away
        C.close(child)
    end)
    C.close(child)
    if not started or not pid then
        C.close(parent)
        disable()
        return nil, started and err or pid
    end

    local rect, reply = ffi.new("int32_t[4]"), ffi.new("uint32_t[2]")
    local pollfd = ffi.new("struct pollfd[1]")
    pollfd[0].fd, pollfd[0].events = parent, C.POLLIN
    local transport = {}

    -- Only one command may be outstanding; sends therefore cannot fill the socket.
    function transport:send(r)
        rect[0], rect[1], rect[2], rect[3] = r.x, r.y, r.w, r.h
        return C.send(parent, rect, ffi.sizeof(rect), NOSIGNAL + DONTWAIT) == ffi.sizeof(rect)
    end

    -- nil: busy; false: worker failed; number: completed marker (including zero).
    function transport:poll(wait)
        local n = C.poll(pollfd, 1, wait and timeout or 0)
        if n == 0 and not wait then return nil end
        if n <= 0 then return false end
        if C.recv(parent, reply, ffi.sizeof(reply), DONTWAIT) ~= ffi.sizeof(reply) or reply[0] ~= 1 then
            return false
        end
        return tonumber(reply[1])
    end

    -- The caller has drained its commands before a normal shutdown. EOF wakes
    -- an idle worker; a failed worker is killed before synchronous fallback.
    function transport:close(failed)
        C.shutdown(parent, 2) -- EOF even if another subprocess inherited our fd
        C.close(parent)
        if failed then util.terminateSubProcess(pid) end
        util.isSubProcessDone(pid, true)
        if not disable() then return false end
        return true
    end
    return transport
end

return Worker
