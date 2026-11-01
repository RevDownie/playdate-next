/// Responsible for calculating enemy spawn waves frequency and spawn locations
///
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
/// The spawn ring is an ellipse squashed to the screen's aspect, so "just off screen" is as close above and below
/// as it is to the sides (a round ring far enough out at the sides is well outside a short map above and below)
const RING_SQUASH = Vec2f{ 1, consts.VIEW_HALF_HEIGHT / consts.VIEW_HALF_WIDTH };

/// Run the waves. A lull counts down to each wave. A wave has two parts:
/// - hold out (`hold` seconds): packs keep spawning so the number of enemies alive tracks a target that climbs
///   from WAVE_START_FRACTION of the wave's `peak` to all of it. The pressure is sustained: killing faster just
///   brings the next pack sooner (at most one pack per WAVE_PACK_INTERVAL)
/// - clear the rest: no more spawns; survived once at most WAVE_CLEAR_LEFT are left (a lull follows), or followed
///   straight away by the next wave if that takes longer than WAVE_CLEAR_MAX_TIME
/// A pack drops in together on one cell just off screen in the wave's direction(s), so it arrives as a crowd
///
pub fn update(spawner: *state.Spawner, enemies: *state.Enemies, rand: std.Random, player_world_pos: Vec2f, spawn: *const SpawnCells, field: *const FlowField, grid: *const CollisionGrid, dt: f32) void {
    spawner.phase_time += dt;
    switch (spawner.phase) {
        .lull => {
            spawner.timer -= dt;
            if (spawner.timer <= 0) startWave(spawner, rand, spawner.wave + 1);
        },
        .wave => {
            if (!spawner.isHolding()) {
                if (spawner.isLastWave()) {
                    //Nothing follows the last wave, so every one of them must go and there is no time limit
                    if (enemies.len == 0) startLull(spawner);
                } else if (enemies.len <= consts.WAVE_CLEAR_LEFT) {
                    startLull(spawner);
                } else if (spawner.phase_time >= spawner.hold + consts.WAVE_CLEAR_MAX_TIME) {
                    startWave(spawner, rand, spawner.wave + 1);
                }
                return;
            }
            spawner.timer -= dt;
            const target = targetAlive(spawner.peak, spawner.phase_time / spawner.hold);
            if (spawner.timer > 0 or enemies.len >= target) return;
            spawner.timer = consts.WAVE_PACK_INTERVAL;
            spawnPack(@min(spawner.pack, target - enemies.len), spawner.sides, spawner.wave, enemies, rand, player_world_pos, spawn, field, grid);
        },
    }
}

/// Enemies the wave keeps alive `progress` (0..1) of the way through holding out
///
fn targetAlive(peak: u8, progress: f32) u8 {
    const fraction = consts.WAVE_START_FRACTION + (1 - consts.WAVE_START_FRACTION) * std.math.clamp(progress, 0, 1);
    return @intFromFloat(@round(@as(f32, @floatFromInt(peak)) * fraction));
}

/// The tuning for wave `n` (1 based): from the WAVES table, then its last four repeated, bigger each time
///
fn waveDef(n: u16) consts.WaveDef {
    std.debug.assert(n >= 1);
    const table_len: u16 = consts.WAVES.len;
    const def = if (n <= table_len) consts.WAVES[n - 1] else blk: {
        const k = n - table_len - 1;
        const repeat = k / 4 + 1;
        const base = consts.WAVES[table_len - 4 + k % 4];
        break :blk consts.WaveDef{
            .hold = @min(consts.WAVE_MAX_HOLD, base.hold + consts.WAVE_REPEAT_LONGER * @as(f32, @floatFromInt(repeat))),
            .peak = @intCast(@min(state.Enemies.capacity, @as(u32, base.peak) + @as(u32, consts.WAVE_REPEAT_EXTRA_PEAK) * repeat)),
            .pack = @intCast(@min(consts.WAVE_MAX_PACK, @as(u32, base.pack) + repeat)),
            .lull = @max(consts.WAVE_MIN_LULL, base.lull - consts.WAVE_REPEAT_SHORTER_LULL * @as(f32, @floatFromInt(repeat))),
        };
    };
    const scaled = @round(@as(f32, @floatFromInt(def.peak)) * consts.WAVE_PEAK_SCALE);
    return .{ .hold = def.hold, .peak = @intFromFloat(std.math.clamp(scaled, 1, state.Enemies.capacity)), .pack = def.pack, .lull = def.lull };
}

