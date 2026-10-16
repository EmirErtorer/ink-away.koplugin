"""The twelve frames. Each design is fn(W, H, option) -> (frame RGB image at
1x with the opening filled by `fill`, opening box (x, y, w, h) at 1x)."""
import math
import numpy as np
from fr import *  # noqa


# ---------------------------------------------------------------- carving kit
def pearls(F, a, b, P, base, amp, reel=True):
    """bead-and-reel in band [a, b)"""
    v, m = F.band(a, b)
    f, pe = F.cells(P, (a + b) / 2)
    bw = (b - a)
    # pearl: ellipse dome in T units
    x = f * pe / (0.36 * pe if not reel else 0.26 * pe)
    yv = (v - 0.5) * 2 / 0.92
    r2 = x * x + yv * yv
    h = base + amp * np.sqrt(np.clip(1 - r2, 0, 1))
    if reel:
        # reels between pearls: a thin double disc
        g = (np.abs(f) - 0.5) * pe  # T units from the cell edge (negative inside)
        rx = (np.abs(np.abs(f) - 0.5) * pe) / (0.12 * pe)
        reel_h = base + amp * 0.75 * np.sqrt(np.clip(1 - rx ** 2, 0, 1)) * np.sqrt(np.clip(1 - (yv * 1.25) ** 2, 0, 1))
        reel_h -= amp * 0.35 * np.exp(-((np.abs(np.abs(f) - 0.5) * pe) / (0.012 * pe + 1e-4)) ** 2 * 0.05)
        h = np.maximum(h, reel_h)
    return np.where(m, h, 0), m


def egg_dart(F, a, b, P, base, amp):
    v, m = F.band(a, b)
    f, pe = F.cells(P, (a + b) / 2)
    xe = f / 0.30
    ye = (v - 0.55) / 0.40
    r2 = xe * xe + ye * ye
    egg = amp * np.sqrt(np.clip(1 - r2, 0, 1))
    # the shell around the egg: a raised rim with a cup inside
    rim_r2 = (f / 0.42) ** 2 + ((v - 0.5) / 0.50) ** 2
    rim = amp * 0.7 * np.exp(-((np.sqrt(rim_r2) - 0.92) / 0.09) ** 2)
    cup = -amp * 0.35 * ((r2 > 1) & (rim_r2 < 0.85))
    # the dart: a pointed ridge at the cell edge, pointing inward (v up)
    g = np.abs(np.abs(f) - 0.5)
    dart_w = 0.10 * np.clip(1 - v, 0, 1) + 0.015
    dart = amp * 0.75 * np.clip(1 - g / dart_w, 0, 1) ** 0.6 * (v > 0.12)
    h = base + np.maximum(np.maximum(egg, rim + cup), dart)
    return np.where(m, h, 0), m


def leaf_and_tongue(F, a, b, P, torus_fn, amp):
    """overlapping acanthus leaves lying along a roll, pointing to the middle
    of each side"""
    v, m = F.band(a, b)
    f, pe = F.cells(P, (a + b) / 2)
    f = f * np.sign(F.a + 1e-6)          # all point toward the side's middle
    base = torus_fn(np.clip(v, 0, 1))
    s = f + 0.5                           # 0 at the leaf's back, 1 at its tip
    # half width across the band: broad at the back, a point at the tip,
    # with three lobes
    env = np.clip(np.sin(np.clip(s * 1.05, 0, 1) * math.pi * 0.92 + 0.25), 0, 1)
    lob = 1 - 0.22 * (1 - np.abs(np.cos(s * 3.0 * math.pi))) ** 1.6
    hw = 0.50 * env * lob
    d = np.abs(v - 0.5)
    inside = d < hw
    # each leaf rises toward its tip, so it lies over the next leaf's back
    rise = amp * (0.25 + 0.75 * s) * np.sqrt(np.clip(1 - (d / (hw + 1e-3)) ** 2, 0, 1))
    rib = amp * 0.45 * np.exp(-(d / 0.035) ** 2) * (s > 0.08) * (s < 0.92)
    veins = 0
    for k in (0.25, 0.55, 0.82):
        line = np.abs((s - k) - (d * 0.9))
        veins = veins + np.exp(-(line / 0.03) ** 2) * (d < hw * 0.9)
    h = base + np.where(inside, rise - rib * 0.6 - amp * 0.35 * veins, -amp * 0.18)
    return np.where(m, h, 0), m


def laurel(F, a, b, P, torus_fn, amp, ang=0.42, ribbon_every=0):
    """overlapping laurel leaves in pairs along a roll, pointing to each
    side's middle (heights in T)"""
    v, m = F.band(a, b)
    f, pe = F.cells(P, (a + b) / 2)
    sg = np.sign(F.a + 1e-6)
    bw = b - a
    X = f * pe * sg                       # T units along, + toward the middle
    Y = (v - 0.5) * bw                    # T units across
    base = torus_fn(np.clip(v, 0, 1))
    Ll, Wl = pe * 1.55, bw * 0.40
    best = np.full(X.shape, -1.0, F32)
    for k in (-1, 0, 1):
        for side in (-1, 1):
            cx, cy = k * pe - 0.10 * pe, side * bw * 0.20
            ca, sa = math.cos(side * -ang), math.sin(side * -ang)
            dx, dy = X - cx, Y - cy
            p = dx * ca - dy * sa
            q = dx * sa + dy * ca
            s_ = p / Ll + 0.5             # 0 at the stalk, 1 at the tip
            hw = Wl / 2 * np.clip(np.sin(np.clip(s_, 0, 1) * math.pi), 0, 1) ** 0.75
            ins = (s_ > 0) & (s_ < 1) & (np.abs(q) < hw)
            qq = np.abs(q) / (hw + 1e-4)
            hh = amp * (0.35 + 0.65 * s_) * np.sqrt(np.clip(1 - qq * qq, 0, 1))
            hh = hh - amp * 0.30 * np.exp(-(q / (0.05 * Wl)) ** 2)      # midrib
            best = np.where(ins, np.maximum(best, hh), best)
    h = base + np.where(best >= 0, best, -amp * 0.25)
    return np.where(m, h, 0), m


