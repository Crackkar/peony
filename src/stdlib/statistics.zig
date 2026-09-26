const std = @import("std");
const binder = @import("runtime_binder");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const number = @import("runtime_number");
const types = @import("types.zig");

const Value = types.Value;

const Function = enum(u16) {
    mean = 1,
    fmean,
    median,
    mode,
};

pub const functions = [_]types.FunctionSpec{
    .{ .id = @intFromEnum(Function.mean), .name = "mean", .params = &.{.{ .name = "data" }} },
    .{ .id = @intFromEnum(Function.fmean), .name = "fmean", .params = &.{
        .{ .name = "data" },
        .{ .name = "weights", .default = .none },
    } },
    .{ .id = @intFromEnum(Function.median), .name = "median", .params = &.{.{ .name = "data" }} },
    .{ .id = @intFromEnum(Function.mode), .name = "mode", .params = &.{.{ .name = "data" }} },
};

const ModuleState = struct {
    header: gc.Header align(8),
    error_class: *exceptions.ExceptionClass,
};

const module_state_kind = gc.Kind{ .trace = traceModuleState };

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const error_class = switch (exceptions.createNativeClass(&self.heap, "StatisticsError", .value_error, null)) {
        .value => |class| class,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var class_root = gc.Root{ .object = &error_class.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&class_root);
    defer roots.pop();
    if (!self.environmentStore(environment, "StatisticsError", Value.object(&error_class.header))) return memoryFailure(self, line, column);
    const state = self.heap.createObject(ModuleState, &module_state_kind) catch return memoryFailure(self, line, column);
    state.* = .{ .header = state.header, .error_class = error_class };
    var state_root = gc.Root{ .object = &state.header };
    roots.add(&state_root);
    for (functions) |spec| if (!storeBoundFunction(self, environment, state, spec, line, column)) return false;
    return true;
}

fn storeBoundFunction(self: anytype, environment: *gc.Header, state: *ModuleState, spec: types.FunctionSpec, line: u32, column: u32) bool {
    const created = functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.statistics), spec.id, Value.object(&state.header));
    const callable = switch (created) {
        .value => |function| Value.object(&function.header),
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    };
    var callable_root = gc.Root{ .object = callable.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&callable_root);
    defer roots.pop();
    if (self.environmentStore(environment, spec.name, callable)) return true;
    return memoryFailure(self, line, column);
}

fn traceModuleState(header: *gc.Header, tracer: *gc.Tracer) void {
    const state: *ModuleState = @ptrCast(@alignCast(header));
    tracer.visit(&state.error_class.header);
}

/// Shewchuk-style non-overlapping partial sums for `statistics.fmean` and the
/// mixed-float path of `mean`. Storage is caller-accounted and reusable.
pub const StableSum = struct {
    allocator: std.mem.Allocator,
    partials: std.ArrayList(f64) = .empty,
    positive_infinity: bool = false,
    negative_infinity: bool = false,
    saw_nan: bool = false,

    pub fn init(allocator: std.mem.Allocator) StableSum {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StableSum) void {
        self.partials.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *StableSum, value: f64) !void {
        if (std.math.isNan(value)) {
            self.saw_nan = true;
            return;
        }
        if (std.math.isPositiveInf(value)) {
            self.positive_infinity = true;
            return;
        }
        if (std.math.isNegativeInf(value)) {
            self.negative_infinity = true;
            return;
        }
        var x = value;
        var output_index: usize = 0;
        for (self.partials.items) |partial| {
            var y = partial;
            if (@abs(x) < @abs(y)) std.mem.swap(f64, &x, &y);
            const high = x + y;
            const low = y - (high - x);
            if (low != 0.0) {
                self.partials.items[output_index] = low;
                output_index += 1;
            }
            x = high;
        }
        if (std.math.isInf(x)) return error.IntermediateOverflow;
        self.partials.shrinkRetainingCapacity(output_index);
        try self.partials.append(self.allocator, x);
    }

    pub fn total(self: *const StableSum) f64 {
        if (self.saw_nan or (self.positive_infinity and self.negative_infinity)) return std.math.nan(f64);
        if (self.positive_infinity) return std.math.inf(f64);
        if (self.negative_infinity) return -std.math.inf(f64);
        var result: f64 = 0;
        var index = self.partials.items.len;
        while (index != 0) {
            index -= 1;
            result += self.partials.items[index];
        }
        return result;
    }
};

const Phase = enum { data, weights };

