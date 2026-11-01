const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const anim = @import("animation.zig");
const bitmap_descs = @import("bitmap_descs.zig");
const kit_descs = @import("kit_descs.zig");
const consts = @import("tweak_constants.zig");
const memory = @import("memory.zig");
const hud_mod = @import("hud.zig");
const screens = @import("screens.zig");
const story = @import("story.zig");
const maths = @import("maths.zig");
const state = @import("game_state.zig");
const GameState = state.GameState;
const level_loader = @import("level_loader.zig");
const Level = level_loader.Level;
const Arena = memory.Arena;

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

pub const Hud = hud_mod.Hud;

/// Which bitmap table a sprite is drawn from. The zombie and gib sheets are in EnemyKind order. `env` is the
/// exception: its frame is a piece of the level's kit, each piece its own bitmap (they differ in size)
///
const Sheet = enum(u8) { player, gun, melee, runner, walker, shambler, brute, env, drop, gibs_runner, gibs_walker, gibs_shambler, gibs_brute, pool, spatter };

const SHEET_FILES = [_][*:0]const u8{ "hero", "hero_gun", "hero_melee", "zombie_runner", "zombie_walker", "zombie_shambler", "zombie_brute" };
const GORE_SHEET_FILES = [_][*:0]const u8{ "gibs_runner", "gibs_walker", "gibs_shambler", "gibs_brute", "splats", "spatters" }; //From Sheet.gibs_runner on

fn enemySheet(kind: state.EnemyKind) Sheet {
    return @fromBackingInt(@intCast(@backingInt(Sheet.runner) + @backingInt(kind)));
}

fn gibSheet(kind: state.EnemyKind) Sheet {
    return @fromBackingInt(@intCast(@backingInt(Sheet.gibs_runner) + @backingInt(kind)));
}

/// Bitmaps owned by the Playdate runtime, loaded once up front
///
pub const Assets = struct {
    tables: [std.enums.values(Sheet).len]*pd.LCDBitmapTable, //Indexed by Sheet (not env)
    //Every kit's pieces, by kit, piece and pixel phase, and each level's baked floor by level index and phase. The
    //environment art is dithered once per screen pixel phase (x even/odd, y even/odd, kit_descs.PHASES) and drawn with
    //the version matching where it lands, so its dither stays fixed to the screen and doesn't flicker as it scrolls
    kit_pieces: [kit_descs.KITS.len][kit_descs.MAX_KIT_PIECES][kit_descs.PHASES]*pd.LCDBitmap,
    kit_tables: [kit_descs.KITS.len]*pd.LCDBitmapTable, //Own the kit_pieces bitmaps: one file per kit
    grounds: [MAX_LEVELS][kit_descs.PHASES]*pd.LCDBitmap,
    fonts: hud_mod.Fonts,
};

const MAX_LEVELS = 8;

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

/// Degrees of circle the melee swing sweeps
const MELEE_ARC_DEGREES: f32 = 140;

/// How fast combo messages float up
const POPUP_RISE_PX_PER_SEC: f32 = 30;

/// Seconds per on/off cycle of a drop that is about to vanish
const BLINK_PERIOD: f32 = 0.25;

/// Drop shadow ellipses in pixels, a little narrower than the drawn drop
const DROP_SHADOW_W = 30;
const DROP_SHADOW_W_LARGE = 32;
const DROP_SHADOW_H = 8;

/// Something about to vanish (`lifetime` seconds left) blinks for its last `blink_time`: hidden every other half
/// period. Integer half periods: a float @mod would call libc's fmodf, which drags newlib's malloc into the device link
///
fn isBlinkedOut(lifetime: f32, blink_time: f32) bool {
    return lifetime < blink_time and @as(u32, @intFromFloat(@max(lifetime, 0) / (BLINK_PERIOD / 2))) % 2 == 0;
}

/// Pixels above its centre a gib lying on the ground is drawn, so it rests on the ground rather than in it
const GIB_REST_LIFT_PX = 2;

/// Size in pixels of the ring drawn at the gun's target's feet
const TARGET_RING_W = 30;
const TARGET_RING_H = 12;

