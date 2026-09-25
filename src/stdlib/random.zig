const std = @import("std");
const binder = @import("runtime_binder");
const bytes_module = @import("runtime_bytes");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const iterator = @import("runtime_iterator");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const string = @import("runtime_string");
const types = @import("types.zig");

const Value = types.Value;
const Function = enum(u16) {
    seed = 1,
    random,
    randint,
    randrange,
    choice,
    choices,
    shuffle,
    sample,
    uniform,
};

pub const functions = [_]types.FunctionSpec{
    .{ .id = @intFromEnum(Function.seed), .name = "seed", .params = &.{
        .{ .name = "a", .default = .none },
        .{ .name = "version", .default = .{ .integer = 2 } },
    } },
    .{ .id = @intFromEnum(Function.random), .name = "random" },
    .{ .id = @intFromEnum(Function.randint), .name = "randint", .params = &.{ .{ .name = "a" }, .{ .name = "b" } } },
    .{ .id = @intFromEnum(Function.randrange), .name = "randrange", .params = &.{
        .{ .name = "start" },
        .{ .name = "stop", .default = .none },
        .{ .name = "step", .default = .{ .integer = 1 } },
    } },
    .{ .id = @intFromEnum(Function.choice), .name = "choice", .params = &.{.{ .name = "seq" }} },
    .{ .id = @intFromEnum(Function.choices), .name = "choices", .params = &.{
        .{ .name = "population" },
        .{ .name = "weights", .default = .none },
        .{ .name = "cum_weights", .flags = binder.parameter_flags_module.keyword_only, .default = .none },
        .{ .name = "k", .flags = binder.parameter_flags_module.keyword_only, .default = .{ .integer = 1 } },
    } },
    .{ .id = @intFromEnum(Function.shuffle), .name = "shuffle", .params = &.{.{ .name = "x" }} },
    .{ .id = @intFromEnum(Function.sample), .name = "sample", .params = &.{
        .{ .name = "population" },
        .{ .name = "k" },
        .{ .name = "counts", .flags = binder.parameter_flags_module.keyword_only, .default = .none },
    } },
    .{ .id = @intFromEnum(Function.uniform), .name = "uniform", .params = &.{ .{ .name = "a" }, .{ .name = "b" } } },
};

const State = struct {
    header: gc.Header align(8),
    prng: std.Random.DefaultPrng,
    default_seed: u64,
};

const state_kind = gc.Kind{};

const TaskMode = enum { randrange, choice, choices, shuffle, sample };
const TaskPhase = enum { prepare, validate, draw };
const RandomTaskPayload = struct {
    mode: TaskMode,
    phase: TaskPhase = .draw,
    result: ?*sequence.List = null,
    length: usize = 0,
    k: usize = 0,
    index: usize = 0,
    remaining: usize = 0,
    total: usize = 0,
    counts_present: bool = false,
    cumulative_present: bool = false,
    counts: []usize = &.{},
    fenwick: []usize = &.{},
    cumulative: []f64 = &.{},
    running_weight: f64 = 0,
    swaps: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    candidate: Value = Value.noneValue(),
    bits_remaining: usize = 0,
    bit_count: usize = 0,
};

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const state = self.heap.createObject(State, &state_kind) catch {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return false;
    };
    state.* = .{
        .header = state.header,
        .prng = std.Random.DefaultPrng.init(self.random_seed),
        .default_seed = self.random_seed,
    };
    var state_root = gc.Root{ .object = &state.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&state_root);
    defer roots.pop();
    for (functions) |spec| {
        if (!storeBoundFunction(Runtime, self, environment, state, spec, line, column)) return false;
    }
    return true;
}

