const std = @import("std");

/// The record saved between sessions (main reads it once at init and writes it when a run ends with a new best).
/// Fixed size binary: a magic tag, so a missing, foreign or old format file reads as "no best yet", then the
/// best score as a u64 little endian
///
pub const SaveData = struct {
    best_score: u64 = 0,
};

pub const FILE_NAME = "best.bin";
const MAGIC = "UTN1";
pub const SIZE = MAGIC.len + @sizeOf(u64);

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
