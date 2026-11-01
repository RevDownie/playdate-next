/// Responsible for drawing the overlay UI
///
const std = @import("std");
const pd = @import("playdate.zig").api;
const build_options = @import("build_options");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const GameState = state.GameState;
const MapSide = @import("level_loader.zig").MapSide;
const screens = @import("screens.zig");
const story = @import("story.zig");

// Screen space text drawn over the world by the renderer: the HUD, the run end screen and the helpers they share.
// Text sits on solid boxes so it stays readable over a full horde and the dithered ground.

/// What the HUD needs from outside the simulation (main owns the save and the run phase)
///
pub const Hud = struct {
    best_score: u64, //On the current level: each level has its own
    level_name: []const u8, //The current level, so the run end screen can say whose best it is
    game_over: ?state.RunEnd = null, //Set while the run end screen is up
    chapter: ?u8 = null, //Story mode: the chapter being played (index into story.CHAPTERS)
};

/// System fonts, loaded once up front
///
pub const Fonts = struct {
    hud: *pd.LCDFont, //The always-on HUD: small, so it covers as little of the screen as it can
    small: *pd.LCDFont, //Labels
    big: *pd.LCDFont, //Banners and titles
};

pub fn loadFonts(playdate_api: *pd.PlaydateAPI) Fonts {
    const graphics = playdate_api.graphics.*;
    return .{
        .hud = graphics.loadFont.?("/System/Fonts/Roobert-10-Bold.pft", null) orelse @panic("loadFonts: Failed to load Roobert-10-Bold"),
        .small = graphics.loadFont.?("/System/Fonts/Roobert-11-Bold.pft", null) orelse @panic("loadFonts: Failed to load Roobert-11-Bold"),
        .big = graphics.loadFont.?("/System/Fonts/Roobert-20-Medium.pft", null) orelse @panic("loadFonts: Failed to load Roobert-20-Medium"),
    };
}

const Anchor = enum { left, centre, right };

/// `normal` is black text on white, `loud` is white on black for things the player must notice
const Style = enum { normal, loud };

const BOX_PAD_X = 3;
const BOX_PAD_Y = 1;

/// The A button as the system fonts draw it: a letter in a circle, as on the device. Use it whenever
/// text tells the player to press it
const BUTTON_A = "Ⓐ";

/// Text length as the SDK counts it for UTF-8: codepoints, not bytes (the HUD's own text is ASCII plus the button
/// glyphs)
///
fn textLen(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Draw `text` (UTF-8) on a solid box. `x` is the box's left edge, centre or right edge per `anchor`; `y` its top
///
fn drawBoxed(graphics: pd.playdate_graphics, font: *pd.LCDFont, text: []const u8, x: c_int, y: c_int, anchor: Anchor, style: Style) void {
    graphics.setFont.?(font);
    const w = graphics.getTextWidth.?(font, text.ptr, textLen(text), pd.kUTF8Encoding, 0);
    const h: c_int = graphics.getFontHeight.?(font);
    const left = switch (anchor) {
        .left => x,
        .centre => x - @divTrunc(w, 2),
        .right => x - w,
    };
    graphics.fillRect.?(left - BOX_PAD_X, y - BOX_PAD_Y, w + BOX_PAD_X * 2, h + BOX_PAD_Y * 2, if (style == .loud) pd.kColorBlack else pd.kColorWhite);
    _ = graphics.setDrawMode.?(if (style == .loud) pd.kDrawModeFillWhite else pd.kDrawModeCopy);
    _ = graphics.drawText.?(text.ptr, textLen(text), pd.kUTF8Encoding, left, y);
    _ = graphics.setDrawMode.?(pd.kDrawModeCopy);
}

/// Format into `buffer`, truncating rather than failing if it doesn't fit
///
fn format(buffer: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, fmt, args) catch buffer;
}

