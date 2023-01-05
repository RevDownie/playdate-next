const maths = @import("maths.zig");
const Vec2f = @Vector(2, f32);

/// Pick the hottest target - closest for now
///
pub fn calculateHottestTargetDir(player_world_pos: Vec2f, enemy_world_pos: []Vec2f) Vec2f {
    if (enemy_world_pos.len < 2)
        return Vec2f{ 0, 0 };

    return maths.normaliseSafe(enemy_world_pos[1] - player_world_pos);
}
