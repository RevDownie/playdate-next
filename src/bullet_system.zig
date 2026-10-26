const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const Bullets = state.Bullets;
const Hit = state.Hit;

const Vec2f = @Vector(2, f32);

const BULLET_MAX_SPEED_V: Vec2f = @splat(consts.BULLET_MAX_SPEED);
const CHAR_BULLET_COLL_RADIUS_SQRD = consts.CHAR_BULLET_COLL_RADIUS * consts.CHAR_BULLET_COLL_RADIUS;

/// Spawn a new bullet that moves along the given trajectory. Firing an empty magazine starts the reload
///
pub fn fire(bullets: *Bullets, world_pos: Vec2f, world_dir: Vec2f) void {
    if (bullets.isReloading()) return;

    if (bullets.magazine == 0) {
        bullets.reload_timer = consts.RELOAD_TIME;
        return;
    }

    if (bullets.len >= Bullets.capacity) return; //Pool exhausted - drop the shot rather than overrun

    const i = bullets.len;
    bullets.pos[i] = world_pos;
    bullets.dir[i] = world_dir;
    bullets.lifetime[i] = consts.BULLET_LIFETIME;
    bullets.len += 1;
    bullets.magazine -= 1;
}

/// Reload, age the bullets and move them along their trajectories.
/// Expired bullets are flagged (lifetime <= 0) and removed by `Bullets.removeDead`
///
pub fn update(bullets: *Bullets, dt: f32) void {
    if (bullets.isReloading()) {
        bullets.reload_timer -= dt;
        if (!bullets.isReloading()) bullets.magazine = consts.BULLET_MAG_SIZE;
    }

    const dt_v: Vec2f = @splat(dt);
    for (bullets.pos[0..bullets.len], bullets.dir[0..bullets.len], bullets.lifetime[0..bullets.len]) |*p, d, *l| {
        l.* -= dt;
        p.* += d * BULLET_MAX_SPEED_V * dt_v;
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

test "[bullet_system] fire drains the magazine then reloads" {
    var b = Bullets{};
    b.magazine = 1;
    fire(&b, @splat(0), Vec2f{ 1, 0 });
    try std.testing.expect(b.len == 1 and b.magazine == 0);

    fire(&b, @splat(0), Vec2f{ 1, 0 }); //Empty - starts the reload instead
    try std.testing.expect(b.len == 1 and b.isReloading());

    update(&b, consts.RELOAD_TIME + 0.01);
    try std.testing.expect(!b.isReloading() and b.magazine == consts.BULLET_MAG_SIZE);
}

test "[bullet_system] fire never overruns the pool" {
    var b = Bullets{};
    b.magazine = 255;
    for (0..@as(usize, Bullets.capacity) + 5) |_| fire(&b, @splat(0), Vec2f{ 1, 0 });
    try std.testing.expect(b.len == Bullets.capacity);
}

test "[bullet_system] expired bullets are all removed in one pass" {
    var b = Bullets{};
    for (0..4) |_| fire(&b, @splat(0), Vec2f{ 1, 0 });
    update(&b, consts.BULLET_LIFETIME + 0.1);
    b.removeDead();
    try std.testing.expect(b.len == 0);
}

test "[bullet_system] each bullet hits one enemy once" {
    var b = Bullets{};
    fire(&b, Vec2f{ 0, 0 }, Vec2f{ 1, 0 });
    fire(&b, Vec2f{ 5, 0 }, Vec2f{ 1, 0 });
    const enemies = [_]Vec2f{ Vec2f{ 0, 0 }, Vec2f{ 0.01, 0 }, Vec2f{ 100, 0 } };
    var hits: [Bullets.capacity]Hit = undefined;

    const first = collide(&b, &enemies, &hits);
    try std.testing.expect(first.len == 1);
    try std.testing.expect(first[0].enemy_idx == 0);

    //The bullet that hit is dead so can't hit again before it is removed
    const second = collide(&b, &enemies, &hits);
    try std.testing.expect(second.len == 0);
}
