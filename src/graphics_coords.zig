/// Responsible for converting between coordinate spaces, from world to screen
///
const std = @import("std");
const consts = @import("tweak_constants.zig");

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

/// A world position (metres, +y up) through camera space to screen pixels (+y down), with the camera at the
/// screen's centre. 1m = METRES_TO_PIXELS pixels
///
pub inline fn worldPointToScreen(camera_pos: Vec2f, world_pos: Vec2f, screen_width: i32, screen_height: i32) Vec2i {
    const half_width: f32 = @floatFromInt(screen_width >> 1);
    const half_height: f32 = @floatFromInt(screen_height >> 1);

    //World to Camera
    const cam_space = world_pos - camera_pos;

    //Camera to Screen
    const screen_posf = Vec2f{ cam_space[0] * consts.METRES_TO_PIXELS + half_width, (cam_space[1] * consts.METRES_TO_PIXELS - half_height) * -1 };
    return Vec2i{ @intFromFloat(screen_posf[0]), @intFromFloat(screen_posf[1]) };
}

test "[graphics_coords] worldPointToScreen - metre conversion" {
    const world_pos = [_]Vec2f{ Vec2f{ 0, 0 }, Vec2f{ 1, -1 }, Vec2f{ 1, 1 }, Vec2f{ -1, -1 }, Vec2f{ -1, 1 } };
    const expected = [_]Vec2i{ Vec2i{ 200, 120 }, Vec2i{ 200 + 128, 120 + 128 }, Vec2i{ 200 + 128, 120 - 128 }, Vec2i{ 200 - 128, 120 + 128 }, Vec2i{ 200 - 128, 120 - 128 } };
    for (world_pos, expected) |wp, e| {
        try std.testing.expect(@reduce(.And, worldPointToScreen(@splat(0), wp, 400, 240) == e));
    }
}

pub const EdgeMarker = struct {
    pos: Vec2i, //Where to draw it, on the inset edge of the screen
    dir: Vec2f, //Unit length, screen space (+y down): the way to the thing it marks
};

/// Where to mark something off screen at `screen_pos`: on the screen's edge, inset by `left`/`top`/`right`/`bottom`
/// pixels, along the line from the centre of the screen (the player) towards it. Null if it is on screen
///
pub fn offScreenMarker(screen_pos: Vec2i, width: i32, height: i32, left: i32, top: i32, right: i32, bottom: i32) ?EdgeMarker {
    if (screen_pos[0] >= 0 and screen_pos[1] >= 0 and screen_pos[0] < width and screen_pos[1] < height) return null;
    const centre = Vec2f{ @floatFromInt(@divTrunc(width, 2)), @floatFromInt(@divTrunc(height, 2)) };
    const d = @as(Vec2f, @floatFromInt(screen_pos)) - centre;
    //How far along d each pair of edges is; the nearer one is where the line leaves the inset rectangle
    const tx = if (d[0] > 0) (@as(f32, @floatFromInt(width - right)) - centre[0]) / d[0] else if (d[0] < 0) (@as(f32, @floatFromInt(left)) - centre[0]) / d[0] else std.math.inf(f32);
    const ty = if (d[1] > 0) (@as(f32, @floatFromInt(height - bottom)) - centre[1]) / d[1] else if (d[1] < 0) (@as(f32, @floatFromInt(top)) - centre[1]) / d[1] else std.math.inf(f32);
    const t = @min(tx, ty);
    const len = @sqrt(d[0] * d[0] + d[1] * d[1]);
    return .{ .pos = @intFromFloat(@round(centre + d * @as(Vec2f, @splat(t)))), .dir = d / @as(Vec2f, @splat(len)) };
}

test "[graphics_coords] off screen markers sit on the inset edge, pointing the way" {
    try std.testing.expect(offScreenMarker(.{ 10, 10 }, 400, 240, 16, 46, 16, 30) == null);
    const right = offScreenMarker(.{ 900, 120 }, 400, 240, 16, 46, 16, 30).?;
    try std.testing.expect(right.pos[0] == 384 and right.pos[1] == 120 and right.dir[0] == 1);
    const up = offScreenMarker(.{ 200, -500 }, 400, 240, 16, 46, 16, 30).?;
    try std.testing.expect(up.pos[0] == 200 and up.pos[1] == 46 and up.dir[1] == -1);
    //Diagonal: whichever edge the line meets first
    const corner = offScreenMarker(.{ -1000, 1000 }, 400, 240, 16, 46, 16, 30).?;
    try std.testing.expect(corner.pos[1] == 210 and corner.pos[0] > 16 and corner.pos[0] < 200);
}
