const std = @import("std");

const Vec2f = @Vector(2, f32);

pub const SpawnData = struct { world_pos: Vec2f };

//TODO: Centralise consts for spawning
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
    spawn_time = 10;
    next_spawn_timer = 1;
}

/// Keep spawning up to the max number by dropping enemies in with increasing frequency
/// Returned data only lasts for a frame before being stomped
///
pub fn update(dt: f32, num_active: usize) []SpawnData {
    if (num_active >= max_active_allowed) {
        return spawn_buffer[0..0];
    }

    next_spawn_timer -= dt;

    if (next_spawn_timer <= 0.0) {
        //Spawn
        next_spawn_timer = spawn_time;
        spawn_time -= 1.0;
        const x = (rand.random().float(f32) * 2.0 - 1.0) * 10;
        const y = (rand.random().float(f32) * 2.0 - 1.0) * 10;
        const sd = SpawnData{ .world_pos = Vec2f{ x, y } };
        spawn_buffer[0] = sd;
        return spawn_buffer[0..1];
    }

    return spawn_buffer[0..0];
}
