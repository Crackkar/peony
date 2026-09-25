const std = @import("std");
const binder = @import("runtime_binder");
const bytes_module = @import("runtime_bytes");
const class_module = @import("runtime_class");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const file_module = @import("runtime_file");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const iterator_module = @import("runtime_iterator");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const string_module = @import("runtime_string");
const types = @import("types.zig");
const collections = @import("collections.zig");

const Value = types.Value;

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "copy", .params = &.{.{ .name = "x" }} },
    .{ .id = 2, .name = "deepcopy", .params = &.{ .{ .name = "x" }, .{ .name = "memo", .default = .none } } },
};

const ModuleState = struct {
    header: gc.Header align(8),
    error_class: *exceptions.ExceptionClass,
};

const module_state_kind = gc.Kind{ .trace = traceModuleState };

const MappingFrame = struct {
    source: *dict_module.Dict,
    target: *dict_module.Dict,
    completed: Value,
    index: usize = 0,
    pending_key: Value = Value.noneValue(),
    copying_value: bool = false,
};

const DeepFrame = union(enum) {
    list: struct { source: *sequence.List, target: *sequence.List, index: usize = 0 },
    tuple: struct { source: *sequence.Tuple, target: *sequence.Tuple, index: usize = 0 },
    mapping: MappingFrame,
    instance: struct { source: *class_module.Instance, target: *class_module.Instance, index: usize = 0 },
};

const DeepTaskPayload = struct {
    allocator: std.mem.Allocator,
    memo: *dict_module.Dict,
    error_class: *exceptions.ExceptionClass,
    current: Value,
    frames: std.ArrayList(DeepFrame) = .empty,
    waiting_hook: bool = false,
    hook_source: Value = Value.noneValue(),
    hook_method: Value = Value.noneValue(),
    hook_args: [1]Value = .{Value.noneValue()},
};

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const error_class = switch (exceptions.createNativeClass(&self.heap, "Error", .exception, null)) {
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
    if (!self.environmentStore(environment, "Error", Value.object(&error_class.header))) return memoryFailure(self, line, column);
    const state = self.heap.createObject(ModuleState, &module_state_kind) catch return memoryFailure(self, line, column);
    state.* = .{ .header = state.header, .error_class = error_class };
    var state_root = gc.Root{ .object = &state.header };
    roots.add(&state_root);
    for (functions) |spec| if (!storeBound(self, environment, state, spec, line, column)) return false;
    return true;
}

fn storeBound(self: anytype, environment: *gc.Header, state: *ModuleState, spec: types.FunctionSpec, line: u32, column: u32) bool {
    const created = functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.copy), spec.id, Value.object(&state.header));
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
    const state = moduleState(receiver) orelse return self.engineFault();
    if (function_id == 1) return copyValue(Runtime, self, destination, state, args[0], line, column);
    if (function_id == 2) return deepCopy(Runtime, self, destination, state, args[0], args[1], line, column);
    return self.engineFault();
}

fn copyValue(comptime Runtime: type, self: *Runtime, destination: u16, state: *ModuleState, value: Value, line: u32, column: u32) bool {
    if (value.asObject()) |header| if (sequence.tupleFromHeader(header) != null) {
        self.setRegister(destination, value);
        return true;
    };
    if (immutableScalar(value)) {
        self.setRegister(destination, value);
        return true;
    }
    if (value.asObject()) |header| {
        if (sequence.listFromHeader(header)) |list| return storeList(self, destination, sequence.createList(&self.heap, list.items.items), line, column);
        if (dict_module.dictFromHeader(header)) |mapping| return storeDict(self, destination, dict_module.copy(&self.heap, mapping), line, column);
        if (types.fromHeader(header)) |native| if (native.ops) |ops| if (ops.mapping) |mapping_fn| {
            const source_mapping = mapping_fn(native) orelse return self.engineFault();
            const clone = collections.createEmptyClone(Runtime, self, native, line, column) orelse return false;
            var clone_root = gc.Root{ .object = &clone.header };
            var roots = gc.RootFrame{};
            roots.push(&self.heap.roots);
            roots.add(&clone_root);
            defer roots.pop();
            const target_mapping = clone.ops.?.mapping.?(clone) orelse return self.engineFault();
            for (source_mapping.entries.items) |entry| if (entry.alive and !self.setMappingValueWithHash(target_mapping, entry.key, entry.value, entry.hash, line, column)) return false;
            self.setRegister(destination, Value.object(&clone.header));
            return true;
        };
        if (class_module.instanceFromHeader(header)) |instance| {
            if (self.lookupAttributeValue(value, "__copy__", line, column)) |method| return startHookTask(Runtime, self, destination, state, value, method, Value.noneValue(), false, line, column);
            if (self.last_exception != null) return false;
            const clone = shallowInstance(self, instance, line, column) orelse return false;
            self.setRegister(destination, clone);
            return true;
        }
        if (isResource(header)) return copyFailure(self, state.error_class, "cannot copy live resource", line, column);
    }
    self.setRegister(destination, value);
    return true;
}

