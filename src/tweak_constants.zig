const bitmap_descs = @import("bitmap_descs.zig");

/// Main constants that impact on gameplay and feel
pub const MAX_ENEMIES: u8 = 100;

pub const PLAYER_ACC: f32 = 2.0;
pub const PLAYER_MAX_SPEED: f32 = 1.5;
pub const ENEMY_MAX_SPEED: f32 = 1.2;
pub const ENEMY_SEPARATION_DIST: f32 = CHAR_WIDTH_M * 0.75; //Enemies are pushed apart when their centres are closer than this
pub const ENEMY_SEPARATION_MAX_PUSH: f32 = 0.1; //Most an enemy is moved by separation in one frame (must stay under a cell)
pub const PLAYER_RING_RADIUS: f32 = CHAR_ENEMY_COLL_RADIUS * 0.8; //Enemies are kept this far from the player (inside contact range)
pub const ENEMY_TURN_RATE: f32 = 6.0; //How quickly enemies steer onto a new heading (fraction of the change per second)

/// Flow field cells settled per frame while it is being rebuilt. Bounds the pathfinding cost of any one frame;
/// a 30x30 level takes about 3 frames to rebuild
pub const FLOW_FIELD_CELLS_PER_FRAME: u32 = 300;

pub const PLAYER_MAX_HEALTH: u8 = 100;
pub const ENEMY_MAX_HEALTH: u8 = 100;
pub const CONTACT_DMG: u8 = 5; //Damage an enemy does to the player when it walks into them
pub const SCORE_PER_KILL: u64 = 10; //Multiplied by the kill streak

pub const FIRST_SPAWN_TIME: f32 = 0.25;
pub const INIT_SPAWN_TIME: f32 = 8.0;
pub const SPAWN_TIME_REDUCTION: f32 = 1.0;
pub const MIN_SPAWN_TIME: f32 = 1.0; //Spawn interval never drops below this (it used to reach 0 and spawn every frame)
pub const ENEMIES_PER_SPAWN: u8 = 3;
pub const SPAWN_EDGE_BAND: f32 = 1.0; //Enemies drop in on free cells within this many metres of the map's edge
pub const SPAWN_MIN_PLAYER_DIST: f32 = 3.0; //...but never closer than this to the player
pub const SPAWN_ATTEMPTS: u8 = 4; //Random spawn cells tried per enemy before giving up (they must be reachable and far enough away)
pub const RNG_SEED: u64 = 42;

pub const FIRE_ANGLE_DELTA: f32 = 60;
pub const FIRE_BUTTON_DELAY: f32 = 0.5;

pub const BUMP_DISTANCE = 0.2;
pub const BUMP_DISTANCE_SMALL = 0.125;
pub const BUMP_TIME = 0.5;

pub const DMG_PER_HIT: u8 = 35;
pub const BULLET_MAG_SIZE: u8 = 60;
pub const BULLET_POOL_SIZE: u8 = BULLET_MAG_SIZE + 10; //A full mag lives at most BULLET_LIFETIME, which is no longer than RELOAD_TIME
pub const BULLET_MAX_SPEED: f32 = 10;
pub const BULLET_LIFETIME = 3;
pub const RELOAD_TIME = 3.0;

pub const FLASH_HIT_EFFECT_DURATION: f32 = 0.3;

pub const MAX_SCORE: u64 = 9999999999;

/// Longest step the simulation takes in one frame. Larger gaps (e.g. returning from the system menu) are clamped
/// so enemies and bullets don't teleport
pub const MAX_FRAME_DT: f32 = 0.1;

pub const METRES_TO_PIXELS: f32 = 128.0;
pub const CHAR_WIDTH_M: f32 = @as(f32, @floatFromInt(bitmap_descs.CHAR_W)) / METRES_TO_PIXELS;
pub const CHAR_BULLET_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5;
pub const CHAR_ENEMY_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5 * 1.25;
