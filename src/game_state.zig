const std = @import("std");
const consts = @import("tweak_constants.zig");
const memory = @import("memory.zig");

const Vec2f = @Vector(2, f32);

// All of the game's mutable simulation state lives here, owned by main and passed to the systems.
// Entity stores are fixed capacity structure-of-arrays: the index is the handle, entities are packed
// densely into 0..len so systems iterate contiguous data, and removal is "flag then compact" once per frame.
// Each array starts on a cache line, and fields only read in rare cases (e.g. bump back) sit in their own
// arrays so the common loops never pull them into the 4 KB L1 cache (see memory.HOT_SET_BUDGET).

/// Platform independent snapshot of the player's input for one frame (built from the Playdate API by main)
///
pub const Input = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    fire_held: bool = false, //A or B
    crank_delta: f32 = 0, //Degrees turned since last frame, positive is forward
};

pub const Player = struct {
    pos: Vec2f = @splat(0),
    vel: Vec2f = @splat(0),
    facing_dir: Vec2f = @splat(0),
    health: u8 = consts.PLAYER_MAX_HEALTH,
    score: u64 = 0,
    kill_streak: u32 = 0,
    hit_flash_timer: f32 = 0, //Counts down while the hit flash effect is showing
};

/// Enemies are dead once their health reaches zero; `removeDead` then compacts them out
///
pub const Enemies = struct {
    pub const capacity = consts.MAX_ENEMIES;

    len: u8 = 0,
    //Hot: read every frame by movement, collision, targeting and render
    pos: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    vel: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    health: [capacity]u8 align(memory.CACHE_LINE_SIZE) = undefined,
    bump_timer: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined, //Seeking resumes when this reaches BUMP_TIME
    //Cold: only read while an enemy is bumping back
    bump_offset: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined, //Direction * distance of the full bump

    pub fn add(self: *Enemies, world_pos: Vec2f) void {
        std.debug.assert(self.len < capacity);
        const i = self.len;
        self.pos[i] = world_pos;
        self.vel[i] = @splat(0);
        self.health[i] = consts.ENEMY_MAX_HEALTH;
        self.bump_timer[i] = consts.BUMP_TIME;
        self.bump_offset[i] = @splat(0);
        self.len += 1;
    }

    pub fn isFull(self: *const Enemies) bool {
        return self.len >= capacity;
    }

    pub fn isBumping(self: *const Enemies, i: usize) bool {
        return self.bump_timer[i] < consts.BUMP_TIME;
    }

    /// Knock the enemy back along `dir` by `dist`, interrupting any seek or bump in progress
    ///
    pub fn startBumpBack(self: *Enemies, i: usize, dir: Vec2f, dist: f32) void {
        self.bump_timer[i] = 0;
        self.bump_offset[i] = dir * @as(Vec2f, @splat(dist));
    }

    /// Swap-remove every enemy whose health has reached zero. Invalidates indices held from before the call
    ///
    pub fn removeDead(self: *Enemies) void {
        var i: u8 = 0;
        while (i < self.len) {
            if (self.health[i] > 0) {
                i += 1;
                continue;
            }
            //Swap the last one in and re-check this slot
            const last = self.len - 1;
            self.pos[i] = self.pos[last];
            self.vel[i] = self.vel[last];
            self.health[i] = self.health[last];
            self.bump_timer[i] = self.bump_timer[last];
            self.bump_offset[i] = self.bump_offset[last];
            self.len = last;
        }
    }

    pub fn positions(self: *const Enemies) []const Vec2f {
        return self.pos[0..self.len];
    }

    pub fn velocities(self: *const Enemies) []const Vec2f {
        return self.vel[0..self.len];
    }
};