const TaskPayload = struct {
    allocator: std.mem.Allocator,
    operation: Function,
    phase: Phase = .data,
    count: usize = 0,
    integer_sum: Value = Value.fromSmallInt(0).?,
    all_integer: bool = true,
    stable: StableSum,
    weight_total: StableSum,
    weighted_total: StableSum,
    values: std.ArrayList(Value) = .empty,
    numeric_values: std.ArrayList(f64) = .empty,
    mode_counts: ?*dict_module.Dict = null,
    mode_order: std.ArrayList(Value) = .empty,
    error_class: *exceptions.ExceptionClass,
};

pub fn execute(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    function_id: u16,
    receiver: Value,
    args: []const Value,
    extra: []const binder.Keyword,
    line: u32,
    column: u32,
) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const operation = std.enums.fromInt(Function, function_id) orelse return self.engineFault();
    const state = moduleState(receiver) orelse return self.engineFault();
    return startTask(Runtime, self, destination, operation, state.error_class, args, line, column);
}

fn startTask(comptime Runtime: type, self: *Runtime, destination: u16, operation: Function, error_class: *exceptions.ExceptionClass, args: []const Value, line: u32, column: u32) bool {
    const data_iterator = createIteratorValue(Runtime, self, args[0], line, column) orelse return false;
    var data_root = gc.Root{ .object = data_iterator.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&data_root);
    defer roots.pop();

    var weights_iterator = Value.noneValue();
    if (operation == .fmean and args[1].tag() != .none) {
        weights_iterator = createIteratorValue(Runtime, self, args[1], line, column) orelse return false;
    }
    var weights_root = gc.Root{ .object = weights_iterator.asObject() };
    roots.add(&weights_root);
    var error_root = gc.Root{ .object = &error_class.header };
    roots.add(&error_root);

    const payload = self.heap.allocator.create(TaskPayload) catch return memoryFailure(self, line, column);
    payload.* = .{
        .allocator = self.heap.allocator,
        .operation = operation,
        .stable = StableSum.init(self.heap.allocator),
        .weight_total = StableSum.init(self.heap.allocator),
        .weighted_total = StableSum.init(self.heap.allocator),
        .error_class = error_class,
    };
    var owns_payload = true;
    defer if (owns_payload) destroyTaskPayload(payload, self.heap.allocator);

    var counts_root = gc.Root{ .object = null };
    roots.add(&counts_root);
    if (operation == .mode) {
        payload.mode_counts = switch (dict_module.create(&self.heap, false)) {
            .value => |mapping| mapping,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        counts_root.object = &payload.mode_counts.?.header;
    }

    const caller = self.top_frame orelse return self.engineFault();
    const inputs = [_]Value{ data_iterator, weights_iterator };
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        .statistics,
        @intFromEnum(operation),
        @ptrCast(caller),
        destination,
        line,
        column,
        &inputs,
        taskOps(Runtime),
    ) catch return memoryFailure(self, line, column);
    task.payload = payload;
    owns_payload = false;
    return self.startNativeTask(task);
}

fn createIteratorValue(comptime Runtime: type, self: *Runtime, source: Value, line: u32, column: u32) ?Value {
    return switch (self.createVmIterator(source, line, column)) {
        .value => |iterator_value| Value.object(&iterator_value.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
        .engine_error => blk: {
            _ = self.engineFault();
            break :blk null;
        },
    };
}

fn taskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return taskStep(Runtime, self, task);
        }

        const ops = types.TaskOps{
            .step = step,
            .trace_payload = traceTaskPayload,
            .destroy_payload = destroyTaskPayload,
        };
    }.ops;
}

fn taskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload = taskPayload(task) orelse return runtimeTaskError("invalid statistics task state");
    if (task.child_ready) {
        if (task.child_error != null) return .propagate;
        if (task.child_done) {
            clearChild(task);
            if (payload.operation == .fmean and payload.phase == .data and task.inputs[1].tag() != .none) {
                payload.phase = .weights;
                return .yield;
            }
            return finishTask(Runtime, self, task, payload);
        }
        const item = task.child_value;
        const processed = switch (payload.operation) {
            .mean => consumeMean(Runtime, self, payload, item),
            .fmean => if (payload.phase == .data)
                consumeFmeanData(Runtime, self, payload, item)
            else
                consumeFmeanWeight(Runtime, self, payload, item),
            .median => consumeMedian(payload, item),
            .mode => consumeMode(Runtime, self, task, payload, item),
        };
        clearChild(task);
        if (processed) |failure| return specializeStatisticsError(payload, failure);
    }
    return .{ .next = task.inputs[if (payload.phase == .data) 0 else 1] };
}

