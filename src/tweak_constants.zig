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
/// Spawning speeds up from one wave every INIT_SPAWN_TIME to one every MIN_SPAWN_TIME (7.5 enemies a second) after
/// about 55s, more than a steady crank of 1-1.5 turns a second can clear, so most runs end in being overrun
pub const INIT_SPAWN_TIME: f32 = 5.0;
pub const SPAWN_TIME_REDUCTION: f32 = 0.25; //Taken off the interval after every wave
pub const MIN_SPAWN_TIME: f32 = 0.4; //Spawn interval never drops below this (it used to reach 0 and spawn every frame)
pub const ENEMIES_PER_SPAWN: u8 = 3;
pub const SPAWN_EDGE_BAND: f32 = 1.0; //Enemies drop in on free cells within this many metres of the map's edge
pub const SPAWN_MIN_PLAYER_DIST: f32 = 3.0; //...but never closer than this to the player
pub const SPAWN_ATTEMPTS: u8 = 4; //Random spawn cells tried per enemy before giving up (they must be reachable and far enough away)
pub const RNG_SEED: u64 = 42;

/// Auto targetting. The gun only aims at enemies the player can see: inside the camera's view and with a
/// clear line from the player's feet. Candidates are ranked by distance, scaled down by the weights below
pub const VIEW_HALF_WIDTH: f32 = 200.0 / METRES_TO_PIXELS; //Half the 400x240 screen in metres, around the camera
pub const VIEW_HALF_HEIGHT: f32 = 120.0 / METRES_TO_PIXELS;
pub const TARGET_VIEW_MARGIN: f32 = 0.1; //Metres beyond the screen edge an enemy can be targeted (as it walks on)
pub const TARGET_AHEAD_WEIGHT: f32 = 0.6; //An enemy dead ahead of the player's movement counts as 60% closer
pub const TARGET_FINISH_WEIGHT: f32 = 0.5; //...a nearly dead one up to 50% closer, so the gun finishes it off
pub const TARGET_STICKY_WEIGHT: f32 = 0.15; //...and one along the current aim 15% closer, so the aim doesn't flick
pub const TARGET_MAX_LOS_TESTS: u8 = 8; //Line of sight tests per frame, on the best candidates first

pub const FIRE_ANGLE_DELTA: f32 = 30; //12 bullets per crank revolution
pub const FIRE_BUTTON_DELAY: f32 = 0.25; //Button fire is the fallback: well under the rate of a steadily turned crank

pub const BUMP_DISTANCE = 0.2;
pub const BUMP_DISTANCE_SMALL = 0.125;
pub const BUMP_TIME = 0.5;

pub const DMG_PER_HIT: u8 = 50; //Two hits per enemy: the first knocks it back (and it can't hurt the player while recoiling), the second kills
pub const BULLET_MAG_SIZE: u8 = 80;
pub const BULLET_POOL_SIZE: u8 = BULLET_MAG_SIZE + 10; //A full mag lives at most BULLET_LIFETIME, which is no longer than RELOAD_TIME
pub const BULLET_MAX_SPEED: f32 = 14; //Must not step over an enemy's hit circle in one frame (checked in bullet_system)
pub const BULLET_RANGE: f32 = 6.0; //Metres a bullet flies before it is spent (about two screen widths)
pub const BULLET_LIFETIME: f32 = BULLET_RANGE / BULLET_MAX_SPEED;
pub const BULLET_SPREAD: f32 = 0.035; //Most a shot strays sideways per metre travelled (about 2 degrees)
pub const RELOAD_TIME = 1.5;
comptime {
    if (BULLET_LIFETIME > RELOAD_TIME) @compileError("BULLET_POOL_SIZE assumes a mag's bullets are gone by the time it has reloaded");
}

/// Gatling gun. Only affects where bullets are drawn: they are simulated from the player's feet so enemies
/// right up against the player can still be hit
pub const GUN_BARRELS: u8 = 6; //One shot per FIRE_ANGLE_DELTA of crank, so the barrels turn twice per crank revolution
pub const GUN_HEIGHT_PX: i32 = 16; //Height of the barrels above the player's feet
pub const MUZZLE_FORWARD: f32 = 0.14; //Metres ahead of the player the barrels end
pub const MUZZLE_SIDE: f32 = 0.08; //Metres to the player's right the gun is held
pub const BARREL_RADIUS: f32 = 0.02; //Metres from the gun's axis to each barrel
pub const MUZZLE_CONVERGE_DIST: f32 = 1.5; //The drawn muzzle offset fades out over this many metres so tracers meet the aim line
pub const TRACER_LENGTH: f32 = 0.3; //Metres of trail drawn behind each bullet (longer than a 50 FPS step so the stream looks unbroken)

pub const FLASH_HIT_EFFECT_DURATION: f32 = 0.3;

pub const MAX_SCORE: u64 = 9999999999;

/// Longest step the simulation takes in one frame. Larger gaps (e.g. returning from the system menu) are clamped
/// so enemies and bullets don't teleport
pub const MAX_FRAME_DT: f32 = 0.1;

pub const METRES_TO_PIXELS: f32 = 128.0;
pub const CHAR_WIDTH_M: f32 = @as(f32, @floatFromInt(bitmap_descs.CHAR_W)) / METRES_TO_PIXELS;
pub const CHAR_BULLET_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5;
pub const CHAR_ENEMY_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5 * 1.25;
