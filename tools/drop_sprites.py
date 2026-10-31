import argparse
import os
from PIL import Image

"""
Ammo and health drop sprites, hand authored as 1-bit pixel grids (no dithering pass, so no mud).
Written as a bitmap table `images/drops-table-N.png`: per `DropKind` (src/game_state.zig, in order) a still
frame then SHEEN_FRAMES frames of a light sweep across it, so `index = kind * FRAMES_PER_KIND + frame`.
Called by convert_raw.py, or run directly: python tools/drop_sprites.py [out_dir]

Reading rules: type reads by tone (ammo is dark with white brass on top, health is a white kit with a black
cross) and size by footprint. Light from the top left, so the right side and front face are shaded.
Each grid character is SCALE x SCALE pixels; dither and the 1px white rim (so it reads over enemies and dark
ground) are applied at the final resolution, so they stay crisp. The bottom row is the base (the anchor); the
renderer draws the shadow on the ground and bounces the sprite above it.

Legend: '.' transparent, 'B' black, 'W' white, 'd' dark dither (75% black), 'l' light dither (25% black)
"""

SCALE = 2
SHEEN_FRAMES = 5
FRAMES_PER_KIND = 1 + SHEEN_FRAMES
SHEEN_WIDTH = 9  # Pixels across the diagonal band of light

DROP_W = 48
DROP_H = 42

AMMO_SMALL = [
    "...B...B...B...",
    "..BWB.BWB.BWB..",
    "..BWB.BWB.BWB..",
    "..BWB.BWB.BWB..",
    "BBBBBBBBBBBBBBB",
    "BWWWWWWWWWWWWdB",
    "BBBBBBBBBBBBBBB",
    "BdddddddddddddB",
    "BdWWWWWWWWWWWdB",
    "BdddddddddddddB",
    "BdddddddddddddB",
    "BBBBBBBBBBBBBBB",
]

AMMO_LARGE = [
    "..B..B..B..B..B..",
    ".BWBBWBBWBBWBBWB.",
    ".BWBBWBBWBBWBBWB.",
    "BBBBBBBBBBBBBBBBB",
    "BWWWWWWWWWWWWWWdB",
    "BBBBBBBBBBBBBBBBB",
    "BWBdddddddddddBdB",
    "BWBdWWWWWWWWWdBdB",
    "BWBdddddddddddBdB",
    "BWBBBBBBBBBBBBBdB",
    "BWBdddddddddddBdB",
    "BWBdddddddddddBdB",
    "BBBBBBBBBBBBBBBBB",
]

HEALTH_SMALL = [
    ".....BBBB.....",
    ".....B..B.....",
    "BBBBBBBBBBBBBB",
    "BWWWWWWWWWWWlB",
    "BWWWWWBBWWWWlB",
    "BWWWWWBBWWWWlB",
    "BWWBBBBBBBBWlB",
    "BWWBBBBBBBBWlB",
    "BWWWWWBBWWWWlB",
    "BWWWWWBBWWWWlB",
    "BWWWWWWWWWWWlB",
    "BBBBBBBBBBBBBB",
]

HEALTH_LARGE = [
    "......BBBB......",
    "......B..B......",
    "BBBBBBBBBBBBBBBB",
    "BWWWWWWBBWWWWWlB",
    "BWWWWWWBBWWWWWlB",
    "BWWWBBBBBBBBWWlB",
    "BWWWBBBBBBBBWWlB",
    "BWWWWWWBBWWWWWlB",
    "BWWWWWWBBWWWWWlB",
    "BWWWWWWWWWWWWWlB",
    "BddddddddddddddB",
    "BBBBBBBBBBBBBBBB",
]

# DropKind order: ammo_small, ammo_large, health_small, health_large
SPRITES = [AMMO_SMALL, AMMO_LARGE, HEALTH_SMALL, HEALTH_LARGE]

BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)


def pixel(c, x, y):
    """ Dither patterns are aligned to the sprite cell """
    if c == 'B':
        return BLACK
    if c == 'W':
        return WHITE
    if c == 'd':
        return WHITE if (x % 2 == 0 and y % 2 == 0) else BLACK
    if c == 'l':
        return BLACK if (x % 2 == 0 and y % 2 == 0) else WHITE
    return CLEAR


def render(rows, sheen_frame=0):
    """ The sprite bottom centred in the cell. sheen_frame 1..SHEEN_FRAMES inverts the inside of the sprite
    (not its outline) under a diagonal band moving from the top left to the bottom right """
    width = len(rows[0]) * SCALE
    height = len(rows) * SCALE
    assert all(len(r) == len(rows[0]) for r in rows), "rows must all be the same width"
    assert width + 2 <= DROP_W and height + 1 <= DROP_H
    ox = (DROP_W - width) // 2
    oy = DROP_H - height

    def char_at(x, y):
        sx, sy = (x - ox) // SCALE, (y - oy) // SCALE
        if 0 <= sx < len(rows[0]) and 0 <= sy < len(rows) and x >= ox and y >= oy:
            return rows[sy][sx]
        return '.'

    def solid(x, y):
        return char_at(x, y) in 'BWdl'

    img = Image.new('RGBA', (DROP_W, DROP_H), CLEAR)
    band_centre = None
    if sheen_frame > 0:
        span = width + height
        band_centre = -SHEEN_WIDTH + (span + 2 * SHEEN_WIDTH) * sheen_frame // (SHEEN_FRAMES + 1)
    for y in range(DROP_H):
        for x in range(DROP_W):
            c = char_at(x, y)
            if c == '.':
                continue
            colour = pixel(c, x, y)
            if band_centre is not None:
                inside = all(solid(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                if inside and abs((x - ox) + (y - oy) - band_centre) <= SHEEN_WIDTH // 2:
                    colour = BLACK if colour == WHITE else WHITE
            img.putpixel((x, y), colour)
    # 1px white rim around the shape, so it reads over dark ground and enemies
    for y in range(DROP_H):
        for x in range(DROP_W):
            if solid(x, y):
                continue
            if any(solid(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                img.putpixel((x, y), WHITE)
    return img


def write(out_dir):
    for kind, rows in enumerate(SPRITES):
        for frame in range(FRAMES_PER_KIND):
            index = kind * FRAMES_PER_KIND + frame
            render(rows, frame).save(os.path.join(out_dir, f"drops-table-{index + 1}.png"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog='Drop sprites', description='Write the 1-bit ammo and health drop sprites')
    parser.add_argument('out_dir', nargs='?', default='images')
    write(parser.parse_args().out_dir)