fn consumeMean(comptime Runtime: type, self: *Runtime, payload: *TaskPayload, item: Value) ?types.TaskStep {
    if (number.isIntegerValue(item) and payload.all_integer) {
        var result: Value = undefined;
        if (captureValue(number.add(&self.heap, payload.integer_sum, item), &result)) |failure| return failure;
        payload.integer_sum = result;
    } else {
        if (payload.all_integer) {
            var previous: f64 = undefined;
            if (captureFloat(number.toFloat(&self.heap, payload.integer_sum), &previous)) |failure| return failure;
            payload.stable.add(previous) catch return memoryOrOverflow();
            payload.all_integer = false;
        }
        var value: f64 = undefined;
        if (captureFloat(number.toFloat(&self.heap, item), &value)) |failure| return failure;
        payload.stable.add(value) catch return memoryOrOverflow();
    }
    payload.count += 1;
    return null;
}

fn consumeFmeanData(comptime Runtime: type, self: *Runtime, payload: *TaskPayload, item: Value) ?types.TaskStep {
    var value: f64 = undefined;
    if (captureFloat(number.toFloat(&self.heap, item), &value)) |failure| return failure;
    payload.numeric_values.append(payload.allocator, value) catch return memoryTaskError();
    if (payload.stable.add(value)) |_| {} else |_| return memoryOrOverflow();
    payload.count += 1;
    return null;
}

fn consumeFmeanWeight(comptime Runtime: type, self: *Runtime, payload: *TaskPayload, item: Value) ?types.TaskStep {
    const index = payload.values.items.len;
    if (index >= payload.numeric_values.items.len) return valueTaskError("data and weights must be the same length");
    var weight: f64 = undefined;
    if (captureFloat(number.toFloat(&self.heap, item), &weight)) |failure| return failure;
    payload.weight_total.add(weight) catch return memoryOrOverflow();
    payload.weighted_total.add(payload.numeric_values.items[index] * weight) catch return memoryOrOverflow();
    payload.values.append(payload.allocator, Value.noneValue()) catch return memoryTaskError();
    return null;
}

fn consumeMedian(payload: *TaskPayload, item: Value) ?types.TaskStep {
    if (!number.isIntegerValue(item) and item.asFloat() == null) return typeTaskError("statistics data must contain numbers");
    payload.values.append(payload.allocator, item) catch return memoryTaskError();
    payload.count += 1;
    return null;
}

fn consumeMode(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *TaskPayload, item: Value) ?types.TaskStep {
    const counts = payload.mode_counts.?;
    const key_hash = self.pythonHash(item, task.line, task.column) orelse return currentExceptionTask(self);
    var context = EqualityContext(Runtime){ .runtime = self, .line = task.line, .column = task.column };
    const lookup = dict_module.lookup(counts, item, key_hash, &context, equalityThunk(Runtime));
    switch (lookup) {
        .failed => return currentExceptionTask(self),
        .missing => {
            if (!self.setMappingValueWithHash(counts, item, Value.fromSmallInt(1).?, key_hash, task.line, task.column)) return currentExceptionTask(self);
            payload.mode_order.append(payload.allocator, item) catch return memoryTaskError();
        },
        .found => |index| {
            var incremented: Value = undefined;
            if (captureValue(number.add(&self.heap, counts.entries.items[index].value, Value.fromSmallInt(1).?), &incremented)) |failure| return failure;
            counts.entries.items[index].value = incremented;
        },
    }
    payload.count += 1;
    return null;
}

fn finishTask(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *TaskPayload) types.TaskStep {
    if (payload.count == 0) return statisticsTaskError(payload.error_class, "no data points");
    const result = switch (payload.operation) {
        .mean => finishMean(self, payload),
        .fmean => finishFmean(payload),
        .median => finishMedian(self, payload),
        .mode => finishMode(Runtime, self, task, payload),
    };
    return specializeStatisticsError(payload, result);
}

