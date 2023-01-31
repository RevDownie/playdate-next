const std = @import("std");
const pd = @import("playdate.zig").api;
const graphics_coords = @import("graphics_coords.zig");
const bullet_sys = @import("bullet_system.zig");
const anim = @import("animation.zig");
const bitmap_descs = @import("bitmap_descs.zig");
const consts = @import("tweak_constants.zig");

const Vec2i = @Vector(2, i32);
const Vec2f = @Vector(2, f32);

pub const RenderData = struct {
    bitmap_table: *pd.LCDBitmapTable,
    bitmap_idx: c_int,
    width_offset: i32,
    height_offset: i32,
    flip: pd.LCDBitmapFlip,
};

pub const MapRenderData = struct {
    bitmap_idx: c_int,
    world_pos: Vec2f,
};

var bg_bitmap: *pd.LCDBitmap = undefined;
var hero_bitmap_table: *pd.LCDBitmapTable = undefined;
var enemy_bitmap_table: *pd.LCDBitmapTable = undefined;
var lvl_bitmap_table: *pd.LCDBitmapTable = undefined;
pub var lvl_render_data: []MapRenderData = undefined;

/// Load the rendering assets - bitmaps and bitmap tables
///
pub fn loadAssets(playdate_api: *pd.PlaydateAPI) void {
    const graphics = playdate_api.graphics.*;

    bg_bitmap = graphics.loadBitmap.?("bg", null).?;
    hero_bitmap_table = graphics.loadBitmapTable.?("hero1", null).?;
    enemy_bitmap_table = graphics.loadBitmapTable.?("enemy1", null).?;
    lvl_bitmap_table = graphics.loadBitmapTable.?("lvl1", null).?;
}

/// Perform the transformations from world to screen space and render the bitmaps
/// Sorting them by "depth order"
///
pub fn render(playdate_api: *pd.PlaydateAPI, camera_pos: Vec2f, player_world_pos: Vec2f, player_facing_dir: Vec2f, enemy_world_positions: []const Vec2f, enemy_velocities: []const Vec2f, player_score: u64, player_health: u8, bullets_remaining: u32) void {
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

    //---Render the map obstacles and characters interleaved based on "depth"
    // var entity_screen_pos: [200]Vec2i = undefined;
    // var buffer_start: u32 = 0;
    // var buffer_end = enemy_world_positions.len;
    // graphics_coords.worldSpaceToScreenSpace(camera_pos, enemy_world_positions.toDataSlice(), entity_screen_pos[buffer_start..buffer_end], dispWidth, dispHeight);
    // buffer_start = buffer_end;
    // buffer_end += map_world_pos.len;
    // graphics_coords.worldSpaceToScreenSpace(camera_pos, map_world_pos[0..], entity_screen_pos[buffer_start..buffer_end], dispWidth, dispHeight);
    // buffer_start = buffer_end;
    // buffer_end += 1;
    // const player_world_pos_tmp = [_]Vec2f{player_world_pos};
    // graphics_coords.worldSpaceToScreenSpace(camera_pos, player_world_pos_tmp[0..], entity_screen_pos[buffer_start..buffer_end], dispWidth, dispHeight);

    // for() |rd| {
    //     graphics.drawBitmap.?(graphics.getTableBitmap.?(rd.bitmap_table, rd.bitmap_idx).?, entity_screen_pos[i][0] - rd.width_offset, entity_screen_pos[i][1] - rd.height_offset, rd.flip);
    // }

    //---Render the map obstacles
    for (lvl_render_data) |ld| {
        const map_world_pos = [_]Vec2f{ld.world_pos};
        var map_screen_pos: [1]Vec2i = undefined;
        graphics_coords.worldSpaceToScreenSpace(camera_pos, map_world_pos[0..], map_screen_pos[0..], dispWidth, dispHeight);
        graphics.drawBitmap.?(graphics.getTableBitmap.?(lvl_bitmap_table, ld.bitmap_idx).?, map_screen_pos[0][0] - (bitmap_descs.ENV_OBJ_W / 2), map_screen_pos[0][1] - bitmap_descs.ENV_OBJ_H, pd.kBitmapUnflipped);
    }

    //---Render the player
    const player_world_pos_tmp = [_]Vec2f{player_world_pos};
    var player_screen_pos: [1]Vec2i = undefined;
    const player_bitmap_frame = anim.bitmapFrameForDir(player_facing_dir);
    graphics_coords.worldSpaceToScreenSpace(camera_pos, player_world_pos_tmp[0..], player_screen_pos[0..], dispWidth, dispHeight);
    const player_h_offset = anim.walkBobAnim(player_world_pos);
    graphics.drawBitmap.?(graphics.getTableBitmap.?(hero_bitmap_table, player_bitmap_frame.index).?, player_screen_pos[0][0] - bitmap_descs.CHAR_W / 2, player_screen_pos[0][1] - bitmap_descs.CHAR_H - player_h_offset, player_bitmap_frame.flip);

    //---Render the enemies
    var enemy_screen_pos: [consts.MAX_ENEMIES]Vec2i = undefined;
    graphics_coords.worldSpaceToScreenSpace(camera_pos, enemy_world_positions, enemy_screen_pos[0..], dispWidth, dispHeight);

    //TODO: Interpolation
    //Enemies facing the way they are moving
    var enemy_bitmap_frames: [consts.MAX_ENEMIES]anim.BitmapFrame = undefined;
    for (enemy_velocities) |v, idx| {
        enemy_bitmap_frames[idx] = anim.bitmapFrameForDir(v);
    }

    for (enemy_world_positions) |p, i| {
        //TODO Culling (in a pass or just in time?)
        const h = anim.walkBobAnim(p);
        graphics.drawBitmap.?(graphics.getTableBitmap.?(enemy_bitmap_table, enemy_bitmap_frames[i].index).?, enemy_screen_pos[i][0] - bitmap_descs.CHAR_W / 2, enemy_screen_pos[i][1] - bitmap_descs.CHAR_H - h, enemy_bitmap_frames[i].flip);
    }

    bullet_sys.render(graphics, disp, camera_pos);

    sys.drawFPS.?(0, 0);

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
}
