const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const bullet_sys = @import("bullet_system.zig");
const anim = @import("animation.zig");
const bitmap_descs = @import("bitmap_descs.zig");
const consts = @import("tweak_constants.zig");

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

const MAX_ENTITIES: u32 = 200;

pub const RenderCommandData = struct {
    bitmap_table: *pd.LCDBitmapTable,
    bitmap_idx: c_int,
    width_offset: i32,
    height_offset: i32,
    flip: pd.LCDBitmapFlip,
};

var playdate_api: *pd.PlaydateAPI = undefined;

var bg_bitmap: *pd.LCDBitmap = undefined;
var player_bitmap_table: *pd.LCDBitmapTable = undefined;
var enemy_bitmap_table: *pd.LCDBitmapTable = undefined;
var env_obj_bitmap_table: *pd.LCDBitmapTable = undefined;

var render_command_sort_order: [MAX_ENTITIES]u8 = undefined;
var render_command_data_buffer: [MAX_ENTITIES]RenderCommandData = undefined;

var player_hit_flash_timer: ?f32 = null;

/// Setup
///
pub fn init(pd_api: *pd.PlaydateAPI) void {
    playdate_api = pd_api;
}

/// Called on restart
///
pub fn reset() void {
    player_hit_flash_timer = null;
    playdate_api.graphics.*.setDrawMode.?(pd.kDrawModeCopy);
}

/// Load the rendering assets - bitmaps and bitmap tables
///
pub fn loadAssets(level_bitmap_name: [*c]const u8) void {
    const graphics = playdate_api.graphics.*;

    bg_bitmap = graphics.loadBitmap.?("bg", null).?;
    player_bitmap_table = graphics.loadBitmapTable.?("hero1", null).?;
    enemy_bitmap_table = graphics.loadBitmapTable.?("enemy1", null).?;
    env_obj_bitmap_table = graphics.loadBitmapTable.?(level_bitmap_name, null).?;
}

/// Toggle on the hit flash effect for the given duration
///
pub fn playerHitFlash(duration: f32) void {
    player_hit_flash_timer = duration;
    playdate_api.graphics.*.setDrawMode.?(pd.kDrawModeInverted);
}

/// Run any time based effects
///
pub fn update(dt: f32) void {
    if (player_hit_flash_timer) |*timer| {
        timer.* -= dt;
        if (timer.* <= 0.0) {
            player_hit_flash_timer = null;
            playdate_api.graphics.*.setDrawMode.?(pd.kDrawModeCopy);
        }
    }
}

