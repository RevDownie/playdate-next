const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const Enemies = @import("game_state.zig").Enemies;

const Vec2f = @Vector(2, f32);

/// Animate:
/// * Entities moving towards the player target
/// * Entities bumping back in response to a collision
///
pub fn update(enemies: *Enemies, player_world_pos: Vec2f, dt: f32) void {
    for (0..enemies.len) |i| {
        if (enemies.isBumping(i)) {
            updateBumpBack(enemies, i, dt);
        } else {
            updateSeeking(enemies, i, player_world_pos, dt);
        }
    }
}

/// Enemies seek out the player and move towards them to attack
///
fn updateSeeking(enemies: *Enemies, i: usize, player_world_pos: Vec2f, dt: f32) void {
    const to_target = player_world_pos - enemies.pos[i];
    const mag = maths.magnitude(to_target);
    const dir_to_target = maths.normaliseSafeMag(to_target, mag, enemies.vel[i]);
    const vel = dir_to_target * @as(Vec2f, @splat(@min(consts.ENEMY_MAX_SPEED, mag)));
    enemies.vel[i] = vel;
    enemies.pos[i] += vel * @as(Vec2f, @splat(dt));
}

/// Animated push back. Seeking resumes once the timer reaches BUMP_TIME
///
fn updateBumpBack(enemies: *Enemies, i: usize, dt: f32) void {
    enemies.bump_timer[i] = @min(enemies.bump_timer[i] + dt, consts.BUMP_TIME);
    const y = easeOutBack(enemies.bump_timer[i] / consts.BUMP_TIME);
    enemies.pos[i] = enemies.bump_start[i] + enemies.bump_offset[i] * @as(Vec2f, @splat(y));
}

/// Easing function to animate the bump back
///
fn easeOutBack(x: f32) f32 {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    const xminus = x - 1;
    return 1 + c3 * (xminus * xminus * xminus) + c1 * (xminus * xminus);
}

test "[enemy_movement_system] bump back lands at the full offset then seeks again" {
    var e = Enemies{};
    e.add(Vec2f{ 0, 0 });
    e.startBumpBack(0, Vec2f{ 1, 0 }, 0.5);
    try std.testing.expect(e.isBumping(0));

    update(&e, Vec2f{ 10, 0 }, consts.BUMP_TIME);
    try std.testing.expect(!e.isBumping(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.pos[0][0], 0.001);

    //Next frame it moves towards the player again
    update(&e, Vec2f{ 10, 0 }, 0.1);
    try std.testing.expect(e.pos[0][0] > 0.5);
}
