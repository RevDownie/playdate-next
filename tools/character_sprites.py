import argparse
import math
import os
from multiprocessing import Pool
import numpy as np
from sdf_sprites import ellipsoid, sphere, capsule, box, clip, pose, render, clean, outline, rim, composite, to_image

"""
The hero and zombie sprite sheets, modelled from primitives and rendered to 1-bit by sdf_sprites.py (raw-images/ is
git-ignored, so the source lives in this script). Called by convert_raw.py, or run directly:
    python tools/character_sprites.py [out_dir] [--preview logs/characters.png]

Only facings 0 (towards the screen) to 180 (away) are drawn; the renderer mirrors them for the other half, so every
model is left/right symmetric and weapons are held two-handed in the middle of the body (no hand swap at the seam).

Tones: 'W' white, 'L' 25% black, 'M' 50%, 'D' 75%, 'K' black. The hero is solid black and white masses with a white
rim, the strongest contrast on screen; zombies are pale dotted skin and dithered rags with a black outline.

Sheets (bitmap tables, index = facing * frames per facing + frame; facing = degrees / step):
- hero: 19 facings (10 degrees) x HERO_FRAMES (idle, 4 run, hurt), then HERO_DEATH_FACINGS (45 degrees) x
  HERO_DEATH_FRAMES falling down. Body only: the arms belong to the weapon layer
- hero_gun / hero_melee: the arms and weapon, drawn over the hero in the same cell with the same anchor. The body's
  occlusion is baked in (pixels the body hides are left out). Gun: idle, hurt. Melee: ready, strike, follow through
- zombie_<kind>: 11 facings (18 degrees) x ENEMY_FRAMES (4 walk, hit). They have no death: killed zombies burst
  into gibs (gore_sprites.py)
"""

# ---------------------------------------------------------------- layout (written into src/bitmap_descs.zig)
HERO_W, HERO_H, HERO_AX, HERO_AY = 48, 48, 24, 43
HERO_FACING_STEP = 10
HERO_FACINGS = 180 // HERO_FACING_STEP + 1
HERO_FRAMES = 6  # idle, run 0..3, hurt
HERO_RUN_FRAMES = 4
HERO_DEATH_FACING_STEP = 45
HERO_DEATH_FACINGS = 180 // HERO_DEATH_FACING_STEP + 1
HERO_DEATH_FRAMES = 4
GUN_FRAMES = 2  # idle, hurt
MELEE_FRAMES = 3  # ready, strike, follow through

ENEMY_FACING_STEP = 18  # Steps that land on 90: side on is the facing seen most
ENEMY_FACINGS = 180 // ENEMY_FACING_STEP + 1
ENEMY_FRAMES = 5  # walk 0..3, hit
ENEMY_WALK_FRAMES = 4
# Per kind (src/game_state.zig EnemyKind order): cell w, h and the feet's pixel in it
ENEMY_CELLS = {"runner": (32, 32, 16, 29), "walker": (48, 48, 24, 43), "shambler": (48, 48, 24, 43), "brute": (64, 64, 32, 58)}

STAND = ((0, 0), (0, 0))

# ---------------------------------------------------------------- shared


def legs(feet, hip_z, sep, r, tone, boot_tone="K", boot=(2.6, 3.6, 2.0), knee_fwd=2.0):
    """Two legs from the hips down to feet ((yL, zL), (yR, zR)), bent forward at the knee"""
    out = []
    for side, (fy, fz) in zip((-1, 1), feet):
        hip = (side * sep, 0, hip_z)
        foot = (side * sep, fy, fz + boot[2] + 1)
        knee = (side * sep, fy * 0.5 - knee_fwd, (hip_z + fz) * 0.5 + 1)
        out += [capsule(hip, knee, r, tone, "leg%d" % side), capsule(knee, foot, r * 0.9, tone, "leg%d" % side),
                box((side * sep, fy - 1.2, fz + boot[2]), boot, boot_tone, "leg%d" % side, rnd=1.2)]
    return out