fn deepCopy(comptime Runtime: type, self: *Runtime, destination: u16, state: *ModuleState, value: Value, memo_value: Value, line: u32, column: u32) bool {
    const memo = if (memo_value.tag() == .none) switch (dict_module.create(&self.heap, false)) {
        .value => |mapping| mapping,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    } else dict_module.dictFromHeader(memo_value.asObject() orelse return self.nativeTypeError(line, column, "memo must be a dict")) orelse return self.nativeTypeError(line, column, "memo must be a dict");
    var roots_array = [_]gc.Root{ .{ .object = value.asObject() }, .{ .object = &memo.header } };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const payload = self.heap.allocator.create(DeepTaskPayload) catch return memoryFailure(self, line, column);
    payload.* = .{ .allocator = self.heap.allocator, .memo = memo, .error_class = state.error_class, .current = value, .hook_args = .{Value.object(&memo.header)} };
    const caller = self.top_frame orelse {
        destroyDeepTask(payload, self.heap.allocator);
        return self.engineFault();
    };
    const task = types.createTask(&self.heap, self.currentNativeTask(), .copy, 3, @ptrCast(caller), destination, line, column, &.{ value, Value.object(&memo.header) }, deepTaskOps(Runtime)) catch {
        destroyDeepTask(payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn deepTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return deepTaskStep(Runtime, self, task);
        }
        const ops = types.TaskOps{ .step = step, .trace_payload = traceDeepTask, .destroy_payload = destroyDeepTask };
    }.ops;
}

fn deepTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload: *DeepTaskPayload = @ptrCast(@alignCast(task.payload orelse return taskRuntimeError("invalid deepcopy task")));
    var transitions: usize = 0;
    if (payload.waiting_hook) {
        if (!task.child_ready) return .yield;
        if (task.child_error != null) return .propagate;
        if (!memoStore(Runtime, self, payload.memo, payload.hook_source, task.child_value, task.line, task.column)) return taskCurrentError(self);
        const copied = task.child_value;
        task.child_ready = false;
        task.child_value = Value.noneValue();
        payload.waiting_hook = false;
        payload.hook_source = Value.noneValue();
        payload.hook_method = Value.noneValue();
        const accepted = acceptDeepValue(Runtime, self, task, payload, copied);
        switch (accepted) {
            .yield => transitions = 1,
            else => return accepted,
        }
    }
    while (transitions < 64) : (transitions += 1) {
        if (!self.chargeBulkWork(1)) return .yield;
        const advanced = visitDeepValue(Runtime, self, task, payload, payload.current);
        switch (advanced) {
            .yield => {},
            else => return advanced,
        }
    }
    return .yield;
}

