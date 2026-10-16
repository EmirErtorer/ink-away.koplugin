"""Picture frame renderer: a height field (moulding profile across the frame,
carving along it, ornaments at corners and side centres) lit by a studio
light from the top left, rendered at SS times the size and scaled down with
Lanczos so every edge is smooth. Heights are in border units (T)."""
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage as ndi

SS = 4
F32 = np.float32


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return a + (b - a) * t


# ----------------------------------------------------------------- geometry
class Frame:
    """Outer size W x H and border T in 1x px; arrays at SS resolution."""

    def __init__(self, W, H, T, ss=SS, unit=None):
        self.W, self.H, self.T, self.ss = W, H, T, ss
        self.unit = unit                                # T units every carving repeats in (pieces)
        w, h, t = W * ss, H * ss, T * ss
        self.w, self.h, self.t = w, h, t
        y, x = np.mgrid[0:h, 0:w].astype(F32) + 0.5
        dl, dr, dt, db = x, w - x, y, h - y
        d = np.minimum(np.minimum(dl, dr), np.minimum(dt, db))
        self.side = np.select([d == dt, d == db, d == dl], [0, 1, 2], 3).astype(np.int8)
        horiz = self.side <= 1
        self.x, self.y, self.d = x, y, d
        self.u = d / t
        self.along = np.where(horiz, x, y)
        self.len = np.where(horiz, F32(w), F32(h))
        self.a = (self.along - self.len / 2) / t       # T units from the side's middle
        self.cx = np.minimum(dl, dr) / t                # T units from the nearest left/right edge
        self.cy = np.minimum(dt, db) / t
        self.mask = d < t
        self.h_ = np.zeros((h, w), F32)                 # the height field, T units

    def band(self, a, b):
        """v in 0..1 across the band [a, b) of u, and its mask."""
        v = (self.u - a) / (b - a)
        return v, (self.u >= a) & (self.u < b)

    def cells(self, P, uc):
        """Position inside a repeat of period ~P (T units) along each side,
        -0.5..0.5, with a whole number of repeats between the mitres at u = uc,
        symmetric about each side's middle. Returns frac, effective period."""
        if self.unit:
            pe = self.unit / max(1, round(self.unit / P))
            c = self.a / pe
            return c - np.floor(c + 0.5), pe
        Lb = self.len / self.t - 2 * uc
        n = np.maximum(1, np.round(Lb / P))
        pe = Lb / n
        c = self.a / pe + np.where(n % 2 == 0, 0.5, 0.0)
        return c - np.floor(c + 0.5), pe

    # corner and side-centre tiles -------------------------------------
    def put_corners(self, th, op=np.maximum):
        """th: an (n, n) height tile for the top-left corner (rows = y)."""
        n = th.shape[0]
        H = self.h_
        H[:n, :n] = op(H[:n, :n], th)
        H[:n, -n:] = op(H[:n, -n:], th[:, ::-1])
        H[-n:, :n] = op(H[-n:, :n], th[::-1, :])
        H[-n:, -n:] = op(H[-n:, -n:], th[::-1, ::-1])

    def put_centres(self, th, op=np.maximum):
        """th: (rows across, cols along) tile for the top side's middle."""
        r, c = th.shape
        H = self.h_
        x0 = (self.w - c) // 2
        H[:r, x0:x0 + c] = op(H[:r, x0:x0 + c], th)
        H[-r:, x0:x0 + c] = op(H[-r:, x0:x0 + c], th[::-1, :])
        tt = th.T
        y0 = (self.h - c) // 2
        H[y0:y0 + c, :r] = op(H[y0:y0 + c, :r], tt)
        H[y0:y0 + c, -r:] = op(H[y0:y0 + c, -r:], tt[:, ::-1])

    def put_corners_rgb(self, img, n):
        """Same placement for a colour/material layer (n, n, k)."""
        pass


