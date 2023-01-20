const std = @import("std");
const maths = @import("maths.zig");
const pd = @import("playdate.zig").api;
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

/// Calculate the updated velocity and position based on input state and acceleration
///
pub fn update(current_button_states: pd.PDButtons, dt: f32, current_player_world_pos: *Vec2f, current_player_vel: *Vec2f) void {
    var move_pressed_h = false;
    var move_pressed_v = false;

    const acc = consts.PLAYER_ACC * dt;
    var vel = current_player_vel.*;

    if ((current_button_states & pd.kButtonRight) > 0) {
        vel[0] += acc;
        move_pressed_h = true;
    }
    if ((current_button_states & pd.kButtonLeft) > 0) {
        vel[0] -= acc;
        move_pressed_h = true;
    }
    if ((current_button_states & pd.kButtonUp) > 0) {
        vel[1] += acc;
        move_pressed_v = true;
    }
    if ((current_button_states & pd.kButtonDown) > 0) {
        vel[1] -= acc;
        move_pressed_v = true;
    }

    if (move_pressed_h == false) {
        vel[0] = 0.0;
    }
    if (move_pressed_v == false) {
        vel[1] = 0.0;
    }

    if (vel[0] < -consts.PLAYER_MAX_SPEED) {
        vel[0] = -consts.PLAYER_MAX_SPEED;
    } else if (vel[0] > consts.PLAYER_MAX_SPEED) {
        vel[0] = consts.PLAYER_MAX_SPEED;
    }

    if (vel[1] < -consts.PLAYER_MAX_SPEED) {
        vel[1] = -consts.PLAYER_MAX_SPEED;
    } else if (vel[1] > consts.PLAYER_MAX_SPEED) {
        vel[1] = consts.PLAYER_MAX_SPEED;
    }

    current_player_world_pos.* += vel * @splat(2, dt);
    current_player_vel.* = vel;
}