/// A new enemy in wave `wave`: a runner (more of them each wave from wave 2), a brute (from wave 3, a few more each
/// wave), a shambler, or a walker
///
fn enemyKind(rand: std.Random, wave: u16) state.EnemyKind {
    const runner_chance = @min(consts.ENEMY_RUNNER_CHANCE_MAX, consts.ENEMY_RUNNER_CHANCE_PER_WAVE * @as(f32, @floatFromInt(wave -| 1)));
    const brute_chance = @min(consts.ENEMY_BRUTE_CHANCE_MAX, consts.ENEMY_BRUTE_CHANCE_PER_WAVE * @as(f32, @floatFromInt(wave -| 2)));
    const roll = rand.float(f32);
    if (roll < runner_chance) return .runner;
    if (roll < runner_chance + brute_chance) return .brute;
    if (roll < runner_chance + brute_chance + consts.ENEMY_SLOW_CHANCE) return .shambler;
    return .walker;
}

/// How fast a new enemy of `kind` seeks the player: walkers a little faster or slower than ENEMY_SPEED each
///
fn enemySpeed(rand: std.Random, kind: state.EnemyKind) f32 {
    return switch (kind) {
        .runner => consts.ENEMY_RUNNER_SPEED,
        .walker => consts.ENEMY_SPEED * (1 + consts.ENEMY_SPEED_JITTER * (rand.float(f32) * 2 - 1)),
        .shambler => consts.ENEMY_SLOW_SPEED,
        .brute => consts.ENEMY_BRUTE_SPEED,
    };
}

/// How many sides of the map wave `n` comes from
///
fn numSides(n: u16) u8 {
    return @intCast(@min(level_loader.NUM_SIDES, 1 + (n - 1) / consts.WAVES_PER_EXTRA_SIDE));
}

fn startWave(spawner: *state.Spawner, rand: std.Random, n: u16) void {
    const def = waveDef(n);
    //One side of the map to begin with, so the pressure has a direction to run from; more later on
    var sides: u8 = 0;
    while (@popCount(sides) < numSides(n)) sides |= @as(u8, 1) << rand.uintLessThan(u3, level_loader.NUM_SIDES);
    spawner.* = .{
        .last_wave = spawner.last_wave,
        .wave = n,
        .phase = .wave,
        .timer = 0, //First pack straight away
        .hold = def.hold,
        .peak = def.peak,
        .pack = def.pack,
        .sides = sides,
    };
}

fn startLull(spawner: *state.Spawner) void {
    spawner.phase = .lull;
    spawner.phase_time = 0;
    spawner.timer = if (spawner.isLastWave()) std.math.inf(f32) else waveDef(spawner.wave).lull;
    spawner.survived = true;
}

/// Drop up to `count` enemies together on one cell. First SPAWN_ATTEMPTS random points in the ring just off
/// screen (SPAWN_MIN_PLAYER_DIST to SPAWN_RING_MAX_DIST away) in one of the wave's directions, then as a fallback
/// the map's edge band on those sides, then anywhere on it. The cell must be free and able to reach the player;
/// if every pick misses the pack waits for the next interval, so the cost is bounded
///
fn spawnPack(count: u8, sides: u8, wave: u16, enemies: *state.Enemies, rand: std.Random, player_world_pos: Vec2f, spawn: *const SpawnCells, field: *const FlowField, grid: *const CollisionGrid) void {
    if (count == 0) return;
    const cell = ringCell(rand, sides, player_world_pos, field, grid) orelse edgeCell(rand, sides, player_world_pos, spawn, field, grid) orelse return;

    //Scatter within the cell so the pack doesn't stack exactly (separation spreads it from there)
    const jitter = Vec2f{ @floatFromInt(grid.cell_width), @floatFromInt(grid.cell_height) } * @as(Vec2f, @splat(0.8 / consts.METRES_TO_PIXELS));
    const n = @min(count, state.Enemies.capacity - enemies.len);
    for (0..n) |_| {
        const offset = (Vec2f{ rand.float(f32), rand.float(f32) } - @as(Vec2f, @splat(0.5))) * jitter;
        const kind = enemyKind(rand, wave);
        enemies.addKind(grid.cellCentre(cell) + offset, kind, enemySpeed(rand, kind));
    }
}

/// Directions (world, +y up) of each MapSide, in its order
const SIDE_DIRS = [level_loader.NUM_SIDES]Vec2f{ .{ 0, 1 }, .{ 1, 0 }, .{ 0, -1 }, .{ -1, 0 } };