pub const BYTES_PER_DRAW_ITEM = @sizeOf(DrawItem) + @sizeOf(SortKey);
comptime {
    if (@sizeOf(DrawItem) != 8) @compileError("DrawItem must stay 8 bytes");
    //Every character and drop on screen at once must fit, leaving room for the environment objects in view
    //(The player is two sprites: the body and the arms holding the weapon. Gore is drawn outside the list: on the
    //ground first, and anything in the air over the sprites)
    if ((2 + @as(usize, consts.MAX_ENEMIES) + consts.MAX_DROPS) * BYTES_PER_DRAW_ITEM > memory.HOT_SET_BUDGET * 3 / 4) @compileError("Character draw list no longer fits the L1 hot set budget");
    for (std.enums.values(state.EnemyKind)) |k| {
        if (!std.mem.eql(u8, @tagName(enemySheet(k)), @tagName(k))) @compileError("Sheet's zombie sheets must be in EnemyKind order");
        if (!std.mem.eql(u8, @tagName(gibSheet(k)), "gibs_" ++ @tagName(k))) @compileError("Sheet's gib sheets must be in EnemyKind order");
    }
    if (@backingInt(Sheet.gibs_runner) + GORE_SHEET_FILES.len != std.enums.values(Sheet).len) @compileError("GORE_SHEET_FILES must cover the last Sheets");
}

pub const RenderStats = struct {
    drawn: u16, //Sprites that survived culling this frame
};

/// Load the rendering assets - bitmaps and bitmap tables, every kit's pieces and every level's ground (`level_names`,
/// whose ground is `ground-<name>`), all up front so changing level between runs reads no image files
///
pub fn loadAssets(playdate_api: *pd.PlaydateAPI, level_names: []const [:0]const u8) Assets {
    const graphics = playdate_api.graphics.*;
    var assets: Assets = undefined;
    for (SHEET_FILES, 0..) |name, i| {
        assets.tables[i] = graphics.loadBitmapTable.?(name, null) orelse @panic("loadAssets: Failed to load a character sheet");
    }
    var name_buf: [64]u8 = undefined;
    for (kit_descs.KITS, 0..) |kit, k| {
        //Piece i's phase v is at index i * PHASES + v (env_kits.py). The table keeps each bitmap's own size
        const name = std.fmt.bufPrintSentinel(&name_buf, "{s}-pieces", .{kit.name}, 0) catch unreachable;
        const table = graphics.loadBitmapTable.?(name, null) orelse @panic("loadAssets: Failed to load a kit's pieces");
        assets.kit_tables[k] = table;
        for (kit.pieces, 0..) |piece, i| {
            for (0..kit_descs.PHASES) |v| {
                const bitmap = graphics.getTableBitmap.?(table, @intCast(i * kit_descs.PHASES + v)) orelse @panic("loadAssets: A kit's pieces table is short");
                var w: c_int = 0;
                var h: c_int = 0;
                graphics.getBitmapData.?(bitmap, &w, &h, null, null, null);
                if (w != piece.w or h != piece.h) @panic("loadAssets: A kit piece's size doesn't match kit_descs (re-run env_kits.py)");
                assets.kit_pieces[k][i][v] = bitmap;
            }
        }
    }
    std.debug.assert(level_names.len <= MAX_LEVELS);
    for (level_names, 0..) |level_name, i| {
        for (0..kit_descs.PHASES) |v| {
            const name = std.fmt.bufPrintSentinel(&name_buf, "ground-{s}-p{d}", .{ level_name, v }, 0) catch unreachable;
            assets.grounds[i][v] = graphics.loadBitmap.?(name, null) orelse @panic("loadAssets: Failed to load a level's ground");
        }
    }
    assets.tables[@backingInt(Sheet.drop)] = graphics.loadBitmapTable.?("drops", null) orelse @panic("loadAssets: Failed to load drops");
    for (GORE_SHEET_FILES, @backingInt(Sheet.gibs_runner)..) |name, i| {
        assets.tables[i] = graphics.loadBitmapTable.?(name, null) orelse @panic("loadAssets: Failed to load a gore sheet");
    }
    assets.fonts = hud_mod.loadFonts(playdate_api);
    return assets;
}

