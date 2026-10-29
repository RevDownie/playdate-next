const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const pd = @import("playdate.zig").api;
const consts = @import("tweak_constants.zig");
const maths = @import("maths.zig");
const state = @import("game_state.zig");
const game = @import("game.zig");
const renderer = @import("renderer.zig");
const level_loader = @import("level_loader.zig");
const save_data = @import("save_data.zig");
const FlowField = @import("flow_field.zig").FlowField;
const enemy_separation_sys = @import("enemy_separation_system.zig");
const memory = @import("memory.zig");
const Arena = memory.Arena;

// Platform layer: owns all memory and state, talks to the Playdate API, and each frame turns its input into
// a `state.Input`, ticks the game and renders it. Control flows one way: main -> game -> systems.

/// Memory. Everything is carved from one static buffer up front; nothing is allocated from the heap.
/// app (whole run) -> level (reset when a level loads) and frame (reset at the start of every frame)
const APP_MEMORY_SIZE = 256 * 1024;
const LEVEL_ARENA_SIZE = 64 * 1024;
const FRAME_ARENA_SIZE = 64 * 1024;
var app_memory: [APP_MEMORY_SIZE]u8 = undefined;
var app_arena: Arena = undefined;
var level_arena: Arena = undefined;
var frame_arena: Arena = undefined;

/// Core data
var playdate_api: *pd.PlaydateAPI = undefined;
var assets: renderer.Assets = undefined;
var level: level_loader.Level = undefined;
var flow_field: FlowField = undefined; //The enemies' path to the player, sized to the level
var game_state: state.GameState = .{};
var save: save_data.SaveData = .{}; //Read once at init, written when a run ends with a new best

/// The simulation only ticks while playing. When the player dies the last frame stays up under the run end
/// screen until they choose to go again
const Phase = enum { playing, game_over };
var phase: Phase = .playing;
var game_over_time: f32 = 0; //Seconds on the run end screen
var new_best = false; //The run that just ended beat the saved best

/// Frame timing and requests from outside the frame loop
var time_last_tick_ms: u32 = 0;
var restart_requested = false;
var invincible_menu_item: ?*pd.PDMenuItem = null; //Debug builds only

/// Debug logging
const debug_logging = builtin.mode == .debug;
var last_log_time_ms: u32 = 0;
var last_render_stats: renderer.RenderStats = .{ .drawn = 0 };
var sim_ms_max: f32 = 0; //Slowest game.tick since the last status line

/// Exposed via the shared library to the Playdate runner which forwards on events
///
pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.c) c_int {
    switch (event) {
        pd.kEventInit => gameInit(playdate),
        //Don't count the time spent paused or in the menu as a frame
        pd.kEventResume, pd.kEventUnlock => resetFrameTimer(),
        else => {},
    }
    return 0;
}

/// Upfront setup - carves out the memory arenas and loads all assets
///
fn gameInit(playdate: [*c]pd.PlaydateAPI) void {
    playdate_api = playdate;
    const sys = playdate_api.system.*;
    if (debug_logging) {
        //Start each run with a fresh log file
        if (playdate_api.file.*.open.?("log.txt", pd.kFileWrite)) |h| _ = playdate_api.file.*.close.?(h);
    }

    app_arena = Arena.init("app", &app_memory);
    level_arena = app_arena.subArena("level", LEVEL_ARENA_SIZE);
    frame_arena = app_arena.subArena("frame", FRAME_ARENA_SIZE);

    sys.setUpdateCallback.?(gameUpdateWrapper, null);
    _ = sys.addMenuItem.?("Restart Level", restartLevel, null);
    if (builtin.mode == .debug) {
        //Debug only: `zig build -Dinvincible` (or `tools/sim.ps1 -Invincible`) starts with it ticked
        game_state.invincible = build_options.invincible;
        invincible_menu_item = sys.addCheckmarkMenuItem.?("Invincible", @intFromBool(game_state.invincible), toggleInvincible, null);
    }

    playdate_api.display.*.setRefreshRate.?(0);

    //TODO: Decide if we change level on restart and also decide if we have shared bitmap atlas
    loadLevel("lvl1.bin");
    assets = renderer.loadAssets(playdate_api, "lvl1");

    save = readSave();
    startRun();
    resetFrameTimer();
    debugLog("init complete: level arena {d}/{d} bytes, L1 hot set budget {d} bytes (collision {d}, separation {d}, flow field {d}, bullet walls {d}, {d} per sprite drawn), {d} spawn cells", .{ level_arena.used(), level_arena.capacity(), memory.HOT_SET_BUDGET, state.COLLISION_HOT_SET_BYTES, enemy_separation_sys.SEPARATION_HOT_SET_BYTES, flow_field.hotSetBytes(), level.collision_grid.cells.len, renderer.BYTES_PER_DRAW_ITEM, level.spawn_cells.all.len });
    if (flow_field.hotSetBytes() > memory.HOT_SET_BUDGET) debugLog("WARNING: flow field ({d} bytes) is larger than the L1 hot set budget, enemy movement will miss the cache", .{flow_field.hotSetBytes()});
    if (level.collision_grid.cells.len > memory.HOT_SET_BUDGET) debugLog("WARNING: collision grid ({d} bytes) is larger than the L1 hot set budget, bullet wall tests will miss the cache", .{level.collision_grid.cells.len});
}

