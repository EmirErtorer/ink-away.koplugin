-- Mock of KOReader's RenderImage: scaleBlitBuffer returns a new buffer of the
-- requested size (the real one uses mupdf's C scaler).
local BB = require("ffi/blitbuffer")
local RenderImage = {}
function RenderImage:scaleBlitBuffer(bb, width, height, free_orig_bb)
    if not width or not height then return bb end
    if bb:getWidth() == width and bb:getHeight() == height then return bb end
    return BB.new(width, height, bb:getType())
end
-- Decode an image file. The tests set RenderImage.fake_size to control the
-- natural dimensions of the "decoded" picture; a nil size means decode fails.
RenderImage.fake_size = { w = 200, h = 100 }
function RenderImage:renderImageFile(path, cache, width, height)
    if not RenderImage.fake_size then return nil end
    return BB.new(RenderImage.fake_size.w, RenderImage.fake_size.h, BB.TYPE_BBRGB32 or 5)
end
return RenderImage