fn visitDeepValue(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *DeepTaskPayload, value: Value) types.TaskStep {
    if (immutableScalar(value)) return acceptDeepValue(Runtime, self, task, payload, value);
    if (memoLookup(Runtime, self, payload.memo, value, task.line, task.column)) |cached| return acceptDeepValue(Runtime, self, task, payload, cached);
    const header = value.asObject() orelse return acceptDeepValue(Runtime, self, task, payload, value);

    if (class_module.instanceFromHeader(header)) |source| {
        if (self.lookupAttributeValue(value, "__deepcopy__", task.line, task.column)) |method| {
            payload.waiting_hook = true;
            payload.hook_source = value;
            payload.hook_method = method;
            return .{ .call = .{ .callable = method, .positional = &payload.hook_args } };
        }
        if (self.last_exception != null) return taskCurrentError(self);
        const target = switch (class_module.createInstance(&self.heap, source.class)) {
            .value => |instance| instance,
            .python_exception => |exception| return .{ .raise = exception },
            .engine_error => return taskRuntimeError("failed to create deepcopy instance"),
        };
        var target_root = gc.Root{ .object = &target.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&target_root);
        defer roots.pop();
        const target_value = Value.object(&target.header);
        if (!memoStore(Runtime, self, payload.memo, value, target_value, task.line, task.column)) return taskCurrentError(self);
        if (source.attributes.items.len == 0) return acceptDeepValue(Runtime, self, task, payload, target_value);
        payload.frames.append(payload.allocator, .{ .instance = .{ .source = source, .target = target } }) catch return .{ .raise = exceptions.memoryError() };
        payload.current = source.attributes.items[0].value;
        return .yield;
    }

    if (sequence.listFromHeader(header)) |source| {
        const target = switch (sequence.createList(&self.heap, &.{})) {
            .value => |list| list,
            .python_exception => |exception| return .{ .raise = exception },
            .engine_error => return taskRuntimeError("failed to create deepcopy list"),
        };
        var target_root = gc.Root{ .object = &target.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&target_root);
        defer roots.pop();
        const target_value = Value.object(&target.header);
        if (!memoStore(Runtime, self, payload.memo, value, target_value, task.line, task.column)) return taskCurrentError(self);
        if (source.items.items.len == 0) return acceptDeepValue(Runtime, self, task, payload, target_value);
        payload.frames.append(payload.allocator, .{ .list = .{ .source = source, .target = target } }) catch return .{ .raise = exceptions.memoryError() };
        payload.current = source.items.items[0];
        return .yield;
    }

    if (sequence.tupleFromHeader(header)) |source| {
        const placeholders = payload.allocator.alloc(Value, source.items.len) catch return .{ .raise = exceptions.memoryError() };
        defer payload.allocator.free(placeholders);
        @memset(placeholders, Value.noneValue());
        const target = switch (sequence.createTuple(&self.heap, placeholders)) {
            .value => |tuple| tuple,
            .python_exception => |exception| return .{ .raise = exception },
            .engine_error => return taskRuntimeError("failed to create deepcopy tuple"),
        };
        var target_root = gc.Root{ .object = &target.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&target_root);
        defer roots.pop();
        const target_value = Value.object(&target.header);
        if (!memoStore(Runtime, self, payload.memo, value, target_value, task.line, task.column)) return taskCurrentError(self);
        if (source.items.len == 0) return acceptDeepValue(Runtime, self, task, payload, target_value);
        payload.frames.append(payload.allocator, .{ .tuple = .{ .source = source, .target = target } }) catch return .{ .raise = exceptions.memoryError() };
        payload.current = source.items[0];
        return .yield;
    }

    if (dict_module.dictFromHeader(header)) |source| return beginDeepMapping(Runtime, self, task, payload, value, source, null);
    if (types.fromHeader(header)) |native| if (native.ops) |ops| if (ops.mapping) |mapping_fn| {
        const source = mapping_fn(native) orelse return taskRuntimeError("invalid native mapping");
        const clone = collections.createEmptyClone(Runtime, self, native, task.line, task.column) orelse return taskCurrentError(self);
        const target = clone.ops.?.mapping.?(clone) orelse return taskRuntimeError("invalid native mapping clone");
        return beginDeepMapping(Runtime, self, task, payload, value, source, .{ .object = clone, .mapping = target });
    };
    if (isResource(header) or types.fromHeader(header) != null) return .{ .raise = .{ .kind = .exception, .message = "cannot deepcopy live resource", .native_class = payload.error_class } };
    return acceptDeepValue(Runtime, self, task, payload, value);
}

const NativeMappingTarget = struct { object: *types.NativeObject, mapping: *dict_module.Dict };

