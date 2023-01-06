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

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);
const SparseArray = sparse_array.SparseArray;

/// Game constants
const MAX_ENTITIES: u8 = 100;
const PLAYER_ACC: f32 = 1.0;
const PLAYER_MAX_SPEED: f32 = 1.5;
const FIRE_ANGLE_DELTA: f32 = 60;

/// Common game state
var playdate_api: *pd.PlaydateAPI = undefined;
var camera_pos = Vec2f{ 0, 0 };

/// Assets
var bg_bitmap: *pd.LCDBitmap = undefined;
var hero_bitmap_table: *pd.LCDBitmapTable = undefined;

/// Entities
var entity_memory: [1024 * 1024]u8 = undefined;
var entity_world_positions: SparseArray(Vec2f, u8) = undefined;
var entity_velocities: SparseArray(Vec2f, u8) = undefined;
var entity_next_free_id: u8 = 1; //TODO: Turn into a stack/queue so we can recycle them

/// Exposed via the shared library to the Playdate runner which forwards on events
///
pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.C) c_int {
    switch (event) {
        pd.kEventInit => gameInit(playdate) catch unreachable,
        else => {},
    }
    return 0;
}

/// Upfront setup - allocates all the memory required and loads and initialises all assets and pools
///
fn gameInit(playdate: [*c]pd.PlaydateAPI) !void {
    playdate_api = playdate;
    playdate_api.system.*.setUpdateCallback.?(gameUpdate, null);

    const graphics = playdate_api.graphics.*;
    playdate_api.display.*.setRefreshRate.?(0); //Temp unleashing the frame limit to measure performance

    //Load the assets
    bg_bitmap = graphics.loadBitmap.?("bg", null).?;
    hero_bitmap_table = graphics.loadBitmapTable.?("hero1", null).?;

    //Create the entity pools - player is always ID 0
    var fba = std.heap.FixedBufferAllocator.init(&entity_memory);

    //TODO: No point having multiple lookups when they are shared across all arrays
    entity_world_positions = try SparseArray(Vec2f, u8).init(MAX_ENTITIES, fba.allocator());
    try entity_world_positions.insert(0, Vec2f{ 0, 0 });

    entity_velocities = try SparseArray(Vec2f, u8).init(MAX_ENTITIES, fba.allocator());
    try entity_velocities.insertFirst(0, Vec2f{ 0, 0 });

    //Init the systems
    enemy_spawn_sys.init(MAX_ENTITIES);
    try enemy_move_sys.init(MAX_ENTITIES, fba.allocator());
}

