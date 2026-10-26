const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const Bullets = state.Bullets;
const Hit = state.Hit;

const Vec2f = @Vector(2, f32);

const CHAR_BULLET_COLL_RADIUS_SQRD = consts.CHAR_BULLET_COLL_RADIUS * consts.CHAR_BULLET_COLL_RADIUS;

/// `collide` tests a point after each move, so a bullet must not step over an enemy's hit circle in one
/// frame at the target 50 FPS (longer frames can, which is acceptable for the odd hitch)
const TARGET_FRAME_DT: f32 = 1.0 / 50.0;
comptime {
    if (consts.BULLET_MAX_SPEED * TARGET_FRAME_DT >= 2 * consts.CHAR_BULLET_COLL_RADIUS) @compileError("Bullets are fast enough to skip over enemies in one frame");
}

/// Spawn a new bullet at `world_pos` (the player's feet) heading along `world_dir`, turned sideways by
/// `stray` (-1 to 1) times BULLET_SPREAD for a little machine gun scatter. Firing an empty magazine starts the reload
///
pub fn fire(bullets: *Bullets, world_pos: Vec2f, world_dir: Vec2f, stray: f32) void {
    if (bullets.isReloading()) return;

    if (bullets.magazine == 0) {
        bullets.reload_timer = consts.RELOAD_TIME;
        return;
    }

    if (bullets.len >= Bullets.capacity) return; //Pool exhausted - drop the shot rather than overrun

    const right = Vec2f{ world_dir[1], -world_dir[0] };
    const i = bullets.len;
    bullets.pos[i] = world_pos;
    bullets.dir[i] = maths.normaliseSafe(world_dir + right * @as(Vec2f, @splat(stray * consts.BULLET_SPREAD)), world_dir);
    bullets.barrel[i] = bullets.next_barrel;
    bullets.lifetime[i] = consts.BULLET_LIFETIME;
    bullets.len += 1;
    bullets.magazine -= 1;
    bullets.next_barrel = (bullets.next_barrel + 1) % consts.GUN_BARRELS;
}