def gadroons(F, a, b, P, base_fn, amp, twist=0.6):
    v, m = F.band(a, b)
    pe = F.cells(P, (a + b) / 2)[1]
    sg = np.sign(F.a + 1e-6)
    c = (F.a * sg) / pe + twist * v
    f = c - np.floor(c + 0.5)
    h = base_fn(np.clip(v, 0, 1)) + amp * np.sqrt(np.clip(1 - (2 * f) ** 2, 0, 1)) - amp * 0.6
    return np.where(m, h, 0), m


def shell(tile, cx, cy, dirx, diry, R, ribs=11, spread=1.1, h0=0.2, h1=0.32, rib_amp=0.06, T=1.0, boss=False):
    """a scallop shell fanning from (cx, cy) toward (dirx, diry); heights in T"""
    dx, dy = tile.x - cx, tile.y - cy
    r = np.sqrt(dx * dx + dy * dy)
    ang = np.arctan2(dy, dx) - math.atan2(diry, dirx)
    ang = (ang + math.pi) % (2 * math.pi) - math.pi
    q = ang / spread                       # -1..1 across the fan
    edge = R * (1 - 0.07 * (1 - np.abs(np.cos(q * ribs * math.pi / 2))) ** 0.7) * (1 - 0.15 * q * q)
    inside = (np.abs(q) < 1) & (r < edge)
    rr = np.clip(r / edge, 0, 1)
    dome = h0 + h1 * np.sqrt(np.clip(1 - rr ** 1.6, 0, 1)) * (1 - 0.25 * q * q)
    rib = np.abs(np.cos(q * ribs * math.pi / 2)) ** 0.6
    hh = dome + rib_amp * rib * rr ** 0.5 - 0.025 * (1 - rr)
    # a rolled lip at the scalloped edge
    lip = 0.04 * np.exp(-((edge - r) / (0.05 * R)) ** 2)
    hh = hh + lip
    # the hinge: a small boss
    if boss:
        b_ = 0.06 * np.sqrt(np.clip(1 - (r / (0.2 * R)) ** 2, 0, 1))
        return np.where(inside | (r < 0.2 * R), np.maximum(hh, h0 + h1 * 0.95 + b_), 0).astype(F32)
    return np.where(inside, hh, 0).astype(F32)


def scroll(tile, cx, cy, r0, r1, a0, turns, width, height, cw=True):
    pts = spiral(cx, cy, r0, r1, a0, turns, 90, cw)
    wv = np.linspace(width * 0.45, width, len(pts))
    m = tile.mask_line(pts, wv)
    return inflate(m, width * 0.5, 0.5) * height


def place(tile_h, tile, F, clip_inner=True):
    """clip an ornament tile to the frame (not into the opening)"""
    if clip_inner:
        inner = np.minimum(tile.x, tile.y) < F.t * 0.985
        tile_h = tile_h * inner
    return tile_h


# ------------------------------------------------------------- picture fill
def compose(frame_img, pic, box, frame_alpha=None, shadow=0.55, depth=None):
    x, y, w, h = box
    out = frame_img.copy()
    p = pic.convert("RGB").resize((w, h), Image.LANCZOS)
    out.paste(p, (x, y))
    return inner_shadow(out, box, depth or max(4, w * 0.03), shadow)


def opening_box(W, H, T):
    return (T, T, W - 2 * T, H - 2 * T)


# =============================================================== 1. Baroque
def baroque(W, H, opt="gold", T=None, unit=None):
    T = T or round(W * 0.155)
    F = Frame(W, H, T, unit=unit)
    t = F.t
    roll = torus(0.17, 0.22, 0.20)
    h = prof(F, [
        (0.00, 0.05, ogee(0.02, 0.12)),
        (0.05, 0.14, flat(0.12)),
        (0.14, 0.50, roll),
        (0.50, 0.68, cove(0.22, 0.16, 0.07)),
        (0.68, 0.80, flat(0.13)),
        (0.80, 0.87, ogee(0.12, 0.10)),
        (0.87, 0.95, flat(0.07)),
        (0.95, 1.00, slope(0.06, 0.0)),
    ], -0.03)
    hp, m = pearls(F, 0.05, 0.14, 0.085, 0.10, 0.05)
    h = np.where(m, hp, h)
    hl, m = laurel(F, 0.14, 0.50, 0.17, roll, 0.075)
    h = np.where(m, hl, h)
    he, m = egg_dart(F, 0.68, 0.80, 0.11, 0.11, 0.045)
    h = np.where(m, he, h)
    hb, m = pearls(F, 0.87, 0.95, 0.045, 0.06, 0.03, reel=False)
    h = np.where(m, hb, h)
    F.h_ = h.astype(F32)

    # the corner: a shell on the diagonal, leaves sweeping along both sides,
    # scrolls at the outer corner
    n = int(1.75 * t)
    tl = Tile(n)
    orn = shell(tl, 0.86 * t, 0.86 * t, -1, -1, 0.68 * t, ribs=11, spread=0.95, h0=0.30, h1=0.30, rib_amp=0.11)
    for sw in (False, True):
        sp = bez([(0.62 * t, 0.36 * t), (0.95 * t, 0.18 * t), (1.30 * t, 0.42 * t), (1.66 * t, 0.30 * t)], 90)
        lf = leaf(tl, sp if not sw else sp[:, ::-1], 0.15 * t, lobes=4, lobe_depth=0.45, vein=0.18)
        lf = np.where(lf > 0, 0.40 + 0.20 * lf, 0)
        cur = scroll(tl, 1.60 * t, 0.36 * t, 0.02 * t, 0.10 * t, 0.0, 1.0, 0.07 * t, 0.12)
        cur = np.where(cur > 0, 0.44 + cur, 0)
        if sw:
            cur = cur.T
        orn = np.maximum(orn, np.maximum(lf, cur))
    # little leaf into the inner corner
    sp = bez([(0.98 * t, 0.98 * t), (1.10 * t, 1.10 * t), (1.25 * t, 1.25 * t)], 40)
    lf = leaf(tl, sp, 0.08 * t, lobes=2, lobe_depth=0.3, vein=0.2)
    orn = np.maximum(orn, np.where(lf > 0, 0.12 + 0.12 * lf, 0))
    # volutes at the outer corner
    for sw in (False, True):
        sc = scroll(tl, 0.36 * t, 0.16 * t, 0.015 * t, 0.085 * t, math.pi, 1.1, 0.06 * t, 0.10, cw=False)
        sc = np.where(sc > 0, 0.30 + sc, 0)
        orn = np.maximum(orn, sc.T if sw else sc)
    orn = place(orn, tl, F)
    F.put_corners(orn)

    # side centres: a smaller shell with leaves either way
    cw_, ch_ = int(2.4 * t), int(0.98 * t)
    tc = Tile(cw_, ch_)
    mid = cw_ / 2
    orn = shell(tc, mid, 0.70 * t, 0, -1, 0.58 * t, ribs=11, spread=1.15, h0=0.30, h1=0.28, rib_amp=0.10)
    for sgn in (-1, 1):
        sp = bez([(mid + sgn * 0.30 * t, 0.42 * t), (mid + sgn * 0.62 * t, 0.20 * t),
                  (mid + sgn * 0.90 * t, 0.46 * t), (mid + sgn * 1.15 * t, 0.32 * t)], 80)
        lf = leaf(tc, sp, 0.12 * t, lobes=3, lobe_depth=0.45, vein=0.18)
        orn = np.maximum(orn, np.where(lf > 0, 0.40 + 0.18 * lf, 0))
    F.put_centres(orn)

    # gesso texture
    F.h_ += 0.0007 * pn(F.x, F.y, 0.02 * t, 0.02 * t, 3, 2)
    hpx = F.h_ * t
    c = Ctx(F, hpx)
    if opt == "gold":
        col = metal(c, GOLD, antique=0.35, bole=0.0)
    elif opt == "antique":
        col = metal(c, BRONZE if False else GOLD, antique=0.85, patina=(58, 40, 20), bole=0.5)
        lum = col.mean(-1, keepdims=True)
        col = mix(col, lum * np.array([1.05, 0.92, 0.70], F32), 0.45) * 0.95
    else:
        col = metal(c, SILVER, antique=0.45, patina=(40, 38, 34))
    img = down(to_img(col), W, H)
    return img, opening_box(W, H, T)


