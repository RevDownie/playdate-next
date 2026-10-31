/// Responsible for player movement in response to input state. Using the collision grid to block and slide
///
const std = @import("std");
const consts = @import("tweak_constants.zig");
const maths = @import("maths.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;

const Vec2f = @Vector(2, f32);

/// Calculate the updated velocity and position based on input state and acceleration
/// ensuring we don't walk through any env obstacles
///
pub fn update(player: *state.Player, input: state.Input, collision_grid: *const CollisionGrid, dt: f32) void {
    const acc = consts.PLAYER_ACC * dt;
    var vel = player.vel;

    if (input.right) vel[0] += acc;
    if (input.left) vel[0] -= acc;
    if (input.up) vel[1] += acc;
    if (input.down) vel[1] -= acc;

    //No momentum - stop dead on an axis as soon as it is released
    if (!input.left and !input.right) vel[0] = 0.0;
    if (!input.up and !input.down) vel[1] = 0.0;

    const max_speed: Vec2f = @splat(consts.PLAYER_MAX_SPEED);
    vel = @max(@min(vel, max_speed), -max_speed);

    // Perform X and Y in separate passes to enable wall sliding
    const pos = player.pos;
    var new_pos = pos + vel * @as(Vec2f, @splat(dt));
    if (collision_grid.isOccupied(Vec2f{ new_pos[0], pos[1] })) {
        new_pos[0] = pos[0];
    }
    if (collision_grid.isOccupied(new_pos)) {
        new_pos[1] = pos[1];
    }

    //Distance run drives the run cycle; only its place in a cycle matters, so it wraps rather than growing forever
    player.run_dist += maths.magnitude(new_pos - pos);
    while (player.run_dist >= consts.HERO_RUN_CYCLE_DIST) player.run_dist -= consts.HERO_RUN_CYCLE_DIST;
    player.pos = new_pos;
    player.vel = vel;
}