def cycle(stride, lift):
    """A 4 frame walk: contact, passing, contact on the other foot, passing. Feet as ((yL, zL), (yR, zR))"""
    return [((-stride, 0.3), (stride * 0.9, lift * 0.6)),
            ((-stride * 0.25, 0), (0, lift)),
            ((stride * 0.9, lift * 0.6), (-stride, 0.3)),
            ((0, lift), (-stride * 0.25, 0))]


def fall(prims, pitch, lift, facing):
    """Topple about the feet, lifted so the back rests on the ground. Always up the screen (away from the camera)
    whichever way it faces, so the body stays inside the cell above its feet"""
    return pose(prims, (0, 0, 0), pitch=pitch, offset=(0, 0, lift * math.sin(math.radians(pitch))), toward=facing)

# ---------------------------------------------------------------- hero: big head, small body, headband, white tee and black vest


HERO_SHOULDER = (6.4, 21.5)  # x, z
HERO_HIP_PIVOT = (0, 0, 10)


def hero_body(feet=STAND):
    p = legs(feet, 10, 3.2, 2.6, "K", boot=(2.4, 3.2, 1.6), knee_fwd=1.2)
    p += [
        box((0, 0, 16.5), (6.2, 4.0, 5.5), "W", "torso", rnd=2.4),                # white tee
        box((0, -0.4, 17.5), (5.9, 4.1, 3.8), "K", "vest", rnd=1.2),              # black vest over it
        box((0, 0, 11.6), (6.2, 4.1, 1.0), "D", "belt"),
        box((0, 5.0, 17.5), (4.2, 1.8, 4.6), "D", "pack", rnd=1.2),               # ammo pack feeding the gun
        ellipsoid((0, -0.5, 30), (8.2, 7.8, 8.0), "W", "head", flat=True),       # face stays solid white
        clip(ellipsoid((0, 0.1, 30.6), (8.6, 8.2, 8.0), "K", "hair"), 2, 36.6),
        clip(clip(ellipsoid((0, -0.1, 30.4), (8.7, 8.3, 8.4), "K", "band"), 2, 34.4), 2, 37.2, keep_above=False),
        capsule((0, 7.6, 35), (2.5, 12.5, 30.5), 1.3, "K", "tails"),              # headband knot tails
        capsule((0, 7.6, 35), (-2.0, 13.0, 32), 1.3, "K", "tails"),
        box((-2.9, -8.2, 30.2), (0.9, 0.8, 1.4), "K", "head", flat=True),         # eyes
        box((2.9, -8.2, 30.2), (0.9, 0.8, 1.4), "K", "head", flat=True),
        box((0.0, -7.4, 25.6), (1.3, 0.7, 0.45), "K", "head", flat=True),         # set mouth
        box((-5.2, -6.8, 31.0), (0.5, 0.8, 2.4), "K", "head", flat=True, roll=25),  # scar over one eye
    ]
    return p


def hero_arms(hands, tone="W", r=2.3):
    out = []
    sx, sz = HERO_SHOULDER
    for side, h in zip((-1, 1), hands):
        sh = (side * sx, 0, sz)
        el = (side * (sx + 0.8), h[1] * 0.45, (sz + h[2]) * 0.5 - 1)
        out += [capsule(sh, el, r, tone, "arm%d" % side), capsule(el, h, r * 0.9, tone, "arm%d" % side),
                sphere(h, r, "W", "hand%d" % side)]
    return out


GUN_Z = 13.5  # Height of the barrels' axis: GUN_HEIGHT_PX in tweak_constants is this on screen
GUN_MUZZLE_Y = -18.5  # Model px ahead of the feet the barrels end: MUZZLE_FORWARD


