-- Minimal stand-in for KOReader's Font: a face is just an opaque table carrying
-- its name and pixel size. Enough for the view's labelWidget in headless tests.
local Font = {}
function Font:getFace(name, size) return { name = name, size = size or 18 } end
return Font
