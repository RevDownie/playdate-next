import argparse
import math
import os
from multiprocessing import Pool
import numpy as np
from sdf_sprites import ellipsoid, sphere, capsule, pose, render, clean, outline, composite, to_image, Prim
import character_sprites as cs

"""
Gore sprites: the body parts a zombie bursts into when killed and the blood splats left on the ground. Called by
convert_raw.py, or run directly: python gore_sprites.py [out_dir] [--preview logs/gore.png]

Gibs are cut from the zombie models in character_sprites.py (same SDF renderer, same pale dotted skin and black
outline) so the pieces match the zombie that burst, each with a black wet end where it was torn off. Splats are
seeded 1-bit blobs, flattened for the camera's angle, black like all the blood.

Sheets (bitmap tables):
- gibs_<kind>: GIB_FADES (solid, then thinning with the dither) x GIB_PARTS (head, arm, leg, torso, chunk) x
  GIB_SPIN_FRAMES tumbling round, so index = (fade * GIB_PARTS + part) * GIB_SPIN_FRAMES + frame. Cell
  GIB_CELLS[kind] square, the piece's centre in the middle
- splats: pools (SPLAT_VARIANTS large then SPLAT_VARIANTS medium) x SPLAT_FADES (solid, half, quarter), so
  index = (size * SPLAT_VARIANTS + variant) * SPLAT_FADES + fade. Cell SPLAT_W x SPLAT_H, centred
- spatters: SPLAT_VARIANTS small drops x SPLAT_FADES, cell SPATTER_W x SPATTER_H, centred
"""

GIB_PARTS = ("head", "arm", "leg", "torso", "chunk")
GIB_SPIN_FRAMES = 8
GIB_FADES = 4
GIB_CELLS = {"runner": 20, "walker": 28, "shambler": 28, "brute": 48}
GIB_SCALE = 1.35  # Pieces are drawn bigger than they were on the body, so they read flying about

SPLAT_W, SPLAT_H = 56, 32
SPATTER_W, SPATTER_H = 12, 8
SPLAT_VARIANTS = 4
SPLAT_FADES = 3
SQUASH = 0.55  # The ground seen from the camera's elevation: circles become this flat

# Which of each model's parts make each gib, and the z band the torso is cut from (model pixels)
GIB_TAGS = {
    "runner": {"head": ("head",), "torso": ("torso",), "torso_band": (10, 20)},
    "walker": {"head": ("head",), "torso": ("torso",), "torso_band": (13, 25)},
    "shambler": {"head": ("head", "hair"), "torso": ("rags",), "torso_band": (15, 27)},
    "brute": {"head": ("head",), "torso": ("belly",), "torso_band": (16, 34)},
}

# ---------------------------------------------------------------- gibs


def inside_points(prims, lo=(-40, -40, -5), hi=(40, 40, 70)):
    """Points on a 1px grid inside the union of prims"""
    g = np.mgrid[lo[0]:hi[0], lo[1]:hi[1], lo[2]:hi[2]].reshape(3, -1).T.astype(np.float32) + 0.5
    d = np.full(len(g), np.inf, np.float32)
    for p in prims:
        d = np.minimum(d, p.f(g))
    return g[d < 0]


def moved(prims, by):
    by = np.array(by, np.float32)
    return [Prim((lambda f: lambda p: f(p + by))(pr.f), pr.tone, pr.part, pr.flat) for pr in prims]


def band(prims, z0, z1):
    out = []
    for pr in prims:
        f = pr.f
        out.append(Prim((lambda f: lambda p: np.maximum(f(p), np.maximum(z0 - p[..., 2], p[..., 2] - z1)))(f), pr.tone, pr.part, pr.flat))
    return out


def scaled(prims, s):
    return [Prim((lambda f: lambda p: f(p / s) * s)(pr.f), pr.tone, pr.part, pr.flat) for pr in prims]


def wet_end(pts, top, r, bone):
    """A black stump where the piece was torn off, at its top (limbs, from the shoulder or hip) or bottom (the head,
    from the neck), with a white bone sticking out of it"""
    z = pts[:, 2]
    end = pts[z > z.max() - 2] if top else pts[z < z.min() + 2]
    e = end.mean(axis=0)
    out = e - pts.mean(axis=0)
    out /= np.linalg.norm(out) + 1e-6
    tip = e + out * bone
    return [sphere(tuple(e), r, "K", "wet", flat=True), capsule(tuple(e - out * r * 0.5), tuple(tip), r * 0.38, "W", "bone"),
            sphere(tuple(tip), r * 0.55, "W", "bone")]


