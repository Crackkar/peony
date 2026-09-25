const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const bytes = @import("runtime_bytes");
const sequence = @import("runtime_sequence");
const slice_utils = @import("runtime_slice");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const file_module = @import("runtime_file");

const Heap = gc.Heap;
const Value = value_module.Value;
pub const IteratorMode = enum { basic, enumerate, zip, reversed, map, filter, generator };

const IteratorInitial = struct {
    mode: IteratorMode = .basic,
    range: ?*Range = null,
    current: Value = Value.noneValue(),
    text: ?*string.Str = null,
    sequence_value: Value = Value.noneValue(),
    byte_string: ?*bytes.Bytes = null,
    inner: ?*Iterator = null,
    enumerate_index: Value = Value.noneValue(),
    reverse_source: Value = Value.noneValue(),
    reverse_index: usize = 0,
    mapping_iterator: ?*dict_module.DictIterator = null,
    callback: Value = Value.noneValue(),
    user_object: ?Value = null,
};

pub const Range = struct {
    header: gc.Header align(8),
    start: Value,
    stop: Value,
    step: Value,
};

pub const Iterator = struct {
    // Zig's default struct layout moves this header behind the other
    // align-8 fields; align-16 pins the GC header at byte offset zero.
    header: gc.Header align(16),
    mode: IteratorMode = .basic,
    range: ?*Range = null,
    current: Value = Value.noneValue(),
    text: ?*string.Str = null,
    sequence_value: Value = Value.noneValue(),
    byte_string: ?*bytes.Bytes = null,
    sequence_index: usize = 0,
    child_index: usize = 0,
    byte_offset: usize = 0,
    inner: ?*Iterator = null,
    children: []?*Iterator = &.{},
    values: []Value = &.{},
    enumerate_index: Value = Value.noneValue(),
    enumerate_values: [2]Value = .{ Value.noneValue(), Value.noneValue() },
    reverse_source: Value = Value.noneValue(),
    reverse_index: usize = 0,
    mapping_iterator: ?*dict_module.DictIterator = null,
    callback: Value = Value.noneValue(),
    user_object: ?Value = null,
    callback_pending: bool = false,
    finished: bool = false,
    started: bool = false,
    generator_frame: ?*anyopaque = null,
    generator_roots: []gc.Root = &.{},
    generator_done: bool = false,
    generator_yielded: ?Value = null,
    generator_frame_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    generator_function: bool = false,
    generator_send_value: Value = Value.noneValue(),
    generator_yield_register: ?u16 = null,
    generator_return_value: Value = Value.noneValue(),
    generator_return_pending: bool = false,
    generator_closing: bool = false,
};

pub const NextResult = union(enum) {
    item: Value,
    done,
    suspended,
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
    tracer.visit(iterator.sequence_value.asObject());
    if (iterator.byte_string) |byte_string| tracer.visit(&byte_string.header);
    tracer.visit(iterator.current.asObject());
    if (iterator.inner) |inner| tracer.visit(&inner.header);
    if (iterator.mapping_iterator) |mapping_iterator| tracer.visit(&mapping_iterator.header);
    for (iterator.children) |child| if (child) |selected| tracer.visit(&selected.header);
    for (iterator.values) |value| tracer.visit(value.asObject());
    tracer.visit(iterator.enumerate_index.asObject());
    for (iterator.enumerate_values) |value| tracer.visit(value.asObject());
    tracer.visit(iterator.reverse_source.asObject());
    tracer.visit(iterator.callback.asObject());
    if (iterator.user_object) |user| tracer.visit(user.asObject());
    if (iterator.generator_yielded) |value| tracer.visit(value.asObject());
    tracer.visit(iterator.generator_send_value.asObject());
    tracer.visit(iterator.generator_return_value.asObject());
    for (iterator.generator_roots) |root| tracer.visit(root.object);
}

