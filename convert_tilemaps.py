import argparse
import os
import random
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image, ImageDraw

import env_kits

"""
Convert the Tiled maps (map-tiles/<level>.tmx, read directly: no JSON export needed) into the game's level files
and baked ground bitmaps.

A map is CELL_W x CELL_H pixel tiles (the game's cell size) with a `kit` map property naming its environment kit
(env_kits.py) and these layers:
- `ground` (tile layer, the kit's <kit>_ground tileset): flat art baked into the ground bitmap, never blocks
- `objects` (tile layer, the kit's <kit>_pieces tileset): obstacles. Each blocks its footprint, which extends right
  and up from the cell it is placed on. Flipping a tile horizontally in Tiled mirrors it in the game
- `drops` (object layer): point objects named `small` or `large`, which must sit on free cells, and one named
  `start`, the free cell the player starts on (the middle cell if there is none)

Outputs per level:
- levels/<level>.bin: u8 width, height, cell width px, cell height px, kit index, drop point count,
  u16 player start cell; per drop point u16 cell, u8 size; the blocked cells as a bitmask (bit i % 8 of byte i / 8, row major);
  then per object u16 cell, u8 piece index (bit 7 set = mirrored) to the end of the file
- images/ground-<level>.png: the floor (ground layer, decals scattered over free floor by a hash of the cell) and
  the view beyond the map (the kit's outside), GROUND_MARGIN_X/Y pixels past each edge. 1-bit with no mask
"""

LEVEL_NAMES = ["woods", "city", "quarantine"]

DROP_SIZES = {'small': 0, 'large': 1}
FLIP_H = 0x80000000
GID_MASK = 0x1FFFFFFF
PIECE_FLIPPED = 0x80


def parse_tmx(path):
    root = ET.parse(path).getroot()
    m = {
        'width': int(root.get('width')), 'height': int(root.get('height')),
        'tilewidth': int(root.get('tilewidth')), 'tileheight': int(root.get('tileheight')),
        'props': {p.get('name'): p.get('value') for p in root.findall('./properties/property')},
        'tilesets': sorted((int(t.get('firstgid')), os.path.splitext(os.path.basename(t.get('source')))[0]) for t in root.findall('tileset')),
        'layers': {}, 'drops': [],
    }
    for layer in root.findall('layer'):
        data = layer.find('data')
        if data.get('encoding') != 'csv':
            raise ValueError(f"{path}: layer {layer.get('name')} must be CSV encoded")
        m['layers'][layer.get('name')] = [int(v) for v in data.text.replace('\n', '').split(',') if v.strip()]
    for group in root.findall('objectgroup'):
        if group.get('name') == 'drops':
            m['drops'] = [(o.get('id'), o.get('name'), float(o.get('x')), float(o.get('y'))) for o in group.findall('object')]
    return m


def decode_gid(m, gid):
    """-> (tileset name, local tile id, flipped) or None for an empty cell"""
    if gid == 0:
        return None
    flipped = bool(gid & FLIP_H)
    gid &= GID_MASK
    first, name = max((t for t in m['tilesets'] if t[0] <= gid), key=lambda t: t[0])
    return name, gid - first, flipped