# ------------------------------------------------------------ more carving
def ribbon_twist(F, a, b, P, rod_h, amp, turns=1.0):
    """a rod with a ribbon wound round it"""
    v, m = F.band(a, b)
    pe = F.cells(P, (a + b) / 2)[1]
    sg = np.sign(F.a + 1e-6)
    rod = rod_h + amp * 1.4 * np.sqrt(np.clip(1 - (2 * v - 1) ** 2, 0, 1))
    c = (F.a * sg) / pe + turns * v
    f = c - np.floor(c + 0.5)
    band = np.abs(f) < 0.26
    edge = np.clip(1 - (np.abs(f) / 0.26) ** 6, 0, 1)
    rib = amp * 0.55 * edge * np.sqrt(np.clip(1 - (2 * v - 1) ** 2, 0, 1)) + amp * 0.12
    h = np.where(band, rod + rib, rod - amp * 0.15)
    return np.where(m, h, 0), m, band & m


def stiff_leaves(F, a, b, P, base, amp, tip_inner=True):
    """upright water leaves with pointed tips, darts between"""
    v, m = F.band(a, b)
    f, pe = F.cells(P, (a + b) / 2)
    vv = v if tip_inner else 1 - v
    hw = 0.44 * np.clip(1 - vv, 0, 1) ** 0.55 * np.clip(vv * 6, 0, 1) ** 0.3
    ins = np.abs(f) < hw
    q = np.abs(f) / (hw + 1e-4)
    leafh = amp * (0.5 + 0.5 * vv) * np.sqrt(np.clip(1 - q * q, 0, 1)) - amp * 0.35 * np.exp(-(f / 0.04) ** 2)
    edge = amp * 0.25 * np.exp(-((q - 0.85) / 0.12) ** 2) * ins
    g = np.abs(np.abs(f) - 0.5)
    dart = amp * 0.55 * np.clip(1 - g / (0.06 * np.clip(1 - vv, 0, 1) + 0.01), 0, 1) * (vv < 0.75)
    h = base + np.where(ins, leafh + edge, np.maximum(dart, -amp * 0.15))
    return np.where(m, h, 0), m


def ripple(F, a, b, P, base_fn, amp, wave=0.0, zig=0.0):
    """Dutch ripple moulding: corrugations across the moulding"""
    v, m = F.band(a, b)
    pe = F.cells(P, (a + b) / 2)[1]
    c = F.a / pe + wave * np.sin(v * 2 * math.pi) + zig * np.abs(v - 0.5)
    h = base_fn(np.clip(v, 0, 1)) + amp * np.sin(c * 2 * math.pi)
    return np.where(m, h, 0), m


def rosette(tile, cx, cy, R, petals=8, h0=0.0, h1=0.12):
    dx, dy = tile.x - cx, tile.y - cy
    r = np.sqrt(dx * dx + dy * dy) / R
    th = np.arctan2(dy, dx)
    pet = np.abs(np.cos(th * petals / 2)) ** 0.7
    outline = 0.72 + 0.28 * pet
    ins = r < outline
    hh = h0 + h1 * np.sqrt(np.clip(1 - (r / outline) ** 2, 0, 1)) * (0.75 + 0.25 * pet)
    hh = hh - h1 * 0.25 * (1 - pet) * (r > 0.3)                 # the creases between petals
    inner = r < 0.45
    hh = np.where(inner, h0 + h1 * 0.9 + h1 * 0.25 * np.abs(np.cos(th * petals)) ** 0.8 * (r > 0.22), hh)
    button = h0 + h1 * 1.25 + h1 * 0.35 * np.sqrt(np.clip(1 - (r / 0.22) ** 2, 0, 1))
    hh = np.where(r < 0.22, button, hh)
    return np.where(ins, hh, 0).astype(F32)


def step(F, a, b, h, ch=0.012):
    """a flat step with small chamfers at both edges (heights in T)"""
    def fn(v):
        bw = b - a
        e = np.minimum(v, 1 - v) * bw
        crown = 0.012 * np.sin(np.clip(v, 0, 1) * math.pi)
        return h + crown - 0.04 * np.clip(1 - e / ch, 0, 1) ** 2
    return (a, b, fn)


def finish(F, col):
    return down(to_img(col), F.W, F.H)