/// The always-on HUD, one short row at the top and bottom so it hides as little of the horde as it can: the wave,
/// the score (and combo), health and ammo, and the wave banners. The best to beat is on the run end screen; the
/// score turns loud once it is being beaten
///
pub fn drawHud(graphics: pd.playdate_graphics, fonts: Fonts, game: *const GameState, hud: Hud, width: c_int, height: c_int, reduce_flashing: bool) void {
    var buf: [48]u8 = undefined;
    const font = fonts.hud;
    const row_h: c_int = graphics.getFontHeight.?(font) + BOX_PAD_Y * 2 + 1;

    //Top left: the wave, or the countdown to the next one. In story, the chapter and how many waves it has
    const spawner = &game.spawner;
    //A chapter numbers its own waves from 1, whichever waves of the table it plays
    const wave_offset: u16 = if (hud.chapter) |ch| story.CHAPTERS[ch].first_wave -| 1 else 0;
    const wave_text = if (hud.chapter) |ch| if (story.CHAPTERS[ch].objective == .walk)
        format(&buf, "STORY Ch{d}  {s}", .{ ch + 1, story.CHAPTER_NAMES[ch] })
    else switch (spawner.phase) {
        .wave => if (spawner.isHolding())
            format(&buf, "STORY Ch{d}  Wave {d}/{d}  {d}s", .{ ch + 1, spawner.wave - wave_offset, story.CHAPTERS[ch].waveCount(), secondsLeft(spawner.hold - spawner.phase_time) })
        else
            format(&buf, "STORY Ch{d}  Wave {d}/{d}  Clear!", .{ ch + 1, spawner.wave - wave_offset, story.CHAPTERS[ch].waveCount() }),
        .lull => if (spawner.isLastWave())
            format(&buf, "STORY Ch{d}  Cleared", .{ch + 1})
        else
            format(&buf, "STORY Ch{d}  Wave {d}/{d} in {d}", .{ ch + 1, spawner.wave + 1 - wave_offset, story.CHAPTERS[ch].waveCount(), secondsLeft(spawner.timer) }),
    } else switch (spawner.phase) {
        .wave => if (spawner.isHolding())
            format(&buf, "Wave {d}  {d}s", .{ spawner.wave, secondsLeft(spawner.hold - spawner.phase_time) })
        else
            format(&buf, "Wave {d}  Clear!", .{spawner.wave}),
        .lull => format(&buf, "Wave {d} in {d}", .{ spawner.wave + 1, secondsLeft(spawner.timer) }),
    };
    drawBoxed(graphics, font, wave_text, BOX_PAD_X, BOX_PAD_Y, .left, .normal);
    drawWaveBanner(graphics, fonts, spawner, wave_offset, width);

    //Bottom left: health, next to the ammo so the two resources read together
    const bottom_y = height - row_h;
    drawBoxed(graphics, font, format(&buf, "HP {d}", .{game.player.health}), BOX_PAD_X, bottom_y, .left, if (game.player.health <= consts.PLAYER_LOW_HEALTH) .loud else .normal);

    //Top right, one row (survival only: story has no score): the score, loud once it beats the best, and to its left
    //the combo multiplying each kill's score, louder once it is worth protecting
    const right = width - BOX_PAD_X;
    if (hud.chapter == null) drawScore(graphics, font, game, hud, right);

    //Bottom right: ammo (health is bottom left). Full says so, as ammo drops are then left lying
    if (game.bullets.ammo == 0) {
        drawBoxed(graphics, font, "OUT OF AMMO", right, bottom_y, .right, .loud);
    } else if (game.bullets.ammo >= consts.MAX_AMMO) {
        drawBoxed(graphics, font, format(&buf, "Ammo {d} MAX", .{game.bullets.ammo}), right, bottom_y, .right, .normal);
    } else {
        drawBoxed(graphics, font, format(&buf, "Ammo {d}", .{game.bullets.ammo}), right, bottom_y, .right, .normal);
    }

    if (game.invincible) drawBoxed(graphics, font, "INVINCIBLE", BOX_PAD_X, BOX_PAD_Y + row_h, .left, .loud); //Debug, so screenshots don't mislead

    //Story: the line being spoken, between the top and bottom rows
    if (hud.chapter != null) {
        if (game.story.lines.front()) |line| drawLine(graphics, fonts, line, width, row_h + LINE_GAP, bottom_y - LINE_GAP, reduce_flashing);
    }
}

