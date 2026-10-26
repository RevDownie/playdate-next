const std = @import("std");
const builtin = @import("builtin");
const pd = @import("playdate.zig").api;
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const game = @import("game.zig");
const renderer = @import("renderer.zig");
const level_loader = @import("level_loader.zig");
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

/// Frame timing and requests from outside the frame loop
var time_last_tick_ms: u32 = 0;
var restart_requested = false;

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

    playdate_api.display.*.setRefreshRate.?(0);

    //TODO: Decide if we change level on restart and also decide if we have shared bitmap atlas
    loadLevel("lvl1.bin");
    assets = renderer.loadAssets(playdate_api, "lvl1");

    game_state.reset();
    resetFrameTimer();
    debugLog("init complete: level arena {d}/{d} bytes, L1 hot set budget {d} bytes (collision {d}, separation {d}, flow field {d}, bullet walls {d}, {d} per sprite drawn), {d} spawn cells", .{ level_arena.used(), level_arena.capacity(), memory.HOT_SET_BUDGET, state.COLLISION_HOT_SET_BYTES, enemy_separation_sys.SEPARATION_HOT_SET_BYTES, flow_field.hotSetBytes(), level.collision_grid.cells.len, renderer.BYTES_PER_DRAW_ITEM, level.spawn_cells.len });
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

/// Called from the system menu by the user if they want to restart. Handled at the start of the next frame
///
fn restartLevel(_: ?*anyopaque) callconv(.c) void {
    restart_requested = true;
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
        game_state.reset();
    }

    const now_ms = sys.getCurrentTimeMilliseconds.?();
    const dt = @min(@as(f32, @floatFromInt(now_ms -% time_last_tick_ms)) * 0.001, consts.MAX_FRAME_DT);
    time_last_tick_ms = now_ms;

    if (debug_logging) sys.resetElapsedTime.?();
    const result = game.tick(&game_state, &level, &flow_field, readInput(), dt, &frame_arena);
    if (debug_logging) sim_ms_max = @max(sim_ms_max, sys.getElapsedTime.?() * 1000);
    if (result == .player_died) {
        game_state.reset();
    }
    last_render_stats = renderer.render(playdate_api, &assets, &game_state, &level, &frame_arena);

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
        .crank_delta = sys.getCrankChange.?(),
    };
}

/// Once a second write a status line so a run can be inspected from the logs
///
fn logStatus(now_ms: u32) void {
    if (!debug_logging or now_ms -% last_log_time_ms < 1000) return;
    last_log_time_ms = now_ms;

    const p = game_state.player;
    debugLog("t={d}ms enemies={d} health={d} score={d} pos=({d:.2},{d:.2}) bullets={d} crank={d:.1} frame_mem={d} drawn={d} sim_ms_max={d:.2}", .{ now_ms, game_state.enemies.len, p.health, p.score, p.pos[0], p.pos[1], game_state.bullets.magazine, playdate_api.system.*.getCrankAngle.?(), frame_arena.high_water, last_render_stats.drawn, sim_ms_max });
    sim_ms_max = 0;
}

/// Debug builds only: write to the Playdate console and append to `log.txt` in the game's data folder.
/// In the simulator that is `<PlaydateSDK>/Disk/Data/<bundleID>/log.txt`
///
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_logging) return;

    var buf: [256]u8 = undefined;
    const msg = std.mem.printSentinel(&buf, "until-none: " ++ fmt, args, 0) catch return;
    playdate_api.system.*.logToConsole.?("%s", msg.ptr);

    const file = playdate_api.file.*;
    const handle = file.open.?("log.txt", pd.kFileAppend) orelse return;
    defer _ = file.close.?(handle);
    _ = file.write.?(handle, msg.ptr, @intCast(msg.len));
    _ = file.write.?(handle, "\n", 1);
}
