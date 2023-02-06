const std = @import("std");
const sparse_array = @import("sparse_array.zig");
const maths = @import("maths.zig");

const Vec2f = @Vector(2, f32);
const SparseArray = sparse_array.SparseArray;
const BucketList = std.SinglyLinkedList(Bucket);

const BUCKET_LEN: u8 = 20;
const SPACE_SIZE = 100;
const CHUNK_SIZE: u32 = 10;
const NUM_CHUNKS_W = (SPACE_SIZE / CHUNK_SIZE);
const NUM_CHUNKS = NUM_CHUNKS_W * NUM_CHUNKS_W;

pub const CollisionInfo = struct {
    entity_id: u8,
    impact_dir: Vec2f,
};

const Bucket = struct {
    ids: [BUCKET_LEN]u8,
    positions: [BUCKET_LEN]Vec2f,
    occupied: u8,
};

var chunks: [NUM_CHUNKS]BucketList = undefined;
var bucket_nodes: [100]BucketList.Node = undefined;
var bucket_node_head: u32 = 0;

/// Given the entities world positions (IDs and positions) group them into fixed size grid chunks
/// When doing collision detection we can then determine what chunk the collision instigator is in and only compare against
/// other entities in that chunk and surrounding chunks (to handle overlap).
/// We don't put entities into multiple chunks if they overlap - we test against multiple chunks instead
///
pub fn groupIntoChunks(entity_world_positions: SparseArray(Vec2f, u8)) void {
    for (chunks) |*chunk| {
        chunk.* = BucketList{};
    }
    bucket_node_head = 0;

    for (entity_world_positions.toDataSlice()) |entity_pos, entity_idx| {
        const id = entity_world_positions.lookupKeyByIndex(entity_idx) catch @panic("spatial_map groupIntoChunks: Cannot lookup key");
        const chunk_idx = calculateChunkIdx(entity_pos);

        //Grab the newest bucket and create one if we don't yet have a bucket
        if (chunks[chunk_idx].first) |bucket_node| {
            if (bucket_node.data.occupied == bucket_node.data.ids.len) {
                //Bucket is full need a new one
                chunks[chunk_idx].prepend(createNewBucketNode(id, entity_pos));
                continue;
            }

            bucket_node.data.ids[bucket_node.data.occupied] = id;
            bucket_node.data.positions[bucket_node.data.occupied] = entity_pos;
            bucket_node.data.occupied += 1;
        } else {
            //First bucket
            chunks[chunk_idx].prepend(createNewBucketNode(id, entity_pos));
        }
    }
}

/// Simple point check and test if the 2 points are within the given radius. Tests all points against all chunks and will
/// return all collisions
///
pub fn checkForPointCollisions(points: []const Vec2f, radius: f32, collision_data: []CollisionInfo, num_collisions: *u32) void {
    // const corners = [_]Vec2f{
    //     Vec2f{ entity_pos[0] - entity_size[0] * 0.5, entity_pos[1] + entity_size[1] * 0.5 },
    //     Vec2f{ entity_pos[0] + entity_size[0] * 0.5, entity_pos[1] + entity_size[1] * 0.5 },
    //     Vec2f{ entity_pos[0] - entity_size[0] * 0.5, entity_pos[1] - entity_size[1] * 0.5 },
    //     Vec2f{ entity_pos[0] + entity_size[0] * 0.5, entity_pos[1] - entity_size[1] * 0.5 },
    // };

    // const chunk_indices = [_]u32{
    //     calculateChunkIdx(corners[0]),
    //     calculateChunkIdx(corners[0]),
    //     calculateChunkIdx(corners[0]),
    //     calculateChunkIdx(corners[0]),
    // };
    var out_idx: u32 = 0;

    for (points) |point| {
        const chunk_idx = calculateChunkIdx(point);
        const buckets = chunks[chunk_idx];
        var it = buckets.first;
        while (it) |node| : (it = node.next) {
            for (node.data.positions[0..node.data.occupied]) |entity_pos, i| {
                const delta = entity_pos - point;
                if (maths.magnitudeSqrd(delta) <= radius) {
                    const id = node.data.ids[i];
                    collision_data[out_idx] = CollisionInfo{ .entity_id = id, .impact_dir = Vec2f{ 1, 0 } };
                    out_idx += 1;
                }
            }
        }
    }

    num_collisions.* = out_idx;
}