const LINE_GAP = 3; //Between a line and the HUD rows
const LINE_MARGIN = 6; //Either side of Ellie's box
const LINE_PAD = 4; //Inside a line's box, around its text
const RADIO_BORDER = 5; //The static round Ellie's box
const TOM_TEXT_W = 300; //Tom's lines wrap at this, centred
const PA_TEXT_W = 340;
const WALKIE_W = 11;
const WALKIE_H = 24;

/// Static on the walkie-talkie: noise patterns cycled at RADIO_STATIC_FPS (frozen with Reduce Flashing on)
const PATTERN_STATIC = [_]pd.LCDPattern{
    .{ 0x5A, 0xA7, 0x3C, 0xD2, 0x69, 0x1E, 0xB4, 0x8B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    .{ 0xC3, 0x2D, 0x96, 0x71, 0xE8, 0x4B, 0x1D, 0xA6, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    .{ 0x9C, 0x63, 0xA9, 0x56, 0x3A, 0xC5, 0x6E, 0x91, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    .{ 0x27, 0xD8, 0x4E, 0xB1, 0x8D, 0x72, 0xE4, 0x1B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
};
/// The edge behind Tom's lines: white on every other pixel, so his words sit on a soft patch over the world rather
/// than in a hard box like the HUD's
const PATTERN_SOFT_EDGE: pd.LCDPattern = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 };
const SOFT_EDGE = 3;

/// The widest a voice's text is allowed before it wraps, on a screen `width` wide
///
pub fn lineTextWidth(voice: story.Voice, width: c_int) c_int {
    return switch (voice) {
        .ellie => width - 2 * (LINE_MARGIN + RADIO_BORDER) - 3 * LINE_PAD - WALKIE_W,
        .tom, .tom_radio => TOM_TEXT_W,
        .pa => PA_TEXT_W,
    };
}

/// Whether a line fits the two rows its box has room for (main checks every line once at init, Debug only)
///
pub fn lineFits(graphics: pd.playdate_graphics, fonts: Fonts, voice: story.Voice, text: []const u8, width: c_int) bool {
    const h = graphics.getTextHeightForMaxWidth.?(fonts.hud, text.ptr, textLen(text), lineTextWidth(voice, width), pd.kUTF8Encoding, pd.kWrapWord, 0, 0);
    return h <= 2 * graphics.getFontHeight.?(fonts.hud);
}

/// One line of dialogue, drawn in its voice (see story.Voice). `top` and `bottom` are the free space between the
/// HUD rows
///
fn drawLine(graphics: pd.playdate_graphics, fonts: Fonts, line: state.Line, width: c_int, top: c_int, bottom: c_int, reduce_flashing: bool) void {
    const text = story.TEXT[line.text];
    const len = textLen(text);
    const font = fonts.hud; //The HUD's small font, so two rows hold any line and Ellie's box stays short
    graphics.setFont.?(font);
    const max_w = lineTextWidth(line.voice, width);
    const text_h = graphics.getTextHeightForMaxWidth.?(font, text.ptr, len, max_w, pd.kUTF8Encoding, pd.kWrapWord, 0, 0);
    const cx = @divTrunc(width, 2);
    switch (line.voice) {
        //The walkie-talkie: a box at the top edged in static, the handset at its left. The static fills it as she
        //comes through and again as she drops out, and the handset's light blinks while she speaks
        .ellie => {
            const h = @max(text_h, WALKIE_H) + 2 * (RADIO_BORDER + LINE_PAD);
            const x = LINE_MARGIN;
            const w = width - 2 * LINE_MARGIN;
            const frame: u32 = if (reduce_flashing) 0 else @intFromFloat(line.time * consts.RADIO_STATIC_FPS);
            graphics.fillRect.?(x, top, w, h, @intFromPtr(&PATTERN_STATIC[frame % PATTERN_STATIC.len]));
            const duration = story.lineDuration(line.voice, line.text);
            const speaking = line.time >= consts.RADIO_TUNE_TIME and line.time < duration - consts.RADIO_DROP_TIME;
            if (speaking or reduce_flashing) {
                graphics.fillRect.?(x + RADIO_BORDER, top + RADIO_BORDER, w - 2 * RADIO_BORDER, h - 2 * RADIO_BORDER, pd.kColorWhite);
                graphics.drawRect.?(x + RADIO_BORDER, top + RADIO_BORDER, w - 2 * RADIO_BORDER, h - 2 * RADIO_BORDER, pd.kColorBlack);
                const text_x = x + RADIO_BORDER + 2 * LINE_PAD + WALKIE_W;
                _ = graphics.drawTextInRect.?(text.ptr, len, pd.kUTF8Encoding, text_x, top + RADIO_BORDER + LINE_PAD, max_w, text_h, pd.kWrapWord, pd.kAlignTextLeft);
            }
            const blink = speaking and (reduce_flashing or @as(u32, @intFromFloat(line.time * 4)) % 2 == 0);
            drawWalkie(graphics, x + RADIO_BORDER + LINE_PAD, top + RADIO_BORDER + LINE_PAD, blink);
        },
        //Tom: his words over the world at the bottom. Answering Ellie he holds the handset, its light on as he
        //transmits
        .tom, .tom_radio => {
            const w = @min(graphics.getTextWidth.?(font, text.ptr, len, pd.kUTF8Encoding, 0) + 1, max_w);
            const y = bottom - text_h;
            const radio = line.voice == .tom_radio;
            const icon_w: c_int = if (radio) WALKIE_W + LINE_PAD else 0;
            const icon_h: c_int = if (radio) WALKIE_H else 0;
            const left = cx - @divTrunc(w + icon_w, 2);
            const block_h = @max(text_h, icon_h);
            const back_x = left - LINE_PAD;
            const back_y = bottom - block_h - LINE_PAD;
            const back_w = w + icon_w + 2 * LINE_PAD;
            const back_h = block_h + LINE_PAD;
            graphics.fillRect.?(back_x - SOFT_EDGE, back_y - SOFT_EDGE, back_w + 2 * SOFT_EDGE, back_h + SOFT_EDGE, @intFromPtr(&PATTERN_SOFT_EDGE));
            graphics.fillRect.?(back_x, back_y, back_w, back_h, pd.kColorWhite);
            if (radio) drawWalkie(graphics, left, bottom - WALKIE_H, true);
            _ = graphics.drawTextInRect.?(text.ptr, len, pd.kUTF8Encoding, left + icon_w, y, w, text_h, pd.kWrapWord, pd.kAlignTextCenter);
        },
        //Loudspeakers: a hard black box, white capitals
        .pa => {
            const w = @min(graphics.getTextWidth.?(font, text.ptr, len, pd.kUTF8Encoding, 0) + 1, max_w);
            graphics.fillRect.?(cx - @divTrunc(w, 2) - 2 * LINE_PAD, top, w + 4 * LINE_PAD, text_h + 2 * LINE_PAD, pd.kColorBlack);
            _ = graphics.setDrawMode.?(pd.kDrawModeFillWhite);
            _ = graphics.drawTextInRect.?(text.ptr, len, pd.kUTF8Encoding, cx - @divTrunc(w, 2), top + LINE_PAD, w, text_h, pd.kWrapWord, pd.kAlignTextCenter);
            _ = graphics.setDrawMode.?(pd.kDrawModeCopy);
        },
    }
}

/// The walkie-talkie handset, WALKIE_W x WALKIE_H with its top left at `x`, `y`: an antenna, the body, the speaker
/// grille and the light. Edged in white so it reads over the static
///
fn drawWalkie(graphics: pd.playdate_graphics, x: c_int, y: c_int, light: bool) void {
    graphics.fillRect.?(x + 1, y - 1, 4, 8, pd.kColorWhite);
    graphics.fillRect.?(x - 1, y + 5, WALKIE_W + 2, WALKIE_H - 4, pd.kColorWhite);
    graphics.fillRect.?(x + 2, y, 2, 7, pd.kColorBlack);
    graphics.fillRect.?(x, y + 6, WALKIE_W, WALKIE_H - 6, pd.kColorBlack);
    for (0..3) |k| graphics.fillRect.?(x + 2, y + 14 + @as(c_int, @intCast(k)) * 3, WALKIE_W - 4, 1, pd.kColorWhite);
    if (light) graphics.fillRect.?(x + WALKIE_W - 4, y + 8, 2, 2, pd.kColorWhite);
}

const FPS_W = 15; //The SDK's counter at two digits
const FPS_H = 12;

/// The SDK's FPS counter, if the build has it (`zig build -Dfps=false` leaves it out). Bottom centre, between health
/// and ammo, where nothing else in the HUD goes, so leaving it out moves nothing. Drawn over the run end screen too
///
pub fn drawFps(sys: pd.playdate_sys, width: c_int, height: c_int) void {
    if (!build_options.fps) return;
    sys.drawFPS.?(@divTrunc(width - FPS_W, 2), height - FPS_H);
}

/// A combo message in the world, centred on `x` with its bottom at `y`
///
pub fn drawPopup(graphics: pd.playdate_graphics, fonts: Fonts, kind: state.PopupKind, value: u32, x: c_int, y: c_int) void {
    var buf: [24]u8 = undefined;
    switch (kind) {
        .combo => drawBoxed(graphics, fonts.hud, format(&buf, "x{d}", .{value}), x, y - graphics.getFontHeight.?(fonts.hud), .centre, .normal),
        .milestone => drawBoxed(graphics, fonts.small, format(&buf, "COMBO x{d}!", .{value}), x, y - graphics.getFontHeight.?(fonts.small), .centre, .loud),
        .lost => drawBoxed(graphics, fonts.small, "COMBO LOST", x, y - graphics.getFontHeight.?(fonts.small), .centre, .loud),
    }
}

const MARKER_RADIUS = 9;
const MARKER_RADIUS_LARGE = 12;

/// An off screen drop: a black disc with a white icon of what it is (a cross for health, a bullet for ammo; a
/// bigger disc for a large one) and an arrow pointing the way to it. `dir` is unit length, screen space
///
pub fn drawDropMarker(graphics: pd.playdate_graphics, kind: state.DropKind, x: c_int, y: c_int, dir: @Vector(2, f32)) void {
    const r: c_int = if (kind.isLarge()) MARKER_RADIUS_LARGE else MARKER_RADIUS;
    graphics.fillEllipse.?(x - r - 1, y - r - 1, 2 * r + 2, 2 * r + 2, 0, 360, pd.kColorWhite);
    graphics.fillEllipse.?(x - r, y - r, 2 * r, 2 * r, 0, 360, pd.kColorBlack);
    const s: c_int = if (kind.isLarge()) 2 else 1; //Icon scale
    if (kind.isAmmo()) {
        //A bullet standing up: a pointed tip on a casing
        graphics.fillRect.?(x - 2 * s, y - 2 * s, 4 * s, 6 * s, pd.kColorWhite);
        graphics.fillTriangle.?(x - 2 * s, y - 2 * s, x + 2 * s, y - 2 * s, x, y - 5 * s, pd.kColorWhite);
    } else {
        graphics.fillRect.?(x - s, y - 4 * s, 2 * s + 1, 8 * s + 1, pd.kColorWhite);
        graphics.fillRect.?(x - 4 * s, y - s, 8 * s + 1, 2 * s + 1, pd.kColorWhite);
    }
    //Arrow just outside the disc
    const f: c_int = r + 2;
    const b: c_int = r + 8;
    const tip = @Vector(2, f32){ @floatFromInt(x), @floatFromInt(y) } + dir * @as(@Vector(2, f32), @splat(@floatFromInt(b)));
    const base = @Vector(2, f32){ @floatFromInt(x), @floatFromInt(y) } + dir * @as(@Vector(2, f32), @splat(@floatFromInt(f)));
    const side = @Vector(2, f32){ -dir[1], dir[0] } * @as(@Vector(2, f32), @splat(4));
    const p1: @Vector(2, c_int) = @intFromFloat(@round(base + side));
    const p2: @Vector(2, c_int) = @intFromFloat(@round(base - side));
    const p3: @Vector(2, c_int) = @intFromFloat(@round(tip));
    graphics.fillTriangle.?(p1[0], p1[1], p2[0], p2[1], p3[0], p3[1], pd.kColorBlack);
}

const BANNER_Y = 140; //Below the player (in the middle of the screen), clear of the HUD at the top and bottom

/// Whole seconds left on a countdown, rounded up so it never shows 0 while still counting
///
fn secondsLeft(timer: f32) u32 {
    if (!(timer > 0) or timer > 999) return 0;
    return @as(u32, @intFromFloat(timer)) + 1;
}

/// The beats of a wave: "WAVE N", how long it keeps coming and from where as it starts, "CLEAR THE REST" when the
/// spawning stops, and "WAVE N CLEARED" when it is cleared (not when it ran out of time: then the next
/// wave starts straight away instead)
///
fn drawWaveBanner(graphics: pd.playdate_graphics, fonts: Fonts, spawner: *const state.Spawner, wave_offset: u16, width: c_int) void {
    var buf: [48]u8 = undefined;
    const cx = @divTrunc(width, 2);
    const big_h: c_int = graphics.getFontHeight.?(fonts.big) + BOX_PAD_Y * 2 + 2;
    switch (spawner.phase) {
        .wave => if (spawner.phase_time < consts.WAVE_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, format(&buf, "WAVE {d}", .{spawner.wave - wave_offset}), cx, BANNER_Y, .centre, .loud);
            var sides_buf: [40]u8 = undefined;
            drawBoxed(graphics, fonts.small, format(&buf, "Incoming for {d}s {s}", .{ secondsLeft(spawner.hold) - 1, sidesText(&sides_buf, spawner.sides) }), cx, BANNER_Y + big_h, .centre, .normal);
        } else if (!spawner.isHolding() and spawner.phase_time < spawner.hold + consts.WAVE_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, "CLEAR THE REST", cx, BANNER_Y, .centre, .loud);
        },
        .lull => if (spawner.cleared and spawner.phase_time < consts.WAVE_CLEARED_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, format(&buf, "WAVE {d} CLEARED", .{spawner.wave - wave_offset}), cx, BANNER_Y, .centre, .normal);
            drawBoxed(graphics, fonts.small, if (spawner.isLastWave()) "Chapter clear" else "Grab what you can", cx, BANNER_Y + big_h, .centre, .normal);
        },
    }
}

