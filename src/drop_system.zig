const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const DropSize = @import("level_loader.zig").DropSize;
const Drops = state.Drops;
const DropKind = state.DropKind;

const Vec2f = @Vector(2, f32);

const DROP_MIN_PLAYER_DIST_SQRD = consts.DROP_MIN_PLAYER_DIST * consts.DROP_MIN_PLAYER_DIST;
const DROP_PICKUP_RADIUS_SQRD = consts.DROP_PICKUP_RADIUS * consts.DROP_PICKUP_RADIUS;

/// Age the drops lying around (expired ones are flagged for `Drops.removeDead`) and, every DROP_INTERVAL while
/// there is room, put a new one on a free drop point. The size comes from the point (large ones are placed where
/// it is risky to go); whether it is ammo or health leans towards what the player is short of.
/// `drop_cells` / `drop_sizes` are the level's drop points. A point is tried DROP_SPAWN_ATTEMPTS times; if
/// none is free and far enough from the player the timer stays expired and it tries again next frame
///
pub fn update(drops: *Drops, rand: std.Random, player_pos: Vec2f, health: u8, ammo: u8, drop_cells: []const u16, drop_sizes: []const DropSize, grid: *const CollisionGrid, dt: f32) void {
    for (drops.lifetime[0..drops.len]) |*l| l.* -= dt;

    if (drops.isFull() or drop_cells.len == 0) return; //The timer waits until there is room
    drops.spawn_timer -= dt;
    if (drops.spawn_timer > 0) return;

    const size: DropSize = if (rand.float(f32) < consts.DROP_LARGE_CHANCE) .large else .small;
    const point = pickPoint(drops, rand, player_pos, drop_cells, drop_sizes, size, grid) orelse return;

    const ammo_chance = ammoChance(health, ammo);
    const is_ammo = rand.float(f32) < ammo_chance;
    const kind: DropKind = switch (drop_sizes[point]) {
        .small => if (is_ammo) .ammo_small else .health_small,
        .large => if (is_ammo) .ammo_large else .health_large,
    };
    drops.add(grid.cellCentre(drop_cells[point]), kind, point);
    drops.spawn_timer = consts.DROP_INTERVAL;
}

/// A random drop point of the wanted size (or any size, if the level has none of that size) with no drop on it
/// and far enough from the player, or null if the attempts all miss
///
fn pickPoint(drops: *const Drops, rand: std.Random, player_pos: Vec2f, drop_cells: []const u16, drop_sizes: []const DropSize, size: DropSize, grid: *const CollisionGrid) ?u8 {
    const num_sized = std.mem.count(DropSize, drop_sizes, &.{size});
    for (0..consts.DROP_SPAWN_ATTEMPTS) |_| {
        const point: u8 = if (num_sized == 0) rand.uintLessThan(u8, @intCast(drop_cells.len)) else nthOfSize(drop_sizes, size, rand.uintLessThan(usize, num_sized));
        if (std.mem.indexOfScalar(u8, drops.point[0..drops.len], point) != null) continue;
        if (maths.magnitudeSqrd(grid.cellCentre(drop_cells[point]) - player_pos) < DROP_MIN_PLAYER_DIST_SQRD) continue;
        return point;
    }
    return null;
}

fn nthOfSize(drop_sizes: []const DropSize, size: DropSize, n: usize) u8 {
    var seen: usize = 0;
    for (drop_sizes, 0..) |s, i| {
        if (s != size) continue;
        if (seen == n) return @intCast(i);
        seen += 1;
    }
    unreachable;
}

/// Chance the next drop is ammo: an even split, moved towards whichever of ammo (against START_AMMO) and health
/// the player is shorter of, and kept within DROP_AMMO_CHANCE_MIN..MAX so neither ever stops dropping
///
fn ammoChance(health: u8, ammo: u8) f32 {
    const ammo_short = 1 - @min(@as(f32, @floatFromInt(ammo)) / @as(f32, @floatFromInt(consts.START_AMMO)), 1);
    const health_short = 1 - @as(f32, @floatFromInt(health)) / @as(f32, @floatFromInt(consts.PLAYER_MAX_HEALTH));
    return std.math.clamp(0.5 + 0.5 * (ammo_short - health_short), consts.DROP_AMMO_CHANCE_MIN, consts.DROP_AMMO_CHANCE_MAX);
}

/// The player walks over drops to pick them up. Ammo tops up the gun and reloads (the gun can't fire until the
/// reload is done; a large drop takes longer), health heals at once. A drop the player has no room for (full
/// ammo or health) is left lying. Collected drops are flagged for `Drops.removeDead`
///
pub fn collect(drops: *Drops, player: *state.Player, bullets: *state.Bullets) void {
    for (drops.pos[0..drops.len], drops.kind[0..drops.len], drops.lifetime[0..drops.len]) |p, kind, *l| {
        if (l.* <= 0) continue;
        if (maths.magnitudeSqrd(p - player.pos) > DROP_PICKUP_RADIUS_SQRD) continue;

        switch (kind) {
            .ammo_small, .ammo_large => {
                if (bullets.ammo >= consts.MAX_AMMO) continue;
                const amount = if (kind == .ammo_large) consts.AMMO_DROP_LARGE else consts.AMMO_DROP_SMALL;
                const reload_time: f32 = if (kind == .ammo_large) consts.RELOAD_TIME_LARGE else consts.RELOAD_TIME_SMALL;
                bullets.ammo = @min(@as(u16, bullets.ammo) + amount, consts.MAX_AMMO);
                bullets.reload_timer = @max(bullets.reload_timer, reload_time);
            },
            .health_small, .health_large => {
                if (player.health >= consts.PLAYER_MAX_HEALTH) continue;
                const amount = if (kind == .health_large) consts.HEALTH_DROP_LARGE else consts.HEALTH_DROP_SMALL;
                player.health = @min(@as(u16, player.health) + amount, consts.PLAYER_MAX_HEALTH);
            },
        }
        l.* = 0;
    }
}