fn storeBoundFunction(comptime Runtime: type, self: *Runtime, environment: *gc.Header, state: *State, spec: types.FunctionSpec, line: u32, column: u32) bool {
    const created = functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.random), spec.id, Value.object(&state.header));
    const callable = switch (created) {
        .value => |value| Value.object(&value.header),
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
    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
    return false;
}

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
    const state = stateFrom(receiver) orelse return self.engineFault();
    const function = std.enums.fromInt(Function, function_id) orelse return self.engineFault();
    return switch (function) {
        .seed => seed(Runtime, self, destination, state, args[0], args[1], line, column),
        .random => storeRandom(self, destination, state),
        .randint => randint(Runtime, self, destination, state, args[0], args[1], line, column),
        .randrange => randrange(Runtime, self, destination, state, args[0], args[1], args[2], line, column),
        .choice => choice(Runtime, self, destination, state, args[0], line, column),
        .choices => choices(Runtime, self, destination, state, args[0], args[1], args[2], args[3], line, column),
        .shuffle => shuffle(Runtime, self, destination, state, args[0], line, column),
        .sample => sample(Runtime, self, destination, state, args[0], args[1], args[2], line, column),
        .uniform => uniform(Runtime, self, destination, state, args[0], args[1], line, column),
    };
}

fn stateFrom(value: Value) ?*State {
    const header = value.asObject() orelse return null;
    if (header.kind != &state_kind) return null;
    return @ptrCast(@alignCast(header));
}

fn seed(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, seed_value: Value, version_value: Value, line: u32, column: u32) bool {
    if (!number.isIntegerValue(version_value) or number.toInt(i64, version_value) != 2) return runtimeError(Runtime, self, line, column, .not_implemented_error, "random seed version 1 is not supported");
    const derived = if (seed_value.tag() == .none)
        state.default_seed
    else
        deriveSeed(Runtime, self, seed_value, line, column) orelse return false;
    state.prng = std.Random.DefaultPrng.init(derived);
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn deriveSeed(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?u64 {
    if (number.isIntegerValue(value)) {
        const result = number.formatInteger(&self.heap, value) orelse return null;
        const text = switch (result) {
            .value => |bytes| bytes,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return null;
            },
            .engine_error => {
                _ = self.engineFault();
                return null;
            },
        };
        defer self.heap.allocator.free(text);
        return std.hash.Wyhash.hash(0x494e_542d_5345_4544, text);
    }
    if (value.asFloat()) |float_value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @bitCast(float_value), .little);
        return std.hash.Wyhash.hash(0x464c_542d_5345_4544, &bytes);
    }
    if (self.valueString(value)) |text| return std.hash.Wyhash.hash(0x5354_522d_5345_4544, text);
    if (self.valueBytes(value)) |bytes| return std.hash.Wyhash.hash(0x4259_542d_5345_4544, bytes);
    _ = self.nativeTypeError(line, column, "seed supports None, int, float, str, and bytes");
    return null;
}

fn storeRandom(self: anytype, destination: u16, state: *State) bool {
    self.setRegister(destination, Value.fromFloat(state.prng.random().float(f64)));
    return true;
}

fn randint(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, lower: Value, upper: Value, line: u32, column: u32) bool {
    if (!number.isIntegerValue(lower) or !number.isIntegerValue(upper)) return self.nativeTypeError(line, column, "randint arguments must be integers");
    var upper_root = gc.Root{ .object = upper.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&upper_root);
    defer roots.pop();
    const exclusive = unwrapValue(Runtime, self, number.add(&self.heap, upper, Value.fromSmallInt(1).?), line, column) orelse return false;
    upper_root.object = exclusive.asObject();
    return randrange(Runtime, self, destination, state, lower, exclusive, Value.fromSmallInt(1).?, line, column);
}

