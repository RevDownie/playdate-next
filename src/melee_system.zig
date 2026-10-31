/// Responsible for player attacks when out of ammo
///
const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const Hit = state.Hit;

const Vec2f = @Vector(2, f32);

const MELEE_RANGE_SQRD = consts.MELEE_RANGE * consts.MELEE_RANGE;

/// Out of ammo, the player lashes out with the gun's stock: every MELEE_INTERVAL it hits the MELEE_MAX_TARGETS
/// nearest enemies within MELEE_RANGE (and doesn't swing at thin air). Each blow is an ordinary hit (damage and
/// knock back, see combat_system), so two kill, and an enemy knocked back can't hurt the player while it recoils.
/// It holds off a few, not a crowd: running dry is a scramble to the next ammo drop, not helplessness.
/// Writes into `hits_out` (at least MELEE_MAX_TARGETS long) and returns the filled part
///
pub fn update(melee: *state.Melee, enemy_positions: []const Vec2f, player_pos: Vec2f, ammo: u8, dt: f32, hits_out: []Hit) []Hit {
    std.debug.assert(hits_out.len >= consts.MELEE_MAX_TARGETS);
    melee.swing_timer = @max(melee.swing_timer - dt, 0);
    melee.cooldown = @max(melee.cooldown - dt, 0);
    if (ammo > 0 or melee.cooldown > 0) return hits_out[0..0];

    //The nearest few in reach, kept sorted nearest first
    var nearest: [consts.MELEE_MAX_TARGETS]u8 = undefined;
    var nearest_dist: [consts.MELEE_MAX_TARGETS]f32 = undefined;
    var count: usize = 0;
    for (enemy_positions, 0..) |p, i| {
        const d = maths.magnitudeSqrd(p - player_pos);
        if (d > MELEE_RANGE_SQRD) continue;
        if (count == consts.MELEE_MAX_TARGETS and d >= nearest_dist[count - 1]) continue;
        var slot = @min(count, consts.MELEE_MAX_TARGETS - 1);
        while (slot > 0 and nearest_dist[slot - 1] > d) : (slot -= 1) {
            nearest[slot] = nearest[slot - 1];
            nearest_dist[slot] = nearest_dist[slot - 1];
        }
        nearest[slot] = @intCast(i);
        nearest_dist[slot] = d;
        count = @min(count + 1, consts.MELEE_MAX_TARGETS);
    }
    if (count == 0) return hits_out[0..0];

    for (nearest[0..count], hits_out[0..count]) |i, *hit| {
        hit.* = .{ .enemy_idx = i, .impact_dir = maths.normaliseSafe(enemy_positions[i] - player_pos, Vec2f{ 1, 0 }) };
    }
    melee.cooldown = consts.MELEE_INTERVAL;
    melee.swing_timer = consts.MELEE_SWING_TIME;
    melee.swing_dir = hits_out[0].impact_dir;
    return hits_out[0..count];
}

test "[melee_system] only out of ammo, only in reach, the nearest few, then a cooldown" {
    var melee = state.Melee{};
    var hits: [consts.MELEE_MAX_TARGETS]Hit = undefined;
    const r = consts.MELEE_RANGE;
    const enemies = [_]Vec2f{ .{ r * 0.9, 0 }, .{ 0, r * 0.3 }, .{ r * 2, 0 }, .{ -r * 0.5, 0 }, .{ 0, -r * 0.7 } };

    try std.testing.expect(update(&melee, &enemies, @splat(0), 1, 0.02, &hits).len == 0); //Still has ammo

    const swing = update(&melee, &enemies, @splat(0), 0, 0.02, &hits);
    try std.testing.expect(swing.len == consts.MELEE_MAX_TARGETS);
    try std.testing.expect(swing[0].enemy_idx == 1 and swing[1].enemy_idx == 3 and swing[2].enemy_idx == 4); //Nearest first
    try std.testing.expect(swing[0].impact_dir[1] == 1); //Knocked away from the player
    try std.testing.expect(melee.swing_timer > 0);

    try std.testing.expect(update(&melee, &enemies, @splat(0), 0, consts.MELEE_INTERVAL / 2, &hits).len == 0);
    try std.testing.expect(update(&melee, &enemies, @splat(0), 0, consts.MELEE_INTERVAL / 2, &hits).len > 0);
}

test "[melee_system] no swing at thin air" {
    var melee = state.Melee{};
    var hits: [consts.MELEE_MAX_TARGETS]Hit = undefined;
    const far = [_]Vec2f{.{ consts.MELEE_RANGE * 1.5, 0 }};
    try std.testing.expect(update(&melee, &far, @splat(0), 0, 0.02, &hits).len == 0);
    try std.testing.expect(melee.cooldown == 0 and melee.swing_timer == 0); //Ready the moment one steps in
}