/// Build a draw list of everything on screen, sort it by "depth order" and draw it, then the bullets, the HUD
/// and (when the run is over) the run end screen. Per frame buffers come from the frame arena
///
pub fn render(playdate_api: *pd.PlaydateAPI, assets: *const Assets, game: *const GameState, level: *const Level, level_index: usize, hud: Hud, frame_arena: *Arena) RenderStats {
    const sys = playdate_api.system.*;
    const disp = playdate_api.display.*;
    const graphics = playdate_api.graphics.*;

    const screen = Screen{ .width = disp.getWidth.?(), .height = disp.getHeight.?(), .camera_pos = game.camera.drawPos() };

    //Inverting the whole screen is the hit flash
    _ = graphics.setDrawMode.?(if (game.player.hit_flash_timer > 0) pd.kDrawModeInverted else pd.kDrawModeCopy);

    //---The floor: one bitmap baked offline (convert_tilemaps.py) with the ground art, decals and the view beyond the
    //map, which extends GROUND_MARGIN_X/Y past the map's edges. Its pixel under the world origin (the centre of
    //the middle cell) goes on the origin's screen position, floored like the sprites' (on screen) positions
    const grid = &level.collision_grid;
    const ground_origin = Vec2i{
        kit_descs.GROUND_MARGIN_X + @as(i32, grid.width / 2) * grid.cell_width + grid.cell_width / 2,
        kit_descs.GROUND_MARGIN_Y + @as(i32, grid.height / 2) * grid.cell_height + grid.cell_height / 2,
    };
    const origin_on_screen = Vec2f{ -screen.camera_pos[0] * consts.METRES_TO_PIXELS + @as(f32, @floatFromInt(screen.width >> 1)), screen.camera_pos[1] * consts.METRES_TO_PIXELS + @as(f32, @floatFromInt(screen.height >> 1)) };
    const ground_pos = Vec2i{ @intFromFloat(@floor(origin_on_screen[0])), @intFromFloat(@floor(origin_on_screen[1])) } - ground_origin;
    graphics.drawBitmap.?(assets.grounds[level_index][phaseAt(ground_pos[0], ground_pos[1])], ground_pos[0], ground_pos[1], pd.kBitmapUnflipped);

    //---Gore on the ground under everything standing, so it needs no depth sort: blood pools, spatters, then the
    //body parts lying in them
    const gore = &game.gore;
    drawSplats(graphics, assets, screen, .pool, gore.pools.pos[0..gore.pools.len], gore.pools.fade[0..gore.pools.len], gore.pools.variant[0..gore.pools.len]);
    drawSplats(graphics, assets, screen, .spatter, gore.spatters.pos[0..gore.spatters.len], gore.spatters.fade[0..gore.spatters.len], gore.spatters.variant[0..gore.spatters.len]);
    const gibs = &gore.gibs;
    for (0..gibs.len) |i| {
        if (gibs.height[i] > 0 or gibs.fade[i] >= consts.GIB_FADE_TIME) continue;
        drawGib(graphics, assets, screen, gibs, i, GIB_REST_LIFT_PX);
    }

    //---Ring on the ground under the gun's target, below the sprites. XOR so it reads on light and dark ground
    if (game.player.target_pos) |t| {
        const feet = screen.toScreen(t);
        graphics.drawEllipse.?(feet[0] - TARGET_RING_W / 2, feet[1] - TARGET_RING_H / 2, TARGET_RING_W, TARGET_RING_H, 2, 0, 360, pd.kColorXOR);
    }

    //---Shadows under the drops, on the ground below their bounce (smaller when higher)
    const drops = &game.drops;
    for (drops.pos[0..drops.len], drops.kind[0..drops.len], drops.lifetime[0..drops.len]) |p, k, l| {
        if (isBlinkedOut(l, consts.DROP_BLINK_TIME)) continue;
        const feet = screen.toScreen(p);
        const w: i32 = @as(i32, if (k.isLarge()) DROP_SHADOW_W_LARGE else DROP_SHADOW_W) - 2 * anim.dropBounce(consts.DROP_LIFETIME - l);
        if (feet[0] + w < 0 or feet[0] - w > screen.width or feet[1] < -DROP_SHADOW_H or feet[1] > screen.height + DROP_SHADOW_H) continue;
        graphics.fillEllipse.?(feet[0] - @divTrunc(w, 2), feet[1] - DROP_SHADOW_H / 2, w, DROP_SHADOW_H, 0, 360, @intFromPtr(&PATTERN_SHADOW));
    }

    //---Build the draw list of visible sprites. The player faces the way they aim, enemies the way they move
    const max_items = 2 + game.enemies.len + game.drops.len + level.obj_world_positions.len;
    var list = DrawList{ .items = frame_arena.alloc(DrawItem, max_items), .keys = frame_arena.alloc(SortKey, max_items) };

    const player = &game.player;
    if (hud.game_over) |over| {
        list.add(screen, .player, player.pos, anim.heroDeathFrame(player.facing_dir, over.time), sheetAnchor(.player), sheetSize(.player));
    } else {
        //The body, then the arms and weapon over it: same depth, and added straight after so it draws just after
        const moving = player.vel[0] != 0 or player.vel[1] != 0;
        const hurt = player.hit_flash_timer > 0;
        list.add(screen, .player, player.pos, anim.heroFrame(player.facing_dir, moving, player.run_dist, hurt), sheetAnchor(.player), sheetSize(.player));
        const melee = game.bullets.ammo == 0;
        const swing_progress = 1 - game.melee.swing_timer / consts.MELEE_SWING_TIME;
        const weapon = anim.heroWeaponFrame(player.facing_dir, melee, game.melee.swing_timer > 0, swing_progress, hurt);
        list.add(screen, if (melee) .melee else .gun, player.pos, weapon, sheetAnchor(.player), sheetSize(.player));
    }
    const enemies = &game.enemies;
    for (enemies.positions(), enemies.velocities(), enemies.kind[0..enemies.len], 0..) |p, v, kind, i| {
        const sheet = enemySheet(kind);
        list.add(screen, sheet, p, anim.enemyFrame(p, v, enemies.isBumping(i)), sheetAnchor(sheet), sheetSize(sheet));
    }
    //Drops bob above their point with a glint now and then, blinking for their last few seconds before they vanish.
    //The bob goes in the anchor so the depth sort still uses the point on the ground
    for (drops.pos[0..drops.len], drops.kind[0..drops.len], drops.lifetime[0..drops.len], drops.point[0..drops.len]) |p, k, l, point| {
        if (isBlinkedOut(l, consts.DROP_BLINK_TIME)) continue;
        const age = consts.DROP_LIFETIME - l;
        const frame = @as(u32, @backingInt(k)) * bitmap_descs.DROP_FRAMES_PER_KIND + anim.dropSheenFrame(age, point);
        const anchor = Vec2i{ bitmap_descs.DROP_W / 2, @as(i32, bitmap_descs.DROP_H) - 1 + anim.dropBounce(age) };
        list.add(screen, .drop, p, .{ .index = @intCast(frame), .flipped = false }, anchor, sheetSize(.drop));
    }
    //Level objects: each piece has its own size and anchor (mirrored pieces have their own anchor too)
    const kit_pieces = kit_descs.KITS[level.kit].pieces;
    for (level.obj_world_positions, level.obj_pieces) |p, piece_byte| {
        const flipped = piece_byte & level_loader.PIECE_FLIPPED != 0;
        const index = piece_byte & ~level_loader.PIECE_FLIPPED;
        const piece = kit_pieces[index];
        list.add(screen, .env, p, .{ .index = index, .flipped = flipped }, .{ if (flipped) piece.anchor_x_flipped else piece.anchor_x, piece.anchor_y }, .{ piece.w, piece.h });
    }

    //---Sort by depth and draw back to front
    const keys = list.keys[0..list.len];
    std.sort.pdq(SortKey, keys, {}, std.sort.asc(SortKey));
    for (keys) |key| {
        const item = list.items[@as(u16, @truncate(key))];
        const bitmap = if (item.sheet == .env) envBitmap(assets, level.kit, item) else graphics.getTableBitmap.?(assets.tables[@backingInt(item.sheet)], item.frame) orelse @panic("render: Bitmap index out of range for its table");
        graphics.drawBitmap.?(bitmap, item.x, item.y, if (item.flipped) pd.kBitmapFlippedX else pd.kBitmapUnflipped);
    }

    //---Gore in the air flies over everything, over a small shadow on the ground: gibs, then droplets of blood (black
    //with a white edge so they show over the zombies too)
    for (0..gibs.len) |i| {
        const height = gibs.height[i];
        if (height <= 0 or gibs.fade[i] >= consts.GIB_FADE_TIME) continue; //(A big burst can fade one still flying)
        const ground = screen.toScreen(gibs.pos[i]);
        const shadow_w: i32 = @divTrunc(@as(i32, @intCast(bitmap_descs.GIB_CELLS[@backingInt(gibs.kind[i])])), 2);
        graphics.fillEllipse.?(ground[0] - @divTrunc(shadow_w, 2), ground[1] - 2, shadow_w, 4, 0, 360, @intFromPtr(&PATTERN_SHADOW));
        drawGib(graphics, assets, screen, gibs, i, @intFromFloat(height * consts.METRES_TO_PIXELS));
    }
    const droplets = &gore.droplets;
    for (droplets.pos[0..droplets.len], droplets.height[0..droplets.len], droplets.live[0..droplets.len], 0..) |p, h, live, i| {
        if (!live) continue;
        const at = screen.toScreen(p) - Vec2i{ 0, @intFromFloat(h * consts.METRES_TO_PIXELS) };
        if (at[0] < -4 or at[0] > screen.width + 4 or at[1] < -4 or at[1] > screen.height + 4) continue;
        const size: i32 = if (i % 3 == 0) 3 else 2; //A few bigger gobs
        graphics.fillRect.?(at[0] - 1, at[1] - 1, size + 2, size + 2, pd.kColorWhite);
        graphics.fillRect.?(at[0], at[1], size, size, pd.kColorBlack);
    }

    //---Bullets are comet tracers on top, at gun height
    const bullets = &game.bullets;
    const gun_height = Vec2i{ 0, consts.GUN_HEIGHT_PX };
    for (bullets.pos[0..bullets.len], bullets.dir[0..bullets.len], bullets.lifetime[0..bullets.len], bullets.barrel[0..bullets.len]) |p, d, l, b| {
        const travelled = (consts.BULLET_LIFETIME - l) * consts.BULLET_MAX_SPEED;
        const tracer = anim.bulletTracer(p, d, travelled, b);
        const head = screen.toScreen(tracer.head) - gun_height;
        const tail = screen.toScreen(tracer.tail) - gun_height;
        drawTracer(graphics, head, tail);
    }

    //---The last shot's muzzle flash at the barrel it left from, unless the player has asked the system to reduce
    //flashing
    if (hud.game_over == null and bullets.flash_timer > 0 and sys.getReduceFlashing.?() == 0) {
        const aim = game.player.facing_dir;
        const muzzle = screen.toScreen(game.player.pos + anim.muzzleOffset(aim, bullets.flash_barrel)) - gun_height;
        drawMuzzleFlash(graphics, muzzle, aim, bullets.flash_barrel, bullets.flash_timer / consts.MUZZLE_FLASH_TIME);
    }

    //---The melee swing: an arc sweeping round the player towards the enemy struck, at chest height
    const melee = &game.melee;
    if (melee.swing_timer > 0) {
        const chest = screen.toScreen(game.player.pos) - Vec2i{ 0, consts.GUN_HEIGHT_PX };
        const r: i32 = @intFromFloat(consts.MELEE_RANGE * consts.METRES_TO_PIXELS);
        //Degrees clockwise from screen up (the API's convention); world +y is up
        const facing = std.math.radiansToDegrees(std.math.atan2(melee.swing_dir[0], melee.swing_dir[1]));
        const progress = 1 - melee.swing_timer / consts.MELEE_SWING_TIME;
        //The API wants angles from 0 to 360: a negative start draws (nearly) the whole circle
        const start = if (facing - MELEE_ARC_DEGREES / 2 < 0) facing - MELEE_ARC_DEGREES / 2 + 360 else facing - MELEE_ARC_DEGREES / 2;
        graphics.drawEllipse.?(chest[0] - r, chest[1] - r, 2 * r, 2 * r, 3, start, start + MELEE_ARC_DEGREES * progress, pd.kColorXOR);
    }

    //---Text is never inverted by the hit flash, so it stays readable
    _ = graphics.setDrawMode.?(pd.kDrawModeCopy);

    //---Off screen drops are marked at the edge, pointing the way
    if (hud.game_over == null) {
        for (drops.pos[0..drops.len], drops.kind[0..drops.len], drops.lifetime[0..drops.len]) |p, k, l| {
            if (isBlinkedOut(l, consts.DROP_BLINK_TIME)) continue;
            const marker = graphics_coords.offScreenMarker(screen.toScreen(p), screen.width, screen.height, consts.DROP_MARKER_INSET_SIDE, consts.DROP_MARKER_INSET_TOP, consts.DROP_MARKER_INSET_SIDE, consts.DROP_MARKER_INSET_BOTTOM) orelse continue;
            hud_mod.drawDropMarker(graphics, k, marker.pos[0], marker.pos[1], marker.dir);
        }
    }

    //---Combo messages float up from above where they happened
    const popups = &game.popups;
    for (popups.pos[0..popups.len], popups.life[0..popups.len], popups.value[0..popups.len], popups.kind[0..popups.len]) |p, life, value, kind| {
        const rise: i32 = @intFromFloat((kind.duration() - life) * POPUP_RISE_PX_PER_SEC);
        const at = screen.toScreen(p) - Vec2i{ 0, @as(i32, bitmap_descs.CHAR_H) + rise };
        if (at[0] < -50 or at[0] > screen.width + 50 or at[1] < -30 or at[1] > screen.height) continue;
        hud_mod.drawPopup(graphics, assets.fonts, kind, value, at[0], at[1]);
    }

    //The run end screen covers the middle, so it waits for the player to finish falling down
    const panel: ?state.RunEnd = if (hud.game_over) |over| (if (over.time >= consts.GAME_OVER_PANEL_DELAY) over else null) else null;
    if (panel) |over| {
        hud_mod.drawGameOver(graphics, assets.fonts, game, hud, over, screen.width, screen.height);
    } else {
        hud_mod.drawHud(graphics, assets.fonts, game, hud, screen.width, screen.height, sys.getReduceFlashing.?() != 0);
    }
    hud_mod.drawFps(sys, screen.width, screen.height);
    return .{ .drawn = @intCast(list.len) };
}

