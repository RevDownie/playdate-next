/// Holds the collision tile locations for the level
///
const std = @import("std");
const consts = @import("tweak_constants.zig");
const maths = @import("maths.zig");
const kit_descs = @import("kit_descs.zig");

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
        const idx = self.cellIndex(world_pos) orelse return true;
        return self.cells[idx];
    }

    /// Spacing that moving points and lines sample the grid at: half the smaller cell side, so no blocked
    /// cell can be stepped over
    ///
    pub fn sampleLength(self: *const CollisionGrid) f32 {
        return @as(f32, @floatFromInt(@min(self.cell_width, self.cell_height))) / consts.METRES_TO_PIXELS * 0.5;
    }

    /// True if no blocked cell lies on the line from `from` to `to`, sampled every `sampleLength` (the spacing
    /// bullets move at, so a bullet fired along a clear line isn't stopped by a wall). `from` itself isn't tested.
    /// Like a bullet, a line exactly through the corner where two blocked cells meet diagonally may slip through
    ///
    pub fn isSegmentClear(self: *const CollisionGrid, from: Vec2f, to: Vec2f) bool {
        const delta = to - from;
        const num_samples: u32 = @intFromFloat(@max(@ceil(maths.magnitude(delta) / self.sampleLength()), 1));
        const step = delta / @as(Vec2f, @splat(@floatFromInt(num_samples)));
        var p = from;
        for (0..num_samples) |_| {
            p += step;
            if (self.isOccupied(p)) return false;
        }
        return true;
    }

    /// Index of the cell containing `world_pos`, or null outside the grid. Cell centres sit on multiples
    /// of the cell size with the grid centred on the world origin
    ///
    pub fn cellIndex(self: *const CollisionGrid, world_pos: Vec2f) ?u16 {
        const screen = world_pos * @as(Vec2f, @splat(consts.METRES_TO_PIXELS));
        const cellx = @round(screen[0] / @as(f32, @floatFromInt(self.cell_width)));
        const celly = @round(screen[1] / @as(f32, @floatFromInt(self.cell_height)));
        const x = cellx + @as(f32, @floatFromInt(self.width / 2));
        const y = -celly + @as(f32, @floatFromInt(self.height / 2));
        //Range check in float space so huge or NaN positions can't overflow the int conversion
        if (!(x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(self.width)) and y < @as(f32, @floatFromInt(self.height)))) {
            return null;
        }
        return @intCast(@as(u32, @intFromFloat(x)) + @as(u32, self.width) * @as(u32, @intFromFloat(y)));
    }

    /// World position of the centre of cell `idx` (the inverse of `cellIndex`)
    ///
    pub fn cellCentre(self: *const CollisionGrid, idx: u16) Vec2f {
        const x = @as(i32, idx % self.width) - self.width / 2;
        const y = @as(i32, idx / self.width) - self.height / 2;
        const px = Vec2f{ @floatFromInt(x * @as(i32, self.cell_width)), @floatFromInt(-y * @as(i32, self.cell_height)) };
        return px / @as(Vec2f, @splat(consts.METRES_TO_PIXELS));
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

test "[collision_grid] cell index and centre round trip with non-square cells and odd width" {
    var cells: [5 * 4]bool = @splat(false);
    const grid = CollisionGrid{ .cells = &cells, .width = 5, .height = 4, .cell_width = kit_descs.CELL_W, .cell_height = kit_descs.CELL_H };
    const cell_m = Vec2f{ @floatFromInt(kit_descs.CELL_W), @floatFromInt(kit_descs.CELL_H) } / @as(Vec2f, @splat(consts.METRES_TO_PIXELS));

    for (0..cells.len) |i| {
        const idx: u16 = @intCast(i);
        try std.testing.expect(grid.cellIndex(grid.cellCentre(idx)).? == idx);
    }
    //Row 0 is the top of the map, so moving one cell up in the world is one row back
    const centre = grid.cellIndex(Vec2f{ 0, 0 }).?;
    try std.testing.expect(grid.cellIndex(Vec2f{ 0, cell_m[1] }).? == centre - 5);
    try std.testing.expect(grid.cellIndex(Vec2f{ cell_m[0], 0 }).? == centre + 1);
    try std.testing.expect(grid.cellIndex(Vec2f{ 100, 0 }) == null);
}

test "[collision_grid] line of sight is blocked by walls, with the levels' cell size" {
    //30x30 grid with a wall down the column two right of the centre (x = 0.67m to 1.11m with the levels' cells)
    var cells: [30 * 30]bool = @splat(false);
    for (0..30) |row| cells[row * 30 + 30 / 2 + 2] = true;
    const grid = CollisionGrid{ .cells = &cells, .width = 30, .height = 30, .cell_width = kit_descs.CELL_W, .cell_height = kit_descs.CELL_H };
    try std.testing.expect(grid.isOccupied(Vec2f{ 0.9, 0 }) and !grid.isOccupied(Vec2f{ 0.6, 0 }) and !grid.isOccupied(Vec2f{ 1.3, 0 }));

    try std.testing.expect(!grid.isSegmentClear(Vec2f{ 0, 0 }, Vec2f{ 1.3, 0 })); //Through the wall
    try std.testing.expect(!grid.isSegmentClear(Vec2f{ 0, 0 }, Vec2f{ 1.3, 0.9 })); //Diagonally through it
    try std.testing.expect(grid.isSegmentClear(Vec2f{ 0, 0 }, Vec2f{ 0.6, 0.9 })); //Short of it
    try std.testing.expect(grid.isSegmentClear(Vec2f{ -1, -0.5 }, Vec2f{ -1.5, 0.5 }));
    try std.testing.expect(grid.isSegmentClear(Vec2f{ 0.2, 0.1 }, Vec2f{ 0.2, 0.1 })); //Zero length
    try std.testing.expect(!grid.isSegmentClear(Vec2f{ 0, 0 }, Vec2f{ -20, 0 })); //Off the map
}
