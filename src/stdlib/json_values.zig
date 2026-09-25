const std = @import("std");
const binder = @import("runtime_binder");
const dict = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const string = @import("runtime_string");
const value_module = @import("runtime_value");
const json = @import("json.zig");
const types = @import("types.zig");

const Value = value_module.Value;

const Function = enum(u16) { loads = 1, dumps, load, dump };
const keyword_only = binder.parameter_flags_module.keyword_only;

pub const functions = [_]types.FunctionSpec{
    .{ .id = @intFromEnum(Function.loads), .name = "loads", .params = &.{.{ .name = "s" }} },
    encodeSpec(.dumps, "dumps", false),
    .{ .id = @intFromEnum(Function.load), .name = "load", .params = &.{.{ .name = "fp" }} },
    encodeSpec(.dump, "dump", true),
};

const ModuleState = struct {
    header: gc.Header align(8),
    decode_error_class: *exceptions.ExceptionClass,
};

const module_state_kind = gc.Kind{ .trace = traceModuleState };

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const error_class = self.ensureJsonDecodeErrorClass(line, column) orelse return false;
    var class_root = gc.Root{ .object = &error_class.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&class_root);
    defer roots.pop();
    if (!self.environmentStore(environment, "JSONDecodeError", Value.object(&error_class.header))) return memoryFailure(self, line, column);
    const state = self.heap.createObject(ModuleState, &module_state_kind) catch return memoryFailure(self, line, column);
    state.* = .{ .header = state.header, .decode_error_class = error_class };
    var state_root = gc.Root{ .object = &state.header };
    roots.add(&state_root);
    for (functions) |spec| if (!storeBoundFunction(self, environment, state, spec, line, column)) return false;
    return true;
}

fn storeBoundFunction(self: anytype, environment: *gc.Header, state: *ModuleState, spec: types.FunctionSpec, line: u32, column: u32) bool {
    const created = functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.json), spec.id, Value.object(&state.header));
    const callable = switch (created) {
        .value => |function| Value.object(&function.header),
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    };
    var root = gc.Root{ .object = callable.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    if (self.environmentStore(environment, spec.name, callable)) return true;
    return memoryFailure(self, line, column);
}

fn traceModuleState(header: *gc.Header, tracer: *gc.Tracer) void {
    const state: *ModuleState = @ptrCast(@alignCast(header));
    tracer.visit(&state.decode_error_class.header);
}

fn encodeSpec(comptime function: Function, comptime name: []const u8, comptime has_file: bool) types.FunctionSpec {
    return .{
        .id = @intFromEnum(function),
        .name = name,
        .params = if (has_file) &.{
            .{ .name = "obj" },
            .{ .name = "fp" },
            .{ .name = "indent", .flags = keyword_only, .default = .none },
            .{ .name = "sort_keys", .flags = keyword_only, .default = .{ .boolean = false } },
            .{ .name = "ensure_ascii", .flags = keyword_only, .default = .{ .boolean = true } },
            .{ .name = "separators", .flags = keyword_only, .default = .none },
            .{ .name = "allow_nan", .flags = keyword_only, .default = .{ .boolean = true } },
        } else &.{
            .{ .name = "obj" },
            .{ .name = "indent", .flags = keyword_only, .default = .none },
            .{ .name = "sort_keys", .flags = keyword_only, .default = .{ .boolean = false } },
            .{ .name = "ensure_ascii", .flags = keyword_only, .default = .{ .boolean = true } },
            .{ .name = "separators", .flags = keyword_only, .default = .none },
            .{ .name = "allow_nan", .flags = keyword_only, .default = .{ .boolean = true } },
        },
    };
}

pub const DetailedParseResult = union(enum) {
    value: Value,
    decode_error: json.Diagnostic,
    python_exception: exceptions.PythonException,
    engine_error,
};

/// Builds Peony Values directly from the event decoder. No intermediate JSON
/// DOM or float conversion is used for integer tokens.
pub fn parseUtf8Detailed(
    comptime Runtime: type,
    self: *Runtime,
    bytes: []const u8,
    line: u32,
    column: u32,
) DetailedParseResult {
    var builder = ValueBuilder(Runtime).init(self, line, column);
    builder.begin();
    defer builder.end();
    var decoder = json.DecodeCursor.init(self.heap.allocator, bytes, .{});
    defer decoder.deinit();
    while (true) {
        const event = decoder.next() catch |err| switch (err) {
            error.InvalidJson => return .{ .decode_error = decoder.diagnostic().? },
            error.OutOfMemory => return .{ .python_exception = exceptions.memoryError() },
        };
        if (event == null) break;
        builder.emit(event.?) catch |err| switch (err) {
            error.RuntimeFailure => return if (self.last_exception) |exception| .{ .python_exception = exception } else .engine_error,
        };
    }
    return if (builder.result) |value| .{ .value = value } else .engine_error;
}