/// Whether a story line fits its voice's box on this screen (main checks every line at init, Debug only)
///
pub fn lineFits(playdate_api: *pd.PlaydateAPI, assets: *const Assets, voice: story.Voice, text: []const u8) bool {
    return hud_mod.lineFits(playdate_api.graphics.*, assets.fonts, voice, text, playdate_api.display.*.getWidth.?());
}

/// A screen with no world under it (the title, story cards): the text on white
///
pub fn renderTitle(playdate_api: *pd.PlaydateAPI, assets: *const Assets, title: screens.Title) void {
    const graphics = clearForText(playdate_api);
    hud_mod.drawTitle(graphics, assets.fonts, title, playdate_api.display.*.getWidth.?());
    hud_mod.drawFps(playdate_api.system.*, playdate_api.display.*.getWidth.?(), playdate_api.display.*.getHeight.?());
}

pub fn renderStoryCard(playdate_api: *pd.PlaydateAPI, assets: *const Assets, card: screens.StoryCard) void {
    const graphics = clearForText(playdate_api);
    const disp = playdate_api.display.*;
    hud_mod.drawStoryCard(graphics, assets.fonts, card, disp.getWidth.?(), disp.getHeight.?());
    hud_mod.drawFps(playdate_api.system.*, disp.getWidth.?(), disp.getHeight.?());
}

