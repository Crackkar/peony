const std = @import("std");
const binder = @import("runtime_binder");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const types = @import("types.zig");

const Value = types.Value;
const var_keyword = binder.parameter_flags_module.var_keyword;

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "__Counter_constructor", .params = &.{
        .{ .name = "iterable", .default = .none },
        .{ .name = "kw", .flags = var_keyword },
    }, .exported = false },
    .{ .id = 2, .name = "__defaultdict_constructor", .params = &.{
        .{ .name = "default_factory", .flags = binder.parameter_flags_module.positional_only, .default = .none },
        .{ .name = "source", .default = .none },
        .{ .name = "kw", .flags = var_keyword },
    }, .exported = false },
    .{ .id = 101, .name = "update", .params = &.{ .{ .name = "iterable", .default = .none }, .{ .name = "kw", .flags = var_keyword } }, .exported = false },
    .{ .id = 102, .name = "subtract", .params = &.{ .{ .name = "iterable", .default = .none }, .{ .name = "kw", .flags = var_keyword } }, .exported = false },
    .{ .id = 103, .name = "elements", .exported = false },
    .{ .id = 104, .name = "most_common", .params = &.{.{ .name = "n", .default = .none }}, .exported = false },
    .{ .id = 105, .name = "total", .exported = false },
    .{ .id = 106, .name = "copy", .exported = false },
    .{ .id = 120, .name = "get", .params = &.{ .{ .name = "key" }, .{ .name = "default", .default = .none } }, .exported = false },
    .{ .id = 121, .name = "keys", .exported = false },
    .{ .id = 122, .name = "values", .exported = false },
    .{ .id = 123, .name = "items", .exported = false },
    .{ .id = 124, .name = "pop", .params = &.{ .{ .name = "key" }, .{ .name = "default", .default = .none } }, .exported = false },
    .{ .id = 125, .name = "setdefault", .params = &.{ .{ .name = "key" }, .{ .name = "default", .default = .none } }, .exported = false },
    .{ .id = 126, .name = "clear", .exported = false },
    .{ .id = 127, .name = "update", .params = &.{ .{ .name = "source", .default = .none }, .{ .name = "kw", .flags = var_keyword } }, .exported = false },
    .{ .id = 128, .name = "copy", .exported = false },
};

pub const classes = [_]types.TypeSpec{
    .{ .type_id = .counter, .module = .collections, .name = "Counter", .base_primitive = .dict_type, .constructor_id = 1 },
    .{ .type_id = .defaultdict, .module = .collections, .name = "defaultdict", .base_primitive = .dict_type, .constructor_id = 2 },
};

const MappingState = struct {
    mapping: *dict_module.Dict,
    factory: Value = Value.noneValue(),
};

const CounterTaskOperation = enum(u16) { construct = 1, update = 2, subtract = 3 };

const CounterTaskPayload = struct {
    allocator: std.mem.Allocator,
    operation: CounterTaskOperation,
    keywords: []binder.Keyword = &.{},
    keyword_count: usize = 0,
};

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const counter = self.ensureNativeClassWithBase(.counter, "Counter", .dict_type, line, column) orelse return false;
    var counter_root = gc.Root{ .object = &counter.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&counter_root);
    defer roots.pop();
    if (!self.environmentStore(environment, "Counter", Value.object(&counter.header))) return memoryFailure(self, line, column);
    const defaults = self.ensureNativeClassWithBase(.defaultdict, "defaultdict", .dict_type, line, column) orelse return false;
    if (!self.environmentStore(environment, "defaultdict", Value.object(&defaults.header))) return memoryFailure(self, line, column);
    return true;
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
    return switch (function_id) {
        1 => constructCounter(Runtime, self, destination, args[0], extra, line, column),
        2 => constructDefaultdict(Runtime, self, destination, args[0], args[1], extra, line, column),
        101 => counterUpdate(Runtime, self, destination, receiver, args[0], extra, false, line, column),
        102 => counterUpdate(Runtime, self, destination, receiver, args[0], extra, true, line, column),
        103 => counterElements(Runtime, self, destination, receiver, extra, line, column),
        104 => counterMostCommon(Runtime, self, destination, receiver, args[0], extra, line, column),
        105 => counterTotal(self, destination, receiver, extra, line, column),
        106 => counterCopy(Runtime, self, destination, receiver, extra, line, column),
        120 => mappingGet(Runtime, self, destination, receiver, args, extra, line, column),
        121...123 => mappingView(self, destination, receiver, extra, function_id, line, column),
        124 => mappingPop(Runtime, self, destination, receiver, args, extra, line, column),
        125 => mappingSetDefault(Runtime, self, destination, receiver, args, extra, line, column),
        126 => mappingClear(self, destination, receiver, extra, line, column),
        127 => mappingUpdate(Runtime, self, destination, receiver, args[0], extra, line, column),
        128 => mappingCopy(Runtime, self, destination, receiver, extra, line, column),
        else => self.engineFault(),
    };
}

