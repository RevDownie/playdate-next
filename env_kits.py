"""
Environment kits: the level art for each theme, modelled in code from 2D primitives and dithered to 1-bit at final
size (the source of the art is this script, like drop_sprites.py).

A kit has
- pieces: obstacles placed on a level's `objects` layer. Each has a footprint in cells (it blocks those cells) and is
  drawn as one bitmap, `images/<kit>-piece-<n>.png`, anchored by `src/kit_descs.zig`
- ground: flat art placed on a level's `ground` layer (paths, roads, tracks). Never blocks
- decals: tiny ground details (grass tufts, cracks) scattered over the free floor by a hash of the cell
- outside: what fills the view beyond the map's edge
Ground, decals and the outside are baked offline into one bitmap per level by convert_tilemaps.py, so the game draws
the whole floor with one blit and no background tile.

Conventions (shared with convert_tilemaps.py and the renderer):
- Cells are CELL_W x CELL_H pixels. A piece is placed at the bottom-left cell of its footprint (like a Tiled tile),
  and its footprint extends right and up from there
- Pieces are drawn in local pixel coordinates: the footprint covers x 0..fw*CELL_W-1 and y -fh*CELL_H..-1, so the
  bottom-left cell's centre (the object's world position and depth) is ANCHOR_LOCAL
- Light from the top left. Solid shapes: lit faces white, shadow faces and cast shadows solid black, detail in black
  or white lines. Dither (MID, through one 4x4 Bayer matrix stepped in DITHER_CELL (2) pixel clusters) only as small
  accents: soot, mud, moss, the turn of a canopy. The reason is flicker: when the view scrolls a pixel, a single
  pixel checker inverts completely and the LCD shows it, clusters change at their edges, and solid areas only at
  their outline. Per kit, pieces lean one way for identity: woods black foliage with white lit edges, city white
  concrete and black burnt vehicles, quarantine dark canvas with white markings. Never use VLIGHT
- Or fine dither in phase variants (PHASES; the kits in DITHERED_KITS): single pixel LIGHT/MID/DARK
  shading and dithered shadows (p.dshadow), each piece and the kit's levels' floors rendered once per screen pixel
  phase, and the renderer draws the version whose dither lines up with the screen. The dither then stays still
  while things move, so it doesn't flicker either. Only tones that repeat every 2 pixels work (LIGHT, MID, DARK)
- The bottom border row and anything that can overlap the playfield from below is kept low (about one row), so
  it never hides the player
- The piece and ground lists are append only: an entry's index is its tile id in the Tiled tilesets and its id in
  every level file, so inserting or reordering one silently swaps art and footprints in every map

  python env_kits.py [images dir] [--preview logs/kits.png]
writes every kit's piece bitmaps, Tiled tilesets (map-tiles/kits/) and src/kit_descs.zig.
"""
import argparse
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw

CELL_W, CELL_H = 57, 27
ANCHOR_LOCAL = (CELL_W // 2, -CELL_H + CELL_H // 2)  # (28, -14): the centre of the footprint's bottom-left cell
GROUND_MARGIN_X, GROUND_MARGIN_Y = 256, 160  # Baked ground beyond the map's edges: covers the camera's widest lean

WHITE, VLIGHT, LIGHT, MID, DARK, BLACK = 255, 223, 191, 127, 63, 0
BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]])

CANVAS_W, CANVAS_H = 320, 260
ORIGIN = (96, 200)  # Canvas pixel of local (0, 0)


DITHER_CELL = 2  # The dither works on cells this many pixels square (see bayer_bw)
# Phase variants: art dithered with single pixel 25/50/75% tones (patterns that repeat every 2 pixels) is drawn in 4
# versions, one per pixel phase (screen x even/odd, y even/odd), and the renderer draws the version whose phase
# matches where the sprite lands. The dither then stays fixed to the screen and only the shapes move, so scrolling
# doesn't invert it (no flicker). Phase v = x phase + 2 * y phase
PHASES = 4
# Kits drawn with their fine dithered art in phase variants (the others use the solid style, one bitmap per piece)
DITHERED_KITS = {"woods", "city", "quarantine"}