/// "from the north", "from the north and east", ... "from all sides"
///
fn sidesText(buffer: []u8, sides: u8) []const u8 {
    if (@popCount(sides) == std.enums.values(MapSide).len) return "from all sides";
    var len: usize = 0;
    var written: u8 = 0;
    const total = @popCount(sides);
    for (std.enums.values(MapSide)) |side| {
        if (sides & (@as(u8, 1) << @intCast(@backingInt(side))) == 0) continue;
        const joiner = if (written == 0) "from the " else if (written + 1 == total) " and " else ", ";
        len += (std.fmt.bufPrint(buffer[len..], "{s}{s}", .{ joiner, @tagName(side) }) catch return buffer[0..len]).len;
        written += 1;
    }
    return buffer[0..len];
}

/// Dims the frozen last frame behind the run end screen: black on every other pixel, the rest left as it was
const PATTERN_DIM: pd.LCDPattern = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 };

const PANEL_W = 260;
const PANEL_LINES = 6; //Below the title, including the "go again" prompt
const STORY_PANEL_LINES = 4;

fn drawScore(graphics: pd.playdate_graphics, font: *pd.LCDFont, game: *const GameState, hud: Hud, right: c_int) void {
    var buf: [24]u8 = undefined;
    const beating_best = hud.best_score > 0 and game.player.score > hud.best_score;
    const score_text = format(&buf, "{d}", .{game.player.score});
    drawBoxed(graphics, font, score_text, right, BOX_PAD_Y, .right, if (beating_best) .loud else .normal);
    const combo = game.player.kill_streak;
    if (combo >= consts.COMBO_SHOW_FROM) {
        const combo_right = right - graphics.getTextWidth.?(font, score_text.ptr, textLen(score_text), pd.kUTF8Encoding, 0) - BOX_PAD_X * 2 - 2;
        var combo_buf: [16]u8 = undefined;
        drawBoxed(graphics, font, format(&combo_buf, "x{d}", .{combo}), combo_right, BOX_PAD_Y, .right, if (combo >= consts.COMBO_LOST_MIN) .loud else .normal);
    }
}

