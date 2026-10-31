const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const Hit = state.Hit;

const Vec2f = @Vector(2, f32);

const CHAR_ENEMY_COLL_RADIUS_SQRD = consts.CHAR_ENEMY_COLL_RADIUS * consts.CHAR_ENEMY_COLL_RADIUS;

/// Apply hits on enemies (from bullets or the melee): push the enemy back and deduct health. Enemies that run out of health are
/// left flagged dead (health 0) for `Enemies.removeDead`; later hits on them in the same frame are ignored.
/// Each kill grows the combo and shows it where the enemy fell (big at a milestone). Every hit that landed is
/// written to `impacts_out` (at least `hits.len` long) for the gore, and the ones written returned
///
pub fn applyHits(hits: []const Hit, enemies: *state.Enemies, player: *state.Player, popups: *state.Popups, impacts_out: []state.Impact) []state.Impact {
    var num_impacts: usize = 0;
    for (hits) |hit| {
        const i = hit.enemy_idx;
        const health = enemies.health[i];
        if (health == 0) continue; //Already killed by an earlier bullet this frame

        const killed = health <= consts.DMG_PER_HIT;
        impacts_out[num_impacts] = .{ .pos = enemies.pos[i], .dir = hit.impact_dir, .kind = enemies.kind[i], .killed = killed };
        num_impacts += 1;
        if (killed) {
            //Dead: it bursts into gore (see gore_system) and is compacted out
            enemies.health[i] = 0;
            player.kill_streak += 1;
            player.kills += 1;
            player.best_streak = @max(player.best_streak, player.kill_streak);
            player.score = @min(player.score + consts.SCORE_PER_KILL * player.kill_streak, consts.MAX_SCORE);
            if (isMilestone(player.kill_streak)) {
                popups.add(enemies.pos[i], .milestone, player.kill_streak);
            } else if (player.kill_streak >= consts.COMBO_SHOW_FROM) {
                popups.add(enemies.pos[i], .combo, player.kill_streak);
            }
        } else {
            enemies.health[i] = health - consts.DMG_PER_HIT;
            //Brutes don't flinch, so fire alone can't hold them off
            const bump = enemies.kind[i].def().bump;
            if (bump > 0) enemies.startBumpBack(i, hit.impact_dir, bump);
        }
    }
    return impacts_out[0..num_impacts];
}

fn isMilestone(combo: u32) bool {
    return combo == consts.COMBO_MILESTONE_FIRST or (combo > 0 and combo % consts.COMBO_MILESTONE_EVERY == 0);
}

/// Enemies that walk into the player hurt them by `damage` (CONTACT_DMG, or 0 when invincible) and recoil.
/// An enemy that is still recoiling can't hurt the player again, so damage is per contact rather than per frame.
/// Being touched breaks the combo, which says so at the player if it was a good one
///
pub fn applyEnemyContact(enemies: *state.Enemies, player: *state.Player, damage: u8, popups: *state.Popups) void {
    var num_hits: u32 = 0;
    for (0..enemies.len) |i| {
        if (enemies.isBumping(i)) continue;
        if (maths.magnitudeSqrd(enemies.pos[i] - player.pos) > CHAR_ENEMY_COLL_RADIUS_SQRD) continue;

        num_hits += 1;
        const recoil_dir = -maths.normaliseSafe(enemies.vel[i], Vec2f{ 1, 0 });
        enemies.startBumpBack(i, recoil_dir, consts.BUMP_DISTANCE_SMALL);
    }

    if (num_hits == 0) return;
    const total = @min(num_hits * damage, player.health);
    player.health -= @intCast(total);
    if (player.kill_streak >= consts.COMBO_LOST_MIN) popups.add(player.pos, .lost, player.kill_streak);
    player.kill_streak = 0;
    player.hit_flash_timer = consts.FLASH_HIT_EFFECT_DURATION;
}

test "[combat_system] a second hit on a killed enemy is ignored" {
    var test_impacts: [8]state.Impact = undefined;
    var enemies = state.Enemies{};
    var player = state.Player{};
    var popups = state.Popups{};
    enemies.add(Vec2f{ 0, 0 });
    enemies.health[0] = consts.DMG_PER_HIT;

    const hits = [_]Hit{ .{ .enemy_idx = 0, .impact_dir = Vec2f{ 1, 0 } }, .{ .enemy_idx = 0, .impact_dir = Vec2f{ 1, 0 } } };
    const impacts = applyHits(&hits, &enemies, &player, &popups, &test_impacts);

    try std.testing.expect(impacts.len == 1 and impacts[0].killed and impacts[0].kind == .walker); //Bursts once
    try std.testing.expect(enemies.health[0] == 0);
    try std.testing.expect(player.kill_streak == 1);
    try std.testing.expect(player.score == consts.SCORE_PER_KILL);
    try std.testing.expect(player.kills == 1 and player.best_streak == 1);
}