# ------------------------------------------------------------ profile parts
def prof(F, pieces, default=0.0):
    """pieces: list of (a, b, fn(v)) with v 0..1 across [a, b) of u."""
    h = np.full(F.u.shape, default, F32)
    for a, b, fn in pieces:
        v, m = F.band(a, b)
        h = np.where(m, fn(np.clip(v, 0, 1)), h)
    return h


def flat(h):
    return lambda v: np.full(v.shape, h, F32)


def slope(h0, h1):
    return lambda v: h0 + (h1 - h0) * smooth(0, 1, v)


def lin(h0, h1):
    return lambda v: h0 + (h1 - h0) * v


def bead(base, amp):
    return lambda v: base + amp * np.sqrt(np.clip(1 - (2 * v - 1) ** 2, 0, 1))


def torus(h0, h1, amp):
    """a convex roll rising from h0 to h1 across, bulging by amp."""
    return lambda v: h0 + (h1 - h0) * v + amp * np.sqrt(np.clip(1 - (2 * v - 1) ** 2, 0, 1))


def cove(h0, h1, depth):
    return lambda v: h0 + (h1 - h0) * v - depth * np.sin(v * math.pi)


def ogee(h0, h1):
    return lambda v: h0 + (h1 - h0) * (0.5 - 0.5 * np.cos(v * math.pi))


# --------------------------------------------------------------- noise
_rng = np.random.default_rng(7)
_LAT = _rng.random((256, 256)).astype(F32)


def noise(xx, yy, seed=0):
    """smooth value noise, period 256 lattice units"""
    off = (seed * 37.17) % 256
    return ndi.map_coordinates(_LAT, [(yy + off) % 256, (xx + off * 1.7) % 256], order=3, mode="grid-wrap").astype(F32)


# The length in px (at SS) every texture repeats in along the frame's sides,
# when the frame is cut into tiling pieces (see export.py); None for a picture.
PERIOD = None


def qp(p):
    """period p (px) snapped so a whole number of them fits PERIOD"""
    if not PERIOD:
        return p
    return PERIOD / max(1, round(PERIOD / p))


def _lat(seed, nu, nv):
    lat = np.roll(np.roll(_LAT, (seed * 53) % 256, 0), (seed * 91) % 256, 1)[:nv, :nu]
    ru, rv = max(1, -(-8 // nu)), max(1, -(-8 // nv))
    return np.tile(lat, (rv, ru))


def pn(xp, yp, sx, sy, seed=0, octaves=1, perx=True, pery=True):
    """smooth noise (fbm) over px coordinates with feature sizes sx, sy px,
    repeating every PERIOD px along x and y (when asked) so strips tile"""
    out = np.zeros(np.shape(xp), F32)
    a, tot = 1.0, 0.0
    for o in range(octaves):
        sxo, syo = sx / 2 ** o, sy / 2 ** o
        nu = nv = 256
        if PERIOD and perx and PERIOD / sxo <= 256:
            nu = max(1, round(PERIOD / sxo)); sxo = PERIOD / nu
        if PERIOD and pery and PERIOD / syo <= 256:
            nv = max(1, round(PERIOD / syo)); syo = PERIOD / nv
        lat = _lat(seed + o * 7, nu, nv)
        hu, hv = lat.shape[1], lat.shape[0]
        out += a * ndi.map_coordinates(lat, [(yp / syo) % hv, (xp / sxo) % hu], order=3, mode="grid-wrap").astype(F32)
        tot += a
        a *= 0.5
    return out / tot


def fbm(xx, yy, octaves=4, seed=0):
    s, a, tot = 1.0, 1.0, 0.0
    out = np.zeros(xx.shape, F32)
    for o in range(octaves):
        out += a * noise(xx * s, yy * s, seed + o)
        tot += a
        s *= 2.03
        a *= 0.5
    return out / tot


# -------------------------------------------------------------- tiles
class Tile:
    """A square or rectangular scratch canvas at SS res for ornaments."""

    def __init__(self, w, h=None):
        self.w, self.h = int(w), int(h or w)
        y, x = np.mgrid[0:self.h, 0:self.w].astype(F32) + 0.5
        self.x, self.y = x, y
        self.z = np.zeros((self.h, self.w), F32)

    def mask_poly(self, pts):
        im = Image.new("L", (self.w, self.h), 0)
        ImageDraw.Draw(im).polygon([tuple(p) for p in pts], fill=255)
        return np.asarray(im, F32) / 255

    def mask_line(self, pts, width):
        im = Image.new("L", (self.w, self.h), 0)
        dr = ImageDraw.Draw(im)
        pts = [tuple(p) for p in pts]
        if np.isscalar(width):
            dr.line(pts, fill=255, width=int(round(width)), joint="curve")
            r = width / 2
            for p in (pts[0], pts[-1]):
                dr.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=255)
        else:
            for i in range(len(pts) - 1):
                r = width[i] / 2
                dr.ellipse([pts[i][0] - r, pts[i][1] - r, pts[i][0] + r, pts[i][1] + r], fill=255)
                dr.line([pts[i], pts[i + 1]], fill=255, width=max(1, int(round(width[i]))))
            r = width[-1] / 2
            p = pts[-1]
            dr.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=255)
        return np.asarray(im, F32) / 255

    def mask_ellipse(self, cx, cy, rx, ry):
        return ((((self.x - cx) / rx) ** 2 + ((self.y - cy) / ry) ** 2) < 1).astype(F32)


