const bitmap_descs = @import("bitmap_descs.zig");
const kit_descs = @import("kit_descs.zig");

/// Main constants that impact on gameplay and feel
pub const MAX_ENEMIES: u8 = 100;

pub const PLAYER_ACC: f32 = 2.0;
pub const PLAYER_MAX_SPEED: f32 = 1.5;
/// Holding one direction into a wall slides the player round its end when they are within this fraction of a cell
/// of the opening, so a d-pad doesn't have to find the diagonal (under half a cell, so only one side can qualify)
pub const PLAYER_CORNER_NUDGE: f32 = 0.4;
comptime {
    //The player's steps are only tested at their destination and stop flush against the cell they would enter
    if (PLAYER_MAX_SPEED * MAX_FRAME_DT >= CELL_MIN_SIDE_M) @compileError("The player is fast enough to step over a cell in one frame");
    if (PLAYER_CORNER_NUDGE >= 0.5) @compileError("PLAYER_CORNER_NUDGE must be under half a cell");
}
/// Enemies come in four kinds (game_state.EnemyKind), each with its own look (character_sprites.py). Most are walkers
/// at about ENEMY_SPEED (a little faster or slower each), some shamblers, from wave 2 a growing share are runners,
/// faster than the player, so a crowd strings out as it closes in and the player can't simply outrun every wave,
/// and from wave 3 a few brutes: big, slow and hard to kill, they shrug off the knock back and walk through fire
pub const ENEMY_SPEED: f32 = 1.2;
pub const ENEMY_SPEED_JITTER: f32 = 0.1; //Walkers vary by up to this fraction either way
pub const ENEMY_SLOW_SPEED: f32 = 0.85;
pub const ENEMY_SLOW_CHANCE: f32 = 0.25;
pub const ENEMY_RUNNER_SPEED: f32 = 1.75; //Faster than PLAYER_MAX_SPEED
pub const ENEMY_RUNNER_CHANCE_PER_WAVE: f32 = 0.04; //From wave 2: 4% of a wave's enemies, then 8%, ...
pub const ENEMY_RUNNER_CHANCE_MAX: f32 = 0.3;
pub const ENEMY_BRUTE_SPEED: f32 = 0.6;
pub const ENEMY_BRUTE_CHANCE_PER_WAVE: f32 = 0.03; //From wave 3: 3% of a wave's enemies, then 6%, ...
pub const ENEMY_BRUTE_CHANCE_MAX: f32 = 0.12;
pub const ENEMY_MAX_SPEED: f32 = ENEMY_RUNNER_SPEED; //The fastest any enemy moves

/// Per kind, in game_state.EnemyKind order. `hit_radius` is the bullet hit circle (drawn size: runners are small,
/// brutes big), `bump` how far a non-lethal hit knocks it back (0: it doesn't flinch, so fire can't hold it off)
/// Killed, it bursts into its head, arms, legs and torso plus `chunks` more lumps of meat, `droplets` of blood and a
/// pool, from `burst_height` metres above its feet. Health is in bullets of DMG_PER_HIT: the slow kinds take several
/// times a walker's, so they feel like a wall of meat rather than one more bullet
pub const EnemyKindDef = struct { health: u8, hit_radius: f32, bump: f32, chunks: u8, droplets: u8, burst_height: f32 };
comptime {
    for (ENEMY_KINDS) |k| {
        if (k.health % DMG_PER_HIT != 0) @compileError("Enemy health must be whole hits of DMG_PER_HIT, or the last hit's damage is wasted");
    }
}
pub const ENEMY_KINDS = [_]EnemyKindDef{
    .{ .health = 25, .hit_radius = CHAR_BULLET_COLL_RADIUS * 0.8, .bump = BUMP_DISTANCE, .chunks = 1, .droplets = 14, .burst_height = 0.1 }, //Runner: one hit
    .{ .health = 50, .hit_radius = CHAR_BULLET_COLL_RADIUS, .bump = BUMP_DISTANCE, .chunks = 2, .droplets = 20, .burst_height = 0.15 }, //Walker: two
    .{ .health = 100, .hit_radius = CHAR_BULLET_COLL_RADIUS, .bump = BUMP_DISTANCE_SMALL, .chunks = 3, .droplets = 22, .burst_height = 0.15 }, //Shambler: four
    .{ .health = 250, .hit_radius = CHAR_BULLET_COLL_RADIUS * 1.5, .bump = 0, .chunks = 6, .droplets = 36, .burst_height = 0.22 }, //Brute: ten
};

