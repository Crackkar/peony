const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const exceptions = @import("runtime_exception");

const Value = value_module.Value;

pub const List = struct {
    header: gc.Header align(8),
    items: std.ArrayList(Value) = .empty,
    version: u64 = 0,
};

pub const Tuple = struct {
    header: gc.Header align(8),
    items: []Value = &.{},
};

pub const ListResult = exceptions.Result(*List);
pub const TupleResult = exceptions.Result(*Tuple);
pub const ValueResult = exceptions.Result(Value);

const list_kind = gc.Kind{ .trace = traceList, .destroy = destroyList };
const tuple_kind = gc.Kind{ .trace = traceTuple, .destroy = destroyTuple };

pub fn listFromHeader(header: *gc.Header) ?*List {
    if (header.kind != &list_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn tupleFromHeader(header: *gc.Header) ?*Tuple {
    if (header.kind != &tuple_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn createList(heap: *gc.Heap, values: []const Value) ListResult {
    const list = heap.createObject(List, &list_kind) catch return memoryError(*List);
    const header = list.header;
    list.* = .{ .header = header, .items = .empty };
    var root = gc.Root{ .object = &list.header };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&root);
    defer roots.pop();
    list.items.appendSlice(heap.allocator, values) catch return memoryError(*List);
    return .{ .value = list };
}

pub fn createTuple(heap: *gc.Heap, values: []const Value) TupleResult {
    const tuple = heap.createObject(Tuple, &tuple_kind) catch return memoryError(*Tuple);
    const header = tuple.header;
    tuple.* = .{ .header = header, .items = &.{} };
    var root = gc.Root{ .object = &tuple.header };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&root);
    defer roots.pop();
    if (values.len != 0) tuple.items = heap.allocator.dupe(Value, values) catch return memoryError(*Tuple);
    return .{ .value = tuple };
}

pub fn append(heap: *gc.Heap, list: *List, value: Value) exceptions.Result(void) {
    list.items.append(heap.allocator, value) catch return memoryError(void);
    list.version +%= 1;
    return .{ .value = {} };
}

pub fn extend(heap: *gc.Heap, list: *List, values: []const Value) exceptions.Result(void) {
    // appendSlice can grow and move the destination buffer before it copies.
    // Snapshot overlapping input first so `items.extend(items)` stays valid.
    var snapshot: ?[]Value = null;
    if (overlaps(list.items.items, values)) {
        snapshot = heap.allocator.dupe(Value, values) catch return memoryError(void);
    }
    defer if (snapshot) |copy_values| heap.allocator.free(copy_values);
    list.items.appendSlice(heap.allocator, snapshot orelse values) catch return memoryError(void);
    if (values.len != 0) list.version +%= 1;
    return .{ .value = {} };
}

pub fn insert(heap: *gc.Heap, list: *List, index_object: Value, value: Value) exceptions.Result(void) {
    if (!number.isIntegerValue(index_object)) return pythonError(void, .type_error, "'insert' index must be an integer");
    const machine_index = if (index_object.asBool()) |boolean|
        @as(i64, @intFromBool(boolean))
    else
        number.toInt(i64, index_object) orelse return pythonError(void, .overflow_error, "Python int too large to convert to C ssize_t");
    const index_value: i128 = @intCast(machine_index);
    const item_count: i128 = @intCast(list.items.items.len);
    var index = index_value;
    if (index < 0) index += item_count;
    index = @min(@max(index, 0), item_count);
    list.items.insert(heap.allocator, @intCast(index), value) catch return memoryError(void);
    list.version +%= 1;
    return .{ .value = {} };
}

pub fn pop(list: *List, index_value: usize) exceptions.Result(Value) {
    if (list.items.items.len == 0 or index_value >= list.items.items.len) return pythonError(Value, .index_error, "pop index out of range");
    const value = list.items.orderedRemove(index_value);
    list.version +%= 1;
    return .{ .value = value };
}

pub fn remove(heap: *gc.Heap, list: *List, index_value: usize) exceptions.Result(void) {
    _ = heap;
    if (index_value >= list.items.items.len) return pythonError(void, .index_error, "list.remove(x): x not in list");
    _ = list.items.orderedRemove(index_value);
    list.version +%= 1;
    return .{ .value = {} };
}

pub fn clear(heap: *gc.Heap, list: *List) void {
    const changed = list.items.items.len != 0;
    list.items.clearAndFree(heap.allocator);
    if (changed) list.version +%= 1;
}

pub fn copy(heap: *gc.Heap, list: *List) ListResult {
    return createList(heap, list.items.items);
}

pub fn reverse(list: *List) void {
    std.mem.reverse(Value, list.items.items);
    if (list.items.items.len > 1) list.version +%= 1;
}

pub fn getIndex(item_count: usize, value: Value) exceptions.Result(usize) {
    const index_value = if (value.asBool()) |boolean|
        @as(i128, @intFromBool(boolean))
    else blk: {
        if (!number.isIntegerValue(value)) return pythonError(usize, .type_error, "sequence indices must be integers or slices");
        break :blk number.toInt(i128, value) orelse return pythonError(usize, .index_error, "sequence index out of range");
    };
    const length_value: i128 = @intCast(item_count);
    const normalized = if (index_value < 0) index_value + length_value else index_value;
    if (normalized < 0 or normalized >= length_value) return pythonError(usize, .index_error, "sequence index out of range");
    return .{ .value = @intCast(normalized) };
}

pub fn concatenate(heap: *gc.Heap, left: Value, right: Value) ValueResult {
    const left_header = left.asObject() orelse return pythonError(Value, .type_error, "can only concatenate sequences of the same type");
    const right_header = right.asObject() orelse return pythonError(Value, .type_error, "can only concatenate sequences of the same type");
    if (listFromHeader(left_header)) |left_list| {
        const right_list = listFromHeader(right_header) orelse return pythonError(Value, .type_error, "can only concatenate list to list");
        return concatValues(heap, left_list.items.items, right_list.items.items, false);
    }
    if (tupleFromHeader(left_header)) |left_tuple| {
        const right_tuple = tupleFromHeader(right_header) orelse return pythonError(Value, .type_error, "can only concatenate tuple to tuple");
        return concatValues(heap, left_tuple.items, right_tuple.items, true);
    }
    return pythonError(Value, .type_error, "unsupported operands for +");
}

pub fn repeat(heap: *gc.Heap, sequence_value: Value, multiplier: Value) ValueResult {
    if (!number.isIntegerValue(multiplier)) return pythonError(Value, .type_error, "can't multiply sequence by non-int");
    const count = if (multiplier.asBool()) |boolean|
        @as(i64, @intFromBool(boolean))
    else
        number.toInt(i64, multiplier) orelse return pythonError(Value, .overflow_error, "repeated sequence is too long");
    if (count <= 0) {
        const header = sequence_value.asObject() orelse return pythonError(Value, .type_error, "can't multiply sequence by non-int");
        if (listFromHeader(header) != null) return listValue(createList(heap, &.{}));
        if (tupleFromHeader(header) != null) return tupleValue(createTuple(heap, &.{}));
        return pythonError(Value, .type_error, "can't multiply sequence by non-int");
    }
    const header = sequence_value.asObject() orelse return pythonError(Value, .type_error, "can't multiply sequence by non-int");
    const list = listFromHeader(header);
    const tuple = tupleFromHeader(header);
    const source = if (list) |object| object.items.items else if (tuple) |object| object.items else return pythonError(Value, .type_error, "can't multiply sequence by non-int");
    if (source.len == 0) return if (list != null) listValue(createList(heap, &.{})) else tupleValue(createTuple(heap, &.{}));
    const source_count = std.math.cast(i64, source.len) orelse return pythonError(Value, .overflow_error, "repeated sequence is too long");
    const output_len_i64 = std.math.mul(i64, source_count, count) catch return pythonError(Value, .overflow_error, "repeated sequence is too long");
    const output_len = std.math.cast(usize, output_len_i64) orelse return memoryError(Value);
    const amount = std.math.cast(usize, count) orelse return memoryError(Value);
    const output = heap.allocator.alloc(Value, output_len) catch return memoryError(Value);
    defer heap.allocator.free(output);
    for (0..amount) |repeat_index| @memcpy(output[repeat_index * source.len ..][0..source.len], source);
    return if (list != null) listValue(createList(heap, output)) else tupleValue(createTuple(heap, output));
}

/// Returns the number of output elements to copy when repeat's arguments are
/// valid and the result size is physically representable. A null result leaves
/// error classification to repeat(), which preserves Python's TypeError,
/// OverflowError, and MemoryError ordering.
pub fn repeatWorkCost(sequence_value: Value, multiplier: Value) ?usize {
    if (!number.isIntegerValue(multiplier)) return null;
    const count = if (multiplier.asBool()) |boolean|
        @as(i64, @intFromBool(boolean))
    else
        number.toInt(i64, multiplier) orelse return null;
    if (count <= 0) return 0;
    const source_len = length(sequence_value) orelse return null;
    if (source_len == 0) return 0;
    const source_count = std.math.cast(i64, source_len) orelse return null;
    const output_len_i64 = std.math.mul(i64, source_count, count) catch return null;
    return std.math.cast(usize, output_len_i64);
}

/// Returns the total session allocation requested by repeat() before it
/// copies the completed result into registers: its temporary Value slice, the
/// result object, and the result's backing allocation (including ArrayList's
/// actual growth capacity for lists).
pub fn repeatAllocationEstimate(sequence_value: Value, output_len: usize) ?usize {
    const header = sequence_value.asObject() orelse return null;
    const object_bytes: usize = if (listFromHeader(header) != null)
        @sizeOf(List)
    else if (tupleFromHeader(header) != null)
        @sizeOf(Tuple)
    else
        return null;

    var total = object_bytes;
    if (output_len == 0) return total;
    const temporary_bytes = std.math.mul(usize, output_len, @sizeOf(Value)) catch return null;
    total = std.math.add(usize, total, temporary_bytes) catch return null;
    const backing_count = if (listFromHeader(header) != null)
        std.ArrayList(Value).growCapacity(output_len)
    else
        output_len;
    const backing_bytes = std.math.mul(usize, backing_count, @sizeOf(Value)) catch return null;
    return std.math.add(usize, total, backing_bytes) catch return null;
}

pub fn length(value: Value) ?usize {
    const header = value.asObject() orelse return null;
    if (listFromHeader(header)) |list| return list.items.items.len;
    if (tupleFromHeader(header)) |tuple| return tuple.items.len;
    return null;
}

pub fn itemAt(value: Value, index_value: usize) ?Value {
    const header = value.asObject() orelse return null;
    if (listFromHeader(header)) |list| return if (index_value < list.items.items.len) list.items.items[index_value] else null;
    if (tupleFromHeader(header)) |tuple| return if (index_value < tuple.items.len) tuple.items[index_value] else null;
    return null;
}

fn concatValues(heap: *gc.Heap, left: []const Value, right: []const Value, is_tuple: bool) ValueResult {
    const item_count = std.math.add(usize, left.len, right.len) catch return memoryError(Value);
    const values = heap.allocator.alloc(Value, item_count) catch return memoryError(Value);
    defer heap.allocator.free(values);
    @memcpy(values[0..left.len], left);
    @memcpy(values[left.len..], right);
    return if (is_tuple) tupleValue(createTuple(heap, values)) else listValue(createList(heap, values));
}

fn overlaps(storage: []const Value, source: []const Value) bool {
    if (storage.len == 0 or source.len == 0) return false;
    const storage_start = @intFromPtr(storage.ptr);
    const source_start = @intFromPtr(source.ptr);
    const storage_end = storage_start + storage.len * @sizeOf(Value);
    const source_end = source_start + source.len * @sizeOf(Value);
    return storage_start < source_end and source_start < storage_end;
}

fn listValue(result: ListResult) ValueResult {
    return switch (result) {
        .value => |list| .{ .value = Value.object(&list.header) },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
    };
}

fn tupleValue(result: TupleResult) ValueResult {
    return switch (result) {
        .value => |tuple| .{ .value = Value.object(&tuple.header) },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
    };
}

fn traceList(header: *gc.Header, tracer: *gc.Tracer) void {
    const list: *List = @ptrCast(@alignCast(header));
    for (list.items.items) |value| tracer.visit(value.asObject());
}

fn traceTuple(header: *gc.Header, tracer: *gc.Tracer) void {
    const tuple: *Tuple = @ptrCast(@alignCast(header));
    for (tuple.items) |value| tracer.visit(value.asObject());
}

fn destroyList(header: *gc.Header, allocator: std.mem.Allocator) void {
    const list: *List = @ptrCast(@alignCast(header));
    list.items.deinit(allocator);
}

fn destroyTuple(header: *gc.Header, allocator: std.mem.Allocator) void {
    const tuple: *Tuple = @ptrCast(@alignCast(header));
    if (tuple.items.len != 0) allocator.free(tuple.items);
    tuple.items = &.{};
}

fn pythonError(comptime T: type, kind: exceptions.PythonExceptionKind, message: []const u8) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}

fn memoryError(comptime T: type) exceptions.Result(T) {
    return pythonError(T, .memory_error, "session memory limit exceeded");
}
