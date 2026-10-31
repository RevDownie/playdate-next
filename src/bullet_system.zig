/// Responsible for spawning a bullet and updating the lifetime state of active bullets
///
const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const kit_descs = @import("kit_descs.zig");
const Bullets = state.Bullets;
const Hit = state.Hit;

const Vec2f = @Vector(2, f32);

/// Each EnemyKind's hit circle, squared
const HIT_RADIUS_SQRD = blk: {
    var r: [consts.ENEMY_KINDS.len]f32 = undefined;
    for (&r, consts.ENEMY_KINDS) |*o, k| o.* = k.hit_radius * k.hit_radius;
    break :blk r;
};

//`collide` tests a point after each move, so a bullet must not step over an enemy's hit circle in one
//frame at TARGET_FPS (longer frames can, which is acceptable for the odd hitch)
comptime {
    var min_hit_radius: f32 = std.math.inf(f32);
    for (consts.ENEMY_KINDS) |k| min_hit_radius = @min(min_hit_radius, k.hit_radius);
    if (consts.BULLET_MAX_SPEED * consts.TARGET_FRAME_DT >= 2 * min_hit_radius) @compileError("Bullets are fast enough to skip over enemies in one frame");
}

/// Spawn a new bullet at `world_pos` (the player's feet) heading along `world_dir`, turned sideways by
/// `stray` (-1 to 1) times BULLET_SPREAD for a little machine gun scatter. Nothing fires when out of ammo: the
/// gun is only refilled by ammo drops (see drop_system).
/// Returns whether a shot went off
///
pub fn fire(bullets: *Bullets, world_pos: Vec2f, world_dir: Vec2f, stray: f32) bool {
    if (bullets.ammo == 0) return false;
    if (bullets.len >= Bullets.capacity) return false; //Pool exhausted - drop the shot rather than overrun

    const right = Vec2f{ world_dir[1], -world_dir[0] };
    const i = bullets.len;
    bullets.pos[i] = world_pos;
    bullets.dir[i] = maths.normaliseSafe(world_dir + right * @as(Vec2f, @splat(stray * consts.BULLET_SPREAD)), world_dir);
    bullets.barrel[i] = bullets.next_barrel;
    bullets.lifetime[i] = consts.BULLET_LIFETIME;
    bullets.len += 1;
    bullets.ammo -= 1;
    bullets.next_barrel = (bullets.next_barrel + 1) % consts.GUN_BARRELS;
    return true;
}

/// Age the bullets and move them along their trajectories. Each move is sampled at least every half
/// cell so a bullet can't tunnel through a wall; one that reaches a blocked cell (or leaves the map) stops
/// at its last free point. Expired and blocked bullets are flagged (lifetime <= 0) and removed by `Bullets.removeDead`
///
pub fn update(bullets: *Bullets, grid: *const CollisionGrid, dt: f32) void {
    const step = consts.BULLET_MAX_SPEED * dt;
    const num_samples: u32 = @intFromFloat(@max(@ceil(step / grid.sampleLength()), 1));
    const sample_step: Vec2f = @splat(step / @as(f32, @floatFromInt(num_samples)));

    for (bullets.pos[0..bullets.len], bullets.dir[0..bullets.len], bullets.lifetime[0..bullets.len]) |*p, d, *l| {
        l.* -= dt;
        if (grid.isOccupied(p.*)) { //Fired from inside a wall
            l.* = 0;
            continue;
        }
        for (0..num_samples) |_| {
            const next = p.* + d * sample_step;
            if (grid.isOccupied(next)) {
                l.* = 0;
                break;
            }
            p.* = next;
        }
    }
}

