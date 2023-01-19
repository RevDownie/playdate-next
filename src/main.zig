const std = @import("std");
const pd = @import("playdate.zig").api;
const sparse_array = @import("sparse_array.zig");
const graphics_coords = @import("graphics_coords.zig");
const maths = @import("maths.zig");
const bullet_sys = @import("bullet_system.zig");
const anim = @import("animation.zig");
const enemy_move_sys = @import("enemy_movement_system.zig");
const enemy_spawn_sys = @import("enemy_spawn_system.zig");
const auto_target_sys = @import("auto_targetting_system.zig");
const player_move_sys = @import("player_movement_system.zig");
const consts = @import("tweak_constants.zig");

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);
const SparseArray = sparse_array.SparseArray;

/// Common game state
var playdate_api: *pd.PlaydateAPI = undefined;
var camera_pos = Vec2f{ 0, 0 };
var time_last_tick: u32 = undefined;

/// Assets
var bg_bitmap: *pd.LCDBitmap = undefined;
var hero_bitmap_table: *pd.LCDBitmapTable = undefined;
var enemy_bitmap_table: *pd.LCDBitmapTable = undefined;

/// Player
var player_world_pos: Vec2f = undefined;
var player_velocity: Vec2f = undefined;
var player_facing_dir: Vec2f = undefined;
var player_health: u8 = undefined;
var player_score: u64 = undefined;

/// Enemy entities
var entity_memory: [1024 * 1024]u8 = undefined;
var enemy_world_positions: SparseArray(Vec2f, u8) = undefined;
var enemy_velocities: SparseArray(Vec2f, u8) = undefined;
var enemy_healths: SparseArray(u8, u8) = undefined;
var enemy_free_id_stack: [consts.MAX_ENEMIES]u8 = undefined;
var enemy_free_id_head: u32 = undefined;
var bullet_collision_info: [consts.MAX_ENEMIES]bullet_sys.CollisionInfo = undefined;
var enemy_collision_info: [consts.MAX_ENEMIES]u8 = undefined;

/// Exposed via the shared library to the Playdate runner which forwards on events
///
pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.C) c_int {
    switch (event) {
        pd.kEventInit => gameInit(playdate),
        else => {},
    }
    return 0;
}

/// A stack of ids that can be pushed and popped when entities are created or destroyed
///
fn createEnemyIds() [consts.MAX_ENEMIES]u8 {
    var id_stack: [consts.MAX_ENEMIES]u8 = undefined;
    var i: u8 = 0;
    while (i < consts.MAX_ENEMIES) : (i += 1) {
        id_stack[i] = consts.MAX_ENEMIES - i - 1;
    }

    return id_stack;
}

/// Upfront setup - allocates all the memory required and loads and initialises all assets and pools
///
fn gameInit(playdate: [*c]pd.PlaydateAPI) void {
    playdate_api = playdate;
    const sys = playdate_api.system.*;
    const graphics = playdate_api.graphics.*;

    sys.setUpdateCallback.?(gameUpdateWrapper, null);
    _ = sys.addMenuItem.?("Restart Level", restartLevel, null);

    playdate_api.display.*.setRefreshRate.?(0); //Temp unleashing the frame limit to measure performance

    //Load the assets
    bg_bitmap = graphics.loadBitmap.?("bg", null).?;
    hero_bitmap_table = graphics.loadBitmapTable.?("hero1", null).?;
    enemy_bitmap_table = graphics.loadBitmapTable.?("enemy1", null).?;

    //Create the entity pools
    var fba = std.heap.FixedBufferAllocator.init(&entity_memory);
    //TODO: No point having multiple lookups when they are shared across all arrays
    enemy_world_positions = SparseArray(Vec2f, u8).init(consts.MAX_ENEMIES, fba.allocator()) catch @panic("init: Failed to init enemy pos");
    enemy_velocities = SparseArray(Vec2f, u8).init(consts.MAX_ENEMIES, fba.allocator()) catch @panic("init: Failed to init enemy vels");
    enemy_healths = SparseArray(u8, u8).init(consts.MAX_ENEMIES, fba.allocator()) catch @panic("init: Failed to init enemy healths");

    //Init the systems
    enemy_spawn_sys.init(consts.MAX_ENEMIES);
    enemy_move_sys.init(consts.MAX_ENEMIES, fba.allocator()) catch @panic("reinit: Failed to init enemy move sys");

    time_last_tick = sys.getCurrentTimeMilliseconds.?();
    reset();
}

