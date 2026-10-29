const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const bitmap_descs = @import("bitmap_descs.zig");

const Vec2f = @Vector(2, f32);

/// Two bytes so the per frame draw lists stay small
pub const BitmapFrame = struct { index: u8, flipped: bool };

// Character sheets (see character_sprites.py) are drawn every `step` degrees from 0 (facing the screen, world -y)
// round to 180 (facing away) through screen left; the other half is the same frames mirrored. Each sheet's index is
// facing * frames per facing + frame

/// The drawn facing nearest to `dir` for a sheet drawn every `step` degrees: its index, and whether to mirror it
///
pub fn facing(dir: Vec2f, comptime step: u32) BitmapFrame {
    const directions = 360 / step;
    const deg = maths.angleDegrees360(@Vector(2, f32){ 0, -1 }, dir);
    const nearest: u32 = if (deg >= 0 and deg < 360) @intFromFloat(@round(deg / @as(f32, step))) else 0; //NaN for a zero dir
    const i = nearest % directions;
    return if (i <= directions / 2) .{ .index = @intCast(i), .flipped = false } else .{ .index = @intCast(directions - i), .flipped = true };
}

/// The player's body: aiming along `aim_dir`; the run cycle while moving (stepped by the distance run, so the feet
/// keep pace), the hurt pose while the hit flash shows
///
pub fn heroFrame(aim_dir: Vec2f, moving: bool, run_dist: f32, hurt: bool) BitmapFrame {
    const f = facing(aim_dir, bitmap_descs.HERO_FACING_STEP);
    const frame: u32 = if (hurt) bitmap_descs.HERO_FRAMES - 1 else if (moving) 1 + cycleFrame(run_dist, consts.HERO_RUN_CYCLE_DIST, bitmap_descs.HERO_RUN_FRAMES) else 0;
    return .{ .index = @intCast(f.index * bitmap_descs.HERO_FRAMES + frame), .flipped = f.flipped };
}

/// The arms and weapon drawn over the body: the gatling (its hurt pose with the body's), or out of ammo the melee
/// weapon, ready or `swing_progress` (0..1) through a blow
///
pub fn heroWeaponFrame(aim_dir: Vec2f, melee: bool, swinging: bool, swing_progress: f32, hurt: bool) BitmapFrame {
    const f = facing(aim_dir, bitmap_descs.HERO_FACING_STEP);
    if (!melee) return .{ .index = @intCast(f.index * bitmap_descs.GUN_FRAMES + @intFromBool(hurt)), .flipped = f.flipped };
    const frame: u32 = if (!swinging) 0 else if (swing_progress < 0.5) 1 else 2;
    return .{ .index = @intCast(f.index * bitmap_descs.MELEE_FRAMES + frame), .flipped = f.flipped };
}

/// The player falling down `time` seconds after dying, then lying still (drawn on the run end screen)
///
pub fn heroDeathFrame(aim_dir: Vec2f, time: f32) BitmapFrame {
    const f = facing(aim_dir, bitmap_descs.HERO_DEATH_FACING_STEP);
    const frame = stepFrame(time, consts.HERO_DEATH_FRAME_TIME, bitmap_descs.HERO_DEATH_FRAMES);
    return .{ .index = @intCast(bitmap_descs.HERO_DEATH_START + f.index * bitmap_descs.HERO_DEATH_FRAMES + frame), .flipped = f.flipped };
}

/// An enemy heading along `vel`: rocked back while it is knocked back, otherwise walking. The walk steps with the
/// distance along its heading, so the feet keep pace with its speed and a crowd doesn't step in unison
///
pub fn enemyFrame(pos: Vec2f, vel: Vec2f, bumping: bool) BitmapFrame {
    const f = facing(vel, bitmap_descs.ENEMY_FACING_STEP);
    const dir = maths.normaliseSafe(vel, Vec2f{ 0, -1 });
    const frame: u32 = if (bumping) bitmap_descs.ENEMY_WALK_FRAMES else cycleFrame(maths.dot(pos, dir), consts.ENEMY_WALK_CYCLE_DIST, bitmap_descs.ENEMY_WALK_FRAMES);
    return .{ .index = @intCast(f.index * bitmap_descs.ENEMY_FRAMES + frame), .flipped = f.flipped };
}

