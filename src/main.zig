const std = @import("std");

const pd = @cImport({
    @cInclude("pd_api.h");
});

var playdate_api: *pd.PlaydateAPI = undefined;

/// Common game state
var player_sprite: *pd.LCDBitmap = undefined;
var player_pos = @Vector(2, i32){ 100, 100 };
var player_vel = @Vector(2, i32){ 0, 0 };
var player_sprite_dir: pd.LCDBitmapFlip = pd.kBitmapUnflipped;

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
    //Spawn the player sprite
    const graphics = playdate_api.graphics.*;
    player_sprite = graphics.loadBitmap.?("Test0.pdi", null).?;

    //Load the enemies sprite pool
    //Init the systems
}

/// The main game update loop that drives the various systems. Also acts as the render loop
///
fn gameUpdate(_: ?*anyopaque) callconv(.C) c_int {
    const playdate = playdate_api;
    const graphics = playdate.graphics.*;
    const sys = playdate.system.*;

    graphics.clear.?(pd.kColorWhite);
    sys.drawFPS.?(0, 0);
    _ = graphics.drawText.?("hello world!", 12, pd.kASCIIEncoding, 100, 100);

    var current: pd.PDButtons = undefined;
    var pushed: pd.PDButtons = undefined;
    var released: pd.PDButtons = undefined;
    sys.getButtonState.?(&current, &pushed, &released);

    playerMovementSystemUpdate(current, &player_pos, &player_vel);

    if (player_vel[0] > 0) {
        player_sprite_dir = pd.kBitmapUnflipped;
    } else if (player_vel[0] < 0) {
        player_sprite_dir = pd.kBitmapFlippedX;
    }

    graphics.drawBitmap.?(player_sprite, player_pos[0], player_pos[1], player_sprite_dir);

    const shouldFire = firingSystemUpdate(sys);
    if (shouldFire) {
        sys.logToConsole.?("Fire");
    }

    return 0;
}

/// Calculate the updated velocity and position based on input state and acceleration
/// TODO: Prob convert to floating point
///
const accel = 1;
const max_speed = 8;
fn playerMovementSystemUpdate(current_button_states: pd.PDButtons, current_player_pos: *@Vector(2, i32), current_player_vel: *@Vector(2, i32)) void {
    var move_pressed = false;

    if ((current_button_states & pd.kButtonRight) > 0) {
        current_player_vel.*[0] += accel;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonLeft) > 0) {
        current_player_vel.*[0] -= accel;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonUp) > 0) {
        current_player_vel.*[1] -= accel;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonDown) > 0) {
        current_player_vel.*[1] += accel;
        move_pressed = true;
    }

    if (move_pressed == false) {
        current_player_vel.* = @Vector(2, i32){ 0, 0 };
    }

    if (current_player_vel.*[0] < -max_speed) {
        current_player_vel.*[0] = -max_speed;
    } else if (current_player_vel.*[0] > max_speed) {
        current_player_vel.*[0] = max_speed;
    }

    if (current_player_vel.*[1] < -max_speed) {
        current_player_vel.*[1] = -max_speed;
    } else if (current_player_vel.*[1] > max_speed) {
        current_player_vel.*[1] = max_speed;
    }

    current_player_pos.* += current_player_vel.*;
}

/// Fire everytime the crank moves through 360 degrees
///
var crank_angle_since_fire: f32 = 0.0;
fn firingSystemUpdate(sys: pd.playdate_sys) bool {
    const crank_delta = sys.getCrankChange.?();
    if (crank_delta >= 0) {
        crank_angle_since_fire += crank_delta;
        if (crank_angle_since_fire >= 360) {
            //Fire
            crank_angle_since_fire -= 360;
            return true;
        }
    }

    return false;
}