/// Check for collisions between the live bullets and the given entities using circle - point tests.
/// Each bullet hits at most one entity and is then flagged dead. Writes into `hits_out` (which must hold
/// one entry per bullet) and returns the filled part. Brute force: every pair is a cheap test against data that stays
/// in the L1 cache (COLLISION_HOT_SET_BYTES)
///
pub fn collide(bullets: *Bullets, enemy_positions: []const Vec2f, enemy_kinds: []const state.EnemyKind, hits_out: []Hit) []Hit {
    std.debug.assert(hits_out.len >= bullets.len and enemy_kinds.len >= enemy_positions.len);
    var num_hits: usize = 0;

    for (bullets.pos[0..bullets.len], bullets.lifetime[0..bullets.len], 0..) |bullet_pos, *lifetime, bullet_idx| {
        if (lifetime.* <= 0) continue;
        for (enemy_positions, enemy_kinds[0..enemy_positions.len], 0..) |enemy_pos, kind, enemy_idx| {
            if (maths.magnitudeSqrd(enemy_pos - bullet_pos) <= HIT_RADIUS_SQRD[@backingInt(kind)]) {
                hits_out[num_hits] = .{ .enemy_idx = @intCast(enemy_idx), .impact_dir = bullets.dir[bullet_idx] };
                num_hits += 1;
                lifetime.* = 0; //Destroy the bullet
                break;
            }
        }
    }

    return hits_out[0..num_hits];
}