/// 20x20 grid of 64px (0.5m) cells with nothing in it, centred on the origin
const open_cells: [20 * 20]bool = @splat(false);
const OPEN_GRID = CollisionGrid{ .cells = &open_cells, .width = 20, .height = 20, .cell_width = 64, .cell_height = 64 };

test "[drop_system] drops arrive on the interval, on free points, until full, then expire" {
    //Plenty of points, all far from the player at the origin (cell 210)
    const cells = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 390, 391 };
    const sizes = [_]DropSize{ .small, .small, .small, .small, .small, .small, .large, .large, .large, .large };
    var drops = Drops{};
    var prng = std.Random.DefaultPrng.init(1);

    update(&drops, prng.random(), @splat(0), 100, 100, &cells, &sizes, &OPEN_GRID, consts.FIRST_DROP_TIME - 0.01);
    try std.testing.expect(drops.len == 0);
    update(&drops, prng.random(), @splat(0), 100, 100, &cells, &sizes, &OPEN_GRID, 0.02);
    try std.testing.expect(drops.len == 1);

    for (0..100) |_| update(&drops, prng.random(), @splat(0), 100, 100, &cells, &sizes, &OPEN_GRID, consts.DROP_INTERVAL / 4);
    try std.testing.expect(drops.len == Drops.capacity);
    //No two on the same point, and each kind matches its point's size
    for (drops.point[0..drops.len], drops.kind[0..drops.len], 0..) |p, k, i| {
        try std.testing.expect(std.mem.indexOfScalar(u8, drops.point[i + 1 .. drops.len], p) == null);
        try std.testing.expect(k.isLarge() == (sizes[p] == .large));
    }

    update(&drops, prng.random(), @splat(0), 100, 100, &cells, &sizes, &OPEN_GRID, consts.DROP_LIFETIME);
    drops.removeDead();
    try std.testing.expect(drops.len == 0);
}

test "[drop_system] drops never appear next to the player" {
    const cells = [_]u16{ 210, 0 }; //The player's cell and the far corner
    const sizes = [_]DropSize{ .small, .small };
    var drops = Drops{};
    var prng = std.Random.DefaultPrng.init(2);
    for (0..20) |_| update(&drops, prng.random(), @splat(0), 100, 100, &cells, &sizes, &OPEN_GRID, consts.DROP_INTERVAL);
    try std.testing.expect(drops.len == 1 and drops.point[0] == 1);
}

test "[drop_system] the kind leans towards what the player is short of" {
    try std.testing.expect(ammoChance(consts.PLAYER_MAX_HEALTH, 0) == consts.DROP_AMMO_CHANCE_MAX);
    try std.testing.expect(ammoChance(1, consts.MAX_AMMO) == consts.DROP_AMMO_CHANCE_MIN);
    try std.testing.expect(ammoChance(consts.PLAYER_MAX_HEALTH, consts.START_AMMO) == 0.5);
}

test "[drop_system] picking up ammo reloads before firing, health heals, and full drops are left" {
    var drops = Drops{};
    var player = state.Player{};
    var bullets = state.Bullets{};
    bullets.ammo = 0;
    player.health = consts.PLAYER_MAX_HEALTH;
    drops.add(@splat(0), .ammo_large, 0);
    drops.add(@splat(0), .health_small, 1);
    drops.add(Vec2f{ 1, 0 }, .health_large, 2); //Out of reach

    collect(&drops, &player, &bullets);
    try std.testing.expect(bullets.ammo == consts.AMMO_DROP_LARGE);
    try std.testing.expect(bullets.reload_timer == consts.RELOAD_TIME_LARGE);
    try std.testing.expect(drops.lifetime[0] <= 0);
    try std.testing.expect(drops.lifetime[1] > 0); //Health was full: left for later
    try std.testing.expect(drops.lifetime[2] > 0);

    player.health = consts.PLAYER_MAX_HEALTH - 5;
    collect(&drops, &player, &bullets);
    try std.testing.expect(player.health == consts.PLAYER_MAX_HEALTH); //Capped
    try std.testing.expect(drops.lifetime[1] <= 0);
}

test "[drop_system] ammo is capped and a full gun leaves ammo lying" {
    var drops = Drops{};
    var player = state.Player{};
    var bullets = state.Bullets{};
    bullets.ammo = consts.MAX_AMMO - 1;
    drops.add(@splat(0), .ammo_large, 0);
    drops.add(@splat(0), .ammo_small, 1);
    collect(&drops, &player, &bullets);
    try std.testing.expect(bullets.ammo == consts.MAX_AMMO);
    try std.testing.expect(drops.lifetime[0] <= 0 and drops.lifetime[1] > 0);
}
