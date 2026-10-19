-- Exercise the real Linux fork/socket transport, substituting only the Elipsa's
-- ioctl and framebuffer. The buffer is MAP_SHARED just like KOReader's ION map.
package.path = "./?.lua;" .. package.path
local ffi = require("ffi")
if ffi.os ~= "Linux" then print("elipsaworker: skipped (Linux transport)"); os.exit(0) end
ffi.cdef[[
    typedef int pid_t;
    struct sched_param { int sched_priority; };
    struct pollfd { int fd; short events; short revents; };
    void *mmap(void *, size_t, int, int, int, long);
    int munmap(void *, size_t);
    int fork(void);
    int getpid(void);
    void _exit(int);
    int close(int);
    int kill(int, int);
    int waitpid(int, int *, int);
    int usleep(unsigned int);
    int poll(struct pollfd *, unsigned long, int);
    long recv(int, void *, size_t, int);
    long send(int, const void *, size_t, int);
    int sched_setscheduler(int, int, const struct sched_param *);
    int setpriority(int, unsigned int, int);
]]
local C = ffi.C
local data = C.mmap(nil, 4096, 3, 0x21, -1, 0) -- PROT_READ|WRITE, MAP_SHARED|ANONYMOUS
assert(data ~= ffi.cast("void *", -1))
local shared = ffi.cast("int32_t *", data)
local fail_toggle = false
local sys = setmetatable({ AF_UNIX = 1, SOCK_SEQPACKET = 5, POLLIN = 1, PRIO_PROCESS = 0, EINTR = 4 }, {
    __index = function(_, name) return C[name] end,
})
function sys.ioctl(fd, request, arg)
    assert(fd == 123 and request == 0x4015, "the exact Elipsa handwriting ABI")
    if fail_toggle then return -1 end
    shared[0] = arg[0] and 1 or 0
    if arg[0] then shared[1] = shared[1] + 1 else shared[2] = shared[2] + 1 end
    return 0
end
-- Use the real FFI functions and kernel IPC; only hardware ioctl is substituted.
package.loaded["ffi"] = setmetatable({ C = sys }, { __index = ffi })
package.loaded["ffi/posix_h"] = true
local pids = {}
package.loaded["ffi/util"] = {
    runInSubProcess = function(fn)
        local pid = C.fork()
        if pid == 0 then
            local success, err = pcall(fn)
            if not success then io.stderr:write(tostring(err), "\n") end
            C._exit(success and 0 or 1)
        end
        if pid < 0 then return false, "fork failed" end
        pids[#pids + 1] = pid
        return pid
    end,
    isSubProcessDone = function(pid, wait)
        return C.waitpid(pid, nil, wait and 0 or 1) ~= 0
    end,
    terminateSubProcess = function(pid) C.kill(pid, 9) end,
}
local Worker = require("ink/elipsaworker")
local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local fb = { fd = 123, waveform_fast = 2, marker_data = ffi.new("uint32_t[1]") }
do
    local worker = assert(Worker.start(fb, function(screen, no_merge, flash, mode, x, y, w, h)
        assert(not no_merge and not flash and mode == 2)
        C.usleep(100000) -- emulate a blocking sunxi update ioctl
        shared[3], shared[4], shared[5], shared[6] = x, y, w, h
        shared[7] = shared[8]
        screen.marker_data[0] = 42
    end))
    ok(shared[0] == 1 and shared[1] == 1, "driver handwriting mode enabled")
    ok(worker:send({ x = 10, y = 20, w = 30, h = 40 }), "request submitted")
    ok(worker:poll(false) == nil, "blocking driver does not block input polling")
    shared[8] = 91
    ok(worker:poll(true) == 42, "actual worker returns driver marker")
    ok(shared[3] == 10 and shared[4] == 20 and shared[5] == 30 and shared[6] == 40, "rectangle survives IPC")
    ok(shared[7] == 91, "worker sees pixels written to shared framebuffer after fork")
    ok(fb.marker_data[0] == 0, "driver structs are private; marker must be copied back explicitly")
    ok(worker:close(false) and shared[0] == 0, "clean close disables handwriting mode")
    ok(C.waitpid(pids[#pids], nil, 1) == -1, "worker reaped, no zombie")
end
do
    local worker = assert(Worker.start(fb, function() error("driver failure") end))
    worker:send({ x = 1, y = 2, w = 3, h = 4 })
    ok(worker:poll(true) == false, "Lua driver failure reported through IPC")
    worker:close(true)
    ok(shared[0] == 0, "failed worker leaves handwriting disabled")
    ok(not worker:send({ x = 1, y = 2, w = 3, h = 4 }), "closed transport fails safely without SIGPIPE")
end
do
    fail_toggle = true
    local count = #pids
    local worker = Worker.start(fb, function() end)
    ok(not worker and #pids == count, "unsupported handwriting ioctl never forks")
end
C.munmap(data, 4096)
print(("elipsaworker: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