fn beginDeepMapping(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *DeepTaskPayload, source_value: Value, source: *dict_module.Dict, native_target: ?NativeMappingTarget) types.TaskStep {
    const target = if (native_target) |selected| selected.mapping else switch (dict_module.create(&self.heap, source.is_set)) {
        .value => |mapping| mapping,
        .python_exception => |exception| return .{ .raise = exception },
        .engine_error => return taskRuntimeError("failed to create deepcopy mapping"),
    };
    const target_value = if (native_target) |selected| Value.object(&selected.object.header) else Value.object(&target.header);
    var target_root = gc.Root{ .object = target_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&target_root);
    defer roots.pop();
    if (!memoStore(Runtime, self, payload.memo, source_value, target_value, task.line, task.column)) return taskCurrentError(self);
    const first = nextAliveEntry(source, 0) orelse return acceptDeepValue(Runtime, self, task, payload, target_value);
    payload.frames.append(payload.allocator, .{ .mapping = .{ .source = source, .target = target, .completed = target_value, .index = first } }) catch return .{ .raise = exceptions.memoryError() };
    payload.current = source.entries.items[first].key;
    return .yield;
}

fn acceptDeepValue(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *DeepTaskPayload, value: Value) types.TaskStep {
    if (payload.frames.items.len == 0) return .{ .complete = value };
    const frame = &payload.frames.items[payload.frames.items.len - 1];
    switch (frame.*) {
        .list => |*list| {
            switch (sequence.append(&self.heap, list.target, value)) {
                .value => {},
                .python_exception => |exception| return .{ .raise = exception },
                .engine_error => return taskRuntimeError("failed to append deepcopy list value"),
            }
            list.index += 1;
            if (list.index < list.source.items.items.len) {
                payload.current = list.source.items.items[list.index];
                return .yield;
            }
            const completed = Value.object(&list.target.header);
            _ = payload.frames.pop();
            return acceptDeepValue(Runtime, self, task, payload, completed);
        },
        .tuple => |*tuple| {
            tuple.target.items[tuple.index] = value;
            tuple.index += 1;
            if (tuple.index < tuple.source.items.len) {
                payload.current = tuple.source.items[tuple.index];
                return .yield;
            }
            const completed = Value.object(&tuple.target.header);
            _ = payload.frames.pop();
            return acceptDeepValue(Runtime, self, task, payload, completed);
        },
        .instance => |*instance| {
            const attribute = instance.source.attributes.items[instance.index];
            class_module.setInstanceAttribute(&self.heap, instance.target, attribute.name, value) catch return .{ .raise = exceptions.memoryError() };
            instance.index += 1;
            if (instance.index < instance.source.attributes.items.len) {
                payload.current = instance.source.attributes.items[instance.index].value;
                return .yield;
            }
            const completed = Value.object(&instance.target.header);
            _ = payload.frames.pop();
            return acceptDeepValue(Runtime, self, task, payload, completed);
        },
        .mapping => |*mapping| {
            const entry = mapping.source.entries.items[mapping.index];
            if (!mapping.copying_value) {
                mapping.pending_key = value;
                mapping.copying_value = true;
                payload.current = entry.value;
                return .yield;
            }
            if (!self.setMappingValue(mapping.target, mapping.pending_key, value, task.line, task.column)) return taskCurrentError(self);
            mapping.pending_key = Value.noneValue();
            mapping.copying_value = false;
            const next = nextAliveEntry(mapping.source, mapping.index + 1);
            if (next) |index| {
                mapping.index = index;
                payload.current = mapping.source.entries.items[index].key;
                return .yield;
            }
            const completed = mapping.completed;
            _ = payload.frames.pop();
            return acceptDeepValue(Runtime, self, task, payload, completed);
        },
    }
}

fn nextAliveEntry(mapping: *dict_module.Dict, start: usize) ?usize {
    var index = start;
    while (index < mapping.entries.items.len) : (index += 1) if (mapping.entries.items[index].alive) return index;
    return null;
}

