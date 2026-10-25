const std = @import("std");

/// Playdate Rev A is an STM32F746 (Cortex-M7): 4 KB L1 data cache, 32 byte lines, and RAM behind it is slow.
/// Rev B uses a different chip that is assumed to be no smaller, so we design for 4 KB.
pub const L1_DCACHE_SIZE = 4 * 1024;
pub const CACHE_LINE_SIZE = 32;

/// Data a loop revisits (re-read per outer iteration, or accessed in random order) should fit in this,
/// leaving the other half of the cache for the stack, the Playdate API and framebuffer writes.
/// Data streamed through once only needs to be packed tightly (no padding, no cold fields mixed in)
pub const HOT_SET_BUDGET = L1_DCACHE_SIZE / 2;

/// A linear (bump) allocator over a fixed buffer, reset wholesale at the end of its phase.
/// The game uses one per lifetime: app (whole run), level (until the next level load) and frame (one tick).
/// Running out of space is a sizing bug, so allocation panics with the arena's name rather than returning an error.
///
pub const Arena = struct {
    name: []const u8,
    fba: std.heap.FixedBufferAllocator,
    high_water: usize = 0,

    pub fn init(name: []const u8, buffer: []u8) Arena {
        return .{ .name = name, .fba = std.heap.FixedBufferAllocator.init(buffer) };
    }

    /// Allocate `n` items, panicking if the arena is full
    ///
    pub fn alloc(self: *Arena, comptime T: type, n: usize) []T {
        const items = self.fba.allocator().alloc(T, n) catch {
            std.debug.panic("{s} arena: out of memory ({d} x {s}, {d}/{d} bytes used)", .{ self.name, n, @typeName(T), self.fba.end_index, self.fba.buffer.len });
        };
        self.high_water = @max(self.high_water, self.fba.end_index);
        return items;
    }

    /// Carve a child arena out of this one (e.g. the level and frame arenas out of the app arena)
    ///
    pub fn subArena(self: *Arena, name: []const u8, size: usize) Arena {
        return Arena.init(name, self.alloc(u8, size));
    }

    /// Release everything allocated from the arena. In Debug the memory is filled with 0xaa so
    /// anything still holding on to it shows up quickly
    ///
    pub fn reset(self: *Arena) void {
        if (std.debug.runtime_safety) @memset(self.fba.buffer[0..self.fba.end_index], 0xaa);
        self.fba.end_index = 0;
    }

    pub fn used(self: *const Arena) usize {
        return self.fba.end_index;
    }

    pub fn capacity(self: *const Arena) usize {
        return self.fba.buffer.len;
    }
};

test "[memory] alloc and reset" {
    var buffer: [256]u8 = undefined;
    var arena = Arena.init("test", &buffer);

    const a = arena.alloc(u32, 4);
    try std.testing.expect(a.len == 4);
    try std.testing.expect(arena.used() >= 16);

    arena.reset();
    try std.testing.expect(arena.used() == 0);
    try std.testing.expect(arena.high_water >= 16);
}

test "[memory] sub arena" {
    var buffer: [256]u8 = undefined;
    var app = Arena.init("app", &buffer);
    var frame = app.subArena("frame", 64);
    try std.testing.expect(frame.capacity() == 64);
    _ = frame.alloc(u8, 64);
    try std.testing.expect(frame.used() == 64);
}
