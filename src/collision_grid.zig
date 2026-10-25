const std = @import("std");
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

/// Static environment collision, one flag per level grid cell (row major, row 0 is the top of the map).
/// Anything outside the grid counts as occupied, which also keeps the player inside the level.
///
pub const CollisionGrid = struct {
    cells: []const bool,
    width: u8,
    height: u8,
    cell_width: u8,
    cell_height: u8,

    pub fn isOccupied(self: *const CollisionGrid, world_pos: Vec2f) bool {
        const screen = world_pos * @as(Vec2f, @splat(consts.METRES_TO_PIXELS));
        const cellx = @round(screen[0] / @as(f32, @floatFromInt(self.cell_width)));
        const celly = @round(screen[1] / @as(f32, @floatFromInt(self.cell_height)));
        const x = cellx + @as(f32, @floatFromInt(self.width / 2));
        const y = -celly + @as(f32, @floatFromInt(self.height / 2));
        //Range check in float space so huge or NaN positions can't overflow the int conversion
        if (!(x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(self.width)) and y < @as(f32, @floatFromInt(self.height)))) {
            return true;
        }

        const idx = @as(usize, @intFromFloat(x)) + @as(usize, self.width) * @as(usize, @intFromFloat(y));
        return self.cells[idx];
    }
};

test "[collision_grid] occupied cells and out of bounds" {
    //3x3 grid with only the centre cell blocked; cells are 1m (128px) square
    const cells = [_]bool{ false, false, false, false, true, false, false, false, false };
    const grid = CollisionGrid{ .cells = &cells, .width = 3, .height = 3, .cell_width = 128, .cell_height = 128 };

    try std.testing.expect(grid.isOccupied(Vec2f{ 0, 0 }));
    try std.testing.expect(!grid.isOccupied(Vec2f{ 1, 1 }));
    try std.testing.expect(!grid.isOccupied(Vec2f{ -1, -1 }));
    try std.testing.expect(grid.isOccupied(Vec2f{ 2, 0 }));
    try std.testing.expect(grid.isOccupied(Vec2f{ -2, 0 }));
    try std.testing.expect(grid.isOccupied(Vec2f{ 0, 1000000 }));
    try std.testing.expect(grid.isOccupied(Vec2f{ std.math.nan(f32), 0 }));
}