fn traceDeepTask(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *DeepTaskPayload = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(&payload.memo.header);
    tracer.visit(&payload.error_class.header);
    tracer.visit(payload.current.asObject());
    tracer.visit(payload.hook_source.asObject());
    tracer.visit(payload.hook_method.asObject());
    tracer.visit(payload.hook_args[0].asObject());
    for (payload.frames.items) |frame| switch (frame) {
        .list => |value| { tracer.visit(&value.source.header); tracer.visit(&value.target.header); },
        .tuple => |value| { tracer.visit(&value.source.header); tracer.visit(&value.target.header); },
        .mapping => |value| { tracer.visit(&value.source.header); tracer.visit(&value.target.header); tracer.visit(value.completed.asObject()); tracer.visit(value.pending_key.asObject()); },
        .instance => |value| { tracer.visit(&value.source.header); tracer.visit(&value.target.header); },
    };
}

fn destroyDeepTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *DeepTaskPayload = @ptrCast(@alignCast(raw orelse return));
    payload.frames.deinit(allocator);
    allocator.destroy(payload);
}

fn taskCurrentError(self: anytype) types.TaskStep {
    return .{ .raise = self.last_exception orelse exceptions.memoryError() };
}

fn taskRuntimeError(message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = .runtime_error, .message = message } };
}

fn deepCopyValue(comptime Runtime: type, self: *Runtime, state: *ModuleState, value: Value, memo: *dict_module.Dict, depth: usize, line: u32, column: u32) exceptions.Result(Value) {
    if (depth >= 256) return .{ .python_exception = .{ .kind = .recursion_error, .message = "maximum copy depth exceeded" } };
    if (!self.chargeBulkWork(1)) return .{ .python_exception = .{ .kind = .runtime_error, .message = "copy work limit exceeded" } };
    if (immutableScalar(value)) return .{ .value = value };
    if (memoLookup(Runtime, self, memo, value, line, column)) |cached| return .{ .value = cached };
    const header = value.asObject() orelse return .{ .value = value };
    if (sequence.listFromHeader(header)) |source| {
        const target = switch (sequence.createList(&self.heap, &.{})) {
            .value => |list| list,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => return .{ .engine_error = .internal_invariant },
        };
        const target_value = Value.object(&target.header);
        if (!memoStore(Runtime, self, memo, value, target_value, line, column)) return currentResult(self);
        for (source.items.items) |item| {
            const copied = takeResult(self, deepCopyValue(Runtime, self, state, item, memo, depth + 1, line, column), line, column) orelse return currentResult(self);
            switch (sequence.append(&self.heap, target, copied)) {
                .value => {},
                .python_exception => |exception| return .{ .python_exception = exception },
                .engine_error => return .{ .engine_error = .internal_invariant },
            }
        }
        return .{ .value = target_value };
    }
    if (sequence.tupleFromHeader(header)) |source| {
        const placeholders = self.heap.allocator.alloc(Value, source.items.len) catch return .{ .python_exception = exceptions.memoryError() };
        defer self.heap.allocator.free(placeholders);
        @memset(placeholders, Value.noneValue());
        const target = switch (sequence.createTuple(&self.heap, placeholders)) {
            .value => |tuple| tuple,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => return .{ .engine_error = .internal_invariant },
        };
        const target_value = Value.object(&target.header);
        if (!memoStore(Runtime, self, memo, value, target_value, line, column)) return currentResult(self);
        for (source.items, 0..) |item, index| target.items[index] = takeResult(self, deepCopyValue(Runtime, self, state, item, memo, depth + 1, line, column), line, column) orelse return currentResult(self);
        return .{ .value = target_value };
    }
    if (dict_module.dictFromHeader(header)) |source| {
        const target = switch (dict_module.create(&self.heap, source.is_set)) {
            .value => |mapping| mapping,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => return .{ .engine_error = .internal_invariant },
        };
        const target_value = Value.object(&target.header);
        if (!memoStore(Runtime, self, memo, value, target_value, line, column)) return currentResult(self);
        for (source.entries.items) |entry| {
            if (!entry.alive) continue;
            const key = takeResult(self, deepCopyValue(Runtime, self, state, entry.key, memo, depth + 1, line, column), line, column) orelse return currentResult(self);
            const item = takeResult(self, deepCopyValue(Runtime, self, state, entry.value, memo, depth + 1, line, column), line, column) orelse return currentResult(self);
            if (!self.setMappingValue(target, key, item, line, column)) return currentResult(self);
        }
        return .{ .value = target_value };
    }
    if (types.fromHeader(header)) |native| if (native.ops) |ops| if (ops.mapping) |mapping_fn| {
        const source = mapping_fn(native) orelse return .{ .engine_error = .internal_invariant };
        const clone = collections.createEmptyClone(Runtime, self, native, line, column) orelse return currentResult(self);
        const target_value = Value.object(&clone.header);
        if (!memoStore(Runtime, self, memo, value, target_value, line, column)) return currentResult(self);
        const target = clone.ops.?.mapping.?(clone) orelse return .{ .engine_error = .internal_invariant };
        for (source.entries.items) |entry| {
            if (!entry.alive) continue;
            const key = takeResult(self, deepCopyValue(Runtime, self, state, entry.key, memo, depth + 1, line, column), line, column) orelse return currentResult(self);
            const item = takeResult(self, deepCopyValue(Runtime, self, state, entry.value, memo, depth + 1, line, column), line, column) orelse return currentResult(self);
            if (!self.setMappingValue(target, key, item, line, column)) return currentResult(self);
        }
        return .{ .value = target_value };
    };
    if (class_module.instanceFromHeader(header)) |source| {
        if (class_module.classAttribute(source.class, "__deepcopy__") != null) return .{ .python_exception = .{ .kind = .type_error, .message = "nested __deepcopy__ hook requires task scheduling" } };
        const target = switch (class_module.createInstance(&self.heap, source.class)) {
            .value => |instance| instance,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => return .{ .engine_error = .internal_invariant },
        };
        const target_value = Value.object(&target.header);
        if (!memoStore(Runtime, self, memo, value, target_value, line, column)) return currentResult(self);
        for (source.attributes.items) |attribute| {
            const copied = takeResult(self, deepCopyValue(Runtime, self, state, attribute.value, memo, depth + 1, line, column), line, column) orelse return currentResult(self);
            class_module.setInstanceAttribute(&self.heap, target, attribute.name, copied) catch return .{ .python_exception = exceptions.memoryError() };
        }
        return .{ .value = target_value };
    }
    if (isResource(header) or types.fromHeader(header) != null) return .{ .python_exception = .{ .kind = .exception, .message = "cannot deepcopy live resource", .native_class = state.error_class } };
    return .{ .value = value };
}

