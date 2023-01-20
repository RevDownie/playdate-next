const std = @import("std");
const pd = @import("playdate.zig").api;
const maths = @import("maths.zig");

const Vec2f = @Vector(2, f32);

pub const BitmapFrame = struct { index: i32, flip: pd.LCDBitmapFlip };

const BITMAP_INDEX_MAP = buildLookupTable();

/// Our sprites are captured at 10 degree snapshots
/// 0 is facing towards screen and 18 is facing away
/// We then mirror the images for rotation in the other direction
///
fn buildLookupTable() [36]BitmapFrame {
    var table: [36]BitmapFrame = undefined;

    var i: usize = 0;
    while (i <= 18) : (i += 1) {
        table[i] = BitmapFrame{ .index = @intCast(i32, i), .flip = pd.kBitmapUnflipped };
    }
    while (i < 36) : (i += 1) {
        table[i] = BitmapFrame{ .index = @intCast(i32, 36 - i), .flip = pd.kBitmapFlippedX };
    }
    return table;
}

/// Convert the given direction vector to a bitmap frame that best matches
///
pub fn bitmapFrameForDir(dir: Vec2f) BitmapFrame {
    const deg = maths.angleDegrees360(@Vector(2, f32){ 0, -1 }, dir);
    const index = @floatToInt(usize, deg * 0.1);
    return BITMAP_INDEX_MAP[index];
}

/// Given the world pos calculate a screen height offset do have the charater bob
///
pub fn walkBobAnim(world_pos: Vec2f) i32 {
    const freq: f32 = 24.0;
    const amp: f32 = 10.0;
    const t1 = world_pos[0];
    const x = (std.math.sin(t1 * freq) + 1.0) * 0.5;
    const t2 = world_pos[1];
    const y = (std.math.sin(t2 * freq) + 1.0) * 0.5;
    return @floatToInt(i32, (x * 0.5 + y * 0.5) * amp);
}