/// Simple point check and test if the 2 points are within the given radius. Will stop checking each point after the first collision
///
pub fn checkForFirstPointCollisions(points: []const Vec2f, radius: f32, collision_data: []CollisionInfo, num_collisions: *u32) void {
    // const corners = [_]Vec2f{
    //     Vec2f{ entity_pos[0] - entity_size[0] * 0.5, entity_pos[1] + entity_size[1] * 0.5 },
    //     Vec2f{ entity_pos[0] + entity_size[0] * 0.5, entity_pos[1] + entity_size[1] * 0.5 },
    //     Vec2f{ entity_pos[0] - entity_size[0] * 0.5, entity_pos[1] - entity_size[1] * 0.5 },
    //     Vec2f{ entity_pos[0] + entity_size[0] * 0.5, entity_pos[1] - entity_size[1] * 0.5 },
    // };

    // const chunk_indices = [_]u32{
    //     calculateChunkIdx(corners[0]),
    //     calculateChunkIdx(corners[0]),
    //     calculateChunkIdx(corners[0]),
    //     calculateChunkIdx(corners[0]),
    // };
    var out_idx: u32 = 0;

    for (points) |point| {
        const chunk_idx = calculateChunkIdx(point);
        const buckets = chunks[chunk_idx];
        var it = buckets.first;
        while (it) |node| : (it = node.next) {
            for (node.data.positions[0..node.data.occupied]) |entity_pos, i| {
                const delta = entity_pos - point;
                if (maths.magnitudeSqrd(delta) <= radius) {
                    const id = node.data.ids[i];
                    collision_data[out_idx] = CollisionInfo{ .entity_id = id, .impact_dir = Vec2f{ 1, 0 } };
                    out_idx += 1;
                    break;
                }
            }
        }
    }

    num_collisions.* = out_idx;
}

/// Convert from world position to a chunk idx
/// The grid is expanded beyond the movement bounds so we don't need to check for out of bounds
///
inline fn calculateChunkIdx(pos: Vec2f) u32 {
    const offset_pos = pos + @splat(2, @intToFloat(f32, SPACE_SIZE / 2));
    const chunk_pos = offset_pos / @splat(2, @intToFloat(f32, CHUNK_SIZE));
    const x = @floatToInt(u32, chunk_pos[0]);
    const y = @floatToInt(u32, chunk_pos[1]);
    return x + NUM_CHUNKS_W * y;
}

/// Create a new bucket node and populate with the id
///
inline fn createNewBucketNode(id: u8, pos: Vec2f) *BucketList.Node {
    var bucket_node_new = &bucket_nodes[bucket_node_head];
    bucket_node_new.* = BucketList.Node{ .data = Bucket{ .occupied = 1, .ids = undefined, .positions = undefined } };
    bucket_node_new.*.data.ids[0] = id;
    bucket_node_new.*.data.positions[0] = pos;
    bucket_node_head += 1;
    return bucket_node_new;
}

test "[spatial_map] calculateChunkIdx - inside" {
    const chunk_idx_1 = calculateChunkIdx(Vec2f{ -45.0, -45.0 });
    try std.testing.expect(chunk_idx_1 == 0);

    const chunk_idx_2 = calculateChunkIdx(Vec2f{ -35.0, -45.0 });
    try std.testing.expect(chunk_idx_2 == 1);

    const chunk_idx_3 = calculateChunkIdx(Vec2f{ -45.0, -35.0 });
    try std.testing.expect(chunk_idx_3 == 10);
}

