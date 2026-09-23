const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const exceptions = @import("runtime_exception");

const Heap = gc.Heap;
const Value = value_module.Value;

pub const Range = struct {
    header: gc.Header align(8),
    start: Value,
    stop: Value,
    step: Value,
};

pub const Iterator = struct {
    header: gc.Header align(8),
    range: ?*Range = null,
    current: Value = Value.noneValue(),
    text: ?*string.Str = null,
    byte_offset: usize = 0,
};

pub const NextResult = union(enum) {
    item: Value,
    done,
    python_exception: exceptions.PythonException,
    engine_error: exceptions.EngineError,
};

const range_kind = gc.Kind{ .trace = traceRange, .destroy = destroyRange };
const iterator_kind = gc.Kind{ .trace = traceIterator, .destroy = destroyIterator };

fn traceRange(header: *gc.Header, tracer: *gc.Tracer) void {
    const range: *Range = @ptrCast(@alignCast(header));
    tracer.visit(range.start.asObject());
    tracer.visit(range.stop.asObject());
    tracer.visit(range.step.asObject());
}

fn destroyRange(_: *gc.Header, _: @import("std").mem.Allocator) void {}

fn traceIterator(header: *gc.Header, tracer: *gc.Tracer) void {
    const iterator: *Iterator = @ptrCast(@alignCast(header));
    if (iterator.range) |range| tracer.visit(&range.header);
    if (iterator.text) |text| tracer.visit(&text.header);
    tracer.visit(iterator.current.asObject());
}

fn destroyIterator(_: *gc.Header, _: @import("std").mem.Allocator) void {}

