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
    fire_pressed: bool = false, //A or B went down this frame
    crank_delta: f32 = 0, //Degrees turned since last frame, positive is forward
};

pub const Player = struct {
    pos: Vec2f = @splat(0),
    vel: Vec2f = @splat(0),
    facing_dir: Vec2f = .{ 1, 0 }, //Unit length: the way the gun is aimed, kept while there is nothing to aim at
    target_pos: ?Vec2f = null, //The enemy the gun is aimed at this frame, if any
    health: u8 = consts.PLAYER_MAX_HEALTH,
    score: u64 = 0,
    kill_streak: u32 = 0, //Kills since the player was last hurt: each kill scores SCORE_PER_KILL times this
    kills: u32 = 0, //This run
    best_streak: u32 = 0, //This run
    hit_flash_timer: f32 = 0, //Counts down while the hit flash effect is showing
    run_dist: f32 = 0, //Metres walked, drives the run cycle (wraps round, only its fraction matters)
};

/// What an enemy is, which sets its look, health, size and how it moves (consts.ENEMY_KINDS is in this order, and
/// the zombie_<kind> sprite sheets are loaded in it)
///
pub const EnemyKind = enum(u8) {
    runner,
    walker,
    shambler,
    brute,

    pub fn def(self: EnemyKind) consts.EnemyKindDef {
        return consts.ENEMY_KINDS[@backingInt(self)];
    }
};
comptime {
    if (consts.ENEMY_KINDS.len != std.enums.values(EnemyKind).len) @compileError("ENEMY_KINDS needs an entry per EnemyKind");
}