fn ringCell(rand: std.Random, sides: u8, player_world_pos: Vec2f, field: *const FlowField, grid: *const CollisionGrid) ?u16 {
    for (0..consts.SPAWN_ATTEMPTS) |_| {
        //Within about 45 degrees either side of the wave's direction
        const dir = SIDE_DIRS[randomSide(rand, sides)];
        const across = Vec2f{ -dir[1], dir[0] } * @as(Vec2f, @splat(rand.float(f32) * 2 - 1));
        const dist = consts.SPAWN_MIN_PLAYER_DIST + rand.float(f32) * (consts.SPAWN_RING_MAX_DIST - consts.SPAWN_MIN_PLAYER_DIST);
        const pos = player_world_pos + maths.normaliseSafe(dir + across, dir) * @as(Vec2f, @splat(dist)) * RING_SQUASH;
        const cell = grid.cellIndex(pos) orelse continue;
        if (grid.cells[cell] or !field.isReachable(cell)) continue;
        if (ringDistSqrd(grid.cellCentre(cell) - player_world_pos) < SPAWN_MIN_PLAYER_DIST_SQRD) continue;
        return cell;
    }
    return null;
}

fn edgeCell(rand: std.Random, sides: u8, player_world_pos: Vec2f, spawn: *const SpawnCells, field: *const FlowField, grid: *const CollisionGrid) ?u16 {
    if (spawn.all.len == 0) return null;
    for (0..consts.SPAWN_ATTEMPTS) |attempt| {
        const side_cells = spawn.sides[randomSide(rand, sides)];
        const cells = if (attempt + 1 < consts.SPAWN_ATTEMPTS and side_cells.len > 0) side_cells else spawn.all;
        const cell = cells[rand.uintLessThan(usize, cells.len)];
        if (!field.isReachable(cell)) continue;
        if (ringDistSqrd(grid.cellCentre(cell) - player_world_pos) < SPAWN_MIN_PLAYER_DIST_SQRD) continue;
        return cell;
    }
    return null;
}

/// Squared distance of an offset from the player, measured on the squashed spawn ring
///
fn ringDistSqrd(offset: Vec2f) f32 {
    return maths.magnitudeSqrd(offset / RING_SQUASH);
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
        if (b.peak < a.peak) dips += 1;
        //Four waves on is never easier
        const later = waveDef(@intCast(n + 4));
        try std.testing.expect(later.peak >= a.peak and later.hold >= a.hold and later.pack >= a.pack);
        try std.testing.expect(a.lull >= consts.WAVE_MIN_LULL and a.hold <= consts.WAVE_MAX_HOLD and a.pack <= consts.WAVE_MAX_PACK);
        try std.testing.expect(a.peak <= state.Enemies.capacity);
    }
    try std.testing.expect(dips >= 4); //Breathers along the way
    try std.testing.expect(waveDef(12).peak > waveDef(4).peak);
}

test "[enemy_spawn_system] the target climbs from the start fraction to the peak while holding out" {
    try std.testing.expect(targetAlive(40, 0) == 16);
    try std.testing.expect(targetAlive(40, 0.5) == 28);
    try std.testing.expect(targetAlive(40, 1) == 40);
    try std.testing.expect(targetAlive(40, 2) == 40);
}

test "[enemy_spawn_system] a wave holds out, refilling as enemies die, then is cleared and survived" {
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

    //Hold out, killing a few now and then: the count keeps tracking the target and never overshoots it
    var spawned_after_kills = false;
    while (spawner.isHolding()) {
        const before = enemies.len;
        update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, dt);
        try std.testing.expect(enemies.len <= targetAlive(spawner.peak, spawner.phase_time / spawner.hold));
        if (enemies.len > before and spawner.phase_time > spawner.hold / 2) spawned_after_kills = true;
        if (@mod(spawner.phase_time, 2.0) < dt and enemies.len > 2) enemies.len -= 2; //"Kill" two
    }
    try std.testing.expect(spawned_after_kills);
    //All in the ring just off screen in the wave's direction, reachable (positions have moved a little, so loosely)
    const dir = SIDE_DIRS[@ctz(spawner.sides)];
    for (enemies.positions()) |p| {
        try std.testing.expect(map.field.isReachable(grid.cellIndex(p).?));
        const d = @sqrt(ringDistSqrd(p - player));
        //Half a 0.5m cell of slack: picks snap to cell centres, which the squash stretches vertically
        try std.testing.expect(d >= consts.SPAWN_MIN_PLAYER_DIST - 0.5 and d <= consts.SPAWN_RING_MAX_DIST + 0.5);
        try std.testing.expect(@reduce(.Add, maths.normaliseSafe((p - player) / RING_SQUASH, @splat(0)) * dir) > 0.6); //Within ~50 degrees
    }

    //Clearing: nothing more spawns; survived once down to WAVE_CLEAR_LEFT
    const left = enemies.len;
    update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, dt);
    try std.testing.expect(enemies.len == left and spawner.phase == .wave);
    enemies.len = consts.WAVE_CLEAR_LEFT;
    update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, dt);
    try std.testing.expect(spawner.phase == .lull and spawner.survived and spawner.wave == 1);
    try std.testing.expect(spawner.timer == waveDef(1).lull);
}

