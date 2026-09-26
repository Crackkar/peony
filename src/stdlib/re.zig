const std = @import("std");
const binder = @import("runtime_binder");
const byte_module = @import("runtime_bytes");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const sequence = @import("runtime_sequence");
const unicode = @import("runtime_unicode");
const regex_core = @import("regex_core");
const types = @import("types.zig");

const parser = regex_core.parser;
const regex_vm = regex_core.vm;
const regex_objects = regex_core.objects;

const Value = types.Value;
const end_sentinel: i64 = 140_737_488_355_327;
const PatternBytes = struct { bytes: []const u8, mode: parser.Mode };

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "compile", .params = &.{ .{ .name = "pattern" }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 2, .name = "search", .params = &.{ .{ .name = "pattern" }, .{ .name = "string" }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 3, .name = "match", .params = &.{ .{ .name = "pattern" }, .{ .name = "string" }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 4, .name = "fullmatch", .params = &.{ .{ .name = "pattern" }, .{ .name = "string" }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 5, .name = "findall", .params = &.{ .{ .name = "pattern" }, .{ .name = "string" }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 6, .name = "finditer", .params = &.{ .{ .name = "pattern" }, .{ .name = "string" }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 7, .name = "split", .params = &.{ .{ .name = "pattern" }, .{ .name = "string" }, .{ .name = "maxsplit", .default = .{ .integer = 0 } }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 8, .name = "sub", .params = &.{ .{ .name = "pattern" }, .{ .name = "repl" }, .{ .name = "string" }, .{ .name = "count", .default = .{ .integer = 0 } }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 9, .name = "subn", .params = &.{ .{ .name = "pattern" }, .{ .name = "repl" }, .{ .name = "string" }, .{ .name = "count", .default = .{ .integer = 0 } }, .{ .name = "flags", .default = .{ .integer = 0 } } } },
    .{ .id = 10, .name = "escape", .params = &.{.{ .name = "pattern" }} },

    .{ .id = 101, .name = "match", .params = match_method_params, .exported = false },
    .{ .id = 102, .name = "search", .params = match_method_params, .exported = false },
    .{ .id = 103, .name = "fullmatch", .params = match_method_params, .exported = false },
    .{ .id = 104, .name = "findall", .params = match_method_params, .exported = false },
    .{ .id = 105, .name = "finditer", .params = match_method_params, .exported = false },
    .{ .id = 106, .name = "split", .params = &.{ .{ .name = "string" }, .{ .name = "maxsplit", .default = .{ .integer = 0 } } }, .exported = false },
    .{ .id = 107, .name = "sub", .params = &.{ .{ .name = "repl" }, .{ .name = "string" }, .{ .name = "count", .default = .{ .integer = 0 } } }, .exported = false },
    .{ .id = 108, .name = "subn", .params = &.{ .{ .name = "repl" }, .{ .name = "string" }, .{ .name = "count", .default = .{ .integer = 0 } } }, .exported = false },

    .{ .id = 201, .name = "group", .params = &.{.{ .name = "groups", .flags = binder.parameter_flags_module.var_positional }}, .exported = false },
    .{ .id = 202, .name = "groups", .params = &.{.{ .name = "default", .flags = binder.parameter_flags_module.positional_only, .default = .none }}, .exported = false },
    .{ .id = 203, .name = "groupdict", .params = &.{.{ .name = "default", .flags = binder.parameter_flags_module.positional_only, .default = .none }}, .exported = false },
    .{ .id = 204, .name = "start", .params = &.{.{ .name = "group", .flags = binder.parameter_flags_module.positional_only, .default = .{ .integer = 0 } }}, .exported = false },
    .{ .id = 205, .name = "end", .params = &.{.{ .name = "group", .flags = binder.parameter_flags_module.positional_only, .default = .{ .integer = 0 } }}, .exported = false },
    .{ .id = 206, .name = "span", .params = &.{.{ .name = "group", .flags = binder.parameter_flags_module.positional_only, .default = .{ .integer = 0 } }}, .exported = false },
};

const match_method_params = &[_]types.Param{
    .{ .name = "string" },
    .{ .name = "pos", .default = .{ .integer = 0 } },
    .{ .name = "endpos", .default = .{ .integer = end_sentinel } },
};

pub const classes = [_]types.TypeSpec{
    .{ .type_id = .regex_pattern, .module = .re, .name = "Pattern" },
    .{ .type_id = .regex_match, .module = .re, .name = "Match" },
    .{ .type_id = .regex_find_iterator, .module = .re, .name = "callable_iterator", .exported = false },
};

const PatternState = struct {
    pattern: regex_objects.Pattern,
};

const MatchState = struct {
    allocator: std.mem.Allocator,
    result: regex_vm.Match,
    byte_captures: []i64,
    pattern: Value,
    subject: Value,
    pos: usize,
    endpos: usize,
};

const MatchOperation = enum(u16) { search = 1, match = 2, fullmatch = 3 };
const MatchTaskPayload = struct {
    allocator: std.mem.Allocator,
    operation: MatchOperation,
    pos: usize,
    endpos: usize,
    engine: ?regex_vm.Engine = null,
};

const FindAllTaskPayload = struct {
    allocator: std.mem.Allocator,
    next_position: usize,
    endpos: usize,
    suppress_empty_at: ?usize = null,
    decoded: ?regex_vm.DecodedSubject = null,
    engine: ?regex_vm.Engine = null,
};

const FindIteratorState = struct {
    allocator: std.mem.Allocator,
    pattern: Value,
    subject: Value,
    pos: usize,
    endpos: usize,
    next_position: usize,
    suppress_empty_at: ?usize = null,
    decoded: ?regex_vm.DecodedSubject = null,
    engine: ?regex_vm.Engine = null,
    finished: bool = false,
};

const SplitTaskPayload = struct {
    allocator: std.mem.Allocator,
    next_position: usize = 0,
    last_end: usize = 0,
    endpos: usize,
    suppress_empty_at: ?usize = null,
    maxsplit: i64,
    split_count: i64 = 0,
    decoded: ?regex_vm.DecodedSubject = null,
    engine: ?regex_vm.Engine = null,
};

const SubPhase = enum { scan, callback };
const SubTaskPayload = struct {
    allocator: std.mem.Allocator,
    phase: SubPhase = .scan,
    next_position: usize = 0,
    last_end: usize = 0,
    endpos: usize,
    suppress_empty_at: ?usize = null,
    max_count: i64,
    replacement_count: i64 = 0,
    return_count: bool,
    callable: bool,
    template: ?regex_objects.Template = null,
    output: std.ArrayList(u8) = .empty,
    decoded: ?regex_vm.DecodedSubject = null,
    engine: ?regex_vm.Engine = null,
    pending_match: Value = Value.noneValue(),
    pending_start: usize = 0,
    pending_end: usize = 0,
    callback_args: [1]Value = .{Value.noneValue()},
};

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const error_class = switch (exceptions.createNativeClass(&self.heap, "error", .value_error, null)) {
        .value => |class| class,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    if (!storeValue(Runtime, self, environment, "error", Value.object(&error_class.header), line, column)) return false;
    const pattern_class = self.ensureNativeClass(.regex_pattern, "Pattern", line, column) orelse return false;
    if (!storeValue(Runtime, self, environment, "Pattern", Value.object(&pattern_class.header), line, column)) return false;
    const match_class = self.ensureNativeClass(.regex_match, "Match", line, column) orelse return false;
    if (!storeValue(Runtime, self, environment, "Match", Value.object(&match_class.header), line, column)) return false;
    const constants = [_]struct { name: []const u8, value: i64 }{
        .{ .name = "ASCII", .value = parser.flag_ascii },
        .{ .name = "A", .value = parser.flag_ascii },
        .{ .name = "IGNORECASE", .value = parser.flag_ignore_case },
        .{ .name = "I", .value = parser.flag_ignore_case },
        .{ .name = "MULTILINE", .value = parser.flag_multiline },
        .{ .name = "M", .value = parser.flag_multiline },
        .{ .name = "DOTALL", .value = parser.flag_dot_all },
        .{ .name = "S", .value = parser.flag_dot_all },
        .{ .name = "UNICODE", .value = parser.flag_unicode },
        .{ .name = "U", .value = parser.flag_unicode },
    };
    for (constants) |constant| {
        if (!storeValue(Runtime, self, environment, constant.name, Value.fromSmallInt(constant.value).?, line, column)) return false;
    }
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
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    return switch (function_id) {
        1 => compileValue(Runtime, self, destination, args[0], args[1], line, column),
        2, 3, 4 => startModuleMatch(Runtime, self, destination, function_id, args, line, column),
        5 => startModuleFindAll(Runtime, self, destination, args, line, column),
        6 => startModuleFindIter(Runtime, self, destination, args, line, column),
        7 => startModuleSplit(Runtime, self, destination, args, line, column),
        8, 9 => startModuleSub(Runtime, self, destination, function_id, args, line, column),
        10 => escapeValue(Runtime, self, destination, args[0], line, column),
        101, 102, 103 => startPatternMatch(Runtime, self, destination, function_id, receiver, args, line, column),
        104 => startPatternFindAll(Runtime, self, destination, receiver, args, line, column),
        105 => startPatternFindIter(Runtime, self, destination, receiver, args, line, column),
        106 => startSplitTask(Runtime, self, destination, receiver, args[0], args[1], line, column),
        107, 108 => startSubTask(Runtime, self, destination, receiver, args[0], args[1], args[2], function_id == 108, line, column),
        201...206 => executeMatchMethod(Runtime, self, destination, function_id, receiver, args, line, column),
        else => self.engineFault(),
    };
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    return switch (object.type_id) {
        .regex_pattern => patternAttribute(Runtime, self, object, name, line, column),
        .regex_match => matchAttribute(Runtime, self, object, name, line, column),
        else => null,
    };
}

fn compileValue(comptime Runtime: type, self: *Runtime, destination: u16, source_value: Value, flags_value: Value, line: u32, column: u32) bool {
    const result = ensurePattern(Runtime, self, source_value, flags_value, line, column) orelse return false;
    self.setRegister(destination, result);
    return true;
}

fn ensurePattern(comptime Runtime: type, self: *Runtime, source_value: Value, flags_value: Value, line: u32, column: u32) ?Value {
    const flags = integerFlags(flags_value) orelse {
        _ = self.nativeTypeError(line, column, "flags must be an integer");
        return null;
    };
    if (nativePattern(source_value)) |existing| {
        if (flags != 0) {
            self.setException(.{ .kind = .value_error, .message = "cannot process flags argument with a compiled pattern" }, line, column, null);
            return null;
        }
        _ = existing;
        return source_value;
    }
    const selected = patternBytes(Runtime, self, source_value) orelse {
        _ = self.nativeTypeError(line, column, "first argument must be string or compiled pattern");
        return null;
    };
    const class = self.ensureNativeClass(.regex_pattern, "Pattern", line, column) orelse return null;
    const object = types.createObject(&self.heap, class, .regex_pattern) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    var root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    const state = self.heap.allocator.create(PatternState) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    var diagnostic = parser.Diagnostic{};
    state.* = .{ .pattern = regex_objects.Pattern.compile(self.heap.allocator, selected.bytes, selected.mode, flags, .{}, &diagnostic) catch |err| {
        self.heap.allocator.destroy(state);
        if (err == error.OutOfMemory) {
            self.setException(exceptions.memoryError(), line, column, null);
        } else {
            setRegexError(Runtime, self, source_value, diagnostic.message, diagnostic.position, line, column);
        }
        return null;
    } };
    object.payload = state;
    object.destroy_payload = destroyPattern;
    return Value.object(&object.header);
}

fn startModuleMatch(comptime Runtime: type, self: *Runtime, destination: u16, function_id: u16, args: []const Value, line: u32, column: u32) bool {
    const pattern_value = ensurePattern(Runtime, self, args[0], args[2], line, column) orelse return false;
    var pattern_root = gc.Root{ .object = pattern_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&pattern_root);
    defer roots.pop();
    return startMatchTask(Runtime, self, destination, operationForFunction(function_id), pattern_value, args[1], 0, end_sentinel, line, column);
}

fn startPatternMatch(comptime Runtime: type, self: *Runtime, destination: u16, function_id: u16, receiver: Value, args: []const Value, line: u32, column: u32) bool {
    const pos = integerPosition(args[1]) orelse return self.nativeTypeError(line, column, "pos must be an integer");
    const endpos = integerPosition(args[2]) orelse return self.nativeTypeError(line, column, "endpos must be an integer");
    return startMatchTask(Runtime, self, destination, operationForFunction(function_id), receiver, args[0], pos, endpos, line, column);
}

fn startModuleFindAll(comptime Runtime: type, self: *Runtime, destination: u16, args: []const Value, line: u32, column: u32) bool {
    const pattern_value = ensurePattern(Runtime, self, args[0], args[2], line, column) orelse return false;
    var pattern_root = gc.Root{ .object = pattern_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&pattern_root);
    defer roots.pop();
    return startFindAllTask(Runtime, self, destination, pattern_value, args[1], 0, end_sentinel, line, column);
}

fn startPatternFindAll(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, args: []const Value, line: u32, column: u32) bool {
    const pos = integerPosition(args[1]) orelse return self.nativeTypeError(line, column, "pos must be an integer");
    const endpos = integerPosition(args[2]) orelse return self.nativeTypeError(line, column, "endpos must be an integer");
    return startFindAllTask(Runtime, self, destination, receiver, args[0], pos, endpos, line, column);
}

fn startModuleFindIter(comptime Runtime: type, self: *Runtime, destination: u16, args: []const Value, line: u32, column: u32) bool {
    const pattern_value = ensurePattern(Runtime, self, args[0], args[2], line, column) orelse return false;
    var pattern_root = gc.Root{ .object = pattern_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&pattern_root);
    defer roots.pop();
    return createFindIterator(Runtime, self, destination, pattern_value, args[1], 0, end_sentinel, line, column);
}

fn startPatternFindIter(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, args: []const Value, line: u32, column: u32) bool {
    const pos = integerPosition(args[1]) orelse return self.nativeTypeError(line, column, "pos must be an integer");
    const endpos = integerPosition(args[2]) orelse return self.nativeTypeError(line, column, "endpos must be an integer");
    return createFindIterator(Runtime, self, destination, receiver, args[0], pos, endpos, line, column);
}

fn createFindIterator(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    pattern_value: Value,
    subject_value: Value,
    raw_pos: i64,
    raw_endpos: i64,
    line: u32,
    column: u32,
) bool {
    const pattern_state = patternFromValue(pattern_value) orelse return self.engineFault();
    const subject = patternBytes(Runtime, self, subject_value) orelse return self.nativeTypeError(line, column, "expected string or bytes-like object");
    if (subject.mode != pattern_state.pattern.program.mode) return self.nativeTypeError(line, column, "cannot use a string pattern on a bytes-like object or vice versa");
    const length = regex_objects.codepointLength(subject.bytes, subject.mode) orelse return self.engineFault();
    const pos = normalizePosition(raw_pos, length);
    const endpos = normalizePosition(raw_endpos, length);
    const class = self.ensureNativeClass(.regex_find_iterator, "callable_iterator", line, column) orelse return false;
    const object = types.createObject(&self.heap, class, .regex_find_iterator) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    var object_root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&object_root);
    defer roots.pop();
    const state = self.heap.allocator.create(FindIteratorState) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    state.* = .{
        .allocator = self.heap.allocator,
        .pattern = pattern_value,
        .subject = subject_value,
        .pos = pos,
        .endpos = endpos,
        .next_position = pos,
    };
    object.payload = state;
    object.trace_payload = traceFindIterator;
    object.destroy_payload = destroyFindIterator;
    object.ops = findIteratorOps(Runtime);
    self.setRegister(destination, Value.object(&object.header));
    return true;
}

fn startModuleSplit(comptime Runtime: type, self: *Runtime, destination: u16, args: []const Value, line: u32, column: u32) bool {
    const pattern_value = ensurePattern(Runtime, self, args[0], args[3], line, column) orelse return false;
    var pattern_root = gc.Root{ .object = pattern_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&pattern_root);
    defer roots.pop();
    return startSplitTask(Runtime, self, destination, pattern_value, args[1], args[2], line, column);
}

fn startSplitTask(comptime Runtime: type, self: *Runtime, destination: u16, pattern_value: Value, subject_value: Value, maxsplit_value: Value, line: u32, column: u32) bool {
    const maxsplit = integerPosition(maxsplit_value) orelse return self.nativeTypeError(line, column, "maxsplit must be an integer");
    const pattern_state = patternFromValue(pattern_value) orelse return self.engineFault();
    const subject = patternBytes(Runtime, self, subject_value) orelse return self.nativeTypeError(line, column, "expected string or bytes-like object");
    if (subject.mode != pattern_state.pattern.program.mode) return self.nativeTypeError(line, column, "cannot use a string pattern on a bytes-like object or vice versa");
    const length = regex_objects.codepointLength(subject.bytes, subject.mode) orelse return self.engineFault();
    const list = switch (sequence.createList(&self.heap, &.{})) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var list_root = gc.Root{ .object = &list.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&list_root);
    defer roots.pop();
    const payload = self.heap.allocator.create(SplitTaskPayload) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    payload.* = .{ .allocator = self.heap.allocator, .endpos = length, .maxsplit = maxsplit };
    const caller = self.top_frame orelse {
        self.heap.allocator.destroy(payload);
        return self.engineFault();
    };
    const inputs = [_]Value{ pattern_value, subject_value, Value.object(&list.header) };
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        .re,
        5,
        @ptrCast(caller),
        destination,
        line,
        column,
        &inputs,
        splitTaskOps(Runtime),
    ) catch {
        self.heap.allocator.destroy(payload);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn splitTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return splitTaskStep(Runtime, self, task);
        }

        const ops = types.TaskOps{ .step = step, .destroy_payload = destroySplitTask };
    }.ops;
}

fn splitTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload = splitTaskPayload(task) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex split state" } };
    const pattern_state = patternFromValue(task.inputs[0]) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex pattern state" } };
    const subject = patternBytes(Runtime, self, task.inputs[1]) orelse return .{ .raise = .{ .kind = .type_error, .message = "invalid regex subject" } };
    const list = sequence.listFromHeader(task.inputs[2].asObject() orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex split list" } }) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex split list" } };
    if (payload.maxsplit < 0 or payload.maxsplit > 0 and payload.split_count >= payload.maxsplit) {
        const tail = sliceValue(Runtime, self, subject, payload.last_end, payload.endpos, task.line, task.column) orelse return .propagate;
        if (!appendListValue(self, list, tail, task.line, task.column)) return .propagate;
        return .{ .complete = task.inputs[2] };
    }
    var budget = regex_vm.WorkBudget{ .remaining = self.remainingNativeWork() };
    if (payload.decoded == null) {
        payload.decoded = regex_vm.decodeSubject(self.heap.allocator, subject.bytes, subject.mode, &budget) catch |err| {
            _ = self.chargeBulkWork(budget.used);
            return regexTaskError(err);
        };
        if (!self.chargeBulkWork(budget.used)) return .yield;
        budget = .{ .remaining = self.remainingNativeWork() };
    }
    if (payload.engine == null) {
        payload.engine = regex_vm.Engine.initDecoded(
            self.heap.allocator,
            &pattern_state.pattern.program,
            &payload.decoded.?,
            .{ .start = payload.next_position, .end = payload.endpos, .anchor = .search, .suppress_empty_at = payload.suppress_empty_at },
            character_semantics,
        ) catch |err| {
            return regexTaskError(err);
        };
    }
    const result = payload.engine.?.step(64, &budget) catch |err| {
        _ = self.chargeBulkWork(budget.used);
        return regexTaskError(err);
    };
    if (!self.chargeBulkWork(budget.used)) return .yield;
    return switch (result) {
        .yielded => .yield,
        .no_match => blk: {
            const tail = sliceDecodedValue(Runtime, self, subject, &payload.decoded.?, payload.last_end, payload.endpos, task.line, task.column) orelse break :blk .propagate;
            if (!appendListValue(self, list, tail, task.line, task.column)) break :blk .propagate;
            break :blk .{ .complete = task.inputs[2] };
        },
        .matched => |match_result| blk: {
            var owned_match = match_result;
            defer owned_match.deinit();
            const whole = owned_match.span(0).?;
            const prefix = sliceDecodedValue(Runtime, self, subject, &payload.decoded.?, payload.last_end, whole.start, task.line, task.column) orelse break :blk .propagate;
            if (!appendListValue(self, list, prefix, task.line, task.column)) break :blk .propagate;
            var group: usize = 1;
            while (group <= pattern_state.pattern.program.group_count) : (group += 1) {
                const value = if (owned_match.span(group) == null)
                    Value.noneValue()
                else
                    groupSliceDecodedValue(Runtime, self, subject, &payload.decoded.?, &owned_match, group, task.line, task.column) orelse break :blk .propagate;
                if (!appendListValue(self, list, value, task.line, task.column)) break :blk .propagate;
            }
            payload.split_count += 1;
            payload.last_end = whole.end;
            if (whole.start == whole.end) {
                payload.next_position = whole.start;
                payload.suppress_empty_at = whole.start;
            } else {
                payload.next_position = whole.end;
                payload.suppress_empty_at = null;
            }
            payload.engine.?.deinit();
            payload.engine = null;
            break :blk .yield;
        },
    };
}

fn splitTaskPayload(task: *types.Task) ?*SplitTaskPayload {
    if (task.owner != .re or task.operation != 5) return null;
    return @ptrCast(@alignCast(task.payload orelse return null));
}

fn destroySplitTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *SplitTaskPayload = @ptrCast(@alignCast(raw orelse return));
    if (payload.engine) |*engine| engine.deinit();
    if (payload.decoded) |*decoded| decoded.deinit();
    allocator.destroy(payload);
}