fn startHookTask(comptime Runtime: type, self: *Runtime, destination: u16, state: *ModuleState, value: Value, method: Value, memo: Value, deep: bool, line: u32, column: u32) bool {
    var roots_array = [_]gc.Root{ .{ .object = value.asObject() }, .{ .object = method.asObject() }, .{ .object = memo.asObject() }, .{ .object = &state.error_class.header } };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const caller = self.top_frame orelse return self.engineFault();
    const task = types.createTask(&self.heap, self.currentNativeTask(), .copy, if (deep) 2 else 1, @ptrCast(caller), destination, line, column, &.{ value, method, memo }, hookTaskOps(Runtime)) catch return memoryFailure(self, line, column);
    return self.startNativeTask(task);
}

fn hookTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            if (!task.child_ready) return .{ .call = .{ .callable = task.inputs[1], .positional = if (task.operation == 2) task.inputs[2..3] else &.{} } };
            if (task.child_error != null) return .propagate;
            if (task.operation == 2) {
                const memo = dict_module.dictFromHeader(task.inputs[2].asObject() orelse return .{ .raise = .{ .kind = .runtime_error, .message = "copy memo is unavailable" } }) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "copy memo is unavailable" } };
                if (!memoStore(Runtime, self, memo, task.inputs[0], task.child_value, task.line, task.column)) return .{ .raise = self.last_exception orelse exceptions.memoryError() };
            }
            return .{ .complete = task.child_value };
        }
        const ops = types.TaskOps{ .step = step };
    }.ops;
}

fn shallowInstance(self: anytype, source: *class_module.Instance, line: u32, column: u32) ?Value {
    const target = switch (class_module.createInstance(&self.heap, source.class)) {
        .value => |instance| instance,
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk null; },
        .engine_error => blk: { _ = self.engineFault(); break :blk null; },
    } orelse return null;
    var root = gc.Root{ .object = &target.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    for (source.attributes.items) |attribute| class_module.setInstanceAttribute(&self.heap, target, attribute.name, attribute.value) catch {
        _ = memoryFailure(self, line, column);
        return null;
    };
    return Value.object(&target.header);
}

