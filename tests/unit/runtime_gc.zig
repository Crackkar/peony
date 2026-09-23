const std = @import("std");
const gc = @import("runtime_gc");

const TestNode = struct {
    header: gc.Header,
    left: ?*gc.Header = null,
    right: ?*gc.Header = null,
    owned: []u8 = &.{},
};

const node_kind = gc.Kind{
    .trace = traceNode,
    .destroy = destroyNode,
};

fn traceNode(header: *gc.Header, tracer: *gc.Tracer) void {
    const node: *TestNode = @ptrCast(@alignCast(header));
    tracer.visit(node.left);
    tracer.visit(node.right);
}

fn destroyNode(header: *gc.Header, allocator: std.mem.Allocator) void {
    const node: *TestNode = @ptrCast(@alignCast(header));
    if (node.owned.len != 0) allocator.free(node.owned);
    node.owned = &.{};
}

pub fn testSessionAllocatorAccounting() !void {
    var session = gc.SessionAllocator.init(std.testing.allocator, 32);
    const allocator = session.allocator();

    var bytes = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), session.live_bytes);
    try std.testing.expectEqual(@as(usize, 8), session.peak_bytes);

    bytes = try allocator.realloc(bytes, 20);
    try std.testing.expectEqual(@as(usize, 20), session.live_bytes);
    // Zig falls back to allocate-copy-free when the backing allocator cannot grow in place.
    try std.testing.expectEqual(@as(usize, 28), session.peak_bytes);

    bytes = try allocator.realloc(bytes, 5);
    try std.testing.expectEqual(@as(usize, 5), session.live_bytes);
    try std.testing.expectEqual(@as(usize, 28), session.peak_bytes);
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
}

pub fn testSessionAllocatorCap() !void {
    var session = gc.SessionAllocator.init(std.testing.allocator, 16);
    const allocator = session.allocator();

    const at_cap = try allocator.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 16), session.live_bytes);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 16), session.live_bytes);
    try std.testing.expectEqual(@as(usize, 16), session.peak_bytes);
    allocator.free(at_cap);
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
}

pub fn testAllocationEdges() !void {
    var session = gc.SessionAllocator.init(std.testing.allocator, 16);
    const allocator = session.allocator();

    const empty = try allocator.alloc(u8, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u16, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), session.peak_bytes);
}

pub fn testSessionIsolation() !void {
    var first_session = gc.SessionAllocator.init(std.testing.allocator, 10);
    var second_session = gc.SessionAllocator.init(std.testing.allocator, 10);
    const first_allocator = first_session.allocator();
    const second_allocator = second_session.allocator();

    const first = try first_allocator.alloc(u8, 10);
    const second = try second_allocator.alloc(u8, 10);
    try std.testing.expectEqual(@as(usize, 10), first_session.live_bytes);
    try std.testing.expectEqual(@as(usize, 10), second_session.live_bytes);
    try std.testing.expectError(error.OutOfMemory, first_allocator.alloc(u8, 1));
    try std.testing.expectError(error.OutOfMemory, second_allocator.alloc(u8, 1));
    first_allocator.free(first);
    second_allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), first_session.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), second_session.live_bytes);
}

pub fn testRootsAndCycles() !void {
    var session = gc.SessionAllocator.init(std.testing.allocator, 4096);
    var heap = gc.Heap{};
    heap.init(&session, .{ .initial_threshold = 4096 });
    defer heap.deinit();

    var first = try heap.createObject(TestNode, &node_kind);
    first.left = null;
    first.right = null;
    first.owned = &.{};
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    var first_root = gc.Root{ .object = &first.header };
    frame.add(&first_root);

    const second = try heap.createObject(TestNode, &node_kind);
    second.left = null;
    second.right = &first.header;
    second.owned = &.{};
    first.left = &second.header;

    try std.testing.expectEqual(@as(usize, 2), heap.object_count);
    try std.testing.expectEqual(@as(usize, 0), heap.collect());
    try std.testing.expectEqual(@as(usize, 2), heap.object_count);

    frame.pop();
    try std.testing.expectEqual(@as(usize, 2), heap.collect());
    try std.testing.expectEqual(@as(usize, 0), heap.object_count);
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
}