fn appendListValue(self: anytype, list: *sequence.List, value: Value, line: u32, column: u32) bool {
    var root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    list.items.append(self.heap.allocator, value) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    list.version +%= 1;
    return true;
}

fn sliceValue(comptime Runtime: type, self: *Runtime, subject: PatternBytes, start: usize, end: usize, line: u32, column: u32) ?Value {
    const byte_start = regex_objects.codepointByteOffset(subject.bytes, subject.mode, start) orelse return null;
    const byte_end = regex_objects.codepointByteOffset(subject.bytes, subject.mode, end) orelse return null;
    const slice = subject.bytes[byte_start..byte_end];
    if (subject.mode == .unicode) return self.createStringValue(slice, line, column);
    return switch (byte_module.create(&self.heap, slice)) {
        .value => |bytes| Value.object(&bytes.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
        .engine_error => null,
    };
}

fn sliceDecodedValue(comptime Runtime: type, self: *Runtime, subject: PatternBytes, decoded: *const regex_vm.DecodedSubject, start: usize, end: usize, line: u32, column: u32) ?Value {
    const slice = regex_objects.sliceDecoded(subject.bytes, decoded, start, end) orelse return null;
    if (subject.mode == .unicode) return self.createStringValue(slice, line, column);
    return switch (byte_module.create(&self.heap, slice)) {
        .value => |bytes| Value.object(&bytes.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
        .engine_error => null,
    };
}

fn groupSliceDecodedValue(comptime Runtime: type, self: *Runtime, subject: PatternBytes, decoded: *const regex_vm.DecodedSubject, match: *const regex_vm.Match, group: usize, line: u32, column: u32) ?Value {
    const slice = regex_objects.captureSliceDecoded(subject.bytes, decoded, match, group) orelse return Value.noneValue();
    if (subject.mode == .unicode) return self.createStringValue(slice, line, column);
    return switch (byte_module.create(&self.heap, slice)) {
        .value => |bytes| Value.object(&bytes.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
        .engine_error => null,
    };
}

fn startModuleSub(comptime Runtime: type, self: *Runtime, destination: u16, function_id: u16, args: []const Value, line: u32, column: u32) bool {
    const pattern_value = ensurePattern(Runtime, self, args[0], args[4], line, column) orelse return false;
    var pattern_root = gc.Root{ .object = pattern_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&pattern_root);
    defer roots.pop();
    return startSubTask(Runtime, self, destination, pattern_value, args[1], args[2], args[3], function_id == 9, line, column);
}

fn startSubTask(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    pattern_value: Value,
    replacement_value: Value,
    subject_value: Value,
    count_value: Value,
    return_count: bool,
    line: u32,
    column: u32,
) bool {
    const max_count = integerPosition(count_value) orelse return self.nativeTypeError(line, column, "count must be an integer");
    const pattern_state = patternFromValue(pattern_value) orelse return self.engineFault();
    const subject = patternBytes(Runtime, self, subject_value) orelse return self.nativeTypeError(line, column, "expected string or bytes-like object");
    if (subject.mode != pattern_state.pattern.program.mode) return self.nativeTypeError(line, column, "cannot use a string pattern on a bytes-like object or vice versa");
    const callable = self.isCallable(replacement_value);
    const replacement = if (callable) null else patternBytes(Runtime, self, replacement_value) orelse return self.nativeTypeError(line, column, "replacement must be a string or callable");
    if (replacement) |selected| if (selected.mode != subject.mode) return self.nativeTypeError(line, column, "replacement must have the same string type as the pattern");
    _ = self.ensureNativeClass(.regex_match, "Match", line, column) orelse return false;
    const length = regex_objects.codepointLength(subject.bytes, subject.mode) orelse return self.engineFault();
    const payload = self.heap.allocator.create(SubTaskPayload) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    payload.* = .{
        .allocator = self.heap.allocator,
        .endpos = length,
        .max_count = max_count,
        .return_count = return_count,
        .callable = callable,
    };
    if (replacement) |selected| {
        var diagnostic = regex_objects.TemplateDiagnostic{};
        payload.template = regex_objects.Template.parse(self.heap.allocator, selected.bytes, &pattern_state.pattern.program, &diagnostic) catch |err| {
            self.heap.allocator.destroy(payload);
            if (err == error.OutOfMemory) self.setException(exceptions.memoryError(), line, column, null) else setRegexError(Runtime, self, replacement_value, diagnostic.message, diagnostic.position, line, column);
            return false;
        };
    }
    const caller = self.top_frame orelse {
        destroySubTask(payload, self.heap.allocator);
        return self.engineFault();
    };
    const inputs = [_]Value{ pattern_value, subject_value, replacement_value };
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        .re,
        6,
        @ptrCast(caller),
        destination,
        line,
        column,
        &inputs,
        subTaskOps(Runtime),
    ) catch {
        destroySubTask(payload, self.heap.allocator);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn subTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return subTaskStep(Runtime, self, task);
        }

        const ops = types.TaskOps{ .step = step, .trace_payload = traceSubTask, .destroy_payload = destroySubTask };
    }.ops;
}

fn subTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload = subTaskPayload(task) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex substitution state" } };
    const pattern_state = patternFromValue(task.inputs[0]) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex pattern state" } };
    const subject = patternBytes(Runtime, self, task.inputs[1]) orelse return .{ .raise = .{ .kind = .type_error, .message = "invalid regex subject" } };
    if (payload.phase == .callback) return resumeSubCallback(Runtime, self, task, payload, subject);
    if (payload.max_count < 0 or payload.max_count > 0 and payload.replacement_count >= payload.max_count) return finishSub(Runtime, self, task, payload, subject);
    var budget = regex_vm.WorkBudget{ .remaining = self.remainingNativeWork() };
    if (payload.decoded == null) {
        payload.decoded = regex_vm.decodeSubject(self.heap.allocator, subject.bytes, subject.mode, &budget) catch |err| {
            _ = self.chargeBulkWork(budget.used);
            return regexTaskError(err);
        };
        if (!self.chargeBulkWork(budget.used)) return .yield;
        budget = .{ .remaining = self.remainingNativeWork() };
    }
    if (payload.engine == null) {
        payload.engine = regex_vm.Engine.initDecoded(
            self.heap.allocator,
            &pattern_state.pattern.program,
            &payload.decoded.?,
            .{ .start = payload.next_position, .end = payload.endpos, .anchor = .search, .suppress_empty_at = payload.suppress_empty_at },
            character_semantics,
        ) catch |err| {
            return regexTaskError(err);
        };
    }
    const result = payload.engine.?.step(64, &budget) catch |err| {
        _ = self.chargeBulkWork(budget.used);
        return regexTaskError(err);
    };
    if (!self.chargeBulkWork(budget.used)) return .yield;
    return switch (result) {
        .yielded => .yield,
        .no_match => finishSub(Runtime, self, task, payload, subject),
        .matched => |match_result| handleSubMatch(Runtime, self, task, payload, subject, match_result),
    };
}

