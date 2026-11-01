const std = @import("std");

/// A level's best score, saved between sessions (main reads every level's once at init and writes a level's when
/// a run on it ends with a new best). Levels play too differently to share one best, so each has its own file,
/// named after the level rather than its index so adding, removing or reordering levels keeps every best with its
/// level. Fixed size binary: a magic tag, so a missing, foreign or old format file reads as "no best yet", then
/// the best score as a u64 little endian
///
pub const SaveData = struct {
    best_score: u64 = 0,
};

const FILE_PREFIX = "best-";
const FILE_SUFFIX = ".bin";
const MAGIC = "UTN1";
pub const SIZE = MAGIC.len + @sizeOf(u64);

/// The longest level name a save file name has room for (main checks every level's at compile time)
pub const MAX_LEVEL_NAME_LEN = 48;
pub const FILE_NAME_CAPACITY = FILE_PREFIX.len + MAX_LEVEL_NAME_LEN + FILE_SUFFIX.len + 1;

/// The save file of the level called `level_name`: `best-<level>.bin`
///
pub fn fileName(buf: *[FILE_NAME_CAPACITY]u8, level_name: []const u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, FILE_PREFIX ++ "{s}" ++ FILE_SUFFIX, .{level_name}, 0) catch unreachable;
}

pub fn encode(data: SaveData) [SIZE]u8 {
    var bytes: [SIZE]u8 = undefined;
    @memcpy(bytes[0..MAGIC.len], MAGIC);
    std.mem.writeInt(u64, bytes[MAGIC.len..SIZE], data.best_score, .little);
    return bytes;
}

/// Anything that isn't a whole record of this format decodes as a fresh save
///
pub fn decode(bytes: []const u8) SaveData {
    if (bytes.len != SIZE or !std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return .{};
    return .{ .best_score = std.mem.readInt(u64, bytes[MAGIC.len..SIZE], .little) };
}

test "[save_data] round trips the best score" {
    const bytes = encode(.{ .best_score = 1234567890 });
    try std.testing.expect(decode(&bytes).best_score == 1234567890);
}

test "[save_data] a missing, short or foreign file is a fresh save" {
    try std.testing.expect(decode(&.{}).best_score == 0);
    const bytes = encode(.{ .best_score = 99 });
    try std.testing.expect(decode(bytes[0 .. SIZE - 1]).best_score == 0);
    var foreign = bytes;
    foreign[0] = 'X';
    try std.testing.expect(decode(&foreign).best_score == 0);
}

test "[save_data] each level saves to a file named after it" {
    var buf: [FILE_NAME_CAPACITY]u8 = undefined;
    try std.testing.expectEqualStrings("best-woods.bin", fileName(&buf, "woods"));
    try std.testing.expectEqualStrings("best-quarantine.bin", fileName(&buf, "quarantine"));
}
