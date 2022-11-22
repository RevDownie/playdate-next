const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const maths = @import("maths.zig");
const bullet_sys = @import("bullet_system.zig");

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

/// Game constants
const MAX_ENTITIES = 100;
const PLAYER_ACC: f32 = 1;
const PLAYER_MAX_SPEED: f32 = 8;
const ENEMY_MAX_SPEED: f32 = 6;
const FIRE_ANGLE_DELTA: f32 = 60;

const SpriteIndex = struct { index: i32, flip: pd.LCDBitmapFlip };

//Our sprites are captured at 22.5 degree snapshots
//0 is facing towards screen and 8 is facing away, 4 is facing to the left
const SPRITE_INDEX_MAP = [_]SpriteIndex{
    SpriteIndex{ .index = 0, .flip = pd.kBitmapUnflipped }, //0
    SpriteIndex{ .index = 0, .flip = pd.kBitmapUnflipped }, //10
    SpriteIndex{ .index = 1, .flip = pd.kBitmapUnflipped }, //20
    SpriteIndex{ .index = 1, .flip = pd.kBitmapUnflipped }, //30
    SpriteIndex{ .index = 2, .flip = pd.kBitmapUnflipped }, //40
    SpriteIndex{ .index = 2, .flip = pd.kBitmapUnflipped }, //50
    SpriteIndex{ .index = 3, .flip = pd.kBitmapUnflipped }, //60
    SpriteIndex{ .index = 3, .flip = pd.kBitmapUnflipped }, //70
    SpriteIndex{ .index = 4, .flip = pd.kBitmapUnflipped }, //80
    SpriteIndex{ .index = 4, .flip = pd.kBitmapUnflipped }, //90
    SpriteIndex{ .index = 4, .flip = pd.kBitmapUnflipped }, //100
    SpriteIndex{ .index = 5, .flip = pd.kBitmapUnflipped }, //110
    SpriteIndex{ .index = 5, .flip = pd.kBitmapUnflipped }, //120
    SpriteIndex{ .index = 6, .flip = pd.kBitmapUnflipped }, //130
    SpriteIndex{ .index = 6, .flip = pd.kBitmapUnflipped }, //140
    SpriteIndex{ .index = 7, .flip = pd.kBitmapUnflipped }, //150
    SpriteIndex{ .index = 7, .flip = pd.kBitmapUnflipped }, //160
    SpriteIndex{ .index = 8, .flip = pd.kBitmapUnflipped }, //170
    SpriteIndex{ .index = 8, .flip = pd.kBitmapUnflipped }, //180
    SpriteIndex{ .index = 8, .flip = pd.kBitmapUnflipped }, //190
    SpriteIndex{ .index = 7, .flip = pd.kBitmapUnflipped }, //200
    SpriteIndex{ .index = 7, .flip = pd.kBitmapUnflipped }, //210
    SpriteIndex{ .index = 6, .flip = pd.kBitmapFlippedX }, //220
    SpriteIndex{ .index = 6, .flip = pd.kBitmapFlippedX }, //230
    SpriteIndex{ .index = 5, .flip = pd.kBitmapFlippedX }, //240
    SpriteIndex{ .index = 5, .flip = pd.kBitmapFlippedX }, //250
    SpriteIndex{ .index = 4, .flip = pd.kBitmapFlippedX }, //260
    SpriteIndex{ .index = 4, .flip = pd.kBitmapFlippedX }, //270
    SpriteIndex{ .index = 4, .flip = pd.kBitmapFlippedX }, //280
    SpriteIndex{ .index = 3, .flip = pd.kBitmapFlippedX }, //290
    SpriteIndex{ .index = 3, .flip = pd.kBitmapFlippedX }, //300
    SpriteIndex{ .index = 2, .flip = pd.kBitmapFlippedX }, //310
    SpriteIndex{ .index = 2, .flip = pd.kBitmapFlippedX }, //320
    SpriteIndex{ .index = 1, .flip = pd.kBitmapFlippedX }, //330
    SpriteIndex{ .index = 1, .flip = pd.kBitmapFlippedX }, //340
    SpriteIndex{ .index = 0, .flip = pd.kBitmapUnflipped }, //350
    SpriteIndex{ .index = 0, .flip = pd.kBitmapUnflipped }, //360
};

/// Common game state
var playdate_api: *pd.PlaydateAPI = undefined;
var entity_world_pos = [_]Vec2f{Vec2f{ 0, 0 }} ** MAX_ENTITIES;
var entity_vels = [_]Vec2f{Vec2f{ 0, 0 }} ** MAX_ENTITIES;
var camera_pos = Vec2f{ 0, 0 };
var hero_bitmap_table: *pd.LCDBitmapTable = undefined;
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

    //Spawn the player sprite
    num_active_entities = 2;

    //Init the systems

}

