//! Scenario tests: drive the whole simulation through `game.tick` for many frames, covering worst-case
//! counts and gameplay outcomes that no single system's unit tests can. Unit tests live next to the code
//! they test; this file is for anything that spans systems.

const std = @import("std");
const consts = @import("../tweak_constants.zig");
const state = @import("../game_state.zig");
const game_mod = @import("../game.zig");
const Arena = @import("../memory.zig").Arena;
const Level = @import("../level_loader.zig").Level;
const FlowField = @import("../flow_field.zig").FlowField;
const level_loader = @import("../level_loader.zig");
const maths = @import("../maths.zig");

/// Level used by the tests: a 30x30 grid of 64px (0.5m) cells, centred on the origin. With `walls` there is
/// a vertical wall at column 19 (x = 2m) from row 5 to 24 and a horizontal one along row 8 (y = 3.5m) from
/// column 3 to 12, so enemies have something to path around; the player at the origin is in the open
///
const TestLevel = struct {
    cells: [30 * 30]bool = undefined,
    level_buffer: [16 * 1024]u8 = undefined,
    frame_buffer: [16 * 1024]u8 = undefined,
    level_arena: Arena = undefined,
    frame_arena: Arena = undefined,
    level: Level = undefined,
    field: FlowField = undefined,

    fn init(self: *TestLevel, walls: bool) void {
        @memset(&self.cells, false);
        if (walls) {
            for (5..25) |row| self.cells[row * 30 + 19] = true;
            for (3..13) |col| self.cells[8 * 30 + col] = true;
        }
        self.level = .{
            .obj_world_positions = &.{},
            .obj_bitmap_indices = &.{},
            .collision_grid = .{ .cells = &self.cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 },
            .spawn_cells = &.{},
            .bg_size_pixels = .{ 0, 0 },
        };
        self.level_arena = Arena.init("level", &self.level_buffer);
        self.level.spawn_cells = level_loader.findSpawnCells(&self.level.collision_grid, &self.level_arena);
        self.frame_arena = Arena.init("frame", &self.frame_buffer);
        self.field = FlowField.init(&self.level_arena, &self.level.collision_grid, self.level.collision_grid.cellIndex(@splat(0)));
    }

    fn tick(self: *TestLevel, game: *state.GameState, input: state.Input) game_mod.TickResult {
        self.frame_arena.reset();
        return game_mod.tick(game, &self.level, &self.field, input, 1.0 / 60.0, &self.frame_arena);
    }
};

test "[scenario] worst case: max enemies and bullets fit the frame arena and pools, and stay out of the walls" {
    var t: TestLevel = .{};
    t.init(true);
    const grid = &t.level.collision_grid;
    var game = state.GameState{};

    //Hold fire until the horde is full (the gun otherwise keeps the count low), then spin the crank flat out
    //with an endless magazine. The player walks a loop the whole time so the flow field keeps rebuilding
    var frames: usize = 0;
    var max_enemies: usize = 0;
    while (frames < 60 * 120) : (frames += 1) {
        game.bullets.magazine = consts.BULLET_MAG_SIZE;
        game.player.health = consts.PLAYER_MAX_HEALTH;
        const phase = (frames / 120) % 4;
        const firing = max_enemies == state.Enemies.capacity;
        _ = t.tick(&game, .{ .crank_delta = if (firing) consts.FIRE_ANGLE_DELTA else 0, .left = phase == 0, .up = phase == 1, .right = phase == 2, .down = phase == 3 });
        try std.testing.expect(game.enemies.len <= state.Enemies.capacity);
        try std.testing.expect(game.bullets.len <= state.Bullets.capacity);
        for (game.enemies.positions()) |p| try std.testing.expect(!grid.isOccupied(p));
        max_enemies = @max(max_enemies, game.enemies.len);
    }
    try std.testing.expect(game.player.score > 0);
    try std.testing.expect(max_enemies == state.Enemies.capacity);
}

test "[scenario] a full horde surrounds the player without stacking" {
    var t: TestLevel = .{};
    t.init(true);
    var game = state.GameState{};

    //No firing and no dying: let the pool fill and pile in on the player for a while
    var frames: usize = 0;
    while (frames < 60 * 90) : (frames += 1) {
        game.player.health = consts.PLAYER_MAX_HEALTH;
        _ = t.tick(&game, .{});
    }
    try std.testing.expect(game.enemies.len == state.Enemies.capacity);

    const pos = game.enemies.positions();
    var stacked: usize = 0;
    var min_pair: f32 = std.math.inf(f32);
    var min_player: f32 = std.math.inf(f32);
    for (pos, 0..) |p, i| {
        min_player = @min(min_player, maths.magnitude(p - game.player.pos));
        for (pos[i + 1 ..]) |q| {
            const d = maths.magnitude(q - p);
            min_pair = @min(min_pair, d);
            if (d < consts.ENEMY_SEPARATION_DIST * 0.5) stacked += 1;
        }
    }
    //Without separation about a fifth of all pairs (~1000 of 4950) end up on top of each other. With it only
    //the odd pair caught mid knock-back (bumping enemies aren't pushed) is closer than half the spacing
    try std.testing.expect(stacked < 20);
    try std.testing.expect(min_pair > 0.05);
    try std.testing.expect(min_player >= consts.PLAYER_RING_RADIUS - 0.01);
}

