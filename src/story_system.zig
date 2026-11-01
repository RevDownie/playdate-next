/// Plays a story chapter's beats: matches this frame's story events against them and queues their lines
///
const std = @import("std");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const story = @import("story.zig");

/// The front line counts its time and goes once it has been up for `story.lineDuration`. A wave starting has Tom
/// call where it comes from, first, as it is what the player needs now. Then each of the chapter's `beats` (its
/// slice of story.BEATS) that hasn't fired this chapter fires if one of `events` is its trigger, queueing its line.
/// Beats are checked in table order, so lines set off together play in that order
///
pub fn update(st: *state.Story, beats: []const story.Beat, events: []const state.StoryEvent, dt: f32) void {
    std.debug.assert(beats.len <= story.MAX_BEATS_PER_CHAPTER);
    const lines = &st.lines;
    if (lines.len > 0) {
        lines.items[0].time += dt;
        if (lines.items[0].time >= story.lineDuration(lines.items[0].voice, lines.items[0].text)) lines.popFront();
    }

    if (events.len == 0) return;
    for (events) |e| {
        if (e.trigger == .wave_started) lines.push(.{ .text = story.warningText(e.wave -| st.wave_offset, e.sides), .voice = .tom });
    }
    for (beats, 0..) |beat, i| {
        const bit = @as(u64, 1) << @intCast(i);
        if (st.fired & bit != 0) continue;
        for (events) |e| {
            if (!matches(beat, e, st.wave_offset)) continue;
            st.fired |= bit;
            lines.push(.{ .text = beat.text, .voice = beat.voice, .beat = @intCast(i) });
            break;
        }
    }
}

fn matches(beat: story.Beat, event: state.StoryEvent, wave_offset: u16) bool {
    if (beat.trigger != event.trigger) return false;
    return switch (beat.trigger) {
        .wave_started, .wave_over => event.wave -| wave_offset == beat.arg,
        .chapter_cleared, .low_health => true,
    };
}

const TEST_BEATS = [_]story.Beat{
    .{ .chapter = 0, .trigger = .wave_over, .arg = 1, .voice = .ellie, .text = 0 },
    .{ .chapter = 0, .trigger = .wave_over, .arg = 1, .voice = .tom_radio, .text = 1 },
    .{ .chapter = 0, .trigger = .wave_started, .arg = 2, .voice = .pa, .text = 2 },
    .{ .chapter = 0, .trigger = .low_health, .arg = 0, .voice = .tom, .text = 3 },
};

test "[story_system] a beat fires once, on its own trigger and wave, and lines set off together play in table order" {
    var st = state.Story{ .active = true, .wave_offset = 3 }; //The chapter's wave 1 is the table's wave 4
    update(&st, &TEST_BEATS, &.{.{ .trigger = .wave_over, .wave = 1 }}, 0.02); //Not this chapter's wave 1
    try std.testing.expect(st.lines.len == 0);
    update(&st, &TEST_BEATS, &.{.{ .trigger = .wave_started, .wave = 4 }}, 0.02); //Wrong trigger: only Tom's warning
    try std.testing.expect(st.lines.len == 1 and st.lines.front().?.beat == null and st.fired == 0);
    st.lines = .{};

    update(&st, &TEST_BEATS, &.{.{ .trigger = .wave_over, .wave = 4 }}, 0.02);
    try std.testing.expect(st.lines.len == 2 and st.fired == 0b11);
    try std.testing.expect(st.lines.items[0].voice == .ellie and st.lines.items[1].voice == .tom_radio);
    update(&st, &TEST_BEATS, &.{.{ .trigger = .wave_over, .wave = 4 }}, 0.02); //Again: already fired
    try std.testing.expect(st.lines.len == 2);
}

test "[story_system] each line shows for its duration, then the next" {
    var st = state.Story{ .active = true };
    update(&st, &TEST_BEATS, &.{ .{ .trigger = .low_health }, .{ .trigger = .wave_started, .wave = 2 } }, 0);
    try std.testing.expect(st.lines.len == 3 and st.lines.front().?.text == story.warningText(2, 0)); //The warning first
    st.lines.popFront();
    try std.testing.expect(st.lines.front().?.voice == .pa); //Then table order, not event order
    const first = story.lineDuration(st.lines.items[0].voice, st.lines.items[0].text);
    update(&st, &TEST_BEATS, &.{}, first - 0.05);
    try std.testing.expect(st.lines.len == 2);
    update(&st, &TEST_BEATS, &.{}, 0.1);
    try std.testing.expect(st.lines.len == 1 and st.lines.front().?.voice == .tom and st.lines.front().?.time == 0);
    update(&st, &TEST_BEATS, &.{}, story.lineDuration(st.lines.items[0].voice, st.lines.items[0].text));
    try std.testing.expect(st.lines.len == 0);
}

test "[story_system] a full queue drops its oldest line, and Ellie's lines allow for the static" {
    var lines = state.Lines{};
    for (0..state.Lines.capacity + 1) |i| lines.push(.{ .text = @intCast(i), .voice = .tom });
    try std.testing.expect(lines.len == state.Lines.capacity and lines.front().?.text == 1);
    try std.testing.expect(lines.items[lines.len - 1].text == state.Lines.capacity);

    const tom = story.lineDuration(.tom, 0);
    const ellie = story.lineDuration(.ellie, 0);
    try std.testing.expectApproxEqAbs(ellie - tom, consts.RADIO_TUNE_TIME + consts.RADIO_DROP_TIME, 0.001);
}

test "[story_system] a wave starting has Tom call where it comes from, ahead of its beats" {
    var st = state.Story{ .active = true, .wave_offset = 3 };
    update(&st, &TEST_BEATS, &.{.{ .trigger = .wave_started, .wave = 5, .sides = 0b0110 }}, 0); //The chapter's wave 2
    try std.testing.expect(st.lines.len == 2 and st.lines.items[1].voice == .pa);
    const warning = st.lines.front().?;
    try std.testing.expect(warning.voice == .tom and warning.beat == null);
    try std.testing.expectEqualStrings("Here they come again. From the east and south.", story.TEXT[warning.text]);
    try std.testing.expect(st.fired == 0b100 and st.heard() == 0); //The PA beat is queued, so not heard yet; the warning isn't a beat
}

test "[story_system] survival's endless waves never overflow the wave match" {
    var st = state.Story{ .active = true, .wave_offset = 0 };
    update(&st, &TEST_BEATS, &.{.{ .trigger = .wave_over, .wave = 300 }}, 0.02);
    try std.testing.expect(st.lines.len == 0);
}
