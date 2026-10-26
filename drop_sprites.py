import argparse
import os
from PIL import Image

"""
Ammo and health drop sprites, hand authored at final size in 1-bit (no dithering pass, so no mud).
Written as a bitmap table `images/drops-table-N.png`, in `DropKind` order (src/game_state.zig).
Called by convert_raw.py, or run directly: python drop_sprites.py [out_dir]

Reading rules: type reads by tone (ammo is dark with white brass on top, health is a white kit with a black
cross) and size by footprint. Light from the top left, so the right side and front face are shaded.
Every sprite gets a 1px white rim so it reads over enemies and dark ground, and a stippled black shadow
(transparent between the dots so the ground shows through) as its bottom row, which is the anchor row.

Legend: '.' transparent, 'B' black, 'W' white, 'd' dark dither (75% black), 'l' light dither (25% black),
's' shadow stipple (50% black, transparent between)
"""

DROP_W = 28
DROP_H = 26

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
    ".sssssssssssss.",
]

AMMO_LARGE = [
    "...B...B...B...B...B...",
    "..BWB.BWB.BWB.BWB.BWB..",
    "..BWB.BWB.BWB.BWB.BWB..",
    "..BWB.BWB.BWB.BWB.BWB..",
    "..BWB.BWB.BWB.BWB.BWB..",
    "BBBBBBBBBBBBBBBBBBBBBBB",
    "BWWWWWWWWWWWWWWWWWWWWdB",
    "BBBBBBBBBBBBBBBBBBBBBBB",
    "BWWBdddddddddddddddBWdB",
    "BWWBdddddddddddddddBWdB",
    "BWWBdddddddddddddddBWdB",
    "BWWBBBBBBBBBBBBBBBBBWdB",
    "BWWBdddddddddddddddBWdB",
    "BWWBdddddddddddddddBWdB",
    "BWWBdddddddddddddddBWdB",
    "BWWBBBBBBBBBBBBBBBBBWdB",
    "BWWBdddddddddddddddBWdB",
    "BWWBdddddddddddddddBWdB",
    "BWWBdddddddddddddddBWdB",
    "BBBBBBBBBBBBBBBBBBBBBBB",
    ".sssssssssssssssssssss.",
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
    ".ssssssssssss.",
]

HEALTH_LARGE = [
    "........BBBBBB........",
    ".......BB....BB.......",
    ".......B......B.......",
    "BBBBBBBBBBBBBBBBBBBBBB",
    "BWWWWWWWWWWWWWWWWWWllB",
    "BWWWWWWWWBBBBWWWWWWllB",
    "BWWWWWWWWBBBBWWWWWWllB",
    "BWWWWWWWWBBBBWWWWWWllB",
    "BWWWWBBBBBBBBBBBBWWllB",
    "BWWWWBBBBBBBBBBBBWWllB",
    "BWWWWBBBBBBBBBBBBWWllB",
    "BWWWWBBBBBBBBBBBBWWllB",
    "BWWWWWWWWBBBBWWWWWWllB",
    "BWWWWWWWWBBBBWWWWWWllB",
    "BWWWWWWWWBBBBWWWWWWllB",
    "BWWWWWWWWWWWWWWWWWWllB",
    "BddddddddddddddddddddB",
    "BBBBBBBBBBBBBBBBBBBBBB",
    ".ssssssssssssssssssss.",
]

# DropKind order: ammo_small, ammo_large, health_small, health_large
SPRITES = [AMMO_SMALL, AMMO_LARGE, HEALTH_SMALL, HEALTH_LARGE]

BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)


def pixel(c, x, y):
    """ Dither patterns are aligned to the sprite cell, whose origin is kept on even screen pixels """
    if c == 'B':
        return BLACK
    if c == 'W':
        return WHITE
    if c == 'd':
        return WHITE if (x % 2 == 0 and y % 2 == 0) else BLACK
    if c == 'l':
        return BLACK if (x % 2 == 0 and y % 2 == 0) else WHITE
    if c == 's':
        return BLACK if (x + y) % 2 == 0 else CLEAR
    return CLEAR


def render(rows):
    width = len(rows[0])
    assert all(len(r) == width for r in rows), "rows must all be the same width"
    assert width + 2 <= DROP_W and len(rows) + 1 <= DROP_H
    img = Image.new('RGBA', (DROP_W, DROP_H), CLEAR)
    # Bottom centred: the shadow row is the cell's bottom row
    ox = (DROP_W - width) // 2
    oy = DROP_H - len(rows)
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            img.putpixel((ox + x, oy + y), pixel(c, ox + x, oy + y))
    # 1px white rim around the solid shape (not the shadow), so it reads over dark ground and enemies
    rim = []
    for y in range(DROP_H):
        for x in range(DROP_W):
            if img.getpixel((x, y))[3] != 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if not (0 <= nx < DROP_W and 0 <= ny < DROP_H):
                    continue
                sy, sx = ny - oy, nx - ox
                solid = 0 <= sy < len(rows) and 0 <= sx < width and rows[sy][sx] in 'BWdl'
                if solid:
                    rim.append((x, y))
                    break
    for p in rim:
        img.putpixel(p, WHITE)
    return img


def write(out_dir):
    for i, rows in enumerate(SPRITES):
        render(rows).save(os.path.join(out_dir, f"drops-table-{i + 1}.png"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog='Drop sprites', description='Write the 1-bit ammo and health drop sprites')
    parser.add_argument('out_dir', nargs='?', default='images')
    write(parser.parse_args().out_dir)
