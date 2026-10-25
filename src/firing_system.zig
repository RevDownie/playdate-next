const std = @import("std");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");

/// Fire every time the crank moves forward through FIRE_ANGLE_DELTA degrees (6 bullets per revolution)
/// Alternatively fire every FIRE_BUTTON_DELAY while A or B is held. Returns true if the gun should fire this frame
///
pub fn update(trigger: *state.Trigger, input: state.Input, dt: f32) bool {
    var fire = false;

    trigger.button_cooldown = @max(trigger.button_cooldown - dt, 0);
    if (input.fire_held and trigger.button_cooldown <= 0) {
        trigger.button_cooldown = consts.FIRE_BUTTON_DELAY;
        fire = true;
    }

    if (input.crank_delta >= 0) {
        trigger.crank_angle_since_fire += input.crank_delta;
        if (trigger.crank_angle_since_fire >= consts.FIRE_ANGLE_DELTA) {
            trigger.crank_angle_since_fire -= consts.FIRE_ANGLE_DELTA;
            fire = true;
        }
    }

    return fire;
}

test "[firing_system] crank fires every FIRE_ANGLE_DELTA" {
    var t = state.Trigger{};
    try std.testing.expect(!update(&t, .{ .crank_delta = consts.FIRE_ANGLE_DELTA - 1 }, 0.016));
    try std.testing.expect(update(&t, .{ .crank_delta = 1 }, 0.016));
    try std.testing.expect(!update(&t, .{ .crank_delta = -90 }, 0.016)); //Backwards is ignored
}

test "[firing_system] held button fires on a delay" {
    var t = state.Trigger{};
    try std.testing.expect(update(&t, .{ .fire_held = true }, 0.016));
    try std.testing.expect(!update(&t, .{ .fire_held = true }, consts.FIRE_BUTTON_DELAY / 2));
    try std.testing.expect(update(&t, .{ .fire_held = true }, consts.FIRE_BUTTON_DELAY / 2));
}