fn constructCounter(comptime Runtime: type, self: *Runtime, destination: u16, source: Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    const object = createMappingObject(Runtime, self, .counter, "Counter", Value.noneValue(), line, column) orelse return false;
    var root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    if (source.tag() == .none) {
        if (!applyKeywords(Runtime, self, stateFromObject(object).?, keywords, false, line, column)) return false;
        self.setRegister(destination, Value.object(&object.header));
        return true;
    }
    if (mappingFromValue(source)) |mapping| {
        if (!applyMapping(Runtime, self, stateFromObject(object).?, mapping, false, line, column)) return false;
        if (!applyKeywords(Runtime, self, stateFromObject(object).?, keywords, false, line, column)) return false;
        self.setRegister(destination, Value.object(&object.header));
        return true;
    }
    return startCounterTask(Runtime, self, destination, object, source, keywords, .construct, line, column);
}

fn constructDefaultdict(comptime Runtime: type, self: *Runtime, destination: u16, factory: Value, source: Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (factory.tag() != .none and !self.isCallable(factory)) return self.nativeTypeError(line, column, "first argument must be callable or None");
    const object = createMappingObject(Runtime, self, .defaultdict, "defaultdict", factory, line, column) orelse return false;
    var object_root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&object_root);
    defer roots.pop();
    const state = stateFromObject(object).?;
    if (source.tag() != .none and !self.updateDictFromValue(state.mapping, source, line, column)) return false;
    for (keywords) |keyword| {
        const key = self.createStringValue(keyword.name, line, column) orelse return false;
        if (!self.setMappingValue(state.mapping, key, keyword.value, line, column)) return false;
    }
    self.setRegister(destination, Value.object(&object.header));
    return true;
}

fn createMappingObject(comptime Runtime: type, self: *Runtime, type_id: types.TypeId, class_name: []const u8, factory: Value, line: u32, column: u32) ?*types.NativeObject {
    const class = self.ensureNativeClassWithBase(type_id, class_name, .dict_type, line, column) orelse return null;
    const object = types.createObject(&self.heap, class, type_id) catch {
        _ = memoryFailure(self, line, column);
        return null;
    };
    var object_root = gc.Root{ .object = &object.header };
    var factory_root = gc.Root{ .object = factory.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&object_root);
    roots.add(&factory_root);
    defer roots.pop();
    const mapping = switch (dict_module.create(&self.heap, false)) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return null;
        },
        .engine_error => {
            _ = self.engineFault();
            return null;
        },
    };
    var mapping_root = gc.Root{ .object = &mapping.header };
    roots.add(&mapping_root);
    const state = self.heap.allocator.create(MappingState) catch {
        _ = memoryFailure(self, line, column);
        return null;
    };
    state.* = .{ .mapping = mapping, .factory = factory };
    object.payload = state;
    object.trace_payload = traceMapping;
    object.destroy_payload = destroyMapping;
    object.ops = mappingOps(Runtime);
    return object;
}

pub fn createEmptyClone(comptime Runtime: type, self: *Runtime, source: *types.NativeObject, line: u32, column: u32) ?*types.NativeObject {
    const state = stateFromObject(source) orelse return null;
    return switch (source.type_id) {
        .counter => createMappingObject(Runtime, self, .counter, "Counter", Value.noneValue(), line, column),
        .defaultdict => createMappingObject(Runtime, self, .defaultdict, "defaultdict", state.factory, line, column),
        else => null,
    };
}

fn counterUpdate(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, source: Value, extra: []const binder.Keyword, subtract: bool, line: u32, column: u32) bool {
    const object = objectFromValue(receiver, .counter) orelse return self.engineFault();
    const state = stateFromObject(object).?;
    if (source.tag() == .none) {
        if (!applyKeywords(Runtime, self, state, extra, subtract, line, column)) return false;
        self.setRegister(destination, Value.noneValue());
        return true;
    }
    if (mappingFromValue(source)) |mapping| {
        if (!applyMapping(Runtime, self, state, mapping, subtract, line, column)) return false;
        if (!applyKeywords(Runtime, self, state, extra, subtract, line, column)) return false;
        self.setRegister(destination, Value.noneValue());
        return true;
    }
    return startCounterTask(Runtime, self, destination, object, source, extra, if (subtract) .subtract else .update, line, column);
}