fn randrange(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, start_value: Value, stop_value: Value, step_value: Value, line: u32, column: u32) bool {
    if (!number.isIntegerValue(start_value) or (stop_value.tag() != .none and !number.isIntegerValue(stop_value)) or !number.isIntegerValue(step_value)) return self.nativeTypeError(line, column, "randrange arguments must be integers");
    if (number.isZeroValue(step_value)) return runtimeError(Runtime, self, line, column, .value_error, "zero step for randrange()");
    const range_result = if (stop_value.tag() == .none)
        iterator.createRange(&self.heap, &.{start_value})
    else
        iterator.createRange(&self.heap, &.{ start_value, stop_value, step_value });
    const range = switch (range_result) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var range_root = gc.Root{ .object = &range.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&range_root);
    defer roots.pop();
    const length = unwrapResult(Runtime, self, iterator.rangeLength(&self.heap, range), line, column) orelse return false;
    if (number.isZeroValue(length)) return runtimeError(Runtime, self, line, column, .value_error, "empty range for randrange()");
    const payload = self.heap.allocator.create(RandomTaskPayload) catch return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
    payload.* = .{ .mode = .randrange, .bit_count = number.integerBitCount(length), .bits_remaining = number.integerBitCount(length) };
    return startRandomTask(Runtime, self, destination, payload, &.{ Value.object(&state.header), Value.object(&range.header), length }, line, column);
}

fn choice(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, population: Value, line: u32, column: u32) bool {
    const length = sequenceLength(Runtime, self, population, line, column) orelse return false;
    if (number.isZeroValue(length)) return runtimeError(Runtime, self, line, column, .index_error, "cannot choose from an empty sequence");
    const payload = self.heap.allocator.create(RandomTaskPayload) catch return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
    payload.* = .{ .mode = .choice, .bit_count = number.integerBitCount(length), .bits_remaining = number.integerBitCount(length) };
    return startRandomTask(Runtime, self, destination, payload, &.{ Value.object(&state.header), population, length }, line, column);
}

fn choices(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, population: Value, weights_value: Value, cumulative_value: Value, k_value: Value, line: u32, column: u32) bool {
    if (!number.isIntegerValue(k_value)) return self.nativeTypeError(line, column, "k must be an integer");
    const k_signed = number.toInt(i64, k_value) orelse return runtimeError(Runtime, self, line, column, .overflow_error, "k is too large");
    if (k_signed < 0) return runtimeError(Runtime, self, line, column, .value_error, "k must be non-negative");
    const k: usize = @intCast(k_signed);
    const length_value = sequenceLength(Runtime, self, population, line, column) orelse return false;
    const length = number.toInt(usize, length_value) orelse return runtimeError(Runtime, self, line, column, .overflow_error, "population is too large");
    if (weights_value.tag() != .none and cumulative_value.tag() != .none) return self.nativeTypeError(line, column, "cannot specify both weights and cumulative weights");
    const weighted = weights_value.tag() != .none or cumulative_value.tag() != .none;
    if (weighted) {
        const source = if (cumulative_value.tag() != .none) cumulative_value else weights_value;
        const source_length_value = sequenceLength(Runtime, self, source, line, column) orelse return false;
        const source_length = number.toInt(usize, source_length_value) orelse return runtimeError(Runtime, self, line, column, .overflow_error, "weights are too large");
        if (source_length != length) return runtimeError(Runtime, self, line, column, .value_error, "weights and population must have equal length");
    }
    const result = createRootedList(Runtime, self, line, column) orelse return false;
    if (k == 0 and !weighted) {
        self.setRegister(destination, Value.object(&result.header));
        return true;
    }
    if (length == 0) return runtimeError(Runtime, self, line, column, .index_error, "cannot choose from an empty population");
    const payload = self.heap.allocator.create(RandomTaskPayload) catch return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
    payload.* = .{
        .mode = .choices,
        .phase = if (weighted) .validate else .draw,
        .result = result,
        .length = length,
        .k = k,
        .cumulative_present = cumulative_value.tag() != .none,
    };
    if (weighted) {
        payload.cumulative = self.heap.allocator.alloc(f64, length) catch {
            self.heap.allocator.destroy(payload);
            return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
        };
    }
    return startRandomTask(Runtime, self, destination, payload, &.{ Value.object(&state.header), population, weights_value, cumulative_value }, line, column);
}