test "[enemy_spawn_system] a wave that isn't cleared in time is followed straight away by the next" {
    const player = Vec2f{ 0, 0 };
    var map: TestMap = .{};
    map.init(player);
    const grid = map.grid();
    var spawner = state.Spawner{};
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(2);
    const end = consts.FIRST_WAVE_DELAY + waveDef(1).hold + consts.WAVE_CLEAR_MAX_TIME + 1;
    var t: f32 = 0;
    while (t < end) : (t += 0.1) {
        update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
        try std.testing.expect(!(spawner.phase == .lull and spawner.wave > 0)); //Never a lull: nothing was killed
    }
    try std.testing.expect(spawner.wave == 2 and !spawner.survived);
}

test "[enemy_spawn_system] packs arrive together, spawning never overfills, and later waves come from more sides" {
    const player = Vec2f{ 0, -4 };
    var map: TestMap = .{};
    map.init(player);
    const grid = map.grid();
    var spawner = state.Spawner{};
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(3);
    var max_sides: u8 = 0;
    var checked_pack = false;
    for (0..20000) |_| {
        const before = enemies.len;
        update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
        try std.testing.expect(enemies.len <= state.Enemies.capacity);
        if (enemies.len >= before + 2) { //A pack: all on one cell
            const cell = grid.cellIndex(enemies.pos[before]).?;
            for (enemies.pos[before..enemies.len]) |p| try std.testing.expect(grid.cellIndex(p).? == cell);
            checked_pack = true;
        }
        if (spawner.wave > 0) try std.testing.expect(@popCount(spawner.sides) == numSides(spawner.wave));
        max_sides = @max(max_sides, @popCount(spawner.sides));
        if (enemies.len > 60) enemies.len -= 10; //Kill some so the waves keep coming
    }
    try std.testing.expect(checked_pack and max_sides >= 3);
    try std.testing.expect(numSides(1) == 1 and numSides(100) == level_loader.NUM_SIDES);
}

test "[enemy_spawn_system] enemy kinds mix, with runners from wave 2, brutes from wave 3 and more of both later" {
    var prng = std.Random.DefaultPrng.init(4);
    var counts: [3][4]u32 = @splat(@splat(0));
    for ([_]u16{ 1, 3, 20 }, 0..) |wave, w| {
        for (0..2000) |_| {
            const kind = enemyKind(prng.random(), wave);
            counts[w][@backingInt(kind)] += 1;
            const s = enemySpeed(prng.random(), kind);
            try std.testing.expect(s >= consts.ENEMY_BRUTE_SPEED and s <= consts.ENEMY_MAX_SPEED);
            if (kind == .walker) try std.testing.expect(s > consts.ENEMY_SLOW_SPEED and s < consts.ENEMY_RUNNER_SPEED);
        }
    }
    const runner = @backingInt(state.EnemyKind.runner);
    const brute = @backingInt(state.EnemyKind.brute);
    try std.testing.expect(counts[0][runner] == 0 and counts[1][runner] > 0 and counts[2][runner] > counts[1][runner]);
    try std.testing.expect(counts[0][brute] == 0 and counts[1][brute] > 0 and counts[2][brute] > counts[1][brute]);
    try std.testing.expect(counts[2][runner] < 2000 * 0.35 and counts[2][brute] < 2000 * 0.15);
    try std.testing.expect(counts[0][@backingInt(state.EnemyKind.shambler)] > 2000 / 5); //Every wave has shamblers
}

test "[enemy_spawn_system] the last wave is never followed by another: it waits to be cleared, then spawning stops" {
    const player = Vec2f{ 0, 0 };
    var map: TestMap = .{};
    map.init(player);
    const grid = map.grid();
    var spawner = state.Spawner{ .last_wave = 1 };
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(5);
    //Nothing killed, well past the time a wave is followed by the next one
    const end = consts.FIRST_WAVE_DELAY + waveDef(1).hold + consts.WAVE_CLEAR_MAX_TIME + 5;
    var t: f32 = 0;
    while (t < end) : (t += 0.1) update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
    try std.testing.expect(spawner.wave == 1 and spawner.phase == .wave and spawner.isLastWave());
    //Down to the few a wave is usually survived with isn't enough: all of them must go
    enemies.len = consts.WAVE_CLEAR_LEFT;
    update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
    try std.testing.expect(spawner.phase == .wave);
    enemies.len = 0;
    update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
    try std.testing.expect(spawner.phase == .lull and spawner.survived);
    for (0..2000) |_| update(&spawner, &enemies, prng.random(), player, &map.spawn, &map.field, &grid, 0.1);
    try std.testing.expect(enemies.len == 0 and spawner.wave == 1 and spawner.last_wave == 1);
}
