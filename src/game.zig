/// The main game loop that ticks all the systems to update the state data. Only runs the simulation, no rendering
///
const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const Arena = @import("memory.zig").Arena;
const Level = @import("level_loader.zig").Level;
const flow_field = @import("flow_field.zig");
const player_move_sys = @import("player_movement_system.zig");
const enemy_spawn_sys = @import("enemy_spawn_system.zig");
const enemy_move_sys = @import("enemy_movement_system.zig");
const bullet_sys = @import("bullet_system.zig");
const combat_sys = @import("combat_system.zig");
const auto_target_sys = @import("auto_targetting_system.zig");
const firing_sys = @import("firing_system.zig");
const drop_sys = @import("drop_system.zig");
const melee_sys = @import("melee_system.zig");
const gore_sys = @import("gore_system.zig");
const camera_sys = @import("camera_system.zig");
const story = @import("story.zig");
const story_sys = @import("story_system.zig");

const Vec2f = @Vector(2, f32);

/// `chapter_complete` only comes in a story chapter: once its last wave is cleared, or its walk is walked
pub const TickResult = enum { playing, player_died, chapter_complete };

/// The orchestrator: advances the simulation one frame by running every system in a fixed order.
/// Systems only see the data they are handed; per frame scratch comes from `frame_arena`.
/// Platform independent (no Playdate API) so it can be driven from tests.
/// `field` is the enemies' path to the player; it is level-sized so it lives in the level arena, not `game`.
///
pub fn tick(game: *state.GameState, level: *const Level, field: *flow_field.FlowField, input: state.Input, dt: f32, frame_arena: *Arena) TickResult {
    const grid = &level.collision_grid;
    game.run_time += dt;
    game.events.len = 0;

    //Spawn enemies offscreen. A wave starting or ending is a story moment
    const wave_before = game.spawner.wave;
    const phase_before = game.spawner.phase;
    enemy_spawn_sys.update(&game.spawner, &game.enemies, game.rng.random(), game.player.pos, &level.spawn_cells, field, grid, dt);
    waveEvents(&game.events, &game.spawner, wave_before, phase_before);

    //Ammo and health drops
    const lull = game.spawner.phase == .lull;
    const drop_interval = if (lull) consts.DROP_LULL_INTERVAL else consts.DROP_INTERVAL;
    const drop_large_chance = if (lull) consts.DROP_LULL_LARGE_CHANCE else consts.DROP_LARGE_CHANCE;
    drop_sys.update(&game.drops, game.rng.random(), game.player.pos, game.player.health, game.bullets.ammo, level.drop_cells, level.drop_sizes, grid, drop_interval, drop_large_chance, dt);

    //Character Movement. The flow field follows the player, a bounded slice of a rebuild per frame. The player picks up
    //the drops they walk over
    player_move_sys.update(&game.player, input, grid, dt);
    drop_sys.collect(&game.drops, &game.player, &game.bullets);
    game.drops.removeDead();
    flow_field.update(field, grid, grid.cellIndex(game.player.pos), consts.FLOW_FIELD_CELLS_PER_FRAME);
    enemy_move_sys.update(&game.enemies, field, grid, game.player.pos, dt);
    enemy_move_sys.separate(&game.enemies, game.player.pos, field, grid, frame_arena.alloc(Vec2f, game.enemies.len));

    //Move projectiles (walls stop them) and resolve bullet and melee hits on enemies (kills are flagged then compacted
    //out). Wounds spray blood and kills burst into gore
    bullet_sys.update(&game.bullets, grid, dt);
    const hits = bullet_sys.collide(&game.bullets, game.enemies.positions(), game.enemies.kind[0..game.enemies.len], frame_arena.alloc(state.Hit, game.bullets.len));
    const impacts = combat_sys.applyHits(hits, &game.enemies, &game.player, &game.popups, !game.story.active, frame_arena.alloc(state.Impact, hits.len));
    gore_sys.spawn(&game.gore, impacts, game.gore_rng.random());
    //Out of ammo, the player strikes the nearest enemies in reach instead
    const melee_hits = melee_sys.update(&game.melee, game.enemies.positions(), game.player.pos, game.bullets.ammo, dt, frame_arena.alloc(state.Hit, consts.MELEE_MAX_TARGETS));
    const melee_impacts = combat_sys.applyHits(melee_hits, &game.enemies, &game.player, &game.popups, !game.story.active, frame_arena.alloc(state.Impact, melee_hits.len));
    gore_sys.spawn(&game.gore, melee_impacts, game.gore_rng.random());
    game.bullets.removeDead();
    game.enemies.removeDead();

    //Enemies touching the player hurt them. Falling to low health is a story moment
    const health_before = game.player.health;
    combat_sys.applyEnemyContact(&game.enemies, &game.player, if (game.invincible) 0 else consts.CONTACT_DMG, &game.popups);
    if (health_before > consts.PLAYER_LOW_HEALTH and game.player.health <= consts.PLAYER_LOW_HEALTH) game.events.add(.{ .trigger = .low_health });
    if (game.player.health == 0) {
        game.player.hit_flash_timer = 0; //The run end screen shows the last frame, so don't leave it inverted
        return .player_died;
    }

    //Camera, trailing the player and leaning towards last frame's aim. Before targeting, as the gun only aims at
    //what is on screen
    camera_sys.update(&game.camera, game.player.pos, game.player.vel, game.player.facing_dir, dt);

    //Now that the enemy positions are final, aim at the best target the player can see and fire.
    //With nothing in sight aim the way the player is moving, or keep the last aim while standing still
    const move_dir = maths.normaliseSafe(game.player.vel, @splat(0));
    const target = auto_target_sys.findTarget(game.player.pos, move_dir, game.player.facing_dir, game.camera.pos, game.enemies.positions(), game.enemies.health[0..game.enemies.len], game.enemies.kind[0..game.enemies.len], grid, frame_arena.alloc(f32, game.enemies.len));
    const aim_dir = if (target) |t| t.dir else maths.normaliseSafe(move_dir, game.player.facing_dir);
    camera_sys.settleShake(&game.camera, dt);
    if (firing_sys.update(&game.trigger, input, dt)) {
        //A shot that went off kicks the view (from the gore rng: visual only)
        if (bullet_sys.fire(&game.bullets, game.player.pos, aim_dir, game.rng.random().float(f32) * 2 - 1)) {
            camera_sys.kick(&game.camera, aim_dir, game.gore_rng.random().float(f32) * 2 - 1);
        }
    }
    game.player.facing_dir = aim_dir; //Player faces the way they are firing
    game.player.target_pos = if (target) |t| t.pos else null;

    //Apply Effects
    game.player.hit_flash_timer = @max(game.player.hit_flash_timer - dt, 0);
    game.popups.update(dt);
    gore_sys.update(&game.gore, grid, dt);

    //Story: this frame's moments set off the chapter's lines. It is done once its last wave is cleared (after a
    //moment to see it was) or its walk is walked, and every line has been heard
    if (!game.story.active) return .playing;
    story_sys.update(&game.story, story.BEATS[game.story.beats.start..game.story.beats.end], game.events.slice(), dt);
    const done = switch (game.story.objective) {
        .survive => game.spawner.isLastWave() and game.spawner.phase == .lull and game.spawner.phase_time >= consts.CHAPTER_COMPLETE_DELAY,
        .walk => blk: {
            game.walk_left -= maths.magnitude(game.player.vel) * dt;
            break :blk game.walk_left <= 0;
        },
    };
    return if (done and game.story.lines.len == 0) .chapter_complete else .playing;
}

