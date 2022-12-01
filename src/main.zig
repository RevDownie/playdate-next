const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const maths = @import("maths.zig");
const bullet_sys = @import("bullet_system.zig");
const anim = @import("animation.zig");
const enemy_spawn_sys = @import("enemy_spawn_system.zig");

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

/// Game constants
const MAX_ENTITIES = 100;
const PLAYER_ACC: f32 = 2;
const PLAYER_MAX_SPEED: f32 = 2.6;
const ENEMY_MAX_SPEED: f32 = 2.4;
const FIRE_ANGLE_DELTA: f32 = 60;

/// Common game state
var playdate_api: *pd.PlaydateAPI = undefined;
var entity_world_pos = [_]Vec2f{Vec2f{ 0, 0 }} ** MAX_ENTITIES;
var entity_vels = [_]Vec2f{Vec2f{ 0, 0 }} ** MAX_ENTITIES;
var camera_pos = Vec2f{ 0, 0 };
var hero_bitmap_table: *pd.LCDBitmapTable = undefined;
var entity_bitmap_frames: [MAX_ENTITIES]anim.BitmapFrame = undefined;
var num_active_entities: usize = 0;

/// Exposed via the shared library to the Playdate runner which forwards on events
///
pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.C) c_int {
    switch (event) {
        pd.kEventInit => gameInit(playdate),
        else => {},
    }
    return 0;
}

/// Upfront setup - allocates all the memory required and loads and initialises all assets and pools
///
fn gameInit(playdate: [*c]pd.PlaydateAPI) void {
    playdate_api = playdate;
    playdate_api.system.*.setUpdateCallback.?(gameUpdate, null);

    const graphics = playdate_api.graphics.*;
    playdate_api.display.*.setRefreshRate.?(0); //Temp unleashing the frame limit to measure performance

    //Load the assets
    hero_bitmap_table = graphics.loadBitmapTable.?("hero1", null).?;

    //Spawn the player sprite - player is always index 0
    num_active_entities = 1;

    //Init the systems
    enemy_spawn_sys.init(MAX_ENTITIES);
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

    const spawned = enemy_spawn_sys.update(dt, num_active_entities);
    for (spawned) |s, idx| {
        const global_idx = num_active_entities + idx;
        entity_world_pos[global_idx] = s.world_pos;
        entity_vels[global_idx] = Vec2f{ 0, 0 };
    }
    num_active_entities += spawned.len;

    playerMovementSystemUpdate(current, dt, &entity_world_pos[0], &entity_vels[0]);
    enemyMovementSystem(entity_world_pos[0], dt, entity_world_pos[1..], entity_vels[1..]);
    const target_dir = autoTargetingSystem(entity_world_pos[0], entity_world_pos[1..]);
    bullet_sys.update(dt);

    const should_fire = firingSystemUpdate(sys);
    if (should_fire) {
        bullet_sys.fire(entity_world_pos[0], target_dir);
    }

    camera_pos = entity_world_pos[0]; //Follow the player directly for now

    //---Render the entities
    var entity_screen_pos: [MAX_ENTITIES]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, entity_world_pos[0..num_active_entities], entity_screen_pos[0..num_active_entities], disp.getWidth.?(), disp.getHeight.?());

    //TODO: Interpolation
    //Player facing the way they are firing, enemies facing the way they are moving
    entity_bitmap_frames[0] = anim.bitmapFrameForDir(target_dir);
    for (entity_vels[1..num_active_entities]) |v, idx| {
        entity_bitmap_frames[idx + 1] = anim.bitmapFrameForDir(v);
    }

    var i: usize = 0;
    while (i < num_active_entities) : (i += 1) {
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

/// Enemies seek out the player and move towards them to attack
///
fn enemyMovementSystem(player_world_pos: Vec2f, dt: f32, enemy_world_pos: []Vec2f, enemy_vels: []Vec2f) void {
    var i: usize = 0;
    while (i < enemy_world_pos.len) : (i += 1) {
        const to_target = player_world_pos - enemy_world_pos[i];
        const mag = maths.magnitude(to_target);
        const dir_to_target = maths.normaliseSafeMag(to_target, mag);
        enemy_vels[i] = dir_to_target * @splat(2, @min(ENEMY_MAX_SPEED, mag));
        enemy_world_pos[i] += enemy_vels[i] * @splat(2, dt);
    }
}

/// Pick the hottest target - closest for now
///
fn autoTargetingSystem(player_world_pos: Vec2f, enemy_world_pos: []Vec2f) Vec2f {
    if (enemy_world_pos.len == 0)
        return Vec2f{ 0, 0 };

    return maths.normaliseSafe(enemy_world_pos[0] - player_world_pos);
}