def gatling():
    p = hero_arms(((-3.2, -7, 13.0), (3.2, -7, 13.0)))
    p += [box((0, -7.5, GUN_Z), (3.4, 3.6, 3.0), "K", "gun", rnd=1.0),
          capsule((0, 3.6, 15), (0, -5, 13), 1.0, "K", "hose")]
    for i in range(6):
        a = math.tau * i / 6
        p.append(capsule((math.cos(a) * 1.7, -10.5, GUN_Z + math.sin(a) * 1.7),
                         (math.cos(a) * 1.7, GUN_MUZZLE_Y, GUN_Z + math.sin(a) * 1.7), 0.7, "K", "barrel"))
    p += [capsule((0, -15.5, GUN_Z), (0, -16.5, GUN_Z), 2.7, "W", "clamp"),
          capsule((0, -10, GUN_Z), (0, GUN_MUZZLE_Y, GUN_Z), 0.9, "K", "gun")]
    return p


def slung_gatling():
    return [capsule((-5, 6.5, 24), (5, 6.5, 12), 2.2, "K", "slung"),
            capsule((-5.5, 7.0, 24.5), (-6.5, 7.2, 26.5), 1.4, "W", "slung")]


def fire_axe(frame):
    """Ready: raised across the body. Strike: swung out in front. Follow through: low on the other side"""
    if frame == 0:
        hands, a, b, head, roll = ((3.0, -7, 14), (-4.0, -7, 19)), (6, -8, 8), (-9, -7, 26), (-12.0, -7, 26), 40
    elif frame == 1:
        hands, a, b, head, roll = ((-1.5, -9, 15), (1.5, -11, 15)), (0, -6, 15), (0, -19, 17), (0, -21, 17), 0
    else:
        hands, a, b, head, roll = ((-3.0, -8, 16), (3.5, -9, 12)), (-6, -8, 20), (8, -10, 6), (10.5, -10, 5), -40
    p = hero_arms(hands)
    p += [capsule(a, b, 1.1, "K", "haft"),
          box(head, (3.2, 1.0, 3.2) if frame != 1 else (1.0, 3.2, 3.2), "W", "axehead", rnd=0.5, roll=roll),
          box(b, (1.5, 1.0, 1.6), "K", "axehead", roll=roll)]
    return p + slung_gatling()

# ---------------------------------------------------------------- zombies: pale rotters


def zombie_walker(feet=STAND, sway=0.0):
    p = legs(feet, 12, 3.2, 2.4, "D", boot_tone="D", boot=(2.2, 3.0, 1.6))
    p += [
        box((0, -0.5, 19), (6.2, 4.0, 6.0), "M", "torso", rnd=2.2, pitch=12),
        box((-2.0, -4.5, 16.5), (2.5, 0.6, 2.0), "K", "torso", flat=True),        # torn hole
        ellipsoid((0, -3.0, 28.5), (5.0, 5.0, 5.4), "L", "head"),
        sphere((-2.0, -7.6, 29.0), 1.0, "K", "head", flat=True),
        sphere((2.0, -7.6, 29.0), 1.0, "K", "head", flat=True),
        box((0, -7.6, 26.3), (1.6, 0.5, 0.8), "K", "head", flat=True),           # mouth
        box((-1.5, -1.0, 33.5), (2.0, 2.0, 0.8), "D", "head", flat=True),        # wound
    ]
    for side in (-1, 1):
        z = 23 + side + side * sway
        p += [capsule((side * 6.6, -1, 23), (side * 5.0, -13, z), 2.4, "L", "arm%d" % side),
              sphere((side * 4.8, -13.5, z), 2.2, "L", "arm%d" % side)]          # arms reaching out
    return p