fn destroyIterator(header: *gc.Header, allocator: std.mem.Allocator) void {
    const iterator: *Iterator = @ptrCast(@alignCast(header));
    if (iterator.children.len != 0) allocator.free(iterator.children);
    if (iterator.values.len != 0) allocator.free(iterator.values);
    iterator.children = &.{};
    iterator.values = &.{};
    if (iterator.generator_frame) |frame| {
        if (iterator.generator_frame_destroy) |destroy| destroy(frame, allocator);
    }
    iterator.generator_frame = null;
    iterator.generator_roots = &.{};
}

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

/// Return the exact Python integer length, without imposing Py_ssize_t limits.
pub fn rangeLength(heap: *Heap, range: *Range) exceptions.Result(Value) {
    var roots = RangeMathRoots{};
    roots.push(heap, range);
    defer roots.pop();
    const ordering = number.compare(range.start, range.stop);
    const order = switch (ordering) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    const positive_step = numberIsPositive(range.step);
    if ((positive_step and order != .less) or (!positive_step and order != .greater)) return smallInteger(0);
    const distance_result = if (positive_step) number.subtract(heap, range.stop, range.start) else number.subtract(heap, range.start, range.stop);
    const distance = resultValue(distance_result) orelse return numericFailure(Value, distance_result);
    roots.set(1, distance);
    const stride_result = if (positive_step) identityValue(range.step) else number.negative(heap, range.step);
    const stride = switch (stride_result) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    roots.set(2, stride);
    const distance_minus_one_result = number.subtract(heap, distance, smallValue(1));
    const distance_minus_one = resultValue(distance_minus_one_result) orelse return numericFailure(Value, distance_minus_one_result);
    roots.set(3, distance_minus_one);
    const quotient_result = number.floorDiv(heap, distance_minus_one, stride);
    const quotient = resultValue(quotient_result) orelse return numericFailure(Value, quotient_result);
    roots.set(4, quotient);
    const count_result = number.add(heap, quotient, smallValue(1));
    const count = resultValue(count_result) orelse return numericFailure(Value, count_result);
    roots.set(5, count);
    return .{ .value = count };
}

pub fn rangeIndex(heap: *Heap, range: *Range, index_value: Value) exceptions.Result(Value) {
    if (!number.isIntegerValue(index_value)) return pythonError(Value, .type_error, "range indices must be integers or slices");
    var roots = RangeMathRoots{};
    roots.push(heap, range);
    defer roots.pop();
    var index = normalizeIntegerArgument(index_value);
    roots.set(1, index);
    if (compareToZero(index) == .less) {
        const length_result = rangeLength(heap, range);
        const length = switch (length_result) {
            .value => |value| value,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        };
        roots.set(2, length);
        const adjusted_result = number.add(heap, index, length);
        index = switch (adjusted_result) {
            .value => |value| value,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        };
        roots.set(1, index);
    }
    if (compareToZero(index) == .less) return pythonError(Value, .index_error, "range object index out of range");
    const length_result = rangeLength(heap, range);
    const length = switch (length_result) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    roots.set(2, length);
    if (compareOrderResult(number.compare(index, length)) != .less) return pythonError(Value, .index_error, "range object index out of range");
    const offset_result = number.multiply(heap, index, range.step);
    const offset = resultValue(offset_result) orelse return numericFailure(Value, offset_result);
    roots.set(3, offset);
    const result = number.add(heap, range.start, offset);
    return switch (result) {
        .value => |value| .{ .value = value },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
    };
}

