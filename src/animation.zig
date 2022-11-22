const pd = @import("playdate.zig").api;
const maths = @import("maths.zig");

pub const BitmapFrame = struct { index: i32, flip: pd.LCDBitmapFlip };

//Our sprites are captured at 22.5 degree snapshots
//0 is facing towards screen and 8 is facing away, 4 is facing to the left
const BITMAP_INDEX_MAP = [_]BitmapFrame{
    BitmapFrame{ .index = 0, .flip = pd.kBitmapUnflipped }, //0
    BitmapFrame{ .index = 0, .flip = pd.kBitmapUnflipped }, //10
    BitmapFrame{ .index = 1, .flip = pd.kBitmapUnflipped }, //20
    BitmapFrame{ .index = 1, .flip = pd.kBitmapUnflipped }, //30
    BitmapFrame{ .index = 2, .flip = pd.kBitmapUnflipped }, //40
    BitmapFrame{ .index = 2, .flip = pd.kBitmapUnflipped }, //50
    BitmapFrame{ .index = 3, .flip = pd.kBitmapUnflipped }, //60
    BitmapFrame{ .index = 3, .flip = pd.kBitmapUnflipped }, //70
    BitmapFrame{ .index = 4, .flip = pd.kBitmapUnflipped }, //80
    BitmapFrame{ .index = 4, .flip = pd.kBitmapUnflipped }, //90
    BitmapFrame{ .index = 4, .flip = pd.kBitmapUnflipped }, //100
    BitmapFrame{ .index = 5, .flip = pd.kBitmapUnflipped }, //110
    BitmapFrame{ .index = 5, .flip = pd.kBitmapUnflipped }, //120
    BitmapFrame{ .index = 6, .flip = pd.kBitmapUnflipped }, //130
    BitmapFrame{ .index = 6, .flip = pd.kBitmapUnflipped }, //140
    BitmapFrame{ .index = 7, .flip = pd.kBitmapUnflipped }, //150
    BitmapFrame{ .index = 7, .flip = pd.kBitmapUnflipped }, //160
    BitmapFrame{ .index = 8, .flip = pd.kBitmapUnflipped }, //170
    BitmapFrame{ .index = 8, .flip = pd.kBitmapUnflipped }, //180
    BitmapFrame{ .index = 8, .flip = pd.kBitmapUnflipped }, //190
    BitmapFrame{ .index = 7, .flip = pd.kBitmapUnflipped }, //200
    BitmapFrame{ .index = 7, .flip = pd.kBitmapUnflipped }, //210
    BitmapFrame{ .index = 6, .flip = pd.kBitmapFlippedX }, //220
    BitmapFrame{ .index = 6, .flip = pd.kBitmapFlippedX }, //230
    BitmapFrame{ .index = 5, .flip = pd.kBitmapFlippedX }, //240
    BitmapFrame{ .index = 5, .flip = pd.kBitmapFlippedX }, //250
    BitmapFrame{ .index = 4, .flip = pd.kBitmapFlippedX }, //260
    BitmapFrame{ .index = 4, .flip = pd.kBitmapFlippedX }, //270
    BitmapFrame{ .index = 4, .flip = pd.kBitmapFlippedX }, //280
    BitmapFrame{ .index = 3, .flip = pd.kBitmapFlippedX }, //290
    BitmapFrame{ .index = 3, .flip = pd.kBitmapFlippedX }, //300
    BitmapFrame{ .index = 2, .flip = pd.kBitmapFlippedX }, //310
    BitmapFrame{ .index = 2, .flip = pd.kBitmapFlippedX }, //320
    BitmapFrame{ .index = 1, .flip = pd.kBitmapFlippedX }, //330
    BitmapFrame{ .index = 1, .flip = pd.kBitmapFlippedX }, //340
    BitmapFrame{ .index = 0, .flip = pd.kBitmapUnflipped }, //350
    BitmapFrame{ .index = 0, .flip = pd.kBitmapUnflipped }, //360
};

/// Convert the given direction vector to a bitmap frame that best matches
///
pub fn bitmapFrameForDir(dir: @Vector(2, f32)) BitmapFrame {
    const deg = maths.angleDegrees360(@Vector(2, f32){ 0, -1 }, dir);
    const index = @floatToInt(usize, deg * 0.1);
    return BITMAP_INDEX_MAP[index];
}