/// Gore. A killed enemy bursts: its gibs (body parts) are thrown along the killing blow, spinning, bounce and skid, then
/// lie on the ground. Blood droplets spray out with them and leave a spatter where they land; the body leaves a pool
/// where it burst, and heavy parts (head, torso) a smaller one where they first land. Non-lethal hits spray
/// WOUND_DROPLETS out of the far side. Gibs, pools and spatters stay until their store needs the room: each is a ring
/// of MAX_* where the newest MAX_* - *_FADE_SLOTS are solid, and each one added starts the oldest solid one fading
/// out through the dither (over *_FADE_TIME), so it has gone before its slot is written again
pub const MAX_GIBS: u8 = 96;
pub const GIB_FADE_SLOTS: u8 = 24; //About two brutes' worth, so a burst doesn't overwrite gibs still fading
pub const MAX_DROPLETS: u8 = 128;
pub const MAX_POOLS: u8 = 40;
pub const POOL_FADE_SLOTS: u8 = 8;
pub const MAX_SPATTERS: u8 = 160;
pub const SPATTER_FADE_SLOTS: u8 = 40; //A brute sprays 36
pub const GIB_FADE_TIME: f32 = 0.8;
pub const SPLAT_FADE_TIME: f32 = 1.5;
pub const GORE_GRAVITY: f32 = 10; //Metres per second squared (screen metres: 128px)
pub const GIB_SPEED_MIN: f32 = 1.0; //Thrown along the blow, up to GIB_SPREAD radians either side
pub const GIB_SPEED_MAX: f32 = 3.0;
pub const GIB_SPREAD: f32 = 1.3;
pub const GIB_LIFT_MIN: f32 = 1.0; //Thrown upwards at
pub const GIB_LIFT_MAX: f32 = 2.4;
pub const GIB_SPIN_MAX: f32 = 28; //Spin frames per second while airborne, either way
pub const GIB_BOUNCE: f32 = 0.4; //Share of its fall speed a gib bounces back up with
pub const GIB_SKID: f32 = 0.55; //Share of its speed along the ground kept on each bounce
pub const GIB_REST_LIFT: f32 = 0.45; //Bounces slower than this and it stops dead
pub const GIB_WALL_BOUNCE: f32 = 0.3; //Share of its speed kept bouncing off a wall
pub const DROPLET_SPEED_MIN: f32 = 0.6;
pub const DROPLET_SPEED_MAX: f32 = 2.6;
pub const DROPLET_SPREAD: f32 = 0.9;
pub const DROPLET_LIFT_MIN: f32 = 0.2;
pub const DROPLET_LIFT_MAX: f32 = 1.4;
pub const WOUND_DROPLETS: u8 = 4;
comptime {
    //Enemy steps are only tested at their destination, so one frame's move must stay under the smallest cell side
    //even on the longest frame
    if (ENEMY_MAX_SPEED * MAX_FRAME_DT >= CELL_MIN_SIDE_M) @compileError("Enemies are fast enough to step over a cell in one frame");
    if (ENEMY_SEPARATION_MAX_PUSH >= CELL_MIN_SIDE_M) @compileError("Separation can push an enemy over a cell in one frame");
}
pub const ENEMY_SEPARATION_DIST: f32 = CHAR_WIDTH_M * 0.75; //Enemies are pushed apart when their centres are closer than this
pub const ENEMY_SEPARATION_MAX_PUSH: f32 = 0.1; //Most an enemy is moved by separation in one frame (must stay under a cell)
pub const PLAYER_RING_RADIUS: f32 = CHAR_ENEMY_COLL_RADIUS * 0.8; //Enemies are kept this far from the player (inside contact range)
pub const ENEMY_TURN_RATE: f32 = 6.0; //How quickly enemies steer onto a new heading (fraction of the change per second)

/// Flow field cells settled per frame while it is being rebuilt. Bounds the pathfinding cost of any one frame;
/// a 16x20 level (320 cells) takes 2 frames to rebuild
pub const FLOW_FIELD_CELLS_PER_FRAME: u32 = 300;

pub const PLAYER_MAX_HEALTH: u8 = 100;
pub const CONTACT_DMG: u8 = 5; //Damage an enemy does to the player when it walks into them
pub const SCORE_PER_KILL: u64 = 10; //Multiplied by the kill streak (the combo), which resets when the player is hurt

