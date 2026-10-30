"""
Level theme mock-ups: one 400x240 1-bit screen per candidate environment kit, at 1:1 game scale, with the real
hero, zombie, drop and gore sprites pasted in so readability and contrast can be judged against the characters.

Art is authored in five tones (the value ladder) and converted with one screen aligned 4x4 Bayer matrix:
  WHITE 255, LIGHT 191 (25% black), MID 127 (50%), DARK 63 (75%), BLACK 0.
Light comes from the top left: top faces light, front faces mid, cast shadows fall down and to the right.
Ground is the quietest layer: white with sparse detail decals (no tiled background).

  python tools/env_mockups.py [--out logs/mockups]
writes <theme>.png (1:1) per theme and contact.png (all themes at 2x, labelled).
"""
import argparse
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 400, 240
WHITE, VLIGHT, LIGHT, MID, DARK, BLACK = 255, 223, 191, 127, 63, 0

BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]])


def dither(img):
    a = np.asarray(img, dtype=np.float32)
    thr = (np.tile(BAYER4, (a.shape[0] // 4 + 1, a.shape[1] // 4 + 1))[: a.shape[0], : a.shape[1]] + 0.5) * 255 / 16
    return Image.fromarray(((a > thr) * 255).astype(np.uint8), "L")


# ---------------------------------------------------------------- sprites from the game, for scale


def load_frame(sheet, index):
    return Image.open(f"images/{sheet}-table-{index + 1}.png").convert("RGBA")


HERO_FRAMES, HERO_GUN_FRAMES, ENEMY_FRAMES = 6, 2, 5
ENEMY_ANCHORS = {"zombie_runner": (16, 29), "zombie_walker": (24, 43), "zombie_shambler": (24, 43), "zombie_brute": (32, 58)}


class Scene:
    """Draw items sorted by base y (like the renderer), drawn into a greyscale canvas, then dithered once"""

    def __init__(self, seed):
        self.img = Image.new("L", (W, H), WHITE)
        self.d = ImageDraw.Draw(self.img)
        self.items = []  # (base_y, fn)
        self.rng = random.Random(seed)

    def add(self, base_y, fn):
        self.items.append((base_y, fn))

    def sprite(self, x, y, sheet, index, anchor, flip=False):
        def fn():
            im = load_frame(sheet, index)
            if flip:
                im = im.transpose(Image.FLIP_LEFT_RIGHT)
            ax = im.width - anchor[0] if flip else anchor[0]
            grey = im.convert("L")
            self.img.paste(grey, (x - ax, y - anchor[1]), im.split()[3])

        self.add(y, fn)

    def hero(self, x, y, facing=4, flip=False):
        self.sprite(x, y, "hero", facing * HERO_FRAMES, (24, 43), flip)
        self.items.append((y + 0.1, lambda: None))
        self.sprite_after(x, y, "hero_gun", facing * HERO_GUN_FRAMES, (24, 43), flip)

    def sprite_after(self, x, y, sheet, index, anchor, flip):
        self.sprite(x, y, sheet, index, anchor, flip)
        base, fn = self.items.pop()
        self.items.append((y + 0.2, fn))

    def zombie(self, x, y, kind="zombie_walker", facing=5, frame=1, flip=False):
        self.sprite(x, y, kind, facing * ENEMY_FRAMES + frame, ENEMY_ANCHORS[kind], flip)

    def ground_sprite(self, x, y, sheet, index, anchor):
        """Flat on the ground (gore, drops' shadows): drawn before everything sorted"""
        im = load_frame(sheet, index)
        self.img.paste(im.convert("L"), (x - anchor[0], y - anchor[1]), im.split()[3])

    def drop(self, x, y, index=0):
        self.d.ellipse([x - 12, y - 3, x + 12, y + 3], fill=DARK)
        self.sprite(x, y - 4, "drops", index, (24, 40))

    def render(self):
        for _, fn in sorted(self.items, key=lambda t: t[0]):
            fn()
        return dither(self.img)


# ---------------------------------------------------------------- drawing helpers


def shadow(d, pts):
    d.polygon(pts, fill=DARK)


def box(s, x, y, w, depth, h, top=LIGHT, front=MID, detail=None, shadow_len=None):
    """A block seen in 3/4: footprint w x depth on the ground ending at y (the front edge), h tall.
    Front face (x..x+w, y-h..y), top face above it. Cast shadow to the right and down"""
    d = s.d
    sl = shadow_len if shadow_len is not None else max(4, h // 3)

    def fn():
        shadow(d, [(x + w, y - depth), (x + w + sl, y - depth + sl // 2), (x + w + sl, y + sl // 2), (x + sl // 2, y + sl // 2), (x, y)])
        d.rectangle([x, y - h - depth, x + w, y - h], fill=top, outline=BLACK)
        d.rectangle([x, y - h, x + w, y], fill=front, outline=BLACK)
        if detail:
            detail(d, x, y, w, depth, h)

    s.add(y, fn)


def cylinder_upright(s, x, y, r, h, body=MID, top=WHITE, hoops=()):
    d = s.d
    ry = max(2, r // 2)

    def fn():
        shadow(d, [(x + r - 2, y - 2), (x + r + h // 2, y), (x + r + h // 2 - 2, y + ry), (x - r // 2, y + ry)])
        d.rectangle([x - r, y - h, x + r, y], fill=body)
        d.rectangle([x + r // 3, y - h, x + r, y], fill=DARK)  # Shaded right side
        d.ellipse([x - r, y - ry, x + r, y + ry], fill=body, outline=BLACK)
        d.rectangle([x - r + 1, y - h, x + r - 1, y], fill=body)
        d.rectangle([x + r // 3, y - h, x + r - 1, y], fill=DARK)
        d.line([x - r, y - h, x - r, y], fill=BLACK)
        d.line([x + r, y - h, x + r, y], fill=BLACK)
        d.arc([x - r, y - ry, x + r, y + ry], 0, 180, fill=BLACK)
        for t in hoops:
            yy = y - int(h * t)
            d.arc([x - r, yy - ry, x + r, yy + ry], 0, 180, fill=BLACK)
        d.ellipse([x - r, y - h - ry, x + r, y - h + ry], fill=top, outline=BLACK)
        d.ellipse([x - r + 3, y - h - ry + 2, x + r - 3, y - h + ry - 2], outline=MID)

    s.add(y, fn)


def hatch(s, pts, fill, line, spacing, outline=BLACK):
    """Fill a polygon with horizontal lines clipped to it (roofs, planks)"""
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    layer = Image.new("L", (W, H), fill)
    ld = ImageDraw.Draw(layer)
    y0, y1 = int(min(p[1] for p in pts)), int(max(p[1] for p in pts))
    for y in range(y0 + spacing, y1, spacing):
        ld.line([(0, y), (W, y)], fill=line)
    s.img.paste(layer, (0, 0), mask)
    s.d.polygon(pts, outline=outline)


def blob(d, cx, cy, rx, ry, rng, n=9, jag=0.18):
    pts = []
    for i in range(n):
        a = i / n * math.tau
        k = 1 + rng.uniform(-jag, jag)
        pts.append((cx + math.cos(a) * rx * k, cy + math.sin(a) * ry * k))
    return pts


def tufts(s, n, area, rng, size=3, avoid=()):
    """Grass tufts: tiny black V strokes, the main ground decal"""
    x0, y0, x1, y1 = area
    for _ in range(n):
        x, y = rng.randint(x0, x1), rng.randint(y0, y1)
        if any(ax0 <= x <= ax1 and ay0 <= y <= ay1 for ax0, ay0, ax1, ay1 in avoid):
            continue
        s.d.line([x - size + 1, y - size, x, y], fill=BLACK)
        s.d.line([x + size - 1, y - size, x, y], fill=BLACK)
        if rng.random() < 0.5:
            s.d.line([x, y - size - 1, x, y], fill=BLACK)


def specks(s, n, area, rng, tone=BLACK, avoid=()):
    x0, y0, x1, y1 = area
    for _ in range(n):
        x, y = rng.randint(x0, x1), rng.randint(y0, y1)
        if any(ax0 <= x <= ax1 and ay0 <= y <= ay1 for ax0, ay0, ax1, ay1 in avoid):
            continue
        s.d.point((x, y), fill=tone)
        if rng.random() < 0.4:
            s.d.point((x + 1, y), fill=tone)


def cracks(s, n, area, rng, tone=BLACK):
    x0, y0, x1, y1 = area
    for _ in range(n):
        x, y = rng.randint(x0, x1), rng.randint(y0, y1)
        pts = [(x, y)]
        for _ in range(rng.randint(2, 4)):
            x += rng.randint(3, 9) * rng.choice((-1, 1))
            y += rng.randint(-3, 3)
            pts.append((x, y))
        s.d.line(pts, fill=tone)


def common_cast(s, hero=(200, 150), zombies=(), drop=None, gore=()):
    for x, y, i in gore:
        s.ground_sprite(x, y, "splats" if i < 100 else "spatters", i % 100, (28, 16))
    s.hero(*hero)
    for z in zombies:
        s.zombie(*z)
    if drop:
        s.drop(*drop)


# ---------------------------------------------------------------- themes


def woodland():
    s = Scene(1)
    rng = s.rng
    d = s.d
    # Ground: white, sparse tufts, leaf litter, a worn dirt path in very light dither
    d.polygon([(0, 200), (120, 170), (230, 175), (400, 150), (400, 172), (230, 197), (120, 192), (0, 222)], fill=VLIGHT)
    tufts(s, 70, (0, 40, 400, 240), rng)
    specks(s, 60, (0, 40, 400, 240), rng, DARK)

    def deciduous(x, y, r=22, seed=0):
        lr = random.Random(seed)

        def fn():
            d.ellipse([x - r + 6, y - 4, x + r + 10, y + 6], fill=DARK)  # Canopy shadow on the ground
            d.rectangle([x - 3, y - 18, x + 3, y], fill=DARK, outline=BLACK)
            d.line([x - 1, y - 16, x - 1, y - 2], fill=MID)
            cy = y - 18 - r * 0.7
            parts = [(x - r * 0.45, cy + 3, r * 0.7), (x + r * 0.45, cy + 4, r * 0.7), (x, cy - r * 0.35, r * 0.75), (x, cy + r * 0.2, r * 0.8)]
            for px, py, pr in parts:
                d.polygon(blob(d, px, py, pr + 1, pr * 0.8 + 1, lr, 11, 0.12), fill=BLACK)
            for px, py, pr in parts:
                d.polygon(blob(d, px, py, pr, pr * 0.8, lr, 11, 0.12), fill=MID)
            d.polygon(blob(d, x - r * 0.25, cy - r * 0.3, r * 0.55, r * 0.4, lr, 9, 0.15), fill=LIGHT)  # Lit top left
            d.chord([x - r, cy + r * 0.1, x + r, cy + r * 0.85], 0, 180, fill=DARK)  # Shaded underside
            for _ in range(5):
                lx, ly = x + lr.uniform(-r * 0.6, r * 0.3), cy + lr.uniform(-r * 0.6, 0)
                d.arc([lx - 3, ly - 2, lx + 3, ly + 2], 180, 360, fill=WHITE)

        s.add(y, fn)

    def pine(x, y, hgt=56):
        def fn():
            d.polygon([(x, y - 2), (x + 26, y + 4), (x + 20, y + 8), (x - 6, y + 4)], fill=DARK)
            d.rectangle([x - 2, y - 8, x + 2, y], fill=BLACK)
            for i, (wdt, top) in enumerate(((16, 0.55), (12, 0.3), (8, 0.0))):
                ty, by = y - hgt + int(hgt * top), y - 8 - int(i * hgt * 0.22)
                d.polygon([(x, ty), (x + wdt, by), (x - wdt, by)], fill=DARK, outline=BLACK)
                d.polygon([(x, ty + 3), (x - wdt + 4, by - 1), (x - 2, by - 1)], fill=MID)
                d.line([(x - wdt + 2, by - 1), (x + wdt - 2, by - 1)], fill=BLACK)

        s.add(y, fn)

    def log(x, y, length=70):
        def fn():
            d.polygon([(x + 6, y), (x + length + 8, y), (x + length + 4, y + 6), (x + 2, y + 6)], fill=DARK)
            d.rounded_rectangle([x, y - 12, x + length, y], 6, fill=MID, outline=BLACK)
            d.line([(x + 4, y - 9), (x + length - 6, y - 9)], fill=LIGHT)
            for bx in range(x + 10, x + length - 8, 9):
                d.line([(bx, y - 6), (bx + 5, y - 6)], fill=BLACK)
            d.ellipse([x + length - 8, y - 12, x + length + 2, y], fill=VLIGHT, outline=BLACK)
            d.ellipse([x + length - 5, y - 9, x + length - 1, y - 3], outline=MID)
            d.line([(x + 20, y - 12), (x + 16, y - 20), (x + 12, y - 22)], fill=BLACK)  # Snapped branch

        s.add(y, fn)

    def boulder(x, y, r=14, seed=3):
        lr = random.Random(seed)

        def fn():
            d.ellipse([x - r + 4, y - 4, x + r + 8, y + 4], fill=DARK)
            pts = [(x - r, y), (x - r - 2, y - r * 0.6), (x - r * 0.4, y - r * 1.2), (x + r * 0.5, y - r * 1.1), (x + r + 2, y - r * 0.5), (x + r, y)]
            d.polygon(pts, fill=MID, outline=BLACK)
            d.polygon([(x - r + 2, y - r * 0.6), (x - r * 0.4, y - r * 1.1), (x + r * 0.3, y - r), (x, y - r * 0.55)], fill=WHITE)
            d.line([(x, y - r * 0.55), (x + 4, y - 2)], fill=BLACK)
            d.polygon([(x + r * 0.3, y - r * 0.4), (x + r, y - r * 0.4), (x + r - 1, y - 1), (x + 4, y - 1)], fill=DARK)

        s.add(y, fn)

    def tent(x, y):
        def fn():
            d.polygon([(x + 30, y), (x + 44, y + 4), (x + 4, y + 6)], fill=DARK)
            d.polygon([(x, y), (x + 18, y - 26), (x + 36, y)], fill=MID, outline=BLACK)
            d.polygon([(x + 18, y - 26), (x + 36, y), (x + 26, y)], fill=DARK, outline=BLACK)
            d.polygon([(x + 12, y), (x + 18, y - 12), (x + 22, y)], fill=BLACK)  # Torn flap
            d.line([(x + 18, y - 26), (x + 18, y - 30)], fill=BLACK)
            # Campfire ring
            for i in range(7):
                a = i / 7 * math.tau
                cx, cy = x + 56 + math.cos(a) * 8, y - 2 + math.sin(a) * 4
                d.ellipse([cx - 2, cy - 2, cx + 2, cy + 1], fill=LIGHT, outline=BLACK)
            d.line([(x + 52, y - 2), (x + 60, y - 3)], fill=BLACK, width=2)

        s.add(y, fn)

    # Edge of the map: a dense tree line along the top
    for i, x in enumerate(range(-10, 420, 30)):
        if i % 2:
            pine(x, 52 + (i * 7) % 9, 50)
        else:
            deciduous(x, 58 + (i * 5) % 7, 20, i)
    deciduous(70, 140, 22, 11)
    deciduous(330, 205, 24, 12)
    pine(300, 120, 58)
    pine(318, 128, 48)
    log(40, 222, 72)
    boulder(120, 110, 13, 4)
    boulder(132, 116, 8, 5)
    tent(230, 104)
    common_cast(s, (196, 160), [(150, 120, "zombie_walker", 3, 1), (262, 180, "zombie_shambler", 6, 2, True), (360, 150, "zombie_runner", 5, 3, True), (110, 196, "zombie_walker", 6, 0)], (300, 232, 0), [(250, 200, 0), (90, 175, 101)])
    return s


def suburb():
    s = Scene(2)
    rng = s.rng
    d = s.d
    # Ground: lawn with tufts, a cracked road across the bottom with a dashed centre line and kerbs
    road_top, road_bot = 168, 222
    d.rectangle([0, road_top, 400, road_bot], fill=VLIGHT)
    d.line([(0, road_top), (400, road_top)], fill=BLACK)
    d.line([(0, road_top - 4), (400, road_top - 4)], fill=MID)
    d.line([(0, road_bot), (400, road_bot)], fill=BLACK)
    for x in range(0, 400, 40):
        d.rectangle([x + 4, 194, x + 22, 196], fill=WHITE)
    cracks(s, 9, (0, road_top + 4, 400, road_bot - 4), rng, DARK)
    tufts(s, 40, (0, 30, 400, road_top - 8), rng)
    tufts(s, 8, (0, road_top + 2, 400, road_bot - 2), rng, 2)

    def house(x, y, w=118, roof_seed=0):
        h, roof = 36, 34

        def fn():
            shadow(d, [(x + w, y - 30), (x + w + 18, y - 22), (x + w + 18, y + 8), (x + 10, y + 8), (x, y)])
            d.rectangle([x, y - h, x + w, y], fill=WHITE, outline=BLACK)  # Front wall, lit
            for sy in range(y - h + 6, y, 6):  # Clapboard siding
                d.line([(x + 1, sy), (x + w - 1, sy)], fill=VLIGHT)
            # Gabled roof seen from the front and above
            hatch(s, [(x - 6, y - h), (x + 14, y - h - roof), (x + w - 14, y - h - roof), (x + w + 6, y - h)], DARK, BLACK, 6)
            d.line([(x + 14, y - h - roof), (x + w - 14, y - h - roof)], fill=WHITE)
            d.polygon([(x + w - 40, y - h - 20), (x + w - 24, y - h - 20), (x + w - 22, y - h - 6), (x + w - 46, y - h - 4)], fill=WHITE, outline=BLACK)  # Hole in the roof
            d.rectangle([x + 24, y - h - roof - 10, x + 34, y - h - roof + 4], fill=MID, outline=BLACK)  # Chimney
            d.rectangle([x + 52, y - 24, x + 66, y], fill=BLACK)  # Door
            d.line([(x + 54, y - 22), (x + 64, y - 6)], fill=LIGHT)
            for wx in (x + 12, x + 84):  # Boarded windows
                d.rectangle([wx, y - 26, wx + 20, y - 10], fill=BLACK)
                d.line([(wx - 2, y - 24), (wx + 22, y - 14)], fill=LIGHT, width=3)
                d.line([(wx - 2, y - 14), (wx + 22, y - 22)], fill=LIGHT, width=3)
            d.rectangle([x - 2, y - 1, x + w + 2, y + 1], fill=BLACK)

        s.add(y, fn)

    def picket(x, y, n=10, gaps=(3, 7)):
        def fn():
            d.line([(x, y - 8), (x + n * 7, y - 8)], fill=BLACK)
            d.line([(x, y - 4), (x + n * 7, y - 4)], fill=BLACK)
            for i in range(n):
                if i in gaps:
                    continue
                px = x + i * 7
                lean = 2 if i == gaps[0] + 1 else 0
                d.polygon([(px + lean, y - 14), (px + 2 + lean, y - 16), (px + 4 + lean, y - 14), (px + 4, y), (px, y)], fill=WHITE, outline=BLACK)
                d.line([(px + 5, y), (px + 7, y + 2)], fill=DARK)

        s.add(y, fn)

    def car(x, y, flip=False):
        def fn():
            d.polygon([(x + 4, y), (x + 76, y), (x + 82, y + 6), (x + 10, y + 6)], fill=DARK)
            d.rounded_rectangle([x, y - 28, x + 74, y - 6], 6, fill=MID, outline=BLACK)  # Body from above
            d.rounded_rectangle([x + 18, y - 34, x + 54, y - 14], 4, fill=LIGHT, outline=BLACK)  # Roof / cabin
            d.rectangle([x + 20, y - 15, x + 52, y - 10], fill=BLACK)  # Windscreen (smashed)
            d.line([(x + 26, y - 15), (x + 32, y - 11), (x + 38, y - 14)], fill=WHITE)
            d.rectangle([x, y - 10, x + 74, y], fill=DARK, outline=BLACK)  # Side
            for wx in (x + 8, x + 54):
                d.ellipse([wx, y - 6, wx + 13, y + 3], fill=BLACK)
            d.line([(x + 60, y - 28), (x + 66, y - 18), (x + 72, y - 22)], fill=BLACK)  # Crumpled bonnet

        s.add(y, fn)

    def hedge(x, y, w=60):
        def fn():
            shadow(d, [(x + w, y - 12), (x + w + 8, y - 8), (x + w + 8, y + 4), (x + 4, y + 4), (x, y)])
            d.rounded_rectangle([x, y - 22, x + w, y], 5, fill=DARK, outline=BLACK)
            for bx in range(x + 4, x + w - 4, 9):
                d.arc([bx, y - 24, bx + 10, y - 14], 180, 360, fill=LIGHT)
                d.arc([bx + 3, y - 16, bx + 13, y - 6], 200, 340, fill=MID)

        s.add(y, fn)

    def bin_tipped(x, y):
        def fn():
            d.rounded_rectangle([x, y - 10, x + 20, y], 3, fill=MID, outline=BLACK)
            d.ellipse([x + 16, y - 11, x + 24, y + 1], fill=BLACK)
            for i in range(5):
                d.rectangle([x + 26 + i * 4, y - 3 + (i % 2) * 2, x + 28 + i * 4, y - 1 + (i % 2) * 2], fill=BLACK)

        s.add(y, fn)

    house(20, 82, 118)
    house(250, 76, 128)
    hedge(150, 70, 70)
    picket(10, 132, 11, (3, 4, 8))
    picket(240, 128, 14, (5, 11))
    car(70, 212)
    car(300, 194)
    bin_tipped(170, 150)
    common_cast(s, (200, 176), [(140, 196, "zombie_walker", 5, 1), (250, 150, "zombie_brute", 6, 1, True), (360, 226, "zombie_runner", 4, 3, True), (40, 160, "zombie_shambler", 4, 2)], (110, 150, 1), [(220, 205, 2), (330, 150, 102)])
    return s


def city():
    s = Scene(3)
    rng = s.rng
    d = s.d
    # Ground: pavement slabs (faint grid) along the top, cracked road with a faded zebra crossing
    d.rectangle([0, 112, 400, 240], fill=VLIGHT)
    d.line([(0, 112), (400, 112)], fill=BLACK)
    for x in range(0, 400, 32):
        d.line([(x, 92), (x, 111)], fill=LIGHT)
    d.line([(0, 102), (400, 102)], fill=LIGHT)
    for y in range(124, 230, 14):
        d.rectangle([168, y, 230, y + 6], fill=WHITE)
    cracks(s, 14, (0, 118, 400, 236), rng, BLACK)
    specks(s, 40, (0, 112, 400, 240), rng, DARK)

    def ruin(x, y, w=110, h=70, seed=0):
        lr = random.Random(seed)

        def fn():
            shadow(d, [(x + w, y - 10), (x + w + 22, y - 2), (x + w + 22, y + 8), (x + 8, y + 8), (x, y)])
            # Jagged broken top edge
            top = [(x, y)]
            n = 9
            for i in range(n + 1):
                tx = x + w * i / n
                top.append((tx, y - h + lr.randint(-4, 22) * (1 if 0 < i < n else 0)))
            top.append((x + w, y))
            d.polygon(top, fill=LIGHT, outline=BLACK)
            for wy in range(y - h + 14, y - 12, 18):  # Window holes
                for wx in range(x + 8, x + w - 14, 20):
                    if lr.random() < 0.85:
                        d.rectangle([wx, wy, wx + 10, wy + 10], fill=BLACK)
                        d.line([(wx, wy + 10), (wx + 10, wy + 10)], fill=MID)
            d.rectangle([x + w // 2 - 10, y - 20, x + w // 2 + 10, y], fill=BLACK)  # Doorway
            for _ in range(4):  # Rebar
                rx = x + lr.randint(10, w - 10)
                d.line([(rx, y - h + 6), (rx + lr.randint(-4, 4), y - h - 6)], fill=BLACK)

        s.add(y, fn)

    def rubble(x, y, seed=0, n=10):
        lr = random.Random(seed)

        def fn():
            d.ellipse([x - 26, y - 8, x + 30, y + 4], fill=DARK)
            for _ in range(n):
                cx, cy = x + lr.randint(-22, 22), y - lr.randint(0, 10)
                r = lr.randint(3, 7)
                tone = lr.choice((WHITE, LIGHT, LIGHT, MID))
                d.polygon(blob(d, cx, cy, r + 1, r * 0.8, lr, 5, 0.3), fill=tone, outline=BLACK)
            d.line([(x - 10, y - 12), (x + 6, y - 20)], fill=BLACK, width=2)  # Girder

        s.add(y, fn)

    def bus(x, y):
        def fn():
            d.polygon([(x + 6, y), (x + 150, y), (x + 158, y + 8), (x + 12, y + 8)], fill=DARK)
            d.rectangle([x, y - 40, x + 148, y - 24], fill=MID, outline=BLACK)  # Roof (burnt)
            d.polygon([(x + 40, y - 40), (x + 70, y - 38), (x + 64, y - 26), (x + 44, y - 28)], fill=BLACK)  # Burnt through
            d.rectangle([x, y - 24, x + 148, y], fill=DARK, outline=BLACK)
            for wx in range(x + 6, x + 140, 16):
                d.rectangle([wx, y - 21, wx + 11, y - 12], fill=BLACK)
            d.rectangle([x + 2, y - 10, x + 146, y - 8], fill=LIGHT)
            for wx in (x + 14, x + 118):
                d.rectangle([wx, y - 4, wx + 14, y + 2], fill=BLACK)

        s.add(y, fn)

    def lamp(x, y):
        def fn():
            d.line([(x + 1, y), (x + 14, y + 6)], fill=DARK, width=2)
            d.line([(x, y), (x, y - 40), (x + 18, y - 52)], fill=BLACK, width=3)  # Bent
            d.rectangle([x + 16, y - 56, x + 26, y - 50], fill=MID, outline=BLACK)
            d.ellipse([x - 4, y - 2, x + 4, y + 2], fill=BLACK)

        s.add(y, fn)

    def crater(x, y):
        d.ellipse([x - 30, y - 10, x + 30, y + 10], fill=DARK, outline=BLACK)
        d.ellipse([x - 22, y - 6, x + 22, y + 7], fill=BLACK)
        d.arc([x - 30, y - 10, x + 30, y + 10], 180, 300, fill=WHITE)

    crater(300, 210)
    ruin(-10, 92, 120, 74, 1)
    ruin(260, 92, 150, 66, 2)
    rubble(140, 96, 3)
    rubble(60, 214, 4, 12)
    bus(130, 170)
    lamp(236, 98)
    common_cast(s, (200, 204), [(110, 130, "zombie_walker", 4, 1), (290, 140, "zombie_runner", 6, 2, True), (360, 190, "zombie_walker", 5, 3, True), (100, 180, "zombie_brute", 4, 1)], (40, 140, 0), [(250, 228, 1), (160, 210, 103)])
    return s


def factory():
    s = Scene(4)
    rng = s.rng
    d = s.d
    # Ground: concrete with expansion joints (faint), a hazard stripe lane edge, oil stains
    for x in range(0, 400, 64):
        d.line([(x, 70), (x, 240)], fill=LIGHT)
    for y in range(110, 240, 48):
        d.line([(0, y), (400, y)], fill=LIGHT)
    for x in range(0, 400, 12):  # Hazard stripes along the walkway
        d.polygon([(x, 160), (x + 6, 160), (x + 2, 166), (x - 4, 166)], fill=BLACK)
    d.line([(0, 159), (400, 159)], fill=BLACK)
    d.line([(0, 166), (400, 166)], fill=BLACK)
    for ox, oy in ((90, 200), (330, 130)):
        d.ellipse([ox - 14, oy - 4, ox + 14, oy + 5], fill=MID)
        d.ellipse([ox - 6, oy - 1, ox + 10, oy + 3], fill=DARK)
    specks(s, 30, (0, 70, 400, 240), rng, MID)

    # Map edge: corrugated warehouse wall with a roller door
    def wall():
        d.rectangle([0, 0, 400, 66], fill=MID)
        for x in range(0, 400, 4):
            d.line([(x, 8), (x, 66)], fill=DARK if x % 8 else LIGHT)
        d.rectangle([0, 0, 400, 8], fill=DARK, outline=BLACK)
        d.line([(0, 66), (400, 66)], fill=BLACK)
        d.rectangle([150, 18, 230, 66], fill=LIGHT, outline=BLACK)  # Roller door, half open
        for y in range(20, 52, 3):
            d.line([(151, y), (229, y)], fill=MID)
        d.rectangle([151, 52, 229, 65], fill=BLACK)
        d.rectangle([40, 24, 70, 38], fill=WHITE, outline=BLACK)  # Sign
        d.line([(44, 31), (66, 31)], fill=BLACK, width=3)
        d.rectangle([0, 66, 400, 72], fill=DARK)

    s.add(0, wall)

    def container(x, y, w=120, stacked=False):
        def detail(d, x, y, w, depth, h):
            for cx in range(x + 3, x + w - 1, 4):
                d.line([(cx, y - h + 2), (cx, y - 2)], fill=DARK)
            for cx in range(x + 2, x + w - 1, 6):
                d.line([(cx, y - h - depth + 2), (cx, y - h - 2)], fill=MID)
            d.rectangle([x + w - 14, y - h + 2, x + w - 2, y - 2], fill=LIGHT, outline=BLACK)  # Door end
            d.line([(x + w - 10, y - h + 4), (x + w - 10, y - 4)], fill=BLACK)
            d.line([(x + w - 6, y - h + 4), (x + w - 6, y - 4)], fill=BLACK)
            d.rectangle([x + 10, y - h + 6, x + 34, y - h + 12], fill=WHITE)  # Stencil

        box(s, x, y, w, 22, 52 if stacked else 28, LIGHT, MID, detail)
        if stacked:
            def seam(x=x, y=y, w=w):
                d.line([(x, y - 27), (x + w, y - 27)], fill=BLACK)
            s.add(y + 0.1, seam)

    def pallet(x, y):
        def detail(d, x, y, w, depth, h):
            for i in range(3):
                d.line([(x, y - h // 3 * i), (x + w, y - h // 3 * i)], fill=BLACK)
            d.line([(x + w // 2, y - h - depth), (x + w // 2, y)], fill=BLACK)
            d.rectangle([x + 4, y - 4, x + w - 4, y - 1], fill=BLACK)

        box(s, x, y, 34, 16, 24, VLIGHT, LIGHT, detail)

    def pipe(x, y, length=150):
        def fn():
            d.rectangle([x + 6, y, x + length + 10, y + 6], fill=DARK)
            for sx in (x + 10, x + length - 16):
                d.rectangle([sx, y - 24, sx + 6, y], fill=MID, outline=BLACK)
            d.rectangle([x, y - 40, x + length, y - 24], fill=MID, outline=BLACK)
            d.line([(x + 1, y - 36), (x + length - 1, y - 36)], fill=WHITE)
            d.line([(x + 1, y - 27), (x + length - 1, y - 27)], fill=DARK)
            for fx in range(x + 30, x + length, 40):
                d.rectangle([fx, y - 42, fx + 4, y - 22], fill=LIGHT, outline=BLACK)  # Flanges

        s.add(y, fn)

    container(10, 124, 118, True)
    container(270, 230, 124)
    for i, (bx, by) in enumerate(((300, 120), (316, 128), (292, 136), (330, 138))):
        cylinder_upright(s, bx, by, 8, 22, MID if i % 2 else DARK, WHITE, (0.35, 0.7))
    pallet(150, 112)
    pallet(186, 116)
    pipe(30, 226, 140)
    common_cast(s, (220, 190), [(150, 160, "zombie_walker", 4, 1), (360, 176, "zombie_shambler", 6, 2, True), (240, 132, "zombie_runner", 6, 0, True), (110, 186, "zombie_walker", 4, 3)], (370, 100, 1), [(250, 214, 1), (190, 150, 101)])
    return s


def military():
    s = Scene(5)
    rng = s.rng
    d = s.d
    # Ground: pale sand stipple and tyre tracks
    specks(s, 120, (0, 50, 400, 240), rng, MID)
    for off in (0, 18):
        for x in range(0, 400, 6):
            y = 196 - x * 0.12 + off
            d.rectangle([x, y, x + 3, y + 1], fill=DARK)

    # Map edge: chain link fence with razor wire on top
    def fence():
        d.rectangle([0, 34, 400, 62], fill=WHITE)
        for x in range(0, 400, 6):
            d.line([(x, 34), (x + 6, 62)], fill=MID)
            d.line([(x + 6, 34), (x, 62)], fill=MID)
        for x in range(0, 410, 48):
            d.rectangle([x, 22, x + 3, 64], fill=DARK, outline=BLACK)
        d.line([(0, 34), (400, 34)], fill=BLACK)
        d.line([(0, 62), (400, 62)], fill=BLACK)
        for x in range(-6, 410, 9):  # Razor wire coil
            d.ellipse([x, 16, x + 13, 30], outline=BLACK)
        d.rectangle([0, 63, 400, 67], fill=DARK)
        d.rectangle([160, 40, 220, 54], fill=WHITE, outline=BLACK)  # Quarantine sign
        d.rectangle([164, 44, 216, 50], fill=BLACK)

    s.add(10, fence)

    def sandbags(x, y, cols=5, rows=3):
        def fn():
            shadow(d, [(x + cols * 16, y - 18), (x + cols * 16 + 10, y - 12), (x + cols * 16 + 10, y + 5), (x + 6, y + 5), (x, y)])
            d.rectangle([x, y - rows * 8 - 12, x + cols * 16, y - rows * 8], fill=LIGHT, outline=BLACK)  # Top layer seen from above
            for i in range(cols):
                d.line([(x + i * 16, y - rows * 8 - 12), (x + i * 16, y - rows * 8)], fill=MID)
            for r in range(rows):
                off = 8 if r % 2 else 0
                for i in range(-1, cols):
                    bx = x + i * 16 + off
                    if bx < x - 4 or bx + 16 > x + cols * 16 + 4:
                        continue
                    by = y - (r + 1) * 8
                    d.rounded_rectangle([bx, by, bx + 16, by + 8], 3, fill=LIGHT if r == rows - 1 else MID, outline=BLACK)
                    d.line([(bx + 3, by + 2), (bx + 8, by + 2)], fill=WHITE)

        s.add(y, fn)

    def jersey(x, y, n=3):
        def fn():
            for i in range(n):
                bx = x + i * 34
                d.polygon([(bx + 30, y - 4), (bx + 40, y + 2), (bx + 38, y + 6), (bx + 6, y + 6), (bx, y)], fill=DARK)
                d.polygon([(bx, y), (bx + 4, y - 8), (bx + 8, y - 20), (bx + 24, y - 20), (bx + 28, y - 8), (bx + 32, y)], fill=MID, outline=BLACK)
                d.rectangle([bx + 8, y - 24, bx + 24, y - 20], fill=WHITE, outline=BLACK)
                for k in range(3):  # Warning stripes
                    d.polygon([(bx + 6 + k * 8, y - 2), (bx + 10 + k * 8, y - 2), (bx + 14 + k * 8, y - 10), (bx + 10 + k * 8, y - 10)], fill=WHITE)

        s.add(y, fn)

    def tent(x, y, w=96):
        def fn():
            shadow(d, [(x + w, y - 20), (x + w + 18, y - 10), (x + w + 18, y + 8), (x + 8, y + 8), (x, y)])
            d.polygon([(x, y), (x + 8, y - 30), (x + w - 8, y - 30), (x + w, y)], fill=DARK, outline=BLACK)
            d.polygon([(x + 8, y - 30), (x + 18, y - 44), (x + w - 18, y - 44), (x + w - 8, y - 30)], fill=MID, outline=BLACK)
            d.line([(x + 18, y - 44), (x + w - 18, y - 44)], fill=WHITE)
            d.rectangle([x + w // 2 - 12, y - 30, x + w // 2 + 12, y - 6], fill=WHITE, outline=BLACK)  # Red cross panel
            d.rectangle([x + w // 2 - 3, y - 26, x + w // 2 + 3, y - 10], fill=BLACK)
            d.rectangle([x + w // 2 - 9, y - 21, x + w // 2 + 9, y - 15], fill=BLACK)
            d.polygon([(x + 14, y), (x + 24, y - 22), (x + 32, y)], fill=BLACK)  # Open flap
            for gx in (x - 2, x + w + 2):
                d.line([(gx, y), (gx + (-8 if gx < x + 10 else 8), y + 4)], fill=BLACK)

        s.add(y, fn)

    def tower(x, y):
        def fn():
            shadow(d, [(x + 30, y - 4), (x + 60, y + 6), (x + 56, y + 10), (x + 4, y + 6)])
            for lx in (x, x + 30):
                d.rectangle([lx, y - 60, lx + 3, y], fill=DARK, outline=BLACK)
            d.line([(x + 2, y - 50), (x + 31, y - 10)], fill=BLACK)
            d.line([(x + 31, y - 50), (x + 2, y - 10)], fill=BLACK)
            d.rectangle([x - 6, y - 80, x + 39, y - 58], fill=MID, outline=BLACK)
            d.rectangle([x - 2, y - 76, x + 35, y - 68], fill=BLACK)
            d.polygon([(x - 10, y - 80), (x + 16, y - 92), (x + 43, y - 80)], fill=DARK, outline=BLACK)

        s.add(y, fn)

    def crates(x, y):
        def detail(d, x, y, w, depth, h):
            d.line([(x, y - h), (x + w, y)], fill=BLACK)
            d.line([(x + w, y - h), (x, y)], fill=BLACK)
            d.rectangle([x + 4, y - h - depth + 3, x + w - 4, y - h - 3], outline=MID)

        box(s, x, y, 24, 12, 20, LIGHT, MID, detail)
        box(s, x + 26, y + 4, 24, 12, 20, LIGHT, MID, detail)

    tower(20, 130)
    tent(250, 120)
    sandbags(80, 200, 6, 3)
    sandbags(300, 220, 5, 2)
    jersey(120, 110, 3)
    crates(40, 226)
    common_cast(s, (210, 170), [(160, 150, "zombie_walker", 4, 1), (330, 160, "zombie_walker", 6, 2, True), (250, 210, "zombie_runner", 6, 3, True), (60, 160, "zombie_shambler", 4, 0)], (370, 90, 0), [(240, 190, 0), (130, 220, 102)])
    return s


def farm():
    s = Scene(6)
    rng = s.rng
    d = s.d
    # Ground: a ploughed field (sparse broken furrows) on the right, yard with tufts on the left
    for y in range(104, 240, 9):
        x = 200
        while x < 400:
            seg = rng.randint(10, 30)
            d.line([(x, y), (x + seg, y)], fill=DARK)
            x += seg + rng.randint(3, 8)
    tufts(s, 40, (0, 60, 190, 240), rng)
    specks(s, 30, (0, 60, 190, 240), rng, DARK)

    def barn(x, y, w=140):
        def fn():
            shadow(d, [(x + w, y - 40), (x + w + 24, y - 28), (x + w + 24, y + 10), (x + 10, y + 10), (x, y)])
            d.rectangle([x, y - 40, x + w, y], fill=MID, outline=BLACK)
            for px in range(x + 6, x + w, 6):  # Vertical boards
                d.line([(px, y - 39), (px, y - 1)], fill=DARK)
            # Gambrel roof from the front and above
            hatch(s, [(x - 6, y - 40), (x + 6, y - 58), (x + 30, y - 74), (x + w - 30, y - 74), (x + w - 6, y - 58), (x + w + 6, y - 40)], DARK, BLACK, 5)
            d.line([(x + 6, y - 58), (x + w - 6, y - 58)], fill=BLACK)
            d.polygon([(x + 30, y - 74), (x + w - 30, y - 74), (x + w - 12, y - 62), (x + 12, y - 62)], fill=MID, outline=BLACK)
            d.polygon([(x + 70, y - 72), (x + 96, y - 70), (x + 90, y - 60), (x + 74, y - 62)], fill=BLACK)  # Caved in
            # Big X braced doors, one hanging open
            dx = x + w // 2 - 26
            d.rectangle([dx, y - 34, dx + 52, y], fill=BLACK)
            d.rectangle([dx, y - 34, dx + 26, y], fill=WHITE, outline=BLACK)
            d.line([(dx, y - 34), (dx + 26, y)], fill=BLACK, width=2)
            d.line([(dx + 26, y - 34), (dx, y)], fill=BLACK, width=2)
            d.polygon([(dx + 52, y - 34), (dx + 64, y - 30), (dx + 64, y + 2), (dx + 52, y)], fill=LIGHT, outline=BLACK)
            d.rectangle([x + 16, y - 70 + 22, x + 30, y - 70 + 32], fill=BLACK)

        s.add(y, fn)

    def bale(x, y, r=12):
        def fn():
            d.ellipse([x - r + 6, y - 3, x + r + 14, y + 4], fill=DARK)
            d.rectangle([x, y - 2 * r, x + 24, y], fill=LIGHT, outline=BLACK)  # Roll body seen side on
            for by in range(y - 2 * r + 4, y, 4):
                d.line([(x + 2, by), (x + 22, by)], fill=MID)
            d.ellipse([x - r, y - 2 * r, x + r, y], fill=VLIGHT, outline=BLACK)  # Spiral end
            for k in range(3, r, 3):
                d.arc([x - k, y - r - k, x + k, y - r + k], 30 * k, 30 * k + 280, fill=BLACK)

        s.add(y, fn)

    def scarecrow(x, y):
        def fn():
            d.line([(x + 2, y), (x + 16, y + 6)], fill=DARK, width=2)
            d.rectangle([x - 1, y - 44, x + 1, y], fill=BLACK)
            d.rectangle([x - 18, y - 36, x + 18, y - 34], fill=BLACK)
            d.polygon([(x - 10, y - 36), (x + 10, y - 36), (x + 12, y - 18), (x - 12, y - 18)], fill=MID, outline=BLACK)  # Coat
            for k in range(-10, 12, 5):
                d.line([(x + k, y - 18), (x + k + 1, y - 13)], fill=BLACK)
            d.ellipse([x - 6, y - 50, x + 6, y - 38], fill=VLIGHT, outline=BLACK)
            d.polygon([(x - 12, y - 46), (x + 12, y - 46), (x + 4, y - 56), (x - 4, y - 56)], fill=DARK, outline=BLACK)  # Hat
            for k in (-18, 18):
                d.line([(x + k, y - 35), (x + k + (2 if k > 0 else -2), y - 30)], fill=BLACK)

        s.add(y, fn)

    def rail_fence(x, y, n=6, broken=(3,)):
        def fn():
            for i in range(n):
                px = x + i * 26
                d.rectangle([px, y - 18, px + 4, y], fill=MID, outline=BLACK)
                if i < n - 1:
                    if i in broken:
                        d.line([(px + 4, y - 14), (px + 22, y - 2)], fill=BLACK, width=3)
                        d.line([(px + 4, y - 14), (px + 22, y - 2)], fill=LIGHT)
                        continue
                    for ry in (y - 14, y - 7):
                        d.rectangle([px + 4, ry, px + 26, ry + 3], fill=LIGHT, outline=BLACK)

        s.add(y, fn)

    def tractor(x, y):
        def fn():
            d.polygon([(x + 4, y), (x + 70, y), (x + 76, y + 6), (x + 8, y + 6)], fill=DARK)
            d.rectangle([x + 20, y - 30, x + 64, y - 10], fill=MID, outline=BLACK)  # Bonnet
            d.rectangle([x + 4, y - 44, x + 28, y - 14], fill=LIGHT, outline=BLACK)  # Cab
            d.rectangle([x + 8, y - 40, x + 24, y - 30], fill=BLACK)
            d.rectangle([x + 54, y - 40, x + 58, y - 30], fill=BLACK)  # Exhaust
            d.ellipse([x - 4, y - 26, x + 26, y + 2], fill=BLACK)  # Big rear wheel
            d.ellipse([x + 4, y - 18, x + 18, y - 6], fill=MID)
            d.ellipse([x + 50, y - 14, x + 68, y + 2], fill=BLACK)
            d.ellipse([x + 55, y - 9, x + 63, y - 3], fill=MID)

        s.add(y, fn)

    barn(10, 108, 150)
    rail_fence(200, 70, 8, (2, 5))
    bale(240, 140)
    bale(270, 150, 10)
    scarecrow(340, 130)
    tractor(40, 210)
    bale(330, 228, 12)
    common_cast(s, (196, 176), [(260, 196, "zombie_walker", 6, 1, True), (130, 150, "zombie_shambler", 4, 2), (360, 176, "zombie_runner", 5, 1, True), (150, 220, "zombie_brute", 3, 3)], (60, 130, 1), [(220, 210, 3), (300, 170, 100)])
    return s


THEMES = [
    ("woodland", "Overgrown Woodland", "Round canopies + pines, logs, boulders, an abandoned camp. White ground, grass tufts"),
    ("suburb", "Abandoned Suburb", "Clapboard houses, picket fences, wrecked cars, hedges. Lawn + cracked road"),
    ("city", "Ruined City", "Shattered tower shells, rubble, burnt bus, bent lamps. Paving + zebra crossing"),
    ("factory", "Industrial Yard", "Corrugated walls, containers, drums, pallets, pipes. Concrete joints + hazard stripes"),
    ("military", "Quarantine Zone", "Sandbags, barriers, med tents, watchtower, razor wire. Sand + tyre tracks"),
    ("farm", "Dead Farm", "Gambrel barn, hay bales, scarecrow, tractor, rail fence. Ploughed furrows"),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="logs/mockups")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    shots = []
    for key, title, blurb in THEMES:
        img = globals()[key]().render()
        img.save(os.path.join(args.out, f"{key}.png"))
        shots.append((title, blurb, img))

    # Contact sheet: 2x, two columns, labelled
    scale, pad, label = 2, 16, 34
    cols = 2
    rows = (len(shots) + cols - 1) // cols
    sheet = Image.new("L", (cols * (W * scale + pad) + pad, rows * (H * scale + pad + label) + pad), 40)
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("arial.ttf", 18)
        small = ImageFont.truetype("arial.ttf", 13)
    except OSError:
        font = small = ImageFont.load_default()
    for i, (title, blurb, img) in enumerate(shots):
        cx = pad + (i % cols) * (W * scale + pad)
        cy = pad + (i // cols) * (H * scale + pad + label)
        d.text((cx, cy), f"{i + 1}. {title}", fill=255, font=font)
        d.text((cx, cy + 19), blurb, fill=190, font=small)
        sheet.paste(img.resize((W * scale, H * scale), Image.NEAREST), (cx, cy + label))
    sheet.save(os.path.join(args.out, "contact.png"))
    print(f"wrote {len(shots)} mock-ups and contact.png to {args.out}")


if __name__ == "__main__":
    main()
