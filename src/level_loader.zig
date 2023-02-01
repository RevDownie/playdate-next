const std = @import("std");
const pd = @import("playdate.zig").api;
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

pub const LevelMapData = struct {
    obj_world_positions: []Vec2f,
    obj_bitmap_indices: []u8,
};

/// Load the object data for the level map converting the co-ords into isometric world positions
/// and returning the bitmap table indices
///
pub fn loadLevelMap(playdate_api: *pd.PlaydateAPI, level_file_name: [*c]const u8, allocator: std.mem.Allocator) LevelMapData {
    const file = playdate_api.file.*;

    var lvl_file = file.open.?(level_file_name, pd.kFileRead);
    defer _ = file.close.?(lvl_file);

    var buffer: [1024]u8 = undefined;
    const data_len = file.read.?(lvl_file, &buffer, 1024);
    std.debug.assert(data_len < 1024);

    var read_idx: usize = 0;
    const grid_width = buffer[read_idx];
    const grid_width_half = grid_width / 2;
    read_idx += 1;
    const grid_height_half = buffer[read_idx] / 2;
    read_idx += 1;
    const cell_width_half = buffer[read_idx] / 2;
    read_idx += 1;
    const cell_height_half = buffer[read_idx] / 2;
    read_idx += 1;

    const num_objs: usize = (@intCast(usize, data_len) - 4) / 3;
    var world_positions = allocator.alloc(Vec2f, num_objs) catch @panic("loadLevelMap: Out of memory for world pos");
    var bitmap_indices = allocator.alloc(u8, num_objs) catch @panic("loadLevelMap: Out of memory for bitmap indices");
    var write_idx: usize = 0;

    while (read_idx < data_len) : (write_idx += 1) {
        const idx = std.mem.readIntSliceNative(u16, buffer[read_idx .. read_idx + 2]);
        const x = @intCast(i32, idx % grid_width) - grid_width_half;
        const y = @intCast(i32, idx / grid_width) - grid_height_half;
        const world_pos = Vec2f{ @intToFloat(f32, (x - y) * cell_width_half), @intToFloat(f32, (x + y) * cell_height_half * -1) } / @splat(2, consts.METRES_TO_PIXELS);
        world_positions[write_idx] = world_pos;
        read_idx += 2;

        const sprite_id = buffer[read_idx];
        bitmap_indices[write_idx] = sprite_id - 1;
        read_idx += 1;
    }

    return LevelMapData{ .obj_world_positions = world_positions, .obj_bitmap_indices = bitmap_indices };
}