/// The main game update loop that drives the various systems. Also acts as the render loop
///
fn gameUpdate(_: ?*anyopaque) callconv(.C) c_int {
    const graphics = playdate_api.graphics.*;
    const sys = playdate_api.system.*;
    const disp = playdate_api.display.*;

    const dt = 0.02; //TODO figure out how to derive this

    graphics.clear.?(pd.kColorWhite);

    var current: pd.PDButtons = undefined;
    var pushed: pd.PDButtons = undefined;
    var released: pd.PDButtons = undefined;
    sys.getButtonState.?(&current, &pushed, &released);

    playerMovementSystemUpdate(current, &entity_world_pos[0], &entity_vels[0]);
    enemyMovementSystem(entity_world_pos[0], entity_world_pos[1..]);
    const target_dir = autoTargetingSystem(entity_world_pos[0], entity_world_pos[1..]);
    bullet_sys.update(dt);

    const shouldFire = firingSystemUpdate(sys);
    if (shouldFire) {
        bullet_sys.fire(entity_world_pos[0], target_dir);
    }

    camera_pos = entity_world_pos[0]; //Follow the player directly for now

    //Render the entities
    var entity_screen_pos: [MAX_ENTITIES]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, entity_world_pos[0..num_active_entities], entity_screen_pos[0..num_active_entities], disp.getWidth.?(), disp.getHeight.?());

    //TODO: Interpolation
    //Player facing the way they are firing
    const deg = maths.angleDegrees360(Vec2f{ 0, -1 }, target_dir);
    const spriteIdx = angleToSpriteIndex(deg);

    var i: usize = 0;
    while (i < num_active_entities) : (i += 1) {
        //TODO Culling (in a pass or just in time?)
        //TODO: Handle centering the sprite at the ground better
        graphics.drawBitmap.?(graphics.getTableBitmap.?(hero_bitmap_table, spriteIdx.index).?, entity_screen_pos[i][0] - 32, entity_screen_pos[i][1] - 64, spriteIdx.flip);
    }

    bullet_sys.render(graphics, disp, camera_pos);

    sys.drawFPS.?(0, 0);

    return 1;
}

/// Calculate the updated velocity and position based on input state and PLAYER_ACCeration
///
fn playerMovementSystemUpdate(current_button_states: pd.PDButtons, current_player_world_pos: *Vec2f, current_player_vel: *Vec2f) void {
    var move_pressed = false;

    if ((current_button_states & pd.kButtonRight) > 0) {
        current_player_vel.*[0] += PLAYER_ACC;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonLeft) > 0) {
        current_player_vel.*[0] -= PLAYER_ACC;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonUp) > 0) {
        current_player_vel.*[1] += PLAYER_ACC;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonDown) > 0) {
        current_player_vel.*[1] -= PLAYER_ACC;
        move_pressed = true;
    }

    if (move_pressed == false) {
        current_player_vel.* = Vec2f{ 0, 0 };
    }

    if (current_player_vel.*[0] < -PLAYER_MAX_SPEED) {
        current_player_vel.*[0] = -PLAYER_MAX_SPEED;
    } else if (current_player_vel.*[0] > PLAYER_MAX_SPEED) {
        current_player_vel.*[0] = PLAYER_MAX_SPEED;
    }

    if (current_player_vel.*[1] < -PLAYER_MAX_SPEED) {
        current_player_vel.*[1] = -PLAYER_MAX_SPEED;
    } else if (current_player_vel.*[1] > PLAYER_MAX_SPEED) {
        current_player_vel.*[1] = PLAYER_MAX_SPEED;
    }

    current_player_world_pos.* += current_player_vel.*;
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
fn enemyMovementSystem(player_world_pos: Vec2f, enemy_world_pos: []Vec2f) void {
    var i: usize = 0;
    while (i < enemy_world_pos.len) : (i += 1) {
        const to_target = player_world_pos - enemy_world_pos[i];
        const mag = maths.magnitude(to_target);
        const dir_to_target = maths.normaliseSafeMag(to_target, mag);

        enemy_world_pos[i] += dir_to_target * @splat(2, @min(ENEMY_MAX_SPEED, mag));
    }
}

/// Pick the hottest target - closest for now
///
fn autoTargetingSystem(player_world_pos: Vec2f, enemy_world_pos: []Vec2f) Vec2f {
    return maths.normaliseSafe(enemy_world_pos[0] - player_world_pos);
}

inline fn angleToSpriteIndex(degrees: f32) SpriteIndex {
    const index = @floatToInt(usize, degrees * 0.1);
    return SPRITE_INDEX_MAP[index];
}
