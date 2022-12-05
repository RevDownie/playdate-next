const pd = @import("playdate.zig").api;
const maths = @import("maths.zig");

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
pub fn bitmapFrameForDir(dir: @Vector(2, f32)) BitmapFrame {
    const deg = maths.angleDegrees360(@Vector(2, f32){ 0, -1 }, dir);
    const index = @floatToInt(usize, deg * 0.1);
    return BITMAP_INDEX_MAP[index];
}
