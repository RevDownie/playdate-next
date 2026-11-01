const std = @import("std");
const level_descs = @import("level_descs.zig");

// Story mode data: the chapters on the route to St Bride's, their card text and the story save. Plain comptime
// tables; main plays them (see docs/story-mode-handover.md).

/// `survive`: play the chapter's waves, complete once the last is cleared. `walk`: no horde, complete once the
/// player has walked WALK_DIST (a stand-in until the ward has its bed to reach)
pub const Objective = enum(u8) { survive, walk };

/// One chapter on a level. A survive chapter plays waves `first_wave` to `last_wave` of the run's wave table, so
/// later chapters start where the fight is harder
///
pub const Chapter = struct {
    level: u8, //Index into level_descs.LEVEL_NAMES
    objective: Objective,
    first_wave: u8 = 0, //Survive only, 1 based
    last_wave: u8 = 0,

    pub fn waveCount(self: Chapter) u8 {
        return if (self.objective == .survive) self.last_wave - self.first_wave + 1 else 0;
    }
};

/// Metres a walk chapter has the player walk before it is complete
pub const WALK_DIST: f32 = 30;

/// A chapter on the level called `level_name`, checked at compile time
///
fn levelIndex(comptime level_name: []const u8) u8 {
    for (level_descs.LEVEL_NAMES, 0..) |n, i| {
        if (std.mem.eql(u8, n, level_name)) return i;
    }
    @compileError("story chapter on an unknown level: " ++ level_name);
}

fn survive(comptime level_name: []const u8, first_wave: u8, last_wave: u8) Chapter {
    return .{ .level = levelIndex(level_name), .objective = .survive, .first_wave = first_wave, .last_wave = last_wave };
}

fn walk(comptime level_name: []const u8) Chapter {
    return .{ .level = levelIndex(level_name), .objective = .walk };
}

/// The route, in order. Until their own kits and maps exist the chapters borrow the existing levels
pub const CHAPTERS = [_]Chapter{
    survive("city", 1, 3), //Ashby Road (suburb kit to come)
    survive("city", 2, 5), //Town Centre
    survive("woods", 4, 7), //Fallow Park
    survive("quarantine", 5, 9), //The Cordon: the fever's peak
    survive("quarantine", 7, 12), //St Bride's (hospital grounds kit to come): the biggest fight
    walk("quarantine"), //The Ward (interior kit to come): no horde
};

/// Placeholder card text until the writing pass (the handover's key beats)
pub const CHAPTER_NAMES = [CHAPTERS.len][]const u8{ "Ashby Road", "Town Centre", "Fallow Park", "The Cordon", "St Bride's", "The Ward" };
pub const CHAPTER_INTROS = [CHAPTERS.len][]const u8{
    "You wake on the kitchen floor. The street outside is screaming.",
    "Every clock in town says 2:10.",
    "The roads are blocked. Through the park, then.",
    "They've fenced off the hospital.",
    "Dawn. The first light in days.",
    "Inside, it is quiet.",
};

comptime {
    if (CHAPTERS.len > std.math.maxInt(u8)) @compileError("chapter indices are u8");
    var prev_first: u8 = 1;
    for (CHAPTERS, 0..) |c, i| switch (c.objective) {
        .survive => {
            if (c.first_wave < 1 or c.last_wave < c.first_wave) @compileError(std.fmt.comptimePrint("chapter {d}: needs waves first_wave..last_wave from 1", .{i + 1}));
            if (c.first_wave < prev_first) @compileError(std.fmt.comptimePrint("chapter {d} starts on an easier wave than the one before", .{i + 1}));
            prev_first = c.first_wave;
        },
        .walk => if (c.first_wave != 0 or c.last_wave != 0) @compileError(std.fmt.comptimePrint("chapter {d}: a walk chapter has no waves", .{i + 1})),
    };
}

/// Where the story is up to, saved between sessions at chapter boundaries only. Fixed size binary: a magic tag, so
/// a missing, foreign or old format file reads as a fresh story, then the chapter to play next and, for judging the
/// story's length, the play time of the chapters completed so far
///
pub const Save = struct {
    chapter: u8 = 0, //Index into CHAPTERS
    play_secs: u32 = 0, //Every attempt at every completed chapter
};

pub const FILE_NAME = "story.bin";
const MAGIC = "UTS3";
pub const SAVE_SIZE = MAGIC.len + 1 + 4;

pub fn encode(save: Save) [SAVE_SIZE]u8 {
    var bytes: [SAVE_SIZE]u8 = undefined;
    @memcpy(bytes[0..MAGIC.len], MAGIC);
    bytes[MAGIC.len] = save.chapter;
    std.mem.writeInt(u32, bytes[MAGIC.len + 1 ..][0..4], save.play_secs, .little);
    return bytes;
}

/// Anything that isn't a whole record of this format, or names a chapter that no longer exists, is a fresh story
///
pub fn decode(bytes: []const u8) Save {
    if (bytes.len != SAVE_SIZE or !std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return .{};
    const ch = bytes[MAGIC.len];
    if (ch >= CHAPTERS.len) return .{};
    return .{
        .chapter = ch,
        .play_secs = std.mem.readInt(u32, bytes[MAGIC.len + 1 ..][0..4], .little),
    };
}

test "[story] every chapter is on a real level, survive chapters have waves and none gets easier" {
    var prev_first: u8 = 1;
    for (CHAPTERS) |c| {
        try std.testing.expect(c.level < level_descs.LEVEL_NAMES.len);
        switch (c.objective) {
            .survive => {
                try std.testing.expect(c.waveCount() > 0 and c.first_wave >= prev_first);
                prev_first = c.first_wave;
            },
            .walk => try std.testing.expect(c.waveCount() == 0),
        }
    }
    try std.testing.expect(CHAPTERS[CHAPTERS.len - 1].objective == .walk); //The ward ends it
}

test "[story] the save round trips" {
    for (0..CHAPTERS.len) |c| {
        const save = Save{ .chapter = @intCast(c), .play_secs = 1234 + @as(u32, @intCast(c)) };
        const bytes = encode(save);
        try std.testing.expect(std.meta.eql(decode(&bytes), save));
    }
}

test "[story] a missing, short, foreign or out of range save is a fresh story" {
    const fresh = Save{};
    try std.testing.expect(std.meta.eql(decode(&.{}), fresh));
    const bytes = encode(.{ .chapter = 1, .play_secs = 60 });
    try std.testing.expect(std.meta.eql(decode(bytes[0 .. SAVE_SIZE - 1]), fresh));
    var foreign = bytes;
    foreign[0] = 'X';
    try std.testing.expect(std.meta.eql(decode(&foreign), fresh));
    var past_end = bytes;
    past_end[MAGIC.len] = CHAPTERS.len;
    try std.testing.expect(std.meta.eql(decode(&past_end), fresh));
}