fn handleSubMatch(
    comptime Runtime: type,
    self: *Runtime,
    task: *types.Task,
    payload: *SubTaskPayload,
    subject: PatternBytes,
    match_result: regex_vm.Match,
) types.TaskStep {
    var owned_match = match_result;
    const whole = owned_match.span(0).?;
    const decoded = &payload.decoded.?;
    const byte_start = decoded.byteOffset(payload.last_end) orelse {
        owned_match.deinit();
        return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex substitution offset" } };
    };
    const byte_end = decoded.byteOffset(whole.start) orelse {
        owned_match.deinit();
        return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex substitution offset" } };
    };
    payload.output.appendSlice(self.heap.allocator, subject.bytes[byte_start..byte_end]) catch {
        owned_match.deinit();
        return .{ .raise = exceptions.memoryError() };
    };
    if (!payload.callable) {
        payload.template.?.expandDecoded(self.heap.allocator, &payload.output, subject.bytes, decoded, &owned_match) catch {
            owned_match.deinit();
            return .{ .raise = exceptions.memoryError() };
        };
        owned_match.deinit();
        advanceSub(payload, whole.start, whole.end);
        return .yield;
    }
    const match_value = createMatchValue(Runtime, self, task.inputs[0], task.inputs[1], payload.next_position, payload.endpos, owned_match, &payload.decoded.?, task.line, task.column) orelse return .propagate;
    payload.pending_match = match_value;
    payload.callback_args[0] = match_value;
    payload.pending_start = whole.start;
    payload.pending_end = whole.end;
    payload.phase = .callback;
    return .{ .call = .{ .callable = task.inputs[2], .positional = &payload.callback_args } };
}