/// Replace the current level, releasing everything the previous one allocated
///
fn loadLevel(file_name: [*:0]const u8) void {
    level_arena.reset();
    level = level_loader.load(playdate_api, file_name, &level_arena) catch |err| std.debug.panic("loadLevel: {s}", .{@errorName(err)});
    flow_field = FlowField.init(&level_arena, &level.collision_grid, level.collision_grid.cellIndex(game_state.player.pos));
}

/// Start a fresh run (also leaves the run end screen)
///
fn startRun() void {
    game_state.reset();
    game_state.trigger.button_cooldown = consts.FIRE_BUTTON_DELAY; //The A/B press that starts the run doesn't also fire
    phase = .playing;
    new_best = false;
}

/// The player died: freeze on the run end screen, and save the score if it is a new best (the one file write
/// in the frame loop, once per run)
///
fn endRun() void {
    phase = .game_over;
    game_over_time = 0;
    const p = game_state.player;
    //Debug invincibility is a cheat, so it never sets a best
    new_best = p.score > save.best_score and !game_state.invincible;
    if (new_best) {
        save.best_score = p.score;
        writeSave(save);
    }
    debugLog("run over: wave={d} score={d} best={d} new_best={} time={d:.1}s kills={d} best_streak={d}", .{ game_state.spawner.wave, p.score, save.best_score, new_best, game_state.run_time, p.kills, p.best_streak });
}

/// The saved best, or a fresh save if there is none yet (or it can't be read)
///
fn readSave() save_data.SaveData {
    const file = playdate_api.file.*;
    const handle = file.open.?(save_data.FILE_NAME, pd.kFileReadData) orelse return .{};
    defer _ = file.close.?(handle);
    var bytes: [save_data.SIZE]u8 = undefined;
    const n = file.read.?(handle, &bytes, bytes.len);
    if (n != bytes.len) return .{};
    return save_data.decode(&bytes);
}

fn writeSave(data: save_data.SaveData) void {
    const file = playdate_api.file.*;
    const handle = file.open.?(save_data.FILE_NAME, pd.kFileWrite) orelse {
        debugLog("WARNING: couldn't open {s} to save the best score", .{save_data.FILE_NAME});
        return;
    };
    defer _ = file.close.?(handle);
    const bytes = save_data.encode(data);
    if (file.write.?(handle, &bytes, bytes.len) != bytes.len) debugLog("WARNING: couldn't write {s}", .{save_data.FILE_NAME});
}

/// Called from the system menu by the user if they want to restart. Handled at the start of the next frame
///
fn restartLevel(_: ?*anyopaque) callconv(.c) void {
    restart_requested = true;
}

/// Debug system menu checkmark: read back its state, so enemies stop (or start) hurting the player
///
fn toggleInvincible(_: ?*anyopaque) callconv(.c) void {
    game_state.invincible = playdate_api.system.*.getMenuItemValue.?(invincible_menu_item) != 0;
}

fn resetFrameTimer() void {
    time_last_tick_ms = playdate_api.system.*.getCurrentTimeMilliseconds.?();
}

/// Ticks the main game update and render once per frame
///
fn gameUpdateWrapper(_: ?*anyopaque) callconv(.c) c_int {
    const sys = playdate_api.system.*;
    frame_arena.reset();

    if (restart_requested) {
        restart_requested = false;
        startRun();
    }

    const now_ms = sys.getCurrentTimeMilliseconds.?();
    const dt = @min(@as(f32, @floatFromInt(now_ms -% time_last_tick_ms)) * 0.001, consts.MAX_FRAME_DT);
    time_last_tick_ms = now_ms;

    const input = readInput();
    switch (phase) {
        .playing => {
            if (debug_logging) sys.resetElapsedTime.?();
            const result = game.tick(&game_state, &level, &flow_field, input, dt, &frame_arena);
            if (debug_logging) sim_ms_max = @max(sim_ms_max, sys.getElapsedTime.?() * 1000);
            if (result == .player_died) endRun();
        },
        .game_over => {
            //A short pause first, so a player still hammering fire doesn't skip the screen
            game_over_time += dt;
            if (game_over_time >= consts.GAME_OVER_INPUT_DELAY and input.fire_pressed) startRun();
        },
    }
    const hud = renderer.Hud{
        .best_score = save.best_score,
        .game_over = if (phase == .game_over) .{ .new_best = new_best, .can_restart = game_over_time >= consts.GAME_OVER_INPUT_DELAY, .time = game_over_time } else null,
    };
    last_render_stats = renderer.render(playdate_api, &assets, &game_state, &level, hud, &frame_arena);

    logStatus(now_ms);
    return 1; //Inform the SDK we have stuff to render
}