fn shuffle(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, value: Value, line: u32, column: u32) bool {
    const header = value.asObject() orelse return self.nativeTypeError(line, column, "shuffle() requires a list");
    const list = sequence.listFromHeader(header) orelse return self.nativeTypeError(line, column, "shuffle() requires a list");
    if (list.items.items.len < 2) {
        self.setRegister(destination, Value.noneValue());
        return true;
    }
    const payload = self.heap.allocator.create(RandomTaskPayload) catch return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
    payload.* = .{ .mode = .shuffle, .length = list.items.items.len, .index = list.items.items.len };
    return startRandomTask(Runtime, self, destination, payload, &.{ Value.object(&state.header), value }, line, column);
}

fn sample(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, population: Value, k_value: Value, counts_value: Value, line: u32, column: u32) bool {
    if (!number.isIntegerValue(k_value)) return self.nativeTypeError(line, column, "sample size must be an integer");
    const k_signed = number.toInt(i64, k_value) orelse return runtimeError(Runtime, self, line, column, .overflow_error, "sample size is too large");
    if (k_signed < 0) return runtimeError(Runtime, self, line, column, .value_error, "sample larger than population or negative");
    const k: usize = @intCast(k_signed);
    const population_length_value = sequenceLength(Runtime, self, population, line, column) orelse return false;
    const population_length = number.toInt(usize, population_length_value) orelse return runtimeError(Runtime, self, line, column, .overflow_error, "population is too large");

    const counts_present = counts_value.tag() != .none;
    if (counts_present) {
        const count_length_value = sequenceLength(Runtime, self, counts_value, line, column) orelse return false;
        const count_length = number.toInt(usize, count_length_value) orelse return runtimeError(Runtime, self, line, column, .overflow_error, "counts are too large");
        if (count_length != population_length) return runtimeError(Runtime, self, line, column, .value_error, "counts and population must have equal length");
    }
    if (!counts_present and k > population_length) return runtimeError(Runtime, self, line, column, .value_error, "sample larger than population or negative");
    const result = createRootedList(Runtime, self, line, column) orelse return false;
    if (k == 0 and !counts_present) {
        self.setRegister(destination, Value.object(&result.header));
        return true;
    }
    const payload = self.heap.allocator.create(RandomTaskPayload) catch return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
    payload.* = .{
        .mode = .sample,
        .phase = if (counts_present) .prepare else .draw,
        .result = result,
        .length = population_length,
        .k = k,
        .remaining = population_length,
        .counts_present = counts_present,
    };
    if (counts_present) {
        if (population_length != 0) {
            payload.counts = self.heap.allocator.alloc(usize, population_length) catch {
                destroyRandomTask(payload, self.heap.allocator);
                return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
            };
        }
        const tree_length = std.math.add(usize, population_length, 1) catch {
            destroyRandomTask(payload, self.heap.allocator);
            return runtimeError(Runtime, self, line, column, .overflow_error, "counts are too large");
        };
        payload.fenwick = self.heap.allocator.alloc(usize, tree_length) catch {
            destroyRandomTask(payload, self.heap.allocator);
            return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
        };
        payload.remaining = 0;
    }
    return startRandomTask(Runtime, self, destination, payload, &.{ Value.object(&state.header), population, counts_value }, line, column);
}

fn uniform(comptime Runtime: type, self: *Runtime, destination: u16, state: *State, lower_value: Value, upper_value: Value, line: u32, column: u32) bool {
    const lower = asFloat(Runtime, self, lower_value, line, column) orelse return false;
    const upper = asFloat(Runtime, self, upper_value, line, column) orelse return false;
    const result = lower + (upper - lower) * state.prng.random().float(f64);
    self.setRegister(destination, Value.fromFloat(result));
    return true;
}

