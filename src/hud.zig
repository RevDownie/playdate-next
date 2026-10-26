const std = @import("std");
const pd = @import("playdate.zig").api;
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const GameState = state.GameState;
const MapSide = @import("level_loader.zig").MapSide;

// Screen space text drawn over the world by the renderer: the HUD, the run end screen and the helpers they share.
// Text sits on solid boxes so it stays readable over a full horde and the dithered ground.

/// What the HUD needs from outside the simulation (main owns the save and the run phase)
///
pub const Hud = struct {
    best_score: u64,
    game_over: ?GameOver = null, //Set while the run end screen is up

    pub const GameOver = struct {
        new_best: bool, //The run that ended beat the saved best
        can_restart: bool, //Past GAME_OVER_INPUT_DELAY, so A/B starts the next run
    };
};

/// System fonts, loaded once up front
///
pub const Fonts = struct {
    small: *pd.LCDFont, //HUD and labels
    big: *pd.LCDFont, //Banners and titles
};

pub fn loadFonts(playdate_api: *pd.PlaydateAPI) Fonts {
    const graphics = playdate_api.graphics.*;
    return .{
        .small = graphics.loadFont.?("/System/Fonts/Roobert-11-Bold.pft", null) orelse @panic("loadFonts: Failed to load Roobert-11-Bold"),
        .big = graphics.loadFont.?("/System/Fonts/Roobert-20-Medium.pft", null) orelse @panic("loadFonts: Failed to load Roobert-20-Medium"),
    };
}

pub const Anchor = enum { left, centre, right };

/// `normal` is black text on white, `loud` is white on black for things the player must notice
pub const Style = enum { normal, loud };

const BOX_PAD_X = 3;
const BOX_PAD_Y = 1;

/// Draw `text` on a solid box. `x` is the box's left edge, centre or right edge per `anchor`; `y` its top
///
pub fn drawBoxed(graphics: pd.playdate_graphics, font: *pd.LCDFont, text: []const u8, x: c_int, y: c_int, anchor: Anchor, style: Style) void {
    graphics.setFont.?(font);
    const w = graphics.getTextWidth.?(font, text.ptr, text.len, pd.kASCIIEncoding, 0);
    const h: c_int = graphics.getFontHeight.?(font);
    const left = switch (anchor) {
        .left => x,
        .centre => x - @divTrunc(w, 2),
        .right => x - w,
    };
    graphics.fillRect.?(left - BOX_PAD_X, y - BOX_PAD_Y, w + BOX_PAD_X * 2, h + BOX_PAD_Y * 2, if (style == .loud) pd.kColorBlack else pd.kColorWhite);
    _ = graphics.setDrawMode.?(if (style == .loud) pd.kDrawModeFillWhite else pd.kDrawModeCopy);
    _ = graphics.drawText.?(text.ptr, text.len, pd.kASCIIEncoding, left, y);
    _ = graphics.setDrawMode.?(pd.kDrawModeCopy);
}

/// Format into `buffer`, truncating rather than failing if it doesn't fit
///
pub fn format(buffer: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, fmt, args) catch buffer;
}

/// The always-on HUD: the wave, health and ammo, score and the best to beat, and the wave banners
///
pub fn drawHud(graphics: pd.playdate_graphics, fonts: Fonts, game: *const GameState, hud: Hud, width: c_int, height: c_int) void {
    var buf: [48]u8 = undefined;
    const small_h: c_int = graphics.getFontHeight.?(fonts.small) + BOX_PAD_Y * 2 + 1;

    //Top left (after the FPS counter): the wave, or the countdown to the next one
    const spawner = &game.spawner;
    const wave_text = switch (spawner.phase) {
        .wave => format(&buf, "Wave {d}", .{spawner.wave}),
        .lull => format(&buf, "Wave {d} in {d}", .{ spawner.wave + 1, secondsLeft(spawner.timer) }),
    };
    drawBoxed(graphics, fonts.small, wave_text, WAVE_LABEL_X, BOX_PAD_Y, .left, .normal);
    drawWaveBanner(graphics, fonts, spawner, width);

    //Top centre: health
    drawBoxed(graphics, fonts.small, format(&buf, "Health {d}", .{game.player.health}), @divTrunc(width, 2), BOX_PAD_Y, .centre, if (game.player.health <= 25) .loud else .normal);

    //Top right: score, then the best to beat (or that it is being beaten)
    const right = width - BOX_PAD_X;
    drawBoxed(graphics, fonts.small, format(&buf, "Score {d}", .{game.player.score}), right, BOX_PAD_Y, .right, .normal);
    if (hud.best_score > 0 and game.player.score > hud.best_score) {
        drawBoxed(graphics, fonts.small, "NEW BEST!", right, BOX_PAD_Y + small_h, .right, .loud);
    } else {
        drawBoxed(graphics, fonts.small, format(&buf, "Best {d}", .{hud.best_score}), right, BOX_PAD_Y + small_h, .right, .normal);
    }
    //...and the combo multiplying each kill's score, louder once it is worth protecting
    const combo = game.player.kill_streak;
    if (combo >= consts.COMBO_SHOW_FROM) {
        drawBoxed(graphics, fonts.small, format(&buf, "Combo x{d}", .{combo}), right, BOX_PAD_Y + small_h * 2, .right, if (combo >= consts.COMBO_LOST_MIN) .loud else .normal);
    }

    //Bottom centre: ammo
    const ammo_y = height - small_h;
    if (game.bullets.isReloading()) {
        drawBoxed(graphics, fonts.small, format(&buf, "Reloading {d}", .{game.bullets.ammo}), @divTrunc(width, 2), ammo_y, .centre, .normal);
    } else if (game.bullets.ammo == 0) {
        drawBoxed(graphics, fonts.small, "OUT OF AMMO", @divTrunc(width, 2), ammo_y, .centre, .loud);
    } else {
        drawBoxed(graphics, fonts.small, format(&buf, "Ammo {d}", .{game.bullets.ammo}), @divTrunc(width, 2), ammo_y, .centre, .normal);
    }

    if (game.invincible) drawBoxed(graphics, fonts.small, "INVINCIBLE", BOX_PAD_X, height - small_h, .left, .loud); //Debug, so screenshots don't mislead
}

