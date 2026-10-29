-- KOReader's gettext for the tests: English, unless a test sets `map` (msgid -> translation).
return setmetatable({}, { __call = function(self, s) return self.map and self.map[s] or s end })