fn startRandomTask(comptime Runtime: type, self: *Runtime, destination: u16, payload: *RandomTaskPayload, inputs: []const Value, line: u32, column: u32) bool {
    var roots = gc.RootFrame{};
    var input_roots: [4]gc.Root = undefined;
    roots.push(&self.heap.roots);
    defer roots.pop();
    for (inputs, 0..) |input, index| {
        input_roots[index] = .{ .object = input.asObject() };
        roots.add(&input_roots[index]);
    }
    var result_root = gc.Root{ .object = if (payload.result) |result| &result.header else null };
    roots.add(&result_root);
    const caller = self.top_frame orelse {
        destroyRandomTask(payload, self.heap.allocator);
        return self.engineFault();
    };
    const task = types.createTask(&self.heap, self.currentNativeTask(), .random, @intFromEnum(payload.mode), @ptrCast(caller), destination, line, column, inputs, randomTaskOps(Runtime)) catch {
        destroyRandomTask(payload, self.heap.allocator);
        return runtimeError(Runtime, self, line, column, .memory_error, "session memory limit exceeded");
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn randomTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return randomTaskStep(Runtime, self, task);
        }
        const ops = types.TaskOps{ .step = step, .trace_payload = traceRandomTask, .destroy_payload = destroyRandomTask };
    }.ops;
}

fn traceRandomTask(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *RandomTaskPayload = @ptrCast(@alignCast(raw orelse return));
    if (payload.result) |result| tracer.visit(&result.header);
    tracer.visit(payload.candidate.asObject());
}

fn destroyRandomTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *RandomTaskPayload = @ptrCast(@alignCast(raw orelse return));
    if (payload.counts.len != 0) allocator.free(payload.counts);
    if (payload.fenwick.len != 0) allocator.free(payload.fenwick);
    if (payload.cumulative.len != 0) allocator.free(payload.cumulative);
    payload.swaps.deinit(allocator);
    allocator.destroy(payload);
}

fn randomTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload: *RandomTaskPayload = @ptrCast(@alignCast(task.payload orelse return randomTaskError(.runtime_error, "invalid random task")));
    const state = stateFrom(task.inputs[0]) orelse return randomTaskError(.runtime_error, "invalid random state");
    for (0..64) |_| {
        if (!self.chargeBulkWork(1)) return .yield;
        const step = switch (payload.mode) {
            .randrange, .choice => randomBelowStep(Runtime, self, task, payload, state),
            .choices => choicesStep(Runtime, self, task, payload, state),
            .shuffle => shuffleStep(task, payload, state),
            .sample => sampleStep(Runtime, self, task, payload, state),
        };
        switch (step) {
            .yield => {},
            else => return step,
        }
    }
    return .yield;
}