fn clearForText(playdate_api: *pd.PlaydateAPI) pd.playdate_graphics {
    const graphics = playdate_api.graphics.*;
    _ = graphics.setDrawMode.?(pd.kDrawModeCopy);
    graphics.clear.?(pd.kColorWhite);
    return graphics;
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

    /// Add a sprite of `size` pixels whose `anchor` (pixels from its top left) sits at `world_pos`, unless it is off
    /// screen
    ///
    fn add(self: *DrawList, screen: Screen, sheet: Sheet, world_pos: Vec2f, frame: anim.BitmapFrame, anchor: Vec2i, size: Vec2i) void {
        const feet = screen.toScreen(world_pos);
        const top_left = feet - anchor;
        if (top_left[0] >= screen.width or top_left[1] >= screen.height or top_left[0] + size[0] <= 0 or top_left[1] + size[1] <= 0) return;

        //On screen, so every coordinate is well within i16 range
        const idx: u16 = @intCast(self.len);
        self.items[idx] = .{ .x = @intCast(top_left[0]), .y = @intCast(top_left[1]), .frame = frame.index, .sheet = sheet, .flipped = frame.flipped };
        const depth: u16 = @intCast(feet[1] + std.math.maxInt(i16));
        self.keys[idx] = (@as(SortKey, depth) << 16) | idx;
        self.len += 1;
    }
};

