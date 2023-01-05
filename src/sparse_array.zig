const std = @import("std");

const Error = error{
    KeyOutOfRange,
    KeyNotFound,
    KeyAlreadyExists,
};

/// Basic look up array allowing us to decouple the index (key) used for look up from the index of the data
/// in the array. Allows for O(1) insertion and removal while still allowing for contiguous iteration over the data
/// Capacity of this array is fixed but the length can grown within that
///
pub fn SparseArray(comptime T: type, comptime TKey: type) type {
    return struct {
        const Self = @This();
        key_to_index: []TKey,
        index_to_key: []TKey,
        data: []T,
        len: usize,
        allocator: std.mem.Allocator,

        /// Initialise the array with a fixed capacity using the given allocator.
        /// The allocator is never invoked again other than to free the memory
        ///
        pub fn init(capacity: TKey, allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var s = Self{
                .len = 0,
                .key_to_index = try allocator.alloc(TKey, capacity),
                .index_to_key = try allocator.alloc(TKey, capacity),
                .data = try allocator.alloc(T, capacity),
                .allocator = allocator,
            };

            for (s.key_to_index) |_, i| {
                s.key_to_index[i] = capacity;
            }

            return s;
        }

        /// Overwrite the value at the given key if it exists otherwise insert
        /// a new value mapped to the given key
        ///
        pub fn insert(self: *Self, key: TKey, element: T) Error!void {
            if (key >= self.key_to_index.len) {
                return Error.KeyOutOfRange;
            }

            const existing_idx = self.key_to_index[key];
            if (existing_idx < self.key_to_index.len) {
                self.data[existing_idx] = element;
                return;
            }

            self.key_to_index[key] = @intCast(TKey, self.len);
            self.index_to_key[self.len] = key;
            self.data[self.len] = element;
            self.len += 1;
        }

        /// Does not overwrite - will fail if key already exists. Otherwise
        /// creates a new entry
        ///
        pub fn insertFirst(self: *Self, key: TKey, element: T) Error!void {
            if (key >= self.key_to_index.len) {
                return Error.KeyOutOfRange;
            }

            const existing_idx = self.key_to_index[key];
            if (existing_idx < self.key_to_index.len) {
                return Error.KeyAlreadyExists;
            }

            self.key_to_index[key] = @intCast(TKey, self.len);
            self.index_to_key[self.len] = key;
            self.data[self.len] = element;
            self.len += 1;
        }

        /// Lookup the value for the given key
        ///
        pub fn lookup(self: *const Self, key: TKey) Error!T {
            if (key >= self.key_to_index.len) {
                return Error.KeyOutOfRange;
            }

            const existing_idx = self.key_to_index[key];
            if (existing_idx >= self.key_to_index.len) {
                return Error.KeyNotFound;
            }

            return self.data[existing_idx];
        }

        /// Lookup the index into the data for the given key
        ///
        pub fn lookupDataIndex(self: *const Self, key: TKey) Error!TKey {
            if (key >= self.key_to_index.len) {
                return Error.KeyOutOfRange;
            }

            const existing_idx = self.key_to_index[key];
            if (existing_idx >= self.key_to_index.len) {
                return Error.KeyNotFound;
            }

            return existing_idx;
        }

        /// Return slice of the keys and how they map to indices
        pub fn toKeysMapSlice(self: *Self) []TKey {
            return self.key_to_index[0..self.len];
        }

        /// Return slice of the data array actually in use
        pub fn toDataSlice(self: *Self) []T {
            return self.data[0..self.len];
        }

        /// Remove the value with the given key, this can cause underlying array order to shift
        ///
        pub fn remove(self: *Self, key: TKey) Error!void {
            if (key >= self.key_to_index.len) {
                return Error.KeyOutOfRange;
            }

            const existing_idx = self.key_to_index[key];
            if (existing_idx >= self.key_to_index.len) {
                return Error.KeyNotFound;
            }

            self.data[existing_idx] = self.data[self.len - 1];
            self.data[self.len - 1] = undefined;

            const moved_key = self.index_to_key[self.len - 1];
            self.key_to_index[moved_key] = existing_idx;

            self.key_to_index[key] = @intCast(TKey, self.key_to_index.len);
            self.index_to_key[existing_idx] = moved_key;

            self.len -= 1;
        }

        /// Remove the value with the given key, this can cause underlying array order to shift
        /// Silent if key doesn't exist
        ///
        pub fn removeIfExists(self: *Self, key: TKey) Error!void {
            if (key >= self.key_to_index.len) {
                return Error.KeyOutOfRange;
            }

            const existing_idx = self.key_to_index[key];
            if (existing_idx >= self.key_to_index.len) {
                return;
            }

            self.data[existing_idx] = self.data[self.len - 1];
            self.data[self.len - 1] = undefined;

            const moved_key = self.index_to_key[self.len - 1];
            self.key_to_index[moved_key] = existing_idx;

            self.key_to_index[key] = @intCast(TKey, self.key_to_index.len);
            self.index_to_key[existing_idx] = moved_key;

            self.len -= 1;
        }

        /// Release all memory and reset
        ///
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.key_to_index);
            self.allocator.free(self.index_to_key);
            self.allocator.free(self.data);
            self.len = 0;
            self.allocator = undefined;
        }
    };
}

test "[sparse_array] empty construction" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();
    try std.testing.expect(a.len == 0);
}

test "[sparse_array] insert new within range" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();

    try a.insert(10, 12);
    try std.testing.expect(a.len == 1);

    const v = try a.lookup(10);
    try std.testing.expect(v == 12);
}

test "[sparse_array] insert existing within range" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();

    try a.insert(10, 12);
    try std.testing.expect(a.len == 1);

    const v = try a.lookup(10);
    try std.testing.expect(v == 12);

    try a.insert(10, 13);
    try std.testing.expect(a.len == 1);

    const v2 = try a.lookup(10);
    try std.testing.expect(v2 == 13);
}

test "[sparse_array] insert outside range" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();

    try std.testing.expectError(Error.KeyOutOfRange, a.insert(100, 12));
}

test "[sparse_array] lookup missing key" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();

    try a.insert(10, 12);
    try std.testing.expectError(Error.KeyOutOfRange, a.lookup(100));
    try std.testing.expectError(Error.KeyNotFound, a.lookup(0));
}

test "[sparse_array] insert multiple" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();

    try a.insert(10, 12);
    try a.insert(1, 11);
    try std.testing.expect(a.len == 2);

    const v = try a.lookup(10);
    try std.testing.expect(v == 12);

    const v2 = try a.lookup(1);
    try std.testing.expect(v2 == 11);
}

test "[sparse_array] insert first" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();

    try a.insertFirst(10, 12);
    try std.testing.expectError(Error.KeyAlreadyExists, a.insertFirst(10, 11));
    const v = try a.lookup(10);
    try std.testing.expect(v == 12);
}

test "[sparse_array] remove" {
    const alloc = std.testing.allocator;
    var a = try SparseArray(u32, u8).init(100, alloc);
    defer a.deinit();

    try a.insert(10, 12);
    try a.insert(1, 11);

    try a.remove(1);
    try std.testing.expect(a.len == 1);
    try std.testing.expectError(Error.KeyNotFound, a.lookup(1));
    const v = try a.lookup(10);
    try std.testing.expect(v == 12);

    try a.remove(10);
    try std.testing.expect(a.len == 0);
    try std.testing.expectError(Error.KeyNotFound, a.lookup(10));
}
