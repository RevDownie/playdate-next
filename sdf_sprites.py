"""
A small signed distance field ray caster that renders characters built from primitives (ellipsoids, capsules,
rounded boxes) straight into 1-bit pixels at their final size: no high resolution render shrunk down, so no mud.
Used by character_sprites.py.

Model space: pixels, z up, the character faces -y (towards the camera at facing 0). Facing 90 turns it to
screen left; the renderer mirrors 0..180 for the other half. The camera looks down at ELEV degrees.

Look: two tone cel shading per material (lit / one step darker away from the top left light), quantised to
white, 25%, 50%, 75% and black and dithered with one fixed 4x4 Bayer matrix (anchored to the sprite's pixels,
so parts that don't move don't shimmer between frames), a black line where one part passes in front of
another, and a 1px black outline.
"""
import math
import numpy as np

ELEV = math.radians(30)
VIEW = np.array([0.0, math.cos(ELEV), -math.sin(ELEV)], np.float32)  # into the screen, downwards
UP = np.array([0.0, math.sin(ELEV), math.cos(ELEV)], np.float32)
RIGHT = np.array([1.0, 0.0, 0.0], np.float32)
LIGHT = np.array([-0.55, -0.45, 0.70])
LIGHT = LIGHT / np.linalg.norm(LIGHT)
TONES = {"W": 1.0, "L": 0.75, "M": 0.5, "D": 0.25, "K": 0.0}
BAYER = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) + 0.5) / 16
SHADE_THRESHOLD = 0.28  # Lambert term below which a surface takes its shadow tone
STEP = 0.5  # Ray march step in pixels: half the thinnest part (gun barrels) so nothing is stepped over
ROWS_PER_CHUNK = 8  # Pixel rows marched at once, bounds memory


class Prim:
    def __init__(self, f, tone, part, flat=False):
        self.f, self.tone, self.part, self.flat = f, tone, part, flat


def rot_matrix(yaw=0.0, pitch=0.0, roll=0.0):
    y, p, r = map(math.radians, (yaw, pitch, roll))
    rz = np.array([[math.cos(y), -math.sin(y), 0], [math.sin(y), math.cos(y), 0], [0, 0, 1]])
    rx = np.array([[1, 0, 0], [0, math.cos(p), -math.sin(p)], [0, math.sin(p), math.cos(p)]])
    ry = np.array([[math.cos(r), 0, math.sin(r)], [0, 1, 0], [-math.sin(r), 0, math.cos(r)]])
    return (rz @ rx @ ry).astype(np.float32)


def ellipsoid(c, r, tone, part, flat=False):
    c, r = np.array(c, np.float32), np.array(r, np.float32)
    return Prim(lambda p: (np.linalg.norm((p - c) / r, axis=-1) - 1) * r.min(), tone, part, flat)


def sphere(c, r, tone, part, flat=False):
    return ellipsoid(c, (r, r, r), tone, part, flat)


def capsule(a, b, r, tone, part, r2=None, flat=False):
    """A limb from a to b, radius r tapering to r2"""
    a, b = np.array(a, np.float32), np.array(b, np.float32)
    ba = b - a
    r2 = r if r2 is None else r2

    def f(p):
        pa = p - a
        h = np.clip((pa @ ba) / (ba @ ba), 0, 1)
        return np.linalg.norm(pa - h[..., None] * ba, axis=-1) - (r + (r2 - r) * h)
    return Prim(f, tone, part, flat)


def box(c, h, tone, part, rnd=0.0, yaw=0, pitch=0, roll=0, flat=False):
    """Box centred on c with half sizes h, edges rounded by rnd"""
    c, h = np.array(c, np.float32), np.array(h, np.float32) - rnd
    m = rot_matrix(yaw, pitch, roll)  # world -> box: p @ m

    def f(p):
        q = np.abs((p - c) @ m) - h
        return np.linalg.norm(np.maximum(q, 0), axis=-1) + np.minimum(q.max(axis=-1), 0) - rnd
    return Prim(f, tone, part, flat)


def clip(prim, axis, val, keep_above=True):
    """Cut a primitive by the plane `axis` = val, keeping the side above (or below)"""
    f = prim.f
    prim.f = (lambda p: np.maximum(f(p), val - p[..., axis])) if keep_above else (lambda p: np.maximum(f(p), p[..., axis] - val))
    return prim


def pose(prims, piv, pitch=0.0, roll=0.0, offset=(0, 0, 0), toward=0.0):
    """Rotate a group of prims about piv (pitch > 0 tips the top backwards, towards +y, or towards +y turned by
    `toward` degrees about z), then move it by offset"""
    piv, off = np.array(piv, np.float32), np.array(offset, np.float32)
    m = rot_matrix(toward, 0, 0) @ rot_matrix(0, -pitch, roll) @ rot_matrix(-toward, 0, 0)  # object -> world, so world -> object is p @ m
    out = []
    for pr in prims:
        out.append(Prim((lambda f: lambda p: f((p - off - piv) @ m + piv))(pr.f), pr.tone, pr.part, pr.flat))
    return out


def shift(a, dy, dx, fill):
    """np.roll without wrapping round"""
    out = np.full_like(a, fill)
    h, w = a.shape
    out[max(dy, 0):h + min(dy, 0), max(dx, 0):w + min(dx, 0)] = a[max(-dy, 0):h + min(-dy, 0), max(-dx, 0):w + min(-dx, 0)]
    return out


N4 = ((0, 1), (0, -1), (1, 0), (-1, 0))
N8 = N4 + ((1, 1), (1, -1), (-1, 1), (-1, -1))