fn resumeSubCallback(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *SubTaskPayload, subject: PatternBytes) types.TaskStep {
    if (!task.child_ready) return .yield;
    if (task.child_error != null) return .propagate;
    const replacement = patternBytes(Runtime, self, task.child_value) orelse return .{ .raise = .{ .kind = .type_error, .message = "replacement function must return a string" } };
    if (replacement.mode != subject.mode) return .{ .raise = .{ .kind = .type_error, .message = "replacement function returned a different string type" } };
    payload.output.appendSlice(self.heap.allocator, replacement.bytes) catch return .{ .raise = exceptions.memoryError() };
    task.child_ready = false;
    task.child_value = Value.noneValue();
    payload.pending_match = Value.noneValue();
    payload.callback_args[0] = Value.noneValue();
    payload.phase = .scan;
    advanceSub(payload, payload.pending_start, payload.pending_end);
    return .yield;
}

fn advanceSub(payload: *SubTaskPayload, start: usize, end: usize) void {
    payload.replacement_count += 1;
    payload.last_end = end;
    if (start == end) {
        payload.next_position = start;
        payload.suppress_empty_at = start;
    } else {
        payload.next_position = end;
        payload.suppress_empty_at = null;
    }
    if (payload.engine) |*engine| engine.deinit();
    payload.engine = null;
}

fn finishSub(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *SubTaskPayload, subject: PatternBytes) types.TaskStep {
    const decoded: ?*const regex_vm.DecodedSubject = if (payload.decoded) |*value| value else null;
    const byte_start = decodedByteOffset(subject, decoded, payload.last_end) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex substitution offset" } };
    const byte_end = decodedByteOffset(subject, decoded, payload.endpos) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex substitution offset" } };
    payload.output.appendSlice(self.heap.allocator, subject.bytes[byte_start..byte_end]) catch return .{ .raise = exceptions.memoryError() };
    const value = if (subject.mode == .unicode)
        self.createStringValue(payload.output.items, task.line, task.column) orelse return .propagate
    else switch (byte_module.create(&self.heap, payload.output.items)) {
        .value => |bytes| Value.object(&bytes.header),
        .python_exception => |exception| return .{ .raise = exception },
        .engine_error => return .{ .raise = .{ .kind = .runtime_error, .message = "failed to create regex bytes result" } },
    };
    if (!payload.return_count) return .{ .complete = value };
    var value_root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&value_root);
    defer roots.pop();
    const values = [_]Value{ value, Value.fromSmallInt(payload.replacement_count) orelse return .{ .raise = .{ .kind = .overflow_error, .message = "replacement count is too large" } } };
    return switch (sequence.createTuple(&self.heap, &values)) {
        .value => |tuple| .{ .complete = Value.object(&tuple.header) },
        .python_exception => |exception| .{ .raise = exception },
        .engine_error => .{ .raise = .{ .kind = .runtime_error, .message = "failed to create substitution result" } },
    };
}

fn decodedByteOffset(subject: PatternBytes, decoded: ?*const regex_vm.DecodedSubject, position: usize) ?usize {
    if (decoded) |selected| return selected.byteOffset(position);
    return regex_objects.codepointByteOffset(subject.bytes, subject.mode, position);
}

fn copyByteCaptures(allocator: std.mem.Allocator, result: *const regex_vm.Match, decoded: *const regex_vm.DecodedSubject) error{OutOfMemory}![]i64 {
    const captures = allocator.alloc(i64, result.captures.len) catch return error.OutOfMemory;
    for (result.captures, captures) |position, *byte_position| {
        byte_position.* = if (position < 0)
            -1
        else
            @intCast(decoded.byteOffset(@intCast(position)) orelse unreachable);
    }
    return captures;
}

