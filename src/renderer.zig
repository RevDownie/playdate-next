const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const anim = @import("animation.zig");
const bitmap_descs = @import("bitmap_descs.zig");
const consts = @import("tweak_constants.zig");
const memory = @import("memory.zig");
const GameState = @import("game_state.zig").GameState;
const Level = @import("level_loader.zig").Level;
const Arena = memory.Arena;

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

/// Which bitmap table a sprite is drawn from
///
const Sheet = enum(u8) { player, enemy, env };

/// Bitmaps owned by the Playdate runtime, loaded once up front
///
pub const Assets = struct {
    bg_bitmap: *pd.LCDBitmap,
    tables: [std.enums.values(Sheet).len]*pd.LCDBitmapTable, //Indexed by Sheet
};

/// One entry in the per frame draw list, already in screen space with the sprite's anchor applied.
/// Kept to 8 bytes (no pointers, sizes or offsets - those come from the Sheet) so the whole list plus its
/// sort keys stays inside the L1 hot set budget while it is sorted and then read back in depth order
///
const DrawItem = extern struct {
    x: i16,
    y: i16,
    frame: u8,
    sheet: Sheet,
    flipped: bool,
    _pad: u8 = 0,
};

/// Sort key: depth (screen y of the sprite's feet, biased to unsigned) in the high half and the draw item's
/// index in the low half. Sorting plain u32s needs no indirection, and as keys are unique the order is stable
const SortKey = u32;

pub const BYTES_PER_DRAW_ITEM = @sizeOf(DrawItem) + @sizeOf(SortKey);
comptime {
    std.debug.assert(@sizeOf(DrawItem) == 8);
    //Every character on screen at once must fit, leaving room for the environment objects in view
    if ((1 + @as(usize, consts.MAX_ENEMIES)) * BYTES_PER_DRAW_ITEM > memory.HOT_SET_BUDGET * 3 / 4) @compileError("Character draw list no longer fits the L1 hot set budget");
}

pub const RenderStats = struct {
    drawn: u16, //Sprites that survived culling this frame
};

/// Load the rendering assets - bitmaps and bitmap tables
///
pub fn loadAssets(playdate_api: *pd.PlaydateAPI, level_bitmap_name: [*:0]const u8) Assets {
    const graphics = playdate_api.graphics.*;
    var assets: Assets = undefined;
    assets.bg_bitmap = graphics.loadBitmap.?("bg", null) orelse @panic("loadAssets: Failed to load bg");
    assets.tables[@intFromEnum(Sheet.player)] = graphics.loadBitmapTable.?("hero1", null) orelse @panic("loadAssets: Failed to load hero1");
    assets.tables[@intFromEnum(Sheet.enemy)] = graphics.loadBitmapTable.?("enemy1", null) orelse @panic("loadAssets: Failed to load enemy1");
    assets.tables[@intFromEnum(Sheet.env)] = graphics.loadBitmapTable.?(level_bitmap_name, null) orelse @panic("loadAssets: Failed to load level bitmaps");
    return assets;
}

