const std = @import("std");
const pd = @import("playdate.zig").api;
const consts = @import("tweak_constants.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const Arena = @import("memory.zig").Arena;

const Vec2f = @Vector(2, f32);
const Vec2i = @Vector(2, i32);

/// Size of drop a level drop point gives (the reward, and the risk of where it is placed)
///
pub const DropSize = enum(u8) { small, large };

/// Which edge of the map a spawn cell is on (north is the top row). Waves come in from one or two of these
///
pub const MapSide = enum(u8) { north, east, south, west };
pub const NUM_SIDES = std.enums.values(MapSide).len;

/// The spawn cells, grouped by side: `sides[s]` are slices of `all`
///
pub const SpawnCells = struct {
    all: []const u16,
    sides: [NUM_SIDES][]const u16,
};

/// Everything loaded for a level. All slices live in the level arena
///
pub const Level = struct {
    obj_world_positions: []const Vec2f,
    obj_bitmap_indices: []const u8,
    collision_grid: CollisionGrid,
    spawn_cells: SpawnCells, //Free cells around the edge of the map that enemies drop in on
    drop_cells: []const u16, //Free cells ammo and health drops appear on, placed by the level designer
    drop_sizes: []const DropSize, //Size of drop each of `drop_cells` gives
    bg_size_pixels: Vec2i,
};

pub const Error = error{
    FileOpenFailed,
    FileReadFailed,
    TruncatedHeader,
    TruncatedObject,
    TruncatedDrops,
    InvalidDropSize,
    DropOnBlockedCell,
    EmptyGrid,
    CellOutOfRange,
    InvalidSpriteId,
};

const HEADER_SIZE = 5;
const DROP_SIZE = 3;
const OBJ_SIZE = 3;

/// Read the level file into the level arena and parse it
///
pub fn load(playdate_api: *pd.PlaydateAPI, level_file_name: [*:0]const u8, arena: *Arena) Error!Level {
    const file = playdate_api.file.*;

    var stat: pd.FileStat = undefined;
    if (file.stat.?(level_file_name, &stat) != 0) return Error.FileOpenFailed;

    const lvl_file = file.open.?(level_file_name, pd.kFileRead) orelse return Error.FileOpenFailed;
    defer _ = file.close.?(lvl_file);

    const bytes = arena.alloc(u8, stat.size);
    var read_len: usize = 0;
    while (read_len < bytes.len) {
        const n = file.read.?(lvl_file, bytes[read_len..].ptr, @intCast(bytes.len - read_len));
        if (n <= 0) return Error.FileReadFailed;
        read_len += @intCast(n);
    }

    return parse(bytes, arena);
}

/// Parse the level binary (see convert_tilemaps.py) converting the cell co-ords into world positions,
/// and build the bitmap table indices and collision grid.
/// Format: u8 grid width, u8 grid height, u8 cell width px, u8 cell height px, u8 drop point count,
/// then per drop point: u16 LE cell index, u8 size (`DropSize`),
/// then per object until the end: u16 LE cell index, u8 sprite id (1 based)
///
pub fn parse(bytes: []const u8, arena: *Arena) Error!Level {
    if (bytes.len < HEADER_SIZE) return Error.TruncatedHeader;
    const grid_width = bytes[0];
    const grid_height = bytes[1];
    const cell_width = bytes[2];
    const cell_height = bytes[3];
    if (grid_width == 0 or grid_height == 0 or cell_width == 0 or cell_height == 0) return Error.EmptyGrid;

    const num_drops: usize = bytes[4];
    if (bytes.len < HEADER_SIZE + num_drops * DROP_SIZE) return Error.TruncatedDrops;
    const drop_bytes = bytes[HEADER_SIZE..][0 .. num_drops * DROP_SIZE];

    const obj_bytes = bytes[HEADER_SIZE + drop_bytes.len ..];
    if (obj_bytes.len % OBJ_SIZE != 0) return Error.TruncatedObject;
    const num_objs = obj_bytes.len / OBJ_SIZE;
    const num_cells = @as(usize, grid_width) * grid_height;

    const world_positions = arena.alloc(Vec2f, num_objs);
    const bitmap_indices = arena.alloc(u8, num_objs);
    const cells = arena.alloc(bool, num_cells);
    @memset(cells, false);

    const half_w: i32 = grid_width / 2;
    const half_h: i32 = grid_height / 2;
    for (0..num_objs) |i| {
        const obj = obj_bytes[i * OBJ_SIZE ..][0..OBJ_SIZE];
        const idx = std.mem.readInt(u16, obj[0..2], .little);
        if (idx >= num_cells) return Error.CellOutOfRange;
        const sprite_id = obj[2];
        if (sprite_id == 0) return Error.InvalidSpriteId;

        cells[idx] = true;
        const x = @as(i32, idx % grid_width) - half_w;
        const y = @as(i32, idx / grid_width) - half_h;
        world_positions[i] = Vec2f{ @floatFromInt(x * cell_width), @floatFromInt(-y * cell_height) } / @as(Vec2f, @splat(consts.METRES_TO_PIXELS));
        bitmap_indices[i] = sprite_id - 1;
    }

    //Drop points come after the objects are placed, so they can be checked against the collision
    const drop_cells = arena.alloc(u16, num_drops);
    const drop_sizes = arena.alloc(DropSize, num_drops);
    for (0..num_drops) |i| {
        const drop = drop_bytes[i * DROP_SIZE ..][0..DROP_SIZE];
        const idx = std.mem.readInt(u16, drop[0..2], .little);
        if (idx >= num_cells) return Error.CellOutOfRange;
        if (cells[idx]) return Error.DropOnBlockedCell;
        drop_cells[i] = idx;
        drop_sizes[i] = std.enums.fromInt(DropSize, drop[2]) orelse return Error.InvalidDropSize;
    }

    const grid = CollisionGrid{
        .cells = cells,
        .width = grid_width,
        .height = grid_height,
        .cell_width = cell_width,
        .cell_height = cell_height,
    };
    return Level{
        .obj_world_positions = world_positions,
        .obj_bitmap_indices = bitmap_indices,
        .collision_grid = grid,
        .spawn_cells = findSpawnCells(&grid, arena),
        .drop_cells = drop_cells,
        .drop_sizes = drop_sizes,
        .bg_size_pixels = Vec2i{ @as(i32, grid_width) * cell_width * 2, @as(i32, grid_height) * cell_height * 2 },
    };
}

/// The free cells within SPAWN_EDGE_BAND metres of the edge of the map, so the horde arrives from the
/// sides rather than out of thin air next to the player, grouped by the side they are on so a wave can
/// come from one direction. Built once at load (two passes: count per side, then fill)
///
pub fn findSpawnCells(grid: *const CollisionGrid, arena: *Arena) SpawnCells {
    const band_px = consts.SPAWN_EDGE_BAND * consts.METRES_TO_PIXELS;
    const band_x: u32 = @max(1, @as(u32, @intFromFloat(@ceil(band_px / @as(f32, @floatFromInt(grid.cell_width))))));
    const band_y: u32 = @max(1, @as(u32, @intFromFloat(@ceil(band_px / @as(f32, @floatFromInt(grid.cell_height))))));

    var counts: [NUM_SIDES]usize = @splat(0);
    for (0..grid.cells.len) |i| {
        if (spawnSide(grid, i, band_x, band_y)) |side| counts[@backingInt(side)] += 1;
    }
    var total: usize = 0;
    for (counts) |c| total += c;
    const all = arena.alloc(u16, total);

    var result = SpawnCells{ .all = all, .sides = undefined };
    var next: [NUM_SIDES]usize = undefined;
    var start: usize = 0;
    for (counts, 0..) |c, s| {
        result.sides[s] = all[start .. start + c];
        next[s] = start;
        start += c;
    }
    for (0..grid.cells.len) |i| {
        const side = spawnSide(grid, i, band_x, band_y) orelse continue;
        all[next[@backingInt(side)]] = @intCast(i);
        next[@backingInt(side)] += 1;
    }
    return result;
}

/// The side of the map a free cell in the edge band is on, or null if it isn't a spawn cell. In the corners,
/// whichever edge is nearer (measured in bands, as cells needn't be square)
///
fn spawnSide(grid: *const CollisionGrid, i: usize, band_x: u32, band_y: u32) ?MapSide {
    if (grid.cells[i]) return null;
    const x: u32 = @intCast(i % grid.width);
    const y: u32 = @intCast(i / grid.width);
    const from_x_edge = @min(x, grid.width - 1 - x);
    const from_y_edge = @min(y, grid.height - 1 - y);
    if (from_x_edge >= band_x and from_y_edge >= band_y) return null;
    //Compare from_y_edge / band_y with from_x_edge / band_x without dividing
    if (from_y_edge * band_x <= from_x_edge * band_y) {
        return if (y < grid.height / 2) .north else .south;
    }
    return if (x < grid.width / 2) .west else .east;
}

test "[level_loader] spawn cells are the free cells around the edge" {
    var buffer: [256]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    //6x6 grid of 128px (1m) cells: a 1 cell band, with one blocked edge cell
    var cells: [36]bool = @splat(false);
    cells[1] = true;
    const grid = CollisionGrid{ .cells = &cells, .width = 6, .height = 6, .cell_width = 128, .cell_height = 128 };
    const spawn = findSpawnCells(&grid, &arena);

    try std.testing.expect(spawn.all.len == 20 - 1);
    var grouped: usize = 0;
    for (spawn.sides, 0..) |side_cells, s| {
        grouped += side_cells.len;
        for (side_cells) |c| {
            const x = c % 6;
            const y = c / 6;
            switch (@as(MapSide, @fromBackingInt(@intCast(s)))) {
                .north => try std.testing.expect(y == 0),
                .south => try std.testing.expect(y == 5),
                .west => try std.testing.expect(x == 0 and y > 0 and y < 5),
                .east => try std.testing.expect(x == 5 and y > 0 and y < 5),
            }
        }
    }
    try std.testing.expect(grouped == spawn.all.len);
    for (spawn.all) |c| {
        try std.testing.expect(!cells[c]);
        const x = c % 6;
        const y = c / 6;
        try std.testing.expect(x == 0 or y == 0 or x == 5 or y == 5);
    }
}

test "[level_loader] parse objects and collision" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    //4x4 grid of 128px cells, a large drop point in cell 5, an object in cell 0 (top left) with sprite 2
    const bytes = [_]u8{ 4, 4, 128, 128, 1, 5, 0, 1, 0, 0, 2 };
    const level = try parse(&bytes, &arena);

    try std.testing.expect(level.obj_world_positions.len == 1);
    try std.testing.expect(level.obj_bitmap_indices[0] == 1);
    try std.testing.expect(level.obj_world_positions[0][0] == -2 and level.obj_world_positions[0][1] == 2);
    try std.testing.expect(level.collision_grid.isOccupied(level.obj_world_positions[0]));
    try std.testing.expect(!level.collision_grid.isOccupied(Vec2f{ 0, 0 }));
    try std.testing.expect(level.spawn_cells.all.len == 12 - 1); //The edge of a 4x4 grid, minus the object
    try std.testing.expect(level.drop_cells.len == 1 and level.drop_cells[0] == 5 and level.drop_sizes[0] == .large);
}