/// Live bullets plus the magazine they are fired from. Bullets are dead once their lifetime reaches zero
///
pub const Bullets = struct {
    pub const capacity = consts.BULLET_POOL_SIZE;

    len: u8 = 0,
    pos: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    lifetime: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined,
    dir: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined, //Only read when moving or on a hit

    magazine: u8 = consts.BULLET_MAG_SIZE,
    reload_timer: f32 = 0, //Reloading while > 0

    pub fn isReloading(self: *const Bullets) bool {
        return self.reload_timer > 0;
    }

    /// Swap-remove every bullet whose lifetime has run out
    ///
    pub fn removeDead(self: *Bullets) void {
        var i: u8 = 0;
        while (i < self.len) {
            if (self.lifetime[i] > 0) {
                i += 1;
                continue;
            }
            const last = self.len - 1;
            self.pos[i] = self.pos[last];
            self.dir[i] = self.dir[last];
            self.lifetime[i] = self.lifetime[last];
            self.len = last;
        }
    }

    pub fn positions(self: *const Bullets) []const Vec2f {
        return self.pos[0..self.len];
    }
};

/// The bullet x enemy collision test re-reads every enemy position for each live bullet, so all of
/// those arrays need to stay resident in the cache together
pub const COLLISION_HOT_SET_BYTES = @sizeOf(@FieldType(Enemies, "pos")) + @sizeOf(@FieldType(Bullets, "pos")) + @sizeOf(@FieldType(Bullets, "lifetime"));
comptime {
    if (COLLISION_HOT_SET_BYTES > memory.HOT_SET_BUDGET) @compileError("Bullet/enemy collision data no longer fits the L1 hot set budget");
}

/// A bullet hitting an enemy this frame (per frame data). `enemy_idx` is only valid until enemies are next compacted
///
pub const Hit = struct {
    enemy_idx: u8,
    impact_dir: Vec2f,
};

/// Crank / button state that decides when the gun fires
///
pub const Trigger = struct {
    crank_angle_since_fire: f32 = 0,
    button_cooldown: f32 = 0, //Seconds until holding A/B fires again
};

pub const Spawner = struct {
    spawn_interval: f32 = consts.INIT_SPAWN_TIME,
    next_spawn_timer: f32 = consts.FIRST_SPAWN_TIME,
};

pub const GameState = struct {
    player: Player = .{},
    enemies: Enemies = .{},
    bullets: Bullets = .{},
    trigger: Trigger = .{},
    spawner: Spawner = .{},
    camera_pos: Vec2f = @splat(0),
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(consts.RNG_SEED), //Not reset between runs

    /// Back to the start of a run, keeping the random sequence going
    ///
    pub fn reset(self: *GameState) void {
        const rng = self.rng;
        self.* = .{ .rng = rng };
    }
};

test "[game_state] enemies removeDead compacts and keeps the living" {
    var e = Enemies{};
    e.add(Vec2f{ 0, 0 });
    e.add(Vec2f{ 1, 0 });
    e.add(Vec2f{ 2, 0 });
    e.add(Vec2f{ 3, 0 });
    e.health[0] = 0;
    e.health[3] = 0;

    e.removeDead();
    try std.testing.expect(e.len == 2);
    //Slot 0 was refilled from the end (which was itself dead) so both survivors remain
    var found_1 = false;
    var found_2 = false;
    for (e.positions()) |p| {
        if (p[0] == 1) found_1 = true;
        if (p[0] == 2) found_2 = true;
    }
    try std.testing.expect(found_1 and found_2);
}

test "[game_state] enemies removeDead all" {
    var e = Enemies{};
    e.add(Vec2f{ 0, 0 });
    e.add(Vec2f{ 1, 0 });
    e.health[0] = 0;
    e.health[1] = 0;
    e.removeDead();
    try std.testing.expect(e.len == 0);
}

test "[game_state] bullets removeDead" {
    var b = Bullets{};
    for (0..5) |i| {
        b.pos[i] = Vec2f{ @floatFromInt(i), 0 };
        b.lifetime[i] = if (i % 2 == 0) 0 else 1;
    }
    b.len = 5;
    b.removeDead();
    try std.testing.expect(b.len == 2);
    for (b.lifetime[0..b.len]) |l| try std.testing.expect(l > 0);
}

test "[game_state] reset keeps rng sequence" {
    var s = GameState{};
    const first = s.rng.random().int(u32);
    s.player.health = 1;
    s.reset();
    try std.testing.expect(s.player.health == consts.PLAYER_MAX_HEALTH);
    var fresh = GameState{};
    try std.testing.expect(fresh.rng.random().int(u32) == first);
    try std.testing.expect(s.rng.random().int(u32) != first);
}