test "[spatial_map] calculateChunkIdx - boundaries" {
    const chunk_idx_1 = calculateChunkIdx(Vec2f{ -50.0, -50.0 });
    try std.testing.expect(chunk_idx_1 == 0);

    const chunk_idx_2 = calculateChunkIdx(Vec2f{ -40.0, -45.0 });
    try std.testing.expect(chunk_idx_2 == 1);

    const chunk_idx_3 = calculateChunkIdx(Vec2f{ -40.0, -30.0 });
    try std.testing.expect(chunk_idx_3 == 21);
}

test "[spatial_map] checkForPointCollisions - in same chunk, single collision" {
    const alloc = std.testing.allocator;
    var positions = try SparseArray(Vec2f, u8).init(5, alloc);
    defer positions.deinit();

    try positions.insert(1, Vec2f{ 5.0, 5.0 });

    groupIntoChunks(positions);

    const r: f32 = 1.0;
    var info: [5]CollisionInfo = undefined;
    var num_collisions: u32 = 0;
    const points = [_]Vec2f{Vec2f{ 4.5, 4.5 }};
    checkForPointCollisions(points[0..], r, info[0..], &num_collisions);

    try std.testing.expect(num_collisions == 1);
    try std.testing.expect(info[0].entity_id == 1);
}

test "[spatial_map] checkForPointCollisions - in same chunk, no collision" {
    const alloc = std.testing.allocator;
    var positions = try SparseArray(Vec2f, u8).init(5, alloc);
    defer positions.deinit();

    try positions.insert(1, Vec2f{ 5.0, 5.0 });

    groupIntoChunks(positions);

    const r: f32 = 1.0;
    var info: [5]CollisionInfo = undefined;
    var num_collisions: u32 = 0;
    const points = [_]Vec2f{Vec2f{ 2.5, 2.5 }};
    checkForPointCollisions(points[0..], r, info[0..], &num_collisions);

    try std.testing.expect(num_collisions == 0);
}

test "[spatial_map] checkForPointCollisions - in same chunk, multiple collisions" {
    const alloc = std.testing.allocator;
    var positions = try SparseArray(Vec2f, u8).init(5, alloc);
    defer positions.deinit();

    try positions.insert(1, Vec2f{ 5.0, 5.0 });
    try positions.insert(2, Vec2f{ 6.0, 6.0 });

    groupIntoChunks(positions);

    const r: f32 = 1.0;
    var info: [5]CollisionInfo = undefined;
    var num_collisions: u32 = 0;
    const points = [_]Vec2f{Vec2f{ 5.5, 5.5 }};
    checkForPointCollisions(points[0..], r, info[0..], &num_collisions);

    try std.testing.expect(num_collisions == 2);
    try std.testing.expect(info[0].entity_id == 1);
    try std.testing.expect(info[1].entity_id == 2);
}

test "[spatial_map] checkForPointCollisions - in different chunks, no collisions" {
    const alloc = std.testing.allocator;
    var positions = try SparseArray(Vec2f, u8).init(5, alloc);
    defer positions.deinit();

    try positions.insert(1, Vec2f{ 5.0, 5.0 });

    groupIntoChunks(positions);

    const r: f32 = 1.0;
    var info: [5]CollisionInfo = undefined;
    var num_collisions: u32 = 0;
    const points = [_]Vec2f{Vec2f{ 25.0, 25.0 }};
    checkForPointCollisions(points[0..], r, info[0..], &num_collisions);

    try std.testing.expect(num_collisions == 0);
}