def render(prims, w, h, ax, ay, facing_deg, keep_from=0):
    """Render prims into a w x h cell with the feet (model origin) at pixel (ax, ay).
    Returns an int array: -1 transparent, 0 black, 1 white. Prims before index `keep_from` block rays but are not
    drawn, which bakes occlusion by the body into a separately drawn layer (the weapon and arms)"""
    reach = max(w, h) * 1.2
    a = math.radians(facing_deg)
    ca, sa = math.cos(a), math.sin(a)
    ts = np.arange(0, 2 * reach, STEP, dtype=np.float32)
    light = np.array([LIGHT[0] * ca - LIGHT[1] * sa, LIGHT[0] * sa + LIGHT[1] * ca, LIGHT[2]])
    val = np.zeros((h, w))
    has = np.zeros((h, w), bool)
    depth = np.full((h, w), np.inf)
    part = np.full((h, w), -1)
    parts = {}
    for p in prims:
        parts.setdefault(p.part, len(parts))

    for j0 in range(0, h, ROWS_PER_CHUNK):
        js, is_ = np.mgrid[j0:min(j0 + ROWS_PER_CHUNK, h), 0:w]
        sx = (is_ + 0.5 - ax).ravel().astype(np.float32)
        sy = (js + 0.5 - ay).ravel().astype(np.float32)
        o = sx[:, None] * RIGHT - sy[:, None] * UP - reach * VIEW
        pts = o[:, None, :] + ts[None, :, None] * VIEW
        mx = pts[..., 0] * ca - pts[..., 1] * sa
        my = pts[..., 0] * sa + pts[..., 1] * ca
        pts = np.stack([mx, my, pts[..., 2]], axis=-1)
        dmin = np.full(pts.shape[:2], np.inf, np.float32)
        for pr in prims:
            dmin = np.minimum(dmin, pr.f(pts))
        inside = dmin < 0
        hit = inside.any(axis=1)
        first = inside.argmax(axis=1)
        idx = np.arange(len(first))
        hp = pts[idx, first]
        win = np.stack([pr.f(hp) for pr in prims]).argmin(axis=0)
        hit &= win >= keep_from
        cval = np.zeros(len(idx))
        cpart = np.full(len(idx), -1)
        for k, pr in enumerate(prims):
            m = hit & (win == k)
            if not m.any():
                continue
            q = hp[m]
            n = np.stack([pr.f(q + e) - pr.f(q - e) for e in np.eye(3, dtype=np.float32) * 0.4], axis=-1)
            n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-9
            base = TONES[pr.tone]
            v = base if pr.flat else np.where(n @ light > SHADE_THRESHOLD, base, base - 0.25)
            cval[m] = np.clip(v, 0, 1)
            cpart[m] = parts[pr.part]
        rows = slice(j0, j0 + js.shape[0])
        val[rows] = cval.reshape(js.shape)
        has[rows] = hit.reshape(js.shape)
        depth[rows] = np.where(hit, ts[first], np.inf).reshape(js.shape)
        part[rows] = cpart.reshape(js.shape)

    thr = np.tile(BAYER, (h // 4 + 1, w // 4 + 1))[:h, :w]
    img = np.where(has, np.where(val > thr, 1, 0), -1)
    # A black line on the far side where one part passes in front of another
    for dy, dx in N4:
        nd = shift(depth, dy, dx, np.inf)
        npart = shift(part, dy, dx, -1)
        img[has & (nd < depth - 0.3) & (npart != part) & (npart >= 0)] = 0
    return img


def clean(img):
    """Remove stray single pixels that differ from all their neighbours (dither noise at a part's edge)"""
    out = img.copy()
    h, w = img.shape
    for j in range(1, h - 1):
        for i in range(1, w - 1):
            v = img[j, i]
            if v < 0:
                continue
            n4 = [img[j - 1, i], img[j + 1, i], img[j, i - 1], img[j, i + 1]]
            if v == 0 and all(x == 1 for x in n4) and img[j - 1, i - 1] == 1 and img[j + 1, i + 1] == 1:
                out[j, i] = 1
            if v == 1 and all(x == 0 for x in n4 + [img[j - 1, i - 1], img[j + 1, i + 1], img[j - 1, i + 1], img[j + 1, i - 1]]):
                out[j, i] = 0
    return out


def grow(mask, neighbours=N4):
    out = mask.copy()
    for dy, dx in neighbours:
        out |= shift(mask, dy, dx, False)
    return out


def outline(img):
    """1px black outline around the silhouette"""
    out = img.copy()
    has = img >= 0
    out[grow(has) & ~has] = 0
    return out


def rim(img, blocked=None):
    """1px white rim outside the (outlined) silhouette, so the player reads on dark ground and over enemies.
    Not drawn where `blocked` (another layer underneath) already has pixels"""
    out = img.copy()
    has = img >= 0
    ring = grow(has, N8) & ~has
    if blocked is not None:
        ring &= ~blocked
    out[ring] = 1
    return out


def composite(dst, src, x=0, y=0):
    """Paste src (-1 transparent) onto dst at x, y"""
    h, w = src.shape
    y0, x0 = max(y, 0), max(x, 0)
    y1, x1 = min(y + h, dst.shape[0]), min(x + w, dst.shape[1])
    if y1 <= y0 or x1 <= x0:
        return
    s = src[y0 - y:y1 - y, x0 - x:x1 - x]
    d = dst[y0:y1, x0:x1]
    d[s >= 0] = s[s >= 0]


def to_image(img):
    """RGBA, transparent where there is no sprite (like drop_sprites.py), which pdc turns into the mask"""
    from PIL import Image
    a = np.zeros(img.shape + (4,), np.uint8)
    a[img == 1] = (255, 255, 255, 255)
    a[img == 0] = (0, 0, 0, 255)
    return Image.fromarray(a, "RGBA")
