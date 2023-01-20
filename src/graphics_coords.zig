const std = @import("std");
const consts = @import("tweak_constants.zig");

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

/// Convert the list of world space coords through camera space and then to screen space ready for rendering
/// 1m = 128 pixels (consts.METRES_TO_PIXELS)
///
pub fn worldSpaceToScreenSpace(camera_pos: Vec2f, world_pos: []const Vec2f, screen_pos: []Vec2i, screen_width: i32, screen_height: i32) void {
    const half_width = screen_width >> 1;
    const half_height = screen_height >> 1;

    var i: usize = 0;
    while (i < world_pos.len) : (i += 1) {
        //World to Camera
        const cam_space = world_pos[i] - camera_pos;

        //Camera to Screen
        const screen_posf = Vec2f{ cam_space[0] * consts.METRES_TO_PIXELS + @intToFloat(f32, half_width), (cam_space[1] * consts.METRES_TO_PIXELS - @intToFloat(f32, half_height)) * -1 };
        screen_pos[i] = Vec2i{ @floatToInt(i32, screen_posf[0]), @floatToInt(i32, screen_posf[1]) };
    }
}

test "[graphics_coords] worldSpaceToScreenSpace - metre conversion" {
    const world_pos = [_]Vec2f{ Vec2f{ 0, 0 }, Vec2f{ 1, -1 }, Vec2f{ 1, 1 }, Vec2f{ -1, -1 }, Vec2f{ -1, 1 } };
    const camera_pos = Vec2f{ 0, 0 };
    var screen_pos: [5]Vec2i = undefined;
    const expected = [_]Vec2i{ Vec2i{ 200, 120 }, Vec2i{ 200 + 128, 120 + 128 }, Vec2i{ 200 + 128, 120 - 128 }, Vec2i{ 200 - 128, 120 + 128 }, Vec2i{ 200 - 128, 120 - 128 } };
    worldSpaceToScreenSpace(camera_pos, world_pos[0..], screen_pos[0..], 400, 240);

    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        try std.testing.expect(screen_pos[i][0] == expected[i][0]);
        try std.testing.expect(screen_pos[i][1] == expected[i][1]);
    }
}