def inflate(m, r, power=0.5):
    """pillow a 0/1 mask into a rounded relief of height 1 at depth r px"""
    e = ndi.distance_transform_edt(m > 0.5).astype(F32)
    t = np.clip(e / r, 0, 1)
    return (1 - (1 - t) ** 2) ** power * (m > 0.5)


def blur(a, s):
    return ndi.gaussian_filter(a, s).astype(F32)


def bez(p, n=64):
    """points along a cubic (4 pts) or quadratic (3 pts) bezier"""
    p = np.asarray(p, F32)
    t = np.linspace(0, 1, n, dtype=F32)[:, None]
    if len(p) == 3:
        return (1 - t) ** 2 * p[0] + 2 * (1 - t) * t * p[1] + t * t * p[2]
    return (1 - t) ** 3 * p[0] + 3 * (1 - t) ** 2 * t * p[1] + 3 * (1 - t) * t * t * p[2] + t ** 3 * p[3]


def spiral(cx, cy, r0, r1, a0, turns, n=80, cw=True):
    t = np.linspace(0, 1, n, dtype=F32)
    r = r0 + (r1 - r0) * t
    a = a0 + (1 if cw else -1) * turns * 2 * math.pi * t
    return np.stack([cx + r * np.cos(a), cy + r * np.sin(a)], 1)


def offset_poly(sp, widths):
    """outline polygon around a spine sp (n,2) with half widths (n,)"""
    d = np.gradient(sp, axis=0)
    d /= np.linalg.norm(d, axis=1, keepdims=True) + 1e-6
    nrm = np.stack([-d[:, 1], d[:, 0]], 1)
    left = sp + nrm * widths[:, None]
    right = sp - nrm * widths[:, None]
    return np.concatenate([left, right[::-1]]), nrm