/// Perform the transformations from world to screen space and render the bitmaps
/// Sorting them by "depth order"
/// TODO: Build the render command data elsewhere?
///
pub fn render(
    camera_pos: Vec2f,
    player_world_pos: Vec2f,
    player_facing_dir: Vec2f,
    enemy_world_positions: []const Vec2f,
    enemy_velocities: []const Vec2f,
    env_obj_world_positions: []const Vec2f,
    env_obj_bitmap_indices: []const u8,
    player_score: u64,
    player_health: u8,
    bullets_remaining: u32,
) void {
    const sys = playdate_api.system.*;
    const disp = playdate_api.display.*;
    const graphics = playdate_api.graphics.*;

    const dispWidth = disp.getWidth.?();
    const dispHeight = disp.getHeight.?();

    graphics.clear.?(pd.kColorWhite);

    //---Render the BG
    const bg_world_pos = [_]Vec2f{Vec2f{ 0, 0 }};
    var bg_screen_pos: [1]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, bg_world_pos[0..], bg_screen_pos[0..], dispWidth, dispHeight);
    graphics.tileBitmap.?(bg_bitmap, bg_screen_pos[0][0] - 1000, bg_screen_pos[0][1] - 1000, 2000, 2000, pd.kBitmapUnflipped);

    //---Transform the entities to screen space
    var entity_screen_pos: [MAX_ENTITIES]Vec2i = undefined;
    var buffer_start: usize = 0;
    var buffer_end: usize = 1;

    const player_world_positions = [_]Vec2f{player_world_pos};
    graphics_coords.worldSpaceToScreenSpace(camera_pos, player_world_positions[0..], entity_screen_pos[buffer_start..buffer_end], dispWidth, dispHeight);
    buffer_start = buffer_end;
    buffer_end += enemy_world_positions.len;

    graphics_coords.worldSpaceToScreenSpace(camera_pos, enemy_world_positions[0..], entity_screen_pos[buffer_start..buffer_end], dispWidth, dispHeight);
    buffer_start = buffer_end;
    buffer_end += env_obj_world_positions.len;

    graphics_coords.worldSpaceToScreenSpace(camera_pos, env_obj_world_positions[0..], entity_screen_pos[buffer_start..buffer_end], dispWidth, dispHeight);

    //---Build the render commands for the player and enemies
    const player_bitmap_frame = anim.bitmapFrameForDir(player_facing_dir);
    render_command_data_buffer[0] = RenderCommandData{
        .bitmap_table = player_bitmap_table,
        .bitmap_idx = player_bitmap_frame.index,
        .flip = player_bitmap_frame.flip,
        .width_offset = bitmap_descs.CHAR_W / 2,
        .height_offset = @intCast(i32, bitmap_descs.CHAR_H) - anim.walkBobAnim(player_world_pos),
    };

    var enemy_bitmap_frames: [consts.MAX_ENEMIES]anim.BitmapFrame = undefined; //Enemies facing the way they are moving
    for (enemy_velocities) |v, i| {
        enemy_bitmap_frames[i] = anim.bitmapFrameForDir(v);
    }
    for (enemy_world_positions) |p, i| {
        render_command_data_buffer[i + 1] = RenderCommandData{
            .bitmap_table = enemy_bitmap_table,
            .bitmap_idx = enemy_bitmap_frames[i].index,
            .flip = enemy_bitmap_frames[i].flip,
            .width_offset = bitmap_descs.CHAR_W / 2,
            .height_offset = @intCast(i32, bitmap_descs.CHAR_H) - anim.walkBobAnim(p),
        };
    }

    const offset = enemy_world_positions.len + 1;
    for (env_obj_bitmap_indices) |bi, i| {
        render_command_data_buffer[i + offset] = RenderCommandData{
            .bitmap_table = env_obj_bitmap_table,
            .bitmap_idx = bi,
            .flip = pd.kBitmapUnflipped,
            .width_offset = bitmap_descs.ENV_OBJ_W / 2,
            .height_offset = bitmap_descs.ENV_OBJ_H,
        };
    }

    //---Sort by "depth", really the y-axis. To keep sorting fast we sort indices rather than render data
    var sorted_indices = render_command_sort_order[0..buffer_end];
    for (sorted_indices) |_, i| {
        sorted_indices[i] = @intCast(u8, i);
    }
    std.sort.sort(u8, sorted_indices, entity_screen_pos[0..buffer_end], compareBackToFront);

    //---Render the entities
    for (sorted_indices) |idx| {
        const rd = render_command_data_buffer[idx];
        graphics.drawBitmap.?(graphics.getTableBitmap.?(rd.bitmap_table, rd.bitmap_idx).?, entity_screen_pos[idx][0] - rd.width_offset, entity_screen_pos[idx][1] - rd.height_offset, rd.flip);
    }

    //TODO: Interleave bullets
    bullet_sys.render(graphics, disp, camera_pos);

    //TODO: Replace with bitmap font
    var score_buffer: ["Score: ".len + 10]u8 = undefined;
    const score_string = std.fmt.bufPrint(&score_buffer, "Score: {d}", .{player_score}) catch @panic("scorePrint: Failed to format");
    _ = graphics.drawText.?(score_string.ptr, score_string.len, pd.kASCIIEncoding, dispWidth - 100, 0);

    var health_buffer: ["Health: ".len + 3]u8 = undefined;
    const health_string = std.fmt.bufPrint(&health_buffer, "Health: {d}", .{player_health}) catch @panic("healthPrint: Failed to format");
    _ = graphics.drawText.?(health_string.ptr, health_string.len, pd.kASCIIEncoding, @divTrunc(dispWidth, 2), 0);

    var bullet_buffer: ["Bullets: ".len + 3]u8 = undefined;
    const bullet_string = std.fmt.bufPrint(&bullet_buffer, "Bullets: {d}", .{bullets_remaining}) catch @panic("bulletPrint: Failed to format");
    _ = graphics.drawText.?(bullet_string.ptr, bullet_string.len, pd.kASCIIEncoding, @divTrunc(dispWidth, 2), dispHeight - 30);

    sys.drawFPS.?(0, 0);
}

/// Used for depth sorting of an index list against the screen positions
///
fn compareBackToFront(screen_positions: []const Vec2i, a: u8, b: u8) bool {
    return screen_positions[a][1] <= screen_positions[b][1];
}
