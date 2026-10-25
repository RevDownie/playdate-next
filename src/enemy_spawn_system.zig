const std = @import("std");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");

const Vec2f = @Vector(2, f32);

/// Keep spawning up to the max number by dropping enemies in around the player with increasing frequency
///
pub fn update(spawner: *state.Spawner, enemies: *state.Enemies, rand: std.Random, player_world_pos: Vec2f, dt: f32) void {
    if (enemies.isFull()) return;

    spawner.next_spawn_timer -= dt;
    if (spawner.next_spawn_timer > 0.0) return;

    spawner.next_spawn_timer = spawner.spawn_interval;
    spawner.spawn_interval = @max(spawner.spawn_interval - consts.SPAWN_TIME_REDUCTION, consts.MIN_SPAWN_TIME);

    const to_spawn = @min(consts.ENEMIES_PER_SPAWN, state.Enemies.capacity - enemies.len);
    for (0..to_spawn) |_| {
        const x = player_world_pos[0] + (rand.float(f32) * 2.0 - 1.0) * consts.SPAWN_RADIUS;
        const y = player_world_pos[1] + (rand.float(f32) * 2.0 - 1.0) * consts.SPAWN_RADIUS;
        enemies.add(Vec2f{ x, y });
    }
}

test "[enemy_spawn_system] never spawns past capacity" {
    var spawner = state.Spawner{};
    var enemies = state.Enemies{};
    var prng = std.Random.DefaultPrng.init(1);
    for (0..1000) |_| update(&spawner, &enemies, prng.random(), @splat(0), 1.0);
    try std.testing.expect(enemies.len == state.Enemies.capacity);
}
