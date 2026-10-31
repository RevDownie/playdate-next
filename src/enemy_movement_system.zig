const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const memory = @import("memory.zig");
const Enemies = @import("game_state.zig").Enemies;
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const flow = @import("flow_field.zig");
const FlowField = flow.FlowField;

const Vec2f = @Vector(2, f32);

/// Animate:
/// * Entities moving towards the player target, following the flow field around obstacles
/// * Entities bumping back in response to a collision
///
/// Walls come from the flow field
///
pub fn update(enemies: *Enemies, field: *const FlowField, grid: *const CollisionGrid, player_world_pos: Vec2f, dt: f32) void {
    for (0..enemies.len) |i| {
        if (enemies.isBumping(i)) {
            updateBumpBack(enemies, i, field, grid, dt);
        } else {
            updateSeeking(enemies, i, field, grid, player_world_pos, dt);
        }
    }
}

/// Enemies seek out the player and move towards them to attack. They take the flow field's step for their
/// cell, and head straight for the player once in the player's cell or one step from it (or with no path).
/// A cell and the neighbour the field steps to are both free and together form a rectangle, so the straight
/// line can't clip scenery. The heading is eased towards the new one so the turns between cells don't snap
///
fn updateSeeking(enemies: *Enemies, i: usize, field: *const FlowField, grid: *const CollisionGrid, player_world_pos: Vec2f, dt: f32) void {
    const pos = enemies.pos[i];
    const cell = grid.cellIndex(pos);
    const dir = field.at(cell);
    const to_target = player_world_pos - pos;
    const mag = maths.magnitude(to_target);

    const follow_field = dir < flow.DIR_GOAL and field.dir[field.nextCell(cell.?, dir)] != flow.DIR_GOAL;
    const desired = if (follow_field)
        field.dir_vecs[dir] * @as(Vec2f, @splat(enemies.speed[i]))
    else
        maths.normaliseSafeMag(to_target, mag, enemies.vel[i]) * @as(Vec2f, @splat(@min(enemies.speed[i], mag)));

    const vel = enemies.vel[i] + (desired - enemies.vel[i]) * @as(Vec2f, @splat(@min(consts.ENEMY_TURN_RATE * dt, 1.0)));
    enemies.vel[i] = vel;
    enemies.pos[i] = field.slide(grid, pos, pos + vel * @as(Vec2f, @splat(dt)), dir == flow.DIR_BLOCKED);
}

/// Animated push back. Seeking resumes once the timer reaches BUMP_TIME. Each frame moves by this frame's
/// share of the eased offset and slides along walls, so a knock back can't push an enemy into (or, held
/// against a wall, jump over) the scenery
///
fn updateBumpBack(enemies: *Enemies, i: usize, field: *const FlowField, grid: *const CollisionGrid, dt: f32) void {
    const prev_y = easeOutBack(enemies.bump_timer[i] / consts.BUMP_TIME);
    enemies.bump_timer[i] = @min(enemies.bump_timer[i] + dt, consts.BUMP_TIME);
    const y = easeOutBack(enemies.bump_timer[i] / consts.BUMP_TIME);
    const pos = enemies.pos[i];
    const step = enemies.bump_offset[i] * @as(Vec2f, @splat(y - prev_y));
    enemies.pos[i] = field.slide(grid, pos, pos + step, field.isBlocked(grid, pos));
}

/// Easing function to animate the bump back
///
fn easeOutBack(x: f32) f32 {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    const xminus = x - 1;
    return 1 + c3 * (xminus * xminus * xminus) + c1 * (xminus * xminus);
}

const SEPARATION_DIST_SQRD = consts.ENEMY_SEPARATION_DIST * consts.ENEMY_SEPARATION_DIST;
const PLAYER_RING_RADIUS_SQRD = consts.PLAYER_RING_RADIUS * consts.PLAYER_RING_RADIUS;
const MAX_PUSH_SQRD = consts.ENEMY_SEPARATION_MAX_PUSH * consts.ENEMY_SEPARATION_MAX_PUSH;

/// The separation pair loop re-reads every enemy position (and, for overlapping pairs, whether it is bumping) for
/// each enemy and accumulates into a push per enemy, so all of those need to stay resident in the cache together
pub const SEPARATION_HOT_SET_BYTES = @sizeOf(@FieldType(Enemies, "pos")) + @sizeOf(@FieldType(Enemies, "bump_timer")) + @as(usize, Enemies.capacity) * @sizeOf(Vec2f);
comptime {
    if (SEPARATION_HOT_SET_BYTES > memory.HOT_SET_BUDGET) @compileError("Enemy separation data no longer fits the L1 hot set budget");
}