pub fn rangeSlice(heap: *Heap, range: *Range, slice_object: *slice_utils.Slice) exceptions.Result(*Range) {
    var roots = RangeMathRoots{};
    roots.push(heap, range);
    defer roots.pop();
    const length_result = rangeLength(heap, range);
    const length = switch (length_result) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    roots.set(1, length);
    const step = if (slice_object.step.tag() == .none) smallValue(1) else normalizeIntegerArgument(slice_object.step);
    if (!number.isIntegerValue(step)) return pythonError(*Range, .type_error, "slice indices must be integers or None");
    if (number.isZeroValue(step)) return pythonError(*Range, .value_error, "slice step cannot be zero");
    roots.set(2, step);
    const positive_slice_step = numberIsPositive(step);
    const start_default_result = if (positive_slice_step) smallInteger(0) else subtractOne(heap, length);
    const start_default = switch (start_default_result) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    const stop_default = if (positive_slice_step) length else minusOne();
    roots.set(3, start_default);
    roots.set(4, stop_default);
    const start_result = normalizeRangeBound(heap, slice_object.start, start_default, length, positive_slice_step);
    const start = switch (start_result) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    roots.set(5, start);
    const stop_result = normalizeRangeBound(heap, slice_object.stop, stop_default, length, positive_slice_step);
    const stop = switch (stop_result) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    roots.set(6, stop);
    const start_offset_result = number.multiply(heap, start, range.step);
    const start_offset = resultValue(start_offset_result) orelse return numericFailure(*Range, start_offset_result);
    roots.set(7, start_offset);
    const new_start_result = number.add(heap, range.start, start_offset);
    const new_start = resultValue(new_start_result) orelse return numericFailure(*Range, new_start_result);
    roots.set(8, new_start);
    const stop_offset_result = number.multiply(heap, stop, range.step);
    const stop_offset = resultValue(stop_offset_result) orelse return numericFailure(*Range, stop_offset_result);
    roots.set(9, stop_offset);
    const new_stop_result = number.add(heap, range.start, stop_offset);
    const new_stop = resultValue(new_stop_result) orelse return numericFailure(*Range, new_stop_result);
    roots.set(10, new_stop);
    const new_step_result = number.multiply(heap, range.step, step);
    const new_step = resultValue(new_step_result) orelse return numericFailure(*Range, new_step_result);
    roots.set(11, new_step);
    return createRange(heap, &.{ new_start, new_stop, new_step });
}