/// Reload, age the bullets and move them along their trajectories. Each move is sampled at least every half
/// cell so a bullet can't tunnel through a wall; one that reaches a blocked cell (or leaves the map) stops
/// at its last free point. Expired and blocked bullets are flagged (lifetime <= 0) and removed by `Bullets.removeDead`
///
pub fn update(bullets: *Bullets, grid: *const CollisionGrid, dt: f32) void {
    if (bullets.isReloading()) {
        bullets.reload_timer -= dt;
        if (!bullets.isReloading()) bullets.magazine = consts.BULLET_MAG_SIZE;
    }

    const step = consts.BULLET_MAX_SPEED * dt;
    const sample_len = @as(f32, @floatFromInt(@min(grid.cell_width, grid.cell_height))) / consts.METRES_TO_PIXELS * 0.5;
    const num_samples: u32 = @intFromFloat(@max(@ceil(step / sample_len), 1));
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
/// one entry per bullet) and returns the filled part.
///
/// TODO: Non brute force collision
///
pub fn collide(bullets: *Bullets, enemy_positions: []const Vec2f, hits_out: []Hit) []Hit {
    std.debug.assert(hits_out.len >= bullets.len);
    var num_hits: usize = 0;

    for (bullets.pos[0..bullets.len], bullets.lifetime[0..bullets.len], 0..) |bullet_pos, *lifetime, bullet_idx| {
        if (lifetime.* <= 0) continue;
        for (enemy_positions, 0..) |enemy_pos, enemy_idx| {
            if (maths.magnitudeSqrd(enemy_pos - bullet_pos) <= CHAR_BULLET_COLL_RADIUS_SQRD) {
                hits_out[num_hits] = .{ .enemy_idx = @intCast(enemy_idx), .impact_dir = bullets.dir[bullet_idx] };
                num_hits += 1;
                lifetime.* = 0; //Destroy the bullet
                break;
            }
        }
    }

    return hits_out[0..num_hits];
}

/// 30x30 grid of 64px (0.5m) cells with nothing in it: the map's edge (+-7.5m) is beyond BULLET_RANGE from the origin
const open_cells: [30 * 30]bool = @splat(false);
const OPEN_GRID = CollisionGrid{ .cells = &open_cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 };

test "[bullet_system] fire drains the magazine then reloads" {
    var b = Bullets{};
    b.magazine = 1;
    fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
    try std.testing.expect(b.len == 1 and b.magazine == 0);

    fire(&b, @splat(0), Vec2f{ 1, 0 }, 0); //Empty - starts the reload instead
    try std.testing.expect(b.len == 1 and b.isReloading());

    update(&b, &OPEN_GRID, consts.RELOAD_TIME + 0.01);
    try std.testing.expect(!b.isReloading() and b.magazine == consts.BULLET_MAG_SIZE);
}

test "[bullet_system] fire never overruns the pool" {
    var b = Bullets{};
    b.magazine = 255;
    for (0..@as(usize, Bullets.capacity) + 5) |_| fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
    try std.testing.expect(b.len == Bullets.capacity);
}

test "[bullet_system] expired bullets are all removed in one pass" {
    var b = Bullets{};
    for (0..4) |_| fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
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
    fire(&b, Vec2f{ 0, 0 }, Vec2f{ 1, 0 }, 0);
    fire(&b, Vec2f{ 5, 0 }, Vec2f{ 1, 0 }, 0);
    const enemies = [_]Vec2f{ Vec2f{ 0, 0 }, Vec2f{ 0.01, 0 }, Vec2f{ 100, 0 } };
    var hits: [Bullets.capacity]Hit = undefined;

    const first = collide(&b, &enemies, &hits);
    try std.testing.expect(first.len == 1);
    try std.testing.expect(first[0].enemy_idx == 0);

    //The bullet that hit is dead so can't hit again before it is removed
    const second = collide(&b, &enemies, &hits);
    try std.testing.expect(second.len == 0);
}

test "[bullet_system] walls stop bullets, even on the longest frame" {
    //Same 0.5m cells, with a one cell thick wall in column 17 (x = 1m)
    var cells: [30 * 30]bool = @splat(false);
    for (0..30) |row| cells[row * 30 + 17] = true;
    const grid = CollisionGrid{ .cells = &cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 };

    for ([_]f32{ 1.0 / 50.0, consts.MAX_FRAME_DT }) |dt| {
        var b = Bullets{};
        fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
        fire(&b, @splat(0), maths.normalise(Vec2f{ 1, 0.3 }), 0);
        while (b.len > 0) {
            update(&b, &grid, dt);
            for (b.positions()) |p| try std.testing.expect(p[0] < 0.75); //The wall's near face
            b.removeDead();
        }
    }
}

test "[bullet_system] a bullet fired inside a wall or off the map dies at once" {
    var cells: [30 * 30]bool = @splat(false);
    cells[15 * 30 + 15] = true; //The origin
    const grid = CollisionGrid{ .cells = &cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 };

    var b = Bullets{};
    fire(&b, @splat(0), Vec2f{ 1, 0 }, 0);
    fire(&b, Vec2f{ 7.2, 3 }, Vec2f{ 1, 0 }, 0); //Leaves the map this frame
    update(&b, &grid, 1.0 / 50.0);
    b.removeDead();
    try std.testing.expect(b.len == 0);
}

test "[bullet_system] spread strays a little and the barrels turn with each shot" {
    var b = Bullets{};
    for (0..consts.GUN_BARRELS + 1) |_| fire(&b, @splat(0), Vec2f{ 0, 1 }, 1);
    const d = b.dir[0];
    try std.testing.expectApproxEqAbs(maths.magnitude(d), 1, 0.0001);
    try std.testing.expect(d[0] > 0 and d[0] < consts.BULLET_SPREAD * 1.01); //Full stray is to the right
    for (0..consts.GUN_BARRELS) |i| try std.testing.expect(b.barrel[i] == i);
    try std.testing.expect(b.barrel[consts.GUN_BARRELS] == 0);
}