/// Run after `update`. Stop enemies stacking up: every pair closer than ENEMY_SEPARATION_DIST is pushed apart by the overlap
/// (half each), and enemies are kept PLAYER_RING_RADIUS from the player so the horde rings them rather than
/// piling onto one point (still inside contact range, so contact damage happens as before).
/// Positional rather than a steering force, so overlap can't build up however hard the flow field pulls.
/// An enemy that is bumping back isn't pushed (the crowd can't shove it straight back in) and the other of
/// the pair takes the whole push. Each enemy's total push is capped and goes through the wall slide.
///
/// Brute force over all pairs: at MAX_ENEMIES that is a fixed ~5k cheap distance tests against data that
/// sits in the L1 cache (SEPARATION_HOT_SET_BYTES), which costs about what a spatial hash would to maintain.
/// `push` is per frame scratch with room for every enemy
///
pub fn separate(enemies: *Enemies, player_world_pos: Vec2f, field: *const FlowField, grid: *const CollisionGrid, push: []Vec2f) void {
    const n = enemies.len;
    const pos = enemies.pos[0..n];
    const pushes = push[0..n];
    @memset(pushes, @splat(0));

    for (0..n) |i| {
        const p = pos[i];
        for (i + 1..n) |j| {
            const d = pos[j] - p;
            const dist_sqrd = maths.magnitudeSqrd(d);
            if (dist_sqrd >= SEPARATION_DIST_SQRD) continue;
            pushApart(enemies, pushes, i, j, d, dist_sqrd);
        }
    }

    for (0..n) |i| {
        if (enemies.isBumping(i)) continue;
        var p = pushes[i] + ringPush(pos[i] + pushes[i], player_world_pos);
        const push_sqrd = maths.magnitudeSqrd(p);
        if (push_sqrd == 0) continue;
        if (push_sqrd > MAX_PUSH_SQRD) p *= @as(Vec2f, @splat(consts.ENEMY_SEPARATION_MAX_PUSH / @sqrt(push_sqrd)));
        pos[i] = field.slide(grid, pos[i], pos[i] + p, field.isBlocked(grid, pos[i]));
    }
}

/// Split the overlap of enemies `i` and `j` (`d` is from i to j) between their pushes. Kept out of line as
/// only overlapping pairs get here, which keeps the pair loop small
///
fn pushApart(enemies: *const Enemies, pushes: []Vec2f, i: usize, j: usize, d: Vec2f, dist_sqrd: f32) void {
    const i_bumping = enemies.isBumping(i);
    const j_bumping = enemies.isBumping(j);
    if (i_bumping and j_bumping) return;

    const dist = @sqrt(dist_sqrd);
    const dir = if (dist > 0) d / @as(Vec2f, @splat(dist)) else Vec2f{ 1, 0 }; //Exactly stacked: split along x
    const overlap = consts.ENEMY_SEPARATION_DIST - dist;
    const share_i: f32 = if (i_bumping) 0 else if (j_bumping) 1 else 0.5;
    pushes[i] -= dir * @as(Vec2f, @splat(overlap * share_i));
    pushes[j] += dir * @as(Vec2f, @splat(overlap * (1 - share_i)));
}

/// The push that moves an enemy at `pos` out to the player's ring, or zero if it is already outside it
///
fn ringPush(pos: Vec2f, player_world_pos: Vec2f) Vec2f {
    const d = pos - player_world_pos;
    const dist_sqrd = maths.magnitudeSqrd(d);
    if (dist_sqrd >= PLAYER_RING_RADIUS_SQRD) return @splat(0);
    const dist = @sqrt(dist_sqrd);
    const dir = if (dist > 0) d / @as(Vec2f, @splat(dist)) else Vec2f{ 1, 0 };
    return dir * @as(Vec2f, @splat(consts.PLAYER_RING_RADIUS - dist));
}

const TestLevel = struct {
    cells: [20 * 20]bool,
    buffer: [8 * 1024]u8,
    arena: memory.Arena,
    grid: CollisionGrid,
    field: FlowField,
    push: [Enemies.capacity]Vec2f,

    /// 20x20 grid of 64px (0.5m) cells, optionally with a wall in column `wall_col` from row 4 to 15
    ///
    fn init(self: *TestLevel, wall_col: ?u8, goal: Vec2f) void {
        @memset(&self.cells, false);
        if (wall_col) |c| {
            for (4..16) |row| self.cells[row * 20 + c] = true;
        }
        self.grid = .{ .cells = &self.cells, .width = 20, .height = 20, .cell_width = 64, .cell_height = 64 };
        self.arena = .init("level", &self.buffer);
        self.field = FlowField.init(&self.arena, &self.grid, self.grid.cellIndex(goal));
    }

    fn separateAt(self: *TestLevel, enemies: *Enemies, player: Vec2f) void {
        separate(enemies, player, &self.field, &self.grid, &self.push);
    }
};