def zombie_runner(feet=STAND, sway=0.0):
    p = legs(feet, 9, 2.4, 1.8, "D", boot_tone="D", boot=(1.6, 2.4, 1.2), knee_fwd=2.5)
    p += [
        box((0, -2.5, 15), (4.2, 2.6, 4.5), "L", "torso", rnd=1.6, pitch=-35),    # leaning hard into the run
        box((0, -4.7, 14.5), (2.8, 0.4, 2.8), "D", "torso", flat=True, pitch=-35),  # ribs
        box((0, -5.0, 15.0), (2.8, 0.3, 0.4), "K", "torso", flat=True, pitch=-35),
        ellipsoid((0, -7.0, 19.5), (3.6, 3.8, 3.6), "L", "head"),
        sphere((-1.4, -10.4, 19.8), 0.8, "K", "head", flat=True),
        sphere((1.4, -10.4, 19.8), 0.8, "K", "head", flat=True),
        box((0, -10.6, 17.8), (1.3, 0.4, 0.7), "K", "head", flat=True),
    ]
    for side in (-1, 1):
        p += [capsule((side * 4.4, -3.5, 17.5), (side * 5.5, 4.5 + side * sway * 2, 12.5), 1.4, "L", "arm%d" % side)]  # arms trailing
    return p


def zombie_shambler(feet=STAND, sway=0.0):
    p = legs(feet, 12, 3.6, 2.6, "D", boot_tone="K", boot=(2.2, 3.0, 1.6))
    p += [
        clip(ellipsoid((0, 0.5, 14), (7.4, 6.0, 10.0), "D", "rags"), 2, 6.0),    # long ragged coat
        box((0, 0, 21), (6.5, 4.2, 5.5), "D", "rags", rnd=2.0),
        box((0, -4.3, 19), (1.0, 0.4, 6.0), "K", "rags", flat=True),
        ellipsoid((0, -1.5, 29.0), (5.2, 5.2, 5.3), "L", "head"),
        sphere((-2.0, -6.4, 29.0), 1.1, "K", "head", flat=True),
        sphere((2.0, -6.4, 29.0), 1.1, "K", "head", flat=True),
        box((0, -6.5, 26.6), (2.2, 0.5, 1.1), "K", "head", flat=True),          # gaping mouth
        clip(ellipsoid((0, 0.5, 30.5), (5.6, 5.6, 5.0), "D", "hair"), 2, 31.5),  # lank hair
    ]
    for side in (-1, 1):
        y = -2.5 + side * sway
        p += [capsule((side * 7.0, 0, 24), (side * 8.5, y, 11), 2.0, "L", "arm%d" % side),
              sphere((side * 8.6, y - 0.1, 10.5), 2.0, "L", "arm%d" % side)]   # arms hanging low
    return p


def zombie_brute(feet=STAND, sway=0.0):
    p = legs(feet, 14, 6.5, 4.6, "D", boot_tone="K", boot=(4.0, 4.6, 2.4))
    p += [
        ellipsoid((0, -1.5, 25), (12.5, 10.5, 12.5), "L", "belly"),             # bloated gut
        box((0, -11.5, 22), (3.0, 0.5, 4.0), "D", "belly", flat=True),          # stitched scar
        box((0, -12.0, 22), (3.2, 0.4, 0.3), "K", "belly", flat=True),
        box((0, -1.2, 16), (11.5, 9.0, 3.0), "D", "pants", rnd=2.5),
        ellipsoid((0, 1, 35), (13.0, 8.0, 5.0), "L", "shoulders"),              # hunched shoulders
        ellipsoid((0, -5.0, 38.5), (4.2, 4.0, 4.0), "L", "head"),               # tiny head
        sphere((-1.6, -8.7, 38.8), 0.9, "K", "head", flat=True),
        sphere((1.6, -8.7, 38.8), 0.9, "K", "head", flat=True),
        box((0, -8.8, 36.4), (1.6, 0.4, 0.7), "K", "head", flat=True),
        box((0, 4, 38), (6.0, 2.0, 1.0), "K", "shoulders", flat=True),          # strap
    ]
    for side in (-1, 1):
        y = -5 + side * sway
        p += [capsule((side * 13, 0, 34), (side * 16, -2, 18), 4.0, "L", "arm%d" % side, r2=3.6),
              capsule((side * 16, -2, 18), (side * 15, y, 6), 4.0, "L", "arm%d" % side, r2=4.8)]  # huge fists
    return p