/// Build a draw list of everything on screen, sort it by "depth order" and draw it, then the bullets and HUD.
/// Per frame buffers come from the frame arena
///
pub fn render(playdate_api: *pd.PlaydateAPI, assets: *const Assets, game: *const GameState, level: *const Level, frame_arena: *Arena) RenderStats {
    const sys = playdate_api.system.*;
    const disp = playdate_api.display.*;
    const graphics = playdate_api.graphics.*;

    const screen = Screen{ .width = disp.getWidth.?(), .height = disp.getHeight.?(), .camera_pos = game.camera_pos };

    //Inverting the whole screen is the hit flash
    _ = graphics.setDrawMode.?(if (game.player.hit_flash_timer > 0) pd.kDrawModeInverted else pd.kDrawModeCopy);

    //---Render the BG
    const bg_screen_pos = screen.toScreen(Vec2f{ 0, 0 });
    const bg_size = level.bg_size_pixels;
    graphics.tileBitmap.?(assets.bg_bitmap, bg_screen_pos[0] - @divTrunc(bg_size[0], 2), bg_screen_pos[1] - @divTrunc(bg_size[1], 2), bg_size[0], bg_size[1], pd.kBitmapUnflipped);

    //---Build the draw list of visible sprites. Characters face the way they are aiming / moving
    const max_items = 1 + game.enemies.len + level.obj_world_positions.len;
    var list = DrawList{ .items = frame_arena.alloc(DrawItem, max_items), .keys = frame_arena.alloc(SortKey, max_items) };

    list.addCharacter(screen, .player, game.player.pos, game.player.facing_dir);
    for (game.enemies.positions(), game.enemies.velocities()) |p, v| {
        list.addCharacter(screen, .enemy, p, v);
    }
    for (level.obj_world_positions, level.obj_bitmap_indices) |p, bi| {
        list.add(screen, .env, p, .{ .index = bi, .flipped = false }, .{ bitmap_descs.ENV_OBJ_W / 2, bitmap_descs.ENV_OBJ_H });
    }

    //---Sort by depth and draw back to front
    const keys = list.keys[0..list.len];
    std.sort.pdq(SortKey, keys, {}, std.sort.asc(SortKey));
    for (keys) |key| {
        const item = list.items[@as(u16, @truncate(key))];
        const bitmap = graphics.getTableBitmap.?(assets.tables[@intFromEnum(item.sheet)], item.frame) orelse @panic("render: Bitmap index out of range for its table");
        graphics.drawBitmap.?(bitmap, item.x, item.y, if (item.flipped) pd.kBitmapFlippedX else pd.kBitmapUnflipped);
    }

    //---Bullets are rendered as geometry on top. TODO: Interleave bullets
    for (game.bullets.positions()) |p| {
        const sp = screen.toScreen(p);
        graphics.fillRect.?(sp[0], sp[1], 6, 6, pd.kColorBlack);
    }

    //---HUD. TODO: Replace with bitmap font
    drawLabel(graphics, "Score: {d}", game.player.score, screen.width - 100, 0);
    drawLabel(graphics, "Health: {d}", game.player.health, @divTrunc(screen.width, 2), 0);
    drawLabel(graphics, "Bullets: {d}", game.bullets.magazine, @divTrunc(screen.width, 2), screen.height - 30);

    sys.drawFPS.?(0, 0);
    return .{ .drawn = @intCast(list.len) };
}

const Screen = struct {
    width: i32,
    height: i32,
    camera_pos: Vec2f,

    fn toScreen(self: Screen, world_pos: Vec2f) Vec2i {
        return graphics_coords.worldPointToScreen(self.camera_pos, world_pos, self.width, self.height);
    }
};

const DrawList = struct {
    items: []DrawItem,
    keys: []SortKey,
    len: usize = 0,

    fn addCharacter(self: *DrawList, screen: Screen, sheet: Sheet, world_pos: Vec2f, facing_dir: Vec2f) void {
        const anchor = Vec2i{ bitmap_descs.CHAR_W / 2, @as(i32, bitmap_descs.CHAR_H) - anim.walkBobAnim(world_pos) };
        self.add(screen, sheet, world_pos, anim.bitmapFrameForDir(facing_dir), anchor);
    }

    /// Add a sprite whose `anchor` (pixels from its top left) sits at `world_pos`, unless it is off screen
    ///
    fn add(self: *DrawList, screen: Screen, sheet: Sheet, world_pos: Vec2f, frame: anim.BitmapFrame, anchor: Vec2i) void {
        const feet = screen.toScreen(world_pos);
        const top_left = feet - anchor;
        const size = sheetSize(sheet);
        if (top_left[0] >= screen.width or top_left[1] >= screen.height or top_left[0] + size[0] <= 0 or top_left[1] + size[1] <= 0) return;

        //On screen, so every coordinate is well within i16 range
        const idx: u16 = @intCast(self.len);
        self.items[idx] = .{ .x = @intCast(top_left[0]), .y = @intCast(top_left[1]), .frame = frame.index, .sheet = sheet, .flipped = frame.flipped };
        const depth: u16 = @intCast(feet[1] + std.math.maxInt(i16));
        self.keys[idx] = (@as(SortKey, depth) << 16) | idx;
        self.len += 1;
    }
};

fn sheetSize(sheet: Sheet) Vec2i {
    return switch (sheet) {
        .player, .enemy => .{ bitmap_descs.CHAR_W, bitmap_descs.CHAR_H },
        .env => .{ bitmap_descs.ENV_OBJ_W, bitmap_descs.ENV_OBJ_H },
    };
}

/// Draw a single number with a label, truncated if it doesn't fit the buffer
///
fn drawLabel(graphics: pd.playdate_graphics, comptime fmt: []const u8, value: anytype, x: c_int, y: c_int) void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, .{value}) catch buffer[0..];
    _ = graphics.drawText.?(text.ptr, text.len, pd.kASCIIEncoding, x, y);
}