/// The run end screen over the frozen last frame: how the run went and how to go again. Survival shows the score
/// and the best to beat; story (no score) the chapter and how far into it the player got
///
pub fn drawGameOver(graphics: pd.playdate_graphics, fonts: Fonts, game: *const GameState, hud: Hud, over: state.RunEnd, width: c_int, height: c_int) void {
    var buf: [48]u8 = undefined;
    graphics.fillRect.?(0, 0, width, height, @intFromPtr(&PATTERN_DIM));

    //Sized from the fonts so the lines always fit
    const small_h: c_int = graphics.getFontHeight.?(fonts.small) + 4;
    const big_h: c_int = graphics.getFontHeight.?(fonts.big) + 6;
    const lines: c_int = if (hud.chapter != null) STORY_PANEL_LINES else PANEL_LINES;
    const panel_h = 10 + big_h + lines * small_h + 4 + 10;
    const left = @divTrunc(width - PANEL_W, 2);
    const top = @divTrunc(height - panel_h, 2);
    graphics.fillRect.?(left, top, PANEL_W, panel_h, pd.kColorWhite);
    graphics.drawRect.?(left + 2, top + 2, PANEL_W - 4, panel_h - 4, pd.kColorBlack);

    const cx = @divTrunc(width, 2);
    var y = top + 10;
    drawBoxed(graphics, fonts.big, "OVERRUN", cx, y, .centre, .normal);
    y += big_h;

    const p = game.player;
    const secs: u32 = @intFromFloat(game.run_time);
    if (hud.chapter) |ch| {
        const c = story.CHAPTERS[ch];
        drawBoxed(graphics, fonts.small, format(&buf, "Ch{d}  {s}", .{ ch + 1, story.CHAPTER_NAMES[ch] }), cx, y, .centre, .normal);
        y += small_h;
        drawBoxed(graphics, fonts.small, format(&buf, "Wave {d}/{d}   Time {d}:{d:0>2}", .{ game.spawner.wave -| (c.first_wave -| 1), c.waveCount(), secs / 60, secs % 60 }), cx, y, .centre, .normal);
        y += small_h;
        drawBoxed(graphics, fonts.small, format(&buf, "Kills {d}", .{p.kills}), cx, y, .centre, .normal);
        y += small_h + 4;
        if (over.canRestart()) drawBoxed(graphics, fonts.small, "Press " ++ BUTTON_A ++ " to retry", cx, y, .centre, .loud);
        return;
    }
    drawBoxed(graphics, fonts.small, format(&buf, "Wave {d}   Time {d}:{d:0>2}", .{ game.spawner.wave, secs / 60, secs % 60 }), cx, y, .centre, .normal);
    y += small_h;
    drawBoxed(graphics, fonts.small, format(&buf, "Kills {d}", .{p.kills}), cx, y, .centre, .normal);
    y += small_h;
    drawBoxed(graphics, fonts.small, format(&buf, "Best combo x{d}", .{p.best_streak}), cx, y, .centre, .normal);
    y += small_h;
    drawBoxed(graphics, fonts.small, format(&buf, "Score {d}", .{p.score}), cx, y, .centre, .normal);
    y += small_h;
    if (over.new_best) {
        drawBoxed(graphics, fonts.small, "NEW BEST!", cx, y, .centre, .loud);
    } else {
        drawBoxed(graphics, fonts.small, format(&buf, "Best on {s} {d}", .{ hud.level_name, hud.best_score }), cx, y, .centre, .normal);
    }
    y += small_h + 4;
    if (over.canRestart()) drawBoxed(graphics, fonts.small, "Press " ++ BUTTON_A ++ " to go again", cx, y, .centre, .loud);
}

