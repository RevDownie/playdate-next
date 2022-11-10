const std = @import("std");

const pd = @cImport({
    @cInclude("pd_api.h");
});

var playdate_api: *pd.PlaydateAPI = undefined;
var player_sprite: *pd.LCDBitmap = undefined;
var player_pos = Vec2i{ .x = 100, .y = 100 };
var player_vel = Vec2i{ .x = 0, .y = 0 };
var player_sprite_dir: pd.LCDBitmapFlip = pd.kBitmapUnflipped;

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

fn gameInit() void {
    //Spawn the player sprite
    const graphics = playdate_api.graphics.*;
    player_sprite = graphics.loadBitmap.?("Test0.pdi", null).?;

    //Load the enemies sprite pool
    //Init the systems
}

const Vec2i = struct {
    x: i32,
    y: i32,
};

fn gameUpdate(_: ?*anyopaque) callconv(.C) c_int {
    const playdate = playdate_api;
    const graphics = playdate.graphics.*;
    const sys = playdate.system.*;
    // const disp = playdate.display.*;

    graphics.clear.?(pd.kColorWhite);
    sys.drawFPS.?(0, 0);
    _ = graphics.drawText.?("hello world!", 12, pd.kASCIIEncoding, 100, 100);

    var current: pd.PDButtons = undefined;
    var pushed: pd.PDButtons = undefined;
    var released: pd.PDButtons = undefined;
    sys.getButtonState.?(&current, &pushed, &released);

    player_pos = playerMovementSystemUpdate(current, player_pos);

    if (player_vel.x > 0) {
        player_sprite_dir = pd.kBitmapUnflipped;
    } else if (player_vel.x < 0) {
        player_sprite_dir = pd.kBitmapFlippedX;
    }

    graphics.drawBitmap.?(player_sprite, player_pos.x, player_pos.y, player_sprite_dir);

    const shouldFire = firingSystemUpdate(sys);
    if (shouldFire) {
        sys.logToConsole.?("Fire");
    }

    return 0;
}

/// Calculate the updated position based on input state and acceleration
/// TODO: Prob convert to floating point
///
const accel = 1;
const max_speed = 8;
fn playerMovementSystemUpdate(current_button_states: pd.PDButtons, current_player_pos: Vec2i) Vec2i {
    var updated_pos = current_player_pos;
    var move_pressed = false;

    if ((current_button_states & pd.kButtonRight) > 0) {
        player_vel.x += accel;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonLeft) > 0) {
        player_vel.x -= accel;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonUp) > 0) {
        player_vel.y -= accel;
        move_pressed = true;
    }
    if ((current_button_states & pd.kButtonDown) > 0) {
        player_vel.y += accel;
        move_pressed = true;
    }

    if (move_pressed == false) {
        player_vel = Vec2i{ .x = 0, .y = 0 };
    }

    if (player_vel.x < -max_speed) {
        player_vel.x = -max_speed;
    } else if (player_vel.x > max_speed) {
        player_vel.x = max_speed;
    }

    if (player_vel.y < -max_speed) {
        player_vel.y = -max_speed;
    } else if (player_vel.y > max_speed) {
        player_vel.y = max_speed;
    }

    updated_pos.x += player_vel.x;
    updated_pos.y += player_vel.y;
    return updated_pos;
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
