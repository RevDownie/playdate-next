const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const Enemies = @import("game_state.zig").Enemies;
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const flow = @import("flow_field.zig");
const FlowField = flow.FlowField;

const Vec2f = @Vector(2, f32);

/// Animate:
/// * Entities moving towards the player target, following the flow field around obstacles
/// * Entities bumping back in response to a collision
///
/// Walls are read from the flow field (one byte per cell) rather than the collision grid so the only
/// per-cell data this loop touches at random is `field.dir`; the grid only supplies the cell maths
///
pub fn update(enemies: *Enemies, field: *const FlowField, grid: *const CollisionGrid, player_world_pos: Vec2f, dt: f32) void {
    for (0..enemies.len) |i| {
        if (enemies.isBumping(i)) {
            updateBumpBack(enemies, i, field, grid, dt);
        } else {
            updateSeeking(enemies, i, field, grid, player_world_pos, dt);
        }
    }
}

/// Enemies seek out the player and move towards them to attack. They take the flow field's step for their
/// cell, and head straight for the player once in the player's cell or one step from it (or with no path).
/// A cell and the neighbour the field steps to are both free and together form a rectangle, so the straight
/// line can't clip scenery. The heading is eased towards the new one so the turns between cells don't snap
///
fn updateSeeking(enemies: *Enemies, i: usize, field: *const FlowField, grid: *const CollisionGrid, player_world_pos: Vec2f, dt: f32) void {
    const pos = enemies.pos[i];
    const cell = grid.cellIndex(pos);
    const dir = field.at(cell);
    const to_target = player_world_pos - pos;
    const mag = maths.magnitude(to_target);

    const follow_field = dir < flow.DIR_GOAL and field.dir[field.nextCell(cell.?, dir)] != flow.DIR_GOAL;
    const desired = if (follow_field)
        field.dir_vecs[dir] * @as(Vec2f, @splat(consts.ENEMY_MAX_SPEED))
    else
        maths.normaliseSafeMag(to_target, mag, enemies.vel[i]) * @as(Vec2f, @splat(@min(consts.ENEMY_MAX_SPEED, mag)));

    const vel = enemies.vel[i] + (desired - enemies.vel[i]) * @as(Vec2f, @splat(@min(consts.ENEMY_TURN_RATE * dt, 1.0)));
    enemies.vel[i] = vel;
    enemies.pos[i] = slide(field, grid, pos, pos + vel * @as(Vec2f, @splat(dt)), dir == flow.DIR_BLOCKED);
}

/// Animated push back. Seeking resumes once the timer reaches BUMP_TIME. Each frame moves by this frame's
/// share of the eased offset and slides along walls, so a knock back can't push an enemy into (or, held
/// against a wall, jump over) the scenery
///
fn updateBumpBack(enemies: *Enemies, i: usize, field: *const FlowField, grid: *const CollisionGrid, dt: f32) void {
    const prev_y = easeOutBack(enemies.bump_timer[i] / consts.BUMP_TIME);
    enemies.bump_timer[i] = @min(enemies.bump_timer[i] + dt, consts.BUMP_TIME);
    const y = easeOutBack(enemies.bump_timer[i] / consts.BUMP_TIME);
    const pos = enemies.pos[i];
    const step = enemies.bump_offset[i] * @as(Vec2f, @splat(y - prev_y));
    enemies.pos[i] = slide(field, grid, pos, pos + step, isBlocked(field, grid, pos));
}

/// Move from `pos` to `new_pos`, dropping whichever axis would enter a blocked cell (X then Y, like the
/// player) so enemies slide along walls. One that is already inside a blocked cell moves freely to get out.
/// Only the destination is tested, so a step must stay shorter than a cell (seeking moves at most
/// ENEMY_MAX_SPEED * MAX_FRAME_DT = 0.12m, and a bump's biggest frame about half of BUMP_DISTANCE)
///
fn slide(field: *const FlowField, grid: *const CollisionGrid, pos: Vec2f, new_pos: Vec2f, start_blocked: bool) Vec2f {
    if (start_blocked) return new_pos;
    var p = new_pos;
    if (isBlocked(field, grid, Vec2f{ p[0], pos[1] })) p[0] = pos[0];
    if (isBlocked(field, grid, p)) p[1] = pos[1];
    return p;
}

inline fn isBlocked(field: *const FlowField, grid: *const CollisionGrid, world_pos: Vec2f) bool {
    return field.at(grid.cellIndex(world_pos)) == flow.DIR_BLOCKED;
}