/// Which phase variant to draw for a bitmap whose left column lands on screen column `x` and top row on `y`
/// (see Assets.kit_pieces)
fn phaseAt(x: i32, y: i32) usize {
    return @intCast((x & 1) | ((y & 1) << 1));
}

/// A level object's bitmap, in the phase that matches where it lands. Mirrored, its left column on screen is its
/// last one, so its phase follows the right edge
fn envBitmap(assets: *const Assets, kit: u8, item: DrawItem) *pd.LCDBitmap {
    const piece = kit_descs.KITS[kit].pieces[item.frame];
    const x: i32 = @as(i32, item.x) + if (item.flipped) @as(i32, piece.w) - 1 else 0;
    return assets.kit_pieces[kit][item.frame][phaseAt(x, item.y)];
}

fn sheetSize(sheet: Sheet) Vec2i {
    return switch (sheet) {
        .player, .gun, .melee => .{ bitmap_descs.HERO_W, bitmap_descs.HERO_H },
        .runner, .walker, .shambler, .brute => .{ enemyCell(sheet)[0], enemyCell(sheet)[1] },
        .env => unreachable, //Per piece: kit_descs
        .drop => .{ bitmap_descs.DROP_W, bitmap_descs.DROP_H },
        .gibs_runner, .gibs_walker, .gibs_shambler, .gibs_brute => @splat(@intCast(bitmap_descs.GIB_CELLS[@backingInt(sheet) - @backingInt(Sheet.gibs_runner)])),
        .pool => .{ bitmap_descs.SPLAT_W, bitmap_descs.SPLAT_H },
        .spatter => .{ bitmap_descs.SPATTER_W, bitmap_descs.SPATTER_H },
    };
}

