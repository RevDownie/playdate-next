const bitmap_descs = @import("bitmap_descs.zig");

/// Main constants that impact on gameplay and feel
pub const MAX_ENEMIES: u8 = 100;

pub const PLAYER_ACC: f32 = 2.0;
pub const PLAYER_MAX_SPEED: f32 = 1.5;
pub const ENEMY_MAX_SPEED: f32 = 1.2;

pub const INIT_SPAWN_TIME: f32 = 8.0;
pub const SPAWN_TIME_REDUCTION: f32 = 1.0;
pub const ENEMIES_PER_SPAWN: u8 = 3;

pub const FIRE_ANGLE_DELTA: f32 = 60;
pub const FIRE_BUTTON_DELAY_MS: u32 = 500;

pub const BUMP_DISTANCE = 0.2;
pub const BUMP_DISTANCE_SMALL = 0.125;
pub const BUMP_TIME = 0.5;

pub const DMG_PER_HIT: u8 = 35;
pub const BULLET_MAG_SIZE = 60;
pub const BULLET_MAX_SPEED: f32 = 10;
pub const BULLET_LIFETIME = 3;
pub const RELOAD_TIME = 3.0;

pub const FLASH_HIT_EFFECT_DURATION: f32 = 0.3;

pub const MAX_SCORE: u64 = 9999999999;

pub const METRES_TO_PIXELS: f32 = 128.0;
pub const CHAR_WIDTH_M: f32 = @intToFloat(f32, bitmap_descs.CHAR_W) / METRES_TO_PIXELS;
pub const CHAR_BULLET_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5;
pub const CHAR_ENEMY_COLL_RADIUS: f32 = CHAR_WIDTH_M * 0.5 * 1.25;
