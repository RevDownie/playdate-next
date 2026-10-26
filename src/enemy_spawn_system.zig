const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const FlowField = @import("flow_field.zig").FlowField;
const level_loader = @import("level_loader.zig");
const SpawnCells = level_loader.SpawnCells;

const Vec2f = @Vector(2, f32);

const SPAWN_MIN_PLAYER_DIST_SQRD = consts.SPAWN_MIN_PLAYER_DIST * consts.SPAWN_MIN_PLAYER_DIST;

/// Run the waves: count down the lull, then spawn the wave's enemies in bursts of WAVE_BURST_SIZE from its side(s)
/// of the map, until it has all spawned and is down to WAVE_CLEAR_LEFT enemies (survived: a lull follows) or it
/// has gone on for WAVE_MAX_TIME (the next wave follows at once). Enemies drop in on the edge spawn cells (see
/// `level_loader.findSpawnCells`); each gets SPAWN_ATTEMPTS random picks that must be able to reach the player and
/// not be too close to them, the last from any side, and waits for the next burst if they all miss, so the cost
/// is bounded
///
pub fn update(spawner: *state.Spawner, enemies: *state.Enemies, rand: std.Random, player_world_pos: Vec2f, spawn: *const SpawnCells, field: *const FlowField, grid: *const CollisionGrid, dt: f32) void {
    spawner.phase_time += dt;
    switch (spawner.phase) {
        .lull => {
            spawner.timer -= dt;
            if (spawner.timer <= 0) startWave(spawner, rand, spawner.wave + 1);
        },
        .wave => {
            if (spawner.to_spawn == 0 and enemies.len <= consts.WAVE_CLEAR_LEFT) {
                startLull(spawner);
                return;
            }
            if (spawner.phase_time >= consts.WAVE_MAX_TIME) {
                startWave(spawner, rand, spawner.wave + 1);
                return;
            }
            if (spawner.to_spawn == 0) return;
            spawner.timer -= dt;
            if (spawner.timer > 0) return;
            spawner.timer = spawner.burst_interval;
            spawnBurst(spawner, enemies, rand, player_world_pos, spawn, field, grid);
        },
    }
}

/// The tuning for wave `n` (1 based): from the WAVES table, then its last four repeated, bigger and faster each time
///
pub fn waveDef(n: u16) consts.WaveDef {
    std.debug.assert(n >= 1);
    const table_len: u16 = consts.WAVES.len;
    const def = if (n <= table_len) consts.WAVES[n - 1] else blk: {
        const k = n - table_len - 1;
        const repeat = k / 4 + 1;
        const base = consts.WAVES[table_len - 4 + k % 4];
        const r: f32 = @floatFromInt(repeat);
        break :blk consts.WaveDef{
            .size = base.size +| consts.WAVE_REPEAT_EXTRA_SIZE *| repeat,
            .burst_interval = @max(consts.WAVE_MIN_BURST_INTERVAL, base.burst_interval - consts.WAVE_REPEAT_FASTER * r),
            .lull = @max(consts.WAVE_MIN_LULL, base.lull - consts.WAVE_REPEAT_SHORTER_LULL * r),
        };
    };
    const scaled = @round(@as(f32, @floatFromInt(def.size)) * consts.WAVE_SIZE_SCALE);
    return .{ .size = @intFromFloat(std.math.clamp(scaled, 1, std.math.maxInt(u16))), .burst_interval = def.burst_interval, .lull = def.lull };
}

fn startWave(spawner: *state.Spawner, rand: std.Random, n: u16) void {
    const def = waveDef(n);
    //One side of the map to begin with, so the pressure has a direction to run from; more later on
    var sides: u8 = 0;
    while (@popCount(sides) < numSides(n)) sides |= @as(u8, 1) << rand.uintLessThan(u3, level_loader.NUM_SIDES);
    spawner.* = .{
        .wave = n,
        .phase = .wave,
        .timer = 0, //First burst straight away
        .to_spawn = def.size,
        .burst_interval = def.burst_interval,
        .sides = sides,
    };
}

/// How many sides of the map wave `n` comes from
///
pub fn numSides(n: u16) u8 {
    return @intCast(@min(level_loader.NUM_SIDES, 1 + (n - 1) / consts.WAVES_PER_EXTRA_SIDE));
}

fn startLull(spawner: *state.Spawner) void {
    spawner.phase = .lull;
    spawner.phase_time = 0;
    spawner.timer = waveDef(spawner.wave).lull;
    spawner.survived = true;
}

fn spawnBurst(spawner: *state.Spawner, enemies: *state.Enemies, rand: std.Random, player_world_pos: Vec2f, spawn: *const SpawnCells, field: *const FlowField, grid: *const CollisionGrid) void {
    if (spawn.all.len == 0) return;
    //Scatter within the cell so enemies sharing a cell don't stack exactly
    const jitter = Vec2f{ @floatFromInt(grid.cell_width), @floatFromInt(grid.cell_height) } * @as(Vec2f, @splat(0.8 / consts.METRES_TO_PIXELS));

    const room = state.Enemies.capacity - enemies.len;
    const count = @min(consts.WAVE_BURST_SIZE, spawner.to_spawn, room);
    for (0..count) |_| {
        for (0..consts.SPAWN_ATTEMPTS) |attempt| {
            //The wave's own side(s) first; the last attempt from anywhere, in case the player is right by them
            const side_cells = spawn.sides[randomSide(rand, spawner.sides)];
            const cells = if (attempt + 1 < consts.SPAWN_ATTEMPTS and side_cells.len > 0) side_cells else spawn.all;
            const cell = cells[rand.uintLessThan(usize, cells.len)];
            if (!field.isReachable(cell)) continue;
            const offset = (Vec2f{ rand.float(f32), rand.float(f32) } - @as(Vec2f, @splat(0.5))) * jitter;
            const pos = grid.cellCentre(cell) + offset;
            if (maths.magnitudeSqrd(pos - player_world_pos) < SPAWN_MIN_PLAYER_DIST_SQRD) continue;
            enemies.add(pos);
            spawner.to_spawn -= 1;
            break;
        }
    }
}

