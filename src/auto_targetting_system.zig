const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const memory = @import("memory.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;

const Vec2f = @Vector(2, f32);

/// The per enemy scores are re-read for every line of sight test while the collision grid is read at random,
/// so they must leave most of the hot set to the grid
pub const TARGET_HOT_SET_BYTES = @as(usize, consts.MAX_ENEMIES) * @sizeOf(f32);
comptime {
    if (TARGET_HOT_SET_BYTES > memory.HOT_SET_BUDGET / 4) @compileError("Target scores no longer leave room in the L1 hot set for the collision grid");
}

pub const Target = struct {
    pos: Vec2f,
    dir: Vec2f, //Unit length, from the player towards `pos`
};

/// Pick the enemy the gun should shoot: the best scoring one the player can see. Visible means inside the
/// camera's view (around `view_centre`, plus TARGET_VIEW_MARGIN) with a clear line from the player's feet.
/// The score is the distance, shrunk for enemies ahead of `move_dir` (the way the player is heading, zero
/// while standing still), for damaged ones (so the gun finishes an enemy off even after its hits knock it
/// back, rather than spreading damage around the horde) and a little for those along `aim_dir` (last frame's
/// aim, so the gun doesn't flick between two similar targets). Line of sight is only tested on the best TARGET_MAX_LOS_TESTS candidates,
/// best first. `scores` is per frame scratch with an entry per enemy. Returns null if nothing can be seen
///
pub fn findTarget(player_pos: Vec2f, move_dir: Vec2f, aim_dir: Vec2f, view_centre: Vec2f, enemy_positions: []const Vec2f, enemy_health: []const u8, enemy_kinds: []const state.EnemyKind, grid: *const CollisionGrid, scores: []f32) ?Target {
    std.debug.assert(scores.len >= enemy_positions.len and enemy_health.len >= enemy_positions.len);
    const view_half = Vec2f{ consts.VIEW_HALF_WIDTH + consts.TARGET_VIEW_MARGIN, consts.VIEW_HALF_HEIGHT + consts.TARGET_VIEW_MARGIN };
    const unseen = std.math.inf(f32);
    const enemy_scores = scores[0..enemy_positions.len];

    //Score every enemy in view in one streamed pass
    for (enemy_positions, enemy_health[0..enemy_positions.len], enemy_kinds[0..enemy_positions.len], enemy_scores) |p, health, kind, *score| {
        if (@reduce(.Or, maths.abs(p - view_centre) > view_half)) {
            score.* = unseen;
            continue;
        }
        const offset = p - player_pos;
        const dist = maths.magnitude(offset);
        const dir = maths.normaliseSafeMag(offset, dist, aim_dir);
        const ahead = 1 - consts.TARGET_AHEAD_WEIGHT * @max(maths.dot(dir, move_dir), 0);
        const sticky = 1 - consts.TARGET_STICKY_WEIGHT * @max(maths.dot(dir, aim_dir), 0);
        const max_health = kind.def().health;
        const damage: f32 = @floatFromInt(max_health -| health);
        const finish = 1 - consts.TARGET_FINISH_WEIGHT * damage / @as(f32, @floatFromInt(max_health));
        score.* = dist * ahead * finish * sticky;
    }

    //Best first until one can be seen. A few linear passes over the scores is cheaper than sorting them all
    for (0..consts.TARGET_MAX_LOS_TESTS) |_| {
        var best: usize = 0;
        var best_score = unseen;
        for (enemy_scores, 0..) |score, i| {
            if (score < best_score) {
                best_score = score;
                best = i;
            }
        }
        if (best_score == unseen) return null;

        const p = enemy_positions[best];
        if (grid.isSegmentClear(player_pos, p)) return .{ .pos = p, .dir = maths.normaliseSafe(p - player_pos, aim_dir) };
        enemy_scores[best] = unseen; //Behind a wall
    }
    return null;
}

/// 30x30 grid of the levels' 57x27px cells (about 13.4 x 6.3m), open apart from a wall down column 17 (x = 0.67m to 1.11m)
fn testGrid(cells: *[30 * 30]bool, wall: bool) CollisionGrid {
    @memset(cells, false);
    if (wall) {
        for (0..30) |row| cells[row * 30 + 17] = true;
    }
    return .{ .cells = cells, .width = 30, .height = 30, .cell_width = 57, .cell_height = 27 };
}

/// Every enemy at full health
fn testFind(player_pos: Vec2f, move_dir: Vec2f, aim_dir: Vec2f, enemies: []const Vec2f, grid: *const CollisionGrid) ?Target {
    const health: [consts.MAX_ENEMIES]u8 = @splat(consts.ENEMY_MAX_HEALTH);
    return testFindHurt(player_pos, move_dir, aim_dir, enemies, health[0..enemies.len], grid);
}

fn testFindHurt(player_pos: Vec2f, move_dir: Vec2f, aim_dir: Vec2f, enemies: []const Vec2f, health: []const u8, grid: *const CollisionGrid) ?Target {
    var scores: [consts.MAX_ENEMIES]f32 = undefined;
    const kinds: [consts.MAX_ENEMIES]state.EnemyKind = @splat(.walker);
    return findTarget(player_pos, move_dir, aim_dir, player_pos, enemies, health, kinds[0..enemies.len], grid, &scores);
}

test "[auto_targetting] nearest visible enemy, or nothing" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, false);
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ 1, 0 }, &.{}, &grid) == null);

    const enemies = [_]Vec2f{ .{ -1.2, 0 }, .{ 0, -0.5 }, .{ 0.8, 0.6 } };
    const t = testFind(@splat(0), @splat(0), .{ 1, 0 }, &enemies, &grid).?;
    try std.testing.expect(t.pos[1] == -0.5);
    try std.testing.expectApproxEqAbs(t.dir[1], -1, 0.0001);
}