/// Typed cross-module entry for Response.json. The JSON module's public call
/// path uses `parseUtf8Detailed` to attach JSONDecodeError metadata.
pub fn parseUtf8(
    comptime Runtime: type,
    self: *Runtime,
    bytes: []const u8,
    line: u32,
    column: u32,
) exceptions.Result(Value) {
    return switch (parseUtf8Detailed(Runtime, self, bytes, line, column)) {
        .value => |value| .{ .value = value },
        .decode_error => .{ .python_exception = .{ .kind = .value_error, .message = "invalid JSON document" } },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => .{ .engine_error = .internal_invariant },
    };
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
    const function = std.enums.fromInt(Function, function_id) orelse return self.engineFault();
    const state = moduleState(receiver) orelse return self.engineFault();
    return switch (function) {
        .loads => startDecodeTask(Runtime, self, destination, state.decode_error_class, args[0], null, line, column),
        .dumps => startEncodeTask(Runtime, self, destination, state.decode_error_class, args[0], null, args[1..], line, column),
        .load => startDecodeTask(Runtime, self, destination, state.decode_error_class, Value.noneValue(), args[0], line, column),
        .dump => startEncodeTask(Runtime, self, destination, state.decode_error_class, args[0], args[1], args[2..], line, column),
    };
}

fn parseEncodeOptions(comptime Runtime: type, self: *Runtime, values: []const Value, line: u32, column: u32) ?json.EncodeOptions {
    if (values.len != 5) {
        _ = self.engineFault();
        return null;
    }
    var options = json.EncodeOptions{};
    const indent_value = values[0];
    if (indent_value.tag() == .none) {
        options.indent = .none;
    } else if (number.isIntegerValue(indent_value)) {
        const count = number.toInt(i64, indent_value) orelse {
            _ = self.nativeTypeError(line, column, "indent is too large");
            return null;
        };
        options.indent = .{ .spaces = @intCast(@max(count, 0)) };
    } else if (self.valueString(indent_value)) |text| {
        options.indent = .{ .text = text };
    } else {
        _ = self.nativeTypeError(line, column, "indent must be None, int, or str");
        return null;
    }
    options.sort_keys = self.valueTruthy(values[1], line, column) orelse return null;
    options.ensure_ascii = self.valueTruthy(values[2], line, column) orelse return null;
    options.allow_nan = self.valueTruthy(values[4], line, column) orelse return null;
    if (values[3].tag() != .none) {
        const pair = sequenceItems(values[3]) orelse {
            _ = self.nativeTypeError(line, column, "separators must be a pair of strings");
            return null;
        };
        if (pair.len != 2) {
            _ = self.nativeTypeError(line, column, "separators must contain two strings");
            return null;
        }
        options.item_separator = self.valueString(pair[0]) orelse {
            _ = self.nativeTypeError(line, column, "item separator must be str");
            return null;
        };
        options.key_separator = self.valueString(pair[1]) orelse {
            _ = self.nativeTypeError(line, column, "key separator must be str");
            return null;
        };
    }
    return options;
}

const DecodePhase = enum { read, decode };

fn DecodeTaskPayload(comptime Runtime: type) type {
    return struct {
        allocator: std.mem.Allocator,
        phase: DecodePhase,
        error_class: *exceptions.ExceptionClass,
        input: Value = Value.noneValue(),
        owned_document: ?[]u8 = null,
        decoder: ?json.DecodeCursor = null,
        builder: ?ValueBuilder(Runtime) = null,
    };
}