test "[enemy_movement_system] bump back lands at the full offset then seeks again" {
    var lvl: TestLevel = undefined;
    lvl.init(null, Vec2f{ 4, 0 });
    var e = Enemies{};
    e.add(Vec2f{ 0, 0 });
    e.startBumpBack(0, Vec2f{ 1, 0 }, 0.5);
    try std.testing.expect(e.isBumping(0));

    update(&e, &lvl.field, &lvl.grid, Vec2f{ 4, 0 }, consts.BUMP_TIME);
    try std.testing.expect(!e.isBumping(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.pos[0][0], 0.001);

    //Next frame it moves towards the player again
    update(&e, &lvl.field, &lvl.grid, Vec2f{ 4, 0 }, 0.1);
    try std.testing.expect(e.pos[0][0] > 0.5);
}

test "[enemy_movement_system] enemies path around a wall instead of walking into it" {
    //Wall at column 12 (x = 1m) between the enemy at x = 2.5 and the player at x = -2
    const player = Vec2f{ -2, 0 };
    var lvl: TestLevel = undefined;
    lvl.init(12, player);
    var e = Enemies{};
    e.add(Vec2f{ 2.5, 0 });

    var frames: u32 = 0;
    while (maths.magnitude(e.pos[0] - player) > 0.1 and frames < 30 * 20) : (frames += 1) {
        update(&e, &lvl.field, &lvl.grid, player, 1.0 / 30.0);
        try std.testing.expect(!lvl.grid.isOccupied(e.pos[0]));
    }
    try std.testing.expect(maths.magnitude(e.pos[0] - player) <= 0.1);
}

test "[enemy_movement_system] an enemy close to the player goes round a single obstacle between them" {
    //Level sized cells (57x27px, 0.21m tall): the player is directly below a blocked cell and the enemy two
    //rows above it, so the straight line to the player (0.42m) runs into the obstacle
    var cells: [9 * 9]bool = @splat(false);
    cells[4 * 9 + 4] = true;
    const grid = CollisionGrid{ .cells = &cells, .width = 9, .height = 9, .cell_width = 57, .cell_height = 27 };
    var buffer: [2048]u8 = undefined;
    var arena = memory.Arena.init("level", &buffer);
    const player = grid.cellCentre(5 * 9 + 4);
    const field = FlowField.init(&arena, &grid, grid.cellIndex(player));
    var e = Enemies{};
    e.add(grid.cellCentre(3 * 9 + 4));

    var frames: u32 = 0;
    while (maths.magnitude(e.pos[0] - player) > 0.05 and frames < 30 * 5) : (frames += 1) {
        update(&e, &field, &grid, player, 1.0 / 30.0);
        try std.testing.expect(!grid.isOccupied(e.pos[0]));
    }
    try std.testing.expect(maths.magnitude(e.pos[0] - player) <= 0.05);
}

test "[enemy_movement_system] a bump into a wall stops at the wall" {
    //The wall's left edge is at x = 0.75m
    var lvl: TestLevel = undefined;
    lvl.init(12, Vec2f{ -2, 0 });
    var e = Enemies{};
    e.add(Vec2f{ 0.65, 0 });
    e.startBumpBack(0, Vec2f{ 1, 0 }, consts.BUMP_DISTANCE);
    for (0..15) |_| {
        update(&e, &lvl.field, &lvl.grid, Vec2f{ -2, 0 }, 1.0 / 30.0);
        try std.testing.expect(!lvl.grid.isOccupied(e.pos[0]));
    }
    try std.testing.expect(e.pos[0][0] < 0.75);
}

test "[enemy_movement_system] each enemy seeks at its own speed" {
    var cells: [9 * 9]bool = @splat(false);
    const grid = CollisionGrid{ .cells = &cells, .width = 9, .height = 9, .cell_width = 64, .cell_height = 64 };
    var buffer: [8 * 1024]u8 = undefined;
    var arena = memory.Arena.init("level", &buffer);
    const field = FlowField.init(&arena, &grid, grid.cellIndex(@splat(0)));
    var e = Enemies{};
    e.addKind(Vec2f{ -1.5, 0 }, .walker, consts.ENEMY_SLOW_SPEED);
    e.addKind(Vec2f{ 1.5, 0 }, .walker, consts.ENEMY_RUNNER_SPEED);
    for (0..30) |_| update(&e, &field, &grid, @splat(0), 1.0 / 50.0);
    //Up to speed after easing in: the runner has covered more ground
    try std.testing.expect(1.5 - @abs(e.pos[1][0]) > 1.5 - @abs(e.pos[0][0]) + 0.1);
    try std.testing.expect(maths.magnitude(e.vel[1]) > consts.PLAYER_MAX_SPEED);
}

const FAR_PLAYER = Vec2f{ -4, -4 };

fn minPairDist(enemies: *const Enemies) f32 {
    var min: f32 = std.math.inf(f32);
    for (0..enemies.len) |i| {
        for (i + 1..enemies.len) |j| min = @min(min, maths.magnitude(enemies.pos[j] - enemies.pos[i]));
    }
    return min;
}

test "[enemy_movement_system] separation: stacked enemies are pushed apart" {
    var lvl: TestLevel = undefined;
    lvl.init(null, @splat(0));
    var e = Enemies{};
    e.add(Vec2f{ 1, 1 });
    e.add(Vec2f{ 1, 1 });

    //The full separation is more than one frame's capped push
    lvl.separateAt(&e, FAR_PLAYER);
    try std.testing.expectApproxEqAbs(consts.ENEMY_SEPARATION_MAX_PUSH * 2, minPairDist(&e), 0.001);
    lvl.separateAt(&e, FAR_PLAYER);
    try std.testing.expect(minPairDist(&e) >= consts.ENEMY_SEPARATION_DIST - 0.001);
    //Pushed equally either side of where they were
    try std.testing.expectApproxEqAbs(@as(f32, 2), e.pos[0][0] + e.pos[1][0], 0.001);
}

test "[enemy_movement_system] separation: a bumping enemy isn't pushed, the other takes the whole push" {
    var lvl: TestLevel = undefined;
    lvl.init(null, @splat(0));
    var e = Enemies{};
    e.add(Vec2f{ 1, 1 });
    e.add(Vec2f{ 1.2, 1 });
    e.startBumpBack(0, Vec2f{ 0, 1 }, 0);

    lvl.separateAt(&e, FAR_PLAYER);
    try std.testing.expect(e.pos[0][0] == 1 and e.pos[0][1] == 1);
    try std.testing.expectApproxEqAbs(1 + consts.ENEMY_SEPARATION_DIST, e.pos[1][0], 0.001);
}

test "[enemy_movement_system] separation: enemies ring the player instead of standing on them" {
    var lvl: TestLevel = undefined;
    lvl.init(null, @splat(0));
    var e = Enemies{};
    const player = Vec2f{ 1, 1 };
    e.add(player + Vec2f{ 0.05, 0 });
    e.add(player);

    for (0..4) |_| lvl.separateAt(&e, player);
    for (e.positions()) |p| {
        const d = maths.magnitude(p - player);
        try std.testing.expect(d >= consts.PLAYER_RING_RADIUS - 0.001);
        try std.testing.expect(d <= consts.CHAR_ENEMY_COLL_RADIUS); //Still close enough to hurt the player
    }
}

test "[enemy_movement_system] separation: pushes don't move enemies into walls" {
    //Column 12 is blocked: x from 0.75m to 1.25m
    var lvl: TestLevel = undefined;
    lvl.init(12, @splat(0));
    var e = Enemies{};
    e.add(Vec2f{ 0.6, 0 });
    e.add(Vec2f{ 0.5, 0 }); //Shoves the first one towards the wall

    for (0..5) |_| {
        lvl.separateAt(&e, FAR_PLAYER);
        for (e.positions()) |p| try std.testing.expect(!lvl.grid.isOccupied(p));
    }
    try std.testing.expect(e.pos[0][0] < 0.75);
}

test "[enemy_movement_system] separation: a full horde dropped on one spot spreads out" {
    var lvl: TestLevel = undefined;
    lvl.init(null, @splat(0));
    var e = Enemies{};
    var prng = std.Random.DefaultPrng.init(3);
    for (0..Enemies.capacity) |_| e.add(Vec2f{ 1, 1 } + Vec2f{ prng.random().float(f32), prng.random().float(f32) } * @as(Vec2f, @splat(0.05)));

    //One pass a frame with a capped push, so a pile this dense takes a few seconds (at 30 FPS) to fully settle
    for (0..120) |_| lvl.separateAt(&e, FAR_PLAYER);
    try std.testing.expect(minPairDist(&e) >= consts.ENEMY_SEPARATION_DIST * 0.9);
}