const TITLE_Y = 50;

/// The title screen on a blank screen: the game's name and the modes, the chosen one loud
///
pub fn drawTitle(graphics: pd.playdate_graphics, fonts: Fonts, title: screens.Title, width: c_int) void {
    const cx = @divTrunc(width, 2);
    const big_h: c_int = graphics.getFontHeight.?(fonts.big) + 6;
    const small_h: c_int = graphics.getFontHeight.?(fonts.small) + 6;
    drawBoxed(graphics, fonts.big, "UNTIL THERE WERE NONE", cx, TITLE_Y, .centre, .normal);
    var y = TITLE_Y + big_h + 24;
    for ([_]screens.Mode{ .story, .survival }, [_][]const u8{ "Story", "Survival" }) |mode, label| {
        drawBoxed(graphics, fonts.small, label, cx, y, .centre, if (mode == title.choice) .loud else .normal);
        y += small_h;
    }
    drawBoxed(graphics, fonts.hud, "Up/Down to choose, " ++ BUTTON_A ++ " to start", cx, y + 24, .centre, .normal);
}

/// A story card on a blank screen: plain text between chapters
///
const CARD_TOP = 40;
const CARD_TEXT_MARGIN = 40; //Each side of the intro text, which wraps
const CARD_TEXT_LINES = 3;