def edge_round(F, h, r=0.04):
    """round the frame's outer edge down a little"""
    return h - 0.05 * np.clip(1 - F.u / r, 0, 1) ** 2


# ============================================================= 2. Louis XVI
def louis(W, H, opt="gold", T=None, unit=None):
    T = T or round(W * 0.125)
    F = Frame(W, H, T, unit=unit)
    t = F.t
    h = prof(F, [
        (0.00, 0.05, ogee(0.02, 0.10)),
        (0.46, 0.52, flat(0.14)),
        (0.52, 0.74, cove(0.14, 0.08, 0.05)),
        (0.90, 0.97, flat(0.05)),
        (0.97, 1.00, slope(0.05, 0.0)),
    ], -0.03)
    gilt = np.zeros(h.shape, bool)
    hp, m = pearls(F, 0.05, 0.14, 0.075, 0.10, 0.045)
    h = np.where(m, hp, h); gilt |= m
    hr, m, band = ribbon_twist(F, 0.14, 0.46, 0.30, 0.12, 0.08, 1.0)
    h = np.where(m, hr, h); gilt |= band
    hl, m = stiff_leaves(F, 0.74, 0.90, 0.10, 0.08, 0.06)
    h = np.where(m, hl, h); gilt |= m
    hb, m = pearls(F, 0.90, 0.97, 0.04, 0.05, 0.025, reel=False)
    h = np.where(m, hb, h); gilt |= m
    gilt |= F.u < 0.05
    # corner blocks with rosettes over the outer frieze
    blk = (F.cx < 0.50) & (F.cy < 0.50)
    e = np.minimum(0.50 - F.cx, 0.50 - F.cy)
    blkh = 0.22 - 0.05 * np.clip(1 - e / 0.03, 0, 1) ** 2
    blkh = np.minimum(blkh, 0.10 + 2.0 * np.minimum(F.cx, F.cy))
    h = np.where(blk, np.maximum(h, blkh), h)
    # a fillet frame on the block
    fil = blk & (np.abs(e - 0.045) < 0.012)
    h = np.where(fil, h + 0.02, h)
    gilt |= fil
    F.h_ = h.astype(F32)
    n = int(0.5 * t)
    tl = Tile(n)
    ro = rosette(tl, 0.27 * t, 0.27 * t, 0.17 * t, petals=8, h0=0.22, h1=0.10)
    F.put_corners(ro)
    rmask = np.zeros(h.shape, F32)
    tmp = Frame.__new__(Frame); tmp.h_ = rmask; tmp.w, tmp.h = F.w, F.h
    Frame.put_corners(tmp, (ro > 0).astype(F32))
    gilt |= rmask > 0
    F.h_ += 0.0006 * pn(F.x, F.y, 0.02 * t, 0.02 * t, 3, 2)
    c = Ctx(F, F.h_ * t)
    if opt == "gold":
        col = metal(c, GOLD, antique=0.3)
    elif opt == "silver":
        col = metal(c, SILVER, antique=0.35, patina=(40, 38, 34))
    else:
        g = metal(c, PALE_GOLD, antique=0.25)
        w = matte(c, (238, 233, 220), amb=0.55, kd=0.55, spec=0.10)
        col = np.where(gilt[..., None], g, w)
    return finish(F, col), opening_box(W, H, T)


# ============================================================ 3. Dutch ripple
def tortoise(F, seed=4):
    t = F.t
    # mottles stretched along each side, as shell veneer is laid
    al, ac = grain_coords(F, seed)
    n1 = pn(al, ac, 0.22 * t, 0.10 * t, seed, 4, pery=False)
    n2 = pn(al, ac, 0.05 * t, 0.03 * t, seed + 3, 3, pery=False)
    k = np.clip((n1 * 0.75 + n2 * 0.25 - 0.40) * 2.4, 0, 1)
    amber = np.array([120, 58, 20], F32) / 255
    mid = np.array([66, 28, 10], F32) / 255
    dark = np.array([22, 10, 5], F32) / 255
    c = np.where((k < 0.5)[..., None], mix(amber, mid, (k * 2)[..., None]), mix(mid, dark, (k * 2 - 1)[..., None]))
    return c


def ripple_frame(W, H, opt="ebony", T=None, unit=None):
    T = T or round(W * 0.13)
    F = Frame(W, H, T, unit=unit)
    t = F.t
    h = prof(F, [
        (0.12, 0.16, flat(0.10)),
        (0.55, 0.61, flat(0.15)),
        (0.90, 1.00, slope(0.07, 0.0)),
    ], -0.03)
    for (a, b, P, fn, amp, wave, zig) in [
        (0.00, 0.12, 0.034, slope(0.03, 0.10), 0.010, 0.0, 0.0),
        (0.16, 0.55, 0.075, torus(0.10, 0.15, 0.15), 0.016, 0.22, 0.0),
        (0.61, 0.80, 0.034, cove(0.15, 0.09, 0.04), 0.008, 0.0, 0.0),
        (0.80, 0.90, 0.045, bead(0.07, 0.04), 0.008, 0.0, 0.9),
    ]:
        hr, m = ripple(F, a, b, P, fn, amp, wave, zig)
        h = np.where(m, hr, h)
    F.h_ = edge_round(F, h).astype(F32)
    c = Ctx(F, F.h_ * t)
    if opt == "ebony":
        base = np.array([20, 17, 15], F32) / 255
        base = base * (0.9 + 0.2 * pn(F.along, F.d, 1.0 * t, 0.03 * t, 2, 3, pery=False))[..., None]
        col = lacquer(c, base, gloss=0.75, sharp=1.4)
    elif opt == "tortoise":
        col = lacquer(c, tortoise(F), gloss=0.75, sharp=1.4, amb=0.40)
    else:
        wt = wood_tex(F, (150, 100, 58), (64, 38, 20), ring=0.09, seed=3)
        col = lacquer(c, wt, gloss=0.45, sharp=1.0, amb=0.40)
        col *= (1 - 0.35 * mitre_seam(F))[..., None]
    return finish(F, col), opening_box(W, H, T)