def bayer_bw(tone, cell=None, phase=(0, 0)):
    """Tone image (L) -> boolean 'is white' through the Bayer matrix, aligned to the image and shifted by `phase`
    pixels. The matrix steps every `cell` (DITHER_CELL) pixels, so patterns are clusters rather than single pixels:
    when the view scrolls by a pixel, a single pixel checker inverts completely (the LCD shows that as flicker), while
    clusters only change at their edges. Shape edges stay at full resolution"""
    cell = cell or DITHER_CELL
    a = np.asarray(tone, dtype=np.float32)
    h, w = a.shape
    m = np.kron(BAYER4, np.ones((cell, cell), dtype=BAYER4.dtype))
    p = m.shape[0]
    m = np.roll(m, (-phase[1], -phase[0]), axis=(0, 1))
    thr = (np.tile(m, (h // p + 1, w // p + 1))[:h, :w] + 0.5) * 255 / 16
    return a > thr


class Pen:
    """Draws a piece in local coordinates onto a tone canvas plus two masks: `solid` (opaque) and `ink` (opaque
    only where the dither comes out black, for shadows and stipple)"""

    def __init__(self, seed=0):
        self.tone = Image.new("L", (CANVAS_W, CANVAS_H), WHITE)
        self.solid = Image.new("L", (CANVAS_W, CANVAS_H), 0)
        self.ink = Image.new("L", (CANVAS_W, CANVAS_H), 0)
        self.t = ImageDraw.Draw(self.tone)
        self.s = ImageDraw.Draw(self.solid)
        self.i = ImageDraw.Draw(self.ink)
        self.rng = random.Random(seed)

    @staticmethod
    def p(pts):
        return [(x + ORIGIN[0], y + ORIGIN[1]) for x, y in pts]

    @staticmethod
    def box(b):
        return [b[0] + ORIGIN[0], b[1] + ORIGIN[1], b[2] + ORIGIN[0], b[3] + ORIGIN[1]]

    def _masks(self, ink):
        return (self.i, self.s) if ink else (self.s, None)

    def polygon(self, pts, fill, outline=None, ink=False):
        pts = self.p(pts)
        self.t.polygon(pts, fill=fill, outline=outline)
        m, _ = self._masks(ink)
        m.polygon(pts, fill=255, outline=255 if outline is not None else None)
        if ink and outline is not None:
            self.s.polygon(pts, outline=255)

    def ellipse(self, b, fill, outline=None, ink=False):
        b = self.box(b)
        self.t.ellipse(b, fill=fill, outline=outline)
        m, _ = self._masks(ink)
        m.ellipse(b, fill=255, outline=255 if outline is not None else None)

    def rect(self, b, fill, outline=None, ink=False):
        b = self.box(b)
        self.t.rectangle(b, fill=fill, outline=outline)
        m, _ = self._masks(ink)
        m.rectangle(b, fill=255, outline=255 if outline is not None else None)

    def rrect(self, b, r, fill, outline=None):
        b = self.box(b)
        self.t.rounded_rectangle(b, r, fill=fill, outline=outline)
        self.s.rounded_rectangle(b, r, fill=255, outline=255 if outline is not None else None)

    def line(self, pts, fill, width=1, ink=False):
        pts = self.p(pts)
        self.t.line(pts, fill=fill, width=width)
        (self.i if ink else self.s).line(pts, fill=255, width=width)

    def arc(self, b, a0, a1, fill, width=1):
        b = self.box(b)
        self.t.arc(b, a0, a1, fill=fill, width=width)
        self.s.arc(b, a0, a1, fill=255, width=width)

    def chord(self, b, a0, a1, fill):
        b = self.box(b)
        self.t.chord(b, a0, a1, fill=fill)
        self.s.chord(b, a0, a1, fill=255)

    def point(self, xy, fill, ink=False):
        xy = (xy[0] + ORIGIN[0], xy[1] + ORIGIN[1])
        self.t.point(xy, fill=fill)
        (self.i if ink else self.s).point(xy, fill=255)

    def shadow(self, pts):
        """Cast shadows are solid black: big dithered areas flicker as the view scrolls"""
        self.polygon(pts, BLACK)

    def shadow_ellipse(self, b):
        self.ellipse(b, BLACK)

    def dshadow(self, pts):
        """A dithered cast shadow ("ink": only its black pixels are opaque, so it darkens what is under it). Only for
        art drawn with phase variants, where the dither stays fixed to the screen"""
        self.polygon(pts, DARK, ink=True)

    def dshadow_ellipse(self, b):
        self.ellipse(b, DARK, ink=True)

    def hatch(self, pts, fill, line, spacing, outline=BLACK):
        """Polygon filled with horizontal lines clipped to it (roofs, planks)"""
        cpts = self.p(pts)
        mask = Image.new("L", (CANVAS_W, CANVAS_H), 0)
        ImageDraw.Draw(mask).polygon(cpts, fill=255)
        layer = Image.new("L", (CANVAS_W, CANVAS_H), fill)
        ld = ImageDraw.Draw(layer)
        y0, y1 = int(min(p[1] for p in cpts)), int(max(p[1] for p in cpts))
        for y in range(y0 + spacing, y1, spacing):
            ld.line([(0, y), (CANVAS_W, y)], fill=line)
        self.tone.paste(layer, (0, 0), mask)
        self.s.polygon(cpts, fill=255, outline=255)
        self.t.polygon(cpts, outline=outline)

    def render(self, cell=None, phases=1):
        """-> (RGBA image per phase, local x, y of the top left, tone, solid mask, ink mask), all trimmed to what was
        drawn. Phase v dithers image pixel (i, j) as screen pixel (i + v % 2, j + v // 2) would be (see PHASES)"""
        cell = cell or DITHER_CELL
        solid = np.asarray(self.solid) > 0
        ink = np.asarray(self.ink) > 0
        ys, xs = np.nonzero(solid | ink)
        if len(xs) == 0:
            raise ValueError("Nothing drawn")
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        tone = np.asarray(self.tone)[y0:y1, x0:x1].copy()
        solid, ink = solid[y0:y1, x0:x1], ink[y0:y1, x0:x1]
        images = []
        for v in range(phases):
            white = bayer_bw(tone, cell, (v % 2, v // 2))
            alpha = solid | (ink & ~white)
            rgba = np.zeros(tone.shape + (4,), dtype=np.uint8)
            col = np.where(white, 255, 0).astype(np.uint8)
            rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = col
            rgba[..., 3] = np.where(alpha, 255, 0)
            images.append(Image.fromarray(rgba, "RGBA"))

        def mask(m):
            return Image.fromarray(np.where(m, 255, 0).astype(np.uint8), "L")
        return images, int(x0 - ORIGIN[0]), int(y0 - ORIGIN[1]), Image.fromarray(tone, "L"), mask(solid), mask(ink)


def jag(rng, cx, cy, rx, ry, n=9, amount=0.18, phase=0.0):
    pts = []
    for i in range(n):
        a = phase + i / n * math.tau
        k = 1 + rng.uniform(-amount, amount)
        pts.append((cx + math.cos(a) * rx * k, cy + math.sin(a) * ry * k))
    return pts


class Art:
    """A drawn piece: its bitmap, where its top left sits in local coordinates, and its footprint in cells"""

    def __init__(self, name, fw, fh, draw, seed=0, keep_decals=False, cell=None, phases=1):
        self.name, self.fw, self.fh = name, fw, fh
        self.keep_decals = keep_decals  # Ground art the kit's decals may still be scattered over
        pen = Pen(seed)
        draw(pen)
        self.images, self.x0, self.y0, self.tone, self.solid_mask, self.ink_mask = pen.render(cell, phases)
        self.image = self.images[0]
        self.tone_mask = Image.fromarray(np.maximum(np.asarray(self.solid_mask), np.asarray(self.ink_mask)), "L")

    @property
    def anchor(self):
        return ANCHOR_LOCAL[0] - self.x0, ANCHOR_LOCAL[1] - self.y0

    @property
    def anchor_flipped_x(self):
        """The anchor of the bitmap drawn mirrored (kBitmapFlippedX): mirrored about the footprint's centre"""
        fpw = self.fw * CELL_W
        return ANCHOR_LOCAL[0] - (fpw - self.x0 - self.image.width)

    def placed(self, flipped=False):
        """(image, anchor) to paste at a cell centre"""
        if flipped:
            return self.image.transpose(Image.FLIP_LEFT_RIGHT), (self.anchor_flipped_x, self.anchor[1])
        return self.image, self.anchor

    def placed_layers(self, flipped=False):
        """(tone, solid mask, ink mask, anchor), to composite and dither once across a baked level"""
        layers = (self.tone, self.solid_mask, self.ink_mask)
        if flipped:
            return tuple(m.transpose(Image.FLIP_LEFT_RIGHT) for m in layers) + ((self.anchor_flipped_x, self.anchor[1]),)
        return layers + (self.anchor,)

    def placed_tone(self, flipped=False):
        """(tone, mask, anchor) of flat ground art, to dither once across the baked level"""
        if flipped:
            return self.tone.transpose(Image.FLIP_LEFT_RIGHT), self.tone_mask.transpose(Image.FLIP_LEFT_RIGHT), (self.anchor_flipped_x, self.anchor[1])
        return self.tone, self.tone_mask, self.anchor

    def tiled_preview(self):
        """For Tiled, which draws a tile with its bottom-left on the cell's bottom-left: crop anything left of or
        below the footprint"""
        left, bottom = max(0, -self.x0), min(self.image.height, -self.y0)
        return self.image.crop((left, 0, self.image.width, bottom))


# ================================================================ Woodland

def w_pine(tall):
    hgt = 62 if tall else 50
    wide = 17 if tall else 15

    def draw(p):
        x, y = 28, -6
        p.shadow([(x - 4, y - 1), (x + 28, y + 3), (x + 22, y + 6), (x - 10, y + 4)])
        for bx in (-14, 10):  # Undergrowth around the base fills the blocked cell
            p.ellipse([x + bx - 8, y - 7, x + bx + 8, y + 2], BLACK)
            p.arc([x + bx - 6, y - 7, x + bx + 4, y - 1], 190, 330, WHITE)
        p.rect([x - 2, y - 9, x + 2, y], BLACK)
        for i, (wdt, top) in enumerate(((wide, 0.52), (wide - 4, 0.27), (wide - 8, 0.0))):
            ty, by = y - hgt + int(hgt * top), y - 8 - int(i * hgt * 0.22)
            p.polygon([(x, ty), (x + wdt, by), (x - wdt, by)], BLACK)
            p.polygon([(x - 1, ty + 3), (x - wdt + 3, by - 1), (x - 3, by - 2)], WHITE, BLACK)  # Lit left flank
            p.line([(x - wdt + 5, by - 4), (x - 5, by - 6)], BLACK)
        p.rect([x - 4, y - 14, x - 1, y - 10], MID)  # Accent

    return draw


def w_oak(r, seed):
    def draw(p):
        rng = random.Random(seed)
        x, y = 28, -6
        p.shadow_ellipse([x - r + 8, y - 4, x + r + 12, y + 5])
        p.ellipse([x - 16, y - 6, x + 14, y + 3], BLACK)  # Roots and leaf litter
        p.rect([x - 3, y - 20, x + 3, y - 1], BLACK)
        p.line([(x - 1, y - 18), (x - 1, y - 4)], WHITE)
        cy = y - 20 - r * 0.7
        parts = [(x - r * 0.45, cy + 3, r * 0.7), (x + r * 0.45, cy + 4, r * 0.7), (x, cy - r * 0.35, r * 0.75), (x, cy + r * 0.2, r * 0.8)]
        for px, py, pr in parts:  # The canopy: a black mass
            p.polygon(jag(rng, px, py, pr + 1, pr * 0.8 + 1, 11, 0.1), BLACK)
        p.polygon(jag(rng, x - r * 0.2, cy - r * 0.35, r * 0.62, r * 0.42, 10, 0.12), WHITE, BLACK)  # Lit cap
        p.polygon(jag(rng, x + r * 0.15, cy + r * 0.05, r * 0.42, r * 0.22, 8, 0.15), MID)  # Accent: the turn
        for _ in range(5):
            lx, ly = x + rng.uniform(-r * 0.7, r * 0.6), cy + rng.uniform(0, r * 0.5)
            p.arc([lx - 3, ly - 2, lx + 3, ly + 2], 200, 340, WHITE)

    return draw


def w_dead_tree(p):
    x, y = 28, -6
    p.shadow([(x, y - 1), (x + 34, y + 5), (x + 30, y + 7), (x - 4, y + 3)])
    p.ellipse([x - 12, y - 5, x + 12, y + 3], WHITE, BLACK)
    p.polygon([(x - 4, y), (x - 3, y - 40), (x + 1, y - 52), (x + 3, y - 40), (x + 4, y)], BLACK)
    p.line([(x - 2, y - 38), (x - 2, y - 2)], WHITE)
    for (sx, sy), (ex, ey) in (((x - 2, y - 30), (x - 18, y - 46)), ((x + 2, y - 24), (x + 16, y - 40)), ((x - 12, y - 40), (x - 20, y - 42)), ((x + 10, y - 34), (x + 20, y - 34)), ((x, y - 44), (x - 6, y - 58))):
        p.line([(sx, sy), (ex, ey)], BLACK, 2)
    p.line([(x + 1, y - 46), (x + 8, y - 58)], BLACK, 1)


def w_bush(p):
    x, y = 28, -6
    p.shadow_ellipse([x - 16, y - 3, x + 30, y + 5])
    pts = []
    for i in range(13):
        a = math.pi + i / 12 * math.pi
        rr = 24 if i % 2 else 20
        pts.append((x + math.cos(a) * rr, y - 4 + math.sin(a) * rr * 0.75))
    pts += [(x + 24, y + 1), (x - 24, y + 1)]
    p.polygon(pts, BLACK)
    for bx in (-14, -4, 6):  # Lit leaf clumps
        p.arc([bx + x - 6, y - 18, bx + x + 4, y - 10], 190, 330, WHITE)
        p.arc([bx + x - 4, y - 14, bx + x + 4, y - 8], 200, 320, WHITE)
    p.rect([x + 8, y - 6, x + 16, y - 3], MID)  # Accent


def w_boulder(p):
    x, y = 56, -10
    p.shadow([(x + 30, y - 30), (x + 56, y - 18), (x + 52, y + 7), (x - 22, y + 7), (x - 40, y)])
    outline = [(x - 46, y), (x - 50, y - 18), (x - 34, y - 42), (x - 6, y - 50), (x + 26, y - 46), (x + 46, y - 26), (x + 48, y - 6), (x + 40, y + 2)]
    p.polygon(outline, WHITE, BLACK)
    p.polygon([(x + 6, y - 28), (x + 22, y - 44), (x + 44, y - 26), (x + 46, y - 6), (x + 30, y - 10)], BLACK)  # Shadow face
    p.line([(x - 46, y - 18), (x - 18, y - 22), (x + 6, y - 28)], BLACK)
    p.line([(x - 18, y - 22), (x - 22, y - 2)], BLACK)
    p.line([(x + 6, y - 28), (x + 2, y - 4)], BLACK)
    p.line([(x - 30, y - 12), (x - 24, y - 6), (x - 26, y - 1)], BLACK)  # Crack
    p.polygon([(x - 44, y - 3), (x - 30, y - 6), (x - 8, y - 4), (x - 6, y + 1), (x - 44, y + 1)], MID)  # Accent: grime
    p.ellipse([x - 54, y - 6, x - 40, y + 3], WHITE, BLACK)
    p.ellipse([x + 44, y - 4, x + 54, y + 3], BLACK)


def w_rock(p):
    x, y = 28, -6
    p.shadow_ellipse([x - 8, y - 3, x + 24, y + 4])
    p.polygon([(x - 16, y), (x - 18, y - 10), (x - 6, y - 20), (x + 10, y - 18), (x + 18, y - 8), (x + 16, y)], WHITE, BLACK)
    p.polygon([(x + 4, y - 9), (x + 17, y - 8), (x + 15, y), (x + 5, y)], BLACK)
    p.line([(x - 16, y - 10), (x + 4, y - 9)], BLACK)


def w_log(p):
    x, y, length = 6, -8, 100
    p.shadow([(x + 6, y), (x + length + 10, y), (x + length + 6, y + 6), (x + 2, y + 6)])
    p.rrect([x, y - 13, x + length, y], 6, WHITE, BLACK)
    p.rect([x + 3, y - 5, x + length - 6, y - 1], BLACK)  # Underside in shadow
    for bx in range(x + 10, x + length - 10, 9):  # Bark
        p.line([(bx, y - 9), (bx + 5, y - 9)], BLACK)
    p.ellipse([x + length - 9, y - 13, x + length + 2, y], WHITE, BLACK)
    p.ellipse([x + length - 6, y - 10, x + length - 1, y - 4], None, BLACK)
    p.line([(x + 24, y - 13), (x + 20, y - 22), (x + 15, y - 24)], BLACK)
    p.line([(x + 62, y - 13), (x + 66, y - 20)], BLACK)
    for fx in (x + 34, x + 44):  # Fern tufts
        p.line([(fx, y - 13), (fx - 3, y - 18)], BLACK)
        p.line([(fx, y - 13), (fx + 3, y - 18)], BLACK)
    p.rect([x + 50, y - 12, x + 58, y - 9], MID)  # Accent: moss


def w_stump(p):
    x, y = 28, -6
    p.shadow_ellipse([x - 4, y - 3, x + 24, y + 4])
    for rx in (-14, 12):
        p.line([(x + rx * 0.5, y - 3), (x + rx, y + 1)], BLACK, 2)
    p.rect([x - 10, y - 14, x + 10, y - 1], WHITE, BLACK)
    p.rect([x + 3, y - 13, x + 10, y - 1], BLACK)
    p.ellipse([x - 10, y - 18, x + 10, y - 10], WHITE, BLACK)
    p.ellipse([x - 6, y - 16, x + 6, y - 12], None, BLACK)


def w_tent(p):
    x, y = 20, -14
    p.shadow([(x + 60, y - 4), (x + 82, y + 3), (x + 74, y + 8), (x + 10, y + 7)])
    p.polygon([(x, y), (x + 32, y - 40), (x + 66, y)], WHITE, BLACK)
    p.polygon([(x + 32, y - 40), (x + 66, y), (x + 48, y)], BLACK)  # Shaded side
    p.polygon([(x + 22, y), (x + 32, y - 20), (x + 40, y)], BLACK)  # Torn open flap
    p.polygon([(x + 40, y), (x + 34, y - 16), (x + 46, y - 6)], WHITE, BLACK)
    p.line([(x + 32, y - 40), (x + 32, y - 46)], BLACK)
    p.line([(x - 4, y + 2), (x + 6, y - 4)], BLACK)  # Guy ropes
    p.line([(x + 70, y + 2), (x + 60, y - 4)], BLACK)
    p.rect([x + 72, y - 12, x + 84, y], WHITE, BLACK)  # Rucksack
    p.line([(x + 74, y - 8), (x + 82, y - 8)], BLACK)
    p.rect([x + 4, y - 3, x + 20, y - 1], MID)  # Accent: mud


def w_car(p):
    x, y = 8, -10
    p.shadow([(x + 6, y), (x + 100, y), (x + 108, y + 7), (x + 12, y + 7)])
    p.rrect([x, y - 30, x + 96, y - 8], 6, BLACK)  # Rusted body from above
    p.rrect([x + 24, y - 38, x + 70, y - 16], 4, WHITE, BLACK)  # Roof
    p.rect([x + 26, y - 17, x + 68, y - 11], BLACK, WHITE)  # Windscreen frame, glass gone
    p.rect([x, y - 11, x + 96, y], BLACK)
    for wx in (x + 10, x + 72):
        p.ellipse([wx, y - 7, wx + 14, y + 3], BLACK, WHITE)
    p.rect([x + 6, y - 26, x + 16, y - 21], MID)  # Accent: rust
    p.line([(x + 30, y), (x + 34, y - 14), (x + 44, y - 24), (x + 40, y - 36)], WHITE, 2)  # Vines over it
    for lx, ly in ((x + 34, y - 14), (x + 44, y - 24), (x + 40, y - 34)):
        p.ellipse([lx - 4, ly - 3, lx + 4, ly + 2], WHITE, BLACK)
    p.line([(x + 86, y), (x + 90, y - 18)], WHITE, 2)
    p.ellipse([x + 86, y - 22, x + 94, y - 16], WHITE, BLACK)


# Woodland, dithered: the original fine shading, drawn with 4 pixel phase variants so the dither stays fixed
# to the screen (see PHASES). Swapped in for the solid w_* pieces while the kit is in DITHERED_KITS

def wd_pine(tall):
    hgt = 62 if tall else 50
    wide = 17 if tall else 15

    def draw(p):
        x, y = 28, -6
        p.dshadow([(x - 4, y - 2), (x + 30, y + 3), (x + 24, y + 8), (x - 10, y + 6)])
        for bx in (-14, 10):  # Undergrowth around the base fills the blocked cell
            p.ellipse([x + bx - 8, y - 7, x + bx + 8, y + 2], MID, BLACK)
            p.arc([x + bx - 6, y - 7, x + bx + 4, y - 1], 190, 330, WHITE)
        p.rect([x - 2, y - 9, x + 2, y], BLACK)
        tiers = ((wide, 0.52), (wide - 4, 0.27), (wide - 8, 0.0))
        for i, (wdt, top) in enumerate(tiers):
            ty, by = y - hgt + int(hgt * top), y - 8 - int(i * hgt * 0.22)
            p.polygon([(x, ty), (x + wdt, by), (x - wdt, by)], DARK, BLACK)
            p.polygon([(x, ty + 3), (x - wdt + 4, by - 1), (x - 1, by - 1)], MID)
            p.line([(x - wdt + 2, by - 1), (x + wdt - 2, by - 1)], BLACK)
            p.line([(x - wdt + 6, by - 3), (x - 3, ty + 6)], LIGHT)

    return draw


def wd_oak(r, seed):
    def draw(p):
        rng = random.Random(seed)
        x, y = 28, -6
        p.dshadow_ellipse([x - r + 8, y - 5, x + r + 14, y + 6])
        p.ellipse([x - 16, y - 6, x + 14, y + 3], DARK, BLACK)  # Roots and leaf litter
        p.rect([x - 3, y - 20, x + 3, y - 1], DARK, BLACK)
        p.line([(x - 1, y - 18), (x - 1, y - 3)], MID)
        cy = y - 20 - r * 0.7
        parts = [(x - r * 0.45, cy + 3, r * 0.7), (x + r * 0.45, cy + 4, r * 0.7), (x, cy - r * 0.35, r * 0.75), (x, cy + r * 0.2, r * 0.8)]
        outlines = [jag(rng, px, py, pr + 1, pr * 0.8 + 1, 11, 0.1) for px, py, pr in parts]
        for o in outlines:
            p.polygon(o, BLACK)
        for px, py, pr in parts:
            p.polygon(jag(rng, px, py, pr, pr * 0.8, 11, 0.1), MID)
        p.polygon(jag(rng, x - r * 0.25, cy - r * 0.3, r * 0.55, r * 0.4, 9, 0.12), LIGHT)
        p.chord([x - r + 1, cy + r * 0.1, x + r - 1, cy + r * 0.8], 0, 180, DARK)
        for _ in range(5):
            lx, ly = x + rng.uniform(-r * 0.6, r * 0.3), cy + rng.uniform(-r * 0.6, 0)
            p.arc([lx - 3, ly - 2, lx + 3, ly + 2], 180, 360, WHITE)

    return draw


def wd_dead_tree(p):
    x, y = 28, -6
    p.dshadow([(x, y - 1), (x + 34, y + 6), (x + 30, y + 8), (x - 4, y + 3)])
    p.ellipse([x - 12, y - 5, x + 12, y + 3], MID, BLACK)
    p.polygon([(x - 4, y), (x - 3, y - 40), (x + 1, y - 52), (x + 3, y - 40), (x + 4, y)], DARK, BLACK)
    p.line([(x - 2, y - 38), (x - 2, y - 2)], LIGHT)
    for (sx, sy), (ex, ey) in (((x - 2, y - 30), (x - 18, y - 46)), ((x + 2, y - 24), (x + 16, y - 40)), ((x - 12, y - 40), (x - 20, y - 42)), ((x + 10, y - 34), (x + 20, y - 34)), ((x, y - 44), (x - 6, y - 58))):
        p.line([(sx, sy), (ex, ey)], BLACK, 2)
    p.line([(x + 1, y - 46), (x + 8, y - 58)], BLACK, 1)


def wd_bush(p):
    x, y = 28, -6
    p.dshadow_ellipse([x - 18, y - 4, x + 30, y + 6])
    pts = []
    for i in range(13):
        a = math.pi + i / 12 * math.pi
        rr = 24 if i % 2 else 20
        pts.append((x + math.cos(a) * rr, y - 4 + math.sin(a) * rr * 0.75))
    pts += [(x + 24, y + 1), (x - 24, y + 1)]
    p.polygon(pts, MID, BLACK)
    p.chord([x - 22, y - 10, x + 22, y + 2], 0, 180, DARK)
    for bx in (-14, -4, 6):
        p.arc([bx + x - 6, y - 18, bx + x + 4, y - 10], 190, 330, WHITE)
    p.line([(x - 23, y + 1), (x + 23, y + 1)], BLACK)


def wd_boulder(p):
    rng = random.Random(7)
    x, y = 56, -10
    p.dshadow([(x + 30, y - 30), (x + 58, y - 18), (x + 54, y + 8), (x - 20, y + 8), (x - 40, y)])
    outline = [(x - 46, y), (x - 50, y - 18), (x - 34, y - 42), (x - 6, y - 50), (x + 26, y - 46), (x + 46, y - 26), (x + 48, y - 6), (x + 40, y + 2)]
    p.polygon(outline, MID, BLACK)
    p.polygon([(x - 46, y - 18), (x - 32, y - 40), (x - 6, y - 48), (x + 22, y - 44), (x + 6, y - 28), (x - 18, y - 22)], WHITE, BLACK)
    p.polygon([(x + 6, y - 28), (x + 22, y - 44), (x + 44, y - 26), (x + 46, y - 6), (x + 30, y - 10)], DARK, BLACK)
    p.line([(x - 18, y - 22), (x - 22, y - 2)], BLACK)
    p.line([(x + 6, y - 28), (x + 2, y - 4)], BLACK)
    for _ in range(4):
        cx, cy = x + rng.randint(-36, -4), y - rng.randint(28, 40)
        p.line([(cx, cy), (cx + 5, cy - 1)], MID)
    p.ellipse([x - 54, y - 6, x - 40, y + 3], LIGHT, BLACK)  # A loose stone
    p.ellipse([x + 44, y - 4, x + 54, y + 3], MID, BLACK)


def wd_rock(p):
    x, y = 28, -6
    p.dshadow_ellipse([x - 10, y - 4, x + 24, y + 5])
    p.polygon([(x - 16, y), (x - 18, y - 10), (x - 6, y - 20), (x + 10, y - 18), (x + 18, y - 8), (x + 16, y)], MID, BLACK)
    p.polygon([(x - 16, y - 10), (x - 6, y - 18), (x + 8, y - 16), (x - 2, y - 9)], WHITE)
    p.polygon([(x + 4, y - 8), (x + 16, y - 8), (x + 15, y - 1), (x + 6, y - 1)], DARK)


def wd_log(p):
    x, y, length = 6, -8, 100
    p.dshadow([(x + 6, y), (x + length + 10, y), (x + length + 6, y + 7), (x + 2, y + 7)])
    p.rrect([x, y - 13, x + length, y], 6, MID, BLACK)
    p.line([(x + 4, y - 10), (x + length - 8, y - 10)], LIGHT)
    for bx in range(x + 10, x + length - 10, 9):
        p.line([(bx, y - 5), (bx + 5, y - 5)], BLACK)
    p.ellipse([x + length - 9, y - 13, x + length + 2, y], WHITE, BLACK)
    p.ellipse([x + length - 6, y - 10, x + length - 1, y - 4], None, MID)
    p.line([(x + 24, y - 13), (x + 20, y - 22), (x + 15, y - 24)], BLACK)
    p.line([(x + 62, y - 13), (x + 66, y - 20)], BLACK)
    for fx in (x + 34, x + 44):  # Moss / fern tufts
        p.line([(fx, y - 13), (fx - 3, y - 18)], BLACK)
        p.line([(fx, y - 13), (fx + 3, y - 18)], BLACK)


def wd_stump(p):
    x, y = 28, -6
    p.dshadow_ellipse([x - 6, y - 4, x + 24, y + 5])
    for rx in (-14, 12):
        p.line([(x + rx * 0.5, y - 3), (x + rx, y + 1)], BLACK, 2)
    p.rect([x - 10, y - 14, x + 10, y - 1], MID, BLACK)
    p.rect([x + 3, y - 13, x + 9, y - 2], DARK)
    p.ellipse([x - 10, y - 18, x + 10, y - 10], WHITE, BLACK)
    p.ellipse([x - 6, y - 16, x + 6, y - 12], None, MID)
    p.line([(x - 2, y - 14), (x + 2, y - 14)], MID)


def wd_tent(p):
    x, y = 20, -14
    p.dshadow([(x + 60, y - 4), (x + 82, y + 4), (x + 74, y + 10), (x + 10, y + 8)])
    p.polygon([(x, y), (x + 32, y - 40), (x + 66, y)], MID, BLACK)
    p.polygon([(x + 32, y - 40), (x + 66, y), (x + 48, y)], DARK, BLACK)
    p.polygon([(x + 22, y), (x + 32, y - 20), (x + 40, y)], BLACK)  # Torn open flap
    p.polygon([(x + 40, y), (x + 34, y - 16), (x + 46, y - 6)], LIGHT, BLACK)
    p.line([(x + 32, y - 40), (x + 32, y - 46)], BLACK)
    p.line([(x - 4, y + 2), (x + 6, y - 4)], BLACK)  # Guy ropes
    p.line([(x + 70, y + 2), (x + 60, y - 4)], BLACK)
    p.rect([x + 72, y - 12, x + 84, y], LIGHT, BLACK)  # Rucksack
    p.line([(x + 74, y - 8), (x + 82, y - 8)], BLACK)


def wd_car(p):
    x, y = 8, -10
    p.dshadow([(x + 6, y), (x + 100, y), (x + 108, y + 8), (x + 12, y + 8)])
    p.rrect([x, y - 30, x + 96, y - 8], 6, MID, BLACK)  # Body from above
    p.rrect([x + 24, y - 38, x + 70, y - 16], 4, LIGHT, BLACK)
    p.rect([x + 26, y - 17, x + 68, y - 11], BLACK)  # Windscreen, gone
    p.rect([x, y - 11, x + 96, y], DARK, BLACK)
    for wx in (x + 10, x + 72):
        p.ellipse([wx, y - 7, wx + 14, y + 3], BLACK)
    p.ellipse([x + 6, y - 26, x + 14, y - 20], DARK)
    p.ellipse([x + 80, y - 28, x + 90, y - 22], DARK)
    # Vines over it
    p.line([(x + 30, y), (x + 34, y - 14), (x + 44, y - 24), (x + 40, y - 36)], BLACK, 2)
    for lx, ly in ((x + 34, y - 14), (x + 44, y - 24), (x + 40, y - 34)):
        p.ellipse([lx - 4, ly - 3, lx + 4, ly + 2], LIGHT, BLACK)
    p.line([(x + 86, y), (x + 90, y - 18)], BLACK, 2)
    p.ellipse([x + 86, y - 22, x + 94, y - 16], LIGHT, BLACK)


# Woodland ground (flat, never blocks)


def wg_path(seed):
    """A worn trail: no fill (its cells get no grass tufts, so it reads as a clear lane), just ruts and pebbles"""
    def draw(p):
        rng = random.Random(seed)
        for _ in range(2):
            sx, sy = rng.randint(6, 40), rng.randint(-22, -6)
            p.line([(sx, sy), (sx + rng.randint(6, 12), sy + rng.choice((-1, 0, 1)))], BLACK)
        for _ in range(3):
            sx, sy = rng.randint(4, 50), rng.randint(-24, -4)
            p.ellipse([sx, sy, sx + 4, sy + 3], WHITE, BLACK)
    return draw


def wg_fire_ring(p):
    x, y = 28, -12
    p.ellipse([x - 8, y - 3, x + 8, y + 3], MID, ink=True)  # Accent: ash
    for i in range(8):
        a = i / 8 * math.tau
        cx, cy = x + math.cos(a) * 13, y + math.sin(a) * 6
        p.ellipse([cx - 3, cy - 2, cx + 3, cy + 2], WHITE, BLACK)
    p.line([(x - 6, y), (x + 6, y - 2)], BLACK, 2)
    p.line([(x - 4, y - 3), (x + 5, y + 2)], BLACK, 2)


def wg_leaves(p):
    rng = random.Random(4)
    for _ in range(18):
        lx, ly = rng.randint(2, 54), rng.randint(-24, -2)
        p.line([(lx, ly), (lx + 2, ly - 1)], BLACK)


def wg_puddle(p):
    p.ellipse([4, -22, 52, -4], None, BLACK)
    p.line([(12, -16), (22, -16)], BLACK)
    p.line([(30, -10), (42, -10)], BLACK)


def d_tuft(size):
    def draw(p):
        x, y = 6, -3
        p.line([(x - size + 1, y - size), (x, y)], BLACK)
        p.line([(x + size - 1, y - size), (x, y)], BLACK)
        p.line([(x, y - size - 1), (x, y)], BLACK)
    return draw


def d_flower(p):
    p.line([(4, -2), (4, -5)], BLACK)
    for dx, dy in ((-1, -6), (1, -6), (0, -7), (0, -5)):
        p.point((4 + dx, dy), BLACK)


def d_pebbles(p):
    p.ellipse([0, -4, 3, -1], BLACK)
    p.ellipse([5, -3, 7, -1], BLACK)


def d_twig(p):
    p.line([(0, -2), (8, -4)], BLACK)
    p.line([(5, -3), (7, -6)], BLACK)


# ================================================================ Ruined City

def c_facade(floors, broken_seed, door=False):
    """A slice of building front exactly one cell wide with no side outlines, so a row of them reads as one street
    of buildings. For the top border"""
    def draw(p):
        rng = random.Random(broken_seed)
        base, fh = -4, 22
        top = base - floors * fh - 6
        edge = [(0, base)]
        for i in range(5):  # Broken skyline
            edge.append((i * 14, top + rng.randint(0, 14 if broken_seed else 3)))
        edge += [(56, top + rng.randint(0, 10 if broken_seed else 3)), (56, base)]
        p.polygon(edge, WHITE)
        p.line(edge[1:-1], BLACK)
        for f in range(floors):
            fy = base - (f + 1) * fh
            p.line([(0, fy + fh - 1), (56, fy + fh - 1)], BLACK)
            for wx in (7, 33):
                if fy + 4 > top + 12 or f == 0:
                    if not (door and f == 0):
                        p.rect([wx, fy + 5, wx + 14, fy + 15], BLACK)
            if f == floors - 1 and broken_seed:
                p.rect([7, fy, 21, fy + 4], MID)  # Accent: soot over a window
        if door:
            p.rect([6, base - 20, 50, base - 1], BLACK)  # Shop shutter, half up
            for sy in range(base - 18, base - 8, 3):
                p.line([(7, sy), (49, sy)], WHITE)
        p.rect([0, base, 56, base + 2], BLACK)  # Shadow at the foot
        for _ in range(3):
            rx = rng.randint(2, 50)
            p.polygon(jag(rng, rx, base + 1, 4, 2, 5, 0.3), WHITE, BLACK)
    return draw


def c_wall_side(p):
    """Side border: a broken wall seen end on, rows of them making one line"""
    x, y = 28, -4
    p.shadow([(x + 8, y - 6), (x + 18, y - 2), (x + 18, y + 2), (x - 6, y + 2)])
    p.polygon([(x - 8, y), (x - 8, y - 40), (x - 3, y - 46), (x + 2, y - 41), (x + 8, y - 44), (x + 8, y)], WHITE, BLACK)
    p.rect([x + 2, y - 40, x + 8, y], BLACK)
    for by in range(y - 36, y, 9):
        p.line([(x - 7, by), (x - 2, by)], BLACK)
    p.polygon([(x - 16, y), (x - 12, y - 6), (x - 6, y - 4), (x - 8, y + 1)], WHITE, BLACK)
    p.polygon([(x + 10, y + 1), (x + 12, y - 5), (x + 18, y - 3), (x + 17, y + 1)], BLACK)


def c_rubble_low(p):
    """Bottom border: low broken concrete, nothing taller than a row"""
    rng = random.Random(21)
    p.shadow_ellipse([4, -8, 60, 2])
    for cx, cy, r, tone in ((12, -6, 8, WHITE), (28, -8, 10, WHITE), (44, -5, 8, BLACK), (20, -3, 5, BLACK), (38, -2, 6, WHITE)):
        p.polygon(jag(rng, cx, cy, r, r * 0.7, 6, 0.3), tone, BLACK)
    p.line([(8, -12), (24, -20)], BLACK, 2)


def c_ruin(p):
    """A gutted building: three cells wide, the front wall standing with its upper floors gone"""
    rng = random.Random(5)
    x0, x1, base, h = 4, 164, -8, 74
    p.shadow([(x1, base - 24), (x1 + 20, base - 12), (x1 + 20, base + 7), (x0 + 10, base + 7), (x0, base)])
    edge = [(x0, base)]
    for i in range(11):
        tx = x0 + (x1 - x0) * i / 10
        edge.append((tx, base - h + (0 if i in (0, 10) else rng.randint(-2, 30))))
    edge.append((x1, base))
    p.polygon(edge, WHITE, BLACK)
    for wy in range(base - h + 16, base - 18, 18):
        for wx in range(x0 + 10, x1 - 16, 22):
            if rng.random() < 0.85:
                p.rect([wx, wy, wx + 12, wy + 10], BLACK)
                if rng.random() < 0.35:  # Accent: soot over a few windows
                    p.rect([wx, wy - 6, wx + 12, wy - 1], MID)
    p.rect([x0 + 70, base - 24, x0 + 92, base], BLACK)  # Doorway
    for fy in range(base - h + 33, base - 4, 18):  # Floor lines, broken
        p.line([(x0 + 2, fy), (x0 + 40, fy)], BLACK)
        p.line([(x0 + 100, fy), (x0 + 150, fy)], BLACK)
    for _ in range(5):
        rx = rng.randint(x0 + 10, x1 - 10)
        p.line([(rx, base - h + 26), (rx + rng.randint(-5, 5), base - h + 8)], BLACK)
    for cx in (x0 + 20, x0 + 120, x1 - 6):
        p.polygon(jag(rng, cx, base, 9, 5, 6, 0.3), WHITE, BLACK)


def c_rubble_pile(p):
    rng = random.Random(9)
    x, y = 57, -10
    p.shadow_ellipse([x - 40, y - 6, x + 58, y + 7])
    for i in range(16):
        cx, cy = x + rng.randint(-40, 40), y - rng.randint(0, 16)
        r = rng.randint(4, 9)
        p.polygon(jag(rng, cx, cy, r + 1, r * 0.75, 5, 0.3), BLACK if i % 4 == 3 else WHITE, BLACK)
    p.line([(x - 22, y - 16), (x + 4, y - 30)], BLACK, 3)  # Girder
    p.line([(x + 18, y - 10), (x + 26, y - 26)], BLACK)
    p.rect([x - 10, y - 4, x + 2, y - 1], MID)  # Accent: dust


def c_rubble_small(p):
    rng = random.Random(13)
    x, y = 28, -8
    p.shadow_ellipse([x - 18, y - 4, x + 28, y + 5])
    for i in range(8):
        cx, cy = x + rng.randint(-16, 16), y - rng.randint(0, 9)
        r = rng.randint(3, 6)
        p.polygon(jag(rng, cx, cy, r + 1, r * 0.75, 5, 0.3), BLACK if i % 3 == 2 else WHITE, BLACK)


def c_bus(p):
    x, y, ln = 10, -6, 150
    p.shadow([(x + 6, y), (x + ln + 2, y), (x + ln + 12, y + 7), (x + 12, y + 7)])
    p.rect([x, y - 42, x + ln, y - 26], WHITE, BLACK)  # Roof
    for bx, bw in ((44, 30), (104, 16)):
        p.polygon([(x + bx, y - 42), (x + bx + bw, y - 40), (x + bx + bw - 6, y - 28), (x + bx + 4, y - 30)], BLACK)  # Burnt through
    p.polygon([(x + 30, y - 41), (x + 44, y - 41), (x + 46, y - 30), (x + 34, y - 32)], MID)  # Accent: scorch
    p.rect([x, y - 26, x + ln, y], BLACK)  # Side, burnt black
    for wx in range(x + 6, x + ln - 8, 16):
        p.rect([wx, y - 23, wx + 11, y - 13], BLACK, WHITE)  # Empty window frames
    p.line([(x + 2, y - 9), (x + ln - 2, y - 9)], WHITE)
    for wx in (x + 14, x + ln - 30):
        p.ellipse([wx, y - 6, wx + 15, y + 3], BLACK, WHITE)
        p.rect([wx + 6, y - 2, wx + 9, y - 1], WHITE)
    p.rect([x + ln - 4, y - 24, x + ln, y - 6], WHITE, BLACK)


def c_car(p):
    x, y = 8, -8
    p.shadow([(x + 6, y), (x + 98, y), (x + 106, y + 7), (x + 12, y + 7)])
    p.rrect([x, y - 28, x + 94, y - 8], 6, BLACK)  # Burnt body
    p.rrect([x + 24, y - 36, x + 68, y - 16], 4, BLACK, WHITE)  # Roof edge catching the light
    p.rect([x + 26, y - 17, x + 66, y - 11], BLACK, WHITE)
    p.rect([x, y - 11, x + 94, y], BLACK)
    for wx in (x + 10, x + 70):
        p.ellipse([wx, y - 6, wx + 14, y + 3], BLACK, WHITE)
    p.line([(x + 30, y - 30), (x + 40, y - 22), (x + 52, y - 32)], WHITE)  # Scorch cracks
    p.polygon([(x + 76, y - 26), (x + 90, y - 22), (x + 88, y - 14), (x + 78, y - 16)], WHITE, BLACK)  # Bonnet gone
    p.rect([x + 4, y - 24, x + 14, y - 20], MID)  # Accent


def c_lamp(p):
    x, y = 28, -8
    p.line([(x + 1, y), (x + 16, y + 4)], BLACK, 2)
    p.ellipse([x - 6, y - 3, x + 6, y + 3], WHITE, BLACK)
    p.line([(x, y), (x, y - 44), (x + 16, y - 58)], BLACK, 3)
    p.rect([x + 14, y - 62, x + 26, y - 56], WHITE, BLACK)
    p.polygon([(x - 18, y + 1), (x - 14, y - 6), (x - 8, y - 4), (x - 10, y + 2)], WHITE, BLACK)


def c_dumpster(p):
    x, y = 6, -6
    p.shadow([(x + 46, y - 14), (x + 56, y - 8), (x + 56, y + 4), (x + 4, y + 4), (x, y)])
    p.rect([x, y - 20, x + 46, y], BLACK)
    for vx in range(x + 6, x + 44, 8):
        p.line([(vx, y - 18), (vx, y - 2)], WHITE)
    p.polygon([(x - 2, y - 20), (x + 4, y - 34), (x + 50, y - 34), (x + 48, y - 20)], WHITE, BLACK)  # Lid flung up
    p.rect([x + 10, y - 13, x + 34, y - 9], WHITE, BLACK)
    for i, (bx, by) in enumerate(((x + 48, y), (x + 52, y - 3))):
        p.rrect([bx, by - 7, bx + 9, by], 3, BLACK if i else WHITE, BLACK)  # Bin bags


def c_tyres(p):
    x, y = 28, -6
    p.shadow_ellipse([x - 8, y - 3, x + 26, y + 5])
    for ty in (0, -7, -14):
        p.ellipse([x - 13, y + ty - 6, x + 13, y + ty + 3], BLACK)
        p.ellipse([x - 6, y + ty - 4, x + 6, y + ty], None, WHITE)
    p.line([(x - 10, y - 18), (x - 2, y - 20)], WHITE)


# City, dithered: the original shading, drawn in phase variants (see PHASES). Swapped in for the solid
# pieces while the kit is in DITHERED_KITS

def cd_facade(floors, broken_seed, door=False):
    """A slice of building front exactly one cell wide with no side outlines, so a row of them reads as one street
    of buildings. For the top border"""
    def draw(p):
        rng = random.Random(broken_seed)
        base, fh = -4, 22
        top = base - floors * fh - 6
        edge = [(0, base)]
        for i in range(5):  # Broken skyline
            edge.append((i * 14, top + rng.randint(0, 14 if broken_seed else 3)))
        edge += [(56, top + rng.randint(0, 10 if broken_seed else 3)), (56, base)]
        p.polygon(edge, LIGHT)
        p.line(edge[1:-1], BLACK)
        for f in range(floors):
            fy = base - (f + 1) * fh
            p.line([(0, fy + fh - 1), (56, fy + fh - 1)], MID)
            for wx in (7, 33):
                if fy + 4 > top + 12 or f == 0:
                    if not (door and f == 0):
                        p.rect([wx, fy + 5, wx + 14, fy + 15], BLACK)
                        p.line([(wx, fy + 15), (wx + 14, fy + 15)], WHITE)
        if door:
            p.rect([6, base - 20, 50, base - 1], DARK, BLACK)  # Shop shutter, half up
            for sy in range(base - 18, base - 8, 3):
                p.line([(7, sy), (49, sy)], MID)
            p.rect([7, base - 7, 49, base - 1], BLACK)
        p.rect([0, base, 56, base + 3], DARK, ink=True)  # Shadow at the foot
        for _ in range(3):
            rx = rng.randint(2, 50)
            p.polygon(jag(rng, rx, base + 1, 4, 2, 5, 0.3), MID, BLACK)
    return draw


def cd_wall_side(p):
    """Side border: a broken wall seen end on, rows of them making one line"""
    x, y = 28, -4
    p.dshadow([(x + 8, y - 6), (x + 18, y - 2), (x + 18, y + 3), (x - 6, y + 3)])
    p.polygon([(x - 8, y), (x - 8, y - 40), (x - 3, y - 46), (x + 2, y - 41), (x + 8, y - 44), (x + 8, y)], LIGHT, BLACK)
    p.rect([x + 2, y - 40, x + 8, y], DARK)
    p.line([(x + 2, y - 40), (x + 2, y)], BLACK)
    for by in range(y - 36, y, 9):
        p.line([(x - 7, by), (x + 1, by)], MID)
    p.polygon([(x - 16, y), (x - 12, y - 6), (x - 6, y - 4), (x - 8, y + 1)], MID, BLACK)
    p.polygon([(x + 10, y + 1), (x + 12, y - 5), (x + 18, y - 3), (x + 17, y + 1)], LIGHT, BLACK)


def cd_rubble_low(p):
    """Bottom border: low broken concrete, nothing taller than a row"""
    rng = random.Random(21)
    p.dshadow_ellipse([2, -12, 60, 2])
    for cx, cy, r, tone in ((12, -6, 8, LIGHT), (28, -8, 10, WHITE), (44, -5, 8, MID), (20, -3, 5, MID), (38, -2, 6, LIGHT)):
        p.polygon(jag(rng, cx, cy, r, r * 0.7, 6, 0.3), tone, BLACK)
    p.line([(8, -12), (24, -20)], BLACK, 2)


def cd_ruin(p):
    """A gutted building: three cells wide, the front wall standing with its upper floors gone"""
    rng = random.Random(5)
    x0, x1, base, h = 4, 164, -8, 74
    p.dshadow([(x1, base - 24), (x1 + 22, base - 12), (x1 + 22, base + 8), (x0 + 10, base + 8), (x0, base)])
    edge = [(x0, base)]
    for i in range(11):
        tx = x0 + (x1 - x0) * i / 10
        edge.append((tx, base - h + (0 if i in (0, 10) else rng.randint(-2, 30))))
    edge.append((x1, base))
    p.polygon(edge, LIGHT, BLACK)
    p.polygon([(x0 + 2, base - h + 4), (x0 + 14, base - h - 6), (x0 + 40, base - h - 6), (x0 + 36, base - h + 6)], DARK, BLACK)  # Slab hanging off
    for wy in range(base - h + 16, base - 18, 18):
        for wx in range(x0 + 10, x1 - 16, 22):
            if rng.random() < 0.85:
                p.rect([wx, wy, wx + 12, wy + 10], BLACK)
                p.line([(wx, wy + 10), (wx + 12, wy + 10)], WHITE)
    p.rect([x0 + 70, base - 24, x0 + 92, base], BLACK)  # Doorway
    for _ in range(5):
        rx = rng.randint(x0 + 10, x1 - 10)
        p.line([(rx, base - h + 26), (rx + rng.randint(-5, 5), base - h + 8)], BLACK)
    for cx in (x0 + 20, x0 + 120, x1 - 6):
        p.polygon(jag(rng, cx, base, 9, 5, 6, 0.3), MID, BLACK)


def cd_rubble_pile(p):
    rng = random.Random(9)
    x, y = 57, -10
    p.dshadow_ellipse([x - 48, y - 10, x + 58, y + 8])
    for _ in range(16):
        cx, cy = x + rng.randint(-40, 40), y - rng.randint(0, 16)
        r = rng.randint(4, 9)
        p.polygon(jag(rng, cx, cy, r + 1, r * 0.75, 5, 0.3), rng.choice((WHITE, LIGHT, LIGHT, MID)), BLACK)
    p.line([(x - 22, y - 16), (x + 4, y - 30)], BLACK, 3)  # Girder
    p.line([(x - 22, y - 16), (x + 4, y - 30)], MID)
    p.line([(x + 18, y - 10), (x + 26, y - 26)], BLACK)


def cd_rubble_small(p):
    rng = random.Random(13)
    x, y = 28, -8
    p.dshadow_ellipse([x - 22, y - 6, x + 28, y + 6])
    for _ in range(8):
        cx, cy = x + rng.randint(-16, 16), y - rng.randint(0, 9)
        r = rng.randint(3, 6)
        p.polygon(jag(rng, cx, cy, r + 1, r * 0.75, 5, 0.3), rng.choice((WHITE, LIGHT, MID)), BLACK)


def cd_bus(p):
    x, y, ln = 10, -6, 150
    p.dshadow([(x + 6, y), (x + ln + 2, y), (x + ln + 12, y + 8), (x + 12, y + 8)])
    p.rect([x, y - 42, x + ln, y - 26], MID, BLACK)  # Roof, burnt
    p.polygon([(x + 44, y - 42), (x + 76, y - 40), (x + 70, y - 28), (x + 48, y - 30)], BLACK)
    p.polygon([(x + 104, y - 42), (x + 122, y - 41), (x + 118, y - 34)], BLACK)
    p.rect([x, y - 26, x + ln, y], DARK, BLACK)
    for wx in range(x + 6, x + ln - 8, 16):
        p.rect([wx, y - 23, wx + 11, y - 13], BLACK)
    p.rect([x + 2, y - 10, x + ln - 2, y - 8], LIGHT)
    for wx in (x + 14, x + ln - 30):
        p.rect([wx, y - 4, wx + 15, y + 2], BLACK)
    p.rect([x + ln - 4, y - 24, x + ln, y - 6], LIGHT, BLACK)  # Front


def cd_car(p):
    x, y = 8, -8
    p.dshadow([(x + 6, y), (x + 98, y), (x + 106, y + 8), (x + 12, y + 8)])
    p.rrect([x, y - 28, x + 94, y - 8], 6, DARK, BLACK)
    p.rrect([x + 24, y - 36, x + 68, y - 16], 4, MID, BLACK)
    p.rect([x + 26, y - 17, x + 66, y - 11], BLACK)
    p.rect([x, y - 11, x + 94, y], DARK, BLACK)
    for wx in (x + 10, x + 70):
        p.ellipse([wx, y - 6, wx + 14, y + 3], BLACK)
    p.line([(x + 30, y - 30), (x + 40, y - 22), (x + 52, y - 32)], WHITE)  # Scorch cracks
    p.polygon([(x + 76, y - 26), (x + 90, y - 22), (x + 88, y - 14), (x + 78, y - 16)], BLACK)  # Bonnet gone


def cd_lamp(p):
    x, y = 28, -8
    p.line([(x + 1, y), (x + 16, y + 5)], DARK, 2, ink=True)
    p.ellipse([x - 6, y - 3, x + 6, y + 3], MID, BLACK)
    p.line([(x, y), (x, y - 44), (x + 16, y - 58)], BLACK, 3)
    p.line([(x - 1, y - 2), (x - 1, y - 42)], LIGHT)
    p.rect([x + 14, y - 62, x + 26, y - 56], MID, BLACK)
    p.polygon([(x - 18, y + 1), (x - 14, y - 6), (x - 8, y - 4), (x - 10, y + 2)], LIGHT, BLACK)


def cd_dumpster(p):
    x, y = 6, -6
    p.dshadow([(x + 46, y - 14), (x + 56, y - 8), (x + 56, y + 5), (x + 4, y + 5), (x, y)])
    p.rect([x, y - 20, x + 46, y], MID, BLACK)
    for vx in range(x + 6, x + 44, 8):
        p.line([(vx, y - 18), (vx, y - 2)], DARK)
    p.polygon([(x - 2, y - 20), (x + 4, y - 34), (x + 50, y - 34), (x + 48, y - 20)], LIGHT, BLACK)  # Lid flung up
    p.rect([x + 10, y - 13, x + 34, y - 9], WHITE)
    for i, (bx, by) in enumerate(((x + 48, y), (x + 52, y - 3))):
        p.rrect([bx, by - 7, bx + 9, by], 3, DARK if i else LIGHT, BLACK)  # Bin bags


def cd_tyres(p):
    x, y = 28, -6
    p.dshadow_ellipse([x - 10, y - 4, x + 26, y + 6])
    for i, (ty) in enumerate((0, -7, -14)):
        p.ellipse([x - 13, y + ty - 6, x + 13, y + ty + 3], BLACK)
        p.ellipse([x - 6, y + ty - 4, x + 6, y + ty], DARK if i < 2 else MID)
    p.line([(x - 10, y - 18), (x - 2, y - 20)], MID)


def cg_road(cracked, line=False, zebra=False):
    def draw(p):
        rng = random.Random(cracked + 3)
        # No fill: the road is the kerbs, cracks and markings (solid, so they only change at their edges when the view
        # scrolls). The plain road is an empty cell that lets the decals onto it
        p.rect([0, -27, 56, -1], WHITE, ink=True)
        if line:
            p.rect([12, -15, 44, -14], BLACK)
        if zebra:
            for zx in (4, 22, 40):
                p.rect([zx, -25, zx + 9, -3], WHITE, BLACK)
        for _ in range(cracked):
            sx, sy = rng.randint(4, 50), rng.randint(-22, -6)
            pts = [(sx, sy)]
            for _ in range(3):
                sx += rng.randint(3, 8) * rng.choice((-1, 1))
                sy += rng.randint(-3, 3)
                pts.append((min(max(sx, 0), 56), min(max(sy, -26), -1)))
            p.line(pts, BLACK)
    return draw


def cg_pavement(p):
    p.line([(0, -27), (56, -27)], LIGHT)
    p.line([(0, -27), (0, -1)], LIGHT)
    p.line([(28, -27), (28, -1)], LIGHT)


def cg_kerb(p):
    p.line([(0, -27), (0, -2)], LIGHT)
    p.line([(0, -5), (56, -5)], BLACK)
    p.line([(0, -1), (56, -1)], BLACK)


def cg_manhole(p):
    p.ellipse([16, -20, 40, -7], WHITE, BLACK)
    for ly in (-16, -13, -10):
        p.line([(20, ly), (36, ly)], BLACK)


def cg_scorch(p):
    rng = random.Random(17)
    p.polygon(jag(rng, 28, -13, 16, 7, 9, 0.3), BLACK)
    for _ in range(14):  # Flecks thrown out round it
        a = rng.uniform(0, math.tau)
        d = rng.uniform(18, 32)
        fx, fy = 28 + math.cos(a) * d, -13 + math.sin(a) * d * 0.45
        p.rect([fx, fy, fx + 1, fy + 1], BLACK)


def d_crack(p):
    p.line([(0, -3), (4, -4), (7, -2), (11, -4)], BLACK)


def d_litter(p):
    p.rect([0, -5, 5, -2], WHITE, BLACK)


def d_brick(p):
    p.rect([0, -4, 4, -1], MID, BLACK)
    p.point((7, -2), BLACK)


def d_bottle(p):
    p.line([(0, -2), (5, -3)], BLACK, 2)
    p.point((6, -3), BLACK)


def city_outside(kit):
    facades = [kit.piece_index(n) for n in ("facade_a", "facade_b", "facade_c")]
    side = [kit.piece_index(n) for n in ("rubble_small", "rubble_low")]
    low = [kit.piece_index(n) for n in ("rubble_low", "rubble_small")]

    def fn(rng, col, row, side_name, dist):
        if side_name == "north":
            # Street after street of building fronts going back
            return [(rng.choice(facades), rng.random() < 0.3, 0, 0)] if row % 3 == 2 or row == -1 else []
        if side_name == "south":
            return [(rng.choice(low), rng.random() < 0.5, rng.randint(-10, 10), rng.randint(-4, 4))] if rng.random() < 0.35 else []
        return [(rng.choice(side), rng.random() < 0.5, rng.randint(-14, 14), rng.randint(-4, 4))] if rng.random() < 0.35 else []

    return fn


def build_city():
    d = "city" in DITHERED_KITS
    kw = {"cell": 1, "phases": PHASES} if d else {}
    pieces = [
        Art("facade_a", 1, 1, (cd_facade if d else c_facade)(3, 0), **kw),
        Art("facade_b", 1, 1, (cd_facade if d else c_facade)(2, 4), **kw),
        Art("facade_c", 1, 1, (cd_facade if d else c_facade)(3, 7, door=True), **kw),
        Art("wall_side", 1, 1, cd_wall_side if d else c_wall_side, **kw),
        Art("rubble_low", 1, 1, cd_rubble_low if d else c_rubble_low, **kw),
        Art("ruin", 3, 2, cd_ruin if d else c_ruin, **kw),
        Art("rubble_pile", 2, 1, cd_rubble_pile if d else c_rubble_pile, **kw),
        Art("rubble_small", 1, 1, cd_rubble_small if d else c_rubble_small, **kw),
        Art("bus", 3, 1, cd_bus if d else c_bus, **kw),
        Art("car", 2, 1, cd_car if d else c_car, **kw),
        Art("lamp", 1, 1, cd_lamp if d else c_lamp, **kw),
        Art("dumpster", 1, 1, cd_dumpster if d else c_dumpster, **kw),
        Art("tyres", 1, 1, cd_tyres if d else c_tyres, **kw),
    ]
    ground = [
        Art("road", 1, 1, cg_road(0), keep_decals=True),
        Art("road_cracked", 1, 1, cg_road(3)),
        Art("road_line", 1, 1, cg_road(0, line=True)),
        Art("zebra", 1, 1, cg_road(0, zebra=True)),
        Art("pavement", 1, 1, cg_pavement),
        Art("kerb", 1, 1, cg_kerb),
        Art("manhole", 1, 1, cg_manhole),
        Art("scorch", 1, 1, cg_scorch),
    ]
    decals = [Art("crack", 1, 1, d_crack), Art("crack2", 1, 1, d_crack), Art("litter", 1, 1, d_litter), Art("brick", 1, 1, d_brick), Art("bottle", 1, 1, d_bottle), Art("pebbles", 1, 1, d_pebbles)]
    kit = Kit("city", "Ruined City", pieces, ground, decals, 0.3, None, cell=1 if d else None, phases=PHASES if d else 1)
    kit.outside = city_outside(kit)
    return kit


# ================================================================ Quarantine Zone

def q_fence_h(p):
    """Top border: chain link panel with razor wire, exactly a cell wide (its post on the left), so a row joins up"""
    base, top = -4, -50
    p.rect([0, base, 56, base + 2], BLACK)  # Shadow at its foot
    p.rect([1, top, 56, base], WHITE)
    for x in range(-24, 60, 9):  # Wire mesh, sparse thin lines clipped to the panel
        for (ax, ay), (bx, by) in (((x, top), (x + 24, base)), ((x + 24, top), (x, base))):
            pts = []
            for t in range(0, 25):
                px, py = ax + (bx - ax) * t / 24, ay + (by - ay) * t / 24
                if 1 <= px <= 56:
                    pts.append((px, py))
            if len(pts) > 1:
                p.line(pts, BLACK)
    p.line([(0, top), (56, top)], BLACK)
    p.line([(0, base), (56, base)], BLACK)
    p.rect([0, top - 14, 3, base], BLACK)  # Post
    for x in range(-4, 56, 9):  # Razor wire coil
        p.ellipse([max(x, 0), top - 14, min(x + 13, 56), top], None, BLACK)


def q_fence_v(p):
    """Side border: the fence seen end on, a post per row and the mesh between them"""
    x, base = 28, -4
    p.shadow([(x + 2, base - 2), (x + 14, base + 2), (x + 12, base + 3), (x - 2, base + 2)])
    p.rect([x - 3, base - 50, x + 3, base], WHITE)
    for y in range(base - 50, base, 6):
        p.line([(x - 3, y), (x + 3, y + 6)], BLACK)
    p.rect([x - 2, base - 58, x + 1, base], BLACK)
    for y in (base - 62, base - 54):
        p.ellipse([x - 7, y, x + 7, y + 8], None, BLACK)


def q_barrier_low(p):
    """Bottom border: a low concrete kerb barrier"""
    x, y = 0, -6
    p.shadow([(x + 2, y), (x + 60, y), (x + 62, y + 4), (x + 4, y + 4)])
    p.polygon([(x, y), (x + 3, y - 10), (x + 53, y - 10), (x + 56, y)], BLACK)
    p.rect([x + 3, y - 14, x + 53, y - 10], WHITE, BLACK)
    for k in range(0, 50, 12):
        p.polygon([(x + 6 + k, y - 1), (x + 10 + k, y - 1), (x + 14 + k, y - 9), (x + 10 + k, y - 9)], WHITE)


def q_sandbags(cols):
    def draw(p):
        rows = 3
        x, y = 4, -6
        w = cols * 16
        p.shadow([(x + w, y - 18), (x + w + 9, y - 12), (x + w + 9, y + 4), (x + 6, y + 4), (x, y)])
        p.rect([x, y - rows * 8 - 10, x + w, y - rows * 8], WHITE, BLACK)
        for i in range(1, cols):
            p.line([(x + i * 16, y - rows * 8 - 10), (x + i * 16, y - rows * 8)], BLACK)
        for r in range(rows):
            off = 8 if r % 2 else 0
            for i in range(-1, cols):
                bx = x + i * 16 + off
                if bx < x - 4 or bx + 16 > x + w + 4:
                    continue
                by = y - (r + 1) * 8
                shaded = r == 0
                p.rrect([bx, by, bx + 16, by + 8], 3, BLACK if shaded else WHITE, BLACK)
                p.line([(bx + 3, by + 2), (bx + 8, by + 2)], WHITE if shaded else BLACK)
        p.rect([x + w // 2 - 6, y - 15, x + w // 2 + 6, y - 10], MID)  # Accent: a damp patch
    return draw


def q_jersey(p):
    x, y = 12, -6
    p.shadow([(x + 30, y - 4), (x + 40, y + 2), (x + 38, y + 5), (x + 6, y + 5), (x, y)])
    p.polygon([(x, y), (x + 4, y - 8), (x + 8, y - 22), (x + 24, y - 22), (x + 28, y - 8), (x + 32, y)], BLACK)
    p.rect([x + 8, y - 26, x + 24, y - 22], WHITE, BLACK)
    for k in range(3):
        p.polygon([(x + 6 + k * 8, y - 2), (x + 10 + k * 8, y - 2), (x + 14 + k * 8, y - 12), (x + 10 + k * 8, y - 12)], WHITE)


def q_med_tent(p):
    x, y, w = 8, -12, 150
    p.shadow([(x + w, y - 20), (x + w + 16, y - 10), (x + w + 16, y + 7), (x + 8, y + 7), (x, y)])
    p.polygon([(x, y), (x + 8, y - 30), (x + w - 8, y - 30), (x + w, y)], BLACK)  # Drab canvas walls
    p.polygon([(x + 8, y - 30), (x + 20, y - 46), (x + w - 20, y - 46), (x + w - 8, y - 30)], BLACK)  # Roof
    p.line([(x + 20, y - 46), (x + w - 20, y - 46)], WHITE)  # Ridge catching the light
    p.line([(x + 8, y - 30), (x + w - 8, y - 30)], WHITE)  # Eave
    for sx in range(x + 30, x + w - 30, 26):  # Seams
        p.line([(sx, y - 45), (sx - 4, y - 31)], WHITE)
    cx = x + w // 2
    p.rect([cx - 12, y - 30, cx + 12, y - 6], WHITE, BLACK)  # Cross panel
    p.rect([cx - 3, y - 26, cx + 3, y - 10], BLACK)
    p.rect([cx - 9, y - 21, cx + 9, y - 15], BLACK)
    p.polygon([(x + 16, y), (x + 28, y - 24), (x + 36, y)], WHITE, BLACK)  # Open flap
    p.polygon([(x + 22, y), (x + 28, y - 14), (x + 32, y)], BLACK)
    p.rect([x + w - 34, y - 8, x + w - 20, y], WHITE, BLACK)  # Stretcher end
    p.rect([x + 40, y - 4, x + 60, y - 1], MID)  # Accent: mud on the skirt
    for gx, dx in ((x - 2, -8), (x + w + 2, 8)):
        p.line([(gx, y), (gx + dx, y + 4)], BLACK)


def q_tower(p):
    x, y = 12, -6
    p.shadow([(x + 30, y - 4), (x + 60, y + 5), (x + 56, y + 8), (x + 4, y + 5)])
    for lx in (x, x + 30):
        p.rect([lx, y - 62, lx + 3, y], BLACK)
    p.line([(x + 2, y - 52), (x + 31, y - 12)], BLACK)
    p.line([(x + 31, y - 52), (x + 2, y - 12)], BLACK)
    p.rect([x - 6, y - 82, x + 39, y - 60], BLACK)  # Cabin
    p.rect([x - 2, y - 78, x + 35, y - 70], BLACK, WHITE)  # Window slot
    p.polygon([(x - 10, y - 82), (x + 16, y - 94), (x + 43, y - 82)], WHITE, BLACK)  # Roof
    p.line([(x + 36, y - 74), (x + 46, y - 80)], WHITE, 2)


def q_crates(p):
    x, y = 6, -6
    for i, (bx, by, s) in enumerate(((x, y, 22), (x + 24, y + 1, 20), (x + 8, y - 22, 20))):
        p.shadow([(bx + s, by - 6), (bx + s + 6, by - 2), (bx + s + 6, by + 2), (bx + 3, by + 2), (bx, by)])
        p.rect([bx, by - s - 6, bx + s, by - s], WHITE, BLACK)
        p.rect([bx, by - s, bx + s, by], WHITE, BLACK)
        p.line([(bx, by - s), (bx + s, by)], BLACK)
        p.line([(bx + s, by - s), (bx, by)], BLACK)
        if i == 1:
            p.rect([bx + 2, by - 4, bx + s - 2, by - 1], MID)  # Accent


def q_drums(p):
    x, y = 28, -4
    for dx, dy in ((-10, -6), (8, -7), (-1, 0)):
        cx, cy, r, h = x + dx, y + dy, 8, 20
        p.shadow([(cx + r - 2, cy - 2), (cx + r + 10, cy), (cx + r + 8, cy + 3), (cx - 4, cy + 3)])
        p.rect([cx - r, cy - h, cx + r, cy], BLACK)
        p.line([(cx - r + 2, cy - h + 2), (cx - r + 2, cy - 2)], WHITE)  # Lit edge
        p.arc([cx - r, cy - 11, cx + r, cy - 5], 0, 180, WHITE)  # Hoop
        p.ellipse([cx - r, cy - h - 4, cx + r, cy - h + 4], WHITE, BLACK)
        p.ellipse([cx - r + 3, cy - h - 2, cx - r + 7, cy - h + 1], None, BLACK)


def q_truck(p):
    x, y = 8, -6
    p.shadow([(x + 6, y), (x + 152, y), (x + 160, y + 7), (x + 12, y + 7)])
    p.polygon([(x, y - 8), (x + 2, y - 44), (x + 104, y - 44), (x + 106, y - 8)], BLACK)  # Drab canvas back
    p.line([(x + 2, y - 44), (x + 104, y - 44)], WHITE)
    for rx in (x + 34, x + 70):
        p.line([(rx, y - 43), (rx, y - 9)], WHITE)
    p.rect([x + 48, y - 32, x + 60, y - 22], WHITE, BLACK)  # Stencilled star panel
    p.point((x + 54, y - 27), BLACK)
    p.rect([x + 6, y - 14, x + 28, y - 10], MID)  # Accent: mud
    p.rect([x + 108, y - 34, x + 146, y - 8], BLACK)  # Cab
    p.rect([x + 114, y - 30, x + 132, y - 20], BLACK, WHITE)
    p.rect([x + 140, y - 30, x + 150, y - 10], WHITE, BLACK)  # Bonnet
    p.rect([x, y - 10, x + 150, y - 4], BLACK)
    for wx in (x + 10, x + 34, x + 120):
        p.ellipse([wx, y - 9, wx + 16, y + 4], BLACK, WHITE)
        p.ellipse([wx + 6, y - 4, wx + 10, y - 1], WHITE)


def q_floodlight(p):
    x, y = 28, -6
    p.shadow([(x, y), (x + 30, y + 5), (x + 28, y + 7), (x - 2, y + 2)])
    p.polygon([(x - 10, y), (x, y - 8), (x + 10, y)], BLACK)  # Tripod feet
    p.rect([x - 1, y - 66, x + 1, y - 6], BLACK)
    p.rect([x - 12, y - 74, x + 12, y - 64], BLACK)
    for lx in (-9, -2, 5):
        p.rect([x + lx, y - 72, x + lx + 4, y - 67], WHITE)
    p.rect([x + 6, y - 20, x + 16, y - 8], WHITE, BLACK)  # Generator box
    p.line([(x + 8, y - 16), (x + 14, y - 16)], BLACK)


# Quarantine, dithered: the original shading, drawn in phase variants (see PHASES). Swapped in for the solid
# pieces while the kit is in DITHERED_KITS

def qd_fence_h(p):
    """Top border: chain link panel with razor wire, exactly a cell wide (its post on the left), so a row joins up"""
    base, top = -4, -50
    p.rect([0, base, 56, base + 3], DARK, ink=True)
    p.rect([1, top, 56, base], WHITE)
    for x in range(-24, 60, 6):  # Diamond mesh, clipped to the panel
        for (ax, ay), (bx, by) in (((x, top), (x + 24, base)), ((x + 24, top), (x, base))):
            pts = []
            for t in range(0, 25):
                px, py = ax + (bx - ax) * t / 24, ay + (by - ay) * t / 24
                if 1 <= px <= 56:
                    pts.append((px, py))
            if len(pts) > 1:
                p.line(pts, MID)
    p.line([(0, top), (56, top)], BLACK)
    p.line([(0, base), (56, base)], BLACK)
    p.rect([0, top - 14, 3, base], DARK, BLACK)  # Post
    for x in range(-4, 56, 9):  # Razor wire coil
        p.ellipse([max(x, 0), top - 14, min(x + 13, 56), top], None, BLACK)


def qd_fence_v(p):
    """Side border: the fence seen end on, a post per row and the mesh between them"""
    x, base = 28, -4
    p.dshadow([(x + 2, base - 2), (x + 14, base + 2), (x + 12, base + 4), (x - 2, base + 2)])
    p.rect([x - 3, base - 50, x + 3, base], WHITE)
    for y in range(base - 50, base, 4):
        p.line([(x - 3, y), (x + 3, y + 4)], MID)
    p.rect([x - 2, base - 58, x + 1, base], DARK, BLACK)
    for y in (base - 62, base - 54):
        p.ellipse([x - 7, y, x + 7, y + 8], None, BLACK)


def qd_barrier_low(p):
    """Bottom border: a low concrete kerb barrier"""
    x, y = 0, -6
    p.dshadow([(x + 2, y), (x + 60, y), (x + 62, y + 5), (x + 4, y + 5)])
    p.polygon([(x, y), (x + 3, y - 10), (x + 53, y - 10), (x + 56, y)], MID, BLACK)
    p.rect([x + 3, y - 14, x + 53, y - 10], WHITE, BLACK)
    for k in range(0, 50, 12):
        p.polygon([(x + 6 + k, y - 1), (x + 10 + k, y - 1), (x + 14 + k, y - 9), (x + 10 + k, y - 9)], WHITE)


def qd_sandbags(cols):
    def draw(p):
        rows = 3
        x, y = 4, -6
        w = cols * 16
        p.dshadow([(x + w, y - 18), (x + w + 10, y - 12), (x + w + 10, y + 5), (x + 6, y + 5), (x, y)])
        p.rect([x, y - rows * 8 - 10, x + w, y - rows * 8], LIGHT, BLACK)
        for i in range(1, cols):
            p.line([(x + i * 16, y - rows * 8 - 10), (x + i * 16, y - rows * 8)], MID)
        for r in range(rows):
            off = 8 if r % 2 else 0
            for i in range(-1, cols):
                bx = x + i * 16 + off
                if bx < x - 4 or bx + 16 > x + w + 4:
                    continue
                by = y - (r + 1) * 8
                p.rrect([bx, by, bx + 16, by + 8], 3, LIGHT if r == rows - 1 else MID, BLACK)
                p.line([(bx + 3, by + 2), (bx + 8, by + 2)], WHITE)
    return draw


def qd_jersey(p):
    x, y = 12, -6
    p.dshadow([(x + 30, y - 4), (x + 40, y + 2), (x + 38, y + 6), (x + 6, y + 6), (x, y)])
    p.polygon([(x, y), (x + 4, y - 8), (x + 8, y - 22), (x + 24, y - 22), (x + 28, y - 8), (x + 32, y)], MID, BLACK)
    p.rect([x + 8, y - 26, x + 24, y - 22], WHITE, BLACK)
    for k in range(3):
        p.polygon([(x + 6 + k * 8, y - 2), (x + 10 + k * 8, y - 2), (x + 14 + k * 8, y - 12), (x + 10 + k * 8, y - 12)], WHITE)


def qd_med_tent(p):
    x, y, w = 8, -12, 150
    p.dshadow([(x + w, y - 20), (x + w + 18, y - 10), (x + w + 18, y + 8), (x + 8, y + 8), (x, y)])
    p.polygon([(x, y), (x + 8, y - 30), (x + w - 8, y - 30), (x + w, y)], DARK, BLACK)
    p.polygon([(x + 8, y - 30), (x + 20, y - 46), (x + w - 20, y - 46), (x + w - 8, y - 30)], MID, BLACK)
    p.line([(x + 20, y - 46), (x + w - 20, y - 46)], WHITE)
    cx = x + w // 2
    p.rect([cx - 12, y - 30, cx + 12, y - 6], WHITE, BLACK)  # Cross panel
    p.rect([cx - 3, y - 26, cx + 3, y - 10], BLACK)
    p.rect([cx - 9, y - 21, cx + 9, y - 15], BLACK)
    p.polygon([(x + 16, y), (x + 28, y - 24), (x + 36, y)], BLACK)  # Open flap
    p.polygon([(x + 36, y), (x + 30, y - 18), (x + 44, y - 4)], LIGHT, BLACK)
    for gx, dx in ((x - 2, -8), (x + w + 2, 8)):
        p.line([(gx, y), (gx + dx, y + 4)], BLACK)
    p.rect([x + w - 34, y - 8, x + w - 20, y], LIGHT, BLACK)  # Stretcher end
    p.line([(x + w - 32, y - 4), (x + w - 22, y - 4)], BLACK)


def qd_tower(p):
    x, y = 12, -6
    p.dshadow([(x + 30, y - 4), (x + 60, y + 6), (x + 56, y + 10), (x + 4, y + 6)])
    for lx in (x, x + 30):
        p.rect([lx, y - 62, lx + 3, y], DARK, BLACK)
    p.line([(x + 2, y - 52), (x + 31, y - 12)], BLACK)
    p.line([(x + 31, y - 52), (x + 2, y - 12)], BLACK)
    p.rect([x - 6, y - 82, x + 39, y - 60], MID, BLACK)
    p.rect([x - 2, y - 78, x + 35, y - 70], BLACK)
    p.polygon([(x - 10, y - 82), (x + 16, y - 94), (x + 43, y - 82)], DARK, BLACK)
    p.line([(x + 36, y - 74), (x + 46, y - 80)], WHITE, 2)  # Searchlight beam stub


def qd_crates(p):
    x, y = 6, -6
    for bx, by, s in ((x, y, 22), (x + 24, y + 1, 20), (x + 8, y - 22, 20)):
        p.dshadow([(bx + s, by - 6), (bx + s + 6, by - 2), (bx + s + 6, by + 3), (bx + 3, by + 3), (bx, by)])
        p.rect([bx, by - s - 6, bx + s, by - s], LIGHT, BLACK)
        p.rect([bx, by - s, bx + s, by], MID, BLACK)
        p.line([(bx, by - s), (bx + s, by)], BLACK)
        p.line([(bx + s, by - s), (bx, by)], BLACK)


def qd_drums(p):
    x, y = 28, -4
    for i, (dx, dy) in enumerate(((-10, -6), (8, -7), (-1, 0))):
        cx, cy, r, h = x + dx, y + dy, 8, 20
        p.dshadow([(cx + r - 2, cy - 2), (cx + r + 10, cy), (cx + r + 8, cy + 4), (cx - 4, cy + 4)])
        p.rect([cx - r, cy - h, cx + r, cy], MID if i % 2 else DARK)
        p.rect([cx + r // 3, cy - h, cx + r, cy], DARK)
        p.line([(cx - r, cy - h), (cx - r, cy)], BLACK)
        p.line([(cx + r, cy - h), (cx + r, cy)], BLACK)
        p.arc([cx - r, cy - 4, cx + r, cy + 4], 0, 180, BLACK)
        p.arc([cx - r, cy - 11, cx + r, cy - 5], 0, 180, BLACK)
        p.ellipse([cx - r, cy - h - 4, cx + r, cy - h + 4], WHITE, BLACK)
        p.ellipse([cx - r + 3, cy - h - 2, cx - r + 7, cy - h + 1], None, MID)


def qd_truck(p):
    x, y = 8, -6
    p.dshadow([(x + 6, y), (x + 152, y), (x + 160, y + 8), (x + 12, y + 8)])
    p.hatch([(x, y - 8), (x + 2, y - 44), (x + 104, y - 44), (x + 106, y - 8)], MID, DARK, 6)  # Canvas back
    p.line([(x + 2, y - 44), (x + 104, y - 44)], WHITE)
    for rx in (x + 34, x + 70):
        p.line([(rx, y - 44), (rx, y - 8)], BLACK)
    p.rect([x + 108, y - 34, x + 146, y - 8], DARK, BLACK)  # Cab
    p.rect([x + 114, y - 30, x + 132, y - 20], BLACK)
    p.rect([x + 140, y - 30, x + 150, y - 10], MID, BLACK)  # Bonnet
    p.rect([x, y - 10, x + 150, y - 4], BLACK)
    for wx in (x + 10, x + 34, x + 120):
        p.ellipse([wx, y - 9, wx + 16, y + 4], BLACK)
        p.ellipse([wx + 5, y - 5, wx + 11, y], MID)
    p.rect([x + 48, y - 30, x + 60, y - 22], WHITE)  # Stencilled star panel
    p.point((x + 54, y - 26), BLACK)


def qd_floodlight(p):
    x, y = 28, -6
    p.dshadow([(x, y), (x + 30, y + 6), (x + 28, y + 8), (x - 2, y + 2)])
    p.polygon([(x - 10, y), (x, y - 8), (x + 10, y)], MID, BLACK)  # Tripod feet
    p.line([(x - 10, y), (x, y - 8)], BLACK)
    p.rect([x - 1, y - 66, x + 1, y - 6], BLACK)
    p.rect([x - 12, y - 74, x + 12, y - 64], DARK, BLACK)
    for lx in (-9, -2, 5):
        p.rect([x + lx, y - 72, x + lx + 4, y - 67], WHITE)
    p.rect([x + 6, y - 20, x + 16, y - 8], MID, BLACK)  # Generator box
    p.line([(x + 8, y - 16), (x + 14, y - 16)], BLACK)


def qg_concrete(p):
    """Slabs: the joints only"""
    p.line([(0, -27), (56, -27)], LIGHT)
    p.line([(0, -27), (0, -1)], LIGHT)


def qg_tracks(vertical):
    def draw(p):
        if vertical:
            for tx in (18, 34):
                for ty in range(-27, 0, 5):
                    p.rect([tx, ty, tx + 2, ty + 1], BLACK)
        else:
            for ty in (-20, -9):
                for tx in range(0, 57, 6):
                    p.rect([tx, ty, tx + 2, ty + 1], BLACK)
    return draw


def qg_helipad(p):
    """3x3 cells (anchor bottom-left): a painted H in a ring on a concrete pad"""
    w, h = 3 * 57, 3 * 27
    for x0, y0, x1, y1 in ((0, -h, w - 1, -h), (0, -1, w - 1, -1), (0, -h, 0, -1), (w - 1, -h, w - 1, -1)):
        p.line([(x0, y0), (x1, y1)], LIGHT)  # The pad's edge
    cx, cy = w // 2, -h // 2
    p.ellipse([cx - 64, cy - 32, cx + 64, cy + 32], None, BLACK)
    p.ellipse([cx - 60, cy - 30, cx + 60, cy + 30], None, BLACK)
    for x0 in (cx - 22, cx + 14):
        p.rect([x0, cy - 18, x0 + 8, cy + 18], WHITE, BLACK)
    p.rect([cx - 14, cy - 3, cx + 14, cy + 3], WHITE, BLACK)


def qg_mud(p):
    rng = random.Random(31)
    pts = jag(rng, 28, -13, 26, 11, 11, 0.3)
    p.polygon(pts, None, BLACK)
    for _ in range(6):
        fx, fy = 28 + rng.uniform(-18, 18), -13 + rng.uniform(-6, 6)
        p.rect([fx, fy, fx + 1, fy + 1], BLACK)


def d_casing(p):
    p.line([(0, -2), (2, -3)], BLACK)
    p.line([(5, -4), (7, -3)], BLACK)


def d_footprints(p):
    for i, (fx, fy) in enumerate(((0, -2), (5, -5), (10, -2), (15, -5))):
        p.rect([fx, fy - 1, fx + 2, fy], BLACK)


def d_sand(p):
    for fx, fy in ((0, -2), (4, -5), (9, -3), (6, -1)):
        p.point((fx, fy), BLACK)


def quarantine_outside(kit):
    tent = kit.piece_index("med_tent")
    side = [kit.piece_index(n) for n in ("sandbags_short", "crates", "drums", "jersey")]
    low = [kit.piece_index(n) for n in ("barrier_low", "sandbags_short")]

    def fn(rng, col, row, side_name, dist):
        if side_name == "north":  # The camp beyond the wire
            if row % 3 == 1 and col % 4 == 0:
                return [(tent, rng.random() < 0.5, rng.randint(-6, 6), 0)]
            return [(rng.choice(side), rng.random() < 0.5, rng.randint(-10, 10), 0)] if rng.random() < 0.08 else []
        if side_name == "south":
            return [(rng.choice(low), False, 0, 0)] if dist == 1 else []  # One barrier line, then open sand
        return [(rng.choice(side), rng.random() < 0.5, rng.randint(-14, 14), rng.randint(-4, 4))] if rng.random() < 0.25 else []

    return fn


def build_quarantine():
    d = "quarantine" in DITHERED_KITS
    kw = {"cell": 1, "phases": PHASES} if d else {}
    pieces = [
        Art("fence_h", 1, 1, qd_fence_h if d else q_fence_h, **kw),
        Art("fence_v", 1, 1, qd_fence_v if d else q_fence_v, **kw),
        Art("barrier_low", 1, 1, qd_barrier_low if d else q_barrier_low, **kw),
        Art("sandbags", 2, 1, (qd_sandbags if d else q_sandbags)(6), **kw),
        Art("sandbags_short", 1, 1, (qd_sandbags if d else q_sandbags)(3), **kw),
        Art("jersey", 1, 1, qd_jersey if d else q_jersey, **kw),
        Art("med_tent", 3, 2, qd_med_tent if d else q_med_tent, **kw),
        Art("tower", 1, 1, qd_tower if d else q_tower, **kw),
        Art("crates", 1, 1, qd_crates if d else q_crates, **kw),
        Art("drums", 1, 1, qd_drums if d else q_drums, **kw),
        Art("truck", 3, 1, qd_truck if d else q_truck, **kw),
        Art("floodlight", 1, 1, qd_floodlight if d else q_floodlight, **kw),
    ]
    ground = [
        Art("concrete", 1, 1, qg_concrete),
        Art("tracks_h", 1, 1, qg_tracks(False)),
        Art("tracks_v", 1, 1, qg_tracks(True)),
        Art("helipad", 3, 3, qg_helipad),
        Art("mud", 1, 1, qg_mud),
    ]
    decals = [Art("sand", 1, 1, d_sand), Art("sand2", 1, 1, d_sand), Art("casing", 1, 1, d_casing), Art("footprints", 1, 1, d_footprints), Art("pebbles", 1, 1, d_pebbles)]
    kit = Kit("quarantine", "Quarantine Zone", pieces, ground, decals, 0.35, None, cell=1 if d else None, phases=PHASES if d else 1)
    kit.outside = quarantine_outside(kit)
    return kit


# ================================================================ kit definitions

class Kit:
    def __init__(self, name, title, pieces, ground, decals, decal_chance, outside, cell=None, phases=1):
        self.name, self.title = name, title
        self.cell = cell or DITHER_CELL  # Dither cell size for its baked floor
        self.phases = phases  # 1, or PHASES: pieces and the floor drawn in phase variants
        self.pieces = pieces  # [Art]
        self.ground = ground  # [Art], flat
        self.decals = decals  # [Art], tiny
        self.decal_chance = decal_chance  # Per free floor cell
        self.outside = outside  # fn(rng, col, row, side, cells beyond the edge) -> [(piece index, flipped, dx, dy)]

    def piece_index(self, name):
        return next(i for i, a in enumerate(self.pieces) if a.name == name)


def woods_outside(kit):
    tree_names = ["pine_tall", "pine_short", "oak_a", "oak_b", "pine_tall", "oak_a"]
    trees = [kit.piece_index(n) for n in tree_names]
    low = [kit.piece_index(n) for n in ("bush", "bush", "rock")]

    def fn(rng, col, row, side, dist):
        if side == "south":  # Low, so nothing reaches up over the bottom border into the playfield
            return [(rng.choice(low), rng.random() < 0.5, rng.randint(-10, 10), rng.randint(-4, 4))] if rng.random() < 0.75 else []
        out = [(rng.choice(trees), rng.random() < 0.5, rng.randint(-12, 12), rng.randint(-6, 6))]
        if rng.random() < 0.3:
            out.append((low[0], rng.random() < 0.5, rng.randint(-14, 14), rng.randint(4, 8)))
        return out

    return fn


def build_woods():
    d = "woods" in DITHERED_KITS
    kw = {"cell": 1, "phases": PHASES} if d else {}
    pieces = [
        Art("pine_tall", 1, 1, (wd_pine if d else w_pine)(True), **kw),
        Art("pine_short", 1, 1, (wd_pine if d else w_pine)(False), **kw),
        Art("oak_a", 1, 1, (wd_oak if d else w_oak)(24, 11), **kw),
        Art("oak_b", 1, 1, (wd_oak if d else w_oak)(20, 12), **kw),
        Art("dead_tree", 1, 1, wd_dead_tree if d else w_dead_tree, **kw),
        Art("bush", 1, 1, wd_bush if d else w_bush, **kw),
        Art("rock", 1, 1, wd_rock if d else w_rock, **kw),
        Art("stump", 1, 1, wd_stump if d else w_stump, **kw),
        Art("boulder", 2, 2, wd_boulder if d else w_boulder, **kw),
        Art("log", 2, 1, wd_log if d else w_log, **kw),
        Art("tent", 2, 1, wd_tent if d else w_tent, **kw),
        Art("car", 2, 1, wd_car if d else w_car, **kw),
    ]
    ground = [
        Art("path_a", 1, 1, wg_path(1)),
        Art("path_b", 1, 1, wg_path(2)),
        Art("fire_ring", 1, 1, wg_fire_ring),
        Art("leaves", 1, 1, wg_leaves),
        Art("puddle", 1, 1, wg_puddle),
    ]
    decals = [Art(f"tuft{s}", 1, 1, d_tuft(s)) for s in (2, 3, 3, 4)] + [Art("flower", 1, 1, d_flower), Art("pebbles", 1, 1, d_pebbles), Art("twig", 1, 1, d_twig)]
    kit = Kit("woods", "Overgrown Woodland", pieces, ground, decals, 0.45, None, cell=1 if d else None, phases=PHASES if d else 1)
    kit.outside = woods_outside(kit)
    return kit


KIT_BUILDERS = [build_woods, build_city, build_quarantine]


def build_all():
    return [b() for b in KIT_BUILDERS]


# ================================================================ output

def write_tileset(path, name, arts, image_dir_rel):
    max_w = max(a.tiled_preview().width for a in arts)
    max_h = max(a.tiled_preview().height for a in arts)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<tileset version="1.9" tiledversion="1.9.2" name="{name}" tilewidth="{max_w}" tileheight="{max_h}" tilecount="{len(arts)}" columns="0">',
        ' <grid orientation="orthogonal" width="1" height="1"/>',
    ]
    for i, a in enumerate(arts):
        prev = a.tiled_preview()
        lines.append(f' <tile id="{i}">')
        lines.append('  <properties>')
        lines.append(f'   <property name="name" value="{a.name}"/>')
        lines.append(f'   <property name="footprint" value="{a.fw}x{a.fh}"/>')
        lines.append('  </properties>')
        lines.append(f'  <image width="{prev.width}" height="{prev.height}" source="{image_dir_rel}/{a.name}.png"/>')
        lines.append(' </tile>')
    lines.append('</tileset>')
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def write_tiled(kits, out_dir="map-tiles/kits"):
    for kit in kits:
        for sub, arts in (("pieces", kit.pieces), ("ground", kit.ground)):
            img_dir = os.path.join(out_dir, kit.name, sub)
            os.makedirs(img_dir, exist_ok=True)
            for a in arts:
                a.tiled_preview().save(os.path.join(img_dir, f"{a.name}.png"))
            write_tileset(os.path.join(out_dir, f"{kit.name}_{sub}.tsx"), f"{kit.name}_{sub}", arts, f"{kit.name}/{sub}")


def write_images(kits, images_dir):
    for kit in kits:
        for f in os.listdir(images_dir):  # Whichever way it was written before
            if f.startswith(f"{kit.name}-piece-"):
                os.remove(os.path.join(images_dir, f))
        for i, a in enumerate(kit.pieces):
            if kit.phases == 1:
                a.image.save(os.path.join(images_dir, f"{kit.name}-piece-{i}.png"))
            else:
                for v, im in enumerate(a.images):
                    im.save(os.path.join(images_dir, f"{kit.name}-piece-{i}-p{v}.png"))


def write_descs(kits, path="src/kit_descs.zig"):
    lines = [
        "//Autogenerated by env_kits.py: the environment kits' pieces and the baked ground's layout",
        "",
        "/// Pixels the baked ground bitmap extends beyond the map on each side (it covers the camera's widest lean)",
        f"pub const GROUND_MARGIN_X: i32 = {GROUND_MARGIN_X};",
        f"pub const GROUND_MARGIN_Y: i32 = {GROUND_MARGIN_Y};",
        "",
        "/// A piece's bitmap size and the pixel that sits on its anchor cell's centre, drawn as is and mirrored",
        "pub const Piece = struct { w: i16, h: i16, anchor_x: i16, anchor_x_flipped: i16, anchor_y: i16 };",
        "",
        "/// `phases`: 1, or PHASES when every piece (and the kit's levels' floors) come in phase variants",
        "pub const Kit = struct { name: [:0]const u8, phases: u8, pieces: []const Piece };",
        "",
        f"pub const PHASES = {PHASES};",
        "",
        "pub const KITS = [_]Kit{",
    ]
    for kit in kits:
        lines.append(f'    .{{ .name = "{kit.name}", .phases = {kit.phases}, .pieces = &.{{')
        for a in kit.pieces:
            ax, ay = a.anchor
            lines.append(f"        .{{ .w = {a.image.width}, .h = {a.image.height}, .anchor_x = {ax}, .anchor_x_flipped = {a.anchor_flipped_x}, .anchor_y = {ay} }}, //{a.name} {a.fw}x{a.fh}")
        lines.append("    } },")
    lines.append("};")
    lines.append("")
    lines.append("pub const MAX_KIT_PIECES = blk: {")
    lines.append("    var n: usize = 0;")
    lines.append("    for (KITS) |k| n = @max(n, k.pieces.len);")
    lines.append("    break :blk n;")
    lines.append("};")
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def preview(kits, path):
    """Contact sheet of every kit's pieces and ground at 2x"""
    rows = []
    for kit in kits:
        for arts in (kit.pieces, kit.ground + kit.decals):
            row_h = max(a.image.height for a in arts) + 8
            row_w = sum(a.image.width + 8 for a in arts) + 8
            row = Image.new("L", (row_w, row_h), 210)
            x = 8
            for a in arts:
                bg = Image.new("L", a.image.size, 255)
                row.paste(bg, (x, row_h - a.image.height - 4))
                row.paste(a.image.convert("L"), (x, row_h - a.image.height - 4), a.image.split()[3])
                x += a.image.width + 8
            rows.append(row)
    w = max(r.width for r in rows)
    sheet = Image.new("L", (w, sum(r.height for r in rows)), 120)
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(path)


def write(images_dir):
    kits = build_all()
    write_images(kits, images_dir)
    write_tiled(kits)
    write_descs(kits)
    return kits


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("images", nargs="?", default="images")
    parser.add_argument("--preview")
    args = parser.parse_args()
    kits = write(args.images)
    if args.preview:
        preview(kits, args.preview)
    print(f"wrote {len(kits)} kits: " + ", ".join(f"{k.name} ({len(k.pieces)} pieces, {len(k.ground)} ground)" for k in kits))
