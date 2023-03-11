const std = @import("std");
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

pub const CollisionGrid = struct {
    collision_grid: std.StaticBitSet(900), //DynamicBitSet seemed to be broken
    width: u8,
    height: u8,
    cell_width: u8,
    cell_height: u8,

    pub fn isOccupied(self: *const CollisionGrid, world_pos: Vec2f) bool {
        const screen = world_pos * @splat(2, consts.METRES_TO_PIXELS);
        const cellx = @floatToInt(i32, @round(screen[0] / @intToFloat(f32, self.cell_width)));
        const celly = @floatToInt(i32, @round(screen[1] / @intToFloat(f32, self.cell_height)));
        const xi: i32 = cellx + self.width / 2;
        const yi: i32 = -celly + self.height / 2;
        const x = @intCast(u32, xi);
        const y = @intCast(u32, yi);
        const idx = x + self.width * y;

        return self.collision_grid.isSet(idx);
    }
};
