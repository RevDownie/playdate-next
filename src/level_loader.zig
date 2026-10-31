const std = @import("std");
const consts = @import("tweak_constants.zig");
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;
const Arena = @import("memory.zig").Arena;
const kit_descs = @import("kit_descs.zig");

const Vec2f = @Vector(2, f32);

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

/// Set in an object's piece byte when it is drawn mirrored
pub const PIECE_FLIPPED: u8 = 0x80;

/// Everything loaded for a level. All slices live in the level arena
///
pub const Level = struct {
    kit: u8, //Index into kit_descs.KITS: the environment the objects are drawn from
    start_pos: Vec2f, //Where the player starts a run: the centre of the start cell
    obj_world_positions: []const Vec2f, //Centre of each object's anchor cell (the bottom-left of its footprint)
    obj_pieces: []const u8, //Piece index into its kit, PIECE_FLIPPED if mirrored
    collision_grid: CollisionGrid,
    spawn_cells: SpawnCells, //Free cells around the edge of the map that enemies drop in on
    drop_cells: []const u16, //Free cells ammo and health drops appear on, placed by the level designer
    drop_sizes: []const DropSize, //Size of drop each of `drop_cells` gives
};

pub const Error = error{
    TruncatedHeader,
    TruncatedObject,
    TruncatedDrops,
    InvalidDropSize,
    DropOnBlockedCell,
    EmptyGrid,
    CellOutOfRange,
    InvalidSpriteId,
    InvalidKit,
    TruncatedCells,
    StartOnBlockedCell,
    WrongCellSize,
};

const HEADER_SIZE = 8;
const DROP_SIZE = 3;
const OBJ_SIZE = 3;