fn finishMean(self: anytype, payload: *TaskPayload) types.TaskStep {
    if (!payload.all_integer) return .{ .complete = Value.fromFloat(payload.stable.total() / @as(f64, @floatFromInt(payload.count))) };
    var divisor: Value = undefined;
    if (captureValue(number.fromInt(&self.heap, @intCast(payload.count)), &divisor)) |failure| return failure;
    var remainder: Value = undefined;
    if (captureValue(number.modulo(&self.heap, payload.integer_sum, divisor), &remainder)) |failure| return failure;
    if (number.isZeroValue(remainder)) {
        var quotient: Value = undefined;
        if (captureValue(number.floorDiv(&self.heap, payload.integer_sum, divisor), &quotient)) |failure| return failure;
        return .{ .complete = quotient };
    }
    var quotient: f64 = undefined;
    if (captureFloat(number.trueDivide(&self.heap, payload.integer_sum, divisor), &quotient)) |failure| return failure;
    return .{ .complete = Value.fromFloat(quotient) };
}

fn finishFmean(payload: *TaskPayload) types.TaskStep {
    if (payload.phase == .data) return .{ .complete = Value.fromFloat(payload.stable.total() / @as(f64, @floatFromInt(payload.count))) };
    if (payload.values.items.len != payload.numeric_values.items.len) return valueTaskError("data and weights must be the same length");
    const denominator = payload.weight_total.total();
    if (denominator == 0.0) return valueTaskError("sum of weights must be non-zero");
    return .{ .complete = Value.fromFloat(payload.weighted_total.total() / denominator) };
}

fn finishMedian(self: anytype, payload: *TaskPayload) types.TaskStep {
    if (sortMedianValues(payload)) |failure| return failure;
    const middle = payload.values.items.len / 2;
    if (payload.values.items.len % 2 == 1) return .{ .complete = payload.values.items[middle] };
    var pair_sum: Value = undefined;
    if (captureValue(number.add(&self.heap, payload.values.items[middle - 1], payload.values.items[middle]), &pair_sum)) |failure| return failure;
    var result: f64 = undefined;
    if (captureFloat(number.trueDivide(&self.heap, pair_sum, Value.fromSmallInt(2).?), &result)) |failure| return failure;
    return .{ .complete = Value.fromFloat(result) };
}

fn sortMedianValues(payload: *TaskPayload) ?types.TaskStep {
    const length = payload.values.items.len;
    if (length < 2) return null;
    const scratch = payload.allocator.alloc(Value, length) catch return memoryTaskError();
    defer payload.allocator.free(scratch);
    var source: []Value = payload.values.items;
    var destination: []Value = scratch;
    var width: usize = 1;
    while (width < length) {
        var run_start: usize = 0;
        while (run_start < length) {
            const middle = @min(run_start + width, length);
            const end = @min(middle + width, length);
            var left = run_start;
            var right = middle;
            var output = run_start;
            while (output < end) : (output += 1) {
                const take_left = if (left >= middle)
                    false
                else if (right >= end)
                    true
                else blk: {
                    const comparison = number.compare(source[left], source[right]);
                    const order = switch (comparison) {
                        .value => |value| value,
                        .python_exception => |exception| return .{ .raise = exception },
                        .engine_error => return runtimeTaskError("numeric comparison failed"),
                    };
                    break :blk order != .greater;
                };
                destination[output] = if (take_left) source[left] else source[right];
                if (take_left) left += 1 else right += 1;
            }
            run_start = end;
        }
        std.mem.swap([]Value, &source, &destination);
        if (width >= length - width) break;
        width *= 2;
    }
    if (source.ptr != payload.values.items.ptr) @memcpy(payload.values.items, source);
    return null;
}

fn finishMode(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *TaskPayload) types.TaskStep {
    const counts = payload.mode_counts.?;
    var best = payload.mode_order.items[0];
    var best_count = Value.fromSmallInt(-1).?;
    var context = EqualityContext(Runtime){ .runtime = self, .line = task.line, .column = task.column };
    for (payload.mode_order.items) |key| {
        const key_hash = self.pythonHash(key, task.line, task.column) orelse return currentExceptionTask(self);
        const found = dict_module.lookup(counts, key, key_hash, &context, equalityThunk(Runtime));
        const value = switch (found) {
            .found => |entry_index| counts.entries.items[entry_index].value,
            .missing, .failed => return runtimeTaskError("mode count table is inconsistent"),
        };
        const comparison = number.compare(value, best_count);
        const order = switch (comparison) {
            .value => |selected| selected,
            .python_exception => |exception| return .{ .raise = exception },
            .engine_error => return runtimeTaskError("mode count comparison failed"),
        };
        if (order == .greater) {
            best = key;
            best_count = value;
        }
    }
    return .{ .complete = best };
}

