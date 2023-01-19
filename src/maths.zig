const std = @import("std");
const Vec2f = @Vector(2, f32);

/// Calculate normalised vector - components divided by magnitude
///
pub fn normaliseSafe(v: Vec2f, fallback: Vec2f) Vec2f {
    if (v[0] == 0 and v[1] == 0) {
        return fallback;
    }

    const m = magnitude(v);
    return v / @splat(2, m);
}

/// Calculate normalised vector when you already have the magnitude
///
pub fn normaliseSafeMag(v: Vec2f, m: f32, fallback: Vec2f) Vec2f {
    if (m == 0) {
        return fallback;
    }

    return v / @splat(2, m);
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
    const deg = (atan2(f32, v2[1], v2[0]) - atan2(f32, v1[1], v1[0])) * 180.0 / 3.14159265;
    const cw = 360 - deg;
    return if (cw < 360) cw else cw - 360;
}

test "[maths] normaliseSafe - regular" {
    const n = normaliseSafe(Vec2f{ 10, 10 }, Vec2f{ 0, 0 });
    const expected = Vec2f{ 0.707, 0.707 };
    try std.testing.expectApproxEqRel(n[0], expected[0], 0.01);
    try std.testing.expectApproxEqRel(n[1], expected[1], 0.01);
}

test "[maths] normaliseSafe - zero" {
    const n = normaliseSafe(Vec2f{ 0, 0 }, Vec2f{ 0, 0 });
    const expected = Vec2f{ 0, 0 };
    try std.testing.expect(n[0] == expected[0]);
    try std.testing.expect(n[1] == expected[1]);
}

test "[maths] normaliseSafeMag - regular" {
    const m = magnitude(Vec2f{ 10, 10 });
    const n = normaliseSafeMag(Vec2f{ 10, 10 }, m, Vec2f{ 0, 0 });
    const expected = Vec2f{ 0.707, 0.707 };
    try std.testing.expectApproxEqRel(n[0], expected[0], 0.01);
    try std.testing.expectApproxEqRel(n[1], expected[1], 0.01);
}

test "[maths] magnitude - regular" {
    const m = magnitude(Vec2f{ 10, 10 });
    const expected = 14.142;
    try std.testing.expectApproxEqRel(m, expected, 0.01);
}

test "[maths] magnitude - zero" {
    const m = magnitude(Vec2f{ 0, 0 });
    const expected = 0;
    try std.testing.expect(m == expected);
}

test "[maths] angleDegrees360 - zero" {
    const a = angleDegrees360(Vec2f{ 1, 0 }, Vec2f{ 1, 0 });
    const expected = 0;
    try std.testing.expect(a == expected);
}

test "[maths] angleDegrees360 - orthoganal" {
    const a = angleDegrees360(Vec2f{ 0, 1 }, Vec2f{ 1, 0 });
    const expecteda = 90;
    try std.testing.expect(a == expecteda);

    const b = angleDegrees360(Vec2f{ 0, 1 }, Vec2f{ 0, -1 });
    const expectedb = 180;
    try std.testing.expect(b == expectedb);

    const c = angleDegrees360(Vec2f{ 0, 1 }, Vec2f{ -1, 0 });
    const expectedc = 270;
    try std.testing.expect(c == expectedc);
}

test "[maths] angleDegrees360 - all quadrants" {
    const a = angleDegrees360(Vec2f{ 0, 1 }, Vec2f{ 0.5, 0.5 });
    const expecteda = 45;
    try std.testing.expect(a == expecteda);

    const b = angleDegrees360(Vec2f{ 0, 1 }, Vec2f{ 0.5, -0.5 });
    const expectedb = 135;
    try std.testing.expect(b == expectedb);

    const c = angleDegrees360(Vec2f{ 0, 1 }, Vec2f{ -0.5, -0.5 });
    const expectedc = 225;
    try std.testing.expect(c == expectedc);

    const d = angleDegrees360(Vec2f{ 0, 1 }, Vec2f{ -0.5, 0.5 });
    const expectedd = 315;
    try std.testing.expect(d == expectedd);
}