fn startCounterTask(comptime Runtime: type, self: *Runtime, destination: u16, object: *types.NativeObject, source: Value, keywords: []const binder.Keyword, operation: CounterTaskOperation, line: u32, column: u32) bool {
    const source_iterator = switch (self.createVmIterator(source, line, column)) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var roots_array = [_]gc.Root{ .{ .object = &object.header }, .{ .object = &source_iterator.header } };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const payload = self.heap.allocator.create(CounterTaskPayload) catch return memoryFailure(self, line, column);
    payload.* = .{ .allocator = self.heap.allocator, .operation = operation };
    var owns_payload = true;
    defer if (owns_payload) destroyCounterTask(payload, self.heap.allocator);
    if (keywords.len != 0) {
        payload.keywords = self.heap.allocator.alloc(binder.Keyword, keywords.len) catch return memoryFailure(self, line, column);
        for (keywords, 0..) |keyword, index| {
            const name = self.heap.allocator.dupe(u8, keyword.name) catch return memoryFailure(self, line, column);
            payload.keywords[index] = .{ .name = name, .value = keyword.value };
            payload.keyword_count += 1;
        }
    }
    const caller = self.top_frame orelse return self.engineFault();
    const task = types.createTask(&self.heap, self.currentNativeTask(), .collections, @intFromEnum(operation), @ptrCast(caller), destination, line, column, &.{ Value.object(&object.header), Value.object(&source_iterator.header) }, counterTaskOps(Runtime)) catch return memoryFailure(self, line, column);
    task.payload = payload;
    owns_payload = false;
    return self.startNativeTask(task);
}

fn counterTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return counterTaskStep(Runtime, self, task);
        }
        const ops = types.TaskOps{ .step = step, .trace_payload = traceCounterTask, .destroy_payload = destroyCounterTask };
    }.ops;
}

fn counterTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload: *CounterTaskPayload = @ptrCast(@alignCast(task.payload orelse return runtimeTaskError("invalid Counter task")));
    const object = objectFromValue(task.inputs[0], .counter) orelse return runtimeTaskError("invalid Counter receiver");
    const state = stateFromObject(object).?;
    if (task.child_ready) {
        if (task.child_error != null) return .propagate;
        if (task.child_done) {
            if (!applyKeywords(Runtime, self, state, payload.keywords, payload.operation == .subtract, task.line, task.column)) return currentExceptionTask(self);
            return .{ .complete = if (payload.operation == .construct) task.inputs[0] else Value.noneValue() };
        }
        const delta = Value.fromSmallInt(if (payload.operation == .subtract) -1 else 1).?;
        if (!addCount(Runtime, self, state, task.child_value, delta, task.line, task.column)) return currentExceptionTask(self);
        task.child_ready = false;
        task.child_value = Value.noneValue();
    }
    return .{ .next = task.inputs[1] };
}

fn applyMapping(comptime Runtime: type, self: *Runtime, state: *MappingState, source: *dict_module.Dict, subtract: bool, line: u32, column: u32) bool {
    for (source.entries.items) |entry| {
        if (!entry.alive) continue;
        const delta = if (subtract) switch (number.negative(&self.heap, entry.value)) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        } else entry.value;
        if (!addCount(Runtime, self, state, entry.key, delta, line, column)) return false;
    }
    return true;
}

fn applyKeywords(comptime Runtime: type, self: *Runtime, state: *MappingState, keywords: []const binder.Keyword, subtract: bool, line: u32, column: u32) bool {
    for (keywords) |keyword| {
        const key = self.createStringValue(keyword.name, line, column) orelse return false;
        const delta = if (subtract) switch (number.negative(&self.heap, keyword.value)) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        } else keyword.value;
        if (!addCount(Runtime, self, state, key, delta, line, column)) return false;
    }
    return true;
}