fn randomBelowStep(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *RandomTaskPayload, state: *State) types.TaskStep {
    if (payload.bits_remaining != 0) {
        const processed = (payload.bit_count - payload.bits_remaining) / 63;
        if (!self.chargeBulkWork(@as(u64, @intCast(processed)) + 1)) return .yield;
        const width: u6 = @intCast(@min(payload.bits_remaining, 63));
        const mask: u64 = (@as(u64, 1) << width) - 1;
        const chunk = state.prng.random().int(u64) & mask;
        if (payload.bits_remaining == payload.bit_count) payload.candidate = Value.fromSmallInt(0).?;
        payload.candidate = unwrapValue(Runtime, self, number.shiftLeft(&self.heap, payload.candidate, Value.fromSmallInt(width).?), task.line, task.column) orelse return .propagate;
        const chunk_value = unwrapValue(Runtime, self, number.fromInt(&self.heap, chunk), task.line, task.column) orelse return .propagate;
        var chunk_root = gc.Root{ .object = chunk_value.asObject() };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&chunk_root);
        defer roots.pop();
        payload.candidate = unwrapValue(Runtime, self, number.bitOr(&self.heap, payload.candidate, chunk_value), task.line, task.column) orelse return .propagate;
        payload.bits_remaining -= width;
        return .yield;
    }
    if (!self.chargeBulkWork(@as(u64, @intCast((payload.bit_count + 62) / 63)))) return .yield;
    const comparison = number.compare(payload.candidate, task.inputs[2]);
    const order = switch (comparison) {
        .value => |value| value,
        .python_exception => |exception| return .{ .raise = exception },
        .engine_error => return randomTaskError(.runtime_error, "random integer comparison failed"),
    };
    if (order != .less) {
        payload.candidate = Value.noneValue();
        payload.bits_remaining = payload.bit_count;
        return .yield;
    }
    const selected = if (payload.mode == .randrange) blk: {
        const header = task.inputs[1].asObject() orelse return randomTaskError(.runtime_error, "invalid range task");
        const range = iterator.rangeFromHeader(header) orelse return randomTaskError(.runtime_error, "invalid range task");
        break :blk unwrapResult(Runtime, self, iterator.rangeIndex(&self.heap, range, payload.candidate), task.line, task.column) orelse return .propagate;
    } else sequenceItem(Runtime, self, task.inputs[1], payload.candidate, task.line, task.column) orelse return .propagate;
    return .{ .complete = selected };
}

fn choicesStep(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *RandomTaskPayload, state: *State) types.TaskStep {
    if (payload.phase == .validate) {
        if (payload.index == payload.length) {
            if (!(payload.running_weight > 0) or !std.math.isFinite(payload.running_weight)) return randomTaskError(.value_error, "total weights must be positive and finite");
            payload.index = 0;
            payload.phase = .draw;
            return .yield;
        }
        const source = task.inputs[if (payload.cumulative_present) 3 else 2];
        const selected = sequenceItemIndex(Runtime, self, source, payload.index, task.line, task.column) orelse return .propagate;
        const weight = asFloat(Runtime, self, selected, task.line, task.column) orelse return .propagate;
        if (!std.math.isFinite(weight)) return randomTaskError(.value_error, "weights must be finite");
        if (payload.cumulative_present) {
            if (payload.index != 0 and weight < payload.running_weight) return randomTaskError(.value_error, "cumulative weights must be nondecreasing");
            payload.running_weight = weight;
        } else {
            if (weight < 0) return randomTaskError(.value_error, "weights must be non-negative");
            payload.running_weight += weight;
        }
        payload.cumulative[payload.index] = payload.running_weight;
        payload.index += 1;
        return .yield;
    }
    if (payload.index == payload.k) return .{ .complete = Value.object(&payload.result.?.header) };
    if (payload.cumulative.len != 0 and !self.chargeBulkWork(@as(u64, @intCast(std.math.log2_int_ceil(usize, payload.length + 1))))) return .yield;
    const random = state.prng.random();
    const index = if (payload.cumulative.len == 0)
        random.uintLessThan(usize, payload.length)
    else
        upperBound(payload.cumulative, random.float(f64) * payload.cumulative[payload.cumulative.len - 1]);
    const selected = sequenceItemIndex(Runtime, self, task.inputs[1], index, task.line, task.column) orelse return .propagate;
    if (!appendList(Runtime, self, payload.result.?, selected, task.line, task.column)) return .propagate;
    payload.index += 1;
    return .yield;
}

fn shuffleStep(task: *types.Task, payload: *RandomTaskPayload, state: *State) types.TaskStep {
    const header = task.inputs[1].asObject() orelse return randomTaskError(.runtime_error, "invalid shuffle list");
    const list = sequence.listFromHeader(header) orelse return randomTaskError(.runtime_error, "invalid shuffle list");
    if (payload.index <= 1) {
        list.version +%= 1;
        return .{ .complete = Value.noneValue() };
    }
    payload.index -= 1;
    const other = state.prng.random().uintLessThan(usize, payload.index + 1);
    std.mem.swap(Value, &list.items.items[payload.index], &list.items.items[other]);
    return .yield;
}

