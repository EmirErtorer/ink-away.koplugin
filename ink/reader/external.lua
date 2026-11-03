-- Adapts the public fixed-page surface contract to the reader's viewer contract.
local Surface = require("ink/reader/surface")
local External = {}
External.__index = External
External.nativeHighlights = false

function External.new(surface, native)
    return setmetatable({ surface = surface, native = native }, External)
end
function External:doc()
    if not self._doc then self._doc = Surface.doc(self.surface) end
    return self._doc
end
function External:currentPage() return self.surface:pages()[1] end
function External:visiblePages() return self.surface:pages() end
function External:layoutKey() return tostring(self.surface) .. "|" .. self.surface:key() end
function External:pagePosition(x, y)
    local page, px, py = self.surface:toPage(x, y)
    if page then return { page = page, x = px, y = py } end
end
function External:readingDirection()
    if self.surface.readingDirection then return self.surface:readingDirection() end
    return self.native:readingDirection()
end
function External:turn(dir, done, frame)
    if self.surface.turn then self.surface:turn(dir, done, frame)
    else done(self.surface) end
end
function External:snapshot(bb) self.surface:snapshot(bb) end
function External:repaint()
    self.surface:repaint()
    self.native:repaint()
end
return External
