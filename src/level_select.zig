const std = @import("std");

/// The level for the next run, out of `count`: `forced` if set (a debug override), otherwise a random one that
/// isn't the level just played (`previous`), so every retry is somewhere new while there is a choice
///
pub fn next(rand: std.Random, count: usize, previous: ?usize, forced: ?usize) usize {
    std.debug.assert(count > 0);
    if (forced) |f| return f;
    const prev = previous orelse return rand.uintLessThan(usize, count);
    if (count == 1) return 0;
    //Pick among the others: skip over the previous one
    const pick = rand.uintLessThan(usize, count - 1);
    return if (pick >= prev) pick + 1 else pick;
}

test "[level_select] a forced level always wins" {
    var prng = std.Random.DefaultPrng.init(1);
    for (0..20) |_| try std.testing.expect(next(prng.random(), 3, 2, 2) == 2);
}

test "[level_select] never the same level twice in a row, and every level comes up" {
    var prng = std.Random.DefaultPrng.init(2);
    var seen: [4]u32 = @splat(0);
    var prev: ?usize = null;
    for (0..400) |_| {
        const n = next(prng.random(), 4, prev, null);
        try std.testing.expect(n < 4);
        if (prev) |p| try std.testing.expect(n != p);
        seen[n] += 1;
        prev = n;
    }
    for (seen) |s| try std.testing.expect(s > 50);
}

test "[level_select] a single level repeats" {
    var prng = std.Random.DefaultPrng.init(3);
    try std.testing.expect(next(prng.random(), 1, null, null) == 0);
    try std.testing.expect(next(prng.random(), 1, 0, null) == 0);
}