# ======================================================= 4. Carved Victorian
WOODS = {
    "walnut": ((128, 84, 50), (52, 30, 16)),
    "mahogany": ((150, 62, 36), (62, 20, 12)),
    "ebonised": ((52, 44, 40), (14, 12, 11)),
    "light": ((214, 176, 122), (150, 108, 62)),
    "fumed": ((128, 88, 52), (58, 36, 18)),
    "cherry": ((176, 98, 58), (96, 46, 24)),
    "oak": ((206, 166, 112), (136, 96, 52)),
}


def victorian(W, H, opt="walnut", T=None, unit=None):
    T = T or round(W * 0.15)
    F = Frame(W, H, T, unit=unit)
    t = F.t
    h = prof(F, [
        (0.00, 0.08, bead(0.02, 0.09)),
        (0.08, 0.13, flat(0.10)),
        (0.13, 0.44, ogee(0.10, 0.30)),
        (0.56, 0.76, cove(0.27, 0.15, 0.05)),
        (0.76, 0.80, slope(0.15, 0.10)),
        (0.80, 0.86, flat(0.10)),
        (0.94, 1.00, slope(0.07, 0.0)),
    ], -0.03)
    # gouge-cut flutes across the ogee
    v, m = F.band(0.18, 0.42)
    f, pe = F.cells(0.085, 0.3)
    fl = 0.018 * np.clip(1 - (2 * f) ** 2, 0, 1) * np.clip(np.sin(np.clip(v, 0, 1) * math.pi), 0, 1) ** 0.7
    h = np.where(m, h - fl, h)
    hg, m = gadroons(F, 0.44, 0.56, 0.06, torus(0.28, 0.28, 0.05), 0.03, twist=1.4)
    h = np.where(m, hg, h)
    hp, m = pearls(F, 0.86, 0.94, 0.05, 0.08, 0.035)
    h = np.where(m, hp, h)
    F.h_ = h.astype(F32)
    c = Ctx(F, F.h_ * t)
    lt, dk = WOODS[opt]
    wt = wood_tex(F, lt, dk, ring=0.10, seed=5)
    wood = lacquer(c, wt, gloss=0.30 if opt != "ebonised" else 0.45, sharp=0.8, amb=0.42)
    wood *= (1 - 0.45 * mitre_seam(F, 0.9))[..., None]
    gold = metal(c, GOLD, antique=0.4)
    col = np.where((F.u >= 0.78)[..., None], gold, wood)
    return finish(F, col), opening_box(W, H, T)


# ========================================================= 5. Arts and Crafts
def crafts(W, H, opt="light", T=None, unit=None):
    T = T or round(W * 0.125)
    F = Frame(W, H, T, unit=unit)
    t, w, hh = F.t, F.w, F.h
    x, y = F.x, F.y
    rail = (y < t) | (y > hh - t)
    up = np.where(y < t, y, hh - y) / t           # across the rail, 0 outer
    us = np.where(x < t, x, w - x) / t            # across the stile
    u = np.where(rail, up, us)
    # each piece: a flat face, rounded outer edge, chamfered inner edge
    face = 0.12 - 0.05 * np.clip(1 - u / 0.05, 0, 1) ** 2
    inner_ok = np.where(rail, (x > t) & (x < w - t), True)
    face = np.where(inner_ok, face - 0.07 * np.clip((u - 0.86) / 0.14, 0, 1), face)
    hgt = np.where(F.mask, face, -0.03)
    # the joints: a hairline between rail and stile, a touch of step
    joint = (~rail) & F.mask & (np.minimum(np.abs(y - t), np.abs(y - (hh - t))) < 0.6 * F.ss)
    hgt = np.where(rail & (np.minimum(x, w - x) < t), hgt + 0.006, hgt)
    # square pegs through the joints
    pegs = np.zeros(hgt.shape, bool)
    for py_ in (0.30, 0.70):
        for (cx, cy) in [(0.5 * t, py_ * t), (w - 0.5 * t, py_ * t), (0.5 * t, hh - py_ * t), (w - 0.5 * t, hh - py_ * t)]:
            pegs |= (np.abs(x - cx) < 0.055 * t) & (np.abs(y - cy) < 0.055 * t)
    hgt = np.where(pegs, hgt + 0.012, hgt)
    F.h_ = hgt.astype(F32)
    c = Ctx(F, F.h_ * t)
    lt, dk = WOODS[opt]
    al = np.where(rail, x, y) + np.where(rail, np.where(y < t, 0, 900), np.where(x < t, 1800, 2700))
    ac = np.where(rail, y, x)
    wt = wood_tex(F, lt, dk, ring=0.16, warp=1.6, figure=0.45 if opt != "cherry" else 0.0, seed=8, al=al, ac=ac)
    col = lacquer(c, wt, gloss=0.16, sharp=0.6, amb=0.45)
    endg = np.array(dk, F32) / 255 * 0.8
    col = np.where(pegs[..., None], endg * (0.6 + 0.6 * c.diff[..., None]), col)
    col *= (1 - 0.55 * blur(joint.astype(F32), 0.8 * F.ss))[..., None]
    return finish(F, col), opening_box(W, H, T)


# =============================================================== 6. Art Deco
DECO = {
    "black": ((16, 16, 18), GOLD),
    "ivory": ((232, 224, 204), SILVER),
    "emerald": ((14, 64, 48), GOLD),
}


