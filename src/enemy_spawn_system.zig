const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const FlowField = @import("flow_field.zig").FlowField;

const Vec2f = @Vector(2, f32);

const SPAWN_MIN_PLAYER_DIST_SQRD = consts.SPAWN_MIN_PLAYER_DIST * consts.SPAWN_MIN_PLAYER_DIST;

/// Keep spawning up to the max number by dropping enemies in around the edge of the map with increasing
/// frequency, so the horde closes in from every side and follows the flow field in rather than appearing
/// in a clump next to the player. `spawn_cells` are the free edge cells (see `level_loader.findSpawnCells`);
/// each enemy gets SPAWN_ATTEMPTS random picks that must be able to reach the player and not be too close
/// to them, and is skipped if they all miss, so the cost is bounded
///
pub fn update(spawner: *state.Spawner, enemies: *state.Enemies, rand: std.Random, player_world_pos: Vec2f, spawn_cells: []const u16, field: *const FlowField, grid: *const CollisionGrid, dt: f32) void {
    if (enemies.isFull() or spawn_cells.len == 0) return;

    spawner.next_spawn_timer -= dt;
    if (spawner.next_spawn_timer > 0.0) return;

    spawner.next_spawn_timer = spawner.spawn_interval;
    spawner.spawn_interval = @max(spawner.spawn_interval - consts.SPAWN_TIME_REDUCTION, consts.MIN_SPAWN_TIME);

    //Scatter within the cell so enemies sharing a cell don't stack exactly
    const jitter = Vec2f{ @floatFromInt(grid.cell_width), @floatFromInt(grid.cell_height) } * @as(Vec2f, @splat(0.8 / consts.METRES_TO_PIXELS));

    const to_spawn = @min(consts.ENEMIES_PER_SPAWN, state.Enemies.capacity - enemies.len);
    for (0..to_spawn) |_| {
        for (0..consts.SPAWN_ATTEMPTS) |_| {
            const cell = spawn_cells[rand.uintLessThan(usize, spawn_cells.len)];
            if (!field.isReachable(cell)) continue;
            const offset = (Vec2f{ rand.float(f32), rand.float(f32) } - @as(Vec2f, @splat(0.5))) * jitter;
            const pos = grid.cellCentre(cell) + offset;
            if (maths.magnitudeSqrd(pos - player_world_pos) < SPAWN_MIN_PLAYER_DIST_SQRD) continue;
            enemies.add(pos);
            break;
        }
    }
}

test "[enemy_spawn_system] spawns up to capacity on reachable edge cells away from the player" {
    const level_loader = @import("level_loader.zig");
    //20x20 grid of 64px (0.5m) cells. A walled off pocket in the top left corner can't reach the player
    var cells: [20 * 20]bool = @splat(false);
    for (0..4) |i| {
        cells[3 * 20 + i] = true;
        cells[i * 20 + 3] = true;
    }
    const grid = CollisionGrid{ .cells = &cells, .width = 20, .height = 20, .cell_width = 64, .cell_height = 64 };
    var buffer: [16 * 1024]u8 = undefined;
    var arena = @import("memory.zig").Arena.init("level", &buffer);
    const spawn_cells = level_loader.findSpawnCells(&grid, &arena);
    //Player near the bottom edge, so some edge cells are too close
    const player = Vec2f{ 0, -4 };
    const field = FlowField.init(&arena, &grid, grid.cellIndex(player));

    var spawner = state.Spawner{};
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(1);
    for (0..1000) |_| update(&spawner, &enemies, prng.random(), player, spawn_cells, &field, &grid, 1.0);
    try std.testing.expect(enemies.len == state.Enemies.capacity);
    for (enemies.positions()) |p| {
        try std.testing.expect(field.isReachable(grid.cellIndex(p)));
        try std.testing.expect(maths.magnitude(p - player) >= consts.SPAWN_MIN_PLAYER_DIST);
    }
}