ZOMBIES = {
    # model, stride, foot lift, arm sway
    "runner": (zombie_runner, 4.5, 2.5, 1.5),
    "walker": (zombie_walker, 3.0, 1.5, 1.0),
    "shambler": (zombie_shambler, 2.0, 0.8, 1.5),
    "brute": (zombie_brute, 3.0, 1.5, 2.0),
}

# ---------------------------------------------------------------- frames


def hero_frame(spec):
    """(layer, facing, frame) -> (spec, body or weapon image). Weapon layers are rendered with the body as an
    occluder, then rimmed only where the body (with its own rim) leaves the ground showing"""
    layer, facing, frame = spec
    w, h, ax, ay = HERO_W, HERO_H, HERO_AX, HERO_AY
    if layer == "death":
        body = fall(hero_body(), (20, 45, 70, 88)[frame], 4.0, facing)
        return spec, rim(outline(clean(render(body, w, h, ax, ay, facing))))
    if layer == "body":
        feet = cycle(4.0, 3.0)[frame - 1] if 1 <= frame <= HERO_RUN_FRAMES else STAND
        body = hero_body(feet)
        if frame == HERO_FRAMES - 1:
            body = pose(body, HERO_HIP_PIVOT, pitch=16, offset=(0, 1, -1))
        return spec, rim(outline(clean(render(body, w, h, ax, ay, facing))))
    body = hero_body()
    weapon = gatling() if layer == "gun" else fire_axe(frame)
    if layer == "gun" and frame == 1:
        body = pose(body, HERO_HIP_PIVOT, pitch=16, offset=(0, 1, -1))
        weapon = pose(weapon, HERO_HIP_PIVOT, pitch=16, offset=(0, 1, -1))
    body_img = rim(outline(clean(render(body, w, h, ax, ay, facing))))
    img = outline(clean(render(body + weapon, w, h, ax, ay, facing, keep_from=len(body))))
    return spec, rim(img, blocked=body_img >= 0)


def enemy_frame(spec):
    kind, facing, frame = spec
    model, stride, lift, sway = ZOMBIES[kind]
    w, h, ax, ay = ENEMY_CELLS[kind]
    if frame < ENEMY_WALK_FRAMES:
        prims = model(cycle(stride, lift)[frame], sway * (1 if frame < 2 else -1))
    else:
        prims = pose(model(), (0, 0, 10), pitch=18, offset=(0, 1.5, -1))  # hit: rocked back
    return spec, outline(clean(render(prims, w, h, ax, ay, facing)))


def specs():
    hero = [("body", f * HERO_FACING_STEP, i) for f in range(HERO_FACINGS) for i in range(HERO_FRAMES)]
    hero += [("death", f * HERO_DEATH_FACING_STEP, i) for f in range(HERO_DEATH_FACINGS) for i in range(HERO_DEATH_FRAMES)]
    hero += [("gun", f * HERO_FACING_STEP, i) for f in range(HERO_FACINGS) for i in range(GUN_FRAMES)]
    hero += [("melee", f * HERO_FACING_STEP, i) for f in range(HERO_FACINGS) for i in range(MELEE_FRAMES)]
    enemies = [(k, f * ENEMY_FACING_STEP, i) for k in ZOMBIES for f in range(ENEMY_FACINGS) for i in range(ENEMY_FRAMES)]
    return hero, enemies


def build(processes=None):
    """Render every frame. Returns {sheet name: [frames in table order]}"""
    hero, enemies = specs()
    with Pool(processes) as pool:
        frames = dict(pool.map(hero_frame, hero, chunksize=4))
        frames.update(pool.map(enemy_frame, enemies, chunksize=4))
    sheets = {
        "hero": [frames[s] for s in hero if s[0] in ("body", "death")],
        "hero_gun": [frames[s] for s in hero if s[0] == "gun"],
        "hero_melee": [frames[s] for s in hero if s[0] == "melee"],
    }
    for k in ZOMBIES:
        sheets["zombie_" + k] = [frames[s] for s in enemies if s[0] == k]
    return sheets