/// A gib's frame in its kind's gib sheet: its part, turned to spin frame `rot` (0..GIB_SPIN_FRAMES), `age` seconds
/// old: solid, then thinning through the fade frames over the last GIB_FADE_TIME
///
pub fn gibFrame(part: u8, rot: f32, age: f32) u8 {
    const spin: u32 = @min(@as(u32, @intFromFloat(@max(rot, 0))), bitmap_descs.GIB_SPIN_FRAMES - 1);
    const fade_start = consts.GIB_TIME - consts.GIB_FADE_TIME;
    const fade: u32 = if (age < fade_start) 0 else 1 + stepFrame(age - fade_start, consts.GIB_FADE_TIME / (bitmap_descs.GIB_FADES - 1), bitmap_descs.GIB_FADES - 1);
    return @intCast((fade * bitmap_descs.GIB_PARTS + part) * bitmap_descs.GIB_SPIN_FRAMES + spin);
}

/// A pool or spatter `age` seconds old: solid, then thinning through the fade frames over the last SPLAT_FADE_TIME.
/// Its frame is `variant * SPLAT_FADES + splatFade(age)`
///
pub fn splatFade(age: f32) u8 {
    const fade_start = consts.SPLAT_TIME - consts.SPLAT_FADE_TIME;
    if (age < fade_start) return 0;
    return @intCast(1 + stepFrame(age - fade_start, consts.SPLAT_FADE_TIME / (bitmap_descs.SPLAT_FADES - 1), bitmap_descs.SPLAT_FADES - 1));
}

/// Which of `frames` a loop is on, `dist` along it at `cycle` per loop. Floors into an integer and wraps with an
/// integer @mod: `dist` can be negative, and a float @mod would call libc's fmodf, which drags newlib's malloc into
/// the device link
///
fn cycleFrame(dist: f32, cycle: f32, comptime frames: u32) u32 {
    const step = std.math.clamp(@floor(dist * (@as(f32, frames) / cycle)), -1e9, 1e9);
    return @intCast(@mod(@as(i32, @intFromFloat(step)), frames));
}

/// A one-shot animation `time` seconds in at `frame_time` each, holding its last frame
///
fn stepFrame(time: f32, frame_time: f32, comptime frames: u32) u32 {
    return @min(@as(u32, @intFromFloat(std.math.clamp(time / frame_time, 0, @as(f32, frames)))), frames - 1);
}

/// Sideways offset of each gatling barrel from the player (metres to the right of the aim), as the barrels
/// turn around the gun's axis
const BARREL_SIDE_OFFSETS = blk: {
    var offsets: [consts.GUN_BARRELS]f32 = undefined;
    for (&offsets, 0..) |*o, i| {
        const angle = maths.PI_2 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(consts.GUN_BARRELS));
        o.* = consts.MUZZLE_SIDE + consts.BARREL_RADIUS * @cos(angle);
    }
    break :blk offsets;
};

/// Pixels a drop is lifted off the ground `age` seconds after it appeared: a gentle repeating hop
///
pub fn dropBounce(age: f32) i32 {
    const phase = age * (std.math.pi / consts.DROP_BOUNCE_PERIOD);
    return @intFromFloat(@round(@abs(std.math.sin(phase)) * consts.DROP_BOUNCE_PX));
}

/// Which frame of its glint a drop shows `age` seconds after it appeared: 0 (no glint) most of the time, then
/// 1..DROP_FRAMES_PER_KIND-1 as the light sweeps across. `point` staggers drops on different points. Integer
/// maths: a float @mod would call libc's fmodf, which drags newlib's malloc into the device link
///
pub fn dropSheenFrame(age: f32, point: u8) u8 {
    const sheen_frames = bitmap_descs.DROP_FRAMES_PER_KIND - 1;
    const ms: u32 = @intFromFloat(@max(age, 0) * 1000);
    const t = (ms + @as(u32, point) * consts.DROP_SHEEN_POINT_OFFSET_MS) % consts.DROP_SHEEN_PERIOD_MS;
    const frame = t / consts.DROP_SHEEN_FRAME_MS;
    return if (frame < sheen_frames) @intCast(frame + 1) else 0;
}

pub const Tracer = struct { head: Vec2f, tail: Vec2f };

/// Where to draw a bullet's tracer streak (world metres, on the ground; the renderer lifts it to gun height).
/// Bullets are simulated from the player's feet, so the drawn bullet starts at the muzzle of the barrel it
/// left from and the offset fades out over MUZZLE_CONVERGE_DIST so it meets the line the bullet really
/// travels. The tail never reaches back past the muzzle
///
pub fn bulletTracer(pos: Vec2f, dir: Vec2f, travelled: f32, barrel: u8) Tracer {
    const right = Vec2f{ dir[1], -dir[0] };
    const fade = @max(1 - travelled / consts.MUZZLE_CONVERGE_DIST, 0);
    const muzzle = dir * @as(Vec2f, @splat(consts.MUZZLE_FORWARD)) + right * @as(Vec2f, @splat(BARREL_SIDE_OFFSETS[barrel % consts.GUN_BARRELS]));
    const head = pos + muzzle * @as(Vec2f, @splat(fade));
    const length = std.math.clamp(travelled, 0.02, consts.TRACER_LENGTH);
    return .{ .head = head, .tail = head - dir * @as(Vec2f, @splat(length)) };
}

