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
const story = @import("../story.zig");

const Vec2f = @Vector(2, f32);

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
            .kit = 0,
            .start_pos = @splat(0),
            .obj_world_positions = &.{},
            .obj_pieces = &.{},
            .collision_grid = .{ .cells = &self.cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 },
            .spawn_cells = .{ .all = &.{}, .sides = @splat(&.{}) },
            .drop_cells = &.{},
            .drop_sizes = &.{},
        };
        self.level_arena = Arena.init("level", &self.level_buffer);
        self.level.spawn_cells = level_loader.findSpawnCells(&self.level.collision_grid, &self.level_arena);
        self.frame_arena = Arena.init("frame", &self.frame_buffer);
        self.field = FlowField.init(&self.level_arena, &self.level.collision_grid, self.level.collision_grid.cellIndex(@splat(0)));
    }

    /// A fresh run on this level, started the way the game starts one
    fn newRun(self: *const TestLevel) state.GameState {
        var game = state.GameState{};
        game_mod.beginRun(&game, self.level.start_pos);
        return game;
    }

    /// Stop the waves and drop enemies on random reachable spawn cells until the pool is full. The waves only
    /// reach a full horde late in a run, which is too slow (and too random) for a test that needs one now
    fn fillHorde(self: *TestLevel, game: *state.GameState, rand: std.Random) void {
        game.spawner.timer = std.math.inf(f32);
        const cells = self.level.spawn_cells.all;
        while (!game.enemies.isFull()) {
            const cell = cells[rand.uintLessThan(usize, cells.len)];
            if (!self.field.isReachable(cell)) continue;
            game.enemies.add(self.level.collision_grid.cellCentre(cell));
        }
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
    var game = t.newRun();

    //Keep the horde topped up to the max and spin the crank flat out with endless ammo. The player walks a
    //loop the whole time so the flow field keeps rebuilding
    var prng = std.Random.DefaultPrng.init(7);
    var frames: usize = 0;
    var max_enemies: usize = 0;
    while (frames < 60 * 120) : (frames += 1) {
        t.fillHorde(&game, prng.random());
        game.bullets.ammo = consts.MAX_AMMO;
        game.player.health = consts.PLAYER_MAX_HEALTH;
        const phase = (frames / 120) % 4;
        _ = t.tick(&game, .{ .crank_delta = consts.FIRE_ANGLE_DELTA, .left = phase == 0, .up = phase == 1, .right = phase == 2, .down = phase == 3 });
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
    var game = t.newRun();

    //No firing and no dying: a full horde piles in on the player for a while
    var prng = std.Random.DefaultPrng.init(7);
    t.fillHorde(&game, prng.random());
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
    var game = t.newRun();
    game.spawner.timer = std.math.inf(f32); //Just the one enemy
    game.enemies.add(.{ 4, 0 }); //Behind the vertical wall at x = 2m

    var frames: usize = 0;
    while (game.player.health == consts.PLAYER_MAX_HEALTH and frames < 60 * 30) : (frames += 1) {
        _ = t.tick(&game, .{});
        try std.testing.expect(!t.level.collision_grid.isOccupied(game.enemies.pos[0]));
    }
    try std.testing.expect(game.player.health < consts.PLAYER_MAX_HEALTH);
    //Going round the wall's end (y = -2.5m) is about 9m, not the 4m straight line
    try std.testing.expect(@as(f32, @floatFromInt(frames)) / 60.0 * consts.ENEMY_SPEED > 6);
}

test "[scenario] the player dies if left alone" {
    var t: TestLevel = .{};
    t.init(false);
    var game = t.newRun();

    var result = game_mod.TickResult.playing;
    var frames: usize = 0;
    while (result == .playing and frames < 60 * 600) : (frames += 1) {
        result = t.tick(&game, .{});
    }
    try std.testing.expect(result == .player_died);
}

test "[scenario] balance: a steadily cranked gun holds the horde off for a while, but is overrun in the end" {
    //A player standing still in the open turning the crank once a second, at TARGET_FPS, with ammo
    //kept topped up (this measures the gun against the waves; ammo comes from drops, see the drop scenarios).
    //With the current tuning they are overrun in wave 4 after ~100s and ~350 kills. The bounds are wide so tuning
    //can move, but a change that makes the gun hopeless or the player unbeatable fails here
    const dt: f32 = consts.TARGET_FRAME_DT;
    var t: TestLevel = .{};
    t.init(true);
    var game = t.newRun();

    var result = game_mod.TickResult.playing;
    var frames: usize = 0;
    var kills: u32 = 0;
    while (result == .playing and frames < consts.TARGET_FPS * 300) : (frames += 1) {
        const streak = game.player.kill_streak;
        game.bullets.ammo = consts.MAX_AMMO;
        t.frame_arena.reset();
        result = game_mod.tick(&game, &t.level, &t.field, .{ .crank_delta = 360.0 * dt }, dt, &t.frame_arena);
        if (game.player.kill_streak > streak) kills += game.player.kill_streak - streak;
    }
    const secs = @as(f32, @floatFromInt(frames)) * dt;
    try std.testing.expect(result == .player_died);
    try std.testing.expect(secs > 80 and secs < 300);
    try std.testing.expect(game.spawner.wave >= 4 and game.spawner.wave <= 9);
    try std.testing.expect(kills > 280);
}

test "[scenario] an enemy right up against the player can be shot" {
    var t: TestLevel = .{};
    t.init(false);
    var game = t.newRun();
    game.spawner.timer = std.math.inf(f32);
    game.enemies.add(.{ consts.PLAYER_RING_RADIUS, 0 });

    //Fires at the end of the first frame, hits on the next
    _ = t.tick(&game, .{ .crank_delta = consts.FIRE_ANGLE_DELTA });
    _ = t.tick(&game, .{});
    try std.testing.expect(game.enemies.len == 1);
    try std.testing.expect(game.enemies.health[0] < state.EnemyKind.walker.def().health);
}

test "[scenario] bullets can't go through walls" {
    var t: TestLevel = .{};
    t.init(true);
    var game = t.newRun();
    game.spawner.timer = std.math.inf(f32);
    game.enemies.add(.{ 4, 0 }); //Behind the vertical wall at x = 2m
    //It is off screen and behind the wall so the gun keeps its aim: point that at the wall
    game.player.facing_dir = .{ 1, 0 };

    //Crank flat out the whole time the enemy is behind the wall (it is pathing round the end)
    var frames: usize = 0;
    var shots: usize = 0;
    while (frames < 60 * 3) : (frames += 1) {
        game.bullets.ammo = consts.MAX_AMMO;
        const before = game.bullets.ammo;
        _ = t.tick(&game, .{ .crank_delta = consts.FIRE_ANGLE_DELTA });
        if (game.bullets.ammo < before) shots += 1;
        for (game.bullets.dir[0..game.bullets.len]) |d| try std.testing.expect(d[0] > 0.99); //At the wall
        const p = game.enemies.pos[0];
        if (p[0] < 2.3 or @abs(p[1]) > 4) break;
        try std.testing.expect(game.enemies.health[0] == state.EnemyKind.walker.def().health);
    }
    try std.testing.expect(shots > 30);
}

test "[scenario] the gun shoots the enemy it can see, not a closer one behind a wall" {
    var t: TestLevel = .{};
    t.init(true);
    var game = t.newRun();
    game.spawner.timer = std.math.inf(f32);
    game.player.pos = .{ 1, 0 };
    game.enemies.add(.{ 2.5, 0 }); //1.5m away, on screen but behind the vertical wall at x = 2m
    game.enemies.add(.{ -0.6, 0 }); //1.6m away in the open

    var frames: usize = 0;
    while (frames < 60) : (frames += 1) {
        game.bullets.ammo = consts.MAX_AMMO;
        _ = t.tick(&game, .{ .crank_delta = consts.FIRE_ANGLE_DELTA });
        for (game.bullets.dir[0..game.bullets.len]) |d| try std.testing.expect(d[0] < 0); //Never a shot at the wall
        for (game.enemies.positions(), game.enemies.health[0..game.enemies.len]) |p, h| {
            if (p[0] > 1.75) try std.testing.expect(h == state.EnemyKind.walker.def().health);
        }
    }
    //The one in the open is dead and the gun has stopped aiming at anything
    try std.testing.expect(game.enemies.len == 1 and game.enemies.pos[0][0] > 1.75);
    try std.testing.expect(game.player.target_pos == null);
}

test "[scenario] with nothing in sight the gun aims the way the player moves, or keeps its aim" {
    var t: TestLevel = .{};
    t.init(false);
    var game = t.newRun();
    game.spawner.timer = std.math.inf(f32);
    game.player.facing_dir = .{ 0, 1 };

    _ = t.tick(&game, .{});
    try std.testing.expect(game.player.facing_dir[0] == 0 and game.player.facing_dir[1] == 1);
    _ = t.tick(&game, .{ .right = true });
    try std.testing.expect(game.player.facing_dir[0] == 1 and game.player.facing_dir[1] == 0);
    _ = t.tick(&game, .{}); //Stopped: keeps aiming right rather than snapping back
    try std.testing.expect(game.player.facing_dir[0] == 1 and game.player.facing_dir[1] == 0);
    try std.testing.expect(game.player.target_pos == null);
}

/// Drop points for the drop scenarios: small ones 3m out on each side of the player's start, large ones further
/// out in two corners
const TEST_DROP_POSITIONS = [_]Vec2f{ .{ 3, 0 }, .{ -3, 0 }, .{ 0, 3 }, .{ 0, -3 }, .{ 5, 5 }, .{ -5, -5 } };
const TEST_DROP_SIZES = [_]level_loader.DropSize{ .small, .small, .small, .small, .large, .large };

/// Crank steadily for `secs` with no enemies, either standing still or walking to the nearest ammo drop.
/// Returns the shots fired
fn shotsFiredWithDrops(walk_to_drops: bool, secs: f32) !u32 {
    const dt: f32 = consts.TARGET_FRAME_DT;
    var t: TestLevel = .{};
    t.init(false);
    var drop_cells: [TEST_DROP_POSITIONS.len]u16 = undefined;
    for (TEST_DROP_POSITIONS, &drop_cells) |p, *c| c.* = t.level.collision_grid.cellIndex(p).?;
    t.level.drop_cells = &drop_cells;
    t.level.drop_sizes = &TEST_DROP_SIZES;
    var game = t.newRun();
    game.spawner.timer = std.math.inf(f32);

    var shots: u32 = 0;
    var frames: usize = 0;
    while (@as(f32, @floatFromInt(frames)) * dt < secs) : (frames += 1) {
        var input = state.Input{ .crank_delta = 360.0 * dt };
        if (walk_to_drops) {
            var nearest: ?Vec2f = null;
            for (game.drops.positions(), game.drops.kind[0..game.drops.len]) |p, k| {
                if (!k.isAmmo()) continue;
                if (nearest == null or maths.magnitude(p - game.player.pos) < maths.magnitude(nearest.? - game.player.pos)) nearest = p;
            }
            if (nearest) |n| {
                const d = n - game.player.pos;
                input.right = d[0] > 0.05;
                input.left = d[0] < -0.05;
                input.up = d[1] > 0.05;
                input.down = d[1] < -0.05;
            }
        }
        const before = game.bullets.ammo;
        t.frame_arena.reset();
        _ = game_mod.tick(&game, &t.level, &t.field, input, dt, &t.frame_arena);
        if (game.bullets.ammo < before) shots += 1;
        try std.testing.expect(game.drops.len <= state.Drops.capacity);
    }
    return shots;
}

test "[scenario] the gun never refills by itself, and a player who goes out for ammo drops keeps firing" {
    //Standing still it runs dry
    const standing = try shotsFiredWithDrops(false, 60);
    try std.testing.expect(standing == consts.START_AMMO);
    //A steady crank wants 12 shots a second; walking to drops keeps the gun going much longer
    const walking = try shotsFiredWithDrops(true, 60);
    try std.testing.expect(walking > standing * 3);
}

/// Survive the horde in the open test level, cranking steadily the whole time, either standing still or
/// walking to the nearest useful drop (ammo, or health once hurt). Returns the seconds survived
fn secondsSurvivedWithDrops(walk_to_drops: bool) f32 {
    const dt: f32 = consts.TARGET_FRAME_DT;
    var t: TestLevel = .{};
    t.init(false);
    var drop_cells: [TEST_DROP_POSITIONS.len]u16 = undefined;
    for (TEST_DROP_POSITIONS, &drop_cells) |p, *c| c.* = t.level.collision_grid.cellIndex(p).?;
    t.level.drop_cells = &drop_cells;
    t.level.drop_sizes = &TEST_DROP_SIZES;
    var game = t.newRun();

    var frames: usize = 0;
    var result = game_mod.TickResult.playing;
    while (result == .playing and frames < consts.TARGET_FPS * 600) : (frames += 1) {
        var input = state.Input{ .crank_delta = 360.0 * dt };
        if (walk_to_drops) {
            const hurt = game.player.health < consts.PLAYER_MAX_HEALTH - consts.HEALTH_DROP_SMALL;
            var nearest: ?Vec2f = null;
            for (game.drops.positions(), game.drops.kind[0..game.drops.len]) |p, k| {
                if (!k.isAmmo() and !hurt) continue;
                if (nearest == null or maths.magnitude(p - game.player.pos) < maths.magnitude(nearest.? - game.player.pos)) nearest = p;
            }
            if (nearest) |n| {
                const d = n - game.player.pos;
                input.right = d[0] > 0.05;
                input.left = d[0] < -0.05;
                input.up = d[1] > 0.05;
                input.down = d[1] < -0.05;
            }
        }
        t.frame_arena.reset();
        result = game_mod.tick(&game, &t.level, &t.field, input, dt, &t.frame_arena);
    }
    return @as(f32, @floatFromInt(frames)) * dt;
}

test "[scenario] under the horde, a player who goes out for drops outlives one who stands still" {
    const standing = secondsSurvivedWithDrops(false);
    const walking = secondsSurvivedWithDrops(true);
    //Standing still lasts ~21s (the melee holds a few off once the ammo is gone); walking to drops reaches the 600s
    //cap (the player is faster than most enemies, so one who keeps moving can outrun most of a wave)
    try std.testing.expect(walking > standing * 1.5);
}

test "[scenario] out of ammo, the player's melee fights off a few enemies" {
    var t: TestLevel = .{};
    t.init(false);
    var game = t.newRun();
    game.spawner.timer = std.math.inf(f32);
    game.bullets.ammo = 0;
    game.enemies.add(.{ 0.6, 0 });
    game.enemies.add(.{ -0.6, 0.1 });
    game.enemies.add(.{ 0, -0.5 });

    var frames: usize = 0;
    var swings: u32 = 0;
    while (game.enemies.len > 0 and frames < 60 * 10) : (frames += 1) {
        const before = game.melee.swing_timer;
        _ = t.tick(&game, .{});
        if (game.melee.swing_timer > before) swings += 1;
    }
    try std.testing.expect(game.enemies.len == 0);
    try std.testing.expect(game.player.kills == 3 and swings >= 2);
    try std.testing.expect(game.player.health > consts.PLAYER_MAX_HEALTH - 4 * consts.CONTACT_DMG); //Mostly held off
}

test "[scenario] a story chapter stops spawning after its waves and is complete once they are cleared" {
    var t: TestLevel = .{};
    t.init(false);
    var game = state.GameState{ .invincible = true };
    game_mod.beginChapter(&game, t.level.start_pos, .{ .level = 0, .objective = .survive, .first_wave = 1, .last_wave = 2 });
    try std.testing.expect(t.tick(&game, .{}) == .playing); //Not complete before the first wave
    try std.testing.expect(!game.scoring); //Story has no score

    //Wave 1: cleared as soon as it stops spawning
    var frames: u32 = 0;
    while (game.spawner.wave < 2) : (frames += 1) {
        try std.testing.expect(t.tick(&game, .{}) == .playing);
        if (game.spawner.phase == .wave and !game.spawner.isHolding()) game.enemies.len = 0;
        try std.testing.expect(frames < consts.TARGET_FPS * 120);
    }

    //Wave 2, the last: left standing well past the time a survival wave is followed by the next
    const limit: u32 = @intFromFloat((game.spawner.hold + consts.WAVE_CLEAR_MAX_TIME + 5) * 60);
    for (0..limit) |_| {
        try std.testing.expect(t.tick(&game, .{}) == .playing);
        try std.testing.expect(game.spawner.wave == 2);
    }
    try std.testing.expect(game.spawner.phase == .wave and game.enemies.len > 0);

    //Cleared: a moment to see it was, then complete, with nothing more spawned
    game.enemies.len = 0;
    var result = game_mod.TickResult.playing;
    frames = 0;
    while (result == .playing) : (frames += 1) {
        result = t.tick(&game, .{});
        try std.testing.expect(game.enemies.len == 0);
        try std.testing.expect(frames < 60 * 10);
    }
    try std.testing.expect(result == .chapter_complete and game.spawner.wave == 2);
    try std.testing.expect(@as(f32, @floatFromInt(frames)) / 60.0 >= consts.CHAPTER_COMPLETE_DELAY - 0.1);
}

test "[scenario] a survival run is never complete: its waves go on" {
    var t: TestLevel = .{};
    t.init(false);
    var game = t.newRun();
    game.invincible = true;
    var frames: u32 = 0;
    while (game.spawner.wave < 3) : (frames += 1) {
        try std.testing.expect(t.tick(&game, .{}) == .playing);
        if (game.spawner.phase == .wave and !game.spawner.isHolding()) game.enemies.len = 0;
        try std.testing.expect(frames < consts.TARGET_FPS * 300);
    }
}

test "[scenario] a later story chapter starts on its first wave and ends after its last" {
    var t: TestLevel = .{};
    t.init(false);
    var game = state.GameState{ .invincible = true };
    game_mod.beginChapter(&game, t.level.start_pos, .{ .level = 0, .objective = .survive, .first_wave = 4, .last_wave = 5 });
    var frames: u32 = 0;
    var first_seen: u16 = 0;
    var result = game_mod.TickResult.playing;
    while (result == .playing) : (frames += 1) {
        result = t.tick(&game, .{});
        if (first_seen == 0 and game.spawner.wave > 0 and game.spawner.phase == .wave) first_seen = game.spawner.wave;
        if (game.spawner.phase == .wave and !game.spawner.isHolding()) game.enemies.len = 0;
        try std.testing.expect(game.spawner.wave <= 5);
        try std.testing.expect(frames < consts.TARGET_FPS * 300);
    }
    try std.testing.expect(result == .chapter_complete and first_seen == 4 and game.spawner.wave == 5);
}

test "[scenario] a walk chapter never spawns and is complete once the player has walked its distance" {
    var t: TestLevel = .{};
    t.init(false);
    var game = state.GameState{};
    game_mod.beginChapter(&game, t.level.start_pos, .{ .level = 0, .objective = .walk });
    //Standing still never completes it
    for (0..consts.TARGET_FPS * 30) |_| try std.testing.expect(t.tick(&game, .{}) == .playing);
    try std.testing.expect(game.enemies.len == 0);
    //Walk back and forth across the open middle of the map
    var frames: u32 = 0;
    var result = game_mod.TickResult.playing;
    while (result == .playing) : (frames += 1) {
        const right = (frames / (consts.TARGET_FPS * 2)) % 2 == 0;
        result = t.tick(&game, .{ .right = right, .left = !right });
        try std.testing.expect(game.enemies.len == 0);
        try std.testing.expect(frames < 60 * 120);
    }
    try std.testing.expect(result == .chapter_complete);
    const walked = @as(f32, @floatFromInt(frames)) / 60.0 * consts.PLAYER_MAX_SPEED;
    try std.testing.expect(walked >= story.WALK_DIST * 0.95 and walked <= story.WALK_DIST * 1.3);
}
