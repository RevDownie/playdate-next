const std = @import("std");
const graphics_coords = @import("graphics_coords.zig");
const pd = @cImport({
    @cInclude("pd_api.h");
});

const Vec2i = @Vector(2, i32);

/// Game constants
const MAX_ENTITIES = 2;
const PLAYER_ACC = 1;
const PLAYER_MAX_SPEED = 8;

/// Common game state
var playdate_api: *pd.PlaydateAPI = undefined;
var entity_sprites: [MAX_ENTITIES]*pd.LCDBitmap = undefined;
var player_sprite_dir: pd.LCDBitmapFlip = pd.kBitmapUnflipped;
var entity_world_pos = [_]Vec2i{Vec2i{ 0, 0 }} ** MAX_ENTITIES;
var entity_vels = [_]Vec2i{Vec2i{ 0, 0 }} ** MAX_ENTITIES;
var camera_pos = Vec2i{ 0, 0 };

var enemy_sprite_tmp: *pd.LCDBitmap = undefined;

/// Exposed via the shared library to the Playdate runner which forwards on events
///
pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.C) c_int {
    switch (event) {
        pd.kEventInit => {
            playdate_api = playdate;
            gameInit();
            playdate.*.system.*.setUpdateCallback.?(gameUpdate, null);
        },
        else => {},
    }
    return 0;
}

/// Upfront setup - allocates all the memory required and loads and initialises all assets and pools
///
fn gameInit() void {
    const graphics = playdate_api.graphics.*;

    //Spawn the player sprite
    entity_sprites[0] = graphics.loadBitmap.?("Test0.pdi", null).?;
    entity_sprites[1] = graphics.loadBitmap.?("Test1.pdi", null).?;

    //Load the enemies sprite pool
    //Init the systems
}

/// The main game update loop that drives the various systems. Also acts as the render loop
///
fn gameUpdate(_: ?*anyopaque) callconv(.C) c_int {
    const graphics = playdate_api.graphics.*;
    const sys = playdate_api.system.*;
    const disp = playdate_api.display.*;

    graphics.clear.?(pd.kColorWhite);

    var current: pd.PDButtons = undefined;
    var pushed: pd.PDButtons = undefined;
    var released: pd.PDButtons = undefined;
    sys.getButtonState.?(&current, &pushed, &released);

    playerMovementSystemUpdate(current, &entity_world_pos[0], &entity_vels[0]);

    //System for all entities
    if (entity_vels[0][0] > 0) {
        player_sprite_dir = pd.kBitmapUnflipped;
    } else if (entity_vels[0][0] < 0) {
        player_sprite_dir = pd.kBitmapFlippedX;
    }

    camera_pos = entity_world_pos[0]; //Follow the player directly for now

    //TODO: Handle only slice of max entities that is used
    var entity_screen_pos = [_]Vec2i{Vec2i{ 0, 0 }} ** MAX_ENTITIES;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, entity_world_pos[0..], entity_screen_pos[0..], disp.getWidth.?(), disp.getHeight.?());

    var i: usize = 0;
    while (i < entity_sprites.len) : (i += 1) {
        //TODO Culling (in a pass or just in time?)
        graphics.drawBitmap.?(entity_sprites[i], entity_screen_pos[i][0], entity_screen_pos[i][1], player_sprite_dir);
    }

    const shouldFire = firingSystemUpdate(sys);
    if (shouldFire) {
        sys.logToConsole.?("Fire");
    }

    _ = graphics.drawText.?("hello world!", 12, pd.kASCIIEncoding, 100, 100);
    sys.drawFPS.?(0, 0);

    return 0;
}

/// Calculate the updated velocity and position based on input state and PLAYER_ACCeration
/// TODO: Prob convert to floating point
///
fn playerMovementSystemUpdate(current_button_states: pd.PDButtons, current_player_world_pos: *Vec2i, current_player_vel: *Vec2i) void {
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
        current_player_vel.* = Vec2i{ 0, 0 };
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
        if (crank_angle_since_fire >= 60) {
            //Fire
            crank_angle_since_fire -= 60;
            return true;
        }
    }

    return false;
}