test "[auto_targetting] enemies off screen are ignored" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, false);
    //Close but above the top of the screen (it shows ~0.94m up and down), and beyond the right edge (~1.56m)
    const hidden = [_]Vec2f{ .{ 0, 1.2 }, .{ 1.8, 0 } };
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ 1, 0 }, &hidden, &grid) == null);

    const enemies = hidden ++ [_]Vec2f{.{ -1.5, 0.3 }};
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ 1, 0 }, &enemies, &grid).?.pos[0] == -1.5);
}

test "[auto_targetting] enemies behind walls are ignored" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, true);
    const enemies = [_]Vec2f{ .{ 1.3, 0 }, .{ 1.3, 0.3 }, .{ -1.5, 0 } }; //Two close ones behind the wall
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ 1, 0 }, &enemies, &grid).?.pos[0] == -1.5);
}

test "[auto_targetting] line of sight tests are bounded" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, true);
    //More enemies behind the wall than are tested: the one in the open further away is missed this frame
    var enemies: [consts.TARGET_MAX_LOS_TESTS + 1]Vec2f = undefined;
    for (&enemies, 0..) |*e, i| e.* = .{ 1.3, @as(f32, @floatFromInt(i)) * 0.05 };
    enemies[enemies.len - 1] = .{ -1.5, 0 };
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ 1, 0 }, &enemies, &grid) == null);
}

test "[auto_targetting] prefers enemies ahead of the player's movement, even when ringed" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, false);
    //Ringed by the horde, the one behind a touch closer and the aim elsewhere: moving right shoots the way out
    const ring = [_]Vec2f{ .{ -0.18, 0 }, .{ 0, 0.19 }, .{ 0.2, 0 }, .{ 0, -0.19 } };
    try std.testing.expect(testFind(@splat(0), .{ 1, 0 }, .{ 0, 1 }, &ring, &grid).?.pos[0] == 0.2);

    //Clear the way ahead before the closer enemy off to the side
    const ahead = [_]Vec2f{ .{ 0, 0.5 }, .{ 1.0, 0 } };
    try std.testing.expect(testFind(@splat(0), .{ 1, 0 }, .{ 0, 1 }, &ahead, &grid).?.pos[0] == 1.0);
    //...but not one that is much further away
    const far_ahead = [_]Vec2f{ .{ 0, 0.5 }, .{ 1.5, 0 } };
    try std.testing.expect(testFind(@splat(0), .{ 1, 0 }, .{ 0, 1 }, &far_ahead, &grid).?.pos[1] == 0.5);
}

test "[auto_targetting] keeps aiming at a target that is about as close as another" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, false);
    const enemies = [_]Vec2f{ .{ -0.5, 0 }, .{ 0.52, 0 } };
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ 1, 0 }, &enemies, &grid).?.pos[0] == 0.52);
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ -1, 0 }, &enemies, &grid).?.pos[0] == -0.5);
}

test "[auto_targetting] finishes off a damaged enemy knocked back out of the ring" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, false);
    //The last target took two hits and was knocked back a little out of the ring (~0.19m), off the aim
    const enemies = [_]Vec2f{ .{ 0.29, 0.06 }, .{ 0, 0.19 }, .{ -0.19, 0 } };
    const one_hit_left = consts.ENEMY_MAX_HEALTH - 2 * consts.DMG_PER_HIT;
    const health = [_]u8{ one_hit_left, consts.ENEMY_MAX_HEALTH, consts.ENEMY_MAX_HEALTH };
    try std.testing.expect(testFindHurt(@splat(0), @splat(0), .{ 1, 0 }, &enemies, &health, &grid).?.pos[0] == 0.29);
    //At full health the nearer ones win
    try std.testing.expect(testFind(@splat(0), @splat(0), .{ 1, 0 }, &enemies, &grid).?.pos[0] != 0.29);
}

test "[auto_targetting] a damaged enemy behind doesn't beat a fresh one in the player's way" {
    var cells: [30 * 30]bool = undefined;
    const grid = testGrid(&cells, false);
    //Ringed and moving right, aiming at the nearly dead enemy behind
    const ring = [_]Vec2f{ .{ -0.19, 0 }, .{ 0.2, 0 } };
    const health = [_]u8{ consts.ENEMY_MAX_HEALTH - 2 * consts.DMG_PER_HIT, consts.ENEMY_MAX_HEALTH };
    try std.testing.expect(testFindHurt(@splat(0), .{ 1, 0 }, .{ -1, 0 }, &ring, &health, &grid).?.pos[0] == 0.2);
}
