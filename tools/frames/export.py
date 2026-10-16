"""Cut the Drawings shelf frames into the pieces Ink Away tiles at run time.

Each mitred frame is rendered once per colour option as a reference frame
whose sides are a whole number of strip lengths long, with every carving and
texture repeating exactly once per strip (fr.PERIOD), so a strip tiles with no
seam at any side length. From it come, per option, one JPEG atlas:

  tl tr bl br             the corners, c x c (only the two arms are used)
  top_l top_r ...         one strip for each half of each side (leaves and
                          twists point to the middle, so the halves differ)
  top_c bottom_c ...      the ornament at each side's middle, if the frame has one

and ink/data/frames/manifest.lua says where each piece is. Instant Photo gets a
paper tile; Canvas Wrap is drawn at run time from the drawing itself.

Run with numpy, Pillow and scipy:
    python3 tools/frames/export.py            # -> ink/data/frames/
    python3 tools/frames/export.py --check    # also report the seams
"""
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fr  # noqa: E402
import designs as D  # noqa: E402

OUT = os.path.join(HERE, "..", "..", "ink", "data", "frames")
CW = 480            # a cover's width; Bookshelf scales it to the shelf
QUALITY = 90

# key: (design fn, border as a share of CW, corner piece in T, centre piece
# in T (0: none), strip length in T, inner shadow on the mat (rows,
# strength), options, inside: (mat tile, the mat round the drawing as a
# share of the opening's width, the drawing floats on it))
SPECS = [
    ("baroque", D.baroque, 0.155, 1.75, 2.4, 0.34, (9, 0.42), ["gold", "antique", "silver"], ("mat", 0, False)),
    ("louis", D.louis, 0.125, 1.0, 0, 0.30, (8, 0.40), ["gold", "white", "silver"], ("mat", 0, False)),
    ("ripple", D.ripple_frame, 0.13, 1.0, 0, 0.30, (8, 0.45), ["ebony", "tortoise", "walnut"], ("mat", 0, False)),
    ("victorian", D.victorian, 0.15, 1.0, 0, 0.36, (8, 0.40), ["walnut", "mahogany", "ebonised"], ("mat", 0, False)),
    ("crafts", D.crafts, 0.125, 1.15, 0, 1.4, (7, 0.35), ["light", "fumed", "cherry"], ("mat", 0, False)),
    ("deco", D.deco, 0.14, 1.0, 1.3, 0.5, (8, 0.42), ["black", "ivory", "emerald"], ("mat", 0, False)),
    ("museum", D.museum, 0.045, 1.0, 0, 3.0, (7, 0.32), ["black", "white", "oak"], ("mat", 0.16, False)),
    ("floating", D.floating, 0.06, 1.0, 0, 2.5, (16, 0.50), ["light", "walnut", "white"], ("linen", 0.10, True)),
    ("metal", D.metal_frame, 0.035, 1.0, 0, 4.0, (6, 0.30), ["silver", "black", "brass"], ("mat", 0, False)),
    ("painted", D.painted, 0.075, 1.0, 0, 2.5, (7, 0.35), ["red", "mustard", "blue", "sage"], ("mat", 0, False)),
]

INSTANT = {"sides": (41, 36, 36, 120), "tile": 96,
           "options": [("white", (250, 249, 245), (52, 52, 64)), ("black", (30, 30, 32), (236, 236, 236)),
                       ("mint", (206, 232, 220), (52, 60, 58))]}


def even(n):
    return n + (n % 2)


def geometry(spec):
    key, fn, frac, cT, wcT, lsT, shadow, opts, inside = spec
    T = round(CW * frac)
    C = max(T, math.ceil(cT * T) + 1)
    Wc = even(math.ceil(wcT * T) + 2) if wcT else 0
    Ls = max(8, round(lsT * T))
    # long enough that the strips are cut from well inside each half, out of
    # reach of the ornaments' shading
    def side(target):
        n = max(5, round((target - 2 * C - Wc) / (2 * Ls)), math.ceil(1.6 * T / Ls) * 2 + 1)
        return 2 * C + Wc + 2 * n * Ls, n
    W0, nx = side(CW)
    H0, ny = side(round(CW * 1.36))
    return dict(T=T, C=C, Wc=Wc, Ls=Ls, W0=W0, H0=H0, nx=nx, ny=ny)