test "[scenario] an enemy behind a wall paths around it and reaches the player" {
    var t: TestLevel = .{};
    t.init(true);
    var game = state.GameState{};
    game.spawner.next_spawn_timer = std.math.inf(f32); //Just the one enemy
    game.enemies.add(.{ 4, 0 }); //Behind the vertical wall at x = 2m

    var frames: usize = 0;
    while (game.player.health == consts.PLAYER_MAX_HEALTH and frames < 60 * 30) : (frames += 1) {
        _ = t.tick(&game, .{});
        try std.testing.expect(!t.level.collision_grid.isOccupied(game.enemies.pos[0]));
    }
    try std.testing.expect(game.player.health < consts.PLAYER_MAX_HEALTH);
    //Going round the wall's end (y = -2.5m) is about 9m, not the 4m straight line
    try std.testing.expect(@as(f32, @floatFromInt(frames)) / 60.0 * consts.ENEMY_MAX_SPEED > 6);
}

test "[scenario] the player dies if left alone" {
    var t: TestLevel = .{};
    t.init(false);
    var game = state.GameState{};

    var result = game_mod.TickResult.playing;
    var frames: usize = 0;
    while (result == .playing and frames < 60 * 600) : (frames += 1) {
        result = t.tick(&game, .{});
    }
    try std.testing.expect(result == .player_died);
}

test "[scenario] an enemy right up against the player can be shot" {
    var t: TestLevel = .{};
    t.init(false);
    var game = state.GameState{};
    game.spawner.next_spawn_timer = std.math.inf(f32);
    game.enemies.add(.{ consts.PLAYER_RING_RADIUS, 0 });

    //Fires at the end of the first frame, hits on the next
    _ = t.tick(&game, .{ .crank_delta = consts.FIRE_ANGLE_DELTA });
    _ = t.tick(&game, .{});
    try std.testing.expect(game.enemies.len == 1);
    try std.testing.expect(game.enemies.health[0] < consts.ENEMY_MAX_HEALTH);
}

test "[scenario] bullets can't go through walls" {
    var t: TestLevel = .{};
    t.init(true);
    var game = state.GameState{};
    game.spawner.next_spawn_timer = std.math.inf(f32);
    game.enemies.add(.{ 4, 0 }); //Behind the vertical wall at x = 2m
    //It is off screen and behind the wall so the gun keeps its aim: point that at the wall
    game.player.facing_dir = .{ 1, 0 };

    //Crank flat out the whole time the enemy is behind the wall (it is pathing round the end)
    var frames: usize = 0;
    var shots: usize = 0;
    while (frames < 60 * 3) : (frames += 1) {
        game.bullets.magazine = consts.BULLET_MAG_SIZE;
        const before = game.bullets.magazine;
        _ = t.tick(&game, .{ .crank_delta = consts.FIRE_ANGLE_DELTA });
        if (game.bullets.magazine < before) shots += 1;
        for (game.bullets.dir[0..game.bullets.len]) |d| try std.testing.expect(d[0] > 0.99); //At the wall
        const p = game.enemies.pos[0];
        if (p[0] < 2.3 or @abs(p[1]) > 4) break;
        try std.testing.expect(game.enemies.health[0] == consts.ENEMY_MAX_HEALTH);
    }
    try std.testing.expect(shots > 30);
}

test "[scenario] the gun shoots the enemy it can see, not a closer one behind a wall" {
    var t: TestLevel = .{};
    t.init(true);
    var game = state.GameState{};
    game.spawner.next_spawn_timer = std.math.inf(f32);
    game.player.pos = .{ 1, 0 };
    game.enemies.add(.{ 2.5, 0 }); //1.5m away, on screen but behind the vertical wall at x = 2m
    game.enemies.add(.{ -0.6, 0 }); //1.6m away in the open

    var frames: usize = 0;
    while (frames < 60) : (frames += 1) {
        game.bullets.magazine = consts.BULLET_MAG_SIZE;
        _ = t.tick(&game, .{ .crank_delta = consts.FIRE_ANGLE_DELTA });
        for (game.bullets.dir[0..game.bullets.len]) |d| try std.testing.expect(d[0] < 0); //Never a shot at the wall
        for (game.enemies.positions(), game.enemies.health[0..game.enemies.len]) |p, h| {
            if (p[0] > 1.75) try std.testing.expect(h == consts.ENEMY_MAX_HEALTH);
        }
    }
    //The one in the open is dead and the gun has stopped aiming at anything
    try std.testing.expect(game.enemies.len == 1 and game.enemies.pos[0][0] > 1.75);
    try std.testing.expect(game.player.target_pos == null);
}

test "[scenario] with nothing in sight the gun aims the way the player moves, or keeps its aim" {
    var t: TestLevel = .{};
    t.init(false);
    var game = state.GameState{};
    game.spawner.next_spawn_timer = std.math.inf(f32);
    game.player.facing_dir = .{ 0, 1 };

    _ = t.tick(&game, .{});
    try std.testing.expect(game.player.facing_dir[0] == 0 and game.player.facing_dir[1] == 1);
    _ = t.tick(&game, .{ .right = true });
    try std.testing.expect(game.player.facing_dir[0] == 1 and game.player.facing_dir[1] == 0);
    _ = t.tick(&game, .{}); //Stopped: keeps aiming right rather than snapping back
    try std.testing.expect(game.player.facing_dir[0] == 1 and game.player.facing_dir[1] == 0);
    try std.testing.expect(game.player.target_pos == null);
}