def deco(W, H, opt="black", T=None, unit=None):
    T = T or round(W * 0.14)
    F = Frame(W, H, T, unit=unit)
    t = F.t
    gold_bands = [(0.075, 0.105, 0.135), (0.385, 0.415, 0.215), (0.605, 0.635, 0.255), (0.815, 0.845, 0.175)]
    pieces = [step(F, 0.0, 0.075, 0.10), step(F, 0.105, 0.385, 0.17), step(F, 0.415, 0.605, 0.23),
              step(F, 0.635, 0.815, 0.16), step(F, 0.845, 0.94, 0.09), (0.94, 1.0, slope(0.08, 0.0))]
    for a, b, hb in gold_bands:
        pieces.append((a, b, bead(hb - 0.03, 0.03)))
    h = prof(F, pieces, -0.03)
    gold = np.zeros(h.shape, bool)
    for a, b, _ in gold_bands:
        gold |= (F.u >= a) & (F.u < b)
    # corner blocks: stepped squares rising to a gold pyramid
    blk = (F.cx < 0.62) & (F.cy < 0.62)
    e = np.minimum(0.62 - F.cx, 0.62 - F.cy)        # in from the block's inner edges
    dc = np.maximum(np.abs(F.cx - 0.31), np.abs(F.cy - 0.31))   # square distance from the block centre
    hb = np.select([dc < 0.07, dc < 0.15, dc < 0.23], [0.40 - 1.2 * dc, 0.33, 0.30], 0.27)
    ch = 0.03 * np.clip(1 - np.minimum.reduce([np.abs(dc - 0.07), np.abs(dc - 0.15), np.abs(dc - 0.23)]) / 0.01, 0, 1) ** 2
    hb = hb - ch
    h = np.where(blk, hb, h)
    gold &= ~blk
    gold |= blk & ((dc < 0.07) | (np.abs(dc - 0.19) < 0.012) | (np.abs(dc - 0.285) < 0.008))
    F.h_ = h.astype(F32)
    # sunburst fans at the middle of each side
    cw_, ch_ = int(1.3 * t), int(0.62 * t)
    tc = Tile(cw_, ch_)
    mid = cw_ / 2
    dx, dy = tc.x - mid, tc.y - 0.62 * t
    r = np.sqrt(dx * dx + dy * dy) / (0.52 * t)
    th = np.arctan2(dx, -dy)
    rays = 1 - np.abs(((th / (math.pi / 13)) % 1) * 2 - 1)        # sharp ridges
    fan = (r < 1) & (dy < 0)
    fh = np.where(fan, 0.27 + 0.05 * rays * np.clip(r * 1.5, 0, 1) - 0.02 * r, 0)
    ring = (np.abs(r - 1.0) < 0.05) & (dy < 0)
    fh = np.where(ring, 0.30, fh)
    hub = r < 0.22
    fh = np.where(hub & (dy < 0), 0.33 + 0.02 * np.sqrt(np.clip(1 - (r / 0.22) ** 2, 0, 1)), fh)
    F.put_centres(fh.astype(F32))
    gm = np.zeros(F.h_.shape, F32)
    tmp = Frame.__new__(Frame); tmp.h_ = gm; tmp.w, tmp.h = F.w, F.h
    Frame.put_centres(tmp, (fh > 0).astype(F32))
    gold |= gm > 0
    c = Ctx(F, F.h_ * t)
    base, stops = DECO[opt]
    lac = lacquer(c, base, gloss=0.85 if opt != "ivory" else 0.35, sharp=0.9, amb=0.35)
    met = metal(c, stops, antique=0.15)
    col = np.where(gold[..., None], met, lac)
    return finish(F, col), opening_box(W, H, T)


# ============================================================= 7. Museum mat
def museum(W, H, opt="black", T=None, unit=None):
    Tf, M = round(W * 0.045), round(W * 0.115)
    if T:
        Tf, M = T, 0      # the frame alone: its mat is laid at run time
    T = Tf + M
    F = Frame(W, H, T, unit=unit)
    t = F.t
    k = Tf / T
    bev = 0.009 * 480 / T if M else 0
    h = prof(F, [
        (0.0, k * 0.25, lambda v: 0.06 + 0.10 * np.sqrt(np.clip(1 - (1 - v) ** 2, 0, 1))),
        (k * 0.25, k * 0.85, flat(0.16)),
        (k * 0.85, k, lambda v: 0.16 - 0.14 * v ** 2),
        (k, 1 - bev, flat(0.0)),
        (1 - bev, 1.0, lin(0.0, -0.025)),
    ], -0.03)
    F.h_ = h.astype(F32)
    hpx = F.h_ * t
    c = Ctx(F, hpx)
    sh = cast_shadow(hpx, 0.30 * t, 0.05 * t)
    fr_ = F.u < k
    if opt == "black":
        fcol = lacquer(c, (24, 24, 26), gloss=0.35, sharp=0.8)
    elif opt == "white":
        fcol = lacquer(c, (236, 234, 228), gloss=0.25, sharp=0.8, amb=0.5)
    else:
        wt = wood_tex(F, *WOODS["oak"], ring=0.18, seed=12)
        fcol = lacquer(c, wt, gloss=0.18, sharp=0.6, amb=0.45)
        fcol *= (1 - 0.4 * mitre_seam(F, 0.6))[..., None]
    paper = np.array([246, 244, 238], F32) / 255
    tex = 1 + 0.015 * (pn(F.x, F.y, 0.015 * t, 0.015 * t, 21, 2) - 0.5)
    mat = paper * tex[..., None] * (0.97 + 0.04 * (c.diff[..., None] - L[2]))
    core = np.array([255, 255, 252], F32) / 255
    bevel = (F.u >= 1 - bev)
    mat = np.where(bevel[..., None], core * (0.62 + 0.45 * c.diff[..., None]), mat)
    mat *= (1 - 0.30 * sh)[..., None] * (0.75 + 0.25 * c.ao)[..., None]
    col = np.where(fr_[..., None], fcol, mat)
    return finish(F, col), opening_box(W, H, T)


# ============================================================ 8. Floating oak
def floating(W, H, opt="light", T=None, unit=None):
    Tf, G = round(W * 0.06), round(W * 0.07)
    if T:
        Tf, G = T, 0      # the frame alone: its linen is laid at run time
    T = Tf + G
    F = Frame(W, H, T, unit=unit)
    t = F.t
    k = Tf / T
    h = prof(F, [
        (0.0, k * 0.12, lambda v: 0.25 + 0.05 * np.sqrt(np.clip(1 - (1 - v) ** 2, 0, 1))),
        (k * 0.12, k * 0.9, flat(0.30)),
        (k * 0.9, k, lambda v: 0.30 - 0.04 * v),
        (k, 1.0, flat(0.0)),
    ], 0.06)                                # the drawing sits raised on a spacer
    F.h_ = h.astype(F32)
    hpx = F.h_ * t
    c = Ctx(F, hpx)
    sh = cast_shadow(hpx, 0.9 * t, 0.06 * t, steps=40)
    if opt == "white":
        fcol = lacquer(c, (240, 238, 232), gloss=0.2, sharp=0.6, amb=0.5)
    else:
        lt, dk = WOODS["oak" if opt == "light" else "walnut"]
        wt = wood_tex(F, lt, dk, ring=0.14, seed=14)
        fcol = lacquer(c, wt, gloss=0.20, sharp=0.6, amb=0.45)
        fcol *= (1 - 0.4 * mitre_seam(F, 0.6))[..., None]
    linen = np.array([226, 220, 206], F32) / 255
    wp = qp(0.024 * t)
    wv = 0.5 + 0.5 * np.sin(F.x / wp * 2 * math.pi) * np.sin(F.y / wp * 2 * math.pi)
    tex = 1 + 0.035 * (wv - 0.5) + 0.03 * (pn(F.x, F.y, 0.05 * t, 0.05 * t, 31, 2) - 0.5)
    back = linen * tex[..., None] * (1 - 0.55 * sh)[..., None] * (0.6 + 0.4 * c.ao)[..., None]
    col = np.where((F.u < k)[..., None], fcol, back)
    img = finish(F, col)
    return img, opening_box(W, H, T)