test "[animation] facings cover every direction, drawn facing screen left and mirrored for the right" {
    try std.testing.expect(std.meta.eql(facing(Vec2f{ 0, -1 }, 10), .{ .index = 0, .flipped = false })); //Facing the screen
    try std.testing.expect(facing(Vec2f{ 0, 1 }, 10).index == 18); //Facing away
    try std.testing.expect(std.meta.eql(facing(Vec2f{ -1, 0 }, 10), .{ .index = 9, .flipped = false })); //Drawn: screen left (world -x)
    try std.testing.expect(std.meta.eql(facing(Vec2f{ 1, 0 }, 10), .{ .index = 9, .flipped = true }));
    try std.testing.expect(std.meta.eql(facing(Vec2f{ -1, 0 }, 18), .{ .index = 5, .flipped = false })); //Enemies: every 18 degrees
    try std.testing.expect(facing(Vec2f{ 0, 1 }, 18).index == 10);
    try std.testing.expect(facing(Vec2f{ 0.05, -1 }, 18).index == 0); //Just off straight down rounds to it, either side
    try std.testing.expect(facing(Vec2f{ -0.05, -1 }, 18).index == 0);
    for (0..360) |d| {
        const a = std.math.degreesToRadians(@as(f32, @floatFromInt(d)));
        try std.testing.expect(facing(Vec2f{ @sin(a), @cos(a) }, 10).index <= 18);
        try std.testing.expect(facing(Vec2f{ @sin(a), @cos(a) }, 18).index <= 10);
    }
    _ = facing(Vec2f{ 0, 0 }, 10);
    _ = facing(Vec2f{ std.math.nan(f32), 0 }, 10);
}

test "[animation] character frames stay inside their sheets" {
    const hero_frames = bitmap_descs.HERO_DEATH_START + (180 / bitmap_descs.HERO_DEATH_FACING_STEP + 1) * bitmap_descs.HERO_DEATH_FRAMES;
    const enemy_frames = (180 / bitmap_descs.ENEMY_FACING_STEP + 1) * bitmap_descs.ENEMY_FRAMES;
    for (0..72) |d| {
        const a = std.math.degreesToRadians(@as(f32, @floatFromInt(d * 5)));
        const dir = Vec2f{ @sin(a), @cos(a) };
        for ([_]f32{ -3.7, 0, 0.13, 55.5 }) |dist| {
            try std.testing.expect(heroFrame(dir, true, @abs(dist), false).index < bitmap_descs.HERO_DEATH_START);
            try std.testing.expect(enemyFrame(dir * @as(Vec2f, @splat(dist)), dir, false).index < enemy_frames);
        }
        try std.testing.expect(heroFrame(dir, false, 0, true).index < bitmap_descs.HERO_DEATH_START);
        try std.testing.expect(heroWeaponFrame(dir, false, false, 0, true).index < (180 / bitmap_descs.HERO_FACING_STEP + 1) * bitmap_descs.GUN_FRAMES);
        try std.testing.expect(heroWeaponFrame(dir, true, true, 0.9, false).index < (180 / bitmap_descs.HERO_FACING_STEP + 1) * bitmap_descs.MELEE_FRAMES);
        for ([_]f32{ 0, 0.1, 99 }) |t| {
            const death = heroDeathFrame(dir, t).index;
            try std.testing.expect(death >= bitmap_descs.HERO_DEATH_START and death < hero_frames);
        }
    }
    try std.testing.expect(hero_frames <= 256 and enemy_frames <= 256); //u8 frame indices
}

