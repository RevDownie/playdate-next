const std = @import("std");
const consts = @import("tweak_constants.zig");
const bitmap_descs = @import("bitmap_descs.zig");
const state = @import("game_state.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;

const Vec2f = @Vector(2, f32);

const SPIN_FRAMES: f32 = @floatFromInt(bitmap_descs.GIB_SPIN_FRAMES);
const VARIANTS: u8 = bitmap_descs.SPLAT_VARIANTS;

/// What a killed enemy bursts into besides `chunks`: every part, and how high it flies (heads go highest)
const BODY_PARTS = [_]state.GibPart{ .head, .arm, .arm, .leg, .leg, .torso };

comptime {
    std.debug.assert(std.enums.values(state.GibPart).len == bitmap_descs.GIB_PARTS);
    std.debug.assert(bitmap_descs.GIB_CELLS.len == std.enums.values(state.EnemyKind).len);
}

/// The gore for the hits that landed this frame (see combat_system.applyHits). A wound sprays a few droplets out of the
/// far side; a kill bursts the enemy into its body parts and lumps of meat, thrown along the blow in a spray of
/// blood, over a pool where it stood. Rolls come from the gore's own `rand`, so gameplay rolls are never disturbed
///
pub fn spawn(gore: *state.Gore, impacts: []const state.Impact, rand: std.Random) void {
    for (impacts) |imp| {
        const def = imp.kind.def();
        if (!imp.killed) {
            for (0..consts.WOUND_DROPLETS) |_| addDroplet(&gore.droplets, rand, imp.pos, def.burst_height, imp.dir);
            continue;
        }
        gore.pools.add(imp.pos, rand.uintLessThan(u8, VARIANTS)); //A large pool
        for (BODY_PARTS) |part| addGib(&gore.gibs, rand, imp, part);
        for (0..def.chunks) |_| addGib(&gore.gibs, rand, imp, .chunk);
        for (0..def.droplets) |_| addDroplet(&gore.droplets, rand, imp.pos, def.burst_height, imp.dir);
    }
}

fn addGib(gibs: *state.Gibs, rand: std.Random, imp: state.Impact, part: state.GibPart) void {
    const height_scale: f32 = switch (part) {
        .head => 1.6,
        .leg => 0.5,
        else => 1.0,
    };
    const extra_lift: f32 = if (part == .head) 0.6 else 0;
    const vel = throw(rand, imp.dir, consts.GIB_SPREAD, consts.GIB_SPEED_MIN, consts.GIB_SPEED_MAX);
    const lift = between(rand, consts.GIB_LIFT_MIN, consts.GIB_LIFT_MAX) + extra_lift;
    const spin = between(rand, -consts.GIB_SPIN_MAX, consts.GIB_SPIN_MAX);
    gibs.add(imp.pos, imp.kind.def().burst_height * height_scale, vel, lift, spin, imp.kind, part);
}

fn addDroplet(droplets: *state.Droplets, rand: std.Random, pos: Vec2f, height: f32, dir: Vec2f) void {
    const vel = throw(rand, dir, consts.DROPLET_SPREAD, consts.DROPLET_SPEED_MIN, consts.DROPLET_SPEED_MAX);
    droplets.add(pos, height, vel, between(rand, consts.DROPLET_LIFT_MIN, consts.DROPLET_LIFT_MAX));
}

/// A velocity along `dir` turned by up to `spread` radians either way, at a speed between `min` and `max`
fn throw(rand: std.Random, dir: Vec2f, spread: f32, min: f32, max: f32) Vec2f {
    const a = between(rand, -spread, spread);
    const c = @cos(a);
    const s = @sin(a);
    const turned = Vec2f{ dir[0] * c - dir[1] * s, dir[0] * s + dir[1] * c };
    return turned * @as(Vec2f, @splat(between(rand, min, max)));
}

fn between(rand: std.Random, min: f32, max: f32) f32 {
    return min + rand.float(f32) * (max - min);
}

/// Fly, fall, bounce and settle the gibs and droplets, and age everything
///
pub fn update(gore: *state.Gore, grid: *const CollisionGrid, dt: f32) void {
    updateGibs(&gore.gibs, &gore.pools, grid, dt);
    updateDroplets(&gore.droplets, &gore.spatters, grid, dt);
    for (gore.pools.age[0..gore.pools.len]) |*a| a.* += dt;
    for (gore.spatters.age[0..gore.spatters.len]) |*a| a.* += dt;
}

/// Gibs fly under gravity, spinning; walls knock them back. Each landing bounces them up with GIB_BOUNCE of their
/// fall speed and slows them, until the bounce is too small and they lie still. Heads and torsos leave a medium pool
/// where they first land
///
fn updateGibs(gibs: *state.Gibs, pools: anytype, grid: *const CollisionGrid, dt: f32) void {
    for (0..gibs.len) |i| {
        if (gibs.age[i] >= consts.GIB_TIME) continue;
        gibs.age[i] += dt;
        if (gibs.resting[i]) continue;

        const to = gibs.pos[i] + gibs.vel[i] * @as(Vec2f, @splat(dt));
        if (grid.isSegmentClear(gibs.pos[i], to)) {
            gibs.pos[i] = to;
        } else {
            gibs.vel[i] *= @splat(-consts.GIB_WALL_BOUNCE);
        }
        gibs.lift[i] -= consts.GORE_GRAVITY * dt;
        gibs.height[i] += gibs.lift[i] * dt;
        //Keep the spin frame in 0..SPIN_FRAMES. It moves under 3 frames per frame, so no float @mod (fmodf) needed
        var rot = gibs.rot[i] + gibs.spin[i] * dt;
        while (rot >= SPIN_FRAMES) rot -= SPIN_FRAMES;
        while (rot < 0) rot += SPIN_FRAMES;
        gibs.rot[i] = rot;
        if (gibs.height[i] > 0) continue;

        //Hit the ground
        gibs.height[i] = 0;
        if (!gibs.landed[i]) {
            gibs.landed[i] = true;
            if (gibs.part[i] == .head or gibs.part[i] == .torso) pools.add(gibs.pos[i], VARIANTS + @as(u8, @intCast(i % VARIANTS))); //Medium
        }
        const bounce = -gibs.lift[i] * consts.GIB_BOUNCE;
        gibs.vel[i] *= @splat(consts.GIB_SKID);
        gibs.spin[i] *= consts.GIB_SKID;
        if (bounce < consts.GIB_REST_LIFT) {
            gibs.resting[i] = true;
            gibs.lift[i] = 0;
        } else {
            gibs.lift[i] = bounce;
        }
    }
}

/// Droplets fly under gravity and leave a spatter where they come down (or hit a wall)
///
fn updateDroplets(droplets: *state.Droplets, spatters: anytype, grid: *const CollisionGrid, dt: f32) void {
    for (0..droplets.len) |i| {
        if (!droplets.live[i]) continue;
        const to = droplets.pos[i] + droplets.vel[i] * @as(Vec2f, @splat(dt));
        const blocked = !grid.isSegmentClear(droplets.pos[i], to);
        if (!blocked) droplets.pos[i] = to;
        droplets.lift[i] -= consts.GORE_GRAVITY * dt;
        droplets.height[i] += droplets.lift[i] * dt;
        if (droplets.height[i] > 0 and !blocked) continue;
        droplets.live[i] = false;
        spatters.add(droplets.pos[i], @intCast(i % VARIANTS));
    }
}

/// 30x30 grid of 64px (0.5m) cells with nothing in it: the map's edge is +-7.5m from the origin
const open_cells: [30 * 30]bool = @splat(false);
const OPEN_GRID = CollisionGrid{ .cells = &open_cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 };

fn kill(kind: state.EnemyKind) state.Impact {
    return .{ .pos = @splat(0), .dir = Vec2f{ 1, 0 }, .kind = kind, .killed = true };
}

test "[gore_system] a kill bursts into every body part, chunks, blood and a pool; bigger enemies make more" {
    var prng = std.Random.DefaultPrng.init(1);
    var runner = state.Gore{};
    spawn(&runner, &.{kill(.runner)}, prng.random());
    var brute = state.Gore{};
    spawn(&brute, &.{kill(.brute)}, prng.random());

    try std.testing.expect(runner.gibs.len == BODY_PARTS.len + consts.ENEMY_KINDS[0].chunks);
    try std.testing.expect(runner.pools.len == 1 and runner.droplets.len == consts.ENEMY_KINDS[0].droplets);
    try std.testing.expect(brute.gibs.len > runner.gibs.len and brute.droplets.len > runner.droplets.len);
    for (std.enums.values(state.GibPart)) |part| {
        try std.testing.expect(std.mem.indexOfScalar(state.GibPart, runner.gibs.part[0..runner.gibs.len], part) != null);
    }
    //Thrown along the blow, upwards
    for (runner.gibs.vel[0..runner.gibs.len], runner.gibs.lift[0..runner.gibs.len]) |v, l| try std.testing.expect(v[0] > 0 and l > 0);
}

test "[gore_system] a wound only sprays a few droplets out of the far side" {
    var prng = std.Random.DefaultPrng.init(2);
    var gore = state.Gore{};
    spawn(&gore, &.{.{ .pos = @splat(0), .dir = Vec2f{ 0, -1 }, .kind = .walker, .killed = false }}, prng.random());
    try std.testing.expect(gore.gibs.len == 0 and gore.pools.len == 0 and gore.droplets.len == consts.WOUND_DROPLETS);
    for (gore.droplets.vel[0..gore.droplets.len]) |v| try std.testing.expect(v[1] < 0);
}

test "[gore_system] gibs bounce, come to rest and expire; droplets land as spatters" {
    var prng = std.Random.DefaultPrng.init(3);
    var gore = state.Gore{};
    spawn(&gore, &.{kill(.brute)}, prng.random());
    const dt: f32 = 1.0 / 50.0;
    var t: f32 = 0;
    while (t < 1.5) : (t += dt) {
        update(&gore, &OPEN_GRID, dt);
        for (gore.gibs.height[0..gore.gibs.len]) |h| try std.testing.expect(h >= 0);
    }
    for (gore.gibs.resting[0..gore.gibs.len], gore.gibs.landed[0..gore.gibs.len]) |r, l| try std.testing.expect(r and l);
    for (gore.gibs.rot[0..gore.gibs.len]) |r| try std.testing.expect(r >= 0 and r < SPIN_FRAMES);
    try std.testing.expect(gore.droplets.liveCount() == 0);
    try std.testing.expect(gore.spatters.len == consts.ENEMY_KINDS[3].droplets);
    try std.testing.expect(gore.pools.len > 1); //Heavy parts splash where they land

    while (t < 1.5 + consts.SPLAT_TIME) : (t += dt) update(&gore, &OPEN_GRID, dt); //Everything had landed by 1.5s
    try std.testing.expect(gore.gibs.liveCount() == 0 and gore.pools.liveCount() == 0 and gore.spatters.liveCount() == 0);
}

test "[gore_system] walls stop gibs and droplets, even on the longest frame" {
    //A one cell thick wall in column 16 (x = 0.5m)
    var cells: [30 * 30]bool = @splat(false);
    for (0..30) |row| cells[row * 30 + 16] = true;
    const grid = CollisionGrid{ .cells = &cells, .width = 30, .height = 30, .cell_width = 64, .cell_height = 64 };
    var gore = state.Gore{};
    gore.gibs.add(Vec2f{ 0.4, 0 }, 0.2, Vec2f{ consts.GIB_SPEED_MAX, 0 }, 2, 0, .walker, .head);
    gore.droplets.add(Vec2f{ 0.4, 0 }, 0.2, Vec2f{ consts.DROPLET_SPEED_MAX, 0 }, 2);
    var t: f32 = 0;
    while (t < 2) : (t += consts.MAX_FRAME_DT) {
        update(&gore, &grid, consts.MAX_FRAME_DT);
        try std.testing.expect(gore.gibs.pos[0][0] < 0.5);
    }
    try std.testing.expect(gore.spatters.len == 1 and gore.spatters.pos[0][0] < 0.5);
}
