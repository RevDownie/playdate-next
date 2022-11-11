const std = @import("std");
const Vec2f = @Vector(2, f32);

/// Calculate normalised vector - components divided by magnitude
///
pub fn normalise_safe(v: Vec2f) Vec2f {
    if (v[0] == 0 and v[1] == 0) {
        return v;
    }

    const m = @sqrt(v[0] * v[0] + v[1] * v[1]);
    return v / @splat(2, m);
}

test "[maths] normalise_safe - regular" {
    const n = normalise_safe(Vec2f{ 10, 10 });
    const expected = Vec2f{ 0.707, 0.707 };
    std.debug.print("{}, {}\n", .{ n[0], n[1] });
    try std.testing.expectApproxEqRel(n[0], expected[0], 0.01);
    try std.testing.expectApproxEqRel(n[1], expected[1], 0.01);
}

test "[maths] normalise_safe - zero" {
    const n = normalise_safe(Vec2f{ 0, 0 });
    const expected = Vec2f{ 0, 0 };
    try std.testing.expect(n[0] == expected[0]);
    try std.testing.expect(n[1] == expected[1]);
}
