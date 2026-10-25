const std = @import("std");
const memory = @import("memory.zig");
const Arena = memory.Arena;
const CollisionGrid = @import("collision_grid.zig").CollisionGrid;

const Vec2f = @Vector(2, f32);

// A flow field over the collision grid: every free cell stores the step to take towards the goal (the player's
// cell) along the shortest path around obstacles. One field serves every enemy, so pathfinding costs the same
// for 1 or 100 of them. It is rebuilt with Dijkstra whenever the player changes cell, spread over several
// frames (a fixed number of cells per frame) so the cost per frame is bounded. Enemies keep reading the last
// finished field (`dir`) while the next one is built into `building`, then the two are swapped.
//
// All buffers are allocated once from the level arena; nothing is allocated per frame.

/// Values of a cell in `FlowField.dir`. 0..7 index `FlowField.dir_vecs` (the step towards the goal)
pub const DIR_GOAL: u8 = 8; //The goal cell itself: seek the player directly
pub const DIR_UNREACHABLE: u8 = 9; //Free, but walled off from the goal
pub const DIR_BLOCKED: u8 = 10; //Occupied by the environment, or outside the grid

pub const NO_CELL: u16 = std.math.maxInt(u16);
const INF_DIST: u32 = std.math.maxInt(u32);

/// Neighbour offsets in cells, indexed by direction. Row 0 is the top of the map so +dy is world -y.
/// Even indices are straight steps, odd are diagonals; the opposite of direction k is (k + 4) % 8
const OFFSETS = [8][2]i8{ .{ 1, 0 }, .{ 1, -1 }, .{ 0, -1 }, .{ -1, -1 }, .{ -1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };

pub const FlowField = struct {
    //Read by the enemies every frame in random order: one byte per cell, see HOT_SET_BUDGET
    dir: []u8,
    dir_vecs: [8]Vec2f, //Unit world vector for each direction (cells aren't square, so these aren't 45 degrees)
    goal: u16 = NO_CELL, //The cell `dir` leads to

    //Build state, only touched while a rebuild is in progress
    building: []u8,
    dist: []u32, //Path cost from the goal in pixels
    heap: []u16, //Min-heap of cells to settle, keyed by `dist`
    heap_pos: []u16, //Where each cell is in `heap`, NO_CELL if it isn't
    heap_len: u32 = 0,
    build_goal: u16 = NO_CELL, //The cell being built for, NO_CELL when idle
    step_cost: [8]u32, //Pixel length of a step in each direction
    width: u8,

    /// Allocate the field for `grid` from the level arena and build it for `goal_cell` straight away, so it
    /// is valid from the first frame
    ///
    pub fn init(arena: *Arena, grid: *const CollisionGrid, goal_cell: ?u16) FlowField {
        const num_cells = grid.cells.len;
        std.debug.assert(num_cells < NO_CELL);
        const cw: f32 = @floatFromInt(grid.cell_width);
        const ch: f32 = @floatFromInt(grid.cell_height);
        const diag_cost: u32 = @intFromFloat(@round(@sqrt(cw * cw + ch * ch)));

        var field = FlowField{
            .dir = arena.alloc(u8, num_cells),
            .building = arena.alloc(u8, num_cells),
            .dist = arena.alloc(u32, num_cells),
            .heap = arena.alloc(u16, num_cells),
            .heap_pos = arena.alloc(u16, num_cells),
            .dir_vecs = undefined,
            .step_cost = undefined,
            .width = grid.width,
        };
        for (OFFSETS, 0..) |o, k| {
            const v = Vec2f{ @as(f32, @floatFromInt(o[0])) * cw, -@as(f32, @floatFromInt(o[1])) * ch };
            field.dir_vecs[k] = v / @as(Vec2f, @splat(@sqrt(v[0] * v[0] + v[1] * v[1])));
            field.step_cost[k] = if (k % 2 == 1) diag_cost else if (o[0] != 0) grid.cell_width else grid.cell_height;
        }
        for (field.dir, grid.cells) |*d, blocked| d.* = if (blocked) DIR_BLOCKED else DIR_UNREACHABLE;
        update(&field, grid, goal_cell, std.math.maxInt(u32));
        return field;
    }

    /// The direction value for `cell`, treating outside the grid as blocked
    ///
    pub inline fn at(self: *const FlowField, cell: ?u16) u8 {
        return if (cell) |c| self.dir[c] else DIR_BLOCKED;
    }

    /// The cell one step along the field from `cell`, which must hold a direction (0..7)
    ///
    pub inline fn nextCell(self: *const FlowField, cell: u16, dir: u8) u16 {
        const o = OFFSETS[dir];
        return @intCast(@as(i32, cell) + o[0] + @as(i32, o[1]) * self.width);
    }

    /// Can an enemy standing in `cell` path to the goal
    ///
    pub fn isReachable(self: *const FlowField, cell: ?u16) bool {
        return self.at(cell) <= DIR_GOAL;
    }

    /// Bytes the enemies read at random each frame (compare with memory.HOT_SET_BUDGET)
    ///
    pub fn hotSetBytes(self: *const FlowField) usize {
        return self.dir.len;
    }
};

/// Keep the field leading to `goal_cell`: start a rebuild when the goal has moved and no build is in
/// progress, then settle at most `budget` cells of it. A goal that moves mid-build is picked up by the
/// next build once this one is published, so a moving player can't starve the field
///
pub fn update(field: *FlowField, grid: *const CollisionGrid, goal_cell: ?u16, budget: u32) void {
    if (field.build_goal == NO_CELL) {
        const goal = goal_cell orelse return;
        if (goal == field.goal) return;
        startBuild(field, grid, goal);
    }

    var settled: u32 = 0;
    while (settled < budget and field.heap_len > 0) : (settled += 1) {
        relaxNeighbours(field, grid, popMin(field));
    }

    if (field.heap_len == 0) {
        std.mem.swap([]u8, &field.dir, &field.building);
        field.goal = field.build_goal;
        field.build_goal = NO_CELL;
    }
}

fn startBuild(field: *FlowField, grid: *const CollisionGrid, goal: u16) void {
    for (field.building, grid.cells) |*d, blocked| d.* = if (blocked) DIR_BLOCKED else DIR_UNREACHABLE;
    @memset(field.dist, INF_DIST);
    @memset(field.heap_pos, NO_CELL);
    field.heap_len = 0;
    field.build_goal = goal;
    field.dist[goal] = 0;
    field.building[goal] = DIR_GOAL;
    push(field, goal);
}

/// Offer each free neighbour of the settled cell `u` a path through it. Diagonal steps need both of the
/// cells beside them free, so paths never cut the corner of an obstacle
///
fn relaxNeighbours(field: *FlowField, grid: *const CollisionGrid, u: u16) void {
    const w: i32 = grid.width;
    const h: i32 = grid.height;
    const ux: i32 = u % grid.width;
    const uy: i32 = u / grid.width;
    const u_dist = field.dist[u];

    for (OFFSETS, 0..) |o, k| {
        const nx = ux + o[0];
        const ny = uy + o[1];
        if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
        const v: u16 = @intCast(ny * w + nx);
        if (grid.cells[v]) continue;
        if (k % 2 == 1 and (grid.cells[@intCast(uy * w + nx)] or grid.cells[@intCast(ny * w + ux)])) continue;

        const d = u_dist + field.step_cost[k];
        if (d >= field.dist[v]) continue;
        field.dist[v] = d;
        field.building[v] = @intCast((k + 4) % 8); //Step from v back towards u
        if (field.heap_pos[v] == NO_CELL) push(field, v) else siftUp(field, field.heap_pos[v]);
    }
}

fn push(field: *FlowField, cell: u16) void {
    const i = field.heap_len;
    field.heap[i] = cell;
    field.heap_len += 1;
    siftUp(field, i);
}

fn popMin(field: *FlowField) u16 {
    const top = field.heap[0];
    field.heap_pos[top] = NO_CELL;
    field.heap_len -= 1;
    if (field.heap_len > 0) {
        field.heap[0] = field.heap[field.heap_len];
        siftDown(field, 0);
    }
    return top;
}

fn siftUp(field: *FlowField, start: u32) void {
    var i = start;
    const cell = field.heap[i];
    const key = field.dist[cell];
    while (i > 0) {
        const parent = (i - 1) / 2;
        const parent_cell = field.heap[parent];
        if (field.dist[parent_cell] <= key) break;
        field.heap[i] = parent_cell;
        field.heap_pos[parent_cell] = @intCast(i);
        i = parent;
    }
    field.heap[i] = cell;
    field.heap_pos[cell] = @intCast(i);
}

fn siftDown(field: *FlowField, start: u32) void {
    var i = start;
    const cell = field.heap[i];
    const key = field.dist[cell];
    while (true) {
        var child = i * 2 + 1;
        if (child >= field.heap_len) break;
        if (child + 1 < field.heap_len and field.dist[field.heap[child + 1]] < field.dist[field.heap[child]]) child += 1;
        const child_cell = field.heap[child];
        if (field.dist[child_cell] >= key) break;
        field.heap[i] = child_cell;
        field.heap_pos[child_cell] = @intCast(i);
        i = child;
    }
    field.heap[i] = cell;
    field.heap_pos[cell] = @intCast(i);
}

/// Grid from rows of text: '#' is blocked, anything else free
///
fn testGrid(comptime rows: []const []const u8, cells: []bool) CollisionGrid {
    for (rows, 0..) |row, y| {
        for (row, 0..) |c, x| cells[y * rows[0].len + x] = c == '#';
    }
    return .{ .cells = cells[0 .. rows.len * rows[0].len], .width = rows[0].len, .height = rows.len, .cell_width = 57, .cell_height = 27 };
}

/// Follow the field from `start`, returning the number of steps to reach the goal (null if it never does)
///
fn walk(field: *const FlowField, grid: *const CollisionGrid, start: u16) ?u32 {
    var cell = start;
    var steps: u32 = 0;
    while (steps <= grid.cells.len) : (steps += 1) {
        const d = field.dir[cell];
        if (d == DIR_GOAL) return steps;
        if (d > DIR_GOAL) return null;
        const x = @as(i32, cell % grid.width) + OFFSETS[d][0];
        const y = @as(i32, cell / grid.width) + OFFSETS[d][1];
        cell = @intCast(y * grid.width + x);
        if (grid.cells[cell]) return null;
    }
    return null;
}

test "[flow_field] routes around a wall" {
    var cells: [8 * 7]bool = undefined;
    const open = testGrid(&.{
        "........",
        ".#####..",
        "....#...",
        "....#...",
        ".####...",
        "........",
        "........",
    }, &cells);
    var buffer: [2048]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    const goal: u16 = 3 * 8 + 2;
    const field = FlowField.init(&arena, &open, goal);

    try std.testing.expect(field.goal == goal);
    try std.testing.expect(field.dir[goal] == DIR_GOAL);
    try std.testing.expect(field.dir[1 * 8 + 1] == DIR_BLOCKED);
    //Every free cell leads to the goal without stepping into a wall
    for (0..open.cells.len) |i| {
        if (open.cells[i]) continue;
        try std.testing.expect(walk(&field, &open, @intCast(i)) != null);
    }
    //From the right of the wall the path has to go round: further than the straight line of 4 cells
    try std.testing.expect(walk(&field, &open, 3 * 8 + 6).? > 4);
}

test "[flow_field] cells walled off from the goal are unreachable" {
    var cells: [6 * 5]bool = undefined;
    const grid = testGrid(&.{
        "......",
        ".###..",
        ".#.#..",
        ".###..",
        "......",
    }, &cells);
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    const field = FlowField.init(&arena, &grid, 0);
    try std.testing.expect(field.dir[2 * 6 + 2] == DIR_UNREACHABLE);
    try std.testing.expect(!field.isReachable(2 * 6 + 2));
    try std.testing.expect(field.isReachable(4 * 6 + 5));
    try std.testing.expect(!field.isReachable(null));
}

test "[flow_field] diagonals never cut an obstacle's corner" {
    var cells: [3 * 3]bool = undefined;
    const grid = testGrid(&.{
        "...",
        ".#.",
        "...",
    }, &cells);
    var buffer: [512]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    //Goal top left: the bottom right corner has to go along an edge, not diagonally past the block
    const field = FlowField.init(&arena, &grid, 0);
    for (0..cells.len) |i| {
        const d = field.dir[i];
        if (d >= DIR_GOAL) continue;
        if (d % 2 == 0) continue;
        const x = @as(i32, @intCast(i % 3));
        const y = @as(i32, @intCast(i / 3));
        try std.testing.expect(!cells[@intCast(y * 3 + x + OFFSETS[d][0])]);
        try std.testing.expect(!cells[@intCast((y + OFFSETS[d][1]) * 3 + x)]);
    }
    try std.testing.expect(walk(&field, &grid, 8).? == 4);
}

test "[flow_field] rebuilds are spread over frames and only published when complete" {
    var cells: [10 * 10]bool = undefined;
    @memset(&cells, false);
    const grid = CollisionGrid{ .cells = &cells, .width = 10, .height = 10, .cell_width = 57, .cell_height = 27 };
    var buffer: [2048]u8 = undefined;
    var arena = Arena.init("level", &buffer);
    var field = FlowField.init(&arena, &grid, 0);

    //Goal moves: 100 cells at 30 per frame takes 4 frames, the old field stays live until then
    var frames: u32 = 0;
    while (true) {
        update(&field, &grid, 99, 30);
        frames += 1;
        if (field.goal == 99) break;
        try std.testing.expect(field.goal == 0 and field.dir[0] == DIR_GOAL);
        //A goal that moves again mid-build doesn't restart it
        update(&field, &grid, 50, 0);
        try std.testing.expect(field.build_goal == 99);
    }
    try std.testing.expect(frames == 4);
    try std.testing.expect(field.dir[99] == DIR_GOAL);
    try std.testing.expect(walk(&field, &grid, 0).? == 9);

    //Nothing to do while the goal stays put
    update(&field, &grid, 99, 30);
    try std.testing.expect(field.build_goal == NO_CELL);
}