test "[level_loader] parse rejects bad input" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    try std.testing.expectError(Error.TruncatedHeader, parse(&[_]u8{ 4, 4 }, &arena));
    try std.testing.expectError(Error.TruncatedHeader, parse(&[_]u8{ 4, 4, 128, 128 }, &arena));
    try std.testing.expectError(Error.EmptyGrid, parse(&[_]u8{ 0, 4, 128, 128, 0 }, &arena));
    try std.testing.expectError(Error.TruncatedObject, parse(&[_]u8{ 4, 4, 128, 128, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.CellOutOfRange, parse(&[_]u8{ 4, 4, 128, 128, 0, 16, 0, 1 }, &arena));
    try std.testing.expectError(Error.InvalidSpriteId, parse(&[_]u8{ 4, 4, 128, 128, 0, 1, 0, 0 }, &arena));
    try std.testing.expectError(Error.TruncatedDrops, parse(&[_]u8{ 4, 4, 128, 128, 2, 5, 0, 0 }, &arena));
    try std.testing.expectError(Error.CellOutOfRange, parse(&[_]u8{ 4, 4, 128, 128, 1, 16, 0, 0 }, &arena));
    try std.testing.expectError(Error.InvalidDropSize, parse(&[_]u8{ 4, 4, 128, 128, 1, 5, 0, 2 }, &arena));
    try std.testing.expectError(Error.DropOnBlockedCell, parse(&[_]u8{ 4, 4, 128, 128, 1, 0, 0, 0, 0, 0, 1 }, &arena));
}