fn addCount(comptime Runtime: type, self: *Runtime, state: *MappingState, key: Value, delta: Value, line: u32, column: u32) bool {
    const key_hash = self.pythonHash(key, line, column) orelse return false;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    const current = switch (dict_module.get(state.mapping, key, key_hash, &context, equalityThunk(Runtime))) {
        .value => |value| value,
        .missing => Value.fromSmallInt(0).?,
        .failed => return false,
    };
    const updated = switch (number.add(&self.heap, current, delta)) {
        .value => |value| value,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    return self.setMappingValueWithHash(state.mapping, key, updated, key_hash, line, column);
}

fn counterElements(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    const list = createList(self, line, column) orelse return false;
    var list_root = gc.Root{ .object = &list.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&list_root);
    defer roots.pop();
    for (state.mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const count = number.toInt(i64, entry.value) orelse return self.nativeTypeError(line, column, "Counter elements counts must be integers");
        if (count <= 0) continue;
        for (0..@intCast(count)) |_| switch (sequence.append(&self.heap, list, entry.key)) {
            .value => {},
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
    }
    return storeListIterator(self, destination, list, line, column);
}

fn counterMostCommon(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, limit_value: Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    const amount_limit: usize = if (limit_value.tag() == .none) state.mapping.size else blk: {
        const selected = number.toInt(i64, limit_value) orelse return self.nativeTypeError(line, column, "n must be an integer or None");
        break :blk if (selected <= 0) 0 else std.math.cast(usize, selected) orelse state.mapping.size;
    };
    var entries: std.ArrayList(dict_module.Entry) = .empty;
    defer entries.deinit(self.heap.allocator);
    for (state.mapping.entries.items) |entry| if (entry.alive) entries.append(self.heap.allocator, entry) catch return memoryFailure(self, line, column);
    var index: usize = 1;
    while (index < entries.items.len) : (index += 1) {
        var cursor = index;
        while (cursor != 0) {
            const order = switch (number.compare(entries.items[cursor].value, entries.items[cursor - 1].value)) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            if (order != .greater) break;
            std.mem.swap(dict_module.Entry, &entries.items[cursor], &entries.items[cursor - 1]);
            cursor -= 1;
        }
    }
    const list = createList(self, line, column) orelse return false;
    var list_root = gc.Root{ .object = &list.header };
    var item_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&list_root);
    roots.add(&item_root);
    defer roots.pop();
    const amount = @min(entries.items.len, amount_limit);
    for (entries.items[0..amount]) |entry| {
        const tuple = switch (sequence.createTuple(&self.heap, &.{ entry.key, entry.value })) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        item_root.object = &tuple.header;
        switch (sequence.append(&self.heap, list, Value.object(&tuple.header))) {
            .value => {},
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        }
    }
    self.setRegister(destination, Value.object(&list.header));
    return true;
}

fn counterTotal(self: anytype, destination: u16, receiver: Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    var total = Value.fromSmallInt(0).?;
    var root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    for (state.mapping.entries.items) |entry| if (entry.alive) {
        total = switch (number.add(&self.heap, total, entry.value)) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        root.object = total.asObject();
    };
    self.setRegister(destination, total);
    return true;
}

fn counterCopy(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const source = stateFromValue(receiver) orelse return self.engineFault();
    const object = createMappingObject(Runtime, self, .counter, "Counter", Value.noneValue(), line, column) orelse return false;
    var object_root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&object_root);
    defer roots.pop();
    const target = stateFromObject(object).?;
    if (!applyMapping(Runtime, self, target, source.mapping, false, line, column)) return false;
    self.setRegister(destination, Value.object(&object.header));
    return true;
}

fn mappingGet(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, args: []const Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    const key_hash = self.pythonHash(args[0], line, column) orelse return false;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    const value = switch (dict_module.get(state.mapping, args[0], key_hash, &context, equalityThunk(Runtime))) {
        .value => |found| found,
        .missing => args[1],
        .failed => return self.last_exception == null and self.engineFault(),
    };
    self.setRegister(destination, value);
    return true;
}

fn mappingView(self: anytype, destination: u16, receiver: Value, extra: []const binder.Keyword, function_id: u16, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    const kind: dict_module.ViewKind = if (function_id == 121) .keys else if (function_id == 122) .values else .items;
    return switch (dict_module.createView(&self.heap, state.mapping, kind)) {
        .value => |view| blk: {
            self.setRegister(destination, Value.object(&view.header));
            break :blk true;
        },
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk false;
        },
        .engine_error => self.engineFault(),
    };
}

fn mappingPop(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, args: []const Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    const hash = self.pythonHash(args[0], line, column) orelse return false;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    return switch (dict_module.delete(state.mapping, args[0], hash, &context, equalityThunk(Runtime))) {
        .found => |index| blk: {
            self.setRegister(destination, state.mapping.entries.items[index].value);
            break :blk true;
        },
        .missing => blk: {
            self.setRegister(destination, args[1]);
            break :blk true;
        },
        .failed => self.last_exception == null and self.engineFault(),
    };
}

fn mappingSetDefault(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, args: []const Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    const hash = self.pythonHash(args[0], line, column) orelse return false;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    const result = switch (dict_module.get(state.mapping, args[0], hash, &context, equalityThunk(Runtime))) {
        .value => |value| value,
        .missing => blk: {
            if (!self.setMappingValueWithHash(state.mapping, args[0], args[1], hash, line, column)) return false;
            break :blk args[1];
        },
        .failed => return false,
    };
    self.setRegister(destination, result);
    return true;
}