# =========================================================== 9. Minimal metal
def metal_frame(W, H, opt="silver", T=None, unit=None):
    T = T or round(W * 0.035)
    F = Frame(W, H, T, unit=unit)
    t = F.t
    h = prof(F, [
        (0.0, 0.18, lambda v: 0.25 + 0.10 * np.sqrt(np.clip(1 - (1 - v) ** 2, 0, 1))),
        (0.18, 0.82, flat(0.35)),
        (0.82, 1.0, lambda v: 0.35 - 0.12 * v ** 2),
    ], 0.0)
    F.h_ = h.astype(F32)
    c = Ctx(F, F.h_ * t)
    brush = pn(F.along, F.d, 2.5 * t, 0.01 * t, 41, pery=False)
    if opt == "black":
        col = lacquer(c, (30, 30, 33), gloss=0.55, sharp=0.7)
    else:
        col = metal(c, SILVER if opt == "silver" else BRASS, rough=0.25)
    col *= (0.92 + 0.12 * brush)[..., None]
    col *= (1 - 0.5 * mitre_seam(F, 0.5))[..., None]
    return finish(F, col), opening_box(W, H, T)


# ============================================================ 10. Painted box
PAINT = {"red": (186, 54, 42), "mustard": (214, 166, 46), "blue": (40, 78, 150), "sage": (128, 150, 118)}


def painted(W, H, opt="red", T=None, unit=None):
    T = T or round(W * 0.075)
    F = Frame(W, H, T, unit=unit)
    t = F.t
    h = prof(F, [
        (0.0, 0.10, lambda v: 0.10 + 0.08 * np.sqrt(np.clip(1 - (1 - v) ** 2, 0, 1))),
        (0.10, 0.84, lambda v: 0.18 + 0.01 * np.sin(v * math.pi)),
        (0.84, 0.90, lambda v: 0.18 - 0.04 * v),
        (0.90, 1.0, slope(0.14, 0.0)),
    ], -0.03)
    F.h_ = h.astype(F32)
    c = Ctx(F, F.h_ * t)
    bru = pn(F.along, F.d, 1.5 * t, 0.012 * t, 51, pery=False)
    base = np.array(PAINT[opt], F32) / 255 * (0.97 + 0.06 * bru)[..., None]
    col = lacquer(c, base, gloss=0.22, sharp=0.6, amb=0.45)
    col *= (1 - 0.35 * mitre_seam(F, 0.5))[..., None]
    return finish(F, col), opening_box(W, H, T)


# ============================================================ 11. Canvas wrap
def canvas_wrap(W, H, opt, pic):
    """a stretched canvas seen a little from the left and above: the face,
    and the right and bottom sides in depth"""
    D = round(W * 0.05)
    fw, fh = W - D - round(W * 0.03), H - D - round(W * 0.03)
    ox, oy = round(W * 0.012), round(W * 0.012)
    S = SS
    bg = Image.new("RGB", (W * S, H * S), (255, 255, 255))
    pic = pic.convert("RGB")
    if opt == "wrap":
        # a gallery wrap: the picture's outer strip runs on round the edge
        pw_, ph_ = pic.size
        sx, sy = round(pw_ * D / (fw + D)), round(ph_ * D / (fh + D))
        side_r = pic.crop((pw_ - sx, 0, pw_, ph_ - sy)).resize((D * S, fh * S), Image.LANCZOS)
        side_b = pic.crop((0, ph_ - sy, pw_ - sx, ph_)).resize((fw * S, D * S), Image.LANCZOS)
        pic = pic.crop((0, 0, pw_ - sx, ph_ - sy))
    face = pic.resize((fw * S, fh * S), Image.LANCZOS)
    a = np.asarray(face, F32) / 255
    yy, xx = np.mgrid[0:fh * S, 0:fw * S].astype(F32)
    weave = 0.5 + 0.5 * np.sin(xx / (1.1 * S) * math.pi) * np.sin(yy / (1.1 * S) * math.pi)
    a = a * (0.95 + 0.07 * weave)[..., None]
    # light falls off a little across the face
    a = a * (1.0 - 0.04 * (xx + yy) / (fw * S + fh * S))[..., None]
    face = to_img(a)
    # the sides
    if opt == "wrap":
        right, bottom = side_r, side_b
    else:
        colr = (246, 245, 240) if opt == "white" else (30, 30, 32)
        right = Image.new("RGB", (D * S, fh * S), colr)
        bottom = Image.new("RGB", (fw * S, D * S), colr)
    def sheared(im, kind, k):
        arr = np.asarray(im, F32) / 255
        arr = arr * k
        im2 = to_img(arr)
        if kind == "r":   # parallelogram: x shifts down as it goes right
            return im2.transform((D * S, (fh + D) * S), Image.AFFINE, (1, 0, 0, -1, 1, 0), Image.BICUBIC)
        return im2.transform(((fw + D) * S, D * S), Image.AFFINE, (1, -1, 0, 0, 1, 0), Image.BICUBIC)
    # a soft shadow on the wall
    shadow = np.zeros((H * S, W * S), F32)
    x0, y0 = ox * S, oy * S
    shadow[y0 + D * S:y0 + (fh + D) * S + round(W * 0.012) * S, x0 + D * S:x0 + (fw + D) * S + round(W * 0.012) * S] = 1
    shadow = blur(shadow, W * 0.018 * S)
    bga = np.asarray(bg, F32) / 255 * (1 - 0.30 * shadow)[..., None]
    bg = to_img(bga)
    r_im = sheared(right, "r", 0.50 if opt != "black" else 0.9)
    b_im = sheared(bottom, "b", 0.68 if opt != "black" else 0.75)
    mr = Image.new("L", r_im.size, 0)
    ImageDraw.Draw(mr).polygon([(0, 0), (D * S, D * S), (D * S, (fh + D) * S), (0, fh * S)], fill=255)
    mb = Image.new("L", b_im.size, 0)
    ImageDraw.Draw(mb).polygon([(0, 0), (fw * S, 0), ((fw + D) * S, D * S), (D * S, D * S)], fill=255)
    bg.paste(r_im, (x0 + fw * S, y0), mr)
    bg.paste(b_im, (x0, y0 + fh * S), mb)
    bg.paste(face, (x0, y0))
    # a soft highlight along the face's top and left edges where the canvas turns
    out = np.asarray(bg, F32) / 255
    edge = np.zeros(out.shape[:2], F32)
    edge[y0:y0 + fh * S, x0 + fw * S - 2 * S:x0 + fw * S] = 0.10
    edge[y0 + fh * S - 2 * S:y0 + fh * S, x0:x0 + fw * S] = 0.06
    out = out * (1 - edge)[..., None]
    return down(to_img(out), W, H)