pub fn testDestructorStorage() !void {
    var session = gc.SessionAllocator.init(std.testing.allocator, 4096);
    var heap = gc.Heap{};
    heap.init(&session, .{ .initial_threshold = 4096 });
    defer heap.deinit();

    const node = try heap.createObject(TestNode, &node_kind);
    node.left = null;
    node.right = null;
    node.owned = &.{};
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    var root = gc.Root{ .object = &node.header };
    frame.add(&root);

    node.owned = try session.allocator().alloc(u8, 128);
    const live_with_buffer = session.live_bytes;
    try std.testing.expect(live_with_buffer >= 128);
    try std.testing.expectEqual(@as(usize, 0), heap.collect());
    try std.testing.expectEqual(@as(usize, 1), heap.object_count);

    frame.pop();
    try std.testing.expectEqual(@as(usize, 1), heap.collect());
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
}

pub fn testMarkingWithoutAllocation() !void {
    var gate = RefusingAllocator{ .backing = std.testing.allocator };
    var session = gc.SessionAllocator.init(gate.allocator(), 4096);
    var heap = gc.Heap{};
    heap.init(&session, .{ .initial_threshold = 4096 });
    defer heap.deinit();

    const first = try heap.createObject(TestNode, &node_kind);
    first.left = null;
    first.right = null;
    first.owned = &.{};
    const second = try heap.createObject(TestNode, &node_kind);
    second.left = &first.header;
    second.right = null;
    second.owned = &.{};
    first.left = &second.header;

    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    var root = gc.Root{ .object = &first.header };
    frame.add(&root);

    const calls_before = gate.memory_operation_calls;
    gate.reject_new_memory = true;
    try std.testing.expectEqual(@as(usize, 0), heap.collect());
    try std.testing.expectEqual(calls_before, gate.memory_operation_calls);
    try std.testing.expectEqual(@as(usize, 2), heap.object_count);
    gate.reject_new_memory = false;
    frame.pop();
}

pub fn testThresholdGrowth() !void {
    var session = gc.SessionAllocator.init(std.testing.allocator, 1024 * 1024);
    var heap = gc.Heap{};
    heap.init(&session, .{ .initial_threshold = 1, .threshold_growth_floor = 32 });
    defer heap.deinit();

    const node = try heap.createObject(TestNode, &node_kind);
    node.left = null;
    node.right = null;
    node.owned = &.{};
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    var root = gc.Root{ .object = &node.header };
    frame.add(&root);

    const old_threshold = heap.collection_threshold;
    const allocation = try session.allocator().alloc(u8, old_threshold);
    const collections_after_growth = heap.collection_count;
    const grown_threshold = heap.collection_threshold;
    try std.testing.expect(collections_after_growth > 0);
    try std.testing.expect(grown_threshold > old_threshold);

    const tiny = try session.allocator().alloc(u8, 1);
    try std.testing.expectEqual(collections_after_growth, heap.collection_count);
    session.allocator().free(tiny);
    session.allocator().free(allocation);
    frame.pop();
}

const RefusingAllocator = struct {
    backing: std.mem.Allocator,
    reject_new_memory: bool = false,
    memory_operation_calls: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *RefusingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *RefusingAllocator = @ptrCast(@alignCast(context));
        self.memory_operation_calls += 1;
        if (self.reject_new_memory) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *RefusingAllocator = @ptrCast(@alignCast(context));
        self.memory_operation_calls += 1;
        if (self.reject_new_memory) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *RefusingAllocator = @ptrCast(@alignCast(context));
        self.memory_operation_calls += 1;
        if (self.reject_new_memory) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *RefusingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