fn EqualityContext(comptime Runtime: type) type {
    return struct { runtime: *Runtime, line: u32, column: u32 };
}

fn equalityThunk(comptime Runtime: type) dict_module.EqualityFn {
    return struct {
        fn equal(raw: *anyopaque, left: Value, right: Value) ?bool {
            const context: *EqualityContext(Runtime) = @ptrCast(@alignCast(raw));
            return context.runtime.valuesEqual(left, right, context.line, context.column);
        }
    }.equal;
}

fn taskPayload(task: *types.Task) ?*TaskPayload {
    if (task.owner != .statistics) return null;
    return @ptrCast(@alignCast(task.payload orelse return null));
}

fn clearChild(task: *types.Task) void {
    task.child_ready = false;
    task.child_done = false;
    task.child_value = Value.noneValue();
    task.child_error = null;
}

fn traceTaskPayload(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *TaskPayload = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(&payload.error_class.header);
    tracer.visit(payload.integer_sum.asObject());
    if (payload.mode_counts) |counts| tracer.visit(&counts.header);
    for (payload.values.items) |value| tracer.visit(value.asObject());
    for (payload.mode_order.items) |value| tracer.visit(value.asObject());
}

fn destroyTaskPayload(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *TaskPayload = @ptrCast(@alignCast(raw orelse return));
    payload.stable.deinit();
    payload.weight_total.deinit();
    payload.weighted_total.deinit();
    payload.values.deinit(allocator);
    payload.numeric_values.deinit(allocator);
    payload.mode_order.deinit(allocator);
    allocator.destroy(payload);
}

fn captureValue(result: exceptions.Result(Value), output: *Value) ?types.TaskStep {
    return switch (result) {
        .value => |value| blk: {
            output.* = value;
            break :blk null;
        },
        .python_exception => |exception| .{ .raise = exception },
        .engine_error => runtimeTaskError("numeric operation failed"),
    };
}

fn captureFloat(result: exceptions.Result(f64), output: *f64) ?types.TaskStep {
    return switch (result) {
        .value => |value| blk: {
            output.* = value;
            break :blk null;
        },
        .python_exception => |exception| .{ .raise = exception },
        .engine_error => runtimeTaskError("numeric conversion failed"),
    };
}

fn currentExceptionTask(self: anytype) types.TaskStep {
    return .{ .raise = self.last_exception orelse .{ .kind = .runtime_error, .message = "statistics operation failed" } };
}

fn memoryFailure(self: anytype, line: u32, column: u32) bool {
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}

fn memoryTaskError() types.TaskStep {
    return .{ .raise = exceptions.memoryError() };
}

fn memoryOrOverflow() types.TaskStep {
    return .{ .raise = .{ .kind = .overflow_error, .message = "intermediate overflow in statistics operation" } };
}

fn typeTaskError(message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = .type_error, .message = message } };
}

fn valueTaskError(message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = .value_error, .message = message } };
}

fn statisticsTaskError(class: *exceptions.ExceptionClass, message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = .value_error, .message = message, .native_class = class } };
}

fn specializeStatisticsError(payload: *TaskPayload, step: types.TaskStep) types.TaskStep {
    return switch (step) {
        .raise => |exception| if (exception.kind == .value_error and exception.native_class == null)
            statisticsTaskError(payload.error_class, exception.message)
        else
            .{ .raise = exception },
        else => step,
    };
}

fn moduleState(value: Value) ?*ModuleState {
    const header = value.asObject() orelse return null;
    if (header.kind != &module_state_kind) return null;
    return @ptrCast(@alignCast(header));
}

fn runtimeTaskError(message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = .runtime_error, .message = message } };
}

test "stable sum preserves cancellation residual" {
    var sum = StableSum.init(std.testing.allocator);
    defer sum.deinit();
    try sum.add(1e16);
    try sum.add(1.0);
    try sum.add(-1e16);
    try std.testing.expectEqual(@as(f64, 1.0), sum.total());
}

test "stable sum handles non-finite values and reports intermediate overflow" {
    var sum = StableSum.init(std.testing.allocator);
    defer sum.deinit();
    try sum.add(std.math.inf(f64));
    try sum.add(-std.math.inf(f64));
    try std.testing.expect(std.math.isNan(sum.total()));

    var overflow = StableSum.init(std.testing.allocator);
    defer overflow.deinit();
    try overflow.add(std.math.floatMax(f64));
    try std.testing.expectError(error.IntermediateOverflow, overflow.add(std.math.floatMax(f64)));
}