fn sampleStep(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *RandomTaskPayload, state: *State) types.TaskStep {
    if (payload.phase == .prepare) {
        payload.fenwick[payload.index] = 0;
        payload.index += 1;
        if (payload.index == payload.fenwick.len) {
            payload.phase = .validate;
            payload.index = 0;
        }
        return .yield;
    }
    if (payload.phase == .validate) {
        if (payload.index == payload.length) {
            if (payload.k > payload.total) return randomTaskError(.value_error, "sample larger than population or negative");
            payload.remaining = payload.total;
            payload.index = 0;
            payload.phase = .draw;
            return .yield;
        }
        const selected = sequenceItemIndex(Runtime, self, task.inputs[2], payload.index, task.line, task.column) orelse return .propagate;
        if (!number.isIntegerValue(selected)) return randomTaskError(.type_error, "counts must be integers");
        const signed = number.toInt(i64, selected) orelse return randomTaskError(.overflow_error, "count is too large");
        if (signed < 0) return randomTaskError(.value_error, "counts must be non-negative");
        const count: usize = @intCast(signed);
        payload.total = std.math.add(usize, payload.total, count) catch return randomTaskError(.overflow_error, "total counts are too large");
        payload.counts[payload.index] = count;
        const position = payload.index + 1;
        payload.fenwick[position] += count;
        const step = position & (~position +% 1);
        if (step <= payload.length - position) payload.fenwick[position + step] += payload.fenwick[position];
        payload.index += 1;
        return .yield;
    }
    if (payload.index == payload.k) return .{ .complete = Value.object(&payload.result.?.header) };
    const random = state.prng.random();
    const selected_index = if (payload.counts_present) blk: {
        const bits = std.math.log2_int_ceil(usize, payload.length + 1);
        if (!self.chargeBulkWork(@as(u64, @intCast(bits)) * 2 + 1)) return .yield;
        var target = random.uintLessThan(usize, payload.remaining);
        var position: usize = 0;
        var bit: usize = 1;
        while (bit <= payload.length / 2) bit *= 2;
        while (bit != 0) : (bit >>= 1) {
            if (bit > payload.length - position) continue;
            const next = position + bit;
            if (payload.fenwick[next] <= target) {
                target -= payload.fenwick[next];
                position = next;
            }
        }
        if (position >= payload.length or payload.counts[position] == 0) return randomTaskError(.runtime_error, "invalid sample counts state");
        payload.counts[position] -= 1;
        var node = position + 1;
        while (node <= payload.length) {
            payload.fenwick[node] -= 1;
            const step = node & (~node +% 1);
            if (step > payload.length - node) break;
            node += step;
        }
        payload.remaining -= 1;
        break :blk position;
    } else blk: {
        const slot = payload.index + random.uintLessThan(usize, payload.length - payload.index);
        const selected = payload.swaps.get(slot) orelse slot;
        const replacement = payload.swaps.get(payload.index) orelse payload.index;
        payload.swaps.put(self.heap.allocator, slot, replacement) catch return randomTaskError(.memory_error, "session memory limit exceeded");
        break :blk selected;
    };
    const selected = sequenceItemIndex(Runtime, self, task.inputs[1], selected_index, task.line, task.column) orelse return .propagate;
    if (!appendList(Runtime, self, payload.result.?, selected, task.line, task.column)) return .propagate;
    payload.index += 1;
    return .yield;
}

fn randomTaskError(kind: @import("runtime_exception").PythonExceptionKind, message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = kind, .message = message } };
}

