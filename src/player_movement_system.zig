/// Responsible for player movement in response to input state. Using the collision grid to block and slide
///
const std = @import("std");
const consts = @import("tweak_constants.zig");
const maths = @import("maths.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;

const Vec2f = @Vector(2, f32);

/// How far short of a blocked cell's edge the player stops, so they stay inside their own cell
const WALL_GAP: f32 = 0.001;

/// Calculate the updated velocity and position based on input state and acceleration
/// ensuring we don't walk through any env obstacles
///
pub fn update(player: *state.Player, input: state.Input, collision_grid: *const CollisionGrid, dt: f32) void {
    const dir = inputDir(input);
    //One speed shared by every direction: it builds up while any direction is held, so changing direction (or a
    //thumb rolling across the d-pad) keeps it. No momentum - stop dead as soon as everything is released
    const held = dir[0] != 0 or dir[1] != 0;
    const speed = if (held) @min(maths.magnitude(player.vel) + consts.PLAYER_ACC * dt, consts.PLAYER_MAX_SPEED) else 0;

    const pos = player.pos;
    const new_pos = move(collision_grid, pos, dir, speed * dt);

    //Distance run drives the run cycle; only its place in a cycle matters, so it wraps rather than growing forever
    player.run_dist += maths.magnitude(new_pos - pos);
    while (player.run_dist >= consts.HERO_RUN_CYCLE_DIST) player.run_dist -= consts.HERO_RUN_CYCLE_DIST;
    player.pos = new_pos;
    player.vel = dir * @as(Vec2f, @splat(speed));
}

/// Unit direction of the d-pad: one of 8, or zero when nothing (or only opposites) is held
///
fn inputDir(input: state.Input) Vec2f {
    const x = @as(f32, @floatFromInt(@intFromBool(input.right))) - @as(f32, @floatFromInt(@intFromBool(input.left)));
    const y = @as(f32, @floatFromInt(@intFromBool(input.up))) - @as(f32, @floatFromInt(@intFromBool(input.down)));
    const scale: f32 = if (x != 0 and y != 0) std.math.sqrt1_2 else 1;
    return Vec2f{ x, y } * @as(Vec2f, @splat(scale));
}

/// Move `dist` along `dir` from `pos` against the collision grid. The axes move in separate passes, each stopping
/// flush against a blocked cell. A diagonal into a wall slides along it at full speed, and a single direction held
/// into the end of a wall is nudged round it
///
fn move(grid: *const CollisionGrid, pos: Vec2f, dir: Vec2f, dist: f32) Vec2f {
    const step = dir * @as(Vec2f, @splat(dist));
    const blocked_x = dir[0] != 0 and grid.isOccupied(Vec2f{ pos[0] + step[0], pos[1] });
    const blocked_y = dir[1] != 0 and grid.isOccupied(Vec2f{ pos[0], pos[1] + step[1] });

    var delta = step;
    if (dir[0] != 0 and dir[1] != 0) {
        //Slide along the wall with all the speed, not just the free axis' share of the diagonal. Past the end of a
        //wall (only the diagonal cell blocked) slide along x
        if (blocked_x and !blocked_y) {
            delta[1] = std.math.sign(dir[1]) * dist;
        } else if ((blocked_y and !blocked_x) or (!blocked_x and !blocked_y and grid.isOccupied(pos + step))) {
            delta[0] = std.math.sign(dir[0]) * dist;
            delta[1] = if (blocked_y) step[1] else 0;
        }
    } else if (blocked_x) {
        delta[1] = cornerNudge(grid, pos, 0, step[0], dist);
    } else if (blocked_y) {
        delta[0] = cornerNudge(grid, pos, 1, step[1], dist);
    }

    var new_pos = pos;
    new_pos[0] = moveAxis(grid, new_pos, 0, delta[0]);
    new_pos[1] = moveAxis(grid, new_pos, 1, delta[1]);
    return new_pos;
}

/// Size of a grid cell in metres on each axis
///
fn cellSize(grid: *const CollisionGrid) Vec2f {
    return Vec2f{ @floatFromInt(grid.cell_width), @floatFromInt(grid.cell_height) } / @as(Vec2f, @splat(consts.METRES_TO_PIXELS));
}

/// New coordinate on `axis` after moving `delta` along it from `pos`. If that lands in a blocked cell it stops
/// just short of the edge of the cell it is in (it can't reach further than the next cell, see the check on
/// PLAYER_MAX_SPEED)
///
fn moveAxis(grid: *const CollisionGrid, pos: Vec2f, comptime axis: u1, delta: f32) f32 {
    if (delta == 0) return pos[axis];
    var target = pos;
    target[axis] += delta;
    if (!grid.isOccupied(target)) return target[axis];

    //Cell centres sit on multiples of the cell size
    const size = cellSize(grid)[axis];
    const side = std.math.sign(delta);
    const edge = @round(pos[axis] / size) * size + side * (size * 0.5 - WALL_GAP);
    //A target short of the edge is in the player's own cell, which is blocked: stay put rather than walk through it
    if ((edge - target[axis]) * side >= 0) return pos[axis];
    //Never back away from a wall the player is already closer to than WALL_GAP
    return if (side > 0) @max(pos[axis], edge) else @min(pos[axis], edge);
}

/// Sideways move (on the other axis) that takes a player moving along `axis` into a blocked cell round its end:
/// when they are within PLAYER_CORNER_NUDGE of a cell of the edge on their nearer side, and both the cell beside
/// them and the one beyond it in the way they are going are free. Zero otherwise
///
fn cornerNudge(grid: *const CollisionGrid, pos: Vec2f, comptime axis: u1, step: f32, dist: f32) f32 {
    const perp: u1 = comptime 1 - axis;
    const size = cellSize(grid)[perp];
    const offset = pos[perp] - @round(pos[perp] / size) * size;
    const side: f32 = if (offset >= 0) 1 else -1;
    const gap = size * 0.5 - @abs(offset);
    if (gap > size * consts.PLAYER_CORNER_NUDGE) return 0;

    var beside = pos;
    beside[perp] += side * size;
    var beyond = beside;
    beyond[axis] += step;
    if (grid.isOccupied(beside) or grid.isOccupied(beyond)) return 0;
    //Just across the edge, so the next step forward is into the free cell
    return side * @min(dist, gap + 2 * WALL_GAP);
}

/// 9x9 grid of the levels' cell size with only the cells listed blocked, for the tests
///
fn testGrid(cells: *[81]bool, blocked: []const [2]u8) CollisionGrid {
    const kit_descs = @import("kit_descs.zig");
    cells.* = @splat(false);
    for (blocked) |c| cells[@as(usize, c[1]) * 9 + c[0]] = true;
    return CollisionGrid{ .cells = cells, .width = 9, .height = 9, .cell_width = kit_descs.CELL_W, .cell_height = kit_descs.CELL_H };
}

/// Run the player for `frames` at TARGET_FRAME_DT, checking they never end up in a blocked cell
///
fn testRun(player: *state.Player, input: state.Input, grid: *const CollisionGrid, frames: u32) !void {
    for (0..frames) |_| {
        update(player, input, grid, consts.TARGET_FRAME_DT);
        try std.testing.expect(!grid.isOccupied(player.pos));
    }
}

test "[player_movement_system] diagonals are no faster than straight lines, and speed survives a change of direction" {
    var cells: [81]bool = undefined;
    const grid = testGrid(&cells, &.{});
    var player: state.Player = .{};
    try testRun(&player, .{ .right = true, .up = true }, &grid, 2);
    const diag_speed = maths.magnitude(player.vel);
    player = .{};
    try testRun(&player, .{ .right = true }, &grid, 2);
    try std.testing.expectApproxEqAbs(diag_speed, maths.magnitude(player.vel), 1e-5);

    //Rolling from right to up keeps the speed built up rather than starting the new axis from zero
    const speed = maths.magnitude(player.vel);
    try testRun(&player, .{ .up = true }, &grid, 1);
    try std.testing.expect(maths.magnitude(player.vel) > speed and player.vel[0] == 0);
    try testRun(&player, .{}, &grid, 1);
    try std.testing.expect(player.vel[0] == 0 and player.vel[1] == 0);
}

test "[player_movement_system] a diagonal into a wall slides along it at full speed, flush against it" {
    var cells: [81]bool = undefined;
    //A wall along the row above the centre
    const grid = testGrid(&cells, &.{ .{ 2, 3 }, .{ 3, 3 }, .{ 4, 3 }, .{ 5, 3 }, .{ 6, 3 } });
    const cell = cellSize(&grid);
    var player: state.Player = .{ .vel = .{ consts.PLAYER_MAX_SPEED, 0 } };
    try testRun(&player, .{ .right = true, .up = true }, &grid, 20);
    try std.testing.expectApproxEqAbs(cell[1] * 0.5, player.pos[1], 2 * WALL_GAP); //Flush with the wall
    const x = player.pos[0];
    try testRun(&player, .{ .right = true, .up = true }, &grid, 1);
    try std.testing.expectApproxEqAbs(consts.PLAYER_MAX_SPEED * consts.TARGET_FRAME_DT, player.pos[0] - x, 1e-5);
}

test "[player_movement_system] holding one direction into the end of a wall nudges round it, but not from its middle" {
    var cells: [81]bool = undefined;
    //One blocked cell above the centre
    const grid = testGrid(&cells, &.{.{ 4, 3 }});
    const cell = cellSize(&grid);

    //Just left of the centre cell's right edge, heading up: nudged right and then up past the block
    var player: state.Player = .{ .pos = .{ cell[0] * 0.3, 0 } };
    try testRun(&player, .{ .up = true }, &grid, 60);
    try std.testing.expect(player.pos[0] > cell[0] * 0.5 and player.pos[1] > cell[1] * 1.5);

    //Squarely below it: stopped flush against it
    player = .{ .pos = .{ cell[0] * 0.05, 0 } };
    try testRun(&player, .{ .up = true }, &grid, 60);
    try std.testing.expect(player.pos[0] == cell[0] * 0.05);
    try std.testing.expectApproxEqAbs(cell[1] * 0.5, player.pos[1], 2 * WALL_GAP);

    //Heading right into the block from beside its top edge (the player's cell is the one left of it)
    player = .{ .pos = .{ -cell[0], cell[1] * 1.3 } };
    try testRun(&player, .{ .right = true }, &grid, 60);
    try std.testing.expect(player.pos[0] > cell[0] * 0.5 and player.pos[1] > cell[1] * 1.5);
}

test "[player_movement_system] no nudge into a gap that is itself blocked" {
    var cells: [81]bool = undefined;
    //Two blocked cells side by side above the centre: nothing to slip through on the right
    const grid = testGrid(&cells, &.{ .{ 4, 3 }, .{ 5, 3 } });
    const cell = cellSize(&grid);
    var player: state.Player = .{ .pos = .{ cell[0] * 0.3, 0 } };
    try testRun(&player, .{ .up = true }, &grid, 60);
    try std.testing.expect(player.pos[0] == cell[0] * 0.3);
}
