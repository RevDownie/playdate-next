const std = @import("std");
const consts = @import("tweak_constants.zig");
const maths = @import("maths.zig");

const Vec2f = @Vector(2, f32);

const MOVE_LEAD_PER_SPEED = Vec2f{ consts.CAMERA_MOVE_LEAD_X, consts.CAMERA_MOVE_LEAD_Y } / @as(Vec2f, @splat(consts.PLAYER_MAX_SPEED));
const AIM_LEAD = Vec2f{ consts.CAMERA_AIM_LEAD_X, consts.CAMERA_AIM_LEAD_Y };
const LEAD_MAX = Vec2f{ consts.CAMERA_MOVE_LEAD_X, consts.CAMERA_MOVE_LEAD_Y } + AIM_LEAD;
const LAG_MAX = Vec2f{ consts.CAMERA_LAG_MAX_X, consts.CAMERA_LAG_MAX_Y };

/// Move the camera. It is a point that trails the player (`camera_pos - lead` last frame), plus a lead:
/// - The trailing point catches up at CAMERA_FOLLOW_RATE, so a running player sits a little ahead of centre (they
///   see more of what is behind them) and the view drifts back under them when they stop; at most CAMERA_LAG_MAX_X/Y
/// - The lead leans a little the way the player moves and, while they move, towards where the gun is aimed
///   (`aim_dir`, unit length), so running away while firing back keeps the horde in view (standing still they can
///   see all round, and the camera shouldn't wander as the gun swings between targets). It follows a critically damped spring (`lead_vel`
///   is its speed) so it never jumps when the player stops dead or the gun swings round: CAMERA_LEAD_FREQ out,
///   the slower CAMERA_RETURN_FREQ back
/// Both are bounded, so the player always stays well on screen
///
pub fn update(camera_pos: *Vec2f, lead: *Vec2f, lead_vel: *Vec2f, player_pos: Vec2f, player_vel: Vec2f, aim_dir: Vec2f, dt: f32) void {
    //Lag: exponential catch up without a runtime exp (rate*dt / (1 + rate*dt) stays under 1 however long the frame)
    const k = consts.CAMERA_FOLLOW_RATE * dt;
    var follow = camera_pos.* - lead.*;
    follow += (player_pos - follow) * @as(Vec2f, @splat(k / (1 + k)));
    follow = player_pos + @max(@min(follow - player_pos, LAG_MAX), -LAG_MAX);

    //Lead, per axis: heading back towards the player is the slow spring
    const moving = @min(maths.magnitude(player_vel) / consts.PLAYER_MAX_SPEED, 1);
    const target = player_vel * MOVE_LEAD_PER_SPEED + aim_dir * AIM_LEAD * @as(Vec2f, @splat(moving));
    const returning = @abs(target) < @abs(lead.*);
    const w = @select(f32, returning, @as(Vec2f, @splat(consts.CAMERA_RETURN_FREQ)), @as(Vec2f, @splat(consts.CAMERA_LEAD_FREQ)));
    const dt_v: Vec2f = @splat(dt);
    const acc = w * w * (target - lead.*) - @as(Vec2f, @splat(2)) * w * lead_vel.*;
    lead_vel.* += acc * dt_v;
    lead.* = @max(@min(lead.* + lead_vel.* * dt_v, LEAD_MAX), -LEAD_MAX);

    camera_pos.* = follow + lead.*;
}

/// A shot kicks the view back against the aim (`aim_dir`, unit length), with a little random sideways jolt
/// (`jolt`, -1 to 1), adding to any kick still easing out. Purely visual: the shake is added when drawing, so
/// targeting never sees it. Bounded by CAMERA_SHAKE_MAX
///
pub fn kick(shake: *Vec2f, aim_dir: Vec2f, jolt: f32) void {
    const side = Vec2f{ -aim_dir[1], aim_dir[0] };
    const k = -aim_dir * @as(Vec2f, @splat(consts.CAMERA_KICK)) + side * @as(Vec2f, @splat(jolt * consts.CAMERA_KICK_JOLT));
    shake.* += k;
    const len = maths.magnitude(shake.*);
    if (len > consts.CAMERA_SHAKE_MAX) shake.* *= @as(Vec2f, @splat(consts.CAMERA_SHAKE_MAX / len));
}