/// Starts the same resumable parser used by json.loads for cross-module byte
/// sources such as requests.Response.json(). The task owns a stable copy of
/// the document and publishes the per-run JSONDecodeError class on demand.
pub fn startParseBytesTask(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    document: []const u8,
    line: u32,
    column: u32,
) bool {
    const error_class = self.ensureJsonDecodeErrorClass(line, column) orelse return false;
    var class_root = gc.Root{ .object = &error_class.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&class_root);
    defer roots.pop();
    const owned = self.heap.allocator.dupe(u8, document) catch return memoryFailure(self, line, column);
    const Payload = DecodeTaskPayload(Runtime);
    const payload = self.heap.allocator.create(Payload) catch {
        self.heap.allocator.free(owned);
        return memoryFailure(self, line, column);
    };
    payload.* = .{
        .allocator = self.heap.allocator,
        .phase = .decode,
        .error_class = error_class,
        .owned_document = owned,
        .decoder = json.DecodeCursor.init(self.heap.allocator, owned, .{}),
        .builder = ValueBuilder(Runtime).init(self, line, column),
    };
    const caller = self.top_frame orelse {
        destroyDecodeTask(Runtime, payload, self.heap.allocator);
        return self.engineFault();
    };
    const inputs = [_]Value{Value.object(&error_class.header)};
    const task = types.createTask(&self.heap, self.currentNativeTask(), .json, @intFromEnum(Function.loads), @ptrCast(caller), destination, line, column, &inputs, decodeTaskOps(Runtime)) catch {
        destroyDecodeTask(Runtime, payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn startDecodeTask(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    error_class: *exceptions.ExceptionClass,
    input: Value,
    file: ?Value,
    line: u32,
    column: u32,
) bool {
    var method = Value.noneValue();
    if (file) |target| {
        method = self.lookupAttributeValue(target, "read", line, column) orelse {
            if (self.last_exception == null) _ = self.nativeAttributeError(line, column, "file-like object has no required method");
            return false;
        };
    }
    var roots_array = [_]gc.Root{
        .{ .object = input.asObject() },
        .{ .object = if (file) |target| target.asObject() else null },
        .{ .object = method.asObject() },
        .{ .object = &error_class.header },
    };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const Payload = DecodeTaskPayload(Runtime);
    const payload = self.heap.allocator.create(Payload) catch return memoryFailure(self, line, column);
    payload.* = .{
        .allocator = self.heap.allocator,
        .phase = if (file == null) .decode else .read,
        .error_class = error_class,
        .input = input,
    };
    if (file == null and !initializeDecode(Runtime, self, payload, input, line, column)) {
        destroyDecodeTask(Runtime, payload, self.heap.allocator);
        return false;
    }
    const caller = self.top_frame orelse {
        destroyDecodeTask(Runtime, payload, self.heap.allocator);
        return self.engineFault();
    };
    const inputs = [_]Value{ input, file orelse Value.noneValue(), method, Value.object(&error_class.header) };
    const task = types.createTask(&self.heap, self.currentNativeTask(), .json, @intFromEnum(Function.loads), @ptrCast(caller), destination, line, column, &inputs, decodeTaskOps(Runtime)) catch {
        destroyDecodeTask(Runtime, payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn initializeDecode(comptime Runtime: type, self: *Runtime, payload: *DecodeTaskPayload(Runtime), input: Value, line: u32, column: u32) bool {
    var byte_input = false;
    const bytes = self.valueString(input) orelse blk: {
        const selected = self.valueBytes(input) orelse return self.nativeTypeError(line, column, "JSON input must be str or bytes");
        byte_input = true;
        break :blk selected;
    };
    if (byte_input and !std.unicode.utf8ValidateSlice(bytes)) {
        self.setException(.{ .kind = .unicode_decode_error, .message = "JSON bytes are not valid UTF-8" }, line, column, null);
        return false;
    }
    payload.input = input;
    payload.decoder = json.DecodeCursor.init(payload.allocator, bytes, .{});
    payload.builder = ValueBuilder(Runtime).init(self, line, column);
    payload.phase = .decode;
    return true;
}

fn decodeTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return decodeTaskStep(Runtime, self, task);
        }
        fn trace(raw: ?*anyopaque, tracer: *gc.Tracer) void {
            traceDecodeTask(Runtime, raw, tracer);
        }
        fn destroy(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
            destroyDecodeTask(Runtime, raw, allocator);
        }
        const ops = types.TaskOps{ .step = step, .trace_payload = trace, .destroy_payload = destroy };
    }.ops;
}

fn decodeTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload: *DecodeTaskPayload(Runtime) = @ptrCast(@alignCast(task.payload orelse return runtimeTaskError("invalid JSON decode task")));
    if (payload.phase == .read) {
        if (!task.child_ready) return .{ .call = .{ .callable = task.inputs[2], .positional = &.{} } };
        if (task.child_error != null) return .propagate;
        const input = task.child_value;
        task.child_ready = false;
        task.child_value = Value.noneValue();
        if (!initializeDecode(Runtime, self, payload, input, task.line, task.column)) return taskCurrentError(self);
    }
    const builder = &(payload.builder orelse return runtimeTaskError("JSON value builder is unavailable"));
    const decoder = &(payload.decoder orelse return runtimeTaskError("JSON decoder is unavailable"));
    builder.begin();
    defer builder.end();
    for (0..64) |_| {
        if (!self.chargeBulkWork(1)) return .yield;
        const event = decoder.next() catch |err| return switch (err) {
            error.InvalidJson => decodeTaskFailure(self, payload.error_class, decoder.parser.input, decoder.diagnostic().?, task.line, task.column),
            error.OutOfMemory => .{ .raise = exceptions.memoryError() },
        };
        if (event == null) return .{ .complete = builder.result orelse return runtimeTaskError("JSON decoder produced no value") };
        builder.emit(event.?) catch |err| return switch (err) {
            error.RuntimeFailure => taskCurrentError(self),
        };
    }
    return .yield;
}

fn traceDecodeTask(comptime Runtime: type, raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *DecodeTaskPayload(Runtime) = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(&payload.error_class.header);
    tracer.visit(payload.input.asObject());
    if (payload.builder) |*builder| {
        for (&builder.roots) |*root| tracer.visit(root.object);
        if (builder.result) |value| tracer.visit(value.asObject());
    }
}

fn destroyDecodeTask(comptime Runtime: type, raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *DecodeTaskPayload(Runtime) = @ptrCast(@alignCast(raw orelse return));
    if (payload.decoder) |*decoder| decoder.deinit();
    if (payload.owned_document) |document| allocator.free(document);
    allocator.destroy(payload);
}

const EncodePhase = enum { encode, write };

fn EncodeTaskPayload(comptime Runtime: type) type {
    return struct {
        allocator: std.mem.Allocator,
        phase: EncodePhase = .encode,
        traversal: ValueEncodeCursor(Runtime),
        method: Value = Value.noneValue(),
        output: Value = Value.noneValue(),
        write_args: [1]Value = .{Value.noneValue()},
        has_file: bool,
    };
}

fn startEncodeTask(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    error_class: *exceptions.ExceptionClass,
    value: Value,
    file: ?Value,
    option_values: []const Value,
    line: u32,
    column: u32,
) bool {
    const options = parseEncodeOptions(Runtime, self, option_values, line, column) orelse return false;
    var method = Value.noneValue();
    if (file) |target| {
        method = self.lookupAttributeValue(target, "write", line, column) orelse {
            if (self.last_exception == null) _ = self.nativeAttributeError(line, column, "file-like object has no required method");
            return false;
        };
    }
    var roots_array = [_]gc.Root{
        .{ .object = value.asObject() },
        .{ .object = if (file) |target| target.asObject() else null },
        .{ .object = method.asObject() },
        .{ .object = &error_class.header },
    };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const Payload = EncodeTaskPayload(Runtime);
    const payload = self.heap.allocator.create(Payload) catch return memoryFailure(self, line, column);
    payload.* = .{
        .allocator = self.heap.allocator,
        .traversal = ValueEncodeCursor(Runtime).init(self, value, options, line, column),
        .method = method,
        .has_file = file != null,
    };
    const caller = self.top_frame orelse {
        destroyEncodeTask(Runtime, payload, self.heap.allocator);
        return self.engineFault();
    };
    var inputs: [9]Value = @splat(Value.noneValue());
    inputs[0] = value;
    inputs[1] = file orelse Value.noneValue();
    inputs[2] = method;
    inputs[3] = Value.object(&error_class.header);
    for (option_values, 0..) |option, index| inputs[index + 4] = option;
    const input_count = 4 + option_values.len;
    const task = types.createTask(&self.heap, self.currentNativeTask(), .json, @intFromEnum(Function.dumps), @ptrCast(caller), destination, line, column, inputs[0..input_count], encodeTaskOps(Runtime)) catch {
        destroyEncodeTask(Runtime, payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn encodeTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return encodeTaskStep(Runtime, self, task);
        }
        fn trace(raw: ?*anyopaque, tracer: *gc.Tracer) void {
            traceEncodeTask(Runtime, raw, tracer);
        }
        fn destroy(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
            destroyEncodeTask(Runtime, raw, allocator);
        }
        const ops = types.TaskOps{ .step = step, .trace_payload = trace, .destroy_payload = destroy };
    }.ops;
}

fn encodeTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload: *EncodeTaskPayload(Runtime) = @ptrCast(@alignCast(task.payload orelse return runtimeTaskError("invalid JSON encode task")));
    if (payload.phase == .write) {
        if (!task.child_ready) return .{ .call = .{ .callable = payload.method, .positional = &payload.write_args } };
        if (task.child_error != null) return .propagate;
        return .{ .complete = Value.noneValue() };
    }
    for (0..64) |_| {
        if (!self.chargeBulkWork(1)) return .yield;
        const advanced = payload.traversal.advance() catch |err| return encodeTaskError(self, err);
        switch (advanced) {
            .progress => {},
            .complete => |bytes| {
                defer self.heap.allocator.free(bytes);
                const output = self.createStringValue(bytes, task.line, task.column) orelse return taskCurrentError(self);
                payload.output = output;
                payload.write_args[0] = output;
                if (!payload.has_file) return .{ .complete = output };
                payload.phase = .write;
                return .{ .call = .{ .callable = payload.method, .positional = &payload.write_args } };
            },
        }
    }
    return .yield;
}

fn traceEncodeTask(comptime Runtime: type, raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *EncodeTaskPayload(Runtime) = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(payload.method.asObject());
    tracer.visit(payload.output.asObject());
    tracer.visit(payload.write_args[0].asObject());
    payload.traversal.trace(tracer);
}

fn destroyEncodeTask(comptime Runtime: type, raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *EncodeTaskPayload(Runtime) = @ptrCast(@alignCast(raw orelse return));
    payload.traversal.deinit();
    allocator.destroy(payload);
}

fn sequenceItems(value: Value) ?[]const Value {
    const header = value.asObject() orelse return null;
    if (sequence.listFromHeader(header)) |list| return list.items.items;
    if (sequence.tupleFromHeader(header)) |tuple| return tuple.items;
    return null;
}

fn decodeFailure(self: anytype, class: *exceptions.ExceptionClass, document: []const u8, diagnostic: json.Diagnostic, line: u32, column: u32) bool {
    self.setException(.{ .kind = .value_error, .message = diagnostic.message, .native_class = class }, line, column, null);
    attachDecodeAttributes(self, document, diagnostic, line, column) catch return memoryFailure(self, line, column);
    return false;
}

/// Cross-module decode failure path for Response.json(). The importing caller
/// uses `parseUtf8Detailed`, then delegates its diagnostic here so the raised
/// class is identical to the cached public `json.JSONDecodeError`.
pub fn setDecodeError(comptime Runtime: type, self: *Runtime, document: []const u8, diagnostic: json.Diagnostic, line: u32, column: u32) bool {
    const class = self.ensureJsonDecodeErrorClass(line, column) orelse return false;
    return decodeFailure(self, class, document, diagnostic, line, column);
}

fn decodeTaskFailure(self: anytype, class: *exceptions.ExceptionClass, document: []const u8, diagnostic: json.Diagnostic, line: u32, column: u32) types.TaskStep {
    self.setException(.{ .kind = .value_error, .message = diagnostic.message, .native_class = class }, line, column, null);
    attachDecodeAttributes(self, document, diagnostic, line, column) catch return .{ .raise = exceptions.memoryError() };
    return .propagate;
}

fn attachDecodeAttributes(self: anytype, document: []const u8, diagnostic: json.Diagnostic, line: u32, column: u32) !void {
    const instance = self.active_exception orelse return error.OutOfMemory;
    const message = self.createStringValue(diagnostic.message, line, column) orelse return error.OutOfMemory;
    try exceptions.setAttribute(&self.heap, instance, "msg", message);
    const doc = self.createStringValue(document, line, column) orelse return error.OutOfMemory;
    try exceptions.setAttribute(&self.heap, instance, "doc", doc);
    try exceptions.setAttribute(&self.heap, instance, "pos", Value.fromSmallInt(@intCast(diagnostic.pos)).?);
    try exceptions.setAttribute(&self.heap, instance, "lineno", Value.fromSmallInt(@intCast(diagnostic.line)).?);
    try exceptions.setAttribute(&self.heap, instance, "colno", Value.fromSmallInt(@intCast(diagnostic.column)).?);
}

fn moduleState(value: Value) ?*ModuleState {
    const header = value.asObject() orelse return null;
    if (header.kind != &module_state_kind) return null;
    return @ptrCast(@alignCast(header));
}

fn memoryFailure(self: anytype, line: u32, column: u32) bool {
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}

fn runtimeTaskError(message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = .runtime_error, .message = message } };
}