fn mappingClear(self: anytype, destination: u16, receiver: Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const state = stateFromValue(receiver) orelse return self.engineFault();
    dict_module.clear(&self.heap, state.mapping);
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn mappingUpdate(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, source: Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    const state = stateFromValue(receiver) orelse return self.engineFault();
    if (source.tag() != .none) {
        if (mappingFromValue(source)) |mapping| {
            for (mapping.entries.items) |entry| if (entry.alive and !self.setMappingValue(state.mapping, entry.key, entry.value, line, column)) return false;
        } else if (!self.updateDictFromValue(state.mapping, source, line, column)) return false;
    }
    for (extra) |keyword| {
        const key = self.createStringValue(keyword.name, line, column) orelse return false;
        if (!self.setMappingValue(state.mapping, key, keyword.value, line, column)) return false;
    }
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn mappingCopy(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, extra: []const binder.Keyword, line: u32, column: u32) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const source_object = types.fromHeader(receiver.asObject() orelse return self.engineFault()) orelse return self.engineFault();
    const source = stateFromObject(source_object) orelse return self.engineFault();
    const clone = createEmptyClone(Runtime, self, source_object, line, column) orelse return false;
    var clone_root = gc.Root{ .object = &clone.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&clone_root);
    defer roots.pop();
    const target = stateFromObject(clone).?;
    for (source.mapping.entries.items) |entry| if (entry.alive and !self.setMappingValueWithHash(target.mapping, entry.key, entry.value, entry.hash, line, column)) return false;
    self.setRegister(destination, Value.object(&clone.header));
    return true;
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    const state = stateFromObject(object) orelse return null;
    if (object.type_id == .defaultdict and std.mem.eql(u8, name, "default_factory")) return state.factory;
    const id: ?u16 = if (std.mem.eql(u8, name, "get")) 120 else if (std.mem.eql(u8, name, "keys")) 121 else if (std.mem.eql(u8, name, "values")) 122 else if (std.mem.eql(u8, name, "items")) 123 else if (std.mem.eql(u8, name, "pop")) 124 else if (std.mem.eql(u8, name, "setdefault")) 125 else if (std.mem.eql(u8, name, "clear")) 126 else if (object.type_id == .defaultdict and std.mem.eql(u8, name, "update")) 127 else if (object.type_id == .defaultdict and std.mem.eql(u8, name, "copy")) 128 else if (object.type_id == .counter and std.mem.eql(u8, name, "update")) 101 else if (object.type_id == .counter and std.mem.eql(u8, name, "subtract")) 102 else if (object.type_id == .counter and std.mem.eql(u8, name, "elements")) 103 else if (object.type_id == .counter and std.mem.eql(u8, name, "most_common")) 104 else if (object.type_id == .counter and std.mem.eql(u8, name, "total")) 105 else if (object.type_id == .counter and std.mem.eql(u8, name, "copy")) 106 else null;
    return if (id) |method_id| boundMethod(self, method_id, Value.object(&object.header), line, column) else null;
}

pub fn setAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, value: Value, line: u32, column: u32) bool {
    const state = stateFromObject(object) orelse return self.engineFault();
    if (object.type_id != .defaultdict or !std.mem.eql(u8, name, "default_factory")) return self.nativeAttributeError(line, column, "native attribute is read-only");
    if (value.tag() != .none and !self.isCallable(value)) return self.nativeTypeError(line, column, "default_factory must be callable or None");
    state.factory = value;
    return true;
}