def leaf(tile, spine, wmax, lobes=4, lobe_depth=0.35, height=1.0, round_r=None, vein=0.25, curl=None):
    """An acanthus-like leaf along `spine` (n,2 px): lobed outline, inflated,
    with a midrib groove and side veins. Returns height (tile units, 0..height)."""
    n = len(spine)
    t = np.linspace(0, 1, n, dtype=F32)
    env = np.clip(np.sin(np.clip(t, 0, 1) * math.pi), 0, 1) ** 0.7 * (1 - 0.35 * t)
    lob = 1 - lobe_depth * (1 - np.abs(np.cos(t * lobes * math.pi))) ** 1.5
    w = wmax * env * lob + 0.6
    poly, nrm = offset_poly(spine, w)
    m = tile.mask_poly(poly)
    r = round_r or wmax * 0.9
    hh = inflate(m, r, 0.6) * height
    # midrib groove
    g = tile.mask_line(spine[int(n * 0.05):int(n * 0.9)], max(1.5, wmax * 0.12))
    hh -= blur(g, max(1, wmax * 0.06)) * vein * height
    # side veins to the lobe tips
    for k in range(1, lobes + 1):
        tk = (k - 0.5) / lobes
        i = min(n - 1, int(tk * n))
        for sgn in (1, -1):
            a = spine[i]
            b = spine[min(n - 1, i + n // (lobes * 3))] + sgn * nrm[i] * w[i] * 0.85
            vm = tile.mask_line(np.stack([a, b]), max(1.2, wmax * 0.07))
            hh -= blur(vm, max(1, wmax * 0.05)) * vein * 0.6 * height
    return np.maximum(hh, 0) * (m > 0.5)


# ------------------------------------------------------------- lighting
L = np.array([-0.48, -0.62, 0.62], F32)
L /= np.linalg.norm(L)
HV = L + np.array([0, 0, 1], F32)
HV /= np.linalg.norm(HV)


def normals(hpx):
    gy, gx = np.gradient(hpx)
    nz = 1 / np.sqrt(gx * gx + gy * gy + 1)
    return (-gx * nz).astype(F32), (-gy * nz).astype(F32), nz.astype(F32)


def occlusion(hpx, t, strength=1.0):
    a = 0
    for s, k in ((0.04, 0.5), (0.12, 0.35), (0.3, 0.25)):
        a = a + k * np.clip((blur(hpx, s * t) - hpx) / (0.05 * t), 0, 2.5)
    return np.clip(1 - 0.38 * strength * a, 0.2, 1).astype(F32)


def env_metal(nx, ny, nz):
    rx, ry = 2 * nz * nx, 2 * nz * ny
    key = np.exp(-((rx + 0.45) ** 2 + (ry + 0.55) ** 2) / 0.09)
    band = np.exp(-((0.6 * rx + 0.8 * ry + 0.25) ** 2) / 0.012) * 0.35
    fill = np.exp(-((rx - 0.55) ** 2 + (ry - 0.5) ** 2) / 0.06) * 0.28
    base = 0.50 + 0.26 * np.clip(-(0.6 * rx + 0.8 * ry), -1, 1)
    return (base + 0.75 * key + band + fill).astype(F32)


def ramp(t, stops):
    """stops: list of (t, (r,g,b)) 0..255"""
    ts = np.array([s[0] for s in stops], F32)
    cs = np.array([s[1] for s in stops], F32) / 255
    out = np.empty(t.shape + (3,), F32)
    for k in range(3):
        out[..., k] = np.interp(t, ts, cs[:, k])
    return out


GOLD = [(0.0, (34, 20, 6)), (0.22, (98, 62, 18)), (0.45, (170, 122, 42)), (0.68, (222, 178, 86)),
        (0.88, (250, 226, 150)), (1.1, (255, 248, 222))]
PALE_GOLD = [(0.0, (40, 30, 12)), (0.22, (110, 86, 40)), (0.45, (180, 150, 86)), (0.68, (226, 202, 140)),
             (0.88, (248, 236, 190)), (1.1, (255, 252, 236))]
SILVER = [(0.0, (22, 24, 28)), (0.22, (78, 82, 90)), (0.45, (150, 154, 160)), (0.68, (205, 208, 212)),
          (0.88, (238, 240, 242)), (1.1, (255, 255, 255))]
BRONZE = [(0.0, (26, 16, 8)), (0.22, (74, 46, 22)), (0.45, (136, 92, 48)), (0.68, (186, 140, 86)),
          (0.88, (226, 196, 150)), (1.1, (250, 236, 210))]
BRASS = [(0.0, (30, 24, 10)), (0.22, (96, 78, 34)), (0.45, (168, 142, 72)), (0.68, (214, 192, 120)),
         (0.88, (242, 230, 176)), (1.1, (255, 252, 232))]


class Ctx:
    def __init__(self, F, hpx, extra_ao=None):
        self.F = F
        self.hpx = hpx
        self.nx, self.ny, self.nz = normals(hpx)
        self.ao = occlusion(hpx, F.t)
        self.diff = np.clip(self.nx * L[0] + self.ny * L[1] + self.nz * L[2], 0, 1).astype(F32)
        self.spec_dot = np.clip(self.nx * HV[0] + self.ny * HV[1] + self.nz * HV[2], 0, 1).astype(F32)
        # curvature: positive on ridges (worn high points)
        self.curv = (-ndi.laplace(blur(hpx, 0.01 * F.t + 0.6))).astype(F32)


def metal(c, stops, antique=0.0, patina=(52, 36, 18), bole=0.0, rough=0.0, seed=1):
    e = env_metal(c.nx, c.ny, c.nz)
    if rough:
        e = mix(e, 0.40 + 0.5 * c.diff, rough)
    col = ramp(e, stops)
    col *= (0.5 + 0.5 * c.ao)[..., None]
    if antique:
        pat = np.array(patina, F32) / 255
        k = np.clip((1 - c.ao) * 1.6, 0, 1) * antique
        nz = pn(c.F.x, c.F.y, 0.35 * c.F.t, 0.35 * c.F.t, seed, 3)
        k = np.clip(k + (nz - 0.5) * 0.25 * antique, 0, 1)
        col = mix(col, pat * (0.6 + 0.6 * col.mean(-1, keepdims=True)), k[..., None])
    if bole:
        wear = np.clip(c.curv * 3.0, 0, 1) * (pn(c.F.x, c.F.y, 0.08 * c.F.t, 0.08 * c.F.t, seed + 9, 3) > 0.62)
        col = mix(col, np.array([0.55, 0.22, 0.12], F32) * (0.5 + 0.5 * c.diff[..., None]), (wear * bole)[..., None])
    return col


def lacquer(c, base, gloss=0.9, sharp=1.0, amb=0.30):
    base = np.asarray(base, F32) / 255 if not isinstance(base, np.ndarray) else base
    d = (amb + 0.85 * c.diff) * (0.45 + 0.55 * c.ao)
    col = base * d[..., None]
    rx, ry = 2 * c.nz * c.nx, 2 * c.nz * c.ny
    w = 0.05 / sharp
    refl = np.exp(-((rx + 0.45) ** 2 + (ry + 0.55) ** 2) / (w * 1.6)) * 0.9 + \
        np.exp(-((0.6 * rx + 0.8 * ry + 0.3) ** 2) / (w * 0.2)) * 0.18
    fres = 0.06 + 0.25 * (1 - c.nz) ** 2
    col = col + ((refl + fres) * gloss * c.ao)[..., None]
    return col


def matte(c, base, amb=0.42, kd=0.75, spec=0.06, shine=20):
    base = np.asarray(base, F32) / 255 if not isinstance(base, np.ndarray) else base
    if base.ndim == 1:
        base = base[None, None, :]
    d = (amb + kd * c.diff) * (0.4 + 0.6 * c.ao)
    col = base * d[..., None] + (spec * c.spec_dot ** shine * c.ao)[..., None]
    return col


# ---------------------------------------------------------------- wood
def grain_coords(F, seed=0):
    """(along, across) px coordinates for each mitred piece's grain"""
    al = F.along + F.side.astype(F32) * 731.0 + seed * 113
    ac = F.d
    return al, ac


def wood_tex(F, light, dark, ring=0.11, warp=2.2, pores=0.18, figure=0.0, seed=0, al=None, ac=None):
    """colour (h,w,3) 0..1 of planed wood, grain running along each piece:
    thin latewood lines that drift slowly, fine pore streaks, broad tone
    variation; low contrast like real timber"""
    if al is None:
        al, ac = grain_coords(F, seed)
    t = F.t
    # the growth rings cut at a slant: lines along the piece, drifting
    drift = pn(al, ac, 5.0 * t, 0.9 * t, seed + 3, 3, pery=False) - 0.5
    cath = pn(al, ac, 1.6 * t, 2.5 * t, seed + 4, 2, pery=False) - 0.5
    g = ac / (ring * t) + warp * 2.5 * drift + 1.4 * np.abs(cath) * (ac / t) * 0
    g = g + 2.0 * cath
    fr = g - np.floor(g)
    late = np.exp(-((fr - 0.5) / 0.11) ** 2)          # the dark latewood line
    early = smooth(0.0, 0.5, fr) * smooth(1.0, 0.5, fr)
    # fine pores: long, very thin streaks
    pore = pn(al, ac, 0.45 * t, 0.0045 * t, seed + 7, pery=False)
    streak = np.clip((pore - 0.55) * 3, 0, 1)
    tone = pn(al, ac, 2.0 * t, 0.6 * t, seed + 9, 3, pery=False)
    v = 0.62 + 0.18 * (tone - 0.5) * 2 - 0.30 * late - pores * 0.9 * streak + 0.06 * early
    if figure:
        rays = pn(al, ac, 0.18 * t, 0.025 * t, seed + 11, pery=False)
        v = v + figure * 0.6 * np.clip(rays - 0.66, 0, 1) * 3
    light = np.array(light, F32) / 255
    dark = np.array(dark, F32) / 255
    return mix(dark, light, np.clip(v, 0, 1)[..., None])


def mitre_seam(F, width_px=0.7):
    s = np.abs(F.cx - F.cy) * F.t
    return (np.exp(-(s / (width_px * F.ss)) ** 2) * (F.mask)).astype(F32)


# ------------------------------------------------------------ composing
def to_img(rgb):
    a = np.clip(rgb * 255 + 0.5, 0, 255).astype(np.uint8)
    return Image.fromarray(a, "RGB")


def down(img, W, H):
    return img.resize((W, H), Image.LANCZOS)


def inner_shadow(img, box, depth, strength=0.55, light=(1, 1)):
    """darken the picture/mat inside box (x,y,w,h) near the frame's top/left
    sight edges, as the frame's lip shades it"""
    W, H = img.size
    x, y, w, h = box
    m = np.ones((H, W), F32)
    m[y:y + h, x:x + w] = 0
    sh = np.roll(np.roll(m, int(depth * 0.5 * light[1]), 0), int(depth * 0.5 * light[0]), 1)
    sh = blur(np.maximum(sh, m), depth * 0.6)
    a = np.asarray(img, F32) / 255
    k = 1 - strength * sh
    inside = np.zeros((H, W), bool)
    inside[y:y + h, x:x + w] = True
    a = np.where(inside[..., None], a * k[..., None], a)
    return to_img(a)


def load_font(size, italic=False, serif=True):
    import os
    base = "/Users/emirertorer/koreader-emulator"
    import glob
    pats = ["NotoSerif-Italic.ttf"] if italic else (["NotoSerif-Regular.ttf"] if serif else ["NotoSans-Regular.ttf"])
    for p in pats:
        g = glob.glob(base + "/**/fonts/**/" + p, recursive=True)
        if g:
            return ImageFont.truetype(g[0], size)
    return ImageFont.load_default()


def cast_shadow(hpx, reach_px, soft_px, steps=28):
    """0..1 shadow from the light at the top left over a height field (px)"""
    lxy = math.hypot(L[0], L[1])
    dx, dy = L[0] / lxy, L[1] / lxy
    slope = L[2] / lxy
    occ = np.zeros(hpx.shape, F32)
    for i in range(1, steps + 1):
        k = reach_px * i / steps
        ox, oy = int(round(-dx * k)), int(round(-dy * k))
        # the height at (x + dx*k, y + dy*k): shift the array the other way
        sh = np.roll(np.roll(hpx, ox, 1), oy, 0)
        if ox > 0:
            sh[:, :ox] = hpx[:, :1]
        if oy > 0:
            sh[:oy, :] = hpx[:1, :]
        over = (sh - hpx - k * slope) / (0.02 * reach_px + 1)
        occ = np.maximum(occ, np.clip(over, 0, 1))
    return blur(occ, soft_px)


def grey(img):
    return img.convert("L").convert("RGB")
