const std = @import("std");
const pd = @import("playdate.zig").api;
const consts = @import("tweak_constants.zig");

const Vec2f = @Vector(2, f32);

/// Load the object data for the level map converting the co-ords into isometric world positions
/// and returning the bitmap table indices
///
pub fn loadLevelMap(playdate_api: *pd.PlaydateAPI, level_file_name: [*c]const u8, world_positions: *std.ArrayList(Vec2f), bitmap_indices: *std.ArrayList(u8)) void {
    const file = playdate_api.file.*;

    var lvl_file = file.open.?(level_file_name, pd.kFileRead);
    defer _ = file.close.?(lvl_file);

    var buffer: [1024]u8 = undefined;
    const data_len = file.read.?(lvl_file, &buffer, 1024);
    std.debug.assert(data_len < 1024);

    var i: usize = 0;
    const grid_width = buffer[i];
    const grid_width_half = grid_width / 2;
    i += 1;
    const grid_height_half = buffer[i] / 2;
    i += 1;
    const cell_width_half = buffer[i] / 2;
    i += 1;
    const cell_height_half = buffer[i] / 2;
    i += 1;

    while (i < data_len) {
        const idx = std.mem.readIntSliceNative(u16, buffer[i .. i + 2]);
        const x = @intCast(i32, idx % grid_width) - grid_width_half;
        const y = @intCast(i32, idx / grid_width) - grid_height_half;
        const world_pos = Vec2f{ @intToFloat(f32, (x - y) * cell_width_half), @intToFloat(f32, (x + y) * cell_height_half * -1) } / @splat(2, consts.METRES_TO_PIXELS);
        world_positions.append(world_pos) catch @panic("loadLevelMap: Failed to append world pos");
        i += 2;

        const sprite_id = buffer[i];
        bitmap_indices.append(sprite_id - 1) catch @panic("loadLevelMap: Failed to append bitmap idx");
        i += 1;
    }
}