/// The story moments in the spawner's last update: a wave starting, and the one before it over (cleared, or run out
/// of time into the next), and the last wave of a chapter cleared
///
fn waveEvents(events: *state.StoryEvents, spawner: *const state.Spawner, wave_before: u16, phase_before: state.WavePhase) void {
    if (spawner.wave != wave_before) {
        if (phase_before == .wave) events.add(.{ .trigger = .wave_over, .wave = wave_before });
        events.add(.{ .trigger = .wave_started, .wave = spawner.wave });
    } else if (phase_before == .wave and spawner.phase == .lull) {
        events.add(.{ .trigger = .wave_over, .wave = spawner.wave });
        if (spawner.isLastWave()) events.add(.{ .trigger = .chapter_cleared });
    }
}

/// Start a fresh run at the level's `start_pos`: everything back to the start (the rngs and debug settings carry
/// on), the camera on the player, and the A/B press that started the run doesn't also fire
///
pub fn beginRun(game: *state.GameState, start_pos: Vec2f) void {
    game.reset();
    game.player.pos = start_pos;
    game.camera.pos = start_pos;
    game.trigger.button_cooldown = consts.RUN_START_FIRE_DELAY;
}

/// Start a story chapter: a fresh run that plays the chapter's waves and then stops spawning, or for a walk
/// chapter never spawns and has the player walk story.WALK_DIST. `beats` are its lines (story.chapterBeats; the
/// tests can give a chapter none)
///
pub fn beginChapter(game: *state.GameState, start_pos: Vec2f, chapter: story.Chapter, beats: story.BeatRange) void {
    beginRun(game, start_pos);
    game.story = .{ .active = true, .objective = chapter.objective, .beats = beats, .wave_offset = chapter.first_wave -| 1 };
    switch (chapter.objective) {
        .survive => {
            game.spawner.wave = chapter.first_wave - 1; //The lull counts down to the first
            game.spawner.last_wave = chapter.last_wave;
        },
        .walk => {
            game.spawner.timer = std.math.inf(f32);
            game.walk_left = story.WALK_DIST;
        },
    }
}