/// The main game update loop that drives the various systems. Also acts as the render loop
///
fn gameUpdate(_: ?*anyopaque) callconv(.C) c_int {
    const graphics = playdate_api.graphics.*;
    const sys = playdate_api.system.*;
    const disp = playdate_api.display.*;

    const dt: f32 = 0.02; //TODO figure out how to derive this

    graphics.clear.?(pd.kColorWhite);

    var current: pd.PDButtons = undefined;
    var pushed: pd.PDButtons = undefined;
    var released: pd.PDButtons = undefined;
    sys.getButtonState.?(&current, &pushed, &released);

    //Spawn any new enemies
    const spawned = enemy_spawn_sys.update(dt, entity_world_positions.len);
    for (spawned) |s| {
        entity_world_positions.insertFirst(entity_next_free_id, s.world_pos) catch @panic("Failed to spawn");
        entity_velocities.insertFirst(entity_next_free_id, Vec2f{ 0, 0 }) catch @panic("Failed to spawn");
        enemy_move_sys.startSeeking(entity_next_free_id) catch @panic("Failed to spawn");
        entity_next_free_id += 1;
    }

    if ((current & pd.kButtonA) > 0) {
        //Test the bump back
        const p = entity_world_positions.lookup(1) catch unreachable;
        enemy_move_sys.startBumpBack(1, p, Vec2f{ -1, 0 }) catch unreachable;
    }

    //Move the player based on input
    playerMovementSystemUpdate(current, dt, &entity_world_positions.data[0], &entity_velocities.data[0]);

    //Move any enemies that are in the seeking or bumping back state
    enemy_move_sys.update(entity_world_positions.data[0], dt, entity_world_positions, entity_velocities) catch @panic("Enemy movement system issue");

    //Now that the enemy positions have been updated - the player can re-evaluate the hottest one to target
    const target_dir = auto_target_sys.calculateHottestTargetDir(entity_world_positions.data[0], entity_world_positions.toDataSlice()) orelse entity_velocities.data[0];

    //Move any fired projectiles
    bullet_sys.update(dt);

    const should_fire = firingSystemUpdate(sys);
    if (should_fire) {
        bullet_sys.fire(entity_world_positions.data[0], target_dir);
    }

    camera_pos = entity_world_positions.data[0]; //Follow the player directly for now

    //---Render the BG
    const bg_world_pos = [_]Vec2f{Vec2f{ 0, 0 }};
    var bg_screen_pos: [1]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, bg_world_pos[0..], bg_screen_pos[0..], disp.getWidth.?(), disp.getHeight.?());
    graphics.tileBitmap.?(bg_bitmap, bg_screen_pos[0][0] - 200, bg_screen_pos[0][1] - 200, 2000, 2000, pd.kBitmapUnflipped);

    //---Render the entities
    var entity_screen_pos: [MAX_ENTITIES]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, entity_world_positions.toDataSlice(), entity_screen_pos[0..], disp.getWidth.?(), disp.getHeight.?());

    //TODO: Interpolation
    //Player facing the way they are firing, enemies facing the way they are moving
    var entity_bitmap_frames: [MAX_ENTITIES]anim.BitmapFrame = undefined;
    for (entity_velocities.toKeysMapSlice()) |idx| {
        const v = entity_velocities.data[idx];
        entity_bitmap_frames[idx] = anim.bitmapFrameForDir(v);
    }
    entity_bitmap_frames[0] = anim.bitmapFrameForDir(target_dir);

    for (entity_world_positions.toDataSlice()) |_, i| {
        //TODO Culling (in a pass or just in time?)
        //TODO: Handle centering the sprite at the ground better
        graphics.drawBitmap.?(graphics.getTableBitmap.?(hero_bitmap_table, entity_bitmap_frames[i].index).?, entity_screen_pos[i][0] - 32, entity_screen_pos[i][1] - 64, entity_bitmap_frames[i].flip);
    }

    bullet_sys.render(graphics, disp, camera_pos);

    sys.drawFPS.?(0, 0);

    return 1;
}

/// Calculate the updated velocity and position based on input state and PLAYER_ACCeration
///
fn playerMovementSystemUpdate(current_button_states: pd.PDButtons, dt: f32, current_player_world_pos: *Vec2f, current_player_vel: *Vec2f) void {
    var move_pressed = false;

    const acc = PLAYER_ACC * dt;
    var vel = current_player_vel.*;

    if ((current_button_states & pd.kButtonRight) > 0) {
        vel[0] += acc;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonLeft) > 0) {
        vel[0] -= acc;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonUp) > 0) {
        vel[1] += acc;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonDown) > 0) {
        vel[1] -= acc;
        move_pressed = true;
    }

    if (move_pressed == false) {
        vel = Vec2f{ 0, 0 };
    }

    if (vel[0] < -PLAYER_MAX_SPEED) {
        vel[0] = -PLAYER_MAX_SPEED;
    } else if (vel[0] > PLAYER_MAX_SPEED) {
        vel[0] = PLAYER_MAX_SPEED;
    }

    if (vel[1] < -PLAYER_MAX_SPEED) {
        vel[1] = -PLAYER_MAX_SPEED;
    } else if (vel[1] > PLAYER_MAX_SPEED) {
        vel[1] = PLAYER_MAX_SPEED;
    }

    current_player_world_pos.* += vel * @splat(2, dt);
    current_player_vel.* = vel;
}

/// Fire everytime the crank moves through 60 degrees (6 bullets per revolution)
///
var crank_angle_since_fire: f32 = 0.0;
fn firingSystemUpdate(sys: pd.playdate_sys) bool {
    const crank_delta = sys.getCrankChange.?();
    if (crank_delta >= 0) {
        crank_angle_since_fire += crank_delta;
        if (crank_angle_since_fire >= FIRE_ANGLE_DELTA) {
            //Fire
            crank_angle_since_fire -= FIRE_ANGLE_DELTA;
            return true;
        }
    }

    return false;
}
