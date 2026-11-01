/// Responsible for drawing the overlay UI
///
const std = @import("std");
const pd = @import("playdate.zig").api;
const build_options = @import("build_options");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const GameState = state.GameState;
const MapSide = @import("level_loader.zig").MapSide;

// Screen space text drawn over the world by the renderer: the HUD, the run end screen and the helpers they share.
// Text sits on solid boxes so it stays readable over a full horde and the dithered ground.

/// What the HUD needs from outside the simulation (main owns the save and the run phase)
///
pub const Hud = struct {
    best_score: u64, //On the current level: each level has its own
    level_name: []const u8, //The current level, so the run end screen can say whose best it is
    game_over: ?state.RunEnd = null, //Set while the run end screen is up
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

/// Draw `text` on a solid box. `x` is the box's left edge, centre or right edge per `anchor`; `y` its top
///
fn drawBoxed(graphics: pd.playdate_graphics, font: *pd.LCDFont, text: []const u8, x: c_int, y: c_int, anchor: Anchor, style: Style) void {
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
fn format(buffer: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, fmt, args) catch buffer;
}

/// The always-on HUD, one short row at the top and bottom so it hides as little of the horde as it can: the wave,
/// the score (and combo), health and ammo, and the wave banners. The best to beat is on the run end screen; the
/// score turns loud once it is being beaten
///
pub fn drawHud(graphics: pd.playdate_graphics, fonts: Fonts, game: *const GameState, hud: Hud, width: c_int, height: c_int) void {
    var buf: [48]u8 = undefined;
    const font = fonts.hud;
    const row_h: c_int = graphics.getFontHeight.?(font) + BOX_PAD_Y * 2 + 1;

    //Top left: the wave, or the countdown to the next one
    const spawner = &game.spawner;
    const wave_text = switch (spawner.phase) {
        .wave => if (spawner.isHolding())
            format(&buf, "Wave {d}  {d}s", .{ spawner.wave, secondsLeft(spawner.hold - spawner.phase_time) })
        else
            format(&buf, "Wave {d}  Clear!", .{spawner.wave}),
        .lull => format(&buf, "Wave {d} in {d}", .{ spawner.wave + 1, secondsLeft(spawner.timer) }),
    };
    drawBoxed(graphics, font, wave_text, BOX_PAD_X, BOX_PAD_Y, .left, .normal);
    drawWaveBanner(graphics, fonts, spawner, width);

    //Bottom left: health, next to the ammo so the two resources read together
    const bottom_y = height - row_h;
    drawBoxed(graphics, font, format(&buf, "HP {d}", .{game.player.health}), BOX_PAD_X, bottom_y, .left, if (game.player.health <= 25) .loud else .normal);

    //Top right, one row: the score, loud once it beats the best, and to its left the combo multiplying each kill's
    //score, louder once it is worth protecting
    const right = width - BOX_PAD_X;
    const beating_best = hud.best_score > 0 and game.player.score > hud.best_score;
    const score_text = format(&buf, "{d}", .{game.player.score});
    drawBoxed(graphics, font, score_text, right, BOX_PAD_Y, .right, if (beating_best) .loud else .normal);
    const combo = game.player.kill_streak;
    if (combo >= consts.COMBO_SHOW_FROM) {
        const combo_right = right - graphics.getTextWidth.?(font, score_text.ptr, score_text.len, pd.kASCIIEncoding, 0) - BOX_PAD_X * 2 - 2;
        var combo_buf: [16]u8 = undefined;
        drawBoxed(graphics, font, format(&combo_buf, "x{d}", .{combo}), combo_right, BOX_PAD_Y, .right, if (combo >= consts.COMBO_LOST_MIN) .loud else .normal);
    }

    //Bottom right: ammo (health is bottom left). Full says so, as ammo drops are then left lying
    if (game.bullets.ammo == 0) {
        drawBoxed(graphics, font, "OUT OF AMMO", right, bottom_y, .right, .loud);
    } else if (game.bullets.ammo >= consts.MAX_AMMO) {
        drawBoxed(graphics, font, format(&buf, "Ammo {d} MAX", .{game.bullets.ammo}), right, bottom_y, .right, .normal);
    } else {
        drawBoxed(graphics, font, format(&buf, "Ammo {d}", .{game.bullets.ammo}), right, bottom_y, .right, .normal);
    }

    if (game.invincible) drawBoxed(graphics, font, "INVINCIBLE", BOX_PAD_X, BOX_PAD_Y + row_h, .left, .loud); //Debug, so screenshots don't mislead
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
        .combo => drawBoxed(graphics, fonts.small, format(&buf, "x{d}", .{value}), x, y - graphics.getFontHeight.?(fonts.small), .centre, .normal),
        .milestone => drawBoxed(graphics, fonts.big, format(&buf, "COMBO x{d}!", .{value}), x, y - graphics.getFontHeight.?(fonts.big), .centre, .loud),
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

/// The beats of a wave: "WAVE N", how long to hold out and where it is coming from as it starts, "CLEAR THE REST"
/// when the spawning stops, and "WAVE N SURVIVED" when it is cleared (not when it ran out of time: then the next
/// wave starts straight away instead)
///
fn drawWaveBanner(graphics: pd.playdate_graphics, fonts: Fonts, spawner: *const state.Spawner, width: c_int) void {
    var buf: [48]u8 = undefined;
    const cx = @divTrunc(width, 2);
    const big_h: c_int = graphics.getFontHeight.?(fonts.big) + BOX_PAD_Y * 2 + 2;
    switch (spawner.phase) {
        .wave => if (spawner.phase_time < consts.WAVE_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, format(&buf, "WAVE {d}", .{spawner.wave}), cx, BANNER_Y, .centre, .loud);
            var sides_buf: [40]u8 = undefined;
            drawBoxed(graphics, fonts.small, format(&buf, "Hold out {d}s {s}", .{ secondsLeft(spawner.hold) - 1, sidesText(&sides_buf, spawner.sides) }), cx, BANNER_Y + big_h, .centre, .normal);
        } else if (!spawner.isHolding() and spawner.phase_time < spawner.hold + consts.WAVE_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, "CLEAR THE REST", cx, BANNER_Y, .centre, .loud);
        },
        .lull => if (spawner.survived and spawner.phase_time < consts.WAVE_SURVIVED_BANNER_TIME) {
            drawBoxed(graphics, fonts.big, format(&buf, "WAVE {d} SURVIVED", .{spawner.wave}), cx, BANNER_Y, .centre, .normal);
            drawBoxed(graphics, fonts.small, "Grab what you can", cx, BANNER_Y + big_h, .centre, .normal);
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

/// The run end screen over the frozen last frame: how the run went, the best, and how to go again
///
pub fn drawGameOver(graphics: pd.playdate_graphics, fonts: Fonts, game: *const GameState, hud: Hud, over: state.RunEnd, width: c_int, height: c_int) void {
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
        drawBoxed(graphics, fonts.small, format(&buf, "Best on {s} {d}", .{ hud.level_name, hud.best_score }), cx, y, .centre, .normal);
    }
    y += small_h + 4;
    if (over.canRestart()) drawBoxed(graphics, fonts.small, "Press A to go again", cx, y, .centre, .loud);
}