/// Combo messages. Each kill shows the combo where the enemy fell; milestones get a big message, and losing a
/// good combo says so at the player
pub const COMBO_SHOW_FROM: u32 = 2; //Combos below this aren't shown
pub const COMBO_MILESTONE_FIRST: u32 = 5;
pub const COMBO_MILESTONE_EVERY: u32 = 10; //...then every multiple of this
pub const COMBO_LOST_MIN: u32 = 5; //Losing a combo at least this long shows "COMBO LOST"
pub const MAX_POPUPS: u8 = 8; //Messages in the world at once; a new one replaces the oldest
pub const PLAYER_LOW_HEALTH: u8 = 25; //At or below: the HUD's health turns loud, and story can have a line

/// Story dialogue (see story.zig and story_system). One line shows at a time, for long enough to read it
pub const MAX_STORY_EVENTS: u8 = 8; //Story moments in one frame: a wave ending, the next starting, low health...
pub const MAX_DIALOGUE_LINES: u8 = 4; //Lines waiting their turn; a new one past this drops the oldest
pub const LINE_BASE_TIME: f32 = 1.5; //Seconds every line shows...
pub const LINE_TIME_PER_CHAR: f32 = 0.055; //...plus this per character, so a long line is up long enough to read
pub const RADIO_TUNE_TIME: f32 = 0.35; //Ellie: seconds of static as the walkie-talkie picks her up, before her words
pub const RADIO_DROP_TIME: f32 = 0.2; //...and as she drops out after them
pub const RADIO_STATIC_FPS: f32 = 15; //How often the static on the walkie-talkie's box changes
pub const POPUP_TIME: f32 = 0.7; //Seconds a combo message shows
pub const POPUP_BIG_TIME: f32 = 1.4; //...and a milestone or COMBO LOST

/// Waves. The horde comes in waves with a lull between them. A wave is `count` enemies, and is over once every one
/// of them is dead. They come in packs, keeping the number alive near a target that climbs from
/// WAVE_START_FRACTION of the wave's `peak` to all of it over WAVE_RAMP_TIME, so the pressure is sustained and
/// builds to a climax (killing faster only brings the next pack sooner). The lull after it is the time to go out
/// for drops (they come faster and bigger then, DROP_LULL_*). Difficulty rises and falls but trends up: the table
/// runs in fours of a build up, a step back, a peak and a breather, each four bigger than the last
pub const WaveDef = struct {
    count: u16, //Enemies in the wave
    peak: u8, //Enemies kept alive by the time the last of them have spawned
    pack: u8, //Enemies per pack (they drop in together on one cell, so they arrive as a crowd)
    lull: f32, //Seconds of quiet after it is cleared
};
pub const WAVES = [_]WaveDef{
    .{ .count = 35, .peak = 14, .pack = 4, .lull = 7 }, //1: from one side, a taste
    .{ .count = 50, .peak = 20, .pack = 4, .lull = 7 },
    .{ .count = 40, .peak = 16, .pack = 4, .lull = 6 }, //Step back
    .{ .count = 75, .peak = 30, .pack = 5, .lull = 9 }, //Peak, then a longer lull to recover
    .{ .count = 60, .peak = 24, .pack = 5, .lull = 7 },
    .{ .count = 95, .peak = 38, .pack = 6, .lull = 7 },
    .{ .count = 75, .peak = 30, .pack = 5, .lull = 6 },
    .{ .count = 125, .peak = 50, .pack = 6, .lull = 9 }, //8: peak
};
/// Past the table the last four repeat, each repeat with more enemies, a higher peak, bigger packs and shorter lulls
pub const WAVE_REPEAT_EXTRA_PEAK: u8 = 10;
pub const WAVE_REPEAT_EXTRA_COUNT: u16 = 20;
pub const WAVE_REPEAT_SHORTER_LULL: f32 = 1.0;
pub const WAVE_MAX_COUNT: u16 = 250;
pub const WAVE_MAX_PACK: u8 = 8;
pub const WAVE_MIN_LULL: f32 = 4.0;
pub const WAVE_START_FRACTION: f32 = 0.4; //Of the peak, kept alive as a wave starts
pub const WAVE_RAMP_TIME: f32 = 25; //Seconds for the number kept alive to climb to the peak (sooner if the wave is killed faster)
pub const WAVE_PACK_INTERVAL: f32 = 0.5; //Seconds between packs at most: faster than a steady crank kills, so a crowd builds
pub const WAVE_PEAK_SCALE: f32 = 1.0; //Every wave's peak and count are multiplied by this (raise it for a stress test)
/// Waves come from one side of the map, then from one more side every this many waves until they come from all
/// four. One side is easy to read and to back away from; a horde on a single front walks into the gun in single
/// file, so the surround is what eventually overruns the player
pub const WAVES_PER_EXTRA_SIDE: u16 = 3;
pub const WAVE_MARK_LEFT: u8 = 5; //Once a wave is down to this many (all spawned), off screen ones are marked at the edge
pub const FIRST_WAVE_DELAY: f32 = 3.0;
pub const WAVE_BANNER_TIME: f32 = 2.0; //How long "WAVE N" shows when a wave starts
pub const WAVE_CLEARED_BANNER_TIME: f32 = 2.5; //...and "WAVE N CLEARED" when it is cleared
pub const CHAPTER_COMPLETE_DELAY: f32 = 2.5; //Story: seconds after the last wave is cleared before the chapter ends
pub const SPAWN_EDGE_BAND: f32 = 1.0; //Enemies drop in on free cells within this many metres of the map's edge
/// ...but never closer than this to the player, measured on the spawn ring (an ellipse with the screen's aspect:
/// 2.3m to the sides is 1.38m above and below), which keeps the screen's corners inside it
pub const SPAWN_MIN_PLAYER_DIST: f32 = 2.3;
/// Waves drop their packs in a ring just off screen in the wave's direction(s), this far from the player at most,
/// so they arrive within a few seconds as a crowd the player can see, rather than one at a time for the gun to
/// pick off as they walk into view. The map's edge band is the fallback
pub const SPAWN_RING_MAX_DIST: f32 = 3.0; //1.8m above and below, inside the levels' height
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