fn mappingOps(comptime Runtime: type) *const types.NativeObjectOps {
    return &struct {
        fn truth(_: *anyopaque, object: *types.NativeObject, _: u32, _: u32) ?bool {
            const state = stateFromObject(object) orelse return null;
            return state.mapping.size != 0;
        }
        fn representation(context: *anyopaque, object: *types.NativeObject, line: u32, column: u32) ?[]u8 {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return null;
            const rendered = self.renderValueOwned(Value.object(&state.mapping.header), true, line, column) orelse return null;
            defer self.heap.allocator.free(rendered);
            return if (object.type_id == .counter)
                std.fmt.allocPrint(self.heap.allocator, "Counter({s})", .{rendered}) catch {
                    return representationFailure(self, line, column);
                }
            else
                std.fmt.allocPrint(self.heap.allocator, "defaultdict(..., {s})", .{rendered}) catch {
                    return representationFailure(self, line, column);
                };
        }
        fn equals(context: *anyopaque, object: *types.NativeObject, other: Value, line: u32, column: u32) ?bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const right_object = types.fromHeader(other.asObject() orelse return false) orelse return false;
            const right = stateFromObject(right_object) orelse return false;
            const left = stateFromObject(object) orelse return null;
            if (object.type_id == .counter and right_object.type_id == .counter) return counterCompare(Runtime, self, left, right, 0, line, column);
            return mappingsEqual(Runtime, self, left.mapping, right.mapping, line, column);
        }
        fn compare(context: *anyopaque, object: *types.NativeObject, other: Value, operation: u8, line: u32, column: u32) ?bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const right_object = types.fromHeader(other.asObject() orelse return null) orelse return null;
            const left = stateFromObject(object) orelse return null;
            const right = stateFromObject(right_object) orelse return null;
            if (object.type_id != .counter or right_object.type_id != .counter) {
                if (operation == 0 or operation == 1) {
                    const equal = mappingsEqual(Runtime, self, left.mapping, right.mapping, line, column) orelse return null;
                    return if (operation == 0) equal else !equal;
                }
                return null;
            }
            return counterCompare(Runtime, self, left, right, operation, line, column);
        }
        fn binary(context: *anyopaque, object: *types.NativeObject, other: Value, operation: u8, reflected: bool, line: u32, column: u32) ?Value {
            if (object.type_id != .counter or (operation != 0 and operation != 1 and operation != 7 and operation != 8)) return null;
            const self: *Runtime = @ptrCast(@alignCast(context));
            const other_object = types.fromHeader(other.asObject() orelse return null) orelse return null;
            if (other_object.type_id != .counter) return null;
            const object_state = stateFromObject(object) orelse return null;
            const other_state = stateFromObject(other_object) orelse return null;
            return counterBinary(Runtime, self, if (reflected) other_state else object_state, if (reflected) object_state else other_state, operation, line, column);
        }
        fn unary(context: *anyopaque, object: *types.NativeObject, operation: u8, line: u32, column: u32) ?Value {
            if (object.type_id != .counter or (operation != 0 and operation != 1)) return null;
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return null;
            return counterUnary(Runtime, self, state, operation == 1, line, column);
        }
        fn getItem(context: *anyopaque, object: *types.NativeObject, key: Value, destination: u16, line: u32, column: u32) ?Value {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return mappingGetItem(Runtime, self, object, key, destination, line, column);
        }
        fn setItem(context: *anyopaque, object: *types.NativeObject, key: Value, value: Value, line: u32, column: u32) bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return self.engineFault();
            return self.setMappingValue(state.mapping, key, value, line, column);
        }
        fn deleteItem(context: *anyopaque, object: *types.NativeObject, key: Value, line: u32, column: u32) bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return self.engineFault();
            const key_hash = self.pythonHash(key, line, column) orelse return false;
            var equality = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
            return switch (dict_module.delete(state.mapping, key, key_hash, &equality, equalityThunk(Runtime))) {
                .found => true,
                .missing => blk: {
                    self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
                    break :blk false;
                },
                .failed => false,
            };
        }
        fn contains(context: *anyopaque, object: *types.NativeObject, key: Value, line: u32, column: u32) ?bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return null;
            const key_hash = self.pythonHash(key, line, column) orelse return null;
            var equality = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
            return switch (dict_module.lookup(state.mapping, key, key_hash, &equality, equalityThunk(Runtime))) {
                .found => true,
                .missing => false,
                .failed => null,
            };
        }
        fn iterate(context: *anyopaque, object: *types.NativeObject, line: u32, column: u32) ?Value {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return null;
            return switch (self.createVmIterator(Value.object(&state.mapping.header), line, column)) {
                .value => |iterator| Value.object(&iterator.header),
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
        fn mapping(object: *types.NativeObject) ?*dict_module.Dict {
            const state = stateFromObject(object) orelse return null;
            return state.mapping;
        }
        const ops = types.NativeObjectOps{
            .get_item = getItem, .set_item = setItem, .delete_item = deleteItem, .contains = contains, .iter = iterate,
            .mapping = mapping,
            .truth = truth, .repr = representation, .hashable = false, .equals = equals, .compare = compare, .binary = binary, .unary = unary,
        };
    }.ops;
}

fn counterCompare(comptime Runtime: type, self: *Runtime, left: *MappingState, right: *MappingState, operation: u8, line: u32, column: u32) ?bool {
    var left_le_right = true;
    var right_le_left = true;
    for (left.mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const other = countValue(Runtime, self, right.mapping, entry.key, line, column) orelse return null;
        const order = numericOrder(self, entry.value, other, line, column) orelse return null;
        if (order == .greater) left_le_right = false;
        if (order == .less) right_le_left = false;
    }
    for (right.mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const other = countValue(Runtime, self, left.mapping, entry.key, line, column) orelse return null;
        const order = numericOrder(self, other, entry.value, line, column) orelse return null;
        if (order == .greater) left_le_right = false;
        if (order == .less) right_le_left = false;
    }
    const equal = left_le_right and right_le_left;
    return switch (operation) {
        0 => equal,
        1 => !equal,
        2 => left_le_right and !equal,
        3 => left_le_right,
        4 => right_le_left and !equal,
        5 => right_le_left,
        else => null,
    };
}

