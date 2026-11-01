const std = @import("std");
const level_descs = @import("level_descs.zig");

// Story mode data: the chapters on the route to St Bride's and the story save. Plain comptime tables; main plays
// them (see docs/story-mode-handover.md).

/// One chapter: a level that plays `waves` waves and then stops spawning; it is complete once they are cleared
///
pub const Chapter = struct {
    level: u8, //Index into level_descs.LEVEL_NAMES
    waves: u8,
};

/// A chapter on the level called `level_name`, checked at compile time
///
fn chapter(comptime level_name: []const u8, waves: u8) Chapter {
    if (waves == 0) @compileError("a chapter needs at least one wave: " ++ level_name);
    for (level_descs.LEVEL_NAMES, 0..) |n, i| {
        if (std.mem.eql(u8, n, level_name)) return .{ .level = i, .waves = waves };
    }
    @compileError("story chapter on an unknown level: " ++ level_name);
}

/// The route, in order. Until their own kits exist the chapters borrow the existing levels; the ward (chapter 6,
/// no horde) joins with its level and the walk objective
pub const CHAPTERS = [_]Chapter{
    chapter("city", 2), //1 Ashby Road (suburb kit to come)
    chapter("city", 3), //2 Town Centre
    chapter("woods", 3), //3 Fallow Park
    chapter("quarantine", 4), //4 The Cordon
    chapter("quarantine", 5), //5 St Bride's (hospital grounds kit to come)
};
comptime {
    if (CHAPTERS.len > std.math.maxInt(u8)) @compileError("chapter indices are u8");
}

/// Where the story is up to, saved between sessions at chapter boundaries only. Fixed size binary: a magic tag, so
/// a missing, foreign or old format file reads as a fresh story, then the chapter to play next
///
pub const Save = struct {
    chapter: u8 = 0, //Index into CHAPTERS
};

pub const FILE_NAME = "story.bin";
const MAGIC = "UTS1";
pub const SAVE_SIZE = MAGIC.len + 1;

pub fn encode(save: Save) [SAVE_SIZE]u8 {
    var bytes: [SAVE_SIZE]u8 = undefined;
    @memcpy(bytes[0..MAGIC.len], MAGIC);
    bytes[MAGIC.len] = save.chapter;
    return bytes;
}

/// Anything that isn't a whole record of this format, or names a chapter that no longer exists, is a fresh story
///
pub fn decode(bytes: []const u8) Save {
    if (bytes.len != SAVE_SIZE or !std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return .{};
    const ch = bytes[MAGIC.len];
    return if (ch < CHAPTERS.len) .{ .chapter = ch } else .{};
}

test "[story] every chapter is on a real level and has waves" {
    for (CHAPTERS) |c| {
        try std.testing.expect(c.level < level_descs.LEVEL_NAMES.len);
        try std.testing.expect(c.waves > 0);
    }
}

test "[story] the save round trips the chapter" {
    for (0..CHAPTERS.len) |c| {
        const bytes = encode(.{ .chapter = @intCast(c) });
        try std.testing.expect(decode(&bytes).chapter == c);
    }
}

test "[story] a missing, short, foreign or out of range save is a fresh story" {
    try std.testing.expect(decode(&.{}).chapter == 0);
    const bytes = encode(.{ .chapter = 1 });
    try std.testing.expect(decode(bytes[0 .. SAVE_SIZE - 1]).chapter == 0);
    var foreign = bytes;
    foreign[0] = 'X';
    try std.testing.expect(decode(&foreign).chapter == 0);
    var past_end = bytes;
    past_end[SAVE_SIZE - 1] = CHAPTERS.len;
    try std.testing.expect(decode(&past_end).chapter == 0);
}
