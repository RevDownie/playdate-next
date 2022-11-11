const std = @import("std");
const Vec2f = @Vector(2, f32);

/// Calculate normalised vector - components divided by magnitude
///
pub fn normaliseSafe(v: Vec2f) Vec2f {
    if (v[0] == 0 and v[1] == 0) {
        return v;
    }

    const m = magnitude(v);
    return v / @splat(2, m);
}

/// Calculate normalised vector when you already have the magnitude
///
pub fn normaliseSafeMag(v: Vec2f, m: f32) Vec2f {
    if (m == 0) {
        return v;
    }

    return v / @splat(2, m);
}

/// Calculate the length of the vector
///
pub inline fn magnitude(v: Vec2f) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

test "[maths] normaliseSafe - regular" {
    const n = normaliseSafe(Vec2f{ 10, 10 });
    const expected = Vec2f{ 0.707, 0.707 };
    try std.testing.expectApproxEqRel(n[0], expected[0], 0.01);
    try std.testing.expectApproxEqRel(n[1], expected[1], 0.01);
}

test "[maths] normaliseSafe - zero" {
    const n = normaliseSafe(Vec2f{ 0, 0 });
    const expected = Vec2f{ 0, 0 };
    try std.testing.expect(n[0] == expected[0]);
    try std.testing.expect(n[1] == expected[1]);
}

test "[maths] normaliseSafeMag - regular" {
    const m = magnitude(Vec2f{ 10, 10 });
    const n = normaliseSafeMag(Vec2f{ 10, 10 }, m);
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