def pieces_of(img, g):
    """the named pieces of a reference frame image"""
    T, C, Wc, Ls, W0, H0 = g["T"], g["C"], g["Wc"], g["Ls"], g["W0"], g["H0"]
    kx, ky = g["nx"] // 2, g["ny"] // 2      # the strip in the middle of each half
    box = {
        "tl": (0, 0, C, C), "tr": (W0 - C, 0, C, C), "bl": (0, H0 - C, C, C), "br": (W0 - C, H0 - C, C, C),
        "top_l": (C + kx * Ls, 0, Ls, T), "top_r": (W0 - C - (kx + 1) * Ls, 0, Ls, T),
        "bottom_l": (C + kx * Ls, H0 - T, Ls, T), "bottom_r": (W0 - C - (kx + 1) * Ls, H0 - T, Ls, T),
        "left_t": (0, C + ky * Ls, T, Ls), "left_b": (0, H0 - C - (ky + 1) * Ls, T, Ls),
        "right_t": (W0 - T, C + ky * Ls, T, Ls), "right_b": (W0 - T, H0 - C - (ky + 1) * Ls, T, Ls),
    }
    if Wc:
        box.update({
            "top_c": ((W0 - Wc) // 2, 0, Wc, T), "bottom_c": ((W0 - Wc) // 2, H0 - T, Wc, T),
            "left_c": (0, (H0 - Wc) // 2, T, Wc), "right_c": (W0 - T, (H0 - Wc) // 2, T, Wc),
        })
    a = np.asarray(img)
    out = {}
    for k, (x, y, w, h) in box.items():
        p = a[y:y + h, x:x + w].copy()
        if k in ("tl", "tr", "bl", "br"):
            # the corner's inner quarter is the opening: never drawn, so made
            # flat (it costs nothing in the JPEG)
            ys = slice(T, C) if k[0] == "t" else slice(0, C - T)
            xs = slice(T, C) if k[1] == "l" else slice(0, C - T)
            p[ys, xs] = p[ys, xs].mean(axis=(0, 1)).astype(np.uint8)
        out[k] = p
    return out


def pad8(p):
    """edge-extend a piece to whole 8 x 8 JPEG blocks, so its neighbours in
    the atlas never bleed into it"""
    h, w = p.shape[:2]
    H, W = -(-h // 8) * 8, -(-w // 8) * 8
    return np.pad(p, ((0, H - h), (0, W - w), (0, 0)), mode="edge")


def pack(pieces, width=512):
    """shelf-pack the pieces at block-aligned spots; returns the atlas array
    and each piece's rect"""
    order = sorted(pieces, key=lambda k: -pad8(pieces[k]).shape[0])
    x = y = rowh = 0
    spots, maxw = {}, 0
    for k in order:
        p = pad8(pieces[k])
        h, w = p.shape[:2]
        if x + w > width and x > 0:
            x, y, rowh = 0, y + rowh, 0
        spots[k] = (x, y)
        x += w
        rowh = max(rowh, h)
        maxw = max(maxw, x)
    H = y + rowh
    atlas = np.zeros((H, maxw, 3), np.uint8)
    rects = {}
    for k, (x0, y0) in spots.items():
        p = pad8(pieces[k])
        atlas[y0:y0 + p.shape[0], x0:x0 + p.shape[1]] = p
        h, w = pieces[k].shape[:2]
        rects[k] = (x0, y0, w, h)
    return atlas, rects


def seam(img, g):
    """how much the second strip differs from the first, per side (0 = none)"""
    a = np.asarray(img).astype(np.int16)
    T, C, Ls = g["T"], g["C"], g["Ls"]
    x = C + (g["nx"] // 2) * Ls
    y = C + (g["ny"] // 2) * Ls
    return [np.abs(a[:T, x:x + Ls] - a[:T, x - Ls:x]).max(), np.abs(a[y:y + Ls, :T] - a[y - Ls:y, :T]).max()]


def lua_rect(r):
    return "{ %d, %d, %d, %d }" % r


def instant_atlas(bg, weave=False):
    """a paper (or linen, `weave`) tile that repeats, and nothing else"""
    n = INSTANT["tile"]
    S = fr.SS
    fr.PERIOD = n * S
    y, x = np.mgrid[0:n * S, 0:n * S].astype(np.float32) + 0.5
    tex = 1 + 0.025 * (fr.pn(x, y, 3.0 * S, 3.0 * S, 61, 3) - 0.5) + 0.012 * (fr.pn(x, y, 24.0 * S, 24.0 * S, 62, 2) - 0.5)
    if weave:
        wp = fr.qp(2.6 * S)
        wv = 0.5 + 0.5 * np.sin(x / wp * 2 * math.pi) * np.sin(y / wp * 2 * math.pi)
        tex = tex + 0.05 * (wv - 0.5) + 0.02 * (fr.pn(x, y, 1.2 * S, 30.0 * S, 63, 2) - 0.5)
    col = np.array(bg, np.float32) / 255 * tex[..., None]
    img = fr.down(fr.to_img(col), n, n)
    fr.PERIOD = None
    return np.asarray(img)


def main():
    check = "--check" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    os.makedirs(OUT, exist_ok=True)
    lines = ["-- Generated by tools/frames/export.py from the frame designs; do not edit.",
             "-- Each frame's pieces are rects { x, y, w, h } in its options' atlases.",
             "return {", "    cover_w = %d," % CW, "    frames = {"]
    total = 0
    for spec in SPECS:
        key, fn, frac, cT, wcT, lsT, shadow, opts, inside = spec
        g = geometry(spec)
        rects = None
        for o in opts:
            if only and key not in only:
                break
            fr.PERIOD = g["Ls"] * fr.SS
            img, _box = fn(g["W0"], g["H0"], o, T=g["T"], unit=g["Ls"] / g["T"])
            fr.PERIOD = None
            if check:
                print("  seam", key, o, ["%.2f" % s for s in seam(img, g)])
            atlas, rects = pack(pieces_of(img, g))
            path = os.path.join(OUT, "%s-%s.jpg" % (key, o))
            Image.fromarray(atlas).save(path, quality=QUALITY, subsampling=0, optimize=True)
            total += os.path.getsize(path)
            print("%-10s %-9s %3d KB  %dx%d" % (key, o, os.path.getsize(path) // 1024, atlas.shape[1], atlas.shape[0]), flush=True)
        if rects is None:
            rects = pack(pieces_of(Image.new("RGB", (g["W0"], g["H0"])), g))[1]
        lines.append("        { key = \"%s\", kind = \"frame\", t = %d, c = %d, wc = %d, ls = %d, shadow = { %d, %.2f }," % (
            key, g["T"], g["C"], g["Wc"], g["Ls"], shadow[0], shadow[1]))
        lines.append("          options = { %s }," % ", ".join('"%s"' % o for o in opts))
        lines.append("          mat = \"%s\", margin = %.3f, float = %s," % (inside[0], inside[1], "true" if inside[2] else "false"))
        lines.append("          pieces = {")
        for k in sorted(rects):
            lines.append("            %s = %s," % (k, lua_rect(rects[k])))
        lines.append("          } },")
    # the mat and the linen the drawings sit on inside their frames
    if not only:
        for name, bg, weave in (("mat", (246, 243, 236), False), ("linen", (226, 220, 206), True)):
            path = os.path.join(OUT, "%s.jpg" % name)
            Image.fromarray(instant_atlas(bg, weave)).save(path, quality=QUALITY, subsampling=0, optimize=True)
            total += os.path.getsize(path)
    # Instant Photo: a card, its paper from a tile
    s = INSTANT["sides"]
    if not only or "instant" in only:
        for o, bg, ink in INSTANT["options"]:
            tile = instant_atlas(bg)
            path = os.path.join(OUT, "instant-%s.jpg" % o)
            Image.fromarray(tile).save(path, quality=QUALITY, subsampling=0, optimize=True)
            total += os.path.getsize(path)
    lines.append("        { key = \"instant\", kind = \"card\", top = %d, left = %d, right = %d, bottom = %d, tile = %d, shadow = { 4, 0.30 }," % (
        s[0], s[1], s[2], s[3], INSTANT["tile"]))
    lines.append("          options = { %s }," % ", ".join('"%s"' % o for o, _, _ in INSTANT["options"]))
    lines.append("          ink = { %s } }," % ", ".join("%s = { %d, %d, %d }" % ((o,) + ink) for o, _, ink in INSTANT["options"]))
    lines.append("        { key = \"canvas\", kind = \"canvas\", options = { \"wrap\", \"white\", \"black\" } },")
    lines.append("    },")
    lines.append("    tiles = { mat = \"mat.jpg\", linen = \"linen.jpg\", size = %d }," % INSTANT["tile"])
    lines += ["}", ""]
    if not only:
        with open(os.path.join(OUT, "manifest.lua"), "w") as f:
            f.write("\n".join(lines))
    print("total %d KB" % (total // 1024))


if __name__ == "__main__":
    main()
