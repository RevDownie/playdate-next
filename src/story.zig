const std = @import("std");
const level_descs = @import("level_descs.zig");
const consts = @import("tweak_constants.zig");

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

/// Who is speaking, which sets how a line is drawn (see hud.drawLine). The player learns to tell them apart before
/// they understand what they are
/// - `tom`: his own thoughts, or said aloud: plain text at the bottom
/// - `tom_radio`: Tom answering Ellie, into the walkie-talkie: at the bottom with the handset, transmitting
/// - `ellie`: the walkie-talkie: a box at the top with a static border, the handset and its light
/// - `pa`: loudspeakers and megaphones: a hard black box, capitals, often cut off
pub const Voice = enum(u8) { tom, tom_radio, ellie, pa };

/// What sets a beat off. game.tick writes these as `GameState.events`; for a wave trigger the beat's `arg` is the
/// chapter's own wave number (1 based), and 0 for the rest
/// - `wave_started`
/// - `wave_over`: the wave ended, cleared or not (one that runs out of time goes straight into the next, and its
///   lines must still play)
/// - `chapter_cleared`: the last wave is cleared. Stands in for reaching the exit until levels have one
/// - `low_health`: health fell to PLAYER_LOW_HEALTH
pub const Trigger = enum(u8) { wave_started, wave_over, chapter_cleared, low_health };

pub const TextId = u16;

/// A line of dialogue that plays once per attempt at its chapter, when its trigger happens. 6 bytes
pub const Beat = struct {
    chapter: u8, //Index into CHAPTERS
    trigger: Trigger,
    arg: u8,
    voice: Voice,
    text: TextId, //Index into TEXT
};

/// A chapter's beats: BEATS[start..end]
pub const BeatRange = struct {
    start: u16 = 0,
    end: u16 = 0,
};

const BeatDef = struct { chapter: u8, trigger: Trigger, arg: u8, voice: Voice, text: []const u8 };

/// `chapter` is 1 based here, as the chapters are numbered on screen
fn line(chapter: u8, trigger: Trigger, arg: u8, voice: Voice, text: []const u8) BeatDef {
    return .{ .chapter = chapter - 1, .trigger = trigger, .arg = arg, .voice = voice, .text = text };
}

/// Every beat, in chapter order and, within a chapter, in the order lines triggered together play. Placeholder
/// lines (the handover's key beats) until the writing pass
const BEAT_DEFS = [_]BeatDef{
    line(1, .wave_over, 1, .ellie, "Dad? Dad, can you hear me?"),
    line(1, .wave_over, 1, .tom_radio, "Ellie! Where are you? Are you hurt?"),
    line(1, .wave_over, 1, .ellie, "I'm at St Bride's. I'm okay. I'm just waiting for you."),
    line(1, .chapter_cleared, 0, .tom_radio, "Stay where you are. I'm coming."),

    line(2, .wave_started, 1, .pa, "REMAIN IN YOUR HOMES. HELP IS ON THE -"),
    line(2, .wave_over, 2, .ellie, "Everyone here keeps asking me questions. I don't know the answers, Dad."),
    line(2, .wave_over, 2, .tom_radio, "What questions? Ellie, what's going on there?"),
    line(2, .wave_over, 2, .ellie, "...Just keep coming."),
    line(2, .wave_started, 3, .pa, "PRESSURE'S EIGHTY OVER -"),

    line(3, .wave_over, 1, .ellie, "Do you remember the pond? You threw bread for the ducks until they got sick of it."),
    line(3, .low_health, 0, .tom_radio, "Not now, love. Not now."),
    line(3, .wave_started, 3, .pa, "HE'S NOT RESPONDING. TRY THE OTHER ONE."),

    line(4, .wave_started, 1, .pa, "STAY BACK FROM THE LINE."),
    line(4, .wave_started, 1, .tom, "My daughter's in there!"),
    line(4, .wave_over, 3, .ellie, "They told me I should say goodbye. I'm not going to."),
    line(4, .wave_over, 3, .tom_radio, "Goodbye? Ellie - Ellie, are you hurt?"),
    line(4, .wave_started, 5, .pa, "FAMILY CAN STAY. FOR NOW."),

    line(5, .wave_over, 2, .ellie, "Something's changed. They're smiling at me. Don't stop now, Dad."),
    line(5, .chapter_cleared, 0, .tom, "I'm here. I'm here."),
};

