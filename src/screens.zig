const std = @import("std");
const consts = @import("tweak_constants.zig");
const Input = @import("game_state.zig").Input;

// The screens outside play (the run end screen is `game_state.RunEnd`, as the renderer draws the world under it).
// Each only counts its time and reads the input; main changes screen at a frame boundary.

pub const Mode = enum(u8) { story, survival };

/// The title screen: pick a mode with up/down, A (or B) to start it
///
pub const Title = struct {
    choice: Mode = .story,

    /// Move the choice. The mode to start once fire is pressed
    ///
    pub fn update(self: *Title, input: Input) ?Mode {
        if (input.up_pressed) self.choice = .story;
        if (input.down_pressed) self.choice = .survival;
        return if (input.fire_pressed) self.choice else null;
    }
};

/// `intro` before a chapter, `outro` once it is complete, `the_end` after the last
pub const CardKind = enum(u8) { intro, outro, the_end };

/// A story card: plain text between chapters, A to continue once CARD_INPUT_DELAY is up so a player still
/// pressing fire doesn't skip it
///
pub const StoryCard = struct {
    kind: CardKind,
    chapter: u8, //Index into story.CHAPTERS
    time: f32 = 0,

    pub fn canContinue(self: StoryCard) bool {
        return self.time >= consts.CARD_INPUT_DELAY;
    }

    /// Count the time on the card. True once the player moves on
    ///
    pub fn update(self: *StoryCard, input: Input, dt: f32) bool {
        self.time += dt;
        return self.canContinue() and input.fire_pressed;
    }
};

test "[screens] the title moves its choice with up and down and starts it on fire" {
    var title = Title{};
    try std.testing.expect(title.update(.{}) == null and title.choice == .story);
    try std.testing.expect(title.update(.{ .down_pressed = true }) == null and title.choice == .survival);
    try std.testing.expect(title.update(.{ .down_pressed = true }) == null and title.choice == .survival);
    try std.testing.expect(title.update(.{ .fire_pressed = true }) == .survival);
    try std.testing.expect(title.update(.{ .up_pressed = true, .fire_pressed = true }) == .story);
}

test "[screens] a story card ignores fire until its delay is up" {
    var card = StoryCard{ .kind = .intro, .chapter = 0 };
    const fire = Input{ .fire_pressed = true };
    try std.testing.expect(!card.update(fire, consts.CARD_INPUT_DELAY / 2));
    try std.testing.expect(!card.update(.{}, consts.CARD_INPUT_DELAY));
    try std.testing.expect(card.update(fire, consts.TARGET_FRAME_DT));
}
