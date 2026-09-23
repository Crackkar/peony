const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const exceptions = @import("runtime_exception");
const sequence = @import("runtime_sequence");

pub const Value = value_module.Value;
pub const Entry = struct {
    key: Value,
    value: Value,
    hash: u64,
    alive: bool = true,
};

pub const Dict = struct {
    header: gc.Header align(8),
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    buckets: []usize = &.{},
    size: usize = 0,
    tombstones: usize = 0,
    version: u64 = 0,
    is_set: bool = false,
};

pub const ViewKind = enum { keys, values, items };

pub const View = struct {
    header: gc.Header align(8),
    owner: *Dict,
    kind: ViewKind,
};

pub const DictIterator = struct {
    header: gc.Header align(8),
    owner: *Dict,
    kind: ViewKind,
    index: usize = 0,
    expected_version: u64,
    exhausted: bool = false,
};

pub const EqualityFn = *const fn (*anyopaque, Value, Value) ?bool;
pub const Lookup = union(enum) { found: usize, missing, failed };
pub const GetResult = union(enum) { value: Value, missing, failed };
pub const IterResult = union(enum) { item: Value, done, python_exception: exceptions.PythonException };

const empty_bucket = std.math.maxInt(usize);
const deleted_bucket = std.math.maxInt(usize) - 1;
const dict_kind = gc.Kind{ .trace = traceDict, .destroy = destroyDict };
const view_kind = gc.Kind{ .trace = traceView };
const iterator_kind = gc.Kind{ .trace = traceIterator };