fn taskCurrentError(self: anytype) types.TaskStep {
    return .{ .raise = self.last_exception orelse exceptions.memoryError() };
}

fn encodeTaskError(self: anytype, err: anyerror) types.TaskStep {
    return switch (err) {
        error.OutOfMemory => .{ .raise = exceptions.memoryError() },
        error.NonFiniteFloat => .{ .raise = .{ .kind = .value_error, .message = "out of range float values are not JSON compliant" } },
        error.CircularReference => .{ .raise = .{ .kind = .value_error, .message = "circular reference detected" } },
        error.TokenTooLong => .{ .raise = .{ .kind = .value_error, .message = "JSON token exceeds maximum length" } },
        error.UnsupportedType, error.InvalidKey, error.IncomparableKeys => .{ .raise = .{ .kind = .type_error, .message = "object is not JSON serializable" } },
        error.NestingTooDeep => .{ .raise = .{ .kind = .value_error, .message = "maximum JSON nesting exceeded" } },
        error.RuntimeFailure => taskCurrentError(self),
        else => runtimeTaskError("JSON encoder failed"),
    };
}

fn encodeResultError(self: anytype, err: anyerror) exceptions.Result([]u8) {
    return switch (err) {
        error.OutOfMemory => .{ .python_exception = exceptions.memoryError() },
        error.NonFiniteFloat => .{ .python_exception = .{ .kind = .value_error, .message = "out of range float values are not JSON compliant" } },
        error.CircularReference => .{ .python_exception = .{ .kind = .value_error, .message = "circular reference detected" } },
        error.TokenTooLong => .{ .python_exception = .{ .kind = .value_error, .message = "JSON token exceeds maximum length" } },
        error.UnsupportedType, error.InvalidKey, error.IncomparableKeys => .{ .python_exception = .{ .kind = .type_error, .message = "object is not JSON serializable" } },
        error.NestingTooDeep => .{ .python_exception = .{ .kind = .value_error, .message = "maximum JSON nesting exceeded" } },
        error.RuntimeFailure => if (self.last_exception) |exception| .{ .python_exception = exception } else .{ .engine_error = .internal_invariant },
        else => .{ .engine_error = .internal_invariant },
    };
}

