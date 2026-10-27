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
pub const SCORE_PER_KILL: u64 = 10; //Multiplied by the kill streak (the combo), which resets when the player is hurt

/// Combo messages. Each kill shows the combo where the enemy fell; milestones get a big message, and losing a
/// good combo says so at the player
pub const COMBO_SHOW_FROM: u32 = 2; //Combos below this aren't shown
pub const COMBO_MILESTONE_FIRST: u32 = 5;
pub const COMBO_MILESTONE_EVERY: u32 = 10; //...then every multiple of this
pub const COMBO_LOST_MIN: u32 = 5; //Losing a combo at least this long shows "COMBO LOST"
pub const MAX_POPUPS: u8 = 8; //Messages in the world at once; a new one replaces the oldest
pub const POPUP_TIME: f32 = 0.7; //Seconds a combo message shows
pub const POPUP_BIG_TIME: f32 = 1.4; //...and a milestone or COMBO LOST

/// Waves. The horde comes in waves with a lull between them. A wave is a fight to hold out through: for `hold`
/// seconds packs keep spawning to keep the number of enemies alive near a target, which climbs from
/// WAVE_START_FRACTION of the wave's `peak` to all of it, so the pressure is sustained and builds to a climax
/// (killing faster only brings the next pack sooner). Then the rest must be cleared (down to WAVE_CLEAR_LEFT) to
/// survive it. The lull after it is the time to go out for drops (they come faster and bigger then, DROP_LULL_*).
/// Difficulty rises and falls but trends up: the table runs in fours of a build up, a step back, a peak and a
/// breather, each four bigger and longer than the last
pub const WaveDef = struct {
    hold: f32, //Seconds the wave keeps spawning
    peak: u8, //Enemies kept alive by the end of the hold
    pack: u8, //Enemies per pack (they drop in together on one cell, so they arrive as a crowd)
    lull: f32, //Seconds of quiet after it is survived
};
pub const WAVES = [_]WaveDef{
    .{ .hold = 20, .peak = 14, .pack = 4, .lull = 7 }, //1: from one side, a taste
    .{ .hold = 25, .peak = 20, .pack = 4, .lull = 7 },
    .{ .hold = 20, .peak = 16, .pack = 4, .lull = 6 }, //Step back
    .{ .hold = 30, .peak = 30, .pack = 5, .lull = 9 }, //Peak, then a longer lull to recover
    .{ .hold = 25, .peak = 24, .pack = 5, .lull = 7 },
    .{ .hold = 35, .peak = 38, .pack = 6, .lull = 7 },
    .{ .hold = 25, .peak = 30, .pack = 5, .lull = 6 },
    .{ .hold = 40, .peak = 50, .pack = 6, .lull = 9 }, //8: peak
};
/// Past the table the last four repeat, each repeat with a higher peak, a longer hold, bigger packs and shorter lulls
pub const WAVE_REPEAT_EXTRA_PEAK: u8 = 10;
pub const WAVE_REPEAT_LONGER: f32 = 5; //Seconds onto the hold
pub const WAVE_REPEAT_SHORTER_LULL: f32 = 1.0;
pub const WAVE_MAX_HOLD: f32 = 60;
pub const WAVE_MAX_PACK: u8 = 8;
pub const WAVE_MIN_LULL: f32 = 4.0;
pub const WAVE_START_FRACTION: f32 = 0.4; //Of the peak, kept alive as a wave starts
pub const WAVE_PACK_INTERVAL: f32 = 0.5; //Seconds between packs at most: faster than a steady crank kills, so a crowd builds
pub const WAVE_PEAK_SCALE: f32 = 1.0; //Every wave's peak is multiplied by this (raise it for a stress test)
/// Waves come from one side of the map, then from one more side every this many waves until they come from all
/// four. One side is easy to read and to back away from; a horde on a single front walks into the gun in single
/// file, so the surround is what eventually overruns the player
pub const WAVES_PER_EXTRA_SIDE: u16 = 3;
pub const WAVE_CLEAR_LEFT: u8 = 3; //After the hold, a wave is survived once no more than this many enemies are left
pub const WAVE_CLEAR_MAX_TIME: f32 = 20.0; //...or followed straight away by the next wave (no lull) if that takes longer
pub const FIRST_WAVE_DELAY: f32 = 3.0;
pub const WAVE_BANNER_TIME: f32 = 2.0; //How long "WAVE N" shows when a wave starts, and "CLEAR THE REST" after the hold
pub const WAVE_SURVIVED_BANNER_TIME: f32 = 2.5; //...and "WAVE N SURVIVED" when it is survived
pub const SPAWN_EDGE_BAND: f32 = 1.0; //Enemies drop in on free cells within this many metres of the map's edge
pub const SPAWN_MIN_PLAYER_DIST: f32 = 3.0; //...but never closer than this to the player
/// Waves drop their packs in a ring just off screen in the wave's direction(s), this far from the player at most,
/// so they arrive within a few seconds as a crowd the player can see (spawning only at the map's edge, the gun
/// picked each enemy off as it walked into view and the screen never filled). The map's edge band is the fallback
pub const SPAWN_RING_MAX_DIST: f32 = 4.5;
pub const SPAWN_ATTEMPTS: u8 = 6; //Random spawn cells tried per enemy before giving up (they must be reachable and far enough away)
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
pub const BULLET_POOL_SIZE: u8 = 90; //The gun fires at most once a frame, so this covers BULLET_LIFETIME at up to 200 FPS
pub const BULLET_MAX_SPEED: f32 = 14; //Must not step over an enemy's hit circle in one frame (checked in bullet_system)
pub const BULLET_RANGE: f32 = 6.0; //Metres a bullet flies before it is spent (about two screen widths)
pub const BULLET_LIFETIME: f32 = BULLET_RANGE / BULLET_MAX_SPEED;
pub const BULLET_SPREAD: f32 = 0.035; //Most a shot strays sideways per metre travelled (about 2 degrees)
comptime {
    if (BULLET_LIFETIME * 200.0 > @as(f32, @floatFromInt(BULLET_POOL_SIZE))) @compileError("BULLET_POOL_SIZE can't hold every bullet in flight at 200 FPS");
}

