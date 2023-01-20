const std = @import("std");
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

pub const SpawnData = struct { world_pos: Vec2f };

var max_active_allowed: u8 = 0;
var spawn_time: f32 = 0;
var next_spawn_timer: f32 = 0;
var spawn_buffer: [5]SpawnData = undefined;
var rand: std.rand.DefaultPrng = undefined;

pub fn init(max_active: u8) void {
    max_active_allowed = max_active;
    rand = std.rand.DefaultPrng.init(42);
}

pub fn reset() void {
    spawn_time = consts.INIT_SPAWN_TIME;
    next_spawn_timer = 0.25;
}

/// Keep spawning up to the max number by dropping enemies in with increasing frequency
/// Returned data only lasts for a frame before being stomped
///
pub fn update(dt: f32, num_active: usize, player_world_pos: Vec2f) []SpawnData {
    if (num_active >= max_active_allowed) {
        return spawn_buffer[0..0];
    }

    next_spawn_timer -= dt;

    if (next_spawn_timer <= 0.0) {
        //Spawn
        next_spawn_timer = spawn_time;
        spawn_time -= consts.SPAWN_TIME_REDUCTION;
        const to_spawn = std.math.min(consts.ENEMIES_PER_SPAWN, max_active_allowed - num_active);
        var i: u32 = 0;
        while (i < to_spawn) : (i += 1) {
            const x = player_world_pos[0] + (rand.random().float(f32) * 2.0 - 1.0) * 10;
            const y = player_world_pos[1] + (rand.random().float(f32) * 2.0 - 1.0) * 10;
            const sd = SpawnData{ .world_pos = Vec2f{ x, y } };
            spawn_buffer[i] = sd;
        }
        return spawn_buffer[0..to_spawn];
    }

    return spawn_buffer[0..0];
}
