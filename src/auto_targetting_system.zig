const std = @import("std");
const maths = @import("maths.zig");
const Vec2f = @Vector(2, f32);

/// Pick the hottest target - closest for now
///
pub fn calculateHottestTargetDir(player_world_pos: Vec2f, enemy_world_positions: []const Vec2f) ?Vec2f {
    if (enemy_world_positions.len == 0)
        return null;

    var closest_dist_sqrd = std.math.floatMax(f32);
    var closest_pos: Vec2f = undefined;
    for (enemy_world_positions) |p| {
        const dist_sqrd = maths.magnitudeSqrd(p - player_world_pos);
        if (dist_sqrd < closest_dist_sqrd) {
            closest_dist_sqrd = dist_sqrd;
            closest_pos = p;
        }
    }

    return maths.normaliseSafe(closest_pos - player_world_pos, Vec2f{ 1, 0 });
}