test "[animation] walk and run cycles step with distance and wrap, death holds its last frame" {
    const step = consts.ENEMY_WALK_CYCLE_DIST / bitmap_descs.ENEMY_WALK_FRAMES;
    const down = Vec2f{ 0, -1 };
    var seen: [bitmap_descs.ENEMY_WALK_FRAMES]bool = @splat(false);
    for (0..bitmap_descs.ENEMY_WALK_FRAMES * 2) |i| {
        const at = Vec2f{ 0, -(@as(f32, @floatFromInt(i)) + 0.5) * step };
        seen[enemyFrame(at, down, false).index] = true;
    }
    for (seen) |s| try std.testing.expect(s);
    try std.testing.expect(enemyFrame(@splat(0), down, true).index == bitmap_descs.ENEMY_WALK_FRAMES); //Knocked back
    try std.testing.expect(heroFrame(down, false, 1.3, false).index == 0); //Standing still
    try std.testing.expect(heroDeathFrame(down, 10).index == bitmap_descs.HERO_DEATH_START + bitmap_descs.HERO_DEATH_FRAMES - 1);
}

test "[animation] gib frames stay in their part's spin frames, gibs and splats fade through every fade frame" {
    const per_fade = bitmap_descs.GIB_PARTS * bitmap_descs.GIB_SPIN_FRAMES;
    for (0..bitmap_descs.GIB_PARTS) |part| {
        for ([_]f32{ -0.1, 0, 3.5, 7.99, 8 }) |rot| {
            const f = gibFrame(@intCast(part), rot, 0);
            try std.testing.expect(f >= part * bitmap_descs.GIB_SPIN_FRAMES and f < (part + 1) * bitmap_descs.GIB_SPIN_FRAMES);
            const last = gibFrame(@intCast(part), rot, consts.GIB_TIME - 0.01);
            try std.testing.expect(last - f == (bitmap_descs.GIB_FADES - 1) * per_fade);
        }
    }
    try std.testing.expect(gibFrame(0, 0, consts.GIB_TIME - consts.GIB_FADE_TIME - 0.01) == 0);
    try std.testing.expect(gibFrame(0, 0, consts.GIB_TIME - consts.GIB_FADE_TIME + 0.01) == per_fade);
    try std.testing.expect(gibFrame(0, 0, 99) < bitmap_descs.GIB_FADES * per_fade);
    try std.testing.expect(splatFade(0) == 0);
    try std.testing.expect(splatFade(consts.SPLAT_TIME - consts.SPLAT_FADE_TIME + 0.01) == 1);
    try std.testing.expect(splatFade(consts.SPLAT_TIME - 0.01) == bitmap_descs.SPLAT_FADES - 1);
    try std.testing.expect(splatFade(99) == bitmap_descs.SPLAT_FADES - 1);
}

test "[animation] bullet tracers start at the muzzle and converge on the bullet" {
    const fired = bulletTracer(@splat(0), Vec2f{ 1, 0 }, 0, 0);
    try std.testing.expectApproxEqAbs(fired.head[0], consts.MUZZLE_FORWARD, 0.0001);
    try std.testing.expect(@abs(fired.head[1]) <= consts.BARREL_RADIUS + 0.0001); //Held in the middle, so mirroring needs no side swap
    try std.testing.expect(fired.tail[0] > 0); //Doesn't poke back through the player

    const far = bulletTracer(Vec2f{ 3, 0 }, Vec2f{ 1, 0 }, consts.MUZZLE_CONVERGE_DIST, 3);
    try std.testing.expect(far.head[0] == 3 and far.head[1] == 0);
    try std.testing.expectApproxEqAbs(far.head[0] - far.tail[0], consts.TRACER_LENGTH, 0.0001);
}

test "[animation] drops hop off the ground and back" {
    const top: i32 = @intFromFloat(consts.DROP_BOUNCE_PX);
    try std.testing.expect(dropBounce(0) == 0);
    try std.testing.expect(dropBounce(consts.DROP_BOUNCE_PERIOD / 2) == top);
    try std.testing.expect(dropBounce(consts.DROP_BOUNCE_PERIOD) == 0);
    for (0..100) |i| {
        const b = dropBounce(@as(f32, @floatFromInt(i)) * 0.037);
        try std.testing.expect(b >= 0 and b <= top);
    }
}

test "[animation] a drop's glint sweeps through every frame once a period, staggered by point" {
    var seen: [bitmap_descs.DROP_FRAMES_PER_KIND]u32 = @splat(0);
    var ms: u32 = 0;
    while (ms < consts.DROP_SHEEN_PERIOD_MS) : (ms += 1) seen[dropSheenFrame(@as(f32, @floatFromInt(ms)) / 1000, 0)] += 1;
    for (seen[1..]) |n| try std.testing.expect(n > 0 and n <= consts.DROP_SHEEN_FRAME_MS + 1);
    try std.testing.expect(seen[0] > consts.DROP_SHEEN_PERIOD_MS / 2); //Mostly still
    try std.testing.expect(dropSheenFrame(0, 0) == 1 and dropSheenFrame(0, 1) == 0);
}