/// A story card on a blank screen. Intro: the chapter's name and its intro line. Outro: how long the chapter took
/// over every attempt. The end: the same for the whole story
///
pub fn drawStoryCard(graphics: pd.playdate_graphics, fonts: Fonts, card: screens.StoryCard, width: c_int, height: c_int) void {
    var buf: [48]u8 = undefined;
    var sub_buf: [48]u8 = undefined;
    const cx = @divTrunc(width, 2);
    const big_h: c_int = graphics.getFontHeight.?(fonts.big) + 6;
    const small_h: c_int = graphics.getFontHeight.?(fonts.small) + 6;
    var y: c_int = CARD_TOP;
    switch (card.kind) {
        .intro => {
            drawBoxed(graphics, fonts.small, format(&sub_buf, "Chapter {d} of {d}", .{ card.chapter + 1, story.CHAPTERS.len }), cx, y, .centre, .normal);
            y += small_h;
            drawBoxed(graphics, fonts.big, story.CHAPTER_NAMES[card.chapter], cx, y, .centre, .normal);
            y += big_h + 8;
            const intro = story.CHAPTER_INTROS[card.chapter];
            graphics.setFont.?(fonts.small);
            graphics.drawTextInRect.?(intro.ptr, textLen(intro), pd.kUTF8Encoding, CARD_TEXT_MARGIN, y, width - CARD_TEXT_MARGIN * 2, small_h * CARD_TEXT_LINES, pd.kWrapWord, pd.kAlignTextCenter);
        },
        .outro => {
            drawBoxed(graphics, fonts.small, format(&sub_buf, "Chapter {d} complete", .{card.chapter + 1}), cx, y, .centre, .normal);
            y += small_h;
            drawBoxed(graphics, fonts.big, story.CHAPTER_NAMES[card.chapter], cx, y, .centre, .normal);
            y += big_h + 8;
            drawBoxed(graphics, fonts.small, format(&buf, "Time {d}:{d:0>2}", .{ card.secs / 60, card.secs % 60 }), cx, y, .centre, .normal);
        },
        .the_end => {
            y += small_h;
            drawBoxed(graphics, fonts.big, "The End", cx, y, .centre, .normal);
            y += big_h + 8;
            drawBoxed(graphics, fonts.small, format(&buf, "Story time {d}:{d:0>2}", .{ card.secs / 60, card.secs % 60 }), cx, y, .centre, .normal);
        },
    }
    if (card.canContinue()) drawBoxed(graphics, fonts.small, "Press " ++ BUTTON_A ++ " to continue", cx, height - CARD_TOP - small_h, .centre, .loud);
}