def gib_model(kind, part):
    """The piece centred on the origin"""
    model = cs.ZOMBIES[kind][0]()
    tags = GIB_TAGS[kind]
    scale = GIB_CELLS[kind] / 28
    if part == "chunk":
        r = 3.0 * scale
        prims = [ellipsoid((0, 0, 0), (r, r * 0.8, r * 0.7), "L", "meat"),
                 capsule((-r * 0.2, 0, 0), (r * 1.6, -r * 0.3, r * 0.5), r * 0.35, "W", "bone"),
                 sphere((r * 1.6, -r * 0.3, r * 0.5), r * 0.5, "W", "bone"),
                 sphere((-r * 0.6, -r * 0.4, r * 0.2), r * 0.6, "K", "wet", flat=True)]
        return scaled(prims, GIB_SCALE)
    if part == "head":
        prims = [p for p in model if p.part in tags["head"]]
    elif part == "arm":
        prims = [p for p in model if p.part == "arm-1"]
    elif part == "leg":
        prims = [p for p in model if p.part == "leg-1"]
    else:
        prims = band([p for p in model if p.part in tags["torso"]], *tags["torso_band"])
    pts = inside_points(prims)
    r = 2.0 * scale + 0.4
    if part == "torso":
        z0, z1 = tags["torso_band"]
        top, bottom = pts[pts[:, 2] > z1 - 2], pts[pts[:, 2] < z0 + 2]
        prims += [ellipsoid(tuple(top.mean(axis=0)), (r * 1.8, r * 1.4, r * 0.7), "K", "wet", flat=True),
                  ellipsoid(tuple(bottom.mean(axis=0)), (r * 1.6, r * 1.2, r * 0.7), "K", "wet", flat=True)]
    else:
        prims += wet_end(pts, part != "head", r, (1.2 if part == "head" else 2.6) * r)
    return scaled(moved(prims, pts.mean(axis=0)), GIB_SCALE)