test "[combat_system] a fresh walker is knocked back by the first hit and killed by the second" {
    var test_impacts: [8]state.Impact = undefined;
    var enemies = state.Enemies{};
    var player = state.Player{};
    var popups = state.Popups{};
    enemies.add(Vec2f{ 0, 0 });

    const hit = [_]Hit{.{ .enemy_idx = 0, .impact_dir = Vec2f{ 1, 0 } }};
    const wound = applyHits(&hit, &enemies, &player, &popups, &test_impacts);
    try std.testing.expect(wound.len == 1 and !wound[0].killed and wound[0].dir[0] == 1);
    try std.testing.expect(enemies.health[0] > 0 and enemies.isBumping(0));
    _ = applyHits(&hit, &enemies, &player, &popups, &test_impacts);
    try std.testing.expect(enemies.health[0] == 0);
}

test "[combat_system] many enemies in contact can't overflow the damage" {
    var enemies = state.Enemies{};
    var player = state.Player{};
    var popups = state.Popups{};
    while (!enemies.isFull()) enemies.add(Vec2f{ 0, 0 });

    applyEnemyContact(&enemies, &player, consts.CONTACT_DMG, &popups);
    try std.testing.expect(player.health == 0);
}

test "[combat_system] recoiling enemies don't damage every frame" {
    var enemies = state.Enemies{};
    var player = state.Player{};
    var popups = state.Popups{};
    enemies.add(Vec2f{ 0, 0 });

    applyEnemyContact(&enemies, &player, consts.CONTACT_DMG, &popups);
    const after_first = player.health;
    try std.testing.expect(after_first == consts.PLAYER_MAX_HEALTH - consts.CONTACT_DMG);
    applyEnemyContact(&enemies, &player, consts.CONTACT_DMG, &popups);
    try std.testing.expect(player.health == after_first);
}

test "[combat_system] an invincible player still gets bumped but takes no damage" {
    var enemies = state.Enemies{};
    var player = state.Player{};
    var popups = state.Popups{};
    enemies.add(Vec2f{ 0, 0 });
    applyEnemyContact(&enemies, &player, 0, &popups);
    try std.testing.expect(player.health == consts.PLAYER_MAX_HEALTH);
    try std.testing.expect(enemies.isBumping(0));
}

test "[combat_system] kills show the growing combo where they fell, big at milestones" {
    var test_impacts: [8]state.Impact = undefined;
    var enemies = state.Enemies{};
    var player = state.Player{};
    var popups = state.Popups{};
    player.kill_streak = consts.COMBO_MILESTONE_FIRST - 2;
    enemies.add(Vec2f{ 1, 2 });
    enemies.add(Vec2f{ 3, 4 });
    enemies.health[0] = consts.DMG_PER_HIT;
    enemies.health[1] = consts.DMG_PER_HIT;
    const hits = [_]Hit{ .{ .enemy_idx = 0, .impact_dir = Vec2f{ 1, 0 } }, .{ .enemy_idx = 1, .impact_dir = Vec2f{ 1, 0 } } };
    _ = applyHits(&hits, &enemies, &player, &popups, &test_impacts);

    try std.testing.expect(popups.len == 2);
    try std.testing.expect(popups.kind[0] == .combo and popups.value[0] == consts.COMBO_MILESTONE_FIRST - 1);
    try std.testing.expect(popups.pos[0][0] == 1 and popups.pos[0][1] == 2);
    try std.testing.expect(popups.kind[1] == .milestone and popups.value[1] == consts.COMBO_MILESTONE_FIRST);
    try std.testing.expect(isMilestone(consts.COMBO_MILESTONE_EVERY * 3) and !isMilestone(consts.COMBO_MILESTONE_EVERY + 1));
}

test "[combat_system] a first kill shows nothing, and only a good combo says it was lost" {
    var test_impacts: [8]state.Impact = undefined;
    var enemies = state.Enemies{};
    var player = state.Player{};
    var popups = state.Popups{};
    enemies.add(Vec2f{ 0, 0 });
    enemies.health[0] = consts.DMG_PER_HIT;
    _ = applyHits(&[_]Hit{.{ .enemy_idx = 0, .impact_dir = Vec2f{ 1, 0 } }}, &enemies, &player, &popups, &test_impacts);
    try std.testing.expect(popups.len == 0);

    var toucher = state.Enemies{};
    toucher.add(Vec2f{ 0, 0 });
    applyEnemyContact(&toucher, &player, consts.CONTACT_DMG, &popups); //A combo of 1 breaking isn't news
    try std.testing.expect(popups.len == 0 and player.kill_streak == 0);

    var toucher2 = state.Enemies{};
    toucher2.add(Vec2f{ 0, 0 });
    player.kill_streak = consts.COMBO_LOST_MIN;
    applyEnemyContact(&toucher2, &player, consts.CONTACT_DMG, &popups);
    try std.testing.expect(popups.len == 1 and popups.kind[0] == .lost and popups.value[0] == consts.COMBO_LOST_MIN);
}