fn ValueBuilder(comptime Runtime: type) type {
    return struct {
        const Self = @This();
        const max_frames = json.max_nesting + 1;
        const scratch_root = max_frames * 2;

        const ContainerKind = enum { array, object };

        const Frame = struct {
            kind: ContainerKind,
            value: Value,
            pending_key: ?Value = null,
        };

        runtime: *Runtime,
        line: u32,
        column: u32,
        frames: [max_frames]Frame = undefined,
        depth: usize = 0,
        roots: [scratch_root + 1]gc.Root = @splat(.{ .object = null }),
        root_frame: gc.RootFrame = .{},
        result: ?Value = null,

        fn init(runtime: *Runtime, line: u32, column: u32) Self {
            return .{ .runtime = runtime, .line = line, .column = column };
        }

        fn begin(self: *Self) void {
            self.root_frame.push(&self.runtime.heap.roots);
            for (&self.roots) |*root| self.root_frame.add(root);
        }

        fn end(self: *Self) void {
            self.root_frame.pop();
        }

        pub fn emit(self: *Self, event: json.Event) !void {
            switch (event) {
                .null_value => try self.attachScalar(Value.noneValue()),
                .boolean => |boolean| try self.attachScalar(if (boolean) Value.trueValue() else Value.falseValue()),
                .integer => |token| {
                    const value = try self.numberValue(number.parseIntegerLiteral(&self.runtime.heap, token));
                    try self.attachScalar(value);
                },
                .float => |token| {
                    const value: f64 = if (std.mem.eql(u8, token, "NaN"))
                        std.math.nan(f64)
                    else if (std.mem.eql(u8, token, "Infinity"))
                        std.math.inf(f64)
                    else if (std.mem.eql(u8, token, "-Infinity"))
                        -std.math.inf(f64)
                    else
                        std.fmt.parseFloat(f64, token) catch return error.RuntimeFailure;
                    try self.attachScalar(Value.fromFloat(value));
                },
                .string => |text| {
                    const value = self.runtime.createStringValue(text, self.line, self.column) orelse return error.RuntimeFailure;
                    try self.attachScalar(value);
                },
                .name => |text| try self.setName(text),
                .array_begin => try self.beginContainer(.array),
                .object_begin => try self.beginContainer(.object),
                .array_end => try self.endContainer(.array),
                .object_end => try self.endContainer(.object),
            }
        }

        fn beginContainer(self: *Self, kind: ContainerKind) !void {
            if (self.depth >= max_frames) return error.RuntimeFailure;
            const value = switch (kind) {
                .array => switch (sequence.createList(&self.runtime.heap, &.{})) {
                    .value => |list| Value.object(&list.header),
                    .python_exception => |exception| {
                        self.runtime.setException(exception, self.line, self.column, null);
                        return error.RuntimeFailure;
                    },
                    .engine_error => return error.RuntimeFailure,
                },
                .object => switch (dict.create(&self.runtime.heap, false)) {
                    .value => |mapping| Value.object(&mapping.header),
                    .python_exception => |exception| {
                        self.runtime.setException(exception, self.line, self.column, null);
                        return error.RuntimeFailure;
                    },
                    .engine_error => return error.RuntimeFailure,
                },
            };
            self.roots[self.depth * 2].object = value.asObject();
            try self.attach(value);
            self.frames[self.depth] = .{ .kind = kind, .value = value };
            self.depth += 1;
        }

        fn endContainer(self: *Self, kind: ContainerKind) !void {
            if (self.depth == 0 or self.frames[self.depth - 1].kind != kind or self.frames[self.depth - 1].pending_key != null) return error.RuntimeFailure;
            self.depth -= 1;
            self.roots[self.depth * 2].object = null;
            self.roots[self.depth * 2 + 1].object = null;
        }

        fn setName(self: *Self, text: []const u8) !void {
            if (self.depth == 0) return error.RuntimeFailure;
            const frame = &self.frames[self.depth - 1];
            if (frame.kind != .object or frame.pending_key != null) return error.RuntimeFailure;
            const key = self.runtime.createStringValue(text, self.line, self.column) orelse return error.RuntimeFailure;
            frame.pending_key = key;
            self.roots[(self.depth - 1) * 2 + 1].object = key.asObject();
        }

        fn attachScalar(self: *Self, value: Value) !void {
            self.roots[scratch_root].object = value.asObject();
            defer self.roots[scratch_root].object = if (self.depth == 0) value.asObject() else null;
            try self.attach(value);
        }

        fn attach(self: *Self, value: Value) !void {
            if (self.depth == 0) {
                if (self.result != null) return error.RuntimeFailure;
                self.result = value;
                self.roots[scratch_root].object = value.asObject();
                return;
            }
            const frame = &self.frames[self.depth - 1];
            const header = frame.value.asObject() orelse return error.RuntimeFailure;
            switch (frame.kind) {
                .array => {
                    const list = sequence.listFromHeader(header) orelse return error.RuntimeFailure;
                    switch (sequence.append(&self.runtime.heap, list, value)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.runtime.setException(exception, self.line, self.column, null);
                            return error.RuntimeFailure;
                        },
                        .engine_error => return error.RuntimeFailure,
                    }
                },
                .object => {
                    const key = frame.pending_key orelse return error.RuntimeFailure;
                    const mapping = dict.dictFromHeader(header) orelse return error.RuntimeFailure;
                    const key_hash = self.runtime.pythonHash(key, self.line, self.column) orelse return error.RuntimeFailure;
                    if (!self.runtime.setMappingValueWithHash(mapping, key, value, key_hash, self.line, self.column)) return error.RuntimeFailure;
                    frame.pending_key = null;
                    self.roots[(self.depth - 1) * 2 + 1].object = null;
                },
            }
        }

        fn numberValue(self: *Self, result: number.ValueResult) !Value {
            return switch (result) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.runtime.setException(exception, self.line, self.column, null);
                    return error.RuntimeFailure;
                },
                .engine_error => return error.RuntimeFailure,
            };
        }
    };
}

