const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

/// Two bytes so the lookup table and the per frame draw lists stay small
pub const BitmapFrame = struct { index: u8, flipped: bool };

const BITMAP_INDEX_MAP = buildLookupTable();

/// Our sprites are captured at 10 degree snapshots
/// 0 is facing towards screen and 18 is facing away
/// We then mirror the images for rotation in the other direction
///
fn buildLookupTable() [36]BitmapFrame {
    var table: [36]BitmapFrame = undefined;

    var i: usize = 0;
    while (i <= 18) : (i += 1) {
        table[i] = BitmapFrame{ .index = @intCast(i), .flipped = false };
    }
    while (i < 36) : (i += 1) {
        table[i] = BitmapFrame{ .index = @intCast(36 - i), .flipped = true };
    }
    return table;
}

/// Convert the given direction vector to a bitmap frame that best matches
///
pub fn bitmapFrameForDir(dir: Vec2f) BitmapFrame {
    const deg = maths.angleDegrees360(@Vector(2, f32){ 0, -1 }, dir);
    const index: usize = @intFromFloat(std.math.clamp(deg * 0.1, 0, @as(f32, BITMAP_INDEX_MAP.len - 1)));
    return BITMAP_INDEX_MAP[index];
}

/// Given the world pos calculate a screen height offset to have the charater bob
///
pub fn walkBobAnim(world_pos: Vec2f) i32 {
    const freq: f32 = 24.0;
    const amp: f32 = 8.0;
    const t1 = world_pos[0];
    const x = (std.math.sin(t1 * freq) + 1.0) * 0.5;
    const t2 = world_pos[1];
    const y = (std.math.sin(t2 * freq) + 1.0) * 0.5;
    return @intFromFloat((x * 0.5 + y * 0.5) * amp);
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

test "[animation] bitmapFrameForDir covers every direction" {
    try std.testing.expect(bitmapFrameForDir(Vec2f{ 0, -1 }).index == 0); //Facing the screen
    try std.testing.expect(bitmapFrameForDir(Vec2f{ 0, 1 }).index == 18); //Facing away
    const left = bitmapFrameForDir(Vec2f{ -1, 0 });
    const right = bitmapFrameForDir(Vec2f{ 1, 0 });
    try std.testing.expect(left.index == right.index and left.flipped != right.flipped);
    _ = bitmapFrameForDir(Vec2f{ 0, 0 });
    _ = bitmapFrameForDir(Vec2f{ std.math.nan(f32), 0 });
}

test "[animation] bullet tracers start at the muzzle and converge on the bullet" {
    const fired = bulletTracer(@splat(0), Vec2f{ 1, 0 }, 0, 0);
    try std.testing.expectApproxEqAbs(fired.head[0], consts.MUZZLE_FORWARD, 0.0001);
    try std.testing.expect(fired.head[1] < 0); //Held on the right when aiming along +x
    try std.testing.expect(fired.tail[0] > 0); //Doesn't poke back through the player

    const far = bulletTracer(Vec2f{ 3, 0 }, Vec2f{ 1, 0 }, consts.MUZZLE_CONVERGE_DIST, 3);
    try std.testing.expect(far.head[0] == 3 and far.head[1] == 0);
    try std.testing.expectApproxEqAbs(far.head[0] - far.tail[0], consts.TRACER_LENGTH, 0.0001);
}
