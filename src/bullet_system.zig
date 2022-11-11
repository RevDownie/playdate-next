const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const Vec2f = @Vector(2, f32);
const Vec2i = @Vector(2, i32);

const BULLET_POOL_SIZE = 100; //TODO: Calculate better approx based on fire rate and lifetime
const BULLET_MAX_SPEED: f32 = 10;
const BULLET_MAX_SPEED_V = @splat(2, BULLET_MAX_SPEED);
const BULLET_LIFETIME = 5;

var num_active: usize = 0;
var bullet_world_pos_pool: [BULLET_POOL_SIZE]Vec2f = undefined;
var bullet_dir_pool: [BULLET_POOL_SIZE]Vec2f = undefined;
var bullet_lifetime_pool: [BULLET_POOL_SIZE]f32 = undefined;

/// Spawn a new bullet that moves along the given trajectory
///
pub fn fire(world_pos: Vec2f, world_dir: Vec2f) void {
    //TODO: Handle circling round to avoid running out
    bullet_world_pos_pool[num_active] = world_pos;
    bullet_dir_pool[num_active] = world_dir;
    bullet_lifetime_pool[num_active] = BULLET_LIFETIME;
    num_active += 1;
}

/// Move any spawned bullets along their trajectories
/// Recycle any that time out
///
pub fn update(dt: f32) void {
    var i: usize = 0;
    while (i < num_active) : (i += 1) {
        bullet_lifetime_pool[i] -= dt;
        if (bullet_lifetime_pool[i] <= 0) {
            //Swap and pop
            num_active -= 1;
            bullet_world_pos_pool[i] = bullet_world_pos_pool[num_active];
            bullet_dir_pool[i] = bullet_dir_pool[num_active];
            bullet_lifetime_pool[i] = bullet_lifetime_pool[num_active];
        }
    }

    i = 0;
    while (i < num_active) : (i += 1) {
        bullet_world_pos_pool[i] += bullet_dir_pool[i] * BULLET_MAX_SPEED_V;
    }
}

/// Bullets are currently rendered via geometry and therefore have their own render path
///
pub fn render(graphics: pd.playdate_graphics, disp: pd.playdate_display, camera_pos: Vec2f) void {
    const active = bullet_world_pos_pool[0..num_active];
    var bullet_screen_pos = [_]Vec2i{Vec2i{ 0, 0 }} ** BULLET_POOL_SIZE;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, active, bullet_screen_pos[0..], disp.getWidth.?(), disp.getHeight.?());

    for (active) |_, i| {
        graphics.drawRect.?(bullet_screen_pos[i][0], bullet_screen_pos[i][1], 15, 15, pd.kColorBlack);
    }
}
