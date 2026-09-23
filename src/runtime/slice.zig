const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const exceptions = @import("runtime_exception");

const Value = value_module.Value;

pub const Slice = struct {
    header: gc.Header align(8),
    start: Value = Value.noneValue(),
    stop: Value = Value.noneValue(),
    step: Value = Value.noneValue(),
};

pub const BoundedIndices = struct { start: i128, stop: i128, step: i128 };
pub const IndexResult = exceptions.Result(usize);
pub const IndicesResult = exceptions.Result(BoundedIndices);

const slice_kind = gc.Kind{ .trace = traceSlice };

pub fn fromHeader(header: *gc.Header) ?*Slice {
    if (header.kind != &slice_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn create(heap: *gc.Heap, start: Value, stop: Value, step: Value) exceptions.Result(*Slice) {
    const object = heap.createObject(Slice, &slice_kind) catch return memoryError(*Slice);
    const header = object.header;
    object.* = .{ .header = header, .start = start, .stop = stop, .step = step };
    return .{ .value = object };
}

pub fn normalize(length: usize, start_value: Value, stop_value: Value, step_value: Value) IndicesResult {
    const length_value: i128 = @intCast(length);
    const step = if (step_value.tag() == .none) 1 else boundedInteger(step_value, true) orelse return pythonError(BoundedIndices, .type_error, "slice indices must be integers or None");
    if (step == 0) return pythonError(BoundedIndices, .value_error, "slice step cannot be zero");

    if (step > 0) {
        const start = if (start_value.tag() == .none) 0 else normalizeBound(start_value, length_value, 0, length_value) orelse return pythonError(BoundedIndices, .type_error, "slice indices must be integers or None");
        const stop = if (stop_value.tag() == .none) length_value else normalizeBound(stop_value, length_value, 0, length_value) orelse return pythonError(BoundedIndices, .type_error, "slice indices must be integers or None");
        return .{ .value = .{ .start = start, .stop = stop, .step = step } };
    }

    const maximum = length_value - 1;
    const start = if (start_value.tag() == .none) maximum else normalizeBound(start_value, length_value, -1, maximum) orelse return pythonError(BoundedIndices, .type_error, "slice indices must be integers or None");
    const stop = if (stop_value.tag() == .none) -1 else normalizeBound(stop_value, length_value, -1, maximum) orelse return pythonError(BoundedIndices, .type_error, "slice indices must be integers or None");
    return .{ .value = .{ .start = start, .stop = stop, .step = step } };
}

pub fn normalizeIndex(length: usize, value: Value) IndexResult {
    const index_value = if (value.asBool()) |boolean|
        @as(i128, @intFromBool(boolean))
    else blk: {
        if (!number.isIntegerValue(value)) return pythonError(usize, .type_error, "sequence indices must be integers or slices");
        break :blk number.toInt(i128, value) orelse return pythonError(usize, .index_error, "sequence index out of range");
    };
    const length_value: i128 = @intCast(length);
    const normalized = if (index_value < 0) index_value + length_value else index_value;
    if (normalized < 0 or normalized >= length_value) return pythonError(usize, .index_error, "sequence index out of range");
    return .{ .value = @intCast(normalized) };
}

/// Shared bounded slice normalization for Unicode strings and bytes.
pub fn normalizeI64(length: i64, start: ?i64, stop: ?i64, step: i64) BoundedIndices {
    const size: i128 = length;
    const stride: i128 = step;
    if (stride > 0) return .{
        .start = clampI64(start orelse 0, size, 0, size),
        .stop = clampI64(stop orelse length, size, 0, size),
        .step = stride,
    };
    return .{
        .start = clampI64(start orelse length - 1, size, -1, size - 1),
        .stop = if (stop == null) -1 else clampI64(stop.?, size, -1, size - 1),
        .step = stride,
    };
}

fn clampI64(value: i64, length: i128, minimum: i128, maximum: i128) i128 {
    var normalized: i128 = value;
    if (normalized < 0) normalized += length;
    return @min(@max(normalized, minimum), maximum);
}

fn normalizeBound(value: Value, length: i128, minimum: i128, maximum: i128) ?i128 {
    var bound = boundedInteger(value, false) orelse return null;
    if (bound < 0) bound += length;
    return @min(@max(bound, minimum), maximum);
}

fn boundedInteger(value: Value, is_step: bool) ?i128 {
    if (!number.isIntegerValue(value)) return null;
    if (number.toInt(i128, value)) |integer| return integer;
    const comparison = number.compare(value, Value.fromSmallInt(0).?);
    const positive = switch (comparison) {
        .value => |order| order == .greater,
        else => return null,
    };
    if (is_step) return if (positive) std.math.maxInt(i64) else std.math.minInt(i64);
    return if (positive) std.math.maxInt(i128) else std.math.minInt(i128);
}

fn traceSlice(header: *gc.Header, tracer: *gc.Tracer) void {
    const value: *Slice = @ptrCast(@alignCast(header));
    tracer.visit(value.start.asObject());
    tracer.visit(value.stop.asObject());
    tracer.visit(value.step.asObject());
}

fn pythonError(comptime T: type, kind: exceptions.PythonExceptionKind, message: []const u8) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}

fn memoryError(comptime T: type) exceptions.Result(T) {
    return pythonError(T, .memory_error, "session memory limit exceeded");
}