fn normalizeRangeBound(heap: *Heap, bound: Value, default: Value, length: Value, positive_step: bool) exceptions.Result(Value) {
    if (bound.tag() == .none) return .{ .value = default };
    if (!number.isIntegerValue(bound)) return pythonError(Value, .type_error, "slice indices must be integers or None");
    var value = normalizeIntegerArgument(bound);
    var value_root = gc.Root{ .object = value.asObject() };
    var value_roots = gc.RootFrame{};
    value_roots.push(&heap.roots);
    value_roots.add(&value_root);
    defer value_roots.pop();
    if (compareToZero(value) == .less) {
        const add_result = number.add(heap, value, length);
        value = switch (add_result) {
            .value => |adjusted| adjusted,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        };
        value_root.object = value.asObject();
    }
    const min_value = if (positive_step) smallValue(0) else minusOne();
    const max_result = if (positive_step) identityValue(length) else subtractOne(heap, length);
    const max_value = switch (max_result) {
        .value => |selected| selected,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    if (compareToZero(value) == .less and positive_step) return .{ .value = min_value };
    if (compareOrderResult(number.compare(value, min_value)) == .less) return .{ .value = min_value };
    if (compareOrderResult(number.compare(value, max_value)) == .greater) return .{ .value = max_value };
    return .{ .value = value };
}

fn subtractOne(heap: *Heap, value: Value) exceptions.Result(Value) {
    return number.subtract(heap, value, smallValue(1));
}

fn identityValue(value: Value) exceptions.Result(Value) {
    return .{ .value = value };
}

fn smallInteger(value: i64) exceptions.Result(Value) {
    return .{ .value = smallValue(value) };
}

fn smallValue(value: i64) Value {
    return Value.fromSmallInt(value).?;
}

fn minusOne() Value {
    return smallValue(-1);
}

fn compareToZero(value: Value) number.Comparison {
    return switch (number.compare(value, smallValue(0))) {
        .value => |order| order,
        else => .equal,
    };
}

fn compareOrderResult(result: number.ComparisonResult) number.Comparison {
    return switch (result) {
        .value => |order| order,
        else => .unordered,
    };
}

const RangeMathRoots = struct {
    frame: gc.RootFrame = .{},
    roots: [12]gc.Root = [_]gc.Root{.{ .object = null }} ** 12,

    fn push(self: *RangeMathRoots, heap: *Heap, range: *Range) void {
        self.roots[0].object = &range.header;
        self.frame.push(&heap.roots);
        for (&self.roots) |*root| self.frame.add(root);
    }

    fn set(self: *RangeMathRoots, index: usize, value: Value) void {
        self.roots[index].object = value.asObject();
    }

    fn pop(self: *RangeMathRoots) void {
        self.frame.pop();
    }
};

pub fn rangeContains(heap: *Heap, range: *Range, item: Value) exceptions.Result(bool) {
    var range_root = gc.Root{ .object = &range.header };
    var range_roots = gc.RootFrame{};
    range_roots.push(&heap.roots);
    range_roots.add(&range_root);
    defer range_roots.pop();
    if (item.asFloat()) |float_value| {
        if (!std.math.isFinite(float_value) or @trunc(float_value) != float_value) return .{ .value = false };
        return switch (number.fromIntegralFloat(heap, float_value)) {
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
    var byte_string: ?*bytes.Bytes = null;
    var has_sequence = false;
    if (value.asObject()) |header| {
        if (iteratorFromHeader(header)) |existing| return .{ .value = existing };
        if (file_module.fromHeader(header) != null) return createInitialized(heap, .{ .sequence_value = value });
        if (dict_module.dictFromHeader(header)) |mapping| return createMappingIterator(heap, mapping, .keys);
        if (dict_module.viewFromHeader(header)) |view| return createMappingIterator(heap, view.owner, view.kind);
        range = rangeFromHeader(header);
        text = string.fromHeader(header);
        byte_string = bytes.fromHeader(header);
        has_sequence = sequence.length(value) != null;
    }
    if (range == null and text == null and byte_string == null and !has_sequence) return pythonError(*Iterator, .type_error, "object is not iterable");

    return createInitialized(heap, .{
        .range = range,
        .current = if (range) |selected| selected.start else Value.noneValue(),
        .text = text,
        .sequence_value = if (has_sequence) value else Value.noneValue(),
        .byte_string = byte_string,
    });
}

fn createMappingIterator(heap: *Heap, owner: *dict_module.Dict, kind: dict_module.ViewKind) exceptions.Result(*Iterator) {
    const created_mapping_iterator = dict_module.createIterator(heap, owner, kind);
    const mapping_iterator = switch (created_mapping_iterator) {
        .value => |selected| selected,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    var root = gc.Root{ .object = &mapping_iterator.header };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&root);
    defer roots.pop();
    return createInitialized(heap, .{ .mapping_iterator = mapping_iterator });
}

pub fn createEnumerate(heap: *Heap, value: Value, start: Value) exceptions.Result(*Iterator) {
    if (!number.isIntegerValue(start)) return pythonError(*Iterator, .type_error, "enumerate() start must be an integer");
    const inner_result = createIterator(heap, value);
    const inner = switch (inner_result) {
        .value => |selected| selected,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    var root = gc.Root{ .object = &inner.header };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&root);
    defer roots.pop();
    return createInitialized(heap, .{ .mode = .enumerate, .inner = inner, .enumerate_index = normalizeIntegerArgument(start) });
}

pub fn createZip(heap: *Heap, inputs: []const Value) exceptions.Result(*Iterator) {
    const wrapper_result = createInitialized(heap, .{ .mode = .zip });
    const wrapper = switch (wrapper_result) {
        .value => |selected| selected,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    var wrapper_root = gc.Root{ .object = &wrapper.header };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&wrapper_root);
    defer roots.pop();

    if (inputs.len == 0) return .{ .value = wrapper };
    wrapper.children = heap.allocator.alloc(?*Iterator, inputs.len) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    @memset(wrapper.children, null);
    wrapper.values = heap.allocator.alloc(Value, inputs.len) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    @memcpy(wrapper.values, inputs);
    for (wrapper.values, 0..) |input, index_value| {
        const child_result = createIterator(heap, input);
        switch (child_result) {
            .value => |child| wrapper.children[index_value] = child,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        }
    }
    @memset(wrapper.values, Value.noneValue());
    return .{ .value = wrapper };
}

pub fn createReversed(heap: *Heap, value: Value) exceptions.Result(*Iterator) {
    if (value.asObject()) |header| {
        if (rangeFromHeader(header)) |range| {
            var reversed_slice = slice_utils.Slice{
                .header = undefined,
                .step = Value.fromSmallInt(-1).?,
            };
            const reversed_result = rangeSlice(heap, range, &reversed_slice);
            const reversed_range = switch (reversed_result) {
                .value => |selected| selected,
                .python_exception => |exception| return .{ .python_exception = exception },
                .engine_error => |failure| return .{ .engine_error = failure },
            };
            var range_root = gc.Root{ .object = &reversed_range.header };
            var roots = gc.RootFrame{};
            roots.push(&heap.roots);
            roots.add(&range_root);
            defer roots.pop();
            return createIterator(heap, Value.object(&reversed_range.header));
        }
    }
    const length = if (sequence.length(value)) |count| count else if (value.asObject()) |header| blk: {
        if (string.fromHeader(header)) |text| break :blk string.length(text);
        if (bytes.fromHeader(header)) |data| break :blk bytes.length(data);
        return pythonError(*Iterator, .type_error, "object is not reversible");
    } else return pythonError(*Iterator, .type_error, "object is not reversible");
    return createInitialized(heap, .{ .mode = .reversed, .reverse_source = value, .reverse_index = length });
}

pub fn createMapFilter(heap: *Heap, is_filter: bool, callback: Value, sources: []const Value) exceptions.Result(*Iterator) {
    if (sources.len == 0 or (is_filter and sources.len != 1)) return pythonError(*Iterator, .type_error, "invalid map or filter iterable count");
    const children = heap.allocator.alloc(?*Iterator, sources.len) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    @memset(children, null);
    const values = heap.allocator.alloc(Value, sources.len) catch {
        heap.allocator.free(children);
        return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    };
    var arrays_owned = true;
    defer if (arrays_owned) {
        heap.allocator.free(values);
        heap.allocator.free(children);
    };
    @memset(values, Value.noneValue());
    const root_count = sources.len * 2 + 1;
    const roots = heap.allocator.alloc(gc.Root, root_count) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    defer heap.allocator.free(roots);
    @memset(roots, .{ .object = null });
    roots[0].object = callback.asObject();
    for (sources, 0..) |source, index| roots[index + 1].object = source.asObject();
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    for (roots) |*root| frame.add(root);
    defer frame.pop();
    for (sources, 0..) |source, index| {
        const source_result = createIterator(heap, source);
        const source_iterator = switch (source_result) {
            .value => |selected| selected,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        };
        children[index] = source_iterator;
        roots[sources.len + 1 + index].object = &source_iterator.header;
    }
    const created = createInitialized(heap, .{ .mode = if (is_filter) .filter else .map, .inner = children[0], .callback = callback });
    const result = switch (created) {
        .value => |selected| selected,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    result.children = children;
    result.values = values;
    arrays_owned = false;
    return .{ .value = result };
}

pub fn createGenerator(heap: *Heap, callback: Value, outer: Value) exceptions.Result(*Iterator) {
    const header = outer.asObject() orelse return pythonError(*Iterator, .type_error, "generator outer expression is not an iterator");
    const source_iterator = iteratorFromHeader(header) orelse return pythonError(*Iterator, .type_error, "generator outer expression is not an iterator");
    var roots = [_]gc.Root{ .{ .object = callback.asObject() }, .{ .object = &source_iterator.header } };
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    for (&roots) |*root| frame.add(root);
    defer frame.pop();
    return createInitialized(heap, .{ .mode = .generator, .inner = source_iterator, .callback = callback });
}

pub fn createFunctionGenerator(heap: *Heap, callback: Value, bound_values: []const Value) exceptions.Result(*Iterator) {
    const allocator = heap.allocator;
    const roots = allocator.alloc(gc.Root, bound_values.len + 2) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    defer allocator.free(roots);
    @memset(roots, .{ .object = null });
    roots[0].object = callback.asObject();
    for (bound_values, 0..) |value, index| roots[index + 1].object = value.asObject();
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    for (roots) |*root| frame.add(root);
    defer frame.pop();

    const created = createInitialized(heap, .{ .mode = .generator, .callback = callback });
    const selected = switch (created) {
        .value => |value| value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    roots[bound_values.len + 1].object = &selected.header;
    const owned = allocator.dupe(Value, bound_values) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    selected.values = owned;
    selected.generator_function = true;
    return .{ .value = selected };
}

pub fn createUserIterator(heap: *Heap, user: Value) exceptions.Result(*Iterator) {
    return createInitialized(heap, .{ .user_object = user });
}

pub fn deferredKind(selected: *const Iterator) ?enum { map, filter, generator } {
    return switch (selected.mode) {
        .map => .map,
        .filter => .filter,
        .generator => .generator,
        else => null,
    };
}

fn createInitialized(heap: *Heap, initial: IteratorInitial) exceptions.Result(*Iterator) {
    const iterator = heap.createObject(Iterator, &iterator_kind) catch return pythonError(*Iterator, .memory_error, "session memory limit exceeded");
    const header = iterator.header;
    iterator.* = .{
        .header = header,
        .mode = initial.mode,
        .range = initial.range,
        .current = initial.current,
        .text = initial.text,
        .sequence_value = initial.sequence_value,
        .byte_string = initial.byte_string,
        .inner = initial.inner,
        .enumerate_index = initial.enumerate_index,
        .reverse_source = initial.reverse_source,
        .reverse_index = initial.reverse_index,
        .mapping_iterator = initial.mapping_iterator,
        .callback = initial.callback,
        .user_object = initial.user_object,
    };
    return .{ .value = iterator };
}

pub fn next(heap: *Heap, iterator: *Iterator) NextResult {
    switch (iterator.mode) {
        .enumerate => return nextEnumerate(heap, iterator),
        .zip => return nextZip(heap, iterator),
        .reversed => return nextReversed(heap, iterator),
        .basic, .map, .filter, .generator => {},
    }
    if (iterator.range) |range| return nextRange(heap, iterator, range);
    if (iterator.sequence_value.asObject()) |sequence_header| {
        if (file_module.fromHeader(sequence_header)) |file| {
            const line = file_module.readBuffer(heap, file.fs, file, null, true);
            const contents = switch (line) {
                .value => |selected| selected,
                .python_exception => |exception| return .{ .python_exception = exception },
                .engine_error => |failure| return .{ .engine_error = failure },
            };
            defer if (contents.len != 0) heap.allocator.free(contents);
            if (contents.len == 0) return .done;
            if (file.mode.binary) return switch (bytes.create(heap, contents)) {
                .value => |item| .{ .item = Value.object(&item.header) },
                .python_exception => |exception| .{ .python_exception = exception },
                .engine_error => |failure| .{ .engine_error = failure },
            };
            return switch (string.create(heap, contents)) {
                .value => |item| .{ .item = Value.object(&item.header) },
                .python_exception => |exception| .{ .python_exception = exception },
                .engine_error => |failure| .{ .engine_error = failure },
            };
        }
    }
    if (iterator.mapping_iterator) |mapping_iterator| return switch (dict_module.next(heap, mapping_iterator)) {
        .item => |item| .{ .item = item },
        .done => .done,
        .python_exception => |exception| .{ .python_exception = exception },
    };
    if (iterator.sequence_value.asObject() != null) {
        const length_value = sequence.length(iterator.sequence_value) orelse return .{ .engine_error = .internal_invariant };
        if (iterator.sequence_index >= length_value) return .done;
        const value = sequence.itemAt(iterator.sequence_value, iterator.sequence_index) orelse return .{ .engine_error = .internal_invariant };
        iterator.sequence_index += 1;
        return .{ .item = value };
    }
    if (iterator.byte_string) |byte_string| {
        if (iterator.sequence_index >= byte_string.data.len) return .done;
        const value = value_module.Value.fromSmallInt(byte_string.data[iterator.sequence_index]).?;
        iterator.sequence_index += 1;
        return .{ .item = value };
    }
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

fn nextEnumerate(heap: *Heap, iterator: *Iterator) NextResult {
    const inner = iterator.inner orelse return .{ .engine_error = .internal_invariant };
    switch (next(heap, inner)) {
        .item => |item| {
            iterator.enumerate_values[0] = iterator.enumerate_index;
            iterator.enumerate_values[1] = item;
            const advanced = number.add(heap, iterator.enumerate_index, smallValue(1));
            iterator.enumerate_index = switch (advanced) {
                .value => |value| value,
                .python_exception => |exception| return .{ .python_exception = exception },
                .engine_error => |failure| return .{ .engine_error = failure },
            };
            const tuple = sequence.createTuple(heap, &iterator.enumerate_values);
            return switch (tuple) {
                .value => |value| .{ .item = Value.object(&value.header) },
                .python_exception => |exception| .{ .python_exception = exception },
                .engine_error => |failure| .{ .engine_error = failure },
            };
        },
        .done => return .done,
        .suspended => return .{ .engine_error = .internal_invariant },
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    }
}

fn nextZip(heap: *Heap, iterator: *Iterator) NextResult {
    if (iterator.children.len == 0) return .done;
    for (iterator.children, 0..) |maybe_child, index_value| {
        const child = maybe_child orelse return .{ .engine_error = .internal_invariant };
        switch (next(heap, child)) {
            .item => |item| iterator.values[index_value] = item,
            .done => return .done,
            .suspended => return .{ .engine_error = .internal_invariant },
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        }
    }
    const tuple = sequence.createTuple(heap, iterator.values);
    return switch (tuple) {
        .value => |value| .{ .item = Value.object(&value.header) },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
    };
}

fn nextReversed(heap: *Heap, iterator: *Iterator) NextResult {
    if (iterator.reverse_index == 0) return .done;
    const object = iterator.reverse_source.asObject() orelse return .{ .engine_error = .internal_invariant };
    const index_value = iterator.reverse_index - 1;
    if (sequence.length(iterator.reverse_source)) |length| {
        if (index_value >= length) return .done;
        const item = sequence.itemAt(iterator.reverse_source, index_value) orelse return .{ .engine_error = .internal_invariant };
        iterator.reverse_index = index_value;
        return .{ .item = item };
    }
    if (string.fromHeader(object)) |text| {
        if (index_value >= string.length(text)) return .done;
        const machine_index = std.math.cast(i64, index_value) orelse return .{ .python_exception = .{ .kind = .overflow_error, .message = "reversed sequence is too large" } };
        return switch (string.index(heap, text, machine_index)) {
            .value => |item| blk: {
                iterator.reverse_index = index_value;
                break :blk .{ .item = Value.object(&item.header) };
            },
            .python_exception => |exception| .{ .python_exception = exception },
            .engine_error => |failure| .{ .engine_error = failure },
        };
    }
    if (bytes.fromHeader(object)) |data| {
        if (index_value >= data.data.len) return .done;
        iterator.reverse_index = index_value;
        return .{ .item = Value.fromSmallInt(data.data[index_value]).? };
    }
    return .{ .engine_error = .internal_invariant };
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