/// Camera (see camera_system). It trails the player a little, so a player running from the horde sits ahead of
/// centre and sees what is chasing them, and leans towards where the gun is aimed and, slightly, the way they move.
/// Vertical amounts are smaller: the screen is short and the HUD sits top and bottom. Set a lead to 0 to turn it off
pub const CAMERA_FOLLOW_RATE: f32 = 6.0; //Catch up per second: at full speed the camera trails ~0.28m (36px)
pub const CAMERA_LAG_MAX_X: f32 = 0.35; //Most it trails the player
pub const CAMERA_LAG_MAX_Y: f32 = 0.12;
pub const CAMERA_AIM_LEAD_X: f32 = 0.3; //Lean towards the aim at full speed (about 38px); none standing still
pub const CAMERA_AIM_LEAD_Y: f32 = 0.1;
pub const CAMERA_MOVE_LEAD_X: f32 = 0.1; //Lean the way the player moves at full speed (less than the lag, so a runner still sits ahead of centre)
pub const CAMERA_MOVE_LEAD_Y: f32 = 0.04;
pub const CAMERA_LEAD_FREQ: f32 = 4.0; //Spring stiffness of the leans going out (radians per second: most of the way in ~1s)
pub const CAMERA_RETURN_FREQ: f32 = 2.0; //...and coming back (~2s)
/// Each shot kicks the view back against the aim a pixel or two and it eases straight back, so a steady crank
/// gives a gentle recoil buzz. Visual only (added when drawing; targeting uses the unshaken camera)
pub const CAMERA_KICK: f32 = 1.5 / METRES_TO_PIXELS;
pub const CAMERA_KICK_JOLT: f32 = 1.0 / METRES_TO_PIXELS; //Random sideways, up to this either way
pub const CAMERA_SHAKE_MAX: f32 = 3.0 / METRES_TO_PIXELS;
pub const CAMERA_SHAKE_SETTLE_RATE: f32 = 25; //Per second: most of a kick has gone in a few frames