/// Called from the system menu by the user if they want to restart
///
fn restartLevel(_: ?*anyopaque) callconv(.C) void {
    reset();
}

/// Reinit this on game restart
///
fn reset() void {
    player_world_pos = @splat(2, @as(f32, 0));
    player_velocity = @splat(2, @as(f32, 0));
    player_facing_dir = @splat(2, @as(f32, 0));
    player_health = 100;
    player_score = 0;

    camera_pos = @splat(2, @as(f32, 0));

    enemy_spawn_sys.reset();
    enemy_move_sys.reset();
    bullet_sys.reset();

    enemy_world_positions.clear();
    enemy_velocities.clear();
    enemy_healths.clear();

    enemy_free_id_stack = createEnemyIds();
    enemy_free_id_head = consts.MAX_ENEMIES - 1;
}

/// Ticks the main game update and render loops
///
fn gameUpdateWrapper(_: ?*anyopaque) callconv(.C) c_int {
    update();
    render();
    return 1; //Inform the SDK we have stuff to render
}

/// The main update loop that drives the various systems
///
fn update() void {
    const sys = playdate_api.system.*;

    const time_this_tick = sys.getCurrentTimeMilliseconds.?();
    const dt = @intToFloat(f32, time_this_tick - time_last_tick) * 0.001;
    time_last_tick = time_this_tick;

    var current: pd.PDButtons = undefined;
    var pushed: pd.PDButtons = undefined;
    var released: pd.PDButtons = undefined;
    sys.getButtonState.?(&current, &pushed, &released);

    //Spawn any new enemies
    const spawned = enemy_spawn_sys.update(dt, enemy_world_positions.len, player_world_pos);
    for (spawned) |s| {
        const ent_id = enemy_free_id_stack[enemy_free_id_head];
        enemy_free_id_head -= 1;

        enemy_world_positions.insertFirst(ent_id, s.world_pos) catch @panic("spawn: Failed to insert pos");
        enemy_velocities.insertFirst(ent_id, Vec2f{ 0, 0 }) catch @panic("spawn: Failed to insert vel");
        enemy_healths.insertFirst(ent_id, 100) catch @panic("spawn: Failed to insert health");
        enemy_move_sys.startSeeking(ent_id) catch @panic("spawn: Failed to start seeking");
    }

    //Move the player based on input and move any enemies that are in the seeking or bumping back state
    player_move_sys.update(current, dt, &player_world_pos, &player_velocity);
    enemy_move_sys.update(player_world_pos, dt, enemy_world_positions, enemy_velocities) catch @panic("enemyMove: Update error");

    //Move any fired projectiles and check for collisions
    var num_hits: u8 = 0;
    bullet_sys.update(dt, enemy_world_positions, bullet_collision_info[0..], &num_hits) catch @panic("bulletSys: Update error");

    //Apply any bullet -> Enemy collisions that push the enemy back, deduct health and ultimately destroy
    for (bullet_collision_info[0..num_hits]) |info| {
        if (enemy_healths.tryLookup(info.entity_id)) |current_health| {
            if (current_health <= consts.DMG_PER_HIT) {
                //Enemy is dead - TODO: Graceful death and not just dissappear
                enemy_world_positions.remove(info.entity_id) catch @panic("enemyDestroy: Failed to remove pos");
                enemy_velocities.remove(info.entity_id) catch @panic("enemyDestroy: Failed to remove vel");
                enemy_healths.remove(info.entity_id) catch @panic("enemyDestroy: Failed to remove health");
                enemy_move_sys.remove(info.entity_id) catch @panic("enemyDestroy: Failed to remove from move sys");
                player_score = std.math.min(player_score + 10, consts.MAX_SCORE); //TODO add score streak based on not being hit

                enemy_free_id_head += 1;
                enemy_free_id_stack[enemy_free_id_head] = info.entity_id;
            } else {
                const new_health = current_health - consts.DMG_PER_HIT;
                enemy_healths.insert(info.entity_id, new_health) catch @panic("enemyHit: Failed to update health");
                const pos = enemy_world_positions.lookup(info.entity_id) catch @panic("enemyHit: failed to find pos");
                enemy_move_sys.startBumpBack(info.entity_id, pos, info.impact_dir) catch @panic("enemyHit: Failed to bump back");
            }
        }
    }

    //Check for collisions with enemies and player and deduct damage
    var num_hits_on_player: u8 = undefined;
    checkPlayerCollision(player_world_pos, enemy_world_positions, enemy_collision_info[0..], &num_hits_on_player) catch @panic("playerCollision: Failed collision check");
    const deduct_health = std.math.min(num_hits_on_player * 5, player_health);
    player_health -= deduct_health;
    if (player_health == 0) {
        reset();
        return;
    }
    for (enemy_collision_info[0..num_hits_on_player]) |enemy_id| {
        const pos = enemy_world_positions.lookup(enemy_id) catch @panic("playerHit: failed to find pos");
        const vel = enemy_velocities.lookup(enemy_id) catch @panic("playerHit: failed to find vel");
        enemy_move_sys.startBumpBack(enemy_id, pos, vel * @splat(2, @as(f32, -1))) catch @panic("playerHit: Failed to bump back");
    }

    //Now that the enemy positions have been updated - the player can re-evaluate the hottest one to target
    const target_dir = auto_target_sys.calculateHottestTargetDir(player_world_pos, enemy_world_positions.toDataSlice()) orelse if (maths.magnitudeSqrd(player_velocity) > 0) player_velocity else Vec2f{ 1, 0 };

    //Fire
    const should_fire = firingSystemUpdate(pushed, sys);
    if (should_fire) {
        bullet_sys.fire(player_world_pos, target_dir);
    }

    camera_pos = player_world_pos; //Follow the player directly for now
    player_facing_dir = target_dir; //Player facing the way they are firing
}