pub fn dictFromHeader(header: *gc.Header) ?*Dict {
    if (header.kind != &dict_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn viewFromHeader(header: *gc.Header) ?*View {
    if (header.kind != &view_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn iteratorFromHeader(header: *gc.Header) ?*DictIterator {
    if (header.kind != &iterator_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn create(heap: *gc.Heap, is_set: bool) exceptions.Result(*Dict) {
    const object = heap.createObject(Dict, &dict_kind) catch return memoryError(*Dict);
    object.* = .{ .header = object.header, .allocator = heap.allocator, .is_set = is_set };
    return .{ .value = object };
}

pub fn createView(heap: *gc.Heap, owner: *Dict, kind: ViewKind) exceptions.Result(*View) {
    var roots = RootScope{};
    roots.push(heap, &owner.header, null);
    defer roots.pop();
    const object = heap.createObject(View, &view_kind) catch return memoryError(*View);
    object.* = .{ .header = object.header, .owner = owner, .kind = kind };
    return .{ .value = object };
}

pub fn createIterator(heap: *gc.Heap, owner: *Dict, kind: ViewKind) exceptions.Result(*DictIterator) {
    var roots = RootScope{};
    roots.push(heap, &owner.header, null);
    defer roots.pop();
    const object = heap.createObject(DictIterator, &iterator_kind) catch return memoryError(*DictIterator);
    object.* = .{ .header = object.header, .owner = owner, .kind = kind, .expected_version = owner.version };
    return .{ .value = object };
}

pub fn lookup(dict: *Dict, key: Value, key_hash: u64, context: *anyopaque, equal: EqualityFn) Lookup {
    if (dict.buckets.len == 0) return .missing;
    const mask = dict.buckets.len - 1;
    var index = @as(usize, @truncate(key_hash)) & mask;
    var visited: usize = 0;
    while (visited < dict.buckets.len) : (visited += 1) {
        const bucket = dict.buckets[index];
        if (bucket == empty_bucket) return .missing;
        if (bucket != deleted_bucket) {
            if (bucket >= dict.entries.items.len) return .failed;
            const entry = dict.entries.items[bucket];
            if (entry.alive and entry.hash == key_hash) {
                const same = equal(context, entry.key, key) orelse return .failed;
                if (same) return .{ .found = bucket };
            }
        }
        index = (index + 1) & mask;
    }
    return .missing;
}

pub fn get(dict: *Dict, key: Value, key_hash: u64, context: *anyopaque, equal: EqualityFn) GetResult {
    return switch (lookup(dict, key, key_hash, context, equal)) {
        .found => |index| .{ .value = dict.entries.items[index].value },
        .missing => .missing,
        .failed => .failed,
    };
}

pub fn set(heap: *gc.Heap, dict: *Dict, key: Value, value: Value, key_hash: u64, context: *anyopaque, equal: EqualityFn) exceptions.Result(void) {
    var roots = RootScope{};
    roots.push(heap, &dict.header, key.asObject());
    roots.addValue(value);
    defer roots.pop();
    const found = lookup(dict, key, key_hash, context, equal);
    switch (found) {
        .failed => return .{ .engine_error = .internal_invariant },
        .found => |entry_index| {
            if (!dict.is_set) dict.entries.items[entry_index].value = value;
            return .{ .value = {} };
        },
        .missing => {},
    }
    if (dict.buckets.len == 0 or (dict.size + dict.tombstones + 1) * 10 >= dict.buckets.len * 7) {
        const desired = if (dict.buckets.len == 0) 8 else dict.buckets.len * 2;
        tryRebuild(heap, dict, desired) catch return memoryError(void);
    } else if (dict.tombstones > 8 and dict.tombstones > dict.size) {
        tryRebuild(heap, dict, dict.buckets.len) catch return memoryError(void);
    }
    dict.entries.append(heap.allocator, .{ .key = key, .value = value, .hash = key_hash }) catch return memoryError(void);
    const entry_index = dict.entries.items.len - 1;
    const bucket = insertionBucket(dict.buckets, key_hash) orelse return .{ .engine_error = .internal_invariant };
    if (dict.buckets[bucket] == deleted_bucket) dict.tombstones -= 1;
    dict.buckets[bucket] = entry_index;
    dict.size += 1;
    dict.version +%= 1;
    return .{ .value = {} };
}

pub fn delete(dict: *Dict, key: Value, key_hash: u64, context: *anyopaque, equal: EqualityFn) Lookup {
    switch (lookup(dict, key, key_hash, context, equal)) {
        .missing => return .missing,
        .failed => return .failed,
        .found => |entry_index| {
            const bucket = findBucketForIndex(dict, entry_index) orelse return .failed;
            dict.buckets[bucket] = deleted_bucket;
            dict.entries.items[entry_index].alive = false;
            dict.size -= 1;
            dict.tombstones += 1;
            dict.version +%= 1;
            return .{ .found = entry_index };
        },
    }
}

pub fn clear(heap: *gc.Heap, dict: *Dict) void {
    const changed_size = dict.size != 0;
    dict.entries.clearRetainingCapacity();
    if (dict.buckets.len != 0) @memset(dict.buckets, empty_bucket);
    dict.size = 0;
    dict.tombstones = 0;
    if (changed_size) dict.version +%= 1;
    _ = heap;
}

pub fn copy(heap: *gc.Heap, source: *Dict) exceptions.Result(*Dict) {
    var roots = RootScope{};
    roots.push(heap, &source.header, null);
    defer roots.pop();
    const result = create(heap, source.is_set);
    const destination = switch (result) {
        .value => |dict| dict,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    roots.addHeader(&destination.header);
    for (source.entries.items) |entry| {
        if (!entry.alive) continue;
        const inserted = set(heap, destination, entry.key, entry.value, entry.hash, @ptrCast(destination), unreachableEquality);
        switch (inserted) {
            .value => {},
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        }
    }
    destination.version = 0;
    return .{ .value = destination };
}

pub fn sizeOf(value: Value) ?usize {
    const header = value.asObject() orelse return null;
    if (dictFromHeader(header)) |dict| return dict.size;
    if (viewFromHeader(header)) |view| return view.owner.size;
    return null;
}

pub fn next(heap: *gc.Heap, iterator: *DictIterator) IterResult {
    if (iterator.exhausted) return .done;
    if (iterator.expected_version != iterator.owner.version) return .{ .python_exception = .{ .kind = .runtime_error, .message = "dictionary changed size during iteration" } };
    while (iterator.index < iterator.owner.entries.items.len) {
        const entry = iterator.owner.entries.items[iterator.index];
        iterator.index += 1;
        if (!entry.alive) continue;
        return switch (iterator.kind) {
            .keys => .{ .item = entry.key },
            .values => .{ .item = entry.value },
            .items => blk: {
                const pair = sequence.createTuple(heap, &.{ entry.key, entry.value });
                break :blk switch (pair) {
                    .value => |tuple| .{ .item = Value.object(&tuple.header) },
                    .python_exception => |exception| .{ .python_exception = exception },
                    .engine_error => .{ .python_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } },
                };
            },
        };
    }
    iterator.exhausted = true;
    return .done;
}

fn tryRebuild(heap: *gc.Heap, dict: *Dict, capacity: usize) !void {
    var roots = RootScope{};
    roots.push(heap, &dict.header, null);
    defer roots.pop();
    const buckets = try heap.allocator.alloc(usize, capacity);
    errdefer heap.allocator.free(buckets);
    @memset(buckets, empty_bucket);
    var live_count: usize = 0;
    for (dict.entries.items) |entry| if (entry.alive) { live_count += 1; };
    const entries = try heap.allocator.alloc(Entry, live_count);
    var cursor: usize = 0;
    for (dict.entries.items) |entry| {
        if (!entry.alive) continue;
        entries[cursor] = entry;
        const bucket = insertionBucket(buckets, entry.hash) orelse unreachable;
        buckets[bucket] = cursor;
        cursor += 1;
    }
    dict.entries.deinit(heap.allocator);
    dict.entries = .{ .items = entries, .capacity = entries.len };
    if (dict.buckets.len != 0) heap.allocator.free(dict.buckets);
    dict.buckets = buckets;
    dict.tombstones = 0;
}

fn insertionBucket(buckets: []const usize, key_hash: u64) ?usize {
    if (buckets.len == 0) return null;
    const mask = buckets.len - 1;
    var index = @as(usize, @truncate(key_hash)) & mask;
    var first_deleted: ?usize = null;
    for (0..buckets.len) |_| {
        const bucket = buckets[index];
        if (bucket == empty_bucket) return first_deleted orelse index;
        if (bucket == deleted_bucket and first_deleted == null) first_deleted = index;
        index = (index + 1) & mask;
    }
    return first_deleted;
}

fn findBucketForIndex(dict: *Dict, entry_index: usize) ?usize {
    if (dict.buckets.len == 0) return null;
    for (dict.buckets, 0..) |bucket, index| if (bucket == entry_index) return index;
    return null;
}

fn traceDict(header: *gc.Header, tracer: *gc.Tracer) void {
    const dict: *Dict = @ptrCast(@alignCast(header));
    for (dict.entries.items) |entry| {
        if (!entry.alive) continue;
        tracer.visit(entry.key.asObject());
        if (!dict.is_set) tracer.visit(entry.value.asObject());
    }
}

fn destroyDict(header: *gc.Header, allocator: std.mem.Allocator) void {
    const dict: *Dict = @ptrCast(@alignCast(header));
    dict.entries.deinit(allocator);
    if (dict.buckets.len != 0) allocator.free(dict.buckets);
    dict.buckets = &.{};
}

fn traceView(header: *gc.Header, tracer: *gc.Tracer) void {
    const view: *View = @ptrCast(@alignCast(header));
    tracer.visit(&view.owner.header);
}

fn traceIterator(header: *gc.Header, tracer: *gc.Tracer) void {
    const iterator: *DictIterator = @ptrCast(@alignCast(header));
    tracer.visit(&iterator.owner.header);
}

fn unreachableEquality(_: *anyopaque, left: Value, right: Value) ?bool {
    return left.identical(right);
}

const RootScope = struct {
    frame: gc.RootFrame = .{},
    roots: [3]gc.Root = .{ .{ .object = null }, .{ .object = null }, .{ .object = null } },
    count: usize = 0,

    fn push(self: *RootScope, heap: *gc.Heap, first: *gc.Header, second: ?*gc.Header) void {
        self.frame.push(&heap.roots);
        self.roots[0].object = first;
        self.frame.add(&self.roots[0]);
        self.count = 1;
        if (second) |header| self.addHeader(header);
    }

    fn addValue(self: *RootScope, value: Value) void {
        if (value.asObject()) |header| self.addHeader(header);
    }

    fn addHeader(self: *RootScope, first: *gc.Header) void {
        if (self.count >= self.roots.len) unreachable;
        self.roots[self.count].object = first;
        self.frame.add(&self.roots[self.count]);
        self.count += 1;
    }

    fn pop(self: *RootScope) void {
        self.frame.pop();
    }
};

fn memoryError(comptime T: type) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
}