def convert_level(name, kits, images_dir, preview_dir=None):
    m = parse_tmx(f"map-tiles/{name}.tmx")
    w, h = m['width'], m['height']
    if (m['tilewidth'], m['tileheight']) != (env_kits.CELL_W, env_kits.CELL_H):
        raise ValueError(f"{name}: tiles must be {env_kits.CELL_W}x{env_kits.CELL_H} (the game's cell size)")
    kit_name = m['props'].get('kit')
    kit_index = next((i for i, k in enumerate(kits) if k.name == kit_name), None)
    if kit_index is None:
        raise ValueError(f"{name}: map property 'kit' must be one of {[k.name for k in kits]}")
    kit = kits[kit_index]

    def placed(layer_name, kind):
        """[(col, row, art index, flipped)] of a tile layer, checked against the kit's tileset"""
        out = []
        for i, gid in enumerate(m['layers'].get(layer_name, [])):
            tile = decode_gid(m, gid)
            if tile is None:
                continue
            ts, local, flipped = tile
            if ts != f"{kit.name}_{kind}":
                raise ValueError(f"{name}: layer {layer_name} uses tileset {ts}, expected {kit.name}_{kind}")
            out.append((i % w, i // w, local, flipped))
        return out

    objects = placed('objects', 'pieces')
    ground = placed('ground', 'ground')

    blocked = [False] * (w * h)
    for col, row, piece, _ in objects:
        art = kit.pieces[piece]
        for fy in range(art.fh):
            for fx in range(art.fw):
                c, r = col + fx, row - fy
                if not (0 <= c < w and 0 <= r < h):
                    raise ValueError(f"{name}: {art.name} at ({col}, {row}) reaches outside the map")
                if blocked[r * w + c]:
                    raise ValueError(f"{name}: {art.name} at ({col}, {row}) overlaps another piece at ({c}, {r})")
                blocked[r * w + c] = True

    drops = []
    start = (h // 2) * w + w // 2
    for oid, dname, x, y in m['drops']:
        col, row = int(x // m['tilewidth']), int(y // m['tileheight'])
        if not (0 <= col < w and 0 <= row < h):
            raise ValueError(f"{name}: drop point {oid} is outside the map")
        if blocked[row * w + col]:
            raise ValueError(f"{name}: point {oid} ({dname}) is on a blocked cell ({col}, {row})")
        if dname == 'start':
            start = row * w + col
            continue
        if dname not in DROP_SIZES:
            raise ValueError(f"{name}: drop point {oid} must be named one of {list(DROP_SIZES)}")
        drops.append((row * w + col, DROP_SIZES[dname]))
    if len(drops) > 255 or len(kit.pieces) > PIECE_FLIPPED:
        raise ValueError(f"{name}: too many drop points or pieces")

    with open(f"levels/{name}.bin", "wb") as of:
        of.write(bytes([w, h, env_kits.CELL_W, env_kits.CELL_H, kit_index, len(drops)]) + start.to_bytes(2, 'little'))
        for idx, size in drops:
            of.write(idx.to_bytes(2, 'little') + bytes([size]))
        mask = bytearray((w * h + 7) // 8)
        for i, b in enumerate(blocked):
            if b:
                mask[i // 8] |= 1 << (i % 8)
        of.write(mask)
        for col, row, piece, flipped in sorted(objects, key=lambda o: (o[1], o[0])):
            of.write((row * w + col).to_bytes(2, 'little') + bytes([piece | (PIECE_FLIPPED if flipped else 0)]))

    ground_img = bake_ground(name, kit, w, h, blocked, ground, images_dir)
    if preview_dir:
        preview_level(os.path.join(preview_dir, f"level-{name}.png"), ground_img, kit, objects, drops, w, start)
    return len(objects), len(drops)


def preview_level(path, ground_img, kit, objects, drops, w, start):
    """The whole level as the game draws it (objects over the ground, back to front), drop points circled and the
    start marked with an X"""
    mx, my = env_kits.GROUND_MARGIN_X, env_kits.GROUND_MARGIN_Y
    cw, ch = env_kits.CELL_W, env_kits.CELL_H
    img = ground_img.convert("L")
    for col, row, piece, flipped in sorted(objects, key=lambda o: (o[1], o[0])):
        im, (ax, ay) = kit.pieces[piece].placed(flipped)
        img.paste(im.convert("L"), (mx + col * cw + cw // 2 - ax, my + row * ch + ch // 2 - ay), im.split()[3])
    d = ImageDraw.Draw(img)
    for idx, size in drops:
        cx, cy = mx + (idx % w) * cw + cw // 2, my + (idx // w) * ch + ch // 2
        r = 9 if size else 5
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=0, width=2)
    sx, sy = mx + (start % w) * cw + cw // 2, my + (start // w) * ch + ch // 2
    d.line([sx - 8, sy - 8, sx + 8, sy + 8], fill=0, width=3)
    d.line([sx - 8, sy + 8, sx + 8, sy - 8], fill=0, width=3)
    img.save(path)


def bake_ground(name, kit, w, h, blocked, ground, images_dir):
    mx, my = env_kits.GROUND_MARGIN_X, env_kits.GROUND_MARGIN_Y
    cw, ch = env_kits.CELL_W, env_kits.CELL_H
    img = Image.new("L", (w * cw + 2 * mx, h * ch + 2 * my), 255)

    def paste(art, col, row, flipped=False, dx=0, dy=0):
        im, (ax, ay) = art.placed(flipped)
        cx, cy = mx + col * cw + cw // 2 + dx, my + row * ch + ch // 2 + dy
        img.paste(im.convert("L"), (cx - ax, cy - ay), im.split()[3])

    # Ground art as tones, dithered once across the whole level so neighbouring cells' patterns line up
    covered = set()
    for col, row, g, flipped in sorted(ground, key=lambda o: (o[1], o[0])):
        art = kit.ground[g]
        tone, mask, (ax, ay) = art.placed_tone(flipped)
        img.paste(tone, (mx + col * cw + cw // 2 - ax, my + row * ch + ch // 2 - ay), mask)
        for fy in range(art.fh):
            for fx in range(art.fw):
                covered.add((col + fx, row - fy))
    img = Image.fromarray(np.where(env_kits.bayer_bw(img), 255, 0).astype(np.uint8), "L")

    level_seed = sum(ord(c) * 31 ** i for i, c in enumerate(name))
    for row in range(h):
        for col in range(w):
            if blocked[row * w + col] or (col, row) in covered:
                continue
            rng = random.Random(level_seed + row * 7919 + col * 104729)
            if rng.random() < kit.decal_chance:
                paste(rng.choice(kit.decals), col, row, rng.random() < 0.5, rng.randint(-22, 22), rng.randint(-9, 9))

    # Beyond the map, row by row from the back so nearer things overlap
    ex, ey = mx // cw + 2, my // ch + 2
    for row in range(-ey, h + ey):
        for col in range(-ex, w + ex):
            if 0 <= col < w and 0 <= row < h:
                continue
            side = "north" if row < 0 else "south" if row >= h else "west" if col < 0 else "east"
            dist = max(-row, row - h + 1, -col, col - w + 1)
            rng = random.Random(level_seed + (row + 1000) * 7919 + (col + 1000) * 104729)
            for piece, flipped, dx, dy in kit.outside(rng, col, row, side, dist):
                paste(kit.pieces[piece], col, row, flipped, dx, dy)

    img = img.point(lambda v: 255 if v >= 128 else 0).convert("1")
    img.save(os.path.join(images_dir, f"ground-{name}.png"))
    return img


def convert_all(images_dir='images', kits=None, preview_dir=None):
    kits = kits or env_kits.build_all()
    os.makedirs('levels', exist_ok=True)
    for f in os.listdir('levels'):
        os.remove(os.path.join('levels', f))
    for name in LEVEL_NAMES:
        n_obj, n_drops = convert_level(name, kits, images_dir, preview_dir)
        print(f"{name}: {n_obj} objects, {n_drops} drop points")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog='Convert Tiled', description='Convert Tiled maps into Playdate level files and baked ground bitmaps')
    parser.add_argument('images', nargs='?', default='images')
    parser.add_argument('--preview', help="directory to write level-<name>.png overviews to (e.g. logs)")
    args = parser.parse_args()
    convert_all(args.images, preview_dir=args.preview)
