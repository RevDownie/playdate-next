const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const Arena = @import("memory.zig").Arena;
const Level = @import("level_loader.zig").Level;
const player_move_sys = @import("player_movement_system.zig");
const enemy_spawn_sys = @import("enemy_spawn_system.zig");
const enemy_move_sys = @import("enemy_movement_system.zig");
const bullet_sys = @import("bullet_system.zig");
const combat_sys = @import("combat_system.zig");
const auto_target_sys = @import("auto_targetting_system.zig");
const firing_sys = @import("firing_system.zig");

const Vec2f = @Vector(2, f32);

pub const TickResult = enum { playing, player_died };

/// The orchestrator: advances the simulation one frame by running every system in a fixed order.
/// Systems only see the data they are handed; per frame scratch comes from `frame_arena`.
/// Platform independent (no Playdate API) so it can be driven from tests.
///
pub fn tick(game: *state.GameState, level: *const Level, input: state.Input, dt: f32, frame_arena: *Arena) TickResult {
    //1. Spawn new enemies around the player
    enemy_spawn_sys.update(&game.spawner, &game.enemies, game.rng.random(), game.player.pos, dt);

    //2. Movement
    player_move_sys.update(&game.player, input, &level.collision_grid, dt);
    enemy_move_sys.update(&game.enemies, game.player.pos, dt);

    //3. Move projectiles and resolve bullet -> enemy hits (kills are flagged then compacted out)
    bullet_sys.update(&game.bullets, dt);
    const hits = bullet_sys.collide(&game.bullets, game.enemies.positions(), frame_arena.alloc(state.Hit, game.bullets.len));
    combat_sys.applyBulletHits(hits, &game.enemies, &game.player);
    game.bullets.removeDead();
    game.enemies.removeDead();

    //4. Enemies touching the player hurt them
    combat_sys.applyEnemyContact(&game.enemies, &game.player);
    if (game.player.health == 0) return .player_died;

    //5. Now that the enemy positions are final, aim at the hottest target and fire
    const target_dir = auto_target_sys.calculateHottestTargetDir(game.player.pos, game.enemies.positions()) orelse maths.normaliseSafe(game.player.vel, Vec2f{ 1, 0 });
    if (firing_sys.update(&game.trigger, input, dt)) {
        bullet_sys.fire(&game.bullets, game.player.pos, target_dir);
    }
    game.player.facing_dir = target_dir; //Player faces the way they are firing

    //6. Camera and effects
    game.camera_pos = game.player.pos; //Follow the player directly for now
    game.player.hit_flash_timer = @max(game.player.hit_flash_timer - dt, 0);

    return .playing;
}

/// Open level used by the tests: a 30x30 grid of 64px cells with nothing in it
///
fn testLevel(cells: []bool) Level {
    @memset(cells, false);
    return .{
        .obj_world_positions = &.{},
        .obj_bitmap_indices = &.{},
        .collision_grid = .{ .cells = cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 },
        .bg_size_pixels = .{ 0, 0 },
    };
}

test "[game] worst case: max enemies and bullets fit the frame arena and pools" {
    var cells: [30 * 30]bool = undefined;
    const level = testLevel(&cells);
    var frame_buffer: [16 * 1024]u8 = undefined;
    var frame_arena = Arena.init("frame", &frame_buffer);
    var game = state.GameState{};

    //Spin the crank flat out with an endless magazine while the horde builds up
    var frames: usize = 0;
    while (frames < 60 * 120) : (frames += 1) {
        frame_arena.reset();
        game.bullets.magazine = consts.BULLET_MAG_SIZE;
        game.player.health = consts.PLAYER_MAX_HEALTH;
        _ = tick(&game, &level, .{ .crank_delta = consts.FIRE_ANGLE_DELTA }, 1.0 / 60.0, &frame_arena);
        try std.testing.expect(game.enemies.len <= state.Enemies.capacity);
        try std.testing.expect(game.bullets.len <= state.Bullets.capacity);
    }
    try std.testing.expect(game.player.score > 0);
}

test "[game] the player dies if left alone" {
    var cells: [30 * 30]bool = undefined;
    const level = testLevel(&cells);
    var frame_buffer: [16 * 1024]u8 = undefined;
    var frame_arena = Arena.init("frame", &frame_buffer);
    var game = state.GameState{};

    var result = TickResult.playing;
    var frames: usize = 0;
    while (result == .playing and frames < 60 * 600) : (frames += 1) {
        frame_arena.reset();
        result = tick(&game, &level, .{}, 1.0 / 60.0, &frame_arena);
    }
    try std.testing.expect(result == .player_died);
}
