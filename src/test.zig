const std = @import("std");
const graphics_coords = @import("graphics_coords.zig");
const Vec2i = @Vector(2, i32);

test "worldSpaceToScreenSpace - extremes" {
    const world_pos = [_]Vec2i{ Vec2i{ 0, 0 }, Vec2i{ 200, -120 }, Vec2i{ 200, 120 }, Vec2i{ -200, -120 }, Vec2i{ -200, 120 } };
    const camera_pos = Vec2i{ 0, 0 };
    var screen_pos: [5]Vec2i = undefined;
    const expected = [_]Vec2i{ Vec2i{ 200, 120 }, Vec2i{ 400, 240 }, Vec2i{ 400, 0 }, Vec2i{ 0, 240 }, Vec2i{ 0, 0 } };
    graphics_coords.worldSpaceToScreenSpace(camera_pos, world_pos[0..], screen_pos[0..], 400, 240);

    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        try std.testing.expect(screen_pos[i][0] == expected[i][0]);
        try std.testing.expect(screen_pos[i][1] == expected[i][1]);
    }
}