/// Easing function to animate the bump back
///
fn easeOutBack(x: f32) f32 {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    const xminus = x - 1;
    return 1 + c3 * (xminus * xminus * xminus) + c1 * (xminus * xminus);
}

const TestLevel = struct {
    cells: [20 * 20]bool,
    buffer: [8 * 1024]u8,
    arena: @import("memory.zig").Arena,
    grid: CollisionGrid,
    field: FlowField,

    /// 20x20 grid of 64px (0.5m) cells, optionally with a wall in column `wall_col` from row 4 to 15
    ///
    fn init(self: *TestLevel, wall_col: ?u8, goal: Vec2f) void {
        @memset(&self.cells, false);
        if (wall_col) |c| {
            for (4..16) |row| self.cells[row * 20 + c] = true;
        }
        self.grid = .{ .cells = &self.cells, .width = 20, .height = 20, .cell_width = 64, .cell_height = 64 };
        self.arena = .init("level", &self.buffer);
        self.field = FlowField.init(&self.arena, &self.grid, self.grid.cellIndex(goal));
    }
};

test "[enemy_movement_system] bump back lands at the full offset then seeks again" {
    var lvl: TestLevel = undefined;
    lvl.init(null, Vec2f{ 4, 0 });
    var e = Enemies{};
    e.add(Vec2f{ 0, 0 });
    e.startBumpBack(0, Vec2f{ 1, 0 }, 0.5);
    try std.testing.expect(e.isBumping(0));

    update(&e, &lvl.field, &lvl.grid, Vec2f{ 4, 0 }, consts.BUMP_TIME);
    try std.testing.expect(!e.isBumping(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.pos[0][0], 0.001);

    //Next frame it moves towards the player again
    update(&e, &lvl.field, &lvl.grid, Vec2f{ 4, 0 }, 0.1);
    try std.testing.expect(e.pos[0][0] > 0.5);
}

test "[enemy_movement_system] enemies path around a wall instead of walking into it" {
    //Wall at column 12 (x = 1m) between the enemy at x = 2.5 and the player at x = -2
    const player = Vec2f{ -2, 0 };
    var lvl: TestLevel = undefined;
    lvl.init(12, player);
    var e = Enemies{};
    e.add(Vec2f{ 2.5, 0 });

    var frames: u32 = 0;
    while (maths.magnitude(e.pos[0] - player) > 0.1 and frames < 30 * 20) : (frames += 1) {
        update(&e, &lvl.field, &lvl.grid, player, 1.0 / 30.0);
        try std.testing.expect(!lvl.grid.isOccupied(e.pos[0]));
    }
    try std.testing.expect(maths.magnitude(e.pos[0] - player) <= 0.1);
}

test "[enemy_movement_system] an enemy close to the player goes round a single obstacle between them" {
    //lvl1-sized cells (57x27px, 0.21m tall): the player is directly below a blocked cell and the enemy two
    //rows above it, so the straight line to the player (0.42m) runs into the obstacle
    var cells: [9 * 9]bool = @splat(false);
    cells[4 * 9 + 4] = true;
    const grid = CollisionGrid{ .cells = &cells, .width = 9, .height = 9, .cell_width = 57, .cell_height = 27 };
    var buffer: [2048]u8 = undefined;
    var arena = @import("memory.zig").Arena.init("level", &buffer);
    const player = grid.cellCentre(5 * 9 + 4);
    const field = FlowField.init(&arena, &grid, grid.cellIndex(player));
    var e = Enemies{};
    e.add(grid.cellCentre(3 * 9 + 4));

    var frames: u32 = 0;
    while (maths.magnitude(e.pos[0] - player) > 0.05 and frames < 30 * 5) : (frames += 1) {
        update(&e, &field, &grid, player, 1.0 / 30.0);
        try std.testing.expect(!grid.isOccupied(e.pos[0]));
    }
    try std.testing.expect(maths.magnitude(e.pos[0] - player) <= 0.05);
}

test "[enemy_movement_system] a bump into a wall stops at the wall" {
    //The wall's left edge is at x = 0.75m
    var lvl: TestLevel = undefined;
    lvl.init(12, Vec2f{ -2, 0 });
    var e = Enemies{};
    e.add(Vec2f{ 0.65, 0 });
    e.startBumpBack(0, Vec2f{ 1, 0 }, consts.BUMP_DISTANCE);
    for (0..15) |_| {
        update(&e, &lvl.field, &lvl.grid, Vec2f{ -2, 0 }, 1.0 / 30.0);
        try std.testing.expect(!lvl.grid.isOccupied(e.pos[0]));
    }
    try std.testing.expect(e.pos[0][0] < 0.75);
}