/// Perform the transformations from world to screen space and render the bitmaps
///
fn render() void {
    const sys = playdate_api.system.*;
    const disp = playdate_api.display.*;
    const graphics = playdate_api.graphics.*;

    const dispWidth = disp.getWidth.?();
    const dispHeight = disp.getHeight.?();

    graphics.clear.?(pd.kColorWhite);

    //---Render the BG
    const bg_world_pos = [_]Vec2f{Vec2f{ 0, 0 }};
    var bg_screen_pos: [1]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, bg_world_pos[0..], bg_screen_pos[0..], dispWidth, dispHeight);
    graphics.tileBitmap.?(bg_bitmap, bg_screen_pos[0][0] - 1000, bg_screen_pos[0][1] - 1000, 2000, 2000, pd.kBitmapUnflipped);

    //---Render the player
    const player_world_pos_tmp = [_]Vec2f{player_world_pos};
    var player_screen_pos: [1]Vec2i = undefined;
    const player_bitmap_frame = anim.bitmapFrameForDir(player_facing_dir);
    graphics_coords.worldSpaceToScreenSpace(camera_pos, player_world_pos_tmp[0..], player_screen_pos[0..], dispWidth, dispHeight);
    graphics.drawBitmap.?(graphics.getTableBitmap.?(hero_bitmap_table, player_bitmap_frame.index).?, player_screen_pos[0][0] - 32, player_screen_pos[0][1] - 64, player_bitmap_frame.flip);

    //---Render the enemies
    var enemy_screen_pos: [consts.MAX_ENEMIES]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, enemy_world_positions.toDataSlice(), enemy_screen_pos[0..], dispWidth, dispHeight);

    //TODO: Interpolation
    //Enemies facing the way they are moving
    var enemy_bitmap_frames: [consts.MAX_ENEMIES]anim.BitmapFrame = undefined;
    for (enemy_velocities.toDataSlice()) |v, idx| {
        const id = enemy_velocities.lookupKeyByIndex(idx) catch @panic("render: Failed to find enemy velocity to determine facing dir");
        enemy_bitmap_frames[id] = anim.bitmapFrameForDir(v);
    }

    for (enemy_world_positions.toDataSlice()) |_, i| {
        //TODO Culling (in a pass or just in time?)
        //TODO: Handle centering the sprite at the ground better
        graphics.drawBitmap.?(graphics.getTableBitmap.?(enemy_bitmap_table, enemy_bitmap_frames[i].index).?, enemy_screen_pos[i][0] - 32, enemy_screen_pos[i][1] - 64, enemy_bitmap_frames[i].flip);
    }

    bullet_sys.render(graphics, disp, camera_pos);

    sys.drawFPS.?(0, 0);

    //TODO: Replace with bitmap font
    var score_buffer: ["Score: ".len + 10]u8 = undefined;
    const score_string = std.fmt.bufPrint(&score_buffer, "Score: {d}", .{player_score}) catch @panic("scorePrint: Failed to format");
    _ = graphics.drawText.?(score_string.ptr, score_string.len, pd.kASCIIEncoding, dispWidth - 100, 0);

    var health_buffer: ["Health: ".len + 3]u8 = undefined;
    const health_string = std.fmt.bufPrint(&health_buffer, "Health: {d}", .{player_health}) catch @panic("healthPrint: Failed to format");
    _ = graphics.drawText.?(health_string.ptr, health_string.len, pd.kASCIIEncoding, @divTrunc(dispWidth, 2), 0);

    var bullet_buffer: ["Bullets: ".len + 3]u8 = undefined;
    const bullet_string = std.fmt.bufPrint(&bullet_buffer, "Bullets: {d}", .{bullet_sys.getRemainingBullets()}) catch @panic("bulletPrint: Failed to format");
    _ = graphics.drawText.?(bullet_string.ptr, bullet_string.len, pd.kASCIIEncoding, @divTrunc(dispWidth, 2), dispHeight - 30);
}