/// Whether the run that just ended beats the saved `best`. Debug invincibility is a cheat, so it never does
///
pub fn isNewBest(game: *const state.GameState, best: u64) bool {
    return game.player.score > best and !game.invincible;
}

test "[game] a run begins at the start point with nothing carried over but the rngs and debug settings" {
    var game = state.GameState{};
    game.player.score = 500;
    game.player.health = 1;
    game.bullets.ammo = 0;
    game.enemies.add(.{ 1, 1 });
    game.invincible = true;
    _ = game.rng.random().int(u32);
    const rng_next = game.rng;

    beginRun(&game, .{ 2, -3 });
    try std.testing.expect(game.player.score == 0 and game.player.health == consts.PLAYER_MAX_HEALTH);
    try std.testing.expect(game.bullets.ammo == consts.START_AMMO and game.enemies.len == 0);
    try std.testing.expect(@reduce(.And, game.player.pos == Vec2f{ 2, -3 }) and @reduce(.And, game.camera.pos == Vec2f{ 2, -3 }));
    try std.testing.expect(game.trigger.button_cooldown == consts.RUN_START_FIRE_DELAY);
    try std.testing.expect(game.invincible and !game.story.active);
    try std.testing.expect(std.meta.eql(game.rng, rng_next)); //The random sequence carries on
}

test "[game] only a higher score sets a new best, and never while invincible" {
    var game = state.GameState{};
    game.player.score = 100;
    try std.testing.expect(isNewBest(&game, 99));
    try std.testing.expect(!isNewBest(&game, 100));
    game.invincible = true;
    try std.testing.expect(!isNewBest(&game, 99));
}

test "[game] the run end screen ignores fire until its delay is up" {
    var over = state.RunEnd{ .new_best = false };
    const fire = state.Input{ .fire_pressed = true };
    try std.testing.expect(!over.update(fire, consts.GAME_OVER_INPUT_DELAY / 2));
    try std.testing.expect(!over.canRestart());
    try std.testing.expect(!over.update(.{}, consts.GAME_OVER_INPUT_DELAY)); //Can restart now, but no press
    try std.testing.expect(over.canRestart());
    try std.testing.expect(over.update(fire, consts.TARGET_FRAME_DT));
}