def gib_frame(spec):
    kind, part, frame = spec
    cell = GIB_CELLS[kind]
    a = 360 * frame / GIB_SPIN_FRAMES
    prims = pose(gib_model(kind, part), (0, 0, 0), pitch=25 * math.sin(math.radians(a)) + 60, roll=a)
    return spec, outline(clean(render(prims, cell, cell, cell // 2, cell // 2, 0)))

# ---------------------------------------------------------------- splats


def disc(mask, cx, cy, r):
    h, w = mask.shape
    y, x = np.mgrid[0:h, 0:w]
    mask |= ((x + 0.5 - cx) ** 2 + ((y + 0.5 - cy) / SQUASH) ** 2) < r * r


def splat_mask(w, h, r, seed, satellites, streaks):
    """A pool: overlapping discs round the centre, drops thrown out round it and streaks of shrinking drops"""
    rng = np.random.default_rng(seed)
    m = np.zeros((h, w), bool)
    cx, cy = w / 2, h / 2
    for _ in range(5):
        a, d = rng.uniform(0, math.tau), rng.uniform(0, r * 0.45)
        disc(m, cx + math.cos(a) * d, cy + math.sin(a) * d * SQUASH, r * rng.uniform(0.45, 0.7))
    for _ in range(streaks):
        a = rng.uniform(0, math.tau)
        for k in range(4):
            d = r * (0.7 + 0.25 * k)
            disc(m, cx + math.cos(a) * d, cy + math.sin(a) * d * SQUASH, r * (0.22 - 0.045 * k))
    for _ in range(satellites):
        a, d = rng.uniform(0, math.tau), r * rng.uniform(0.9, 1.35)
        disc(m, cx + math.cos(a) * d, cy + math.sin(a) * d * SQUASH, r * rng.uniform(0.06, 0.13) + 0.5)
    return m


def bayer(h, w):
    return np.tile(np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]), (h // 4 + 1, w // 4 + 1))[:h, :w]


def gib_faded(img, fade):
    """A gib frame thinned by the Bayer dither (3/4, 1/2, 1/4 of its pixels left), the ground showing through"""
    return np.where(bayer(*img.shape) >= (0, 4, 8, 12)[fade], img, -1)


def faded(mask, fade, gloss=False):
    """-1 transparent, 0 black. Fading thins the black with the Bayer dither, leaving the ground showing through"""
    h, w = mask.shape
    keep = mask & (bayer(h, w) >= (0, 8, 12)[fade])
    img = np.where(keep, 0, -1)
    if gloss and fade == 0:
        # A wet highlight on the pool, up and left towards the light
        inner = mask.copy()
        for dy, dx in ((0, 3), (0, -3), (3, 0), (-3, 0)):
            inner &= np.roll(np.roll(mask, dy, 0), dx, 1)
        ys, xs = np.nonzero(inner)
        if len(xs):
            x0, y0 = xs.min(), ys[xs == xs.min()].min()
            for i in range(3):
                if 0 <= y0 + 1 < h and x0 + 1 + i < w and inner[y0 + 1, x0 + 1 + i]:
                    img[y0 + 1, x0 + 1 + i] = 1
            if inner[y0 + 2, x0 + 1]:
                img[y0 + 2, x0 + 1] = 1
    return img


def splats():
    large = [splat_mask(SPLAT_W, SPLAT_H, 20, 10 + v, satellites=9, streaks=4) for v in range(SPLAT_VARIANTS)]
    medium = [splat_mask(SPLAT_W, SPLAT_H, 11, 20 + v, satellites=5, streaks=3) for v in range(SPLAT_VARIANTS)]
    small = [splat_mask(SPATTER_W, SPATTER_H, 3.2, 30 + v, satellites=2, streaks=0) for v in range(SPLAT_VARIANTS)]
    return ([faded(m, f, gloss=True) for m in large + medium for f in range(SPLAT_FADES)],
            [faded(m, f) for m in small for f in range(SPLAT_FADES)])

# ---------------------------------------------------------------- sheets


def build(processes=None):
    specs = [(k, p, f) for k in GIB_CELLS for p in GIB_PARTS for f in range(GIB_SPIN_FRAMES)]
    with Pool(processes) as pool:
        frames = dict(pool.map(gib_frame, specs, chunksize=4))
    sheets = {"gibs_" + k: [gib_faded(frames[s], f) for f in range(GIB_FADES) for s in specs if s[0] == k] for k in GIB_CELLS}
    sheets["splats"], sheets["spatters"] = splats()
    return sheets


def save(sheets, out_dir):
    for name, frames in sheets.items():
        for i, img in enumerate(frames):
            to_image(img).save(os.path.join(out_dir, f"{name}-table-{i + 1}.png"))


def preview(sheets, path, scale=3):
    """Every gib frame per kind, then the splats, on light grey ground"""
    from PIL import Image
    rows = [sheets["gibs_" + k][p * GIB_SPIN_FRAMES:(p + 1) * GIB_SPIN_FRAMES] for k in GIB_CELLS for p in range(len(GIB_PARTS))]
    rows.append([sheets["gibs_walker"][f * len(GIB_PARTS) * GIB_SPIN_FRAMES] for f in range(GIB_FADES)])  # A head fading
    rows += [sheets["splats"][i:i + 6] for i in range(0, len(sheets["splats"]), 6)]
    rows.append(sheets["spatters"])
    cw, ch = 60, 36
    canvas = np.full((len(rows) * ch, max(len(r) for r in rows) * cw), -2)
    for r, cells in enumerate(rows):
        for c, img in enumerate(cells):
            composite(canvas, img, c * cw + (cw - img.shape[1]) // 2, r * ch + (ch - img.shape[0]) // 2)
    rgb = np.full(canvas.shape + (3,), 200, np.uint8)
    rgb[canvas == 1] = 255
    rgb[canvas == 0] = 0
    im = Image.fromarray(rgb)
    im.resize((im.width * scale, im.height * scale), Image.NEAREST).save(path)


def desc_lines():
    """Zig constants for src/bitmap_descs.zig"""
    return [
        f"pub const GIB_PARTS: u32 = {len(GIB_PARTS)};", f"pub const GIB_SPIN_FRAMES: u32 = {GIB_SPIN_FRAMES};",
        f"pub const GIB_FADES: u32 = {GIB_FADES};",
        "/// Per EnemyKind: the square gib cell's size (the piece's centre is in the middle)",
        "pub const GIB_CELLS = [_]u32{ " + ", ".join(str(c) for c in GIB_CELLS.values()) + " };",
        f"pub const SPLAT_W: u32 = {SPLAT_W};", f"pub const SPLAT_H: u32 = {SPLAT_H};",
        f"pub const SPATTER_W: u32 = {SPATTER_W};", f"pub const SPATTER_H: u32 = {SPATTER_H};",
        f"pub const SPLAT_VARIANTS: u32 = {SPLAT_VARIANTS};", f"pub const SPLAT_FADES: u32 = {SPLAT_FADES};",
    ]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Render the gib and blood splat sprite sheets")
    parser.add_argument("out_dir", nargs="?", default="images")
    parser.add_argument("--preview", help="also write a contact sheet png here")
    args = parser.parse_args()
    built = build()
    save(built, args.out_dir)
    if args.preview:
        preview(built, args.preview)
