-- KOReader plugins run under LuaJIT with a set of globals provided by the host.
std = "luajit"
globals = { "G_reader_settings" }
read_globals = { "Device" }
-- tests use their own mock package path
files["tests/"] = { ignore = { "212", "213" } }
max_line_length = false