pub fn rangeFromHeader(header: *gc.Header) ?*Range {
    if (header.kind != &range_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn iteratorFromHeader(header: *gc.Header) ?*Iterator {
    if (header.kind != &iterator_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn createRange(heap: *Heap, args: []const Value) exceptions.Result(*Range) {
    if (args.len == 0 or args.len > 3) return pythonError(*Range, .type_error, "range expected 1 to 3 arguments");
    for (args) |argument| {
        if (!number.isIntegerValue(argument)) return pythonError(*Range, .type_error, "range() arguments must be integers or have an __index__ method");
    }

    const start = if (args.len == 1) Value.fromSmallInt(0).? else normalizeIntegerArgument(args[0]);
    const stop = normalizeIntegerArgument(if (args.len == 1) args[0] else args[1]);
    const step = if (args.len == 3) normalizeIntegerArgument(args[2]) else Value.fromSmallInt(1).?;
    if (number.isZeroValue(step)) return pythonError(*Range, .value_error, "range() arg 3 must not be zero");

    const object = heap.createObject(Range, &range_kind) catch return pythonError(*Range, .memory_error, "session memory limit exceeded");
    object.start = start;
    object.stop = stop;
    object.step = step;
    return .{ .value = object };
}

fn normalizeIntegerArgument(value: Value) Value {
    if (value.asBool()) |boolean| return Value.fromSmallInt(if (boolean) 1 else 0).?;
    return value;
}

pub fn truthyRange(range: *const Range) exceptions.Result(bool) {
    const ordering = number.compare(range.start, range.stop);
    return switch (ordering) {
        .value => |order| .{ .value = if (number.isZeroValue(range.step)) false else if (numberIsPositive(range.step)) order == .less else order == .greater },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
    };
}

pub fn rangeContains(heap: *Heap, range: *Range, item: Value) exceptions.Result(bool) {
    var range_root = gc.Root{ .object = &range.header };
    var range_roots = gc.RootFrame{};
    range_roots.push(&heap.roots);
    range_roots.add(&range_root);
    defer range_roots.pop();
    if (item.asFloat()) |float_value| {
        if (!std.math.isFinite(float_value) or @trunc(float_value) != float_value) return .{ .value = false };
        if (@abs(float_value) >= 1.0e37) return .{ .value = false };
        const integer: i128 = @intFromFloat(float_value);
        return switch (number.fromInt(heap, integer)) {
            .value => |converted| blk: {
                var converted_root = gc.Root{ .object = converted.asObject() };
                var converted_roots = gc.RootFrame{};
                converted_roots.push(&heap.roots);
                converted_roots.add(&converted_root);
                defer converted_roots.pop();
                break :blk rangeContains(heap, range, converted);
            },
            .python_exception => |exception| .{ .python_exception = exception },
            .engine_error => |failure| .{ .engine_error = failure },
        };
    }
    if (!number.isIntegerValue(item)) return .{ .value = false };
    const lower_or_upper = number.compare(item, range.start);
    const stop_order = number.compare(item, range.stop);
    const first = compareValues(lower_or_upper) orelse return comparisonFailure(bool, lower_or_upper);
    const second = compareValues(stop_order) orelse return comparisonFailure(bool, stop_order);
    const inside = if (numberIsPositive(range.step)) first != .less and second == .less else first != .greater and second == .greater;
    if (!inside) return .{ .value = false };

    const difference = number.subtract(heap, item, range.start);
    const difference_value = resultValue(difference) orelse return numericFailure(bool, difference);
    var difference_root = gc.Root{ .object = difference_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&difference_root);
    defer roots.pop();
    const remainder = number.modulo(heap, difference_value, range.step);
    const remainder_value = resultValue(remainder) orelse return numericFailure(bool, remainder);
    return .{ .value = number.isZeroValue(remainder_value) };
}

pub fn createIterator(heap: *Heap, value: Value) exceptions.Result(*Iterator) {
    var range: ?*Range = null;
    var text: ?*string.Str = null;
    if (value.asObject()) |header| {
        range = rangeFromHeader(header);
        text = string.fromHeader(header);
    }
    if (range == null and text == null) return pythonError(*Iterator, .type_error, "object is not iterable");

    const iterator = heap.createObject(Iterator, &iterator_kind) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    iterator.range = range;
    iterator.current = if (range) |selected| selected.start else Value.noneValue();
    iterator.text = text;
    iterator.byte_offset = 0;
    return .{ .value = iterator };
}

pub fn next(heap: *Heap, iterator: *Iterator) NextResult {
    if (iterator.range) |range| return nextRange(heap, iterator, range);
    const text = iterator.text orelse return .{ .engine_error = .internal_invariant };
    if (iterator.byte_offset >= text.data.len) return .done;
    const start = iterator.byte_offset;
    const width = codepointWidth(text.data[start]);
    const end = start + width;
    iterator.byte_offset = end;
    return switch (string.create(heap, text.data[start..end])) {
        .value => |character| .{ .item = value_module.Value.object(&character.header) },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
    };
}

fn nextRange(heap: *Heap, iterator: *Iterator, range: *Range) NextResult {
    const order = number.compare(iterator.current, range.stop);
    const comparison = switch (order) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    if (if (numberIsPositive(range.step)) comparison != .less else comparison != .greater) return .done;

    const item = iterator.current;
    switch (number.add(heap, iterator.current, range.step)) {
        .value => |advanced| iterator.current = advanced,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    }
    return .{ .item = item };
}

fn numberIsPositive(value: Value) bool {
    const zero = Value.fromSmallInt(0).?;
    return switch (number.compare(value, zero)) {
        .value => |order| order == .greater,
        else => true,
    };
}

fn compareValues(result: number.ComparisonResult) ?number.Comparison {
    return switch (result) {
        .value => |comparison| comparison,
        else => null,
    };
}

fn comparisonFailure(comptime T: type, result: number.ComparisonResult) exceptions.Result(T) {
    return switch (result) {
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
        .value => unreachable,
    };
}

fn resultValue(result: number.ValueResult) ?Value {
    return switch (result) {
        .value => |value| value,
        else => null,
    };
}

fn numericFailure(comptime T: type, result: number.ValueResult) exceptions.Result(T) {
    return switch (result) {
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
        .value => unreachable,
    };
}

fn codepointWidth(first: u8) usize {
    if (first & 0x80 == 0) return 1;
    if (first & 0xe0 == 0xc0) return 2;
    if (first & 0xf0 == 0xe0) return 3;
    return 4;
}

fn pythonError(comptime T: type, kind: @import("runtime_exception").PythonExceptionKind, message: []const u8) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}