fn mappingsEqual(comptime Runtime: type, self: *Runtime, left: *dict_module.Dict, right: *dict_module.Dict, line: u32, column: u32) ?bool {
    if (left.size != right.size) return false;
    for (left.entries.items) |entry| {
        if (!entry.alive) continue;
        const hash = self.pythonHash(entry.key, line, column) orelse return null;
        var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
        const other = switch (dict_module.get(right, entry.key, hash, &context, equalityThunk(Runtime))) {
            .value => |value| value,
            .missing => return false,
            .failed => return null,
        };
        if (!(self.valuesEqual(entry.value, other, line, column) orelse return null)) return false;
    }
    return true;
}

fn counterBinary(comptime Runtime: type, self: *Runtime, left: *MappingState, right: *MappingState, operation: u8, line: u32, column: u32) ?Value {
    const result_object = createMappingObject(Runtime, self, .counter, "Counter", Value.noneValue(), line, column) orelse return null;
    var result_root = gc.Root{ .object = &result_object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&result_root);
    defer roots.pop();
    const result = stateFromObject(result_object).?;
    for (left.mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const right_value = countValue(Runtime, self, right.mapping, entry.key, line, column) orelse return null;
        const combined = combineCounts(self, entry.value, right_value, operation, line, column) orelse return null;
        if (!storePositive(Runtime, self, result, entry.key, combined, line, column)) return null;
    }
    for (right.mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const exists = mappingContainsKey(Runtime, self, left.mapping, entry.key, line, column) orelse return null;
        if (exists) continue;
        const combined = combineCounts(self, Value.fromSmallInt(0).?, entry.value, operation, line, column) orelse return null;
        if (!storePositive(Runtime, self, result, entry.key, combined, line, column)) return null;
    }
    return Value.object(&result_object.header);
}

fn counterUnary(comptime Runtime: type, self: *Runtime, source: *MappingState, negative: bool, line: u32, column: u32) ?Value {
    const result_object = createMappingObject(Runtime, self, .counter, "Counter", Value.noneValue(), line, column) orelse return null;
    var result_root = gc.Root{ .object = &result_object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&result_root);
    defer roots.pop();
    const result = stateFromObject(result_object).?;
    for (source.mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const count = if (negative) blk: {
            break :blk switch (number.negative(&self.heap, entry.value)) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
                .engine_error => {
                    _ = self.engineFault();
                    return null;
                },
            };
        } else entry.value;
        if (!storePositive(Runtime, self, result, entry.key, count, line, column)) return null;
    }
    return Value.object(&result_object.header);
}

fn combineCounts(self: anytype, left: Value, right: Value, operation: u8, line: u32, column: u32) ?Value {
    if (operation == 0 or operation == 1) return switch (if (operation == 0) number.add(&self.heap, left, right) else number.subtract(&self.heap, left, right)) {
        .value => |value| value,
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk null; },
        .engine_error => blk: { _ = self.engineFault(); break :blk null; },
    };
    const order = numericOrder(self, left, right, line, column) orelse return null;
    return if (operation == 7) (if (order == .greater) right else left) else (if (order == .less) right else left);
}

fn storePositive(comptime Runtime: type, self: *Runtime, state: *MappingState, key: Value, count: Value, line: u32, column: u32) bool {
    const order = numericOrder(self, count, Value.fromSmallInt(0).?, line, column) orelse return false;
    if (order != .greater) return true;
    const hash = self.pythonHash(key, line, column) orelse return false;
    return self.setMappingValueWithHash(state.mapping, key, count, hash, line, column);
}

fn countValue(comptime Runtime: type, self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) ?Value {
    const hash = self.pythonHash(key, line, column) orelse return null;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    return switch (dict_module.get(mapping, key, hash, &context, equalityThunk(Runtime))) {
        .value => |value| value,
        .missing => Value.fromSmallInt(0).?,
        .failed => null,
    };
}

fn mappingContainsKey(comptime Runtime: type, self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) ?bool {
    const hash = self.pythonHash(key, line, column) orelse return null;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    return switch (dict_module.lookup(mapping, key, hash, &context, equalityThunk(Runtime))) { .found => true, .missing => false, .failed => null };
}