fn createMatchValue(
    comptime Runtime: type,
    self: *Runtime,
    pattern: Value,
    subject: Value,
    pos: usize,
    endpos: usize,
    result: regex_vm.Match,
    decoded: *const regex_vm.DecodedSubject,
    line: u32,
    column: u32,
) ?Value {
    const byte_captures = copyByteCaptures(self.heap.allocator, &result, decoded) catch {
        var owned = result;
        owned.deinit();
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    const state = self.heap.allocator.create(MatchState) catch {
        var owned = result;
        owned.deinit();
        self.heap.allocator.free(byte_captures);
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    state.* = .{ .allocator = self.heap.allocator, .result = result, .byte_captures = byte_captures, .pattern = pattern, .subject = subject, .pos = pos, .endpos = endpos };
    const class = self.ensureNativeClass(.regex_match, "Match", line, column) orelse {
        state.result.deinit();
        state.allocator.free(state.byte_captures);
        self.heap.allocator.destroy(state);
        return null;
    };
    const object = types.createObject(&self.heap, class, .regex_match) catch {
        state.result.deinit();
        state.allocator.free(state.byte_captures);
        self.heap.allocator.destroy(state);
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    object.payload = state;
    object.trace_payload = traceMatch;
    object.destroy_payload = destroyMatch;
    object.ops = matchObjectOps(Runtime);
    return Value.object(&object.header);
}

fn subTaskPayload(task: *types.Task) ?*SubTaskPayload {
    if (task.owner != .re or task.operation != 6) return null;
    return @ptrCast(@alignCast(task.payload orelse return null));
}

fn traceSubTask(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *SubTaskPayload = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(payload.pending_match.asObject());
    tracer.visit(payload.callback_args[0].asObject());
}

fn destroySubTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *SubTaskPayload = @ptrCast(@alignCast(raw orelse return));
    if (payload.engine) |*engine| engine.deinit();
    if (payload.decoded) |*decoded| decoded.deinit();
    if (payload.template) |*template| template.deinit();
    payload.output.deinit(allocator);
    allocator.destroy(payload);
}

fn startFindAllTask(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    pattern_value: Value,
    subject_value: Value,
    raw_pos: i64,
    raw_endpos: i64,
    line: u32,
    column: u32,
) bool {
    const pattern_state = patternFromValue(pattern_value) orelse return self.engineFault();
    const subject = patternBytes(Runtime, self, subject_value) orelse return self.nativeTypeError(line, column, "expected string or bytes-like object");
    if (subject.mode != pattern_state.pattern.program.mode) return self.nativeTypeError(line, column, "cannot use a string pattern on a bytes-like object or vice versa");
    const length = regex_objects.codepointLength(subject.bytes, subject.mode) orelse return self.engineFault();
    const pos = normalizePosition(raw_pos, length);
    const endpos = normalizePosition(raw_endpos, length);
    const list = switch (sequence.createList(&self.heap, &.{})) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var list_root = gc.Root{ .object = &list.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&list_root);
    defer roots.pop();
    const payload = self.heap.allocator.create(FindAllTaskPayload) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    payload.* = .{ .allocator = self.heap.allocator, .next_position = pos, .endpos = endpos };
    const caller = self.top_frame orelse {
        self.heap.allocator.destroy(payload);
        return self.engineFault();
    };
    const inputs = [_]Value{ pattern_value, subject_value, Value.object(&list.header) };
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        .re,
        4,
        @ptrCast(caller),
        destination,
        line,
        column,
        &inputs,
        findAllTaskOps(Runtime),
    ) catch {
        self.heap.allocator.destroy(payload);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn findAllTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return findAllTaskStep(Runtime, self, task);
        }

        const ops = types.TaskOps{ .step = step, .destroy_payload = destroyFindAllTask };
    }.ops;
}

fn findAllTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload = findAllTaskPayload(task) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex findall state" } };
    const pattern_state = patternFromValue(task.inputs[0]) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex pattern state" } };
    const subject = patternBytes(Runtime, self, task.inputs[1]) orelse return .{ .raise = .{ .kind = .type_error, .message = "invalid regex subject" } };
    var budget = regex_vm.WorkBudget{ .remaining = self.remainingNativeWork() };
    if (payload.decoded == null) {
        payload.decoded = regex_vm.decodeSubject(self.heap.allocator, subject.bytes, subject.mode, &budget) catch |err| {
            _ = self.chargeBulkWork(budget.used);
            return regexTaskError(err);
        };
        if (!self.chargeBulkWork(budget.used)) return .yield;
        budget = .{ .remaining = self.remainingNativeWork() };
    }
    if (payload.engine == null) {
        payload.engine = regex_vm.Engine.initDecoded(
            self.heap.allocator,
            &pattern_state.pattern.program,
            &payload.decoded.?,
            .{ .start = payload.next_position, .end = payload.endpos, .anchor = .search, .suppress_empty_at = payload.suppress_empty_at },
            character_semantics,
        ) catch |err| {
            return regexTaskError(err);
        };
    }
    const result = payload.engine.?.step(64, &budget) catch |err| {
        _ = self.chargeBulkWork(budget.used);
        return regexTaskError(err);
    };
    if (!self.chargeBulkWork(budget.used)) return .yield;
    return switch (result) {
        .yielded => .yield,
        .no_match => .{ .complete = task.inputs[2] },
        .matched => |match_result| blk: {
            var owned_match = match_result;
            defer owned_match.deinit();
            const item = findAllItem(Runtime, self, pattern_state, subject.bytes, &payload.decoded.?, &owned_match, task.line, task.column) orelse break :blk .propagate;
            var item_root = gc.Root{ .object = item.asObject() };
            var roots = gc.RootFrame{};
            roots.push(&self.heap.roots);
            roots.add(&item_root);
            defer roots.pop();
            const list_header = task.inputs[2].asObject() orelse break :blk .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex result list" } };
            const list = sequence.listFromHeader(list_header) orelse break :blk .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex result list" } };
            list.items.append(self.heap.allocator, item) catch break :blk .{ .raise = exceptions.memoryError() };
            list.version +%= 1;
            const span = owned_match.span(0).?;
            if (span.start == span.end) {
                payload.next_position = span.start;
                payload.suppress_empty_at = span.start;
            } else {
                payload.next_position = span.end;
                payload.suppress_empty_at = null;
            }
            payload.engine.?.deinit();
            payload.engine = null;
            break :blk .yield;
        },
    };
}

fn findAllItem(comptime Runtime: type, self: *Runtime, pattern: *PatternState, subject: []const u8, decoded: *const regex_vm.DecodedSubject, match: *const regex_vm.Match, line: u32, column: u32) ?Value {
    const count = pattern.pattern.program.group_count;
    if (count == 0) return captureOrEmpty(Runtime, self, pattern, subject, decoded, match, 0, line, column);
    if (count == 1) return captureOrEmpty(Runtime, self, pattern, subject, decoded, match, 1, line, column);
    const values = self.heap.allocator.alloc(Value, count) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    defer self.heap.allocator.free(values);
    const roots_storage = self.heap.allocator.alloc(gc.Root, count) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    defer self.heap.allocator.free(roots_storage);
    @memset(roots_storage, .{ .object = null });
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (roots_storage) |*root| roots.add(root);
    defer roots.pop();
    for (values, 0..) |*value, index| {
        value.* = captureOrEmpty(Runtime, self, pattern, subject, decoded, match, index + 1, line, column) orelse return null;
        roots_storage[index].object = value.asObject();
    }
    return switch (sequence.createTuple(&self.heap, values)) {
        .value => |tuple| Value.object(&tuple.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
        .engine_error => null,
    };
}

fn captureOrEmpty(comptime Runtime: type, self: *Runtime, pattern: *PatternState, subject: []const u8, decoded: *const regex_vm.DecodedSubject, match: *const regex_vm.Match, group: usize, line: u32, column: u32) ?Value {
    const slice = regex_objects.captureSliceDecoded(subject, decoded, match, group) orelse "";
    if (pattern.pattern.program.mode == .unicode) return self.createStringValue(slice, line, column);
    return switch (byte_module.create(&self.heap, slice)) {
        .value => |bytes| Value.object(&bytes.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
        .engine_error => null,
    };
}

fn findAllTaskPayload(task: *types.Task) ?*FindAllTaskPayload {
    if (task.owner != .re or task.operation != 4) return null;
    return @ptrCast(@alignCast(task.payload orelse return null));
}

fn destroyFindAllTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *FindAllTaskPayload = @ptrCast(@alignCast(raw orelse return));
    if (payload.engine) |*engine| engine.deinit();
    if (payload.decoded) |*decoded| decoded.deinit();
    allocator.destroy(payload);
}

fn findIteratorOps(comptime Runtime: type) *const types.NativeObjectOps {
    return &struct {
        fn iter(_: *anyopaque, object: *types.NativeObject, _: u32, _: u32) ?Value {
            return Value.object(&object.header);
        }

        fn next(context: *anyopaque, object: *types.NativeObject, destination: u16, line: u32, column: u32) types.NativeNextResult {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = findIteratorFromObject(object) orelse return .{ .engine_error = .internal_invariant };
            if (state.finished) return .done;
            const caller = self.top_frame orelse return .{ .engine_error = .internal_invariant };
            const iterator_value = Value.object(&object.header);
            const task = types.createTask(
                &self.heap,
                self.currentNativeTask(),
                .re,
                7,
                @ptrCast(caller),
                destination,
                line,
                column,
                &.{iterator_value},
                findIteratorTaskOps(Runtime),
            ) catch return .{ .python_exception = exceptions.memoryError() };
            if (!self.startNativeTask(task)) return .{ .engine_error = .internal_invariant };
            return .suspended;
        }

        const ops = types.NativeObjectOps{ .iter = iter, .next = next };
    }.ops;
}

fn findIteratorTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return findIteratorTaskStep(Runtime, self, task);
        }

        const ops = types.TaskOps{ .step = step };
    }.ops;
}

