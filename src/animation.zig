const std = @import("std");
const maths = @import("maths.zig");

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
    //Clamp in float space - rounding can land exactly on 360, and @min/@max drop a NaN so the cast is always safe
    const index: usize = @intFromFloat(std.math.clamp(deg * 0.1, 0, @as(f32, BITMAP_INDEX_MAP.len - 1)));
    return BITMAP_INDEX_MAP[index];
}

/// Given the world pos calculate a screen height offset do have the charater bob
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

test "[animation] bitmapFrameForDir covers every direction" {
    try std.testing.expect(bitmapFrameForDir(Vec2f{ 0, -1 }).index == 0); //Facing the screen
    try std.testing.expect(bitmapFrameForDir(Vec2f{ 0, 1 }).index == 18); //Facing away
    const left = bitmapFrameForDir(Vec2f{ -1, 0 });
    const right = bitmapFrameForDir(Vec2f{ 1, 0 });
    try std.testing.expect(left.index == right.index and left.flipped != right.flipped);
    _ = bitmapFrameForDir(Vec2f{ 0, 0 });
    _ = bitmapFrameForDir(Vec2f{ std.math.nan(f32), 0 });
}
