const std = @import("std");
const gc = @import("runtime_gc");
const string = @import("runtime_string");
const exceptions = @import("runtime_exception");
const slice_utils = @import("runtime_slice");

pub const BytesResult = exceptions.Result(*Bytes);
pub const ByteResult = exceptions.Result(u8);
pub const PythonExceptionKind = exceptions.PythonExceptionKind;

pub const Bytes = struct {
    header: gc.Header align(8),
    data: []u8,
    cached_hash: ?u64 = null,
};

const bytes_kind = gc.Kind{ .destroy = destroyBytes };

pub fn fromHeader(header: *gc.Header) ?*Bytes {
    if (header.kind != &bytes_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn create(heap: *gc.Heap, input: []const u8) BytesResult {
    const data = heap.allocator.dupe(u8, input) catch return memoryError();
    return createOwned(heap, data);
}

pub fn fromIntegers(heap: *gc.Heap, values: []const i64) BytesResult {
    for (values) |value| {
        if (value < 0 or value > 255) return pythonError(*Bytes, .value_error, "bytes must be in range(0, 256)");
    }
    const data = heap.allocator.alloc(u8, values.len) catch return memoryError();
    for (values, 0..) |value, index_value| data[index_value] = @intCast(value);
    return createOwned(heap, data);
}

pub fn content(value: *const Bytes) []const u8 {
    return value.data;
}

pub fn length(value: *const Bytes) usize {
    return value.data.len;
}

pub fn index(value: *const Bytes, index_value: i64) ByteResult {
    const count = std.math.cast(i64, value.data.len) orelse return pythonError(u8, .overflow_error, "bytes object is too large to index");
    const normalized = if (index_value < 0) index_value + count else index_value;
    if (normalized < 0 or normalized >= count) return pythonError(u8, .index_error, "bytes index out of range");
    return .{ .value = value.data[@intCast(normalized)] };
}

pub fn slice(heap: *gc.Heap, value: *Bytes, start: ?i64, stop: ?i64, step: i64) BytesResult {
    if (step == 0) return pythonError(*Bytes, .value_error, "slice step cannot be zero");
    const count = std.math.cast(i64, value.data.len) orelse return pythonError(*Bytes, .overflow_error, "bytes object is too large to slice");
    const indices = slice_utils.normalizeI64(count, start, stop, step);
    return sliceNormalized(heap, value, indices);
}

pub fn sliceNormalized(heap: *gc.Heap, value: *Bytes, indices: slice_utils.BoundedIndices) BytesResult {
    var roots = RootScope{};
    roots.push(heap, value);
    defer roots.pop();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(heap.allocator);
    var index_value = indices.start;
    while (if (indices.step > 0) index_value < indices.stop else index_value > indices.stop) {
        output.append(heap.allocator, value.data[@intCast(index_value)]) catch return memoryError();
        index_value = std.math.add(i128, index_value, indices.step) catch break;
    }
    const data = output.toOwnedSlice(heap.allocator) catch return memoryError();
    return createOwned(heap, data);
}

pub fn equal(left: *const Bytes, right: *const Bytes) bool {
    return std.mem.eql(u8, left.data, right.data);
}

pub fn hash(value: *Bytes) u64 {
    if (value.cached_hash) |cached| return cached;
    var hash_value: u64 = 14_695_981_039_346_656_037;
    for (value.data) |byte| hash_value = (hash_value ^ byte) *% 1_099_511_628_211;
    value.cached_hash = hash_value;
    return hash_value;
}

pub fn encode(heap: *gc.Heap, value: *string.Str) BytesResult {
    var roots = RootScope{};
    roots.pushHeader(heap, &value.header);
    defer roots.pop();
    return create(heap, string.content(value));
}

pub fn decode(heap: *gc.Heap, value: *Bytes) string.StringResult {
    if (!std.unicode.utf8ValidateSlice(value.data)) {
        return .{ .python_exception = .{ .kind = .unicode_decode_error, .message = "invalid UTF-8 sequence" } };
    }
    var roots = RootScope{};
    roots.push(heap, value);
    defer roots.pop();
    return string.create(heap, value.data);
}

fn createOwned(heap: *gc.Heap, data: []u8) BytesResult {
    const object = heap.createObject(Bytes, &bytes_kind) catch {
        heap.allocator.free(data);
        return memoryError();
    };
    const header = object.header;
    object.* = .{ .header = header, .data = data };
    return .{ .value = object };
}

fn destroyBytes(header: *gc.Header, allocator: std.mem.Allocator) void {
    const value: *Bytes = @ptrCast(@alignCast(header));
    allocator.free(value.data);
    value.data = &.{};
}

const RootScope = struct {
    frame: gc.RootFrame = .{},
    root: gc.Root = .{ .object = null },

    fn push(self: *RootScope, heap: *gc.Heap, value: *Bytes) void {
        self.pushHeader(heap, &value.header);
    }

    fn pushHeader(self: *RootScope, heap: *gc.Heap, header: *gc.Header) void {
        self.frame.push(&heap.roots);
        self.root.object = header;
        self.frame.add(&self.root);
    }

    fn pop(self: *RootScope) void {
        self.frame.pop();
    }
};

fn pythonError(comptime T: type, kind: PythonExceptionKind, message: []const u8) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}

fn memoryError() BytesResult {
    return pythonError(*Bytes, .memory_error, "session memory limit exceeded");
}