fn findIteratorTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    if (task.owner != .re or task.operation != 7 or task.inputs.len != 1) return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex iterator task" } };
    const object = types.fromHeader(task.inputs[0].asObject() orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex iterator" } }) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex iterator" } };
    const state = findIteratorFromObject(object) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex iterator state" } };
    if (state.finished) return .done;
    const pattern_state = patternFromValue(state.pattern) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex pattern state" } };
    const subject = patternBytes(Runtime, self, state.subject) orelse return .{ .raise = .{ .kind = .type_error, .message = "invalid regex subject" } };
    var budget = regex_vm.WorkBudget{ .remaining = self.remainingNativeWork() };
    if (state.decoded == null) {
        state.decoded = regex_vm.decodeSubject(self.heap.allocator, subject.bytes, subject.mode, &budget) catch |err| {
            _ = self.chargeBulkWork(budget.used);
            return regexTaskError(err);
        };
        if (!self.chargeBulkWork(budget.used)) return .yield;
        budget = .{ .remaining = self.remainingNativeWork() };
    }
    if (state.engine == null) {
        state.engine = regex_vm.Engine.initDecoded(
            self.heap.allocator,
            &pattern_state.pattern.program,
            &state.decoded.?,
            .{ .start = state.next_position, .end = state.endpos, .anchor = .search, .suppress_empty_at = state.suppress_empty_at },
            character_semantics,
        ) catch |err| return regexTaskError(err);
    }
    const result = state.engine.?.step(64, &budget) catch |err| {
        _ = self.chargeBulkWork(budget.used);
        return regexTaskError(err);
    };
    if (!self.chargeBulkWork(budget.used)) return .yield;
    return switch (result) {
        .yielded => .yield,
        .no_match => blk: {
            state.engine.?.deinit();
            state.engine = null;
            state.finished = true;
            break :blk .done;
        },
        .matched => |match_result| blk: {
            const whole = match_result.span(0) orelse {
                var owned = match_result;
                owned.deinit();
                break :blk .{ .raise = .{ .kind = .runtime_error, .message = "regex match has no whole span" } };
            };
            if (whole.start == whole.end) {
                state.next_position = whole.start;
                state.suppress_empty_at = whole.start;
            } else {
                state.next_position = whole.end;
                state.suppress_empty_at = null;
            }
            state.engine.?.deinit();
            state.engine = null;
            const value = createMatchValue(Runtime, self, state.pattern, state.subject, state.pos, state.endpos, match_result, &state.decoded.?, task.line, task.column) orelse break :blk .propagate;
            break :blk .{ .complete = value };
        },
    };
}

fn regexTaskError(err: regex_vm.Error) types.TaskStep {
    return switch (err) {
        error.OutOfMemory => .{ .raise = exceptions.memoryError() },
        error.WorkLimit => .yield,
        error.InvalidUtf8 => .{ .raise = .{ .kind = .unicode_error, .message = "invalid UTF-8 regex subject" } },
    };
}

fn startMatchTask(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    operation: MatchOperation,
    pattern_value: Value,
    subject_value: Value,
    raw_pos: i64,
    raw_endpos: i64,
    line: u32,
    column: u32,
) bool {
    const pattern_state = patternFromValue(pattern_value) orelse return self.engineFault();
    const subject = patternBytes(Runtime, self, subject_value) orelse return self.nativeTypeError(line, column, "expected string or bytes-like object");
    if (subject.mode != pattern_state.pattern.program.mode) return self.nativeTypeError(line, column, "cannot use a string pattern on a bytes-like object or vice versa");
    const length = regex_objects.codepointLength(subject.bytes, subject.mode) orelse return self.engineFault();
    const pos = normalizePosition(raw_pos, length);
    const endpos = normalizePosition(raw_endpos, length);
    _ = self.ensureNativeClass(.regex_match, "Match", line, column) orelse return false;
    const payload = self.heap.allocator.create(MatchTaskPayload) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    payload.* = .{ .allocator = self.heap.allocator, .operation = operation, .pos = pos, .endpos = endpos };
    const caller = self.top_frame orelse {
        self.heap.allocator.destroy(payload);
        return self.engineFault();
    };
    const inputs = [_]Value{ pattern_value, subject_value };
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        .re,
        @intFromEnum(operation),
        @ptrCast(caller),
        destination,
        line,
        column,
        &inputs,
        matchTaskOps(Runtime),
    ) catch {
        self.heap.allocator.destroy(payload);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn matchTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return matchTaskStep(Runtime, self, task);
        }

        const ops = types.TaskOps{ .step = step, .destroy_payload = destroyMatchTask };
    }.ops;
}

fn matchTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload = matchTaskPayload(task) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex task state" } };
    const pattern_state = patternFromValue(task.inputs[0]) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid regex pattern state" } };
    const subject = patternBytes(Runtime, self, task.inputs[1]) orelse return .{ .raise = .{ .kind = .type_error, .message = "invalid regex subject" } };
    var budget = regex_vm.WorkBudget{ .remaining = self.remainingNativeWork() };
    if (payload.engine == null) {
        payload.engine = regex_vm.Engine.init(
            self.heap.allocator,
            &pattern_state.pattern.program,
            subject.bytes,
            .{
                .start = payload.pos,
                .end = payload.endpos,
                .anchor = switch (payload.operation) {
                    .search => .search,
                    .match => .match,
                    .fullmatch => .fullmatch,
                },
            },
            character_semantics,
            &budget,
        ) catch |err| {
            _ = self.chargeBulkWork(budget.used);
            return switch (err) {
                error.OutOfMemory => .{ .raise = exceptions.memoryError() },
                error.WorkLimit => .yield,
                error.InvalidUtf8 => .{ .raise = .{ .kind = .unicode_error, .message = "invalid UTF-8 regex subject" } },
            };
        };
        if (!self.chargeBulkWork(budget.used)) return .yield;
        budget = .{ .remaining = self.remainingNativeWork() };
    }
    const result = payload.engine.?.step(64, &budget) catch |err| {
        _ = self.chargeBulkWork(budget.used);
        return switch (err) {
            error.OutOfMemory => .{ .raise = exceptions.memoryError() },
            error.WorkLimit => .yield,
            error.InvalidUtf8 => .{ .raise = .{ .kind = .unicode_error, .message = "invalid UTF-8 regex subject" } },
        };
    };
    if (!self.chargeBulkWork(budget.used)) return .yield;
    return switch (result) {
        .yielded => .yield,
        .no_match => .{ .complete = Value.noneValue() },
        .matched => |match_result| createMatchResult(Runtime, self, task, payload, match_result),
    };
}

fn createMatchResult(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *MatchTaskPayload, result: regex_vm.Match) types.TaskStep {
    const byte_captures = copyByteCaptures(self.heap.allocator, &result, payload.engine.?.input) catch {
        var owned = result;
        owned.deinit();
        return .{ .raise = exceptions.memoryError() };
    };
    const state = self.heap.allocator.create(MatchState) catch {
        var owned = result;
        owned.deinit();
        self.heap.allocator.free(byte_captures);
        return .{ .raise = exceptions.memoryError() };
    };
    state.* = .{ .allocator = self.heap.allocator, .result = result, .byte_captures = byte_captures, .pattern = task.inputs[0], .subject = task.inputs[1], .pos = payload.pos, .endpos = payload.endpos };
    const class = self.ensureNativeClass(.regex_match, "Match", task.line, task.column) orelse {
        state.result.deinit();
        state.allocator.free(state.byte_captures);
        self.heap.allocator.destroy(state);
        return .{ .raise = .{ .kind = .runtime_error, .message = "regex Match class is unavailable" } };
    };
    const object = types.createObject(&self.heap, class, .regex_match) catch {
        state.result.deinit();
        state.allocator.free(state.byte_captures);
        self.heap.allocator.destroy(state);
        return .{ .raise = exceptions.memoryError() };
    };
    object.payload = state;
    object.trace_payload = traceMatch;
    object.destroy_payload = destroyMatch;
    object.ops = matchObjectOps(Runtime);
    return .{ .complete = Value.object(&object.header) };
}

fn matchObjectOps(comptime Runtime: type) *const types.NativeObjectOps {
    return &struct {
        fn getItem(context: *anyopaque, object: *types.NativeObject, key: Value, destination: u16, line: u32, column: u32) ?Value {
            _ = destination;
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = matchFromObject(object) orelse return null;
            const index = groupIndex(Runtime, self, state, key, line, column) orelse return null;
            return groupValue(Runtime, self, state, index, line, column);
        }

        const ops = types.NativeObjectOps{ .get_item = getItem };
    }.ops;
}

fn matchTaskPayload(task: *types.Task) ?*MatchTaskPayload {
    if (task.owner != .re) return null;
    return @ptrCast(@alignCast(task.payload orelse return null));
}

fn destroyMatchTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *MatchTaskPayload = @ptrCast(@alignCast(raw orelse return));
    if (payload.engine) |*engine| engine.deinit();
    allocator.destroy(payload);
}

fn operationForFunction(function_id: u16) MatchOperation {
    return switch (function_id) {
        2, 102 => .search,
        3, 101 => .match,
        4, 103 => .fullmatch,
        else => unreachable,
    };
}

fn integerPosition(value: Value) ?i64 {
    if (value.asSmallInt()) |integer| return integer;
    if (value.asBool()) |boolean| return if (boolean) 1 else 0;
    return null;
}

fn normalizePosition(value: i64, length: usize) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), length);
}

fn escapeValue(comptime Runtime: type, self: *Runtime, destination: u16, input: Value, line: u32, column: u32) bool {
    const selected = patternBytes(Runtime, self, input) orelse return self.nativeTypeError(line, column, "escape() argument must be str or bytes");
    const escaped = regex_objects.escape(self.heap.allocator, selected.bytes, selected.mode) catch |err| {
        self.setException(if (err == error.OutOfMemory) exceptions.memoryError() else .{ .kind = .value_error, .message = "invalid regex escape input" }, line, column, null);
        return false;
    };
    defer self.heap.allocator.free(escaped);
    const result = if (selected.mode == .unicode)
        self.createStringValue(escaped, line, column) orelse return false
    else
        switch (byte_module.create(&self.heap, escaped)) {
            .value => |bytes| Value.object(&bytes.header),
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        } orelse return false;
    self.setRegister(destination, result);
    return true;
}