/// Ammo. Nothing reloads the gun on its own: it only refills from ammo drops, so the player has to go out and
/// find them. Picking one up reloads for a while (longer for a large drop) and the gun can't fire meanwhile
pub const START_AMMO: u8 = 80; //About 7s of a steady crank
pub const MAX_AMMO: u8 = 250; //Most the player can carry (ammo is a u8). An ammo drop is left lying while full

/// Drops appear one at a time on the level's drop points (an object layer in the Tiled map). Small points sit in
/// the middle of the map, outside the enemies' spawn band; large ones in the rooms at the top and bottom, where
/// the horde arrives, behind the gaps in the walls. Big rewards mean going where the enemies come from
pub const MAX_DROPS: u8 = 5; //Live at once. The timer waits while this many are lying around
pub const FIRST_DROP_TIME: f32 = 3.0;
pub const DROP_INTERVAL: f32 = 3.0; //Seconds between drops while there is room for one
pub const DROP_LIFETIME: f32 = 20.0; //Uncollected drops vanish, so the map keeps changing and hoarding a spot doesn't pay
pub const DROP_BLINK_TIME: f32 = 4.0; //A drop blinks for its last few seconds
pub const DROP_LARGE_CHANCE: f32 = 0.35; //Chance a new drop goes on a large point rather than a small one
pub const DROP_LULL_INTERVAL: f32 = 1.5; //Between waves drops come faster...
pub const DROP_LULL_LARGE_CHANCE: f32 = 0.6; //...and are more often large
pub const DROP_MIN_PLAYER_DIST: f32 = 2.0; //Drops never appear this close to the player: they have to go and get them
pub const DROP_SPAWN_ATTEMPTS: u8 = 4; //Random points tried per drop (must be free and far enough away), then retried next frame
pub const DROP_PICKUP_RADIUS: f32 = CHAR_WIDTH_M * 0.5;
pub const DROP_PICKUP_RADIUS_LARGE: f32 = CHAR_WIDTH_M * 0.75; //Large drops are drawn about as wide as the player
/// Drops bob gently and a glint sweeps across them now and then, so they catch the eye
pub const DROP_BOUNCE_PX: f32 = 5; //Height of each hop
pub const DROP_BOUNCE_PERIOD: f32 = 0.8; //Seconds per hop
pub const DROP_SHEEN_PERIOD_MS: u32 = 1600; //A glint this often...
pub const DROP_SHEEN_FRAME_MS: u32 = 50; //...stepping through its frames this fast
pub const DROP_SHEEN_POINT_OFFSET_MS: u32 = 370; //Per drop point, so drops don't all glint at once
/// The chance a drop is ammo leans towards whichever of ammo and health the player is shorter of, within these
pub const DROP_AMMO_CHANCE_MIN: f32 = 0.3;
pub const DROP_AMMO_CHANCE_MAX: f32 = 0.75;
pub const AMMO_DROP_SMALL: u8 = 40;
pub const AMMO_DROP_LARGE: u8 = 150;
pub const RELOAD_TIME_SMALL: f32 = 0.6; //Picking up ammo takes this long before the gun fires again
pub const RELOAD_TIME_LARGE: f32 = 2.0; //...a large crate leaves the player defenceless for a while, out where the enemies spawn
pub const HEALTH_DROP_SMALL: u8 = 15;
pub const HEALTH_DROP_LARGE: u8 = 45;

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
pub const GAME_OVER_INPUT_DELAY: f32 = 1.0; //Seconds the run end screen ignores fire before A/B starts the next run

/// Longest step the simulation takes in one frame. Larger gaps (e.g. returning from the system menu) are clamped
/// so enemies and bullets don't teleport
pub const MAX_FRAME_DT: f32 = 0.1;

pub const METRES_TO_PIXELS: f32 = 128.0;
pub const CHAR_WIDTH_M: f32 = @as(f32, @floatFromInt(bitmap_descs.CHAR_W)) / METRES_TO_PIXELS;
pub const CHAR_BULLET_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5;
pub const CHAR_ENEMY_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5 * 1.25;