/// One of the sides set in `mask` (a bit per MapSide), at random
///
fn randomSide(rand: std.Random, mask: u8) usize {
    std.debug.assert(mask != 0);
    var pick = rand.uintLessThan(u8, @popCount(mask));
    for (0..level_loader.NUM_SIDES) |s| {
        if (mask & (@as(u8, 1) << @intCast(s)) == 0) continue;
        if (pick == 0) return s;
        pick -= 1;
    }
    unreachable;
}

/// 20x20 grid of 64px (0.5m) cells. A walled off pocket in the top left corner can't reach the player
const TestMap = struct {
    cells: [20 * 20]bool = @splat(false),
    buffer: [16 * 1024]u8 = undefined,
    arena: @import("memory.zig").Arena = undefined,
    spawn: SpawnCells = undefined,
    field: FlowField = undefined,

    fn grid(self: *const TestMap) CollisionGrid {
        return .{ .cells = &self.cells, .width = 20, .height = 20, .cell_width = 64, .cell_height = 64 };
    }

    fn init(self: *TestMap, player: Vec2f) void {
        for (0..4) |i| {
            self.cells[3 * 20 + i] = true;
            self.cells[i * 20 + 3] = true;
        }
        self.arena = @import("memory.zig").Arena.init("level", &self.buffer);
        const g = self.grid();
        self.spawn = level_loader.findSpawnCells(&g, &self.arena);
        self.field = FlowField.init(&self.arena, &g, g.cellIndex(player));
    }
};

test "[enemy_spawn_system] the wave table rises and falls but trends harder" {
    var dips: u32 = 0;
    for (1..40) |n| {
        const a = waveDef(@intCast(n));
        const b = waveDef(@intCast(n + 1));
        if (b.size < a.size) dips += 1;
        //Four waves on is always bigger and no slower
        const later = waveDef(@intCast(n + 4));
        try std.testing.expect(later.size > a.size);
        try std.testing.expect(later.burst_interval <= a.burst_interval);
        try std.testing.expect(a.burst_interval >= consts.WAVE_MIN_BURST_INTERVAL and a.lull >= consts.WAVE_MIN_LULL);
    }
    try std.testing.expect(dips >= 8); //A breather in every four
}

test "[enemy_spawn_system] a wave starts after the lull, spawns its size from its side, and is survived" {
    const player = Vec2f{ 0, 0 };
    var map: TestMap = .{};
    map.init(player);
    const grid = map.grid();
    var spawner = state.Spawner{};
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(1);
    const dt: f32 = 0.05;

    var t: f32 = 0;
    while (spawner.phase == .lull) : (t += dt) update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, dt);
    try std.testing.expect(spawner.wave == 1 and @popCount(spawner.sides) == 1);
    try std.testing.expectApproxEqAbs(t, consts.FIRST_WAVE_DELAY, dt * 1.5);

    while (spawner.to_spawn > 0) update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, dt);
    try std.testing.expect(enemies.len == waveDef(1).size);
    //All on the wave's side, reachable and away from the player
    const side: usize = @ctz(spawner.sides);
    for (enemies.positions()) |p| {
        const cell = grid.cellIndex(p).?;
        try std.testing.expect(std.mem.indexOfScalar(u16, map.spawn.sides[side], cell) != null);
        try std.testing.expect(map.field.isReachable(cell));
        try std.testing.expect(maths.magnitude(p - player) >= consts.SPAWN_MIN_PLAYER_DIST);
    }

    //Kill all but WAVE_CLEAR_LEFT: survived, and the lull is the wave's
    enemies.len = consts.WAVE_CLEAR_LEFT;
    update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, dt);
    try std.testing.expect(spawner.phase == .lull and spawner.survived and spawner.wave == 1);
    try std.testing.expect(spawner.timer == waveDef(1).lull);
}

test "[enemy_spawn_system] a wave that isn't survived in time is followed straight away by the next" {
    const player = Vec2f{ 0, 0 };
    var map: TestMap = .{};
    map.init(player);
    const grid = map.grid();
    var spawner = state.Spawner{};
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(2);
    var t: f32 = 0;
    while (t < consts.FIRST_WAVE_DELAY + consts.WAVE_MAX_TIME + 1) : (t += 0.1) {
        update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
        try std.testing.expect(!(spawner.phase == .lull and spawner.wave > 0)); //Never a lull: nothing was killed
    }
    try std.testing.expect(spawner.wave == 2 and !spawner.survived);
}

test "[enemy_spawn_system] spawning never overfills the enemies, and later waves come from more sides" {
    const player = Vec2f{ 0, -4 };
    var map: TestMap = .{};
    map.init(player);
    const grid = map.grid();
    var spawner = state.Spawner{};
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(3);
    var max_sides: u8 = 0;
    for (0..5000) |_| {
        update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
        try std.testing.expect(enemies.len <= state.Enemies.capacity);
        if (spawner.wave > 0) try std.testing.expect(@popCount(spawner.sides) == numSides(spawner.wave));
        max_sides = @max(max_sides, @popCount(spawner.sides));
    }
    try std.testing.expect(enemies.len == state.Enemies.capacity and max_sides >= 2);
    try std.testing.expect(numSides(1) == 1 and numSides(100) == level_loader.NUM_SIDES);
}