/// Enemies are dead once their health reaches zero; `removeDead` then compacts them out
///
pub const Enemies = struct {
    pub const capacity = consts.MAX_ENEMIES;

    len: u8 = 0,
    //Hot: read every frame by movement, collision, targeting and render
    pos: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    vel: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    health: [capacity]u8 align(memory.CACHE_LINE_SIZE) = undefined,
    speed: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined, //Metres a second it seeks the player at
    kind: [capacity]EnemyKind align(memory.CACHE_LINE_SIZE) = undefined,
    bump_timer: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined, //Seeking resumes when this reaches BUMP_TIME
    //Cold: only read while an enemy is bumping back
    bump_offset: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined, //Direction * distance of the full bump

    /// Add a walker moving at ENEMY_SPEED
    pub fn add(self: *Enemies, world_pos: Vec2f) void {
        self.addKind(world_pos, .walker, consts.ENEMY_SPEED);
    }

    /// Add a walker moving at `speed`
    pub fn addWithSpeed(self: *Enemies, world_pos: Vec2f, speed: f32) void {
        self.addKind(world_pos, .walker, speed);
    }

    pub fn addKind(self: *Enemies, world_pos: Vec2f, kind: EnemyKind, speed: f32) void {
        std.debug.assert(self.len < capacity);
        std.debug.assert(speed <= consts.ENEMY_MAX_SPEED);
        const i = self.len;
        self.pos[i] = world_pos;
        self.speed[i] = speed;
        self.kind[i] = kind;
        self.vel[i] = @splat(0);
        self.health[i] = kind.def().health;
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
            self.speed[i] = self.speed[last];
            self.kind[i] = self.kind[last];
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

/// Live bullets plus the ammo they are fired from. Bullets are dead once their lifetime reaches zero
///
pub const Bullets = struct {
    pub const capacity = consts.BULLET_POOL_SIZE;

    len: u8 = 0,
    pos: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    lifetime: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined,
    dir: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined, //Only read when moving or on a hit
    barrel: [capacity]u8 align(memory.CACHE_LINE_SIZE) = undefined, //Gatling barrel it left from, only read when drawn

    ammo: u8 = consts.START_AMMO,
    reload_timer: f32 = 0, //Reloading an ammo drop while > 0, and can't fire
    next_barrel: u8 = 0, //Barrel the next shot leaves from, turns with every shot

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
            self.barrel[i] = self.barrel[last];
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
pub const COLLISION_HOT_SET_BYTES = @sizeOf(@FieldType(Enemies, "pos")) + @sizeOf(@FieldType(Enemies, "kind")) + @sizeOf(@FieldType(Bullets, "pos")) + @sizeOf(@FieldType(Bullets, "lifetime"));
comptime {
    if (COLLISION_HOT_SET_BYTES > memory.HOT_SET_BUDGET) @compileError("Bullet/enemy collision data no longer fits the L1 hot set budget");
}

/// A bullet hitting an enemy this frame (per frame data). `enemy_idx` is only valid until enemies are next compacted
///
pub const Hit = struct {
    enemy_idx: u8,
    impact_dir: Vec2f,
};

/// The player's melee blow, used when out of ammo (see melee_system)
///
pub const Melee = struct {
    cooldown: f32 = 0, //Seconds until the next blow can land
    swing_timer: f32 = 0, //Counts down while the swing shows
    swing_dir: Vec2f = .{ 1, 0 }, //Towards the nearest enemy struck
};

/// Crank / button state that decides when the gun fires
///
pub const Trigger = struct {
    crank_angle_since_fire: f32 = 0,
    button_cooldown: f32 = 0, //Seconds until holding A/B fires again
};

pub const PopupKind = enum(u8) {
    combo, //A kill that grew the combo
    milestone, //A kill that reached a combo milestone
    lost, //A combo of COMBO_LOST_MIN or more was broken

    pub fn duration(self: PopupKind) f32 {
        return if (self == .combo) consts.POPUP_TIME else consts.POPUP_BIG_TIME;
    }
};

/// Short-lived messages in the world (the combo as it grows, where the kill happened). Fixed capacity: when full a
/// new one replaces the oldest, as only the latest matter
///
pub const Popups = struct {
    pub const capacity = consts.MAX_POPUPS;

    len: u8 = 0,
    pos: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    life: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined, //Seconds left showing
    value: [capacity]u32 align(memory.CACHE_LINE_SIZE) = undefined, //The combo it is about
    kind: [capacity]PopupKind align(memory.CACHE_LINE_SIZE) = undefined,

    pub fn add(self: *Popups, world_pos: Vec2f, kind: PopupKind, value: u32) void {
        var i = self.len;
        if (i < capacity) {
            self.len += 1;
        } else {
            i = @intCast(std.mem.indexOfMin(f32, &self.life)); //The oldest has the least life left
        }
        self.pos[i] = world_pos;
        self.life[i] = kind.duration();
        self.value[i] = value;
        self.kind[i] = kind;
    }

    /// Count down, then swap-remove the ones that have finished showing
    ///
    pub fn update(self: *Popups, dt: f32) void {
        for (self.life[0..self.len]) |*l| l.* -= dt;
        var i: u8 = 0;
        while (i < self.len) {
            if (self.life[i] > 0) {
                i += 1;
                continue;
            }
            const last = self.len - 1;
            self.pos[i] = self.pos[last];
            self.life[i] = self.life[last];
            self.value[i] = self.value[last];
            self.kind[i] = self.kind[last];
            self.len = last;
        }
    }
};

/// Killed enemies falling down and lying there for a moment (drawn only, nothing collides with them). Fixed
/// capacity: when full the newest replace the oldest
///
pub const Corpses = struct {
    pub const capacity = consts.MAX_CORPSES;

    len: u8 = 0,
    pos: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    dir: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined, //The way it was facing when it fell
    age: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined, //Seconds since it died
    kind: [capacity]EnemyKind align(memory.CACHE_LINE_SIZE) = undefined,

    /// Add a corpse for every enemy flagged dead (health 0). Call before `Enemies.removeDead`
    pub fn addDead(self: *Corpses, enemies: *const Enemies) void {
        for (0..enemies.len) |e| {
            if (enemies.health[e] > 0) continue;
            var i = self.len;
            if (i < capacity) {
                self.len += 1;
            } else {
                i = @intCast(std.mem.indexOfMax(f32, &self.age));
            }
            self.pos[i] = enemies.pos[e];
            self.dir[i] = enemies.vel[e];
            self.age[i] = 0;
            self.kind[i] = enemies.kind[e];
        }
    }

    /// Age them, then swap-remove the ones that have lain there long enough
    pub fn update(self: *Corpses, dt: f32) void {
        for (self.age[0..self.len]) |*a| a.* += dt;
        var i: u8 = 0;
        while (i < self.len) {
            if (self.age[i] < consts.CORPSE_TIME) {
                i += 1;
                continue;
            }
            const last = self.len - 1;
            self.pos[i] = self.pos[last];
            self.dir[i] = self.dir[last];
            self.age[i] = self.age[last];
            self.kind[i] = self.kind[last];
            self.len = last;
        }
    }
};

pub const WavePhase = enum(u8) { lull, wave };

/// Where the run is in its waves (see the WAVE_* constants and enemy_spawn_system). A lull counts down to the next
/// wave; a wave holds out (spawning) for `hold` seconds, then must be cleared to be survived
///
pub const Spawner = struct {
    wave: u16 = 0, //The current wave, or during a lull the one just fought (0 before the first)
    phase: WavePhase = .lull,
    phase_time: f32 = 0, //Seconds since this lull or wave began (drives the HUD)
    timer: f32 = consts.FIRST_WAVE_DELAY, //Lull: until the next wave. Wave: until the next pack. Infinite stops spawning
    hold: f32 = 0, //This wave's tuning (see consts.WaveDef)
    peak: u8 = 0,
    pack: u8 = 0,
    sides: u8 = 0, //Bit per level_loader.MapSide the wave comes from
    survived: bool = false, //This lull follows a wave the player survived (rather than one that ran out of time)

    /// Still spawning: the wave is being held out
    pub fn isHolding(self: *const Spawner) bool {
        return self.phase == .wave and self.phase_time < self.hold;
    }
};

/// What a drop gives, in the order of the drops bitmap table (see drop_sprites.py)
///
pub const DropKind = enum(u8) {
    ammo_small,
    ammo_large,
    health_small,
    health_large,

    pub fn isAmmo(self: DropKind) bool {
        return self == .ammo_small or self == .ammo_large;
    }

    pub fn isLarge(self: DropKind) bool {
        return self == .ammo_large or self == .health_large;
    }
};

/// Ammo and health lying on the level's drop points, waiting to be picked up. Dead once their lifetime runs
/// out or they are collected (lifetime set to 0)
///
pub const Drops = struct {
    pub const capacity = consts.MAX_DROPS;

    len: u8 = 0,
    pos: [capacity]Vec2f align(memory.CACHE_LINE_SIZE) = undefined,
    lifetime: [capacity]f32 align(memory.CACHE_LINE_SIZE) = undefined,
    kind: [capacity]DropKind align(memory.CACHE_LINE_SIZE) = undefined,
    point: [capacity]u8 align(memory.CACHE_LINE_SIZE) = undefined, //Index of the level drop point it is on, so two never share one

    spawn_timer: f32 = consts.FIRST_DROP_TIME, //Counts down to the next drop while there is room for one

    pub fn add(self: *Drops, world_pos: Vec2f, kind: DropKind, point: u8) void {
        std.debug.assert(self.len < capacity);
        const i = self.len;
        self.pos[i] = world_pos;
        self.lifetime[i] = consts.DROP_LIFETIME;
        self.kind[i] = kind;
        self.point[i] = point;
        self.len += 1;
    }

    pub fn isFull(self: *const Drops) bool {
        return self.len >= capacity;
    }

    /// Swap-remove every drop that has expired or been collected
    ///
    pub fn removeDead(self: *Drops) void {
        var i: u8 = 0;
        while (i < self.len) {
            if (self.lifetime[i] > 0) {
                i += 1;
                continue;
            }
            const last = self.len - 1;
            self.pos[i] = self.pos[last];
            self.lifetime[i] = self.lifetime[last];
            self.kind[i] = self.kind[last];
            self.point[i] = self.point[last];
            self.len = last;
        }
    }

    pub fn positions(self: *const Drops) []const Vec2f {
        return self.pos[0..self.len];
    }
};

pub const GameState = struct {
    player: Player = .{},
    enemies: Enemies = .{},
    bullets: Bullets = .{},
    drops: Drops = .{},
    popups: Popups = .{},
    corpses: Corpses = .{},
    trigger: Trigger = .{},
    melee: Melee = .{},
    spawner: Spawner = .{},
    camera_pos: Vec2f = @splat(0),
    run_time: f32 = 0, //Seconds survived this run
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(consts.RNG_SEED), //Not reset between runs
    invincible: bool = false, //Debug: enemies can't hurt the player (set from the debug menu). Not reset between runs

    /// Back to the start of a run, keeping the random sequence going and the debug settings
    ///
    pub fn reset(self: *GameState) void {
        const rng = self.rng;
        const invincible = self.invincible;
        self.* = .{ .rng = rng, .invincible = invincible };
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

test "[game_state] drops removeDead keeps the live ones with their data" {
    var d = Drops{};
    d.add(Vec2f{ 0, 0 }, .ammo_small, 0);
    d.add(Vec2f{ 1, 0 }, .health_large, 1);
    d.add(Vec2f{ 2, 0 }, .ammo_large, 2);
    d.lifetime[0] = 0;
    d.removeDead();
    try std.testing.expect(d.len == 2);
    try std.testing.expect(d.pos[0][0] == 2 and d.kind[0] == .ammo_large and d.point[0] == 2);
    try std.testing.expect(d.pos[1][0] == 1 and d.kind[1] == .health_large and d.point[1] == 1);
}

test "[game_state] popups replace the oldest when full and go once shown" {
    var p = Popups{};
    for (0..Popups.capacity) |i| {
        p.add(Vec2f{ @floatFromInt(i), 0 }, .combo, @intCast(i));
        p.update(0.01); //Each one older than the next
    }
    p.add(Vec2f{ 99, 0 }, .milestone, 99);
    try std.testing.expect(p.len == Popups.capacity);
    try std.testing.expect(std.mem.indexOfScalar(u32, p.value[0..p.len], 0) == null); //The oldest went
    try std.testing.expect(std.mem.indexOfScalar(u32, p.value[0..p.len], 99) != null);

    p.update(consts.POPUP_TIME);
    try std.testing.expect(p.len == 1 and p.kind[0] == .milestone); //Milestones show for longer
    p.update(consts.POPUP_BIG_TIME);
    try std.testing.expect(p.len == 0);
}

test "[game_state] enemies keep their kind through removeDead, and start with its health" {
    var e = Enemies{};
    e.addKind(Vec2f{ 0, 0 }, .runner, consts.ENEMY_RUNNER_SPEED);
    e.addKind(Vec2f{ 1, 0 }, .brute, consts.ENEMY_BRUTE_SPEED);
    try std.testing.expect(e.health[0] == EnemyKind.runner.def().health and e.health[1] == EnemyKind.brute.def().health);
    e.health[0] = 0;
    e.removeDead();
    try std.testing.expect(e.len == 1 and e.kind[0] == .brute and e.pos[0][0] == 1);
}

test "[game_state] corpses are added for the dead, replace the oldest when full and go once lain long enough" {
    var e = Enemies{};
    var c = Corpses{};
    e.addKind(Vec2f{ 0, 0 }, .shambler, consts.ENEMY_SLOW_SPEED);
    e.add(Vec2f{ 1, 0 });
    e.health[0] = 0;
    c.addDead(&e);
    try std.testing.expect(c.len == 1 and c.kind[0] == .shambler and c.pos[0][0] == 0);

    e.removeDead();
    e.health[0] = 0; //The walker, dying over and over
    for (0..Corpses.capacity) |_| {
        c.update(0.01);
        c.addDead(&e);
    }
    try std.testing.expect(c.len == Corpses.capacity);
    try std.testing.expect(std.mem.indexOfScalar(EnemyKind, c.kind[0..c.len], .shambler) == null); //The oldest went

    c.update(consts.CORPSE_TIME);
    try std.testing.expect(c.len == 0);
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
