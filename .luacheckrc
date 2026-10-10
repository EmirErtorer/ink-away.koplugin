-- KOReader plugins run under LuaJIT with a set of globals provided by the host.
std = "luajit"
globals = { "G_reader_settings" }
read_globals = { "Device" }
max_line_length = false
-- Methods keep `self` even when they don't use it, as KOReader's own code does,
-- and names starting with an underscore are unused on purpose (loops use `_i`,
-- not `_`, so they don't hide gettext).
self = false
ignore = { "21./_.*" }

-- Tests reuse names, shadow and overwrite freely, and fill in a few stand-ins.
files["tests/"] = { ignore = { "21", "23", "311", "4", "542" } }
files["tests/scribe/harness.lua"] = { globals = { table = { fields = { "pack" } } } }

-- build output
exclude_files = { "dist/" }