/// Parse the level binary (see convert_tilemaps.py; main reads the file) into `arena`, converting the cell
/// co-ords into world positions and building the collision grid. Nothing keeps hold of `bytes`.
/// Format: u8 grid width, u8 grid height, u8 cell width px, u8 cell height px, u8 kit, u8 drop point count,
/// u16 LE player start cell, then per drop point: u16 LE cell index, u8 size (`DropSize`),
/// then the blocked cells as a bitmask (bit i % 8 of byte i / 8: the objects' footprints),
/// then per object until the end: u16 LE anchor cell index, u8 piece index (PIECE_FLIPPED if mirrored)
///
pub fn parse(bytes: []const u8, arena: *Arena) Error!Level {
    if (bytes.len < HEADER_SIZE) return Error.TruncatedHeader;
    const grid_width = bytes[0];
    const grid_height = bytes[1];
    const cell_width = bytes[2];
    const cell_height = bytes[3];
    const kit = bytes[4];
    if (grid_width == 0 or grid_height == 0 or cell_width == 0 or cell_height == 0) return Error.EmptyGrid;
    if (kit >= kit_descs.KITS.len) return Error.InvalidKit;
    //The pieces and the baked floor are drawn for this cell size only
    if (cell_width != kit_descs.CELL_W or cell_height != kit_descs.CELL_H) return Error.WrongCellSize;

    const num_drops: usize = bytes[5];
    const start_cell = std.mem.readInt(u16, bytes[6..8], .little);
    if (bytes.len < HEADER_SIZE + num_drops * DROP_SIZE) return Error.TruncatedDrops;
    const drop_bytes = bytes[HEADER_SIZE..][0 .. num_drops * DROP_SIZE];

    const num_cells = @as(usize, grid_width) * grid_height;
    const mask_len = (num_cells + 7) / 8;
    if (bytes.len < HEADER_SIZE + drop_bytes.len + mask_len) return Error.TruncatedCells;
    const mask = bytes[HEADER_SIZE + drop_bytes.len ..][0..mask_len];

    const obj_bytes = bytes[HEADER_SIZE + drop_bytes.len + mask_len ..];
    if (obj_bytes.len % OBJ_SIZE != 0) return Error.TruncatedObject;
    const num_objs = obj_bytes.len / OBJ_SIZE;

    const world_positions = arena.alloc(Vec2f, num_objs);
    const pieces = arena.alloc(u8, num_objs);
    const cells = arena.alloc(bool, num_cells);
    for (cells, 0..) |*c, i| c.* = mask[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;

    const grid = CollisionGrid{
        .cells = cells,
        .width = grid_width,
        .height = grid_height,
        .cell_width = cell_width,
        .cell_height = cell_height,
    };
    if (start_cell >= num_cells) return Error.CellOutOfRange;
    if (cells[start_cell]) return Error.StartOnBlockedCell;
    const num_pieces = kit_descs.KITS[kit].pieces.len;
    for (0..num_objs) |i| {
        const obj = obj_bytes[i * OBJ_SIZE ..][0..OBJ_SIZE];
        const idx = std.mem.readInt(u16, obj[0..2], .little);
        if (idx >= num_cells) return Error.CellOutOfRange;
        if (obj[2] & ~PIECE_FLIPPED >= num_pieces) return Error.InvalidSpriteId;
        world_positions[i] = grid.cellCentre(idx);
        pieces[i] = obj[2];
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

    return Level{
        .kit = kit,
        .start_pos = grid.cellCentre(start_cell),
        .obj_world_positions = world_positions,
        .obj_pieces = pieces,
        .collision_grid = grid,
        .spawn_cells = findSpawnCells(&grid, arena),
        .drop_cells = drop_cells,
        .drop_sizes = drop_sizes,
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

test "[level_loader] parse objects, footprints and collision" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    //4x4 grid of the levels' cells, kit 0, the player starting in cell 6, a large drop point in cell 5. A mirrored 2x2
    //piece placed on cell 12 (column 0 of the bottom row: its footprint's bottom-left) whose footprint, extending
    //right and up, blocks 8, 9, 12 and 13
    const bytes = [_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 1, 6, 0, 5, 0, 1, 0b0000_0000, 0b0011_0011, 12, 0, 1 | PIECE_FLIPPED };
    const level = try parse(&bytes, &arena);
    const cell_m = Vec2f{ @floatFromInt(kit_descs.CELL_W), @floatFromInt(kit_descs.CELL_H) } / @as(Vec2f, @splat(consts.METRES_TO_PIXELS));

    try std.testing.expect(level.kit == 0);
    try std.testing.expect(level.start_pos[0] == 0 and level.start_pos[1] == cell_m[1]); //Cell 6: column 2, row 1
    try std.testing.expect(level.obj_world_positions.len == 1);
    try std.testing.expect(level.obj_pieces[0] == 1 | PIECE_FLIPPED);
    //Its position is its anchor cell's centre: column 0, row 3 of a 4x4 grid centred on the origin
    try std.testing.expect(level.obj_world_positions[0][0] == -2 * cell_m[0] and level.obj_world_positions[0][1] == -cell_m[1]);
    const grid = &level.collision_grid;
    for ([_]u16{ 8, 9, 12, 13 }) |c| try std.testing.expect(grid.cells[c]);
    var blocked: usize = 0;
    for (grid.cells) |c| blocked += @intFromBool(c);
    try std.testing.expect(blocked == 4);
    try std.testing.expect(grid.isOccupied(level.obj_world_positions[0]));
    try std.testing.expect(grid.isOccupied(level.obj_world_positions[0] + cell_m)); //Up and right: cell 9
    try std.testing.expect(!grid.isOccupied(Vec2f{ 0, 0 }));
    //The edge band (SPAWN_EDGE_BAND) is wider than this grid in level cells, so every free cell is a spawn cell
    try std.testing.expect(level.spawn_cells.all.len == 16 - 4);
    try std.testing.expect(level.drop_cells.len == 1 and level.drop_cells[0] == 5 and level.drop_sizes[0] == .large);
}

test "[level_loader] parse rejects bad input" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    try std.testing.expectError(Error.TruncatedHeader, parse(&[_]u8{ 4, 4 }, &arena));
    try std.testing.expectError(Error.TruncatedHeader, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.EmptyGrid, parse(&[_]u8{ 0, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.InvalidKit, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, kit_descs.KITS.len, 0, 0, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.TruncatedCells, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.TruncatedObject, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 0, 0, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.CellOutOfRange, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 16, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.StartOnBlockedCell, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 0, 0, 1, 0 }, &arena));
    try std.testing.expectError(Error.CellOutOfRange, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 0, 0, 0, 0, 16, 0, 1 }, &arena));
    try std.testing.expectError(Error.InvalidSpriteId, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 0, 0, 0, 0, 0, 1, 0, 127 }, &arena));
    try std.testing.expectError(Error.TruncatedDrops, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 2, 0, 0, 5, 0, 0 }, &arena));
    try std.testing.expectError(Error.CellOutOfRange, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 1, 0, 0, 16, 0, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.InvalidDropSize, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 1, 0, 0, 5, 0, 2, 0, 0 }, &arena));
    try std.testing.expectError(Error.WrongCellSize, parse(&[_]u8{ 4, 4, 128, 128, 0, 0, 0, 0, 0, 0 }, &arena));
    try std.testing.expectError(Error.DropOnBlockedCell, parse(&[_]u8{ 4, 4, kit_descs.CELL_W, kit_descs.CELL_H, 0, 1, 2, 0, 0, 0, 0, 1, 0 }, &arena));
}
