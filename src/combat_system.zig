const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const Hit = state.Hit;

const Vec2f = @Vector(2, f32);

const CHAR_ENEMY_COLL_RADIUS_SQRD = consts.CHAR_ENEMY_COLL_RADIUS * consts.CHAR_ENEMY_COLL_RADIUS;

/// Apply bullet -> enemy hits: push the enemy back and deduct health. Enemies that run out of health are
/// left flagged dead (health 0) for `Enemies.removeDead`; later hits on them in the same frame are ignored
///
pub fn applyBulletHits(hits: []const Hit, enemies: *state.Enemies, player: *state.Player) void {
    for (hits) |hit| {
        const i = hit.enemy_idx;
        const health = enemies.health[i];
        if (health == 0) continue; //Already killed by an earlier bullet this frame

        if (health <= consts.DMG_PER_HIT) {
            //Enemy is dead - TODO: Graceful death and not just dissappear
            enemies.health[i] = 0;
            player.kill_streak += 1;
            player.score = @min(player.score + consts.SCORE_PER_KILL * player.kill_streak, consts.MAX_SCORE);
        } else {
            enemies.health[i] = health - consts.DMG_PER_HIT;
            enemies.startBumpBack(i, hit.impact_dir, consts.BUMP_DISTANCE);
        }
    }
}

/// Enemies that walk into the player hurt them and recoil. An enemy that is still recoiling can't hurt the
/// player again, so damage is per contact rather than per frame
///
pub fn applyEnemyContact(enemies: *state.Enemies, player: *state.Player) void {
    var num_hits: u32 = 0;
    for (0..enemies.len) |i| {
        if (enemies.isBumping(i)) continue;
        if (maths.magnitudeSqrd(enemies.pos[i] - player.pos) > CHAR_ENEMY_COLL_RADIUS_SQRD) continue;

        num_hits += 1;
        const recoil_dir = -maths.normaliseSafe(enemies.vel[i], Vec2f{ 1, 0 });
        enemies.startBumpBack(i, recoil_dir, consts.BUMP_DISTANCE_SMALL);
    }

    if (num_hits == 0) return;
    const damage = @min(num_hits * consts.CONTACT_DMG, player.health);
    player.health -= @intCast(damage);
    player.kill_streak = 0;
    player.hit_flash_timer = consts.FLASH_HIT_EFFECT_DURATION;
}

test "[combat_system] a second hit on a killed enemy is ignored" {
    var enemies = state.Enemies{};
    var player = state.Player{};
    enemies.add(Vec2f{ 0, 0 });
    enemies.health[0] = consts.DMG_PER_HIT;

    const hits = [_]Hit{ .{ .enemy_idx = 0, .impact_dir = Vec2f{ 1, 0 } }, .{ .enemy_idx = 0, .impact_dir = Vec2f{ 1, 0 } } };
    applyBulletHits(&hits, &enemies, &player);

    try std.testing.expect(enemies.health[0] == 0);
    try std.testing.expect(player.kill_streak == 1);
    try std.testing.expect(player.score == consts.SCORE_PER_KILL);
}

test "[combat_system] many enemies in contact can't overflow the damage" {
    var enemies = state.Enemies{};
    var player = state.Player{};
    while (!enemies.isFull()) enemies.add(Vec2f{ 0, 0 });

    applyEnemyContact(&enemies, &player);
    try std.testing.expect(player.health == 0);
}

test "[combat_system] recoiling enemies don't damage every frame" {
    var enemies = state.Enemies{};
    var player = state.Player{};
    enemies.add(Vec2f{ 0, 0 });

    applyEnemyContact(&enemies, &player);
    const after_first = player.health;
    try std.testing.expect(after_first == consts.PLAYER_MAX_HEALTH - consts.CONTACT_DMG);
    applyEnemyContact(&enemies, &player);
    try std.testing.expect(player.health == after_first);
}