/// Fire everytime the crank moves through 60 degrees (6 bullets per revolution)
///
var crank_angle_since_fire: f32 = 0.0;
fn firingSystemUpdate(pushed: pd.PDButtons, sys: pd.playdate_sys) bool {
    if ((pushed & pd.kButtonB) > 0) {
        return true;
    }

    const crank_delta = sys.getCrankChange.?();
    if (crank_delta >= 0) {
        crank_angle_since_fire += crank_delta;
        if (crank_angle_since_fire >= consts.FIRE_ANGLE_DELTA) {
            //Fire
            crank_angle_since_fire -= consts.FIRE_ANGLE_DELTA;
            return true;
        }
    }

    return false;
}

/// Check number of collisions between enemies and player
///
fn checkPlayerCollision(player_pos: Vec2f, enemy_positions: SparseArray(Vec2f, u8), collision_data: []u8, num_collisions: *u8) !void {
    num_collisions.* = 0;

    for (enemy_positions.toDataSlice()) |enemy_pos, enemy_idx| {
        const delta = enemy_pos - player_pos;
        if (maths.magnitudeSqrd(delta) <= 0.5 * 0.5) {
            collision_data[num_collisions.*] = try enemy_positions.lookupKeyByIndex(enemy_idx);
            num_collisions.* += 1;
        }
    }
}
