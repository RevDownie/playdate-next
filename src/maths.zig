const std = @import("std");
const Vec2f = @Vector(2, f32);

/// Calculate normalised vector - components divided by magnitude
///
pub fn normaliseSafe(v: Vec2f, fallback: Vec2f) Vec2f {
    if (v[0] == 0 and v[1] == 0) {
        return fallback;
    }

    const m = magnitude(v);
    return v / @as(Vec2f, @splat(m));
}

/// Calculate normalised vector when you already have the magnitude
///
pub fn normaliseSafeMag(v: Vec2f, m: f32, fallback: Vec2f) Vec2f {
    if (m == 0) {
        return fallback;
    }

    return v / @as(Vec2f, @splat(m));
}

/// Calculate the length of the vector
///
pub inline fn magnitude(v: Vec2f) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

/// Calculate the length of the vector without doing the square root
///
pub inline fn magnitudeSqrd(v: Vec2f) f32 {
    return v[0] * v[0] + v[1] * v[1];
}

/// Returns the angle in degrees between the 2 vectors in the range 0 - 360
///
pub inline fn angleDegrees360(v1: Vec2f, v2: Vec2f) f32 {
    const atan2 = std.math.atan2;
    const deg = (atan2(v2[1], v2[0]) - atan2(v1[1], v1[0])) * (180.0 / std.math.pi);
    const cw = 360 - deg;
    return if (cw < 360) cw else cw - 360;
}

/// Dot product: the cosine of the angle between two unit vectors
///
pub inline fn dot(v1: Vec2f, v2: Vec2f) f32 {
    return v1[0] * v2[0] + v1[1] * v2[1];
}

test "[maths] normaliseSafe: unit length, or the fallback for a zero vector" {
    const n = normaliseSafe(Vec2f{ 3, -4 }, Vec2f{ 1, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.8), n[1], 0.0001);
    const fallback = normaliseSafe(Vec2f{ 0, 0 }, Vec2f{ 0, -1 });
    try std.testing.expect(fallback[0] == 0 and fallback[1] == -1);
}

test "[maths] angleDegrees360 is clockwise from the first vector, in 0..360" {
    const cases = [_]struct { to: Vec2f, deg: f32 }{
        .{ .to = .{ 0, 1 }, .deg = 0 },
        .{ .to = .{ 0.5, 0.5 }, .deg = 45 },
        .{ .to = .{ 1, 0 }, .deg = 90 },
        .{ .to = .{ 0.5, -0.5 }, .deg = 135 },
        .{ .to = .{ 0, -1 }, .deg = 180 },
        .{ .to = .{ -0.5, -0.5 }, .deg = 225 },
        .{ .to = .{ -1, 0 }, .deg = 270 },
        .{ .to = .{ -0.5, 0.5 }, .deg = 315 },
    };
    for (cases) |c| {
        const a = angleDegrees360(Vec2f{ 0, 1 }, c.to);
        try std.testing.expectApproxEqAbs(c.deg, a, 0.001);
        try std.testing.expect(a >= 0 and a < 360);
    }
}