fn sequenceLength(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?Value {
    if (sequence.length(value)) |length| return unwrapValue(Runtime, self, number.fromInt(&self.heap, length), line, column);
    const header = value.asObject() orelse {
        _ = self.nativeTypeError(line, column, "object is not a sequence");
        return null;
    };
    if (string.fromHeader(header)) |text| return unwrapValue(Runtime, self, number.fromInt(&self.heap, string.length(text)), line, column);
    if (bytes_module.fromHeader(header)) |bytes| return unwrapValue(Runtime, self, number.fromInt(&self.heap, bytes_module.length(bytes)), line, column);
    if (iterator.rangeFromHeader(header)) |range| return unwrapResult(Runtime, self, iterator.rangeLength(&self.heap, range), line, column);
    _ = self.nativeTypeError(line, column, "object is not a sequence");
    return null;
}

fn sequenceItem(comptime Runtime: type, self: *Runtime, value: Value, index: Value, line: u32, column: u32) ?Value {
    var value_root = gc.Root{ .object = value.asObject() };
    var index_root = gc.Root{ .object = index.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&value_root);
    roots.add(&index_root);
    defer roots.pop();
    const machine_index = number.toInt(usize, index) orelse {
        _ = runtimeError(Runtime, self, line, column, .overflow_error, "sequence index is too large");
        return null;
    };
    return sequenceItemIndex(Runtime, self, value, machine_index, line, column);
}

fn sequenceItemIndex(comptime Runtime: type, self: *Runtime, value: Value, index: usize, line: u32, column: u32) ?Value {
    if (sequence.itemAt(value, index)) |item| return item;
    const header = value.asObject() orelse return null;
    if (string.fromHeader(header)) |text| {
        return switch (string.index(&self.heap, text, @intCast(index))) {
            .value => |created| Value.object(&created.header),
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
    if (bytes_module.fromHeader(header)) |bytes| {
        return switch (bytes_module.index(bytes, @intCast(index))) {
            .value => |byte| Value.fromSmallInt(byte),
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
    if (iterator.rangeFromHeader(header)) |range| {
        const index_value = unwrapValue(Runtime, self, number.fromInt(&self.heap, index), line, column) orelse return null;
        var index_root = gc.Root{ .object = index_value.asObject() };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&index_root);
        defer roots.pop();
        return unwrapResult(Runtime, self, iterator.rangeIndex(&self.heap, range, index_value), line, column);
    }
    _ = self.nativeTypeError(line, column, "object is not a sequence");
    return null;
}

fn createRootedList(comptime Runtime: type, self: *Runtime, line: u32, column: u32) ?*sequence.List {
    return switch (sequence.createList(&self.heap, &.{})) {
        .value => |list| list,
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

fn appendList(comptime Runtime: type, self: *Runtime, list: *sequence.List, value: Value, line: u32, column: u32) bool {
    var value_root = gc.Root{ .object = value.asObject() };
    var list_root = gc.Root{ .object = &list.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&value_root);
    roots.add(&list_root);
    defer roots.pop();
    return switch (sequence.append(&self.heap, list, value)) {
        .value => true,
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk false;
        },
        .engine_error => blk: {
            break :blk self.engineFault();
        },
    };
}

fn upperBound(values: []const f64, target: f64) usize {
    var low: usize = 0;
    var high = values.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (target < values[middle]) high = middle else low = middle + 1;
    }
    return @min(low, values.len - 1);
}

fn asFloat(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?f64 {
    return switch (number.toFloat(&self.heap, value)) {
        .value => |float_value| float_value,
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

fn unwrapValue(comptime Runtime: type, self: *Runtime, result: number.ValueResult, line: u32, column: u32) ?Value {
    return switch (result) {
        .value => |value| value,
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

fn unwrapResult(comptime Runtime: type, self: *Runtime, result: anytype, line: u32, column: u32) ?Value {
    return switch (result) {
        .value => |value| value,
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

fn runtimeError(comptime Runtime: type, self: *Runtime, line: u32, column: u32, kind: anytype, message: []const u8) bool {
    self.setException(.{ .kind = kind, .message = message }, line, column, null);
    return false;
}