def save(sheets, out_dir):
    for name, frames in sheets.items():
        assert len(frames) <= 256, name + " has more frames than a u8 index"
        for i, img in enumerate(frames):
            to_image(img).save(os.path.join(out_dir, f"{name}-table-{i + 1}.png"))


def preview(sheets, path, scale=3):
    """Contact sheet for checking the art: every facing of the hero (idle, run, hurt, gun and melee over it) and each
    zombie's frames, on grey"""
    from PIL import Image
    rows = []
    for f in range(HERO_FACINGS):
        cells = []
        for i in range(HERO_FRAMES):
            img = sheets["hero"][f * HERO_FRAMES + i].copy()
            composite(img, sheets["hero_gun"][f * GUN_FRAMES + (1 if i == HERO_FRAMES - 1 else 0)])
            cells.append(img)
        for i in range(MELEE_FRAMES):
            img = sheets["hero"][f * HERO_FRAMES].copy()
            composite(img, sheets["hero_melee"][f * MELEE_FRAMES + i])
            cells.append(img)
        rows.append(cells)
    death_start = HERO_FACINGS * HERO_FRAMES
    rows.append(sheets["hero"][death_start:death_start + HERO_DEATH_FACINGS * HERO_DEATH_FRAMES:2])
    for k in ZOMBIES:
        for f in range(0, ENEMY_FACINGS, 3):
            rows.append(sheets["zombie_" + k][f * ENEMY_FRAMES:(f + 1) * ENEMY_FRAMES])
    cw = 64
    canvas = np.full((len(rows) * cw, max(len(r) for r in rows) * cw), -2)
    for r, cells in enumerate(rows):
        for c, img in enumerate(cells):
            composite(canvas, img, c * cw + (cw - img.shape[1]) // 2, r * cw + (cw - img.shape[0]))
    rgb = np.zeros(canvas.shape + (3,), np.uint8)
    rgb[canvas == 1] = 255
    rgb[canvas < 0] = 120
    im = Image.fromarray(rgb)
    im.resize((im.width * scale, im.height * scale), Image.NEAREST).save(path)


def desc_lines():
    """Zig constants for src/bitmap_descs.zig"""
    lines = [
        f"pub const HERO_W: u32 = {HERO_W};", f"pub const HERO_H: u32 = {HERO_H};",
        f"pub const HERO_ANCHOR_X: u32 = {HERO_AX};", f"pub const HERO_ANCHOR_Y: u32 = {HERO_AY};",
        f"pub const HERO_FACING_STEP: u32 = {HERO_FACING_STEP};", f"pub const HERO_FRAMES: u32 = {HERO_FRAMES};",
        f"pub const HERO_RUN_FRAMES: u32 = {HERO_RUN_FRAMES};",
        f"pub const HERO_DEATH_START: u32 = {HERO_FACINGS * HERO_FRAMES};",
        f"pub const HERO_DEATH_FACING_STEP: u32 = {HERO_DEATH_FACING_STEP};", f"pub const HERO_DEATH_FRAMES: u32 = {HERO_DEATH_FRAMES};",
        f"pub const GUN_FRAMES: u32 = {GUN_FRAMES};", f"pub const MELEE_FRAMES: u32 = {MELEE_FRAMES};",
        f"pub const ENEMY_FACING_STEP: u32 = {ENEMY_FACING_STEP};", f"pub const ENEMY_FRAMES: u32 = {ENEMY_FRAMES};",
        f"pub const ENEMY_WALK_FRAMES: u32 = {ENEMY_WALK_FRAMES};",
        "/// Per EnemyKind: cell width, height and the feet's pixel in it",
        "pub const ENEMY_CELLS = [_][4]u32{ " + ", ".join(".{ %d, %d, %d, %d }" % c for c in ENEMY_CELLS.values()) + " };",
    ]
    return lines


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Render the hero and zombie sprite sheets")
    parser.add_argument("out_dir", nargs="?", default="images")
    parser.add_argument("--preview", help="also write a contact sheet png here")
    args = parser.parse_args()
    built = build()
    save(built, args.out_dir)
    if args.preview:
        preview(built, args.preview)