fn ValueEncodeCursor(comptime Runtime: type) type {
    return struct {
        const Self = @This();
        const KeyKind = enum { none, numeric, text };
        const Key = struct { entry_index: usize, value: Value, text: []u8, kind: KeyKind };
        const MappingPhase = enum { collect, sort, begin, emit };
        const SequenceFrame = struct { header: *gc.Header, items: []const Value, index: usize = 0 };
        const MappingFrame = struct {
            header: *gc.Header,
            mapping: *dict.Dict,
            keys: std.ArrayList(Key) = .empty,
            scan: usize = 0,
            phase: MappingPhase = .collect,
            sort_i: usize = 1,
            sort_j: usize = 1,
            emit_index: usize = 0,
        };
        const Frame = union(enum) { list: SequenceFrame, tuple: SequenceFrame, mapping: MappingFrame };
        const Advance = union(enum) { progress, complete: []u8 };

        runtime: *Runtime,
        encoder: json.Encoder,
        options: json.EncodeOptions,
        line: u32,
        column: u32,
        current: ?Value,
        frames: std.ArrayList(Frame) = .empty,
        finished: bool = false,

        fn init(runtime: *Runtime, value: Value, options: json.EncodeOptions, line: u32, column: u32) Self {
            return .{
                .runtime = runtime,
                .encoder = json.Encoder.init(runtime.heap.allocator, options),
                .options = options,
                .line = line,
                .column = column,
                .current = value,
            };
        }

        fn deinit(self: *Self) void {
            for (self.frames.items) |*frame| self.deinitFrame(frame);
            self.frames.deinit(self.runtime.heap.allocator);
            self.encoder.deinit();
            self.* = undefined;
        }

        fn trace(self: *Self, tracer: *gc.Tracer) void {
            if (self.current) |value| tracer.visit(value.asObject());
            for (self.frames.items) |*frame| switch (frame.*) {
                .list => |sequence_frame| tracer.visit(sequence_frame.header),
                .tuple => |sequence_frame| tracer.visit(sequence_frame.header),
                .mapping => |*mapping_frame| {
                    tracer.visit(mapping_frame.header);
                    for (mapping_frame.keys.items) |key| tracer.visit(key.value.asObject());
                },
            };
        }

        fn advance(self: *Self) !Advance {
            if (self.finished) return error.InvalidEventStream;
            if (self.current) |value| {
                self.current = null;
                try self.visit(value);
                return .progress;
            }
            if (self.frames.items.len == 0) {
                self.finished = true;
                return .{ .complete = try self.encoder.finish() };
            }
            const frame = &self.frames.items[self.frames.items.len - 1];
            switch (frame.*) {
                .list => |*sequence_frame| return try self.advanceSequence(sequence_frame, .array_end),
                .tuple => |*sequence_frame| return try self.advanceSequence(sequence_frame, .array_end),
                .mapping => |*mapping_frame| return try self.advanceMapping(mapping_frame),
            }
        }

        fn advanceSequence(self: *Self, frame: *SequenceFrame, end_event: json.Event) !Advance {
            if (frame.index < frame.items.len) {
                self.current = frame.items[frame.index];
                frame.index += 1;
                return .progress;
            }
            try self.encoder.emit(end_event);
            var removed = self.frames.pop().?;
            self.deinitFrame(&removed);
            return .progress;
        }

        fn advanceMapping(self: *Self, frame: *MappingFrame) !Advance {
            switch (frame.phase) {
                .collect => {
                    if (frame.scan < frame.mapping.entries.items.len) {
                        const index = frame.scan;
                        frame.scan += 1;
                        const entry = frame.mapping.entries.items[index];
                        if (entry.alive) {
                            const key = try self.makeKey(index, entry.key);
                            frame.keys.append(self.runtime.heap.allocator, key) catch |err| {
                                if (key.text.len != 0) self.runtime.heap.allocator.free(key.text);
                                return err;
                            };
                        }
                        return .progress;
                    }
                    frame.phase = if (self.options.sort_keys and frame.keys.items.len > 1) .sort else .begin;
                    return .progress;
                },
                .sort => {
                    if (frame.sort_i >= frame.keys.items.len) {
                        frame.phase = .begin;
                        return .progress;
                    }
                    if (frame.sort_j > 0 and try self.lessKey(frame.keys.items[frame.sort_j], frame.keys.items[frame.sort_j - 1])) {
                        std.mem.swap(Key, &frame.keys.items[frame.sort_j], &frame.keys.items[frame.sort_j - 1]);
                        frame.sort_j -= 1;
                    } else {
                        frame.sort_i += 1;
                        frame.sort_j = frame.sort_i;
                    }
                    return .progress;
                },
                .begin => {
                    try self.encoder.emit(.object_begin);
                    frame.phase = .emit;
                    return .progress;
                },
                .emit => {
                    if (frame.emit_index < frame.keys.items.len) {
                        const key = frame.keys.items[frame.emit_index];
                        frame.emit_index += 1;
                        try self.encoder.emit(.{ .name = key.text });
                        self.current = frame.mapping.entries.items[key.entry_index].value;
                        return .progress;
                    }
                    try self.encoder.emit(.object_end);
                    var removed = self.frames.pop().?;
                    self.deinitFrame(&removed);
                    return .progress;
                },
            }
        }

        fn visit(self: *Self, value: Value) !void {
            if (self.frames.items.len > self.options.nesting_limit) return error.NestingTooDeep;
            if (value.tag() == .none) return self.encoder.emit(.null_value);
            if (value.asBool()) |boolean| return self.encoder.emit(.{ .boolean = boolean });
            if (number.isIntegerValue(value)) {
                const formatted = number.formatInteger(&self.runtime.heap, value) orelse return error.UnsupportedType;
                const text = try self.numberText(formatted);
                defer self.runtime.heap.allocator.free(text);
                return self.encoder.emit(.{ .integer = text });
            }
            if (value.asFloat()) |float_value| {
                if (std.math.isNan(float_value)) return self.encoder.emit(.{ .float = "NaN" });
                if (std.math.isPositiveInf(float_value)) return self.encoder.emit(.{ .float = "Infinity" });
                if (std.math.isNegativeInf(float_value)) return self.encoder.emit(.{ .float = "-Infinity" });
                const text = self.runtime.renderValueOwned(value, true, self.line, self.column) orelse return error.RuntimeFailure;
                defer self.runtime.heap.allocator.free(text);
                return self.encoder.emit(.{ .float = text });
            }
            const header = value.asObject() orelse return error.UnsupportedType;
            if (string.fromHeader(header)) |text| return self.encoder.emit(.{ .string = string.content(text) });
            try self.checkCycle(header);
            if (sequence.listFromHeader(header)) |list| {
                try self.encoder.emit(.array_begin);
                try self.frames.append(self.runtime.heap.allocator, .{ .list = .{ .header = header, .items = list.items.items } });
                return;
            }
            if (sequence.tupleFromHeader(header)) |tuple| {
                try self.encoder.emit(.array_begin);
                try self.frames.append(self.runtime.heap.allocator, .{ .tuple = .{ .header = header, .items = tuple.items } });
                return;
            }
            if (dict.dictFromHeader(header)) |mapping| {
                if (mapping.is_set) return error.UnsupportedType;
                try self.frames.append(self.runtime.heap.allocator, .{ .mapping = .{ .header = header, .mapping = mapping } });
                return;
            }
            return error.UnsupportedType;
        }

        fn checkCycle(self: *Self, header: *gc.Header) !void {
            for (self.frames.items) |frame| switch (frame) {
                .list => |sequence_frame| if (sequence_frame.header == header) return error.CircularReference,
                .tuple => |sequence_frame| if (sequence_frame.header == header) return error.CircularReference,
                .mapping => |mapping_frame| if (mapping_frame.header == header) return error.CircularReference,
            };
        }

        fn makeKey(self: *Self, index: usize, value: Value) !Key {
            if (value.tag() == .none) return .{ .entry_index = index, .value = value, .text = try self.runtime.heap.allocator.dupe(u8, "null"), .kind = .none };
            if (value.asBool()) |boolean| return .{ .entry_index = index, .value = value, .text = try self.runtime.heap.allocator.dupe(u8, if (boolean) "true" else "false"), .kind = .numeric };
            if (number.isIntegerValue(value)) {
                const formatted = number.formatInteger(&self.runtime.heap, value) orelse return error.InvalidKey;
                return .{ .entry_index = index, .value = value, .text = try self.numberText(formatted), .kind = .numeric };
            }
            if (value.asFloat()) |float_value| {
                if (!self.options.allow_nan and !std.math.isFinite(float_value)) return error.NonFiniteFloat;
                const text = if (std.math.isNan(float_value))
                    try self.runtime.heap.allocator.dupe(u8, "NaN")
                else if (std.math.isPositiveInf(float_value))
                    try self.runtime.heap.allocator.dupe(u8, "Infinity")
                else if (std.math.isNegativeInf(float_value))
                    try self.runtime.heap.allocator.dupe(u8, "-Infinity")
                else
                    self.runtime.renderValueOwned(value, true, self.line, self.column) orelse return error.RuntimeFailure;
                return .{ .entry_index = index, .value = value, .text = text, .kind = .numeric };
            }
            const header = value.asObject() orelse return error.InvalidKey;
            const text = string.fromHeader(header) orelse return error.InvalidKey;
            return .{ .entry_index = index, .value = value, .text = try self.runtime.heap.allocator.dupe(u8, string.content(text)), .kind = .text };
        }

        fn numberText(self: *Self, result: exceptions.Result([]u8)) ![]u8 {
            return switch (result) {
                .value => |text| text,
                .python_exception => |exception| {
                    self.runtime.setException(exception, self.line, self.column, null);
                    return error.RuntimeFailure;
                },
                .engine_error => error.RuntimeFailure,
            };
        }

        fn lessKey(_: *Self, left: Key, right: Key) !bool {
            if (left.kind != right.kind and !(left.kind == .numeric and right.kind == .numeric)) return error.IncomparableKeys;
            return switch (left.kind) {
                .text => std.mem.lessThan(u8, left.text, right.text),
                .none => false,
                .numeric => switch (number.compare(left.value, right.value)) {
                    .value => |comparison| comparison == .less,
                    else => error.IncomparableKeys,
                },
            };
        }

        fn deinitFrame(self: *Self, frame: *Frame) void {
            switch (frame.*) {
                .mapping => |*mapping_frame| {
                    for (mapping_frame.keys.items) |key| if (key.text.len != 0) self.runtime.heap.allocator.free(key.text);
                    mapping_frame.keys.deinit(self.runtime.heap.allocator);
                },
                else => {},
            }
        }

    };
}

pub fn serializeUtf8(
    comptime Runtime: type,
    self: *Runtime,
    value: Value,
    options: json.EncodeOptions,
    line: u32,
    column: u32,
) exceptions.Result([]u8) {
    var value_root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&value_root);
    defer roots.pop();
    var traversal = ValueEncodeCursor(Runtime).init(self, value, options, line, column);
    defer traversal.deinit();
    while (true) switch (traversal.advance() catch |err| return encodeResultError(self, err)) {
        .progress => {},
        .complete => |output| return .{ .value = output },
    };
}
