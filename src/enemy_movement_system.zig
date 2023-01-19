const std = @import("std");
const maths = @import("maths.zig");
const SparseArray = @import("sparse_array.zig").SparseArray;
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

const SeekData = struct { entity_id: u8 };
const BumpData = struct { entity_id: u8, start_world_pos: Vec2f, bump_dir: Vec2f, bump_dist: f32, timer: f32 };

var entity_seek_data: SparseArray(SeekData, u8) = undefined;
var entity_bump_data: SparseArray(BumpData, u8) = undefined;

/// Allocate the pools
///
pub fn init(max_num_entities: u8, allocator: std.mem.Allocator) !void {
    entity_seek_data = try SparseArray(SeekData, u8).init(max_num_entities, allocator);
    entity_bump_data = try SparseArray(BumpData, u8).init(max_num_entities, allocator);
}

pub fn reset() void {
    entity_seek_data.clear();
    entity_bump_data.clear();
}

/// Register the entity with the system so that it gets animated
///
pub fn startSeeking(entity_id: u8) !void {
    try entity_bump_data.removeIfExists(entity_id);
    try entity_seek_data.insert(entity_id, SeekData{ .entity_id = entity_id });
}

/// Register the entity with the system so that it gets animated
///
pub fn startBumpBack(entity_id: u8, world_pos: Vec2f, bump_dir: Vec2f, bump_dist: f32) !void {
    try entity_seek_data.removeIfExists(entity_id);
    try entity_bump_data.insert(entity_id, BumpData{ .entity_id = entity_id, .start_world_pos = world_pos, .bump_dir = bump_dir, .bump_dist = bump_dist, .timer = 0 });
}

/// Remove the entity from the system
///
pub fn remove(entity_id: u8) !void {
    try entity_seek_data.removeIfExists(entity_id);
    try entity_bump_data.removeIfExists(entity_id);
}

/// Animate:
/// * Entities moving towards the player target
/// * Entities bumping back in response to a collision
///
pub fn update(player_world_pos: Vec2f, dt: f32, enemy_world_positions: SparseArray(Vec2f, u8), enemy_velocities: SparseArray(Vec2f, u8)) !void {
    try updateSeeking(player_world_pos, dt, enemy_world_positions, enemy_velocities);
    try updateBumpBack(dt, enemy_world_positions);
}

/// Enemies seek out the player and move towards them to attack
///
fn updateSeeking(player_world_pos: Vec2f, dt: f32, enemy_world_positions: SparseArray(Vec2f, u8), enemy_velocities: SparseArray(Vec2f, u8)) !void {
    for (entity_seek_data.toDataSlice()) |ent| {
        const entity_id = ent.entity_id;
        const entity_pos_idx = try enemy_world_positions.lookupDataIndex(entity_id);
        const to_target = player_world_pos - enemy_world_positions.data[entity_pos_idx];
        const mag = maths.magnitude(to_target);
        const dir_to_target = maths.normaliseSafeMag(to_target, mag, enemy_velocities.data[entity_pos_idx]);
        const vel = dir_to_target * @splat(2, @min(consts.ENEMY_MAX_SPEED, mag));
        enemy_velocities.data[entity_pos_idx] = vel;
        enemy_world_positions.data[entity_pos_idx] += vel * @splat(2, dt);
    }
}

/// Animated push back
///
fn updateBumpBack(dt: f32, enemy_world_positions: SparseArray(Vec2f, u8)) !void {
    for (entity_bump_data.toMutableDataSlice()) |*ent| {
        ent.*.timer += dt;
        const x = @min(ent.*.timer / consts.BUMP_TIME, 1.0);
        const y = easeOutBack(x);
        const entity_pos_idx = try enemy_world_positions.lookupDataIndex(ent.*.entity_id);
        enemy_world_positions.data[entity_pos_idx] = ent.*.start_world_pos + ent.*.bump_dir * @splat(2, ent.*.bump_dist * y);

        if (x >= 1.0) {
            //Done bumping so put back to seeking
            try startSeeking(ent.*.entity_id);
        }
    }
}

/// Easing function to animate the bump back
///
fn easeOutBack(x: f32) f32 {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    const xminus = x - 1;
    return 1 + c3 * (xminus * xminus * xminus) + c1 * (xminus * xminus);
}