fn executeMatchMethod(comptime Runtime: type, self: *Runtime, destination: u16, function_id: u16, receiver: Value, args: []const Value, line: u32, column: u32) bool {
    const object = types.fromHeader(receiver.asObject() orelse return self.engineFault()) orelse return self.engineFault();
    const state = matchFromObject(object) orelse return self.engineFault();
    return switch (function_id) {
        201 => groupMethod(Runtime, self, destination, state, args[0], line, column),
        202 => groupsMethod(Runtime, self, destination, state, args[0], line, column),
        203 => groupdictMethod(Runtime, self, destination, state, args[0], line, column),
        204, 205, 206 => spanMethod(Runtime, self, destination, state, args[0], function_id, line, column),
        else => self.engineFault(),
    };
}

pub fn executeDirectMatchMethod(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    function_id: u16,
    receiver: Value,
    positional: []const Value,
    keywords: []const binder.Keyword,
    line: u32,
    column: u32,
) ?bool {
    if (function_id < 201 or function_id > 206) return null;
    const object = types.fromHeader(receiver.asObject() orelse return self.engineFault()) orelse return self.engineFault();
    const state = matchFromObject(object) orelse return self.engineFault();
    if (keywords.len != 0) return self.nativeTypeError(line, column, "match methods do not accept keyword arguments");
    if (function_id == 201) return groupItemsMethod(Runtime, self, destination, state, positional, line, column);
    if (positional.len > 1) return self.nativeArity(line, column);
    const argument = if (positional.len == 1)
        positional[0]
    else if (function_id == 202 or function_id == 203)
        Value.noneValue()
    else
        Value.fromSmallInt(0).?;
    return switch (function_id) {
        202 => groupsMethod(Runtime, self, destination, state, argument, line, column),
        203 => groupdictMethod(Runtime, self, destination, state, argument, line, column),
        204, 205, 206 => spanMethod(Runtime, self, destination, state, argument, function_id, line, column),
        else => unreachable,
    };
}

fn groupMethod(comptime Runtime: type, self: *Runtime, destination: u16, state: *MatchState, groups_value: Value, line: u32, column: u32) bool {
    const header = groups_value.asObject() orelse return self.engineFault();
    const groups = sequence.tupleFromHeader(header) orelse return self.engineFault();
    return groupItemsMethod(Runtime, self, destination, state, groups.items, line, column);
}

fn groupItemsMethod(comptime Runtime: type, self: *Runtime, destination: u16, state: *MatchState, groups: []const Value, line: u32, column: u32) bool {
    if (groups.len == 0) return storeGroup(Runtime, self, destination, state, 0, line, column);
    if (groups.len == 1) {
        const index = groupIndex(Runtime, self, state, groups[0], line, column) orelse return false;
        return storeGroup(Runtime, self, destination, state, index, line, column);
    }
    var values = self.heap.allocator.alloc(Value, groups.len) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    defer self.heap.allocator.free(values);
    var value_roots = self.heap.allocator.alloc(gc.Root, values.len) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    defer self.heap.allocator.free(value_roots);
    @memset(value_roots, .{ .object = null });
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (value_roots) |*root| roots.add(root);
    defer roots.pop();
    for (groups, 0..) |group, index| {
        const selected = groupIndex(Runtime, self, state, group, line, column) orelse return false;
        values[index] = groupValue(Runtime, self, state, selected, line, column) orelse return false;
        value_roots[index].object = values[index].asObject();
    }
    return storeTuple(Runtime, self, destination, values, line, column);
}

fn groupsMethod(comptime Runtime: type, self: *Runtime, destination: u16, state: *MatchState, default: Value, line: u32, column: u32) bool {
    const count = state.result.captures.len / 2 - 1;
    const values = self.heap.allocator.alloc(Value, count) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    defer self.heap.allocator.free(values);
    const roots_storage = self.heap.allocator.alloc(gc.Root, count) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    defer self.heap.allocator.free(roots_storage);
    @memset(roots_storage, .{ .object = null });
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (roots_storage) |*root| roots.add(root);
    defer roots.pop();
    for (values, 0..) |*value, index| {
        value.* = if (state.result.span(index + 1) == null) default else groupValue(Runtime, self, state, index + 1, line, column) orelse return false;
        roots_storage[index].object = value.asObject();
    }
    return storeTuple(Runtime, self, destination, values, line, column);
}

fn groupdictMethod(comptime Runtime: type, self: *Runtime, destination: u16, state: *MatchState, default: Value, line: u32, column: u32) bool {
    const pattern_state = patternFromValue(state.pattern) orelse return self.engineFault();
    const mapping = switch (dict_module.create(&self.heap, false)) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var mapping_root = gc.Root{ .object = &mapping.header };
    var key_root = gc.Root{ .object = null };
    var value_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&mapping_root);
    roots.add(&key_root);
    roots.add(&value_root);
    defer roots.pop();
    for (pattern_state.pattern.program.group_names) |entry| {
        const key = self.createStringValue(entry.name, line, column) orelse return false;
        key_root.object = key.asObject();
        const value = if (state.result.span(entry.index) == null) default else groupValue(Runtime, self, state, entry.index, line, column) orelse return false;
        value_root.object = value.asObject();
        if (!self.setMappingValue(mapping, key, value, line, column)) return false;
    }
    self.setRegister(destination, Value.object(&mapping.header));
    return true;
}

fn spanMethod(comptime Runtime: type, self: *Runtime, destination: u16, state: *MatchState, group: Value, function_id: u16, line: u32, column: u32) bool {
    const index = groupIndex(Runtime, self, state, group, line, column) orelse return false;
    const span = state.result.span(index);
    const start: i64 = if (span) |selected| @intCast(selected.start) else -1;
    const end: i64 = if (span) |selected| @intCast(selected.end) else -1;
    if (function_id == 204 or function_id == 205) {
        self.setRegister(destination, Value.fromSmallInt(if (function_id == 204) start else end).?);
        return true;
    }
    const values = [_]Value{ Value.fromSmallInt(start).?, Value.fromSmallInt(end).? };
    return storeTuple(Runtime, self, destination, &values, line, column);
}

fn storeGroup(comptime Runtime: type, self: *Runtime, destination: u16, state: *MatchState, index: usize, line: u32, column: u32) bool {
    const value = groupValue(Runtime, self, state, index, line, column) orelse return false;
    self.setRegister(destination, value);
    return true;
}

fn groupValue(comptime Runtime: type, self: *Runtime, state: *MatchState, index: usize, line: u32, column: u32) ?Value {
    const slot = std.math.mul(usize, index, 2) catch return null;
    if (slot + 1 >= state.byte_captures.len) return Value.noneValue();
    const start = state.byte_captures[slot];
    const end = state.byte_captures[slot + 1];
    if (start < 0 or end < 0) return Value.noneValue();
    const subject = patternBytes(Runtime, self, state.subject) orelse return null;
    const byte_start: usize = @intCast(start);
    const byte_end: usize = @intCast(end);
    if (byte_start > byte_end or byte_end > subject.bytes.len) return null;
    const slice = subject.bytes[byte_start..byte_end];
    if (subject.mode == .unicode) return self.createStringValue(slice, line, column);
    return switch (byte_module.create(&self.heap, slice)) {
        .value => |bytes| Value.object(&bytes.header),
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

fn groupIndex(comptime Runtime: type, self: *Runtime, state: *MatchState, value: Value, line: u32, column: u32) ?usize {
    const numeric_index = value.asSmallInt() orelse if (value.asBool()) |boolean| @as(i64, @intFromBool(boolean)) else null;
    if (numeric_index) |index| {
        if (index >= 0 and index <= state.result.captures.len / 2 - 1) return @intCast(index);
        self.setException(.{ .kind = .index_error, .message = "no such group" }, line, column, null);
        return null;
    }
    const name = self.valueString(value) orelse {
        self.setException(.{ .kind = .index_error, .message = "no such group" }, line, column, null);
        return null;
    };
    const pattern_state = patternFromValue(state.pattern) orelse return null;
    return pattern_state.pattern.program.groupIndex(name) orelse {
        self.setException(.{ .kind = .index_error, .message = "no such group" }, line, column, null);
        return null;
    };
}

fn patternAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    const state = patternFromObject(object) orelse return null;
    if (std.mem.eql(u8, name, "pattern")) return if (state.pattern.program.mode == .unicode)
        self.createStringValue(state.pattern.source, line, column)
    else switch (byte_module.create(&self.heap, state.pattern.source)) {
        .value => |bytes| Value.object(&bytes.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
        .engine_error => null,
    };
    if (std.mem.eql(u8, name, "flags")) return Value.fromSmallInt(@intCast(state.pattern.program.flags));
    if (std.mem.eql(u8, name, "groups")) return Value.fromSmallInt(@intCast(state.pattern.program.group_count));
    if (std.mem.eql(u8, name, "groupindex")) {
        const mapping = switch (dict_module.create(&self.heap, false)) {
            .value => |created| created,
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => null,
        } orelse return null;
        var mapping_root = gc.Root{ .object = &mapping.header };
        var key_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&mapping_root);
        roots.add(&key_root);
        defer roots.pop();
        for (state.pattern.program.group_names) |entry| {
            const key = self.createStringValue(entry.name, line, column) orelse return null;
            key_root.object = key.asObject();
            if (!self.setMappingValue(mapping, key, Value.fromSmallInt(@intCast(entry.index)).?, line, column)) return null;
        }
        return Value.object(&mapping.header);
    }
    const method_id: u16 = if (std.mem.eql(u8, name, "match")) 101 else if (std.mem.eql(u8, name, "search")) 102 else if (std.mem.eql(u8, name, "fullmatch")) 103 else if (std.mem.eql(u8, name, "findall")) 104 else if (std.mem.eql(u8, name, "finditer")) 105 else if (std.mem.eql(u8, name, "split")) 106 else if (std.mem.eql(u8, name, "sub")) 107 else if (std.mem.eql(u8, name, "subn")) 108 else return null;
    return boundMethod(Runtime, self, .re, method_id, Value.object(&object.header), line, column);
}

fn matchAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    const state = matchFromObject(object) orelse return null;
    if (std.mem.eql(u8, name, "string")) return state.subject;
    if (std.mem.eql(u8, name, "re")) return state.pattern;
    const method_id: u16 = if (std.mem.eql(u8, name, "group")) 201 else if (std.mem.eql(u8, name, "groups")) 202 else if (std.mem.eql(u8, name, "groupdict")) 203 else if (std.mem.eql(u8, name, "start")) 204 else if (std.mem.eql(u8, name, "end")) 205 else if (std.mem.eql(u8, name, "span")) 206 else return null;
    return boundMethod(Runtime, self, .re, method_id, Value.object(&object.header), line, column);
}