/// A combo message in the world, centred on `x` with its bottom at `y`
///
pub fn drawPopup(graphics: pd.playdate_graphics, fonts: Fonts, kind: state.PopupKind, value: u32, x: c_int, y: c_int) void {
    var buf: [24]u8 = undefined;
    switch (kind) {
        .combo => drawBoxed(graphics, fonts.small, format(&buf, "x{d}", .{value}), x, y - graphics.getFontHeight.?(fonts.small), .centre, .normal),
        .milestone => drawBoxed(graphics, fonts.big, format(&buf, "COMBO x{d}!", .{value}), x, y - graphics.getFontHeight.?(fonts.big), .centre, .loud),
        .lost => drawBoxed(graphics, fonts.small, "COMBO LOST", x, y - graphics.getFontHeight.?(fonts.small), .centre, .loud),
    }
}

const WAVE_LABEL_X = 34; //Clear of the FPS counter
const BANNER_Y = 140; //Below the player (in the middle of the screen), clear of the HUD at the top and bottom

/// Whole seconds left on a countdown, rounded up so it never shows 0 while still counting
///
fn secondsLeft(timer: f32) u32 {
    if (!(timer > 0) or timer > 999) return 0;
    return @as(u32, @intFromFloat(timer)) + 1;
}

/// The start and end of a wave: "WAVE N" and where it is coming from as it starts, and "WAVE N SURVIVED" when it
/// is cleared (not when it ran out of time: then the next wave starts straight away instead)
///
fn drawWaveBanner(graphics: pd.playdate_graphics, fonts: Fonts, spawner: *const state.Spawner, width: c_int) void {
    var buf: [48]u8 = undefined;
    const cx = @divTrunc(width, 2);
    const big_h: c_int = graphics.getFontHeight.?(fonts.big) + BOX_PAD_Y * 2 + 2;
    switch (spawner.phase) {
        .wave => if (spawner.phase_time < consts.WAVE_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, format(&buf, "WAVE {d}", .{spawner.wave}), cx, BANNER_Y, .centre, .loud);
            drawBoxed(graphics, fonts.small, sidesText(&buf, spawner.sides), cx, BANNER_Y + big_h, .centre, .normal);
        },
        .lull => if (spawner.survived and spawner.phase_time < consts.WAVE_SURVIVED_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, format(&buf, "WAVE {d} SURVIVED", .{spawner.wave}), cx, BANNER_Y, .centre, .normal);
            drawBoxed(graphics, fonts.small, "Grab what you can", cx, BANNER_Y + big_h, .centre, .normal);
        },
    }
}

/// "From the north", "From the north and east", ... "From all sides"
///
fn sidesText(buffer: []u8, sides: u8) []const u8 {
    if (@popCount(sides) == std.enums.values(MapSide).len) return "From all sides";
    var len: usize = 0;
    var written: u8 = 0;
    const total = @popCount(sides);
    for (std.enums.values(MapSide)) |side| {
        if (sides & (@as(u8, 1) << @intCast(@backingInt(side))) == 0) continue;
        const joiner = if (written == 0) "From the " else if (written + 1 == total) " and " else ", ";
        len += (std.fmt.bufPrint(buffer[len..], "{s}{s}", .{ joiner, @tagName(side) }) catch return buffer[0..len]).len;
        written += 1;
    }
    return buffer[0..len];
}

/// Dims the frozen last frame behind the run end screen: black on every other pixel, the rest left as it was
const PATTERN_DIM: pd.LCDPattern = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 };

const PANEL_W = 260;
const PANEL_LINES = 6; //Below the title, including the "go again" prompt

/// The run end screen over the frozen last frame: how the run went, the best, and how to go again
///
pub fn drawGameOver(graphics: pd.playdate_graphics, fonts: Fonts, game: *const GameState, hud: Hud, over: Hud.GameOver, width: c_int, height: c_int) void {
    var buf: [48]u8 = undefined;
    graphics.fillRect.?(0, 0, width, height, @intFromPtr(&PATTERN_DIM));

    //Sized from the fonts so the lines always fit
    const small_h: c_int = graphics.getFontHeight.?(fonts.small) + 4;
    const big_h: c_int = graphics.getFontHeight.?(fonts.big) + 6;
    const panel_h = 10 + big_h + PANEL_LINES * small_h + 4 + 10;
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
    drawBoxed(graphics, fonts.small, format(&buf, "Wave {d}   Survived {d}:{d:0>2}", .{ game.spawner.wave, secs / 60, secs % 60 }), cx, y, .centre, .normal);
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
        drawBoxed(graphics, fonts.small, format(&buf, "Best {d}", .{hud.best_score}), cx, y, .centre, .normal);
    }
    y += small_h + 4;
    if (over.can_restart) drawBoxed(graphics, fonts.small, "Press A to go again", cx, y, .centre, .loud);
}