fn numericOrder(self: anytype, left: Value, right: Value, line: u32, column: u32) ?number.Comparison {
    return switch (number.compare(left, right)) {
        .value => |order| order,
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk null; },
        .engine_error => blk: { _ = self.engineFault(); break :blk null; },
    };
}

fn representationFailure(self: anytype, line: u32, column: u32) ?[]u8 {
    _ = memoryFailure(self, line, column);
    return null;
}

fn mappingGetItem(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, key: Value, destination: u16, line: u32, column: u32) ?Value {
    const state = stateFromObject(object) orelse return null;
    const key_hash = self.pythonHash(key, line, column) orelse return null;
    var context = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
    switch (dict_module.get(state.mapping, key, key_hash, &context, equalityThunk(Runtime))) {
        .value => |value| return value,
        .failed => return null,
        .missing => {},
    }
    if (object.type_id == .counter) return Value.fromSmallInt(0).?;
    if (state.factory.tag() == .none) {
        self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
        return null;
    }
    const caller = self.top_frame orelse {
        _ = self.engineFault();
        return null;
    };
    const task = types.createTask(&self.heap, self.currentNativeTask(), .collections, 200, @ptrCast(caller), destination, line, column, &.{ Value.object(&object.header), key, state.factory }, defaultTaskOps(Runtime)) catch {
        _ = memoryFailure(self, line, column);
        return null;
    };
    if (!self.startNativeTask(task)) return null;
    return null;
}

fn defaultTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            if (!task.child_ready) return .{ .call = .{ .callable = task.inputs[2], .positional = &.{} } };
            if (task.child_error != null) return .propagate;
            const object = objectFromValue(task.inputs[0], .defaultdict) orelse return runtimeTaskError("invalid defaultdict receiver");
            const state = stateFromObject(object).?;
            if (!self.setMappingValue(state.mapping, task.inputs[1], task.child_value, task.line, task.column)) return currentExceptionTask(self);
            return .{ .complete = task.child_value };
        }
        const ops = types.TaskOps{ .step = step };
    }.ops;
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

fn createList(self: anytype, line: u32, column: u32) ?*sequence.List {
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

fn storeListIterator(self: anytype, destination: u16, list: *sequence.List, line: u32, column: u32) bool {
    return switch (self.createVmIterator(Value.object(&list.header), line, column)) {
        .value => |iterator| blk: {
            self.setRegister(destination, Value.object(&iterator.header));
            break :blk true;
        },
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk false;
        },
        .engine_error => self.engineFault(),
    };
}

fn boundMethod(self: anytype, id: u16, receiver: Value, line: u32, column: u32) ?Value {
    return switch (functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.collections), id, receiver)) {
        .value => |function| Value.object(&function.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
    };
}

fn mappingFromValue(value: Value) ?*dict_module.Dict {
    const header = value.asObject() orelse return null;
    if (dict_module.dictFromHeader(header)) |mapping| return mapping;
    const object = types.fromHeader(header) orelse return null;
    const ops = object.ops orelse return null;
    const mapping = ops.mapping orelse return null;
    return mapping(object);
}

fn objectFromValue(value: Value, expected: types.TypeId) ?*types.NativeObject {
    const object = types.fromHeader(value.asObject() orelse return null) orelse return null;
    return if (object.type_id == expected) object else null;
}

fn stateFromValue(value: Value) ?*MappingState {
    const object = types.fromHeader(value.asObject() orelse return null) orelse return null;
    return stateFromObject(object);
}

fn stateFromObject(object: *types.NativeObject) ?*MappingState {
    if (object.type_id != .counter and object.type_id != .defaultdict) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn traceMapping(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const state: *MappingState = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(&state.mapping.header);
    tracer.visit(state.factory.asObject());
}

fn destroyMapping(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *MappingState = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(state);
}

fn traceCounterTask(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *CounterTaskPayload = @ptrCast(@alignCast(raw orelse return));
    for (payload.keywords) |keyword| tracer.visit(keyword.value.asObject());
}

fn destroyCounterTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *CounterTaskPayload = @ptrCast(@alignCast(raw orelse return));
    for (payload.keywords[0..payload.keyword_count]) |keyword| allocator.free(keyword.name);
    if (payload.keywords.len != 0) allocator.free(payload.keywords);
    allocator.destroy(payload);
}

fn currentExceptionTask(self: anytype) types.TaskStep {
    return .{ .raise = self.last_exception orelse .{ .kind = .runtime_error, .message = "collection operation failed" } };
}

fn runtimeTaskError(message: []const u8) types.TaskStep {
    return .{ .raise = .{ .kind = .runtime_error, .message = message } };
}

fn memoryFailure(self: anytype, line: u32, column: u32) bool {
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}
