const std = @import("std");
const Vec2i = @Vector(2, i32);

/// Convert the list of world space coords through camera space and then to screen space ready for rendering
///
pub fn worldSpaceToScreenSpace(camera_pos: Vec2i, world_pos: []const Vec2i, screen_pos: []Vec2i, screen_width: i32, screen_height: i32) void {
    const half_width = screen_width >> 1;
    const half_height = screen_height >> 1;

    var i: usize = 0;
    while (i < world_pos.len) : (i += 1) {
        //World to Camera
        const cam_space = world_pos[i] - camera_pos;
        //Camera to Screen
        screen_pos[i] = Vec2i{ cam_space[0] + half_width, (cam_space[1] - half_height) * -1 };
    }
}

test "[graphics_coords] worldSpaceToScreenSpace - extremes" {
    const world_pos = [_]Vec2i{ Vec2i{ 0, 0 }, Vec2i{ 200, -120 }, Vec2i{ 200, 120 }, Vec2i{ -200, -120 }, Vec2i{ -200, 120 } };
    const camera_pos = Vec2i{ 0, 0 };
    var screen_pos: [5]Vec2i = undefined;
    const expected = [_]Vec2i{ Vec2i{ 200, 120 }, Vec2i{ 400, 240 }, Vec2i{ 400, 0 }, Vec2i{ 0, 240 }, Vec2i{ 0, 0 } };
    worldSpaceToScreenSpace(camera_pos, world_pos[0..], screen_pos[0..], 400, 240);

    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        try std.testing.expect(screen_pos[i][0] == expected[i][0]);
        try std.testing.expect(screen_pos[i][1] == expected[i][1]);
    }
}