/// Draw a sheet's frame with its `centre` pixel at `at`, unless it is off screen
fn drawCentred(graphics: pd.playdate_graphics, assets: *const Assets, screen: Screen, sheet: Sheet, frame: u8, at: Vec2i) void {
    const size = sheetSize(sheet);
    const top_left = at - @divTrunc(size, Vec2i{ 2, 2 });
    if (top_left[0] >= screen.width or top_left[1] >= screen.height or top_left[0] + size[0] <= 0 or top_left[1] + size[1] <= 0) return;
    const bitmap = graphics.getTableBitmap.?(assets.tables[@backingInt(sheet)], frame) orelse @panic("render: Bitmap index out of range for its table");
    graphics.drawBitmap.?(bitmap, top_left[0], top_left[1], pd.kBitmapUnflipped);
}

/// Gib `i`, `lift_px` above the point on the ground under it
fn drawGib(graphics: pd.playdate_graphics, assets: *const Assets, screen: Screen, gibs: *const state.Gibs, i: usize, lift_px: i32) void {
    const frame = anim.gibFrame(@backingInt(gibs.part[i]), gibs.rot[i], gibs.fade[i]);
    drawCentred(graphics, assets, screen, gibSheet(gibs.kind[i]), frame, screen.toScreen(gibs.pos[i]) - Vec2i{ 0, lift_px });
}

/// Pools or spatters that haven't faded out, thinning while they fade
fn drawSplats(graphics: pd.playdate_graphics, assets: *const Assets, screen: Screen, sheet: Sheet, pos: []const Vec2f, fade: []const f32, variant: []const u8) void {
    for (pos, fade, variant) |p, f, v| {
        if (f >= consts.SPLAT_FADE_TIME) continue;
        drawCentred(graphics, assets, screen, sheet, @intCast(v * bitmap_descs.SPLAT_FADES + anim.splatFade(f)), screen.toScreen(p));
    }
}

/// Pixel in a character's cell that sits on its feet
fn sheetAnchor(sheet: Sheet) Vec2i {
    return switch (sheet) {
        .runner, .walker, .shambler, .brute => .{ enemyCell(sheet)[2], enemyCell(sheet)[3] },
        else => .{ bitmap_descs.HERO_ANCHOR_X, bitmap_descs.HERO_ANCHOR_Y },
    };
}

fn enemyCell(sheet: Sheet) [4]i32 {
    const cell = bitmap_descs.ENEMY_CELLS[@backingInt(sheet) - @backingInt(Sheet.runner)];
    return .{ @intCast(cell[0]), @intCast(cell[1]), @intCast(cell[2]), @intCast(cell[3]) };
}