fn memoLookup(comptime Runtime: type, self: *Runtime, memo: *dict_module.Dict, source: Value, line: u32, column: u32) ?Value {
    const header = source.asObject() orelse return null;
    const key = idValue(self, header, line, column) orelse return null;
    const hash = self.pythonHash(key, line, column) orelse return null;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    return switch (dict_module.get(memo, key, hash, &context, equalityThunk(Runtime))) {
        .value => |value| value,
        .missing, .failed => null,
    };
}

fn memoStore(comptime Runtime: type, self: *Runtime, memo: *dict_module.Dict, source: Value, target: Value, line: u32, column: u32) bool {
    var target_root = gc.Root{ .object = target.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&target_root);
    defer roots.pop();
    const key = idValue(self, source.asObject() orelse return true, line, column) orelse return false;
    return self.setMappingValue(memo, key, target, line, column);
}

fn idValue(self: anytype, header: *gc.Header, line: u32, column: u32) ?Value {
    return switch (number.fromInt(&self.heap, @intFromPtr(header))) {
        .value => |value| value,
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk null; },
        .engine_error => blk: { _ = self.engineFault(); break :blk null; },
    };
}

fn immutableScalar(value: Value) bool {
    if (value.asObject()) |header| {
        if (string_module.fromHeader(header) != null or bytes_module.fromHeader(header) != null or class_module.classFromHeader(header) != null or functions_module.functionFromHeader(header) != null) return true;
    }
    return value.tag() != .heap_object;
}

fn isResource(header: *gc.Header) bool {
    return file_module.fromHeader(header) != null or iterator_module.iteratorFromHeader(header) != null;
}

fn takeResult(self: anytype, result: exceptions.Result(Value), line: u32, column: u32) ?Value {
    return switch (result) {
        .value => |value| value,
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk null; },
        .engine_error => blk: { _ = self.engineFault(); break :blk null; },
    };
}

fn currentResult(self: anytype) exceptions.Result(Value) {
    if (self.last_exception) |exception| return .{ .python_exception = exception };
    return .{ .engine_error = .internal_invariant };
}

fn storeList(self: anytype, destination: u16, result: exceptions.Result(*sequence.List), line: u32, column: u32) bool {
    return switch (result) {
        .value => |list| blk: { self.setRegister(destination, Value.object(&list.header)); break :blk true; },
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk false; },
        .engine_error => self.engineFault(),
    };
}

fn storeDict(self: anytype, destination: u16, result: exceptions.Result(*dict_module.Dict), line: u32, column: u32) bool {
    return switch (result) {
        .value => |mapping| blk: { self.setRegister(destination, Value.object(&mapping.header)); break :blk true; },
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk false; },
        .engine_error => self.engineFault(),
    };
}

fn EqualityContext(comptime Runtime: type) type { return struct { runtime: *Runtime, line: u32, column: u32 }; }
fn equalityThunk(comptime Runtime: type) dict_module.EqualityFn {
    return struct { fn equal(raw: *anyopaque, left: Value, right: Value) ?bool { const context: *EqualityContext(Runtime) = @ptrCast(@alignCast(raw)); return context.runtime.valuesEqual(left, right, context.line, context.column); } }.equal;
}

fn moduleState(value: Value) ?*ModuleState {
    const header = value.asObject() orelse return null;
    if (header.kind != &module_state_kind) return null;
    return @ptrCast(@alignCast(header));
}
fn traceModuleState(header: *gc.Header, tracer: *gc.Tracer) void { const state: *ModuleState = @ptrCast(@alignCast(header)); tracer.visit(&state.error_class.header); }
fn copyFailure(self: anytype, class: *exceptions.ExceptionClass, message: []const u8, line: u32, column: u32) bool { self.setException(.{ .kind = .exception, .message = message, .native_class = class }, line, column, null); return false; }
fn memoryFailure(self: anytype, line: u32, column: u32) bool { self.setException(exceptions.memoryError(), line, column, null); return false; }