/// Ease the shake back to nothing (CAMERA_SHAKE_SETTLE_RATE, without a runtime exp)
///
pub fn settleShake(shake: *Vec2f, dt: f32) void {
    shake.* *= @as(Vec2f, @splat(1 / (1 + consts.CAMERA_SHAKE_SETTLE_RATE * dt)));
}

comptime {
    //The player must stay well clear of the HUD rows and screen edges with the full lag and lead
    if (LAG_MAX[0] + LEAD_MAX[0] > consts.VIEW_HALF_WIDTH * 0.5 or LAG_MAX[1] + LEAD_MAX[1] > consts.VIEW_HALF_HEIGHT * 0.3) @compileError("Camera lag and lead push the player too near the screen edge");
    //Semi-implicit Euler on the spring stays stable while w * dt is well under 1, even on the longest frame
    if (consts.CAMERA_LEAD_FREQ * consts.MAX_FRAME_DT > 0.5) @compileError("CAMERA_LEAD_FREQ is too stiff for MAX_FRAME_DT");
}

const TEST_DT: f32 = 1.0 / 50.0;

test "[camera_system] a running player sits ahead of centre, and the camera catches up gently when they stop" {
    var cam: Vec2f = @splat(0);
    var lead: Vec2f = @splat(0);
    var lead_vel: Vec2f = @splat(0);
    var pos: Vec2f = @splat(0);
    const vel = Vec2f{ consts.PLAYER_MAX_SPEED, 0 };
    const aim = Vec2f{ -1, 0 }; //Running right, firing back left
    for (0..250) |_| {
        pos += vel * @as(Vec2f, @splat(TEST_DT));
        update(&cam, &lead, &lead_vel, pos, vel, aim, TEST_DT);
        try std.testing.expect(@abs(cam[0] - pos[0]) <= LAG_MAX[0] + LEAD_MAX[0]);
    }
    try std.testing.expect(cam[0] < pos[0] - 0.1); //The view shows more of what is behind
    //Stop dead: the camera keeps drifting the way it was going for a moment rather than snapping back
    const before = cam;
    update(&cam, &lead, &lead_vel, pos, @splat(0), aim, TEST_DT);
    try std.testing.expect(cam[0] > before[0] and cam[0] - before[0] < consts.PLAYER_MAX_SPEED * TEST_DT * 1.1);
    for (0..500) |_| update(&cam, &lead, &lead_vel, pos, @splat(0), aim, TEST_DT);
    //Standing still it settles back on the player, whichever way the gun is aimed
    try std.testing.expectApproxEqAbs(pos[0], cam[0], 0.001);
}

test "[camera_system] firing kicks the view back against the aim, bounded, and it settles within a few frames" {
    var shake: Vec2f = @splat(0);
    kick(&shake, .{ 1, 0 }, 0);
    try std.testing.expect(shake[0] < 0 and shake[1] == 0);
    for (0..50) |_| kick(&shake, .{ 0, 1 }, 1); //A long burst
    try std.testing.expect(maths.magnitude(shake) <= consts.CAMERA_SHAKE_MAX * 1.0001);
    for (0..10) |_| settleShake(&shake, TEST_DT);
    try std.testing.expect(maths.magnitude(shake) < 0.5 / consts.METRES_TO_PIXELS); //Under half a pixel after 0.2s
}

test "[camera_system] lag and lead stay within their limits, even on long frames" {
    var cam: Vec2f = @splat(0);
    var lead: Vec2f = @splat(0);
    var lead_vel: Vec2f = @splat(0);
    var pos: Vec2f = @splat(0);
    const vel = Vec2f{ -consts.PLAYER_MAX_SPEED, consts.PLAYER_MAX_SPEED };
    for (0..100) |i| {
        pos += vel * @as(Vec2f, @splat(consts.MAX_FRAME_DT));
        const aim: Vec2f = if (i % 7 < 3) .{ 1, 0 } else .{ 0, -1 }; //The gun swinging between targets
        update(&cam, &lead, &lead_vel, pos, vel, aim, consts.MAX_FRAME_DT);
        try std.testing.expect(@reduce(.And, @abs(lead) <= LEAD_MAX));
        try std.testing.expect(@reduce(.And, @abs(cam - lead - pos) <= LAG_MAX + @as(Vec2f, @splat(0.0001))));
    }
}