test "[spatial_map] checkForPointCollisions - in different chunks, single collision" {
    const alloc = std.testing.allocator;
    var positions = try SparseArray(Vec2f, u8).init(5, alloc);
    defer positions.deinit();

    try positions.insert(1, Vec2f{ 5.0, 5.0 });
    try positions.insert(2, Vec2f{ 16.0, 6.0 });

    groupIntoChunks(positions);

    const r: f32 = 1.0;
    var info: [5]CollisionInfo = undefined;
    var num_collisions: u32 = 0;
    const points = [_]Vec2f{Vec2f{ 15.5, 5.5 }};
    checkForPointCollisions(points[0..], r, info[0..], &num_collisions);

    try std.testing.expect(num_collisions == 1);
    try std.testing.expect(info[0].entity_id == 2);
}

test "[spatial_map] checkForPointCollisions - bucket spillover" {
    const alloc = std.testing.allocator;
    var positions = try SparseArray(Vec2f, u8).init(BUCKET_LEN + 1, alloc);
    defer positions.deinit();

    var i: u8 = 0;
    while (i < BUCKET_LEN + 1) : (i += 1) {
        try positions.insert(i, Vec2f{ 5.0, 5.0 });
    }

    groupIntoChunks(positions);

    const r: f32 = 1.0;
    var info: [BUCKET_LEN + 1]CollisionInfo = undefined;
    var num_collisions: u32 = 0;
    const points = [_]Vec2f{Vec2f{ 5.5, 5.5 }};
    checkForPointCollisions(points[0..], r, info[0..], &num_collisions);

    try std.testing.expect(num_collisions == BUCKET_LEN + 1);
    try std.testing.expect(info[0].entity_id == BUCKET_LEN);
}

fn oldCollisionCheck(points: []const Vec2f, r: f32, entity_world_positions: SparseArray(Vec2f, u8), collision_data: []CollisionInfo, num_collisions: *u32) !void {
    var out_idx: u32 = 0;

    for (points) |bullet_pos| {
        for (entity_world_positions.toDataSlice()) |entity_pos, entity_idx| {
            const delta = entity_pos - bullet_pos;
            if (maths.magnitudeSqrd(delta) <= r) {
                collision_data[out_idx] = CollisionInfo{ .entity_id = try entity_world_positions.lookupKeyByIndex(entity_idx), .impact_dir = Vec2f{ 1, 0 } };
                out_idx += 1;
            }
        }
    }

    num_collisions.* = out_idx;
}

test "[spatial_map] checkForPointCollisions - stress test" {
    const timer = std.time.Timer;
    const alloc = std.testing.allocator;

    var rand: std.rand.DefaultPrng = undefined;
    rand = std.rand.DefaultPrng.init(42);

    const COUNT_A: u8 = 36;
    const COUNT_B: u8 = 255;

    var positions_a: [COUNT_A]Vec2f = undefined;
    var positions_b = try SparseArray(Vec2f, u8).init(COUNT_B, alloc);
    defer positions_b.deinit();

    var i: u8 = 0;
    while (i < COUNT_A) : (i += 1) {
        positions_a[i] = Vec2f{ rand.random().float(f32) * 49.0, rand.random().float(f32) * 49.0 };
    }

    i = 0;
    while (i < COUNT_B) : (i += 1) {
        try positions_b.insert(i, Vec2f{ rand.random().float(f32) * 49.0, rand.random().float(f32) * 49.0 });
    }

    const r: f32 = 1.0;
    var info: [3000]CollisionInfo = undefined;
    var num_collisions: u32 = 0;

    var n: usize = 0;
    while (n < 10) : (n += 1) {
        var t = try timer.start();
        groupIntoChunks(positions_b);
        checkForPointCollisions(positions_a[0..], r, info[0..], &num_collisions);
        std.debug.print("\nms: {d:.5} num_collisions: {}\n", .{ @intToFloat(f64, t.read()) / 1000000.0, num_collisions });
    }

    n = 0;
    while (n < 10) : (n += 1) {
        var t = try timer.start();
        try oldCollisionCheck(positions_a[0..], r, positions_b, info[0..], &num_collisions);
        std.debug.print("\nOLD: ms: {d:.5} num_collisions: {}\n", .{ @intToFloat(f64, t.read()) / 1000000.0, num_collisions });
    }
}
