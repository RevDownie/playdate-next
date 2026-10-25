//! Scenario tests: drive the whole simulation through `game.tick` for many frames, covering worst-case
//! counts and gameplay outcomes that no single system's unit tests can. Unit tests live next to the code
//! they test; this file is for anything that spans systems.

const std = @import("std");
const consts = @import("../tweak_constants.zig");
const state = @import("../game_state.zig");
const game_mod = @import("../game.zig");
const Arena = @import("../memory.zig").Arena;
const Level = @import("../level_loader.zig").Level;

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

test "[scenario] worst case: max enemies and bullets fit the frame arena and pools" {
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
        _ = game_mod.tick(&game, &level, .{ .crank_delta = consts.FIRE_ANGLE_DELTA }, 1.0 / 60.0, &frame_arena);
        try std.testing.expect(game.enemies.len <= state.Enemies.capacity);
        try std.testing.expect(game.bullets.len <= state.Bullets.capacity);
    }
    try std.testing.expect(game.player.score > 0);
}

test "[scenario] the player dies if left alone" {
    var cells: [30 * 30]bool = undefined;
    const level = testLevel(&cells);
    var frame_buffer: [16 * 1024]u8 = undefined;
    var frame_arena = Arena.init("frame", &frame_buffer);
    var game = state.GameState{};

    var result = game_mod.TickResult.playing;
    var frames: usize = 0;
    while (result == .playing and frames < 60 * 600) : (frames += 1) {
        frame_arena.reset();
        result = game_mod.tick(&game, &level, .{}, 1.0 / 60.0, &frame_arena);
    }
    try std.testing.expect(result == .player_died);
}