fn boundMethod(comptime Runtime: type, self: *Runtime, module: types.ModuleId, id: u16, receiver: Value, line: u32, column: u32) ?Value {
    return switch (functions_module.createLibrary(&self.heap, @intFromEnum(module), id, receiver)) {
        .value => |function| Value.object(&function.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
    };
}

fn storeTuple(comptime Runtime: type, self: *Runtime, destination: u16, values: []const Value, line: u32, column: u32) bool {
    return switch (sequence.createTuple(&self.heap, values)) {
        .value => |tuple| blk: {
            self.setRegister(destination, Value.object(&tuple.header));
            break :blk true;
        },
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk false;
        },
        .engine_error => self.engineFault(),
    };
}

fn patternBytes(comptime Runtime: type, self: *Runtime, value: Value) ?PatternBytes {
    if (self.valueString(value)) |text| return .{ .bytes = text, .mode = .unicode };
    if (self.valueBytes(value)) |bytes| return .{ .bytes = bytes, .mode = .bytes };
    return null;
}

fn integerFlags(value: Value) ?u32 {
    const raw = value.asSmallInt() orelse if (value.asBool()) |boolean| @as(i64, if (boolean) 1 else 0) else return null;
    if (raw < 0 or raw > std.math.maxInt(u32)) return null;
    return @intCast(raw);
}

fn nativePattern(value: Value) ?*PatternState {
    const object = types.fromHeader(value.asObject() orelse return null) orelse return null;
    return patternFromObject(object);
}

fn patternFromValue(value: Value) ?*PatternState {
    return nativePattern(value);
}

fn patternFromObject(object: *types.NativeObject) ?*PatternState {
    if (object.type_id != .regex_pattern) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn matchFromObject(object: *types.NativeObject) ?*MatchState {
    if (object.type_id != .regex_match) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn findIteratorFromObject(object: *types.NativeObject) ?*FindIteratorState {
    if (object.type_id != .regex_find_iterator) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn destroyPattern(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *PatternState = @ptrCast(@alignCast(raw orelse return));
    state.pattern.deinit();
    allocator.destroy(state);
}

fn destroyMatch(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *MatchState = @ptrCast(@alignCast(raw orelse return));
    state.result.deinit();
    allocator.free(state.byte_captures);
    allocator.destroy(state);
}

fn traceMatch(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const state: *MatchState = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(state.pattern.asObject());
    tracer.visit(state.subject.asObject());
}

fn destroyFindIterator(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *FindIteratorState = @ptrCast(@alignCast(raw orelse return));
    if (state.engine) |*engine| engine.deinit();
    if (state.decoded) |*decoded| decoded.deinit();
    allocator.destroy(state);
}

fn traceFindIterator(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const state: *FindIteratorState = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(state.pattern.asObject());
    tracer.visit(state.subject.asObject());
}

fn storeValue(comptime Runtime: type, self: *Runtime, environment: *gc.Header, name: []const u8, value: Value, line: u32, column: u32) bool {
    var root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    if (self.environmentStore(environment, name, value)) return true;
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}

pub const character_semantics = regex_vm.CharacterSemantics{
    .has_property = unicodeHasProperty,
    .case_variants = unicodeCaseVariants,
};

fn unicodeHasProperty(_: ?*const anyopaque, codepoint: u21, property: regex_vm.Property) bool {
    if (codepoint <= 0x7f) return switch (property) {
        .decimal => codepoint >= '0' and codepoint <= '9',
        .alnum => codepoint >= '0' and codepoint <= '9' or codepoint >= 'a' and codepoint <= 'z' or codepoint >= 'A' and codepoint <= 'Z',
        .whitespace => codepoint == ' ' or codepoint == '\t' or codepoint == '\n' or codepoint == '\r' or codepoint == 0x0b or codepoint == 0x0c,
    };
    return unicode.hasProperty(codepoint, switch (property) {
        .decimal => .decimal,
        .alnum => .alnum,
        .whitespace => .whitespace,
    });
}

fn unicodeCaseVariants(_: ?*const anyopaque, codepoint: u21, output: *[12]u21) usize {
    var length: usize = 0;
    appendVariant(output, &length, codepoint);
    appendVariant(output, &length, unicode.simpleMapping(codepoint, .lower));
    appendVariant(output, &length, unicode.simpleMapping(codepoint, .upper));
    appendVariant(output, &length, unicode.simpleMapping(codepoint, .title));
    appendVariant(output, &length, unicode.simpleMapping(codepoint, .casefold));
    switch (codepoint) {
        0x0130, 0x0131 => appendVariant(output, &length, 'i'),
        0x017f => appendVariant(output, &length, 's'),
        0x212a => appendVariant(output, &length, 'k'),
        'i', 'I' => {
            appendVariant(output, &length, 0x0130);
            appendVariant(output, &length, 0x0131);
        },
        's', 'S' => appendVariant(output, &length, 0x017f),
        'k', 'K' => appendVariant(output, &length, 0x212a),
        else => {},
    }
    return length;
}

fn appendVariant(output: *[12]u21, length: *usize, value: u21) void {
    for (output[0..length.*]) |existing| if (existing == value) return;
    if (length.* < output.len) {
        output[length.*] = value;
        length.* += 1;
    }
}

fn setRegexError(
    comptime Runtime: type,
    self: *Runtime,
    pattern: Value,
    message: []const u8,
    position: usize,
    line: u32,
    column: u32,
) void {
    const module = self.findCachedModule("re") orelse {
        self.setException(.{ .kind = .value_error, .message = message }, line, column, null);
        return;
    };
    const class_value = Runtime.environmentLookup(module.environment, "error") orelse {
        self.setException(.{ .kind = .value_error, .message = message }, line, column, null);
        return;
    };
    const class = exceptions.classFromHeader(class_value.asObject() orelse {
        self.setException(.{ .kind = .value_error, .message = message }, line, column, null);
        return;
    }) orelse {
        self.setException(.{ .kind = .value_error, .message = message }, line, column, null);
        return;
    };
    self.setException(.{ .kind = class.kind, .message = message, .native_class = class }, line, column, null);
    const instance = self.active_exception orelse return;
    const message_value = self.createStringValue(message, line, column) orelse return;
    var roots_storage = [_]gc.Root{ .{ .object = pattern.asObject() }, .{ .object = message_value.asObject() } };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_storage) |*root| roots.add(root);
    defer roots.pop();
    exceptions.setAttribute(&self.heap, instance, "msg", message_value) catch return replaceWithMemoryError(self, line, column);
    exceptions.setAttribute(&self.heap, instance, "pattern", pattern) catch return replaceWithMemoryError(self, line, column);
    const position_value = Value.fromSmallInt(@intCast(position)).?;
    exceptions.setAttribute(&self.heap, instance, "pos", position_value) catch return replaceWithMemoryError(self, line, column);
}

fn replaceWithMemoryError(self: anytype, line: u32, column: u32) void {
    self.setException(exceptions.memoryError(), line, column, null);
}