pub const FIRE_ANGLE_DELTA: f32 = 30; //12 bullets per crank revolution
/// Holding A or B fires nearly as fast as a steadily turned crank, so players who can't crank aren't left far behind.
/// The crank keeps the edge of turning faster in a burst
pub const FIRE_BUTTON_DELAY: f32 = 0.1;
const STEADY_CRANK_SHOTS_PER_SEC: f32 = 360.0 / FIRE_ANGLE_DELTA; //A revolution a second
comptime {
    if (1.0 / FIRE_BUTTON_DELAY > STEADY_CRANK_SHOTS_PER_SEC) @compileError("Button fire should not outpace a steadily turned crank");
    if (1.0 / FIRE_BUTTON_DELAY < STEADY_CRANK_SHOTS_PER_SEC * 0.75) @compileError("Button fire should be close to a steadily turned crank, for players who can't crank");
}
pub const RUN_START_FIRE_DELAY: f32 = 0.3; //Seconds holding A/B doesn't fire at the start of a run, so the press that started it doesn't

pub const BUMP_DISTANCE = 0.2;
pub const BUMP_DISTANCE_SMALL = 0.125;
pub const BUMP_TIME = 0.5;

pub const DMG_PER_HIT: u8 = 25; //A bullet's (or melee blow's) damage. A walker takes two: the first knocks it back (and it can't hurt the player while recoiling), the second kills
pub const BULLET_POOL_SIZE: u8 = 90; //The gun fires at most once a frame, so this covers BULLET_LIFETIME at up to 200 FPS
pub const BULLET_MAX_SPEED: f32 = 14; //Must not step over an enemy's hit circle in one frame (checked in bullet_system)
pub const BULLET_RANGE: f32 = 6.0; //Metres a bullet flies before it is spent (about two screen widths)
pub const BULLET_LIFETIME: f32 = BULLET_RANGE / BULLET_MAX_SPEED;
pub const BULLET_SPREAD: f32 = 0.035; //Most a shot strays sideways per metre travelled (about 2 degrees)
comptime {
    if (BULLET_LIFETIME * 200.0 > @as(f32, @floatFromInt(BULLET_POOL_SIZE))) @compileError("BULLET_POOL_SIZE can't hold every bullet in flight at 200 FPS");
}

/// Ammo. Nothing refills the gun on its own: only ammo drops do, so the player has to go out and find them. A
/// pickup can be fired straight away
pub const START_AMMO: u8 = 80; //About 7s of a steady crank
pub const MAX_AMMO: u8 = 200; //Most the player can carry: a large drop tops it up rather than doubling it. Drops are left lying while full

/// Drops appear one at a time on the level's drop points (an object layer in the Tiled map), each marked small or
/// large by the level designer. Large points go somewhere risky to reach, so big rewards mean going out into the horde
pub const MAX_DROPS: u8 = 5; //Live at once. The timer waits while this many are lying around
pub const FIRST_DROP_TIME: f32 = 3.0;
pub const DROP_INTERVAL: f32 = 3.0; //Seconds between drops while there is room for one
pub const DROP_LIFETIME: f32 = 20.0; //Uncollected drops vanish, so the map keeps changing and hoarding a spot doesn't pay
pub const DROP_BLINK_TIME: f32 = 4.0; //A drop blinks for its last few seconds
pub const DROP_LARGE_CHANCE: f32 = 0.25; //Chance a new drop goes on a large point rather than a small one
pub const DROP_LULL_INTERVAL: f32 = 1.5; //Between waves drops come faster...
pub const DROP_LULL_LARGE_CHANCE: f32 = 0.4; //...and are more often large, but still rarer than small ones
comptime {
    if (DROP_LARGE_CHANCE >= 0.5 or DROP_LULL_LARGE_CHANCE >= 0.5) @compileError("Large drops must be rarer than small ones");
}
pub const DROP_MIN_PLAYER_DIST: f32 = 2.0; //Drops never appear this close to the player: they have to go and get them
pub const DROP_SPAWN_ATTEMPTS: u8 = 4; //Random points tried per drop (must be free and far enough away), then retried next frame
pub const DROP_PICKUP_RADIUS: f32 = CHAR_WIDTH_M * 0.5;
pub const DROP_PICKUP_RADIUS_LARGE: f32 = CHAR_WIDTH_M * 0.6; //Large drops are drawn only a little bigger than the small ones
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
pub const HEALTH_DROP_SMALL: u8 = 12;
pub const HEALTH_DROP_LARGE: u8 = 35;