canvas_wrap.custom = True


# ========================================================== 12. Instant photo
INSTANT = {"white": (250, 249, 245), "black": (30, 30, 32), "mint": (206, 232, 220)}


def instant(W, H, opt, pic, name="Sunny house"):
    S = SS
    side, top, bot = round(W * 0.075), round(W * 0.085), round(W * 0.25)
    pw = W - 2 * side
    ph = H - top - bot
    base = np.array(INSTANT[opt], F32) / 255
    yy, xx = np.mgrid[0:H * S, 0:W * S].astype(F32)
    tex = 1 + 0.02 * (fbm(xx / (3.0 * S), yy / (3.0 * S), 3, 61) - 0.5)
    card = base * tex[..., None]
    # the paper bows a little: lighter top left, darker bottom right
    card *= (1.02 - 0.05 * (xx / (W * S) + yy / (H * S)) / 2)[..., None]
    img = to_img(card)
    p = pic.convert("RGB").resize((pw * S, ph * S), Image.LANCZOS)
    img.paste(p, (side * S, top * S))
    a = np.asarray(img, F32) / 255
    # the window is a little recessed: a shadow inside its top and left
    win = np.zeros(a.shape[:2], F32)
    win[top * S:(top + ph) * S, side * S:(side + pw) * S] = 1
    outside = 1 - win
    sh = blur(np.roll(np.roll(outside, int(0.8 * S), 0), int(0.8 * S), 1), 1.2 * S) * win
    a = a * (1 - 0.35 * sh)[..., None]
    # rounded corners on a light background
    m = Image.new("L", (W * S, H * S), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, W * S - 1, H * S - 1], radius=int(W * 0.018 * S), fill=255)
    mm = np.asarray(m, F32) / 255
    bgc = np.array([255, 255, 255], F32) / 255
    a = a * mm[..., None] + bgc * (1 - mm)[..., None]
    img = to_img(a)
    # the caption, handwritten
    font = load_font(int(W * 0.062 * S), italic=True)
    d = ImageDraw.Draw(img)
    ink = (52, 52, 64) if opt != "black" else (236, 236, 236)
    tw = d.textlength(name, font=font)
    d.text(((W * S - tw) / 2, (top + ph) * S + bot * S * 0.30), name, font=font, fill=ink)
    return down(img, W, H)


instant.custom = True


# ----------------------------------------------------------------- registry
def pads_sym(f):
    return lambda W: (round(W * f),) * 4


DESIGNS = {
    "baroque": ("Gilded Baroque", baroque, [("Gold", "gold"), ("Antique gold", "antique"), ("Silver gilt", "silver")], pads_sym(0.155)),
    "louis": ("Louis XVI", louis, [("Gold", "gold"), ("White and gold", "white"), ("Silver", "silver")], pads_sym(0.125)),
    "ripple": ("Dutch Ripple", ripple_frame, [("Ebony", "ebony"), ("Tortoiseshell", "tortoise"), ("Walnut", "walnut")], pads_sym(0.13)),
    "victorian": ("Carved Victorian", victorian, [("Walnut", "walnut"), ("Mahogany", "mahogany"), ("Ebonised", "ebonised")], pads_sym(0.15)),
    "crafts": ("Arts and Crafts", crafts, [("Light oak", "light"), ("Fumed oak", "fumed"), ("Cherry", "cherry")], pads_sym(0.125)),
    "deco": ("Art Deco", deco, [("Black and gold", "black"), ("Ivory and silver", "ivory"), ("Emerald and gold", "emerald")], pads_sym(0.14)),
    "museum": ("Museum Mat", museum, [("Black", "black"), ("White", "white"), ("Oak", "oak")], lambda W: (round(W * 0.045) + round(W * 0.115),) * 4),
    "floating": ("Floating Frame", floating, [("Light oak", "light"), ("Walnut", "walnut"), ("White", "white")], lambda W: (round(W * 0.06) + round(W * 0.07),) * 4),
    "metal": ("Minimal Metal", metal_frame, [("Silver", "silver"), ("Black", "black"), ("Brass", "brass")], pads_sym(0.035)),
    "painted": ("Painted Box", painted, [("Red", "red"), ("Mustard", "mustard"), ("Blue", "blue"), ("Sage", "sage")], pads_sym(0.075)),
    "canvas": ("Canvas Wrap", canvas_wrap, [("Picture on the sides", "wrap"), ("White sides", "white"), ("Black sides", "black")],
               lambda W: (round(W * 0.012), round(W * 0.012), round(W * 0.05) + round(W * 0.03) - round(W * 0.012), round(W * 0.05) + round(W * 0.03) - round(W * 0.012))),
    "instant": ("Instant Photo", instant, [("White", "white"), ("Black", "black"), ("Mint", "mint")],
                lambda W: (round(W * 0.075), round(W * 0.085), round(W * 0.075), round(W * 0.25))),
}
ORDER = ["baroque", "louis", "ripple", "victorian", "crafts", "deco", "museum", "floating", "metal", "painted", "canvas", "instant"]