/// 30x30 grid of 64px (0.5m) cells with nothing in it, so bullets fired from the origin expire before the map's edge
const open_cells: [30 * 30]bool = @splat(false);
const OPEN_GRID = CollisionGrid{ .cells = &open_cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 };
comptime {
    for ([_]Vec2f{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
        if (OPEN_GRID.isOccupied(d * @as(Vec2f, @splat(consts.BULLET_RANGE)))) @compileError("OPEN_GRID is smaller than BULLET_RANGE: test bullets would hit its edge before they expire");
    }
}

test "[bullet_system] an empty gun stays empty until ammo is picked up" {
    var b = Bullets{};
    b.ammo = 1;
    try std.testing.expect(fire(&b, @splat(0), Vec2f{ 1, 0 }, 0));
    try std.testing.expect(b.len == 1 and b.ammo == 0);

    try std.testing.expect(!fire(&b, @splat(0), Vec2f{ 1, 0 }, 0)); //Empty: nothing happens, and it never refills by itself
    update(&b, &OPEN_GRID, 10);
    try std.testing.expect(b.len == 1 and b.ammo == 0);

    b.ammo = 10; //As if an ammo drop was picked up: it fires straight away
    try std.testing.expect(fire(&b, @splat(0), Vec2f{ 1, 0 }, 0));
    try std.testing.expect(b.ammo == 9);
}

test "[bullet_system] fire never overruns the pool" {
    var b = Bullets{};
    b.ammo = 255;
    for (0..@as(usize, Bullets.capacity) + 5) |_| _ = fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
    try std.testing.expect(b.len == Bullets.capacity);
}

test "[bullet_system] expired bullets are all removed in one pass" {
    var b = Bullets{};
    for (0..4) |_| _ = fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
    var t: f32 = 0;
    while (t < consts.BULLET_LIFETIME - 0.05) : (t += 0.01) update(&b, &OPEN_GRID, 0.01);
    b.removeDead();
    try std.testing.expect(b.len == 4); //Still in flight just short of BULLET_RANGE
    update(&b, &OPEN_GRID, 0.1);
    b.removeDead();
    try std.testing.expect(b.len == 0);
}

test "[bullet_system] each bullet hits one enemy once" {
    var b = Bullets{};
    _ = fire(&b, Vec2f{ 0, 0 }, Vec2f{ 1, 0 }, 0);
    _ = fire(&b, Vec2f{ 5, 0 }, Vec2f{ 1, 0 }, 0);
    const enemies = [_]Vec2f{ Vec2f{ 0, 0 }, Vec2f{ 0.01, 0 }, Vec2f{ 100, 0 } };
    const kinds: [3]state.EnemyKind = @splat(.walker);
    var hits: [Bullets.capacity]Hit = undefined;

    const first = collide(&b, &enemies, &kinds, &hits);
    try std.testing.expect(first.len == 1);
    try std.testing.expect(first[0].enemy_idx == 0);

    //The bullet that hit is dead so can't hit again before it is removed
    const second = collide(&b, &enemies, &kinds, &hits);
    try std.testing.expect(second.len == 0);
}

test "[bullet_system] big enemies are easier to hit than small ones" {
    var b = Bullets{};
    const off = (consts.CHAR_BULLET_COLL_RADIUS + state.EnemyKind.brute.def().hit_radius) / 2; //Inside a brute, outside a walker
    _ = fire(&b, Vec2f{ 0, off }, Vec2f{ 1, 0 }, 0);
    _ = fire(&b, Vec2f{ 5, off }, Vec2f{ 1, 0 }, 0);
    const enemies = [_]Vec2f{ Vec2f{ 0, 0 }, Vec2f{ 5, 0 } };
    const kinds = [_]state.EnemyKind{ .walker, .brute };
    var hits: [Bullets.capacity]Hit = undefined;
    const got = collide(&b, &enemies, &kinds, &hits);
    try std.testing.expect(got.len == 1 and got[0].enemy_idx == 1);
}

test "[bullet_system] walls one level cell thick stop bullets, even on the longest frame" {
    //The levels' cells, with a wall down the column two right of the origin and along the row two above it. A row
    //is the thin way through (CELL_H), which a bullet crosses several times over on a MAX_FRAME_DT step
    const n = 30;
    const centre: u16 = (n / 2) * n + n / 2;
    var cells: [n * n]bool = @splat(false);
    for (0..n) |i| {
        cells[i * n + n / 2 + 2] = true;
        cells[(n / 2 - 2) * n + i] = true;
    }
    const grid = CollisionGrid{ .cells = &cells, .width = n, .height = n, .cell_width = kit_descs.CELL_W, .cell_height = kit_descs.CELL_H };
    const right_face = (grid.cellCentre(centre + 1)[0] + grid.cellCentre(centre + 2)[0]) / 2;
    const top_face = (grid.cellCentre(centre - n)[1] + grid.cellCentre(centre - 2 * n)[1]) / 2;

    for ([_]f32{ consts.TARGET_FRAME_DT, consts.MAX_FRAME_DT }) |dt| {
        var b = Bullets{};
        for ([_]Vec2f{ .{ 1, 0 }, .{ 1, 0.3 }, .{ 0, 1 }, .{ 0.3, 1 } }) |d| _ = fire(&b, @splat(0), maths.normaliseSafe(d, @splat(0)), 0);
        var t: f32 = 0;
        while (b.len > 0) : (t += dt) {
            update(&b, &grid, dt);
            for (b.positions()) |p| try std.testing.expect(p[0] < right_face and p[1] < top_face);
            b.removeDead();
        }
        try std.testing.expect(t < consts.BULLET_LIFETIME / 2); //Stopped by the walls, not expired
    }
}

test "[bullet_system] a bullet fired inside a wall or off the map dies at once" {
    var cells: [30 * 30]bool = @splat(false);
    cells[15 * 30 + 15] = true; //The origin
    const grid = CollisionGrid{ .cells = &cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 };

    var b = Bullets{};
    _ = fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
    _ = fire(&b, Vec2f{ 7.2, 3 }, Vec2f{ 1, 0 }, 0); //Leaves the map this frame
    update(&b, &grid, consts.TARGET_FRAME_DT);
    b.removeDead();
    try std.testing.expect(b.len == 0);
}

test "[bullet_system] spread strays a little and the barrels turn with each shot" {
    var b = Bullets{};
    for (0..consts.GUN_BARRELS + 1) |_| _ = fire(&b, @splat(0), Vec2f{ 0, 1 }, 1);
    const d = b.dir[0];
    try std.testing.expectApproxEqAbs(maths.magnitude(d), 1, 0.0001);
    try std.testing.expect(d[0] > 0 and d[0] < consts.BULLET_SPREAD * 1.01); //Full stray is to the right
    for (0..consts.GUN_BARRELS) |i| try std.testing.expect(b.barrel[i] == i);
    try std.testing.expect(b.barrel[consts.GUN_BARRELS] == 0);
}