/// Gatling gun. Only affects where bullets are drawn: they are simulated from the player's feet so enemies
/// right up against the player can still be hit
pub const GUN_BARRELS: u8 = 6; //One shot per FIRE_ANGLE_DELTA of crank, so the barrels turn twice per crank revolution
pub const GUN_HEIGHT_PX: i32 = 12; //Height of the barrels above the player's feet (GUN_Z in character_sprites.py, on screen)
pub const MUZZLE_FORWARD: f32 = 0.14; //Metres ahead of the player the barrels end (held in the middle of the body, so mirrored facings need no side swap)
pub const BARREL_RADIUS: f32 = 0.013; //Metres from the gun's axis to each barrel
pub const MUZZLE_CONVERGE_DIST: f32 = 1.5; //The drawn muzzle offset fades out over this many metres so tracers meet the aim line
pub const TRACER_LENGTH: f32 = 0.3; //Metres of trail drawn behind each bullet (longer than a 50 FPS step so the stream looks unbroken)
pub const MUZZLE_FLASH_TIME: f32 = 0.06; //Seconds each shot's flash shows at the muzzle, shrinking (about 3 frames at TARGET_FPS)

pub const FLASH_HIT_EFFECT_DURATION: f32 = 0.3; //The player shows the hurt pose for as long

/// Character animation (frames in character_sprites.py). Walk and run cycles step with the distance covered
pub const HERO_RUN_CYCLE_DIST: f32 = 0.4; //Metres per run cycle (two steps)
pub const ENEMY_WALK_CYCLE_DIST: f32 = 0.35;
pub const HERO_DEATH_FRAME_TIME: f32 = 0.12; //Seconds per frame of the player falling down

/// Melee. Out of ammo, the player strikes the few nearest enemies in reach with the gun's stock (see melee_system)
pub const MELEE_RANGE: f32 = CHAR_ENEMY_COLL_RADIUS * 1.5; //Reaches the ring enemies crowd the player at, and a bit beyond
pub const MELEE_INTERVAL: f32 = 0.6; //Seconds between blows
pub const MELEE_MAX_TARGETS: u8 = 3; //Enemies hit per blow: holds off a few, not a crowd
pub const MELEE_SWING_TIME: f32 = 0.15; //How long the swing shows

/// Off screen drops are marked at the screen's edge, pointing the way to them
/// Insets are to the marker's centre: room for its disc and arrow (~22px) clear of the one row HUD (~15px)
pub const DROP_MARKER_INSET_TOP: i32 = 38;
pub const DROP_MARKER_INSET_BOTTOM: i32 = 36;
pub const DROP_MARKER_INSET_SIDE: i32 = 24;

pub const MAX_SCORE: u64 = 9999999999;
pub const GAME_OVER_INPUT_DELAY: f32 = 1.0; //Seconds the run end screen ignores fire before A/B starts the next run
pub const CARD_INPUT_DELAY: f32 = 0.6; //Seconds a story card ignores A, so a press held from before doesn't skip it
pub const GAME_OVER_PANEL_DELAY: f32 = 0.8; //Seconds the player is seen falling down before the run end panel covers them
comptime {
    if (GAME_OVER_PANEL_DELAY > GAME_OVER_INPUT_DELAY) @compileError("The run end panel must show before A/B can restart");
}

/// The shipping frame rate on device (the display refreshes at up to 50 Hz). Budgets and tunneling checks are made
/// against its frame time; longer frames are allowed to be slightly worse for the odd hitch
pub const TARGET_FPS: u32 = 50;
pub const TARGET_FRAME_DT: f32 = 1.0 / @as(f32, @floatFromInt(TARGET_FPS));

/// Longest step the simulation takes in one frame. Larger gaps (e.g. returning from the system menu) are clamped
/// so enemies and bullets don't teleport
pub const MAX_FRAME_DT: f32 = 0.1;

pub const METRES_TO_PIXELS: f32 = 128.0;
/// The smaller side of a level cell (kit_descs.CELL_W x CELL_H px), about 0.21m
pub const CELL_MIN_SIDE_M: f32 = @as(f32, @floatFromInt(@min(kit_descs.CELL_W, kit_descs.CELL_H))) / METRES_TO_PIXELS;
pub const CHAR_WIDTH_M: f32 = @as(f32, @floatFromInt(bitmap_descs.CHAR_W)) / METRES_TO_PIXELS;
pub const CHAR_BULLET_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5;
pub const CHAR_ENEMY_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5 * 1.25;

comptime {
    for (WAVES, 1..) |w, n| {
        if (w.count < w.peak) @compileError(@import("std").fmt.comptimePrint("WAVES[{d}]: fewer enemies than its peak", .{n}));
    }
}