/// Snapshot this frame's buttons and crank
///
fn readInput() state.Input {
    const sys = playdate_api.system.*;
    var current: pd.PDButtons = undefined;
    var pushed: pd.PDButtons = undefined;
    var released: pd.PDButtons = undefined;
    sys.getButtonState.?(&current, &pushed, &released);

    return .{
        .left = (current & pd.kButtonLeft) != 0,
        .right = (current & pd.kButtonRight) != 0,
        .up = (current & pd.kButtonUp) != 0,
        .down = (current & pd.kButtonDown) != 0,
        .fire_held = (current & (pd.kButtonA | pd.kButtonB)) != 0,
        .fire_pressed = (pushed & (pd.kButtonA | pd.kButtonB)) != 0,
        .crank_delta = sys.getCrankChange.?(),
    };
}

/// Once a second write a status line so a run can be inspected from the logs
///
fn logStatus(now_ms: u32) void {
    if (!debug_logging or now_ms -% last_log_time_ms < 1000) return;
    last_log_time_ms = now_ms;

    const p = game_state.player;
    //The nearest drop, so a scripted run can walk to it
    const drops = &game_state.drops;
    var near: usize = 0;
    for (drops.positions(), 0..) |d, i| {
        if (maths.magnitudeSqrd(d - p.pos) < maths.magnitudeSqrd(drops.pos[near] - p.pos)) near = i;
    }
    const near_pos = if (drops.len > 0) drops.pos[near] else p.pos;
    //Enemies in view: what the player actually sees of a wave
    var on_screen: u32 = 0;
    for (game_state.enemies.positions()) |e| {
        const d = e - game_state.camera_pos;
        if (@abs(d[0]) < consts.VIEW_HALF_WIDTH and @abs(d[1]) < consts.VIEW_HALF_HEIGHT) on_screen += 1;
    }
    debugLog("t={d}ms wave={d}:{s} enemies={d} on_screen={d} health={d} score={d} combo={d} pos=({d:.2},{d:.2}) bullets={d} reload={d:.1} drops={d} invincible={} near={s}({d:.2},{d:.2}) aim=({d:.2},{d:.2}) target={s} crank={d:.1} frame_mem={d} drawn={d} gibs={d} droplets={d} splats={d} sim_ms_max={d:.2}", .{ now_ms, game_state.spawner.wave, @tagName(game_state.spawner.phase), game_state.enemies.len, on_screen, p.health, p.score, p.kill_streak, p.pos[0], p.pos[1], game_state.bullets.ammo, @max(game_state.bullets.reload_timer, 0), drops.len, game_state.invincible, if (drops.len > 0) @tagName(drops.kind[near]) else "none", near_pos[0], near_pos[1], p.facing_dir[0], p.facing_dir[1], if (p.target_pos != null) "yes" else "no", playdate_api.system.*.getCrankAngle.?(), frame_arena.high_water, last_render_stats.drawn, game_state.gore.gibs.liveCount(), game_state.gore.droplets.liveCount(), game_state.gore.pools.liveCount() + game_state.gore.spatters.liveCount(), sim_ms_max });
    sim_ms_max = 0;
}

/// Debug builds only: write to the Playdate console and append to `log.txt` in the game's data folder.
/// In the simulator that is `<PlaydateSDK>/Disk/Data/<bundleID>/log.txt`
///
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_logging) return;

    var buf: [384]u8 = undefined;
    const msg = std.mem.printSentinel(&buf, "until-none: " ++ fmt, args, 0) catch return;
    playdate_api.system.*.logToConsole.?("%s", msg.ptr);

    const file = playdate_api.file.*;
    const handle = file.open.?("log.txt", pd.kFileAppend) orelse return;
    defer _ = file.close.?(handle);
    _ = file.write.?(handle, msg.ptr, @intCast(msg.len));
    _ = file.write.?(handle, "\n", 1);
}