/// The longest line, so every line fits two rows of its box (main also measures them against the font at init)
pub const MAX_LINE_CHARS = 90;
/// Each chapter's fired beats are a u64 bitmask
pub const MAX_BEATS_PER_CHAPTER = 64;

/// The beats and, by TextId, every line's text
pub const BEATS: [BEAT_DEFS.len]Beat = blk: {
    var beats: [BEAT_DEFS.len]Beat = undefined;
    for (BEAT_DEFS, 0..) |d, i| beats[i] = .{ .chapter = d.chapter, .trigger = d.trigger, .arg = d.arg, .voice = d.voice, .text = i };
    break :blk beats;
};
pub const TEXT: [BEAT_DEFS.len][]const u8 = blk: {
    var text: [BEAT_DEFS.len][]const u8 = undefined;
    for (BEAT_DEFS, 0..) |d, i| text[i] = d.text;
    break :blk text;
};

/// Where each chapter's beats start in BEATS (and the last chapter's end)
const CHAPTER_BEAT_START: [CHAPTERS.len + 1]u16 = blk: {
    var starts: [CHAPTERS.len + 1]u16 = undefined;
    var b: u16 = 0;
    for (0..CHAPTERS.len + 1) |c| {
        while (b < BEATS.len and BEATS[b].chapter < c) b += 1;
        starts[c] = b;
    }
    break :blk starts;
};

/// How long a line shows: long enough to read it, and for Ellie the static either side of her words
///
pub fn lineDuration(voice: Voice, text: TextId) f32 {
    const chars: f32 = @floatFromInt(TEXT[text].len);
    const radio: f32 = if (voice == .ellie) consts.RADIO_TUNE_TIME + consts.RADIO_DROP_TIME else 0;
    return consts.LINE_BASE_TIME + chars * consts.LINE_TIME_PER_CHAR + radio;
}

pub fn chapterBeats(chapter: u8) BeatRange {
    return .{ .start = CHAPTER_BEAT_START[chapter], .end = CHAPTER_BEAT_START[chapter + 1] };
}

comptime {
    @setEvalBranchQuota(20000);
    if (BEATS.len > std.math.maxInt(TextId)) @compileError("too many lines for a TextId");
    for (BEAT_DEFS, 0..) |d, i| {
        const where = std.fmt.comptimePrint("beat {d} (chapter {d})", .{ i, d.chapter + 1 });
        if (d.chapter >= CHAPTERS.len) @compileError(where ++ ": no such chapter");
        if (i > 0 and d.chapter < BEAT_DEFS[i - 1].chapter) @compileError(where ++ ": BEATS must be in chapter order, so each chapter's are one range");
        switch (d.trigger) {
            .wave_started, .wave_over => if (d.arg < 1 or d.arg > CHAPTERS[d.chapter].waveCount()) @compileError(where ++ ": its wave isn't one of the chapter's"),
            .chapter_cleared, .low_health => if (d.arg != 0) @compileError(where ++ ": only wave triggers take an arg"),
        }
        if (d.text.len == 0 or d.text.len > MAX_LINE_CHARS) @compileError(where ++ ": a line is 1 to MAX_LINE_CHARS long");
        if (d.voice == .pa) for (d.text) |ch| if (std.ascii.isLower(ch)) @compileError(where ++ ": the PA speaks in capitals");
    }
    for (0..CHAPTERS.len) |c| {
        const r = chapterBeats(c);
        if (r.end - r.start > MAX_BEATS_PER_CHAPTER) @compileError(std.fmt.comptimePrint("chapter {d} has more beats than its u64 mask", .{c + 1}));
    }
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

test "[story] each chapter's beats are its own, one range after another, and every line has its text" {
    var next: u16 = 0;
    for (0..CHAPTERS.len) |c| {
        const r = chapterBeats(@intCast(c));
        try std.testing.expect(r.start == next and r.end >= r.start);
        for (BEATS[r.start..r.end]) |b| try std.testing.expect(b.chapter == c and TEXT[b.text].len > 0);
        next = r.end;
    }
    try std.testing.expect(next == BEATS.len);
    try std.testing.expect(BEATS[chapterBeats(0).start].voice == .ellie); //The story opens with her calling
}
