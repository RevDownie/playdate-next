const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const maths = @import("maths.zig");
const SparseArray = @import("sparse_array.zig").SparseArray;
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);
const Vec2i = @Vector(2, i32);

const BULLET_POOL_SIZE = 100; //TODO: Calculate better approx based on fire rate and lifetime
const BULLET_MAX_SPEED_V = @splat(2, consts.BULLET_MAX_SPEED);

var num_active: usize = 0;
var bullet_world_pos_pool: [BULLET_POOL_SIZE]Vec2f = undefined;
var bullet_dir_pool: [BULLET_POOL_SIZE]Vec2f = undefined;
var bullet_lifetime_pool: [BULLET_POOL_SIZE]f32 = undefined;

pub const CollisionInfo = struct {
    entity_id: u8,
    impact_dir: Vec2f,
};

/// Spawn a new bullet that moves along the given trajectory
///
pub fn fire(world_pos: Vec2f, world_dir: Vec2f) void {
    //TODO: Handle circling round to avoid running out
    bullet_world_pos_pool[num_active] = world_pos;
    bullet_dir_pool[num_active] = world_dir;
    bullet_lifetime_pool[num_active] = consts.BULLET_LIFETIME;
    num_active += 1;
}

/// Move any spawned bullets along their trajectories
/// Recycle any that time out
/// Return any collisions
///
pub fn update(dt: f32, entity_world_positions: SparseArray(Vec2f, u8), collision_data: []CollisionInfo, num_collisions: *u8) !void {
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
        bullet_world_pos_pool[i] += bullet_dir_pool[i] * BULLET_MAX_SPEED_V * @splat(2, dt);
    }

    try checkForCollisions(entity_world_positions, collision_data, num_collisions);
}

/// Bullets are currently rendered via geometry and therefore have their own render path
///
pub fn render(graphics: pd.playdate_graphics, disp: pd.playdate_display, camera_pos: Vec2f) void {
    const active = bullet_world_pos_pool[0..num_active];
    var bullet_screen_pos = [_]Vec2i{Vec2i{ 0, 0 }} ** BULLET_POOL_SIZE;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, active, bullet_screen_pos[0..], disp.getWidth.?(), disp.getHeight.?());

    for (active) |_, i| {
        graphics.drawRect.?(bullet_screen_pos[i][0], bullet_screen_pos[i][1], 4, 4, pd.kColorBlack);
    }
}

/// Check for collision between the bullets and the given entities
/// Uses circle - point collision and returns the ids and hit directions of the hit entities
///
/// TODO: Non brute force collision and prevent duplicate collisions
///
fn checkForCollisions(entity_world_positions: SparseArray(Vec2f, u8), collision_data: []CollisionInfo, num_collisions: *u8) !void {
    var out_idx: u8 = 0;

    for (bullet_world_pos_pool[0..num_active]) |bullet_pos, bullet_idx| {
        for (entity_world_positions.toDataSlice()) |entity_pos, entity_idx| {
            const delta = entity_pos - bullet_pos;
            if (maths.magnitudeSqrd(delta) <= 0.25 * 0.25) {
                collision_data[out_idx] = CollisionInfo{ .entity_id = try entity_world_positions.lookupKeyByIndex(entity_idx), .impact_dir = bullet_dir_pool[bullet_idx] };
                out_idx += 1;

                //Destroy the bullet
                bullet_lifetime_pool[bullet_idx] = 0;
                break;
            }
        }
    }

    num_collisions.* = out_idx;
}