/// 8x8 dither patterns for the fading tracer tail: 8 rows of image (1 = white) then 8 rows of mask
const PATTERN_HALF: pd.LCDPattern = .{ 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
/// Ground shadows: black on every other pixel, the ground showing through the rest (the mask rows are the checker)
const PATTERN_SHADOW: pd.LCDPattern = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 };
const PATTERN_QUARTER: pd.LCDPattern = .{ 0xEE, 0xBB, 0xEE, 0xBB, 0xEE, 0xBB, 0xEE, 0xBB, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

/// Draw a bullet as a comet: a solid head fading through 50% then 25% dither towards the tail, over a white
/// glow so it reads on the dark enemies as well as the light ground
///
fn drawTracer(graphics: pd.playdate_graphics, head: Vec2i, tail: Vec2i) void {
    const front = lerpPoint(head, tail, 0.33);
    const back = lerpPoint(head, tail, 0.66);
    graphics.drawLine.?(tail[0], tail[1], head[0], head[1], 7, pd.kColorWhite);
    graphics.drawLine.?(tail[0], tail[1], back[0], back[1], 3, @intFromPtr(&PATTERN_QUARTER));
    graphics.drawLine.?(back[0], back[1], front[0], front[1], 4, @intFromPtr(&PATTERN_HALF));
    graphics.drawLine.?(front[0], front[1], head[0], head[1], 4, pd.kColorBlack);
    graphics.fillEllipse.?(head[0] - 3, head[1] - 3, 6, 6, 0, 360, pd.kColorBlack);
}

/// The muzzle flash's spikes as (along the aim, across it) times its length: a long one forward, two shorter
/// diagonals and two stubs to the sides
const FLASH_SPIKES = [_]Vec2f{ .{ 1, 0 }, .{ 0.6, 0.5 }, .{ 0.6, -0.5 }, .{ 0.1, 0.45 }, .{ 0.1, -0.45 } };
/// Forward spike length in pixels by barrel, so a burst's flashes differ as the barrels turn
const FLASH_LENGTHS = [_]f32{ 18, 13, 15 };

/// A starburst at `at` pointing along `aim` (world, unit length): a black outline round a white core so it shows on
/// the light ground and the dark zombies alike. It shrinks as `life` runs from 1 down to 0
///
fn drawMuzzleFlash(graphics: pd.playdate_graphics, at: Vec2i, aim: Vec2f, barrel: u8, life: f32) void {
    const fwd = Vec2f{ aim[0], -aim[1] }; //Screen y is down
    const side = Vec2f{ -fwd[1], fwd[0] };
    const c: Vec2f = @floatFromInt(at);
    const length = FLASH_LENGTHS[barrel % FLASH_LENGTHS.len] * (0.5 + 0.5 * life);
    //Black then white over it, each spike a triangle from a base across its root
    for ([_]struct { scale: f32, half_w: f32, colour: pd.LCDColor }{ .{ .scale = 1, .half_w = 4, .colour = pd.kColorBlack }, .{ .scale = 0.75, .half_w = 2.5, .colour = pd.kColorWhite } }) |pass| {
        for (FLASH_SPIKES) |s| {
            const d = fwd * @as(Vec2f, @splat(s[0])) + side * @as(Vec2f, @splat(s[1]));
            const n = maths.normaliseSafe(d, fwd);
            const across = Vec2f{ -n[1], n[0] } * @as(Vec2f, @splat(pass.half_w));
            const tip: Vec2i = @intFromFloat(@round(c + d * @as(Vec2f, @splat(length * pass.scale))));
            const a: Vec2i = @intFromFloat(@round(c + across));
            const b: Vec2i = @intFromFloat(@round(c - across));
            graphics.fillTriangle.?(a[0], a[1], b[0], b[1], tip[0], tip[1], pass.colour);
        }
        const r: i32 = @intFromFloat(@round(pass.half_w * 1.5));
        graphics.fillEllipse.?(at[0] - r, at[1] - r, 2 * r, 2 * r, 0, 360, pass.colour);
    }
}

fn lerpPoint(a: Vec2i, b: Vec2i, t: f32) Vec2i {
    const af: Vec2f = @floatFromInt(a);
    const bf: Vec2f = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * @as(Vec2f, @splat(t))));
}
