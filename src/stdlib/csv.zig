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
const keyword_only = binder.parameter_flags_module.keyword_only;

pub const functions = [_]types.FunctionSpec{
    readerSpec(1, "reader"),
    writerSpec(2, "writer"),
    .{ .id = 3, .name = "DictReader", .params = &.{
        .{ .name = "f" }, .{ .name = "fieldnames", .default = .none }, .{ .name = "restkey", .default = .none }, .{ .name = "restval", .default = .none },
        .{ .name = "delimiter", .flags = keyword_only, .default = .{ .text = "," } },
        .{ .name = "quotechar", .flags = keyword_only, .default = .{ .text = "\"" } },
        .{ .name = "quoting", .flags = keyword_only, .default = .{ .integer = 0 } },
    } },
    .{ .id = 4, .name = "DictWriter", .params = &.{
        .{ .name = "f" }, .{ .name = "fieldnames" }, .{ .name = "restval", .default = .{ .text = "" } }, .{ .name = "extrasaction", .default = .{ .text = "raise" } },
        .{ .name = "delimiter", .flags = keyword_only, .default = .{ .text = "," } },
        .{ .name = "quotechar", .flags = keyword_only, .default = .{ .text = "\"" } },
        .{ .name = "lineterminator", .flags = keyword_only, .default = .{ .text = "\r\n" } },
        .{ .name = "quoting", .flags = keyword_only, .default = .{ .integer = 0 } },
    } },
    .{ .id = 101, .name = "writerow", .params = &.{.{ .name = "row" }}, .exported = false },
    .{ .id = 102, .name = "writerows", .params = &.{.{ .name = "rows" }}, .exported = false },
    .{ .id = 201, .name = "writeheader", .exported = false },
};

pub const classes = [_]types.TypeSpec{
    .{ .type_id = .csv_reader, .module = .csv, .name = "reader" },
    .{ .type_id = .csv_writer, .module = .csv, .name = "writer" },
    .{ .type_id = .csv_dict_reader, .module = .csv, .name = "DictReader" },
    .{ .type_id = .csv_dict_writer, .module = .csv, .name = "DictWriter" },
};

fn readerSpec(comptime id: u16, comptime name: []const u8) types.FunctionSpec {
    return .{ .id = id, .name = name, .params = &.{
        .{ .name = "csvfile" },
        .{ .name = "delimiter", .flags = keyword_only, .default = .{ .text = "," } },
        .{ .name = "quotechar", .flags = keyword_only, .default = .{ .text = "\"" } },
        .{ .name = "quoting", .flags = keyword_only, .default = .{ .integer = 0 } },
    } };
}

fn writerSpec(comptime id: u16, comptime name: []const u8) types.FunctionSpec {
    return .{ .id = id, .name = name, .params = &.{
        .{ .name = "csvfile" },
        .{ .name = "delimiter", .flags = keyword_only, .default = .{ .text = "," } },
        .{ .name = "quotechar", .flags = keyword_only, .default = .{ .text = "\"" } },
        .{ .name = "lineterminator", .flags = keyword_only, .default = .{ .text = "\r\n" } },
        .{ .name = "quoting", .flags = keyword_only, .default = .{ .integer = 0 } },
    } };
}

pub const QuoteMode = enum(i64) {
    minimal = 0,
    all = 1,
    nonnumeric = 2,
};

pub const Dialect = struct {
    delimiter: []const u8 = ",",
    quote: []const u8 = "\"",
    line_terminator: []const u8 = "\r\n",
    quoting: QuoteMode = .minimal,

    pub fn validate(self: Dialect) !void {
        if (!singleCodepoint(self.delimiter)) return error.InvalidDelimiter;
        if (!singleCodepoint(self.quote)) return error.InvalidQuote;
        if (!std.unicode.utf8ValidateSlice(self.line_terminator)) return error.InvalidLineTerminator;
        if (std.mem.eql(u8, self.delimiter, self.quote)) return error.InvalidDialect;
    }
};

pub const Field = struct {
    text: []const u8,
    quoted: bool,
};

const OwnedField = struct {
    text: []u8,
    quoted: bool,
};

const ReadState = enum {
    field_start,
    unquoted,
    quoted,
    after_quote,
};

/// Incremental CSV reader core. It owns only the current record's UTF-8 field
/// buffers and emits a borrowed row to the caller. Python float conversion,
/// dictionaries, and iterator scheduling stay in the Runtime adapter.
pub const ReaderCore = struct {
    allocator: std.mem.Allocator,
    dialect: Dialect,
    state: ReadState = .field_start,
    current: std.ArrayList(u8) = .empty,
    fields: std.ArrayList(OwnedField) = .empty,
    current_quoted: bool = false,
    saw_source_item: bool = false,
    pending_record: bool = false,
    line_num: usize = 0,

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect) !ReaderCore {
        try dialect.validate();
        return .{ .allocator = allocator, .dialect = dialect };
    }

    pub fn deinit(self: *ReaderCore) void {
        self.clearFields();
        self.fields.deinit(self.allocator);
        self.current.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feedItem(self: *ReaderCore, item: []const u8, sink: anytype) anyerror!void {
        if (!std.unicode.utf8ValidateSlice(item)) return error.InvalidUtf8;
        self.saw_source_item = true;
        self.line_num += 1;
        var cursor: usize = 0;
        var ended_with_record = false;
        while (cursor < item.len) {
            ended_with_record = false;
            switch (self.state) {
                .field_start => {
                    if (startsAt(item, cursor, self.dialect.quote)) {
                        self.state = .quoted;
                        self.current_quoted = true;
                        self.pending_record = true;
                        cursor += self.dialect.quote.len;
                    } else if (startsAt(item, cursor, self.dialect.delimiter)) {
                        try self.endField();
                        self.pending_record = true;
                        cursor += self.dialect.delimiter.len;
                    } else if (newlineWidth(item, cursor)) |width| {
                        try self.endField();
                        try self.emitRow(sink);
                        ended_with_record = true;
                        cursor += width;
                    } else {
                        const width = try codepointWidth(item, cursor);
                        try self.current.appendSlice(self.allocator, item[cursor..][0..width]);
                        self.state = .unquoted;
                        self.pending_record = true;
                        cursor += width;
                    }
                },
                .unquoted => {
                    if (startsAt(item, cursor, self.dialect.delimiter)) {
                        try self.endField();
                        self.state = .field_start;
                        cursor += self.dialect.delimiter.len;
                    } else if (newlineWidth(item, cursor)) |width| {
                        try self.endField();
                        try self.emitRow(sink);
                        ended_with_record = true;
                        cursor += width;
                    } else {
                        const width = try codepointWidth(item, cursor);
                        try self.current.appendSlice(self.allocator, item[cursor..][0..width]);
                        cursor += width;
                    }
                },
                .quoted => {
                    if (startsAt(item, cursor, self.dialect.quote)) {
                        self.state = .after_quote;
                        cursor += self.dialect.quote.len;
                    } else {
                        const width = try codepointWidth(item, cursor);
                        try self.current.appendSlice(self.allocator, item[cursor..][0..width]);
                        cursor += width;
                    }
                },
                .after_quote => {
                    if (startsAt(item, cursor, self.dialect.quote)) {
                        try self.current.appendSlice(self.allocator, self.dialect.quote);
                        self.state = .quoted;
                        cursor += self.dialect.quote.len;
                    } else if (startsAt(item, cursor, self.dialect.delimiter)) {
                        try self.endField();
                        self.state = .field_start;
                        cursor += self.dialect.delimiter.len;
                    } else if (newlineWidth(item, cursor)) |width| {
                        try self.endField();
                        try self.emitRow(sink);
                        ended_with_record = true;
                        cursor += width;
                    } else {
                        // Python's default non-strict reader accepts ordinary
                        // characters following a closing quote.
                        const width = try codepointWidth(item, cursor);
                        try self.current.appendSlice(self.allocator, item[cursor..][0..width]);
                        self.state = .unquoted;
                        cursor += width;
                    }
                },
            }
        }
        if (self.state == .quoted) return;
        if (!ended_with_record) {
            try self.endField();
            try self.emitRow(sink);
        }
    }

    pub fn finish(self: *ReaderCore, sink: anytype) anyerror!void {
        if (!self.pending_record and self.fields.items.len == 0 and self.current.items.len == 0) return;
        try self.endField();
        try self.emitRow(sink);
    }

    fn endField(self: *ReaderCore) !void {
        const text = try self.current.toOwnedSlice(self.allocator);
        errdefer if (text.len != 0) self.allocator.free(text);
        try self.fields.append(self.allocator, .{ .text = text, .quoted = self.current_quoted });
        self.current = .empty;
        self.current_quoted = false;
        self.state = .field_start;
        self.pending_record = true;
    }

    fn emitRow(self: *ReaderCore, sink: anytype) !void {
        const exposed = try self.allocator.alloc(Field, self.fields.items.len);
        defer self.allocator.free(exposed);
        for (self.fields.items, 0..) |field, index| exposed[index] = .{ .text = field.text, .quoted = field.quoted };
        try sink.row(exposed, self.line_num);
        self.clearFields();
        self.state = .field_start;
        self.current_quoted = false;
        self.pending_record = false;
    }

    fn clearFields(self: *ReaderCore) void {
        for (self.fields.items) |field| if (field.text.len != 0) self.allocator.free(field.text);
        self.fields.clearRetainingCapacity();
    }
};

pub const WriteField = struct {
    text: []const u8,
    numeric: bool = false,
};

/// Serializes exactly one CSV row. The Runtime adapter calls the target's
/// `write` once with this completed owned buffer.
pub fn writeRow(allocator: std.mem.Allocator, dialect: Dialect, fields: []const WriteField) ![]u8 {
    try dialect.validate();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (fields, 0..) |field, index| {
        if (!std.unicode.utf8ValidateSlice(field.text)) return error.InvalidUtf8;
        if (index != 0) try output.appendSlice(allocator, dialect.delimiter);
        const quote = switch (dialect.quoting) {
            .all => true,
            .nonnumeric => !field.numeric,
            .minimal => containsSpecial(field.text, dialect) or (fields.len == 1 and field.text.len == 0),
        };
        if (quote) try output.appendSlice(allocator, dialect.quote);
        var cursor: usize = 0;
        while (cursor < field.text.len) {
            if (startsAt(field.text, cursor, dialect.quote)) {
                try output.appendSlice(allocator, dialect.quote);
                try output.appendSlice(allocator, dialect.quote);
                cursor += dialect.quote.len;
            } else {
                const width = try codepointWidth(field.text, cursor);
                try output.appendSlice(allocator, field.text[cursor..][0..width]);
                cursor += width;
            }
        }
        if (quote) try output.appendSlice(allocator, dialect.quote);
    }
    try output.appendSlice(allocator, dialect.line_terminator);
    return output.toOwnedSlice(allocator);
}

fn containsSpecial(text: []const u8, dialect: Dialect) bool {
    return std.mem.indexOf(u8, text, dialect.delimiter) != null or
        std.mem.indexOf(u8, text, dialect.quote) != null or
        std.mem.indexOfScalar(u8, text, '\r') != null or
        std.mem.indexOfScalar(u8, text, '\n') != null;
}

fn startsAt(input: []const u8, cursor: usize, needle: []const u8) bool {
    return cursor <= input.len and needle.len <= input.len - cursor and std.mem.eql(u8, input[cursor..][0..needle.len], needle);
}

fn newlineWidth(input: []const u8, cursor: usize) ?usize {
    if (input[cursor] == '\n') return 1;
    if (input[cursor] != '\r') return null;
    return if (cursor + 1 < input.len and input[cursor + 1] == '\n') 2 else 1;
}

fn codepointWidth(input: []const u8, cursor: usize) !usize {
    const width = std.unicode.utf8ByteSequenceLength(input[cursor]) catch return error.InvalidUtf8;
    if (cursor + width > input.len) return error.InvalidUtf8;
    _ = std.unicode.utf8Decode(input[cursor..][0..width]) catch return error.InvalidUtf8;
    return width;
}

fn singleCodepoint(text: []const u8) bool {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return false;
    const width = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    return width == text.len;
}

const ModuleState = struct {
    header: gc.Header align(8),
    error_class: *exceptions.ExceptionClass,
};

const module_state_kind = gc.Kind{ .trace = traceModuleState };

const ReaderState = struct {
    core: ReaderCore,
    source: Value,
    pending: std.ArrayList(Value) = .empty,
    exhausted: bool = false,
    active: bool = false,
    error_class: *exceptions.ExceptionClass,
    fieldnames: Value = Value.noneValue(),
    restkey: Value = Value.noneValue(),
    restval: Value = Value.noneValue(),
    dict_mode: bool = false,
    dialect_values: [3]Value = .{ Value.noneValue(), Value.noneValue(), Value.noneValue() },
};

const WriterState = struct {
    allocator: std.mem.Allocator,
    target: Value,
    write_method: Value,
    dialect: Dialect,
    error_class: *exceptions.ExceptionClass,
    fieldnames: Value = Value.noneValue(),
    restval: Value = Value.noneValue(),
    extras_ignore: bool = false,
    dict_mode: bool = false,
    dialect_values: [3]Value = .{ Value.noneValue(), Value.noneValue(), Value.noneValue() },
};

const WriterPhase = enum { collect, call };

const OwnedWriteField = struct { text: []u8, numeric: bool };

const WriterTaskPayload = struct {
    allocator: std.mem.Allocator,
    phase: WriterPhase = .collect,
    fields: std.ArrayList(OwnedWriteField) = .empty,
    call_args: [1]Value = .{Value.noneValue()},
};

const WriterowsPayload = struct {
    row_args: [1]Value = .{Value.noneValue()},
    waiting_call: bool = false,
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
    for (functions) |spec| if (spec.exported and !storeBoundFunction(self, environment, state, spec, line, column)) return false;
    if (!self.environmentStore(environment, "QUOTE_MINIMAL", Value.fromSmallInt(0).?)) return memoryFailure(self, line, column);
    if (!self.environmentStore(environment, "QUOTE_ALL", Value.fromSmallInt(1).?)) return memoryFailure(self, line, column);
    if (self.environmentStore(environment, "QUOTE_NONNUMERIC", Value.fromSmallInt(2).?)) return true;
    return memoryFailure(self, line, column);
}

fn storeBoundFunction(self: anytype, environment: *gc.Header, state: *ModuleState, spec: types.FunctionSpec, line: u32, column: u32) bool {
    const created = functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.csv), spec.id, Value.object(&state.header));
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
    return switch (function_id) {
        1 => createReader(Runtime, self, destination, moduleState(receiver) orelse return self.engineFault(), args, false, line, column),
        2 => createWriter(Runtime, self, destination, moduleState(receiver) orelse return self.engineFault(), args, false, line, column),
        3 => createReader(Runtime, self, destination, moduleState(receiver) orelse return self.engineFault(), args, true, line, column),
        4 => createWriter(Runtime, self, destination, moduleState(receiver) orelse return self.engineFault(), args, true, line, column),
        101 => writerow(Runtime, self, destination, receiver, args[0], line, column),
        102 => writerows(Runtime, self, destination, receiver, args[0], line, column),
        201 => writeheader(Runtime, self, destination, receiver, line, column),
        else => self.engineFault(),
    };
}

fn createReader(comptime Runtime: type, self: *Runtime, destination: u16, module: *ModuleState, args: []const Value, dict_mode: bool, line: u32, column: u32) bool {
    const offset: usize = if (dict_mode) 4 else 1;
    const dialect = parseDialect(self, args[offset], args[offset + 1], null, args[offset + 2], module.error_class, line, column) orelse return false;
    const source = switch (self.createVmIterator(args[0], line, column)) {
        .value => |iterator| Value.object(&iterator.header),
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var source_root = gc.Root{ .object = source.asObject() };
    var field_root = gc.Root{ .object = if (dict_mode) args[1].asObject() else null };
    var field_iterator_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&source_root);
    roots.add(&field_root);
    roots.add(&field_iterator_root);
    defer roots.pop();
    var fieldnames_task = false;
    var fieldnames_iterator = Value.noneValue();
    const fieldnames = if (!dict_mode or args[1].tag() == .none)
        Value.noneValue()
    else if (sequenceItems(args[1]) != null)
        normalizeFieldnames(Runtime, self, args[1], line, column) orelse return false
    else blk: {
        fieldnames_iterator = switch (self.createVmIterator(args[1], line, column)) {
            .value => |iterator| Value.object(&iterator.header),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        field_iterator_root.object = fieldnames_iterator.asObject();
        const names = switch (sequence.createList(&self.heap, &.{})) {
            .value => |list| Value.object(&list.header),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        fieldnames_task = true;
        break :blk names;
    };
    field_root.object = fieldnames.asObject();
    const type_id: types.TypeId = if (dict_mode) .csv_dict_reader else .csv_reader;
    const class = self.ensureNativeClass(type_id, if (dict_mode) "DictReader" else "reader", line, column) orelse return false;
    const object = types.createObject(&self.heap, class, type_id) catch return memoryFailure(self, line, column);
    var object_root = gc.Root{ .object = &object.header };
    roots.add(&object_root);
    const core = ReaderCore.init(self.heap.allocator, dialect) catch return csvFailure(self, module.error_class, "invalid CSV dialect", line, column);
    const state = self.heap.allocator.create(ReaderState) catch return memoryFailure(self, line, column);
    state.* = .{
        .core = core,
        .source = source,
        .error_class = module.error_class,
        .dict_mode = dict_mode,
        .fieldnames = fieldnames,
        .restkey = if (dict_mode) args[2] else Value.noneValue(),
        .restval = if (dict_mode) args[3] else Value.noneValue(),
        .dialect_values = .{ args[offset], args[offset + 1], Value.noneValue() },
    };
    object.payload = state;
    object.trace_payload = traceReader;
    object.destroy_payload = destroyReader;
    object.ops = readerOps(Runtime);
    if (fieldnames_task) return startFieldnamesTask(Runtime, self, destination, object, fieldnames_iterator, line, column);
    self.setRegister(destination, Value.object(&object.header));
    return true;
}

fn startFieldnamesTask(comptime Runtime: type, self: *Runtime, destination: u16, object: *types.NativeObject, iterator_value: Value, line: u32, column: u32) bool {
    const caller = self.top_frame orelse return self.engineFault();
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        .csv,
        303,
        @ptrCast(caller),
        destination,
        line,
        column,
        &.{ Value.object(&object.header), iterator_value },
        fieldnamesTaskOps(Runtime),
    ) catch return memoryFailure(self, line, column);
    return self.startNativeTask(task);
}

fn fieldnamesTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const object = objectFromValue(task.inputs[0]) orelse return runtimeTaskError("invalid DictReader fieldnames task");
            const state = readerState(object) orelse return runtimeTaskError("invalid DictReader fieldnames state");
            const names = sequence.listFromHeader(state.fieldnames.asObject() orelse return runtimeTaskError("invalid DictReader fieldnames list")) orelse return runtimeTaskError("invalid DictReader fieldnames list");
            if (task.child_ready) {
                if (task.child_error != null) return .propagate;
                if (task.child_done) return .{ .complete = task.inputs[0] };
                if (self.valueString(task.child_value) == null) return .{ .raise = .{ .kind = .type_error, .message = "fieldnames entries must be strings" } };
                switch (sequence.append(&self.heap, names, task.child_value)) {
                    .value => {},
                    .python_exception => |exception| return .{ .raise = exception },
                    .engine_error => return runtimeTaskError("failed to append DictReader fieldname"),
                }
                task.child_ready = false;
                task.child_value = Value.noneValue();
            }
            return .{ .next = task.inputs[1] };
        }
        const ops = types.TaskOps{ .step = step };
    }.ops;
}

fn createWriter(comptime Runtime: type, self: *Runtime, destination: u16, module: *ModuleState, args: []const Value, dict_mode: bool, line: u32, column: u32) bool {
    const offset: usize = if (dict_mode) 4 else 1;
    const dialect = parseDialect(self, args[offset], args[offset + 1], args[offset + 2], args[offset + 3], module.error_class, line, column) orelse return false;
    const method = self.lookupAttributeValue(args[0], "write", line, column) orelse {
        if (self.last_exception == null) _ = self.nativeTypeError(line, column, "csvfile must provide write()");
        return false;
    };
    var roots_array = [_]gc.Root{ .{ .object = args[0].asObject() }, .{ .object = method.asObject() }, .{ .object = if (dict_mode) args[1].asObject() else null } };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const fieldnames = if (dict_mode) normalizeFieldnames(Runtime, self, args[1], line, column) orelse return false else Value.noneValue();
    roots_array[2].object = fieldnames.asObject();
    const type_id: types.TypeId = if (dict_mode) .csv_dict_writer else .csv_writer;
    const class = self.ensureNativeClass(type_id, if (dict_mode) "DictWriter" else "writer", line, column) orelse return false;
    const object = types.createObject(&self.heap, class, type_id) catch return memoryFailure(self, line, column);
    var object_root = gc.Root{ .object = &object.header };
    roots.add(&object_root);
    const extras_ignore = if (dict_mode) blk: {
        const action = self.valueString(args[3]) orelse return self.nativeTypeError(line, column, "extrasaction must be str");
        if (std.ascii.eqlIgnoreCase(action, "ignore")) break :blk true;
        if (std.ascii.eqlIgnoreCase(action, "raise")) break :blk false;
        return self.nativeTypeError(line, column, "extrasaction must be 'raise' or 'ignore'");
    } else false;
    const state = self.heap.allocator.create(WriterState) catch return memoryFailure(self, line, column);
    state.* = .{
        .allocator = self.heap.allocator,
        .target = args[0],
        .write_method = method,
        .dialect = dialect,
        .error_class = module.error_class,
        .dict_mode = dict_mode,
        .fieldnames = fieldnames,
        .restval = if (dict_mode) args[2] else Value.noneValue(),
        .extras_ignore = extras_ignore,
        .dialect_values = .{ args[offset], args[offset + 1], args[offset + 2] },
    };
    object.payload = state;
    object.trace_payload = traceWriter;
    object.destroy_payload = destroyWriter;
    self.setRegister(destination, Value.object(&object.header));
    return true;
}

fn parseDialect(self: anytype, delimiter_value: Value, quote_value: Value, terminator_value: ?Value, quoting_value: Value, error_class: *exceptions.ExceptionClass, line: u32, column: u32) ?Dialect {
    const delimiter = self.valueString(delimiter_value) orelse {
        _ = self.nativeTypeError(line, column, "delimiter must be str");
        return null;
    };
    const quote = self.valueString(quote_value) orelse {
        _ = self.nativeTypeError(line, column, "quotechar must be str");
        return null;
    };
    const terminator = if (terminator_value) |value| self.valueString(value) orelse {
        _ = self.nativeTypeError(line, column, "lineterminator must be str");
        return null;
    } else "\r\n";
    const quoting_int = number.toInt(i64, quoting_value) orelse {
        _ = self.nativeTypeError(line, column, "quoting must be an integer");
        return null;
    };
    const quoting = std.enums.fromInt(QuoteMode, quoting_int) orelse {
        _ = csvFailure(self, error_class, "bad quoting value", line, column);
        return null;
    };
    const dialect = Dialect{ .delimiter = delimiter, .quote = quote, .line_terminator = terminator, .quoting = quoting };
    dialect.validate() catch {
        _ = csvFailure(self, error_class, "invalid CSV dialect", line, column);
        return null;
    };
    return dialect;
}

fn readerOps(comptime Runtime: type) *const types.NativeObjectOps {
    return &struct {
        fn iterate(_: *anyopaque, object: *types.NativeObject, _: u32, _: u32) ?Value {
            return Value.object(&object.header);
        }
        fn next(context: *anyopaque, object: *types.NativeObject, destination: u16, line: u32, column: u32) @import("runtime_iterator").NextResult {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = readerState(object) orelse return .{ .engine_error = .internal_invariant };
            if (state.pending.items.len != 0) return .{ .item = state.pending.orderedRemove(0) };
            if (state.exhausted) return .done;
            if (state.active) return .suspended;
            const caller = self.top_frame orelse return .{ .engine_error = .internal_invariant };
            const task = types.createTask(&self.heap, self.currentNativeTask(), .csv, 300, @ptrCast(caller), destination, line, column, &.{ Value.object(&object.header), state.source }, readerTaskOps(Runtime)) catch return .{ .python_exception = exceptions.memoryError() };
            state.active = true;
            if (!self.startNativeTask(task)) {
                state.active = false;
                return .{ .engine_error = .internal_invariant };
            }
            return .suspended;
        }
        const ops = types.NativeObjectOps{ .iter = iterate, .next = next };
    }.ops;
}

fn readerTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const object = objectFromValue(task.inputs[0]) orelse return runtimeTaskError("invalid CSV reader task");
            const state = readerState(object) orelse return runtimeTaskError("invalid CSV reader state");
            if (task.child_ready) {
                if (task.child_error != null) {
                    state.active = false;
                    return .propagate;
                }
                if (task.child_done) {
                    var sink = RowSink(Runtime){ .runtime = self, .state = state, .line = task.line, .column = task.column };
                    state.core.finish(&sink) catch return readerTaskFailure(self, state, task.line, task.column);
                    state.exhausted = true;
                    state.active = false;
                    if (state.pending.items.len != 0) return .{ .complete = state.pending.orderedRemove(0) };
                    return .done;
                }
                const text = self.valueString(task.child_value) orelse {
                    state.active = false;
                    return .{ .raise = .{ .kind = .type_error, .message = "CSV iterator must return str" } };
                };
                var sink = RowSink(Runtime){ .runtime = self, .state = state, .line = task.line, .column = task.column };
                state.core.feedItem(text, &sink) catch return readerTaskFailure(self, state, task.line, task.column);
                task.child_ready = false;
                task.child_value = Value.noneValue();
                if (state.pending.items.len != 0) {
                    state.active = false;
                    return .{ .complete = state.pending.orderedRemove(0) };
                }
            }
            return .{ .next = task.inputs[1] };
        }
        const ops = types.TaskOps{ .step = step };
    }.ops;
}

fn RowSink(comptime Runtime: type) type {
    return struct {
        runtime: *Runtime,
        state: *ReaderState,
        line: u32,
        column: u32,

        pub fn row(self: *@This(), fields: []const Field, _: usize) !void {
            const list = switch (sequence.createList(&self.runtime.heap, &.{})) {
                .value => |created| created,
                .python_exception => return error.OutOfMemory,
                .engine_error => return error.RuntimeFailure,
            };
            var list_root = gc.Root{ .object = &list.header };
            var item_root = gc.Root{ .object = null };
            var roots = gc.RootFrame{};
            roots.push(&self.runtime.heap.roots);
            roots.add(&list_root);
            roots.add(&item_root);
            defer roots.pop();
            for (fields) |field| {
                const item = if (self.state.core.dialect.quoting == .nonnumeric and !field.quoted and field.text.len != 0)
                    Value.fromFloat(std.fmt.parseFloat(f64, field.text) catch return error.InvalidNumber)
                else
                    self.runtime.createStringValue(field.text, self.line, self.column) orelse return error.RuntimeFailure;
                item_root.object = item.asObject();
                switch (sequence.append(&self.runtime.heap, list, item)) {
                    .value => {},
                    else => return error.OutOfMemory,
                }
            }
            var value = Value.object(&list.header);
            if (self.state.dict_mode) value = (try makeDictRow(Runtime, self.runtime, self.state, value, self.line, self.column)) orelse return;
            item_root.object = value.asObject();
            try self.state.pending.append(self.runtime.heap.allocator, value);
        }
    };
}

fn makeDictRow(comptime Runtime: type, self: *Runtime, state: *ReaderState, row_value: Value, line: u32, column: u32) !?Value {
    const row = sequence.listFromHeader(row_value.asObject() orelse return error.RuntimeFailure) orelse return error.RuntimeFailure;
    if (state.fieldnames.tag() == .none) {
        state.fieldnames = row_value;
        return null;
    }
    const names = sequenceItems(state.fieldnames) orelse return error.RuntimeFailure;
    const mapping = switch (dict_module.create(&self.heap, false)) {
        .value => |created| created,
        else => return error.OutOfMemory,
    };
    var mapping_root = gc.Root{ .object = &mapping.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&mapping_root);
    defer roots.pop();
    for (names, 0..) |key, index| {
        const value = if (index < row.items.items.len) row.items.items[index] else state.restval;
        if (!self.setMappingValue(mapping, key, value, line, column)) return error.RuntimeFailure;
    }
    if (row.items.items.len > names.len) {
        const extras = switch (sequence.createList(&self.heap, row.items.items[names.len..])) {
            .value => |created| created,
            else => return error.OutOfMemory,
        };
        var extras_root = gc.Root{ .object = &extras.header };
        roots.add(&extras_root);
        if (!self.setMappingValue(mapping, state.restkey, Value.object(&extras.header), line, column)) return error.RuntimeFailure;
    }
    return Value.object(&mapping.header);
}

fn writerow(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, row: Value, line: u32, column: u32) bool {
    const object = objectFromValue(receiver) orelse return self.engineFault();
    const state = writerState(object) orelse return self.engineFault();
    if (state.dict_mode) return dictWriterow(Runtime, self, destination, object, state, row, line, column);
    return startWriterRow(Runtime, self, destination, object, row, line, column);
}

fn startWriterRow(comptime Runtime: type, self: *Runtime, destination: u16, object: *types.NativeObject, row: Value, line: u32, column: u32) bool {
    const iterator_value = switch (self.createVmIterator(row, line, column)) {
        .value => |iterator| Value.object(&iterator.header),
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var roots_array = [_]gc.Root{ .{ .object = &object.header }, .{ .object = iterator_value.asObject() } };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const payload = self.heap.allocator.create(WriterTaskPayload) catch return memoryFailure(self, line, column);
    payload.* = .{ .allocator = self.heap.allocator };
    const caller = self.top_frame orelse {
        destroyWriterTask(payload, self.heap.allocator);
        return self.engineFault();
    };
    const task = types.createTask(&self.heap, self.currentNativeTask(), .csv, 301, @ptrCast(caller), destination, line, column, &.{ Value.object(&object.header), iterator_value }, writerTaskOps(Runtime)) catch {
        destroyWriterTask(payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn writerTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const payload: *WriterTaskPayload = @ptrCast(@alignCast(task.payload orelse return runtimeTaskError("invalid CSV writer task")));
            const object = objectFromValue(task.inputs[0]) orelse return runtimeTaskError("invalid CSV writer receiver");
            const state = writerState(object) orelse return runtimeTaskError("invalid CSV writer state");
            if (payload.phase == .call) {
                if (!task.child_ready) return .yield;
                if (task.child_error != null) return .propagate;
                return .{ .complete = task.child_value };
            }
            if (task.child_ready) {
                if (task.child_error != null) return .propagate;
                if (task.child_done) {
                    const fields = self.heap.allocator.alloc(WriteField, payload.fields.items.len) catch return .{ .raise = exceptions.memoryError() };
                    defer self.heap.allocator.free(fields);
                    for (payload.fields.items, 0..) |field, index| fields[index] = .{ .text = field.text, .numeric = field.numeric };
                    const encoded = writeRow(self.heap.allocator, state.dialect, fields) catch return .{ .raise = .{ .kind = .value_error, .message = "CSV row serialization failed", .native_class = state.error_class } };
                    defer self.heap.allocator.free(encoded);
                    payload.call_args[0] = self.createStringValue(encoded, task.line, task.column) orelse return currentExceptionTask(self);
                    payload.phase = .call;
                    task.child_ready = false;
                    return .{ .call = .{ .callable = state.write_method, .positional = &payload.call_args } };
                }
                const field = renderField(self, task.child_value, task.line, task.column) orelse return currentExceptionTask(self);
                payload.fields.append(payload.allocator, field) catch {
                    payload.allocator.free(field.text);
                    return .{ .raise = exceptions.memoryError() };
                };
                task.child_ready = false;
                task.child_value = Value.noneValue();
            }
            return .{ .next = task.inputs[1] };
        }
        const ops = types.TaskOps{ .step = step, .trace_payload = traceWriterTask, .destroy_payload = destroyWriterTask };
    }.ops;
}

fn renderField(self: anytype, value: Value, line: u32, column: u32) ?OwnedWriteField {
    if (value.tag() == .none) return .{ .text = self.heap.allocator.dupe(u8, "") catch return null, .numeric = false };
    if (self.valueString(value)) |text| return .{ .text = self.heap.allocator.dupe(u8, text) catch return null, .numeric = false };
    const numeric = number.isIntegerValue(value) or value.asFloat() != null;
    const text = self.renderValueOwned(value, false, line, column) orelse return null;
    return .{ .text = text, .numeric = numeric };
}

fn writerows(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, rows: Value, line: u32, column: u32) bool {
    const object = objectFromValue(receiver) orelse return self.engineFault();
    _ = writerState(object) orelse return self.engineFault();
    const iterator_value = switch (self.createVmIterator(rows, line, column)) {
        .value => |iterator| Value.object(&iterator.header),
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    const method = boundMethod(self, 101, receiver, line, column) orelse return false;
    var roots_array = [_]gc.Root{ .{ .object = receiver.asObject() }, .{ .object = iterator_value.asObject() }, .{ .object = method.asObject() } };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    for (&roots_array) |*root| roots.add(root);
    defer roots.pop();
    const caller = self.top_frame orelse return self.engineFault();
    const payload = self.heap.allocator.create(WriterowsPayload) catch return memoryFailure(self, line, column);
    payload.* = .{};
    const task = types.createTask(&self.heap, self.currentNativeTask(), .csv, 302, @ptrCast(caller), destination, line, column, &.{ receiver, iterator_value, method }, writerowsTaskOps()) catch {
        self.heap.allocator.destroy(payload);
        return memoryFailure(self, line, column);
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn writerowsTaskOps() *const types.TaskOps {
    return &struct {
        fn step(_: *anyopaque, task: *types.Task) types.TaskStep {
            const payload: *WriterowsPayload = @ptrCast(@alignCast(task.payload orelse return runtimeTaskError("invalid writerows task")));
            if (task.child_ready) {
                if (task.child_error != null) return .propagate;
                if (payload.waiting_call) {
                    payload.waiting_call = false;
                    payload.row_args[0] = Value.noneValue();
                    task.child_ready = false;
                    task.child_value = Value.noneValue();
                    return .{ .next = task.inputs[1] };
                }
                if (task.child_done) return .{ .complete = Value.noneValue() };
                payload.waiting_call = true;
                payload.row_args[0] = task.child_value;
                task.child_ready = false;
                return .{ .call = .{ .callable = task.inputs[2], .positional = &payload.row_args } };
            }
            return .{ .next = task.inputs[1] };
        }
        fn trace(raw: ?*anyopaque, tracer: *gc.Tracer) void {
            const payload: *WriterowsPayload = @ptrCast(@alignCast(raw orelse return));
            tracer.visit(payload.row_args[0].asObject());
        }
        fn destroy(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
            const payload: *WriterowsPayload = @ptrCast(@alignCast(raw orelse return));
            allocator.destroy(payload);
        }
        const ops = types.TaskOps{ .step = step, .trace_payload = trace, .destroy_payload = destroy };
    }.ops;
}

fn dictWriterow(comptime Runtime: type, self: *Runtime, destination: u16, object: *types.NativeObject, state: *WriterState, row_value: Value, line: u32, column: u32) bool {
    const mapping = dict_module.dictFromHeader(row_value.asObject() orelse return self.nativeTypeError(line, column, "dict row must be a mapping")) orelse return self.nativeTypeError(line, column, "dict row must be a mapping");
    const names = sequenceItems(state.fieldnames) orelse return self.engineFault();
    if (!state.extras_ignore) for (mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        var found = false;
        for (names) |name| {
            const equal = self.valuesEqual(entry.key, name, line, column) orelse return false;
            if (equal) { found = true; break; }
        }
        if (!found) {
            self.setException(.{ .kind = .value_error, .message = "dict contains fields not in fieldnames" }, line, column, null);
            return false;
        }
    };
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
    for (names) |key| {
        const hash = self.pythonHash(key, line, column) orelse return false;
        var equality = EqualityContext(Runtime){ .runtime = self, .line = line, .column = column };
        const value = switch (dict_module.get(mapping, key, hash, &equality, equalityThunk(Runtime))) {
            .value => |found| found,
            .missing => state.restval,
            .failed => return false,
        };
        switch (sequence.append(&self.heap, list, value)) {
            .value => {},
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        }
    }
    return startWriterRow(Runtime, self, destination, object, Value.object(&list.header), line, column);
}

fn writeheader(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, line: u32, column: u32) bool {
    const object = objectFromValue(receiver) orelse return self.engineFault();
    const state = writerState(object) orelse return self.engineFault();
    if (!state.dict_mode) return self.nativeAttributeError(line, column, "writer has no writeheader method");
    return startWriterRow(Runtime, self, destination, object, state.fieldnames, line, column);
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    if (readerState(object)) |state| {
        if (std.mem.eql(u8, name, "line_num")) return Value.fromSmallInt(@intCast(state.core.line_num));
        if (state.dict_mode and std.mem.eql(u8, name, "fieldnames")) return state.fieldnames;
        return null;
    }
    if (writerState(object)) |state| {
        if (state.dict_mode and std.mem.eql(u8, name, "fieldnames")) return state.fieldnames;
        const id: ?u16 = if (std.mem.eql(u8, name, "writerow")) 101 else if (std.mem.eql(u8, name, "writerows")) 102 else if (state.dict_mode and std.mem.eql(u8, name, "writeheader")) 201 else null;
        return if (id) |method_id| boundMethod(self, method_id, Value.object(&object.header), line, column) else null;
    }
    return null;
}

fn normalizeFieldnames(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?Value {
    if (value.tag() == .none) return null;
    if (sequence.listFromHeader(value.asObject() orelse return null) != null) return value;
    const items = sequenceItems(value) orelse {
        _ = self.nativeTypeError(line, column, "fieldnames must be an iterable of strings");
        return null;
    };
    return switch (sequence.createList(&self.heap, items)) {
        .value => |list| Value.object(&list.header),
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

fn sequenceItems(value: Value) ?[]const Value {
    const header = value.asObject() orelse return null;
    if (sequence.listFromHeader(header)) |list| return list.items.items;
    if (sequence.tupleFromHeader(header)) |tuple| return tuple.items;
    return null;
}

fn EqualityContext(comptime Runtime: type) type { return struct { runtime: *Runtime, line: u32, column: u32 }; }

fn equalityThunk(comptime Runtime: type) dict_module.EqualityFn {
    return struct {
        fn equal(raw: *anyopaque, left: Value, right: Value) ?bool {
            const context: *EqualityContext(Runtime) = @ptrCast(@alignCast(raw));
            return context.runtime.valuesEqual(left, right, context.line, context.column);
        }
    }.equal;
}

fn boundMethod(self: anytype, id: u16, receiver: Value, line: u32, column: u32) ?Value {
    return switch (functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.csv), id, receiver)) {
        .value => |function| Value.object(&function.header),
        .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk null; },
    };
}

fn moduleState(value: Value) ?*ModuleState {
    const header = value.asObject() orelse return null;
    if (header.kind != &module_state_kind) return null;
    return @ptrCast(@alignCast(header));
}

fn objectFromValue(value: Value) ?*types.NativeObject { return types.fromHeader(value.asObject() orelse return null); }

fn readerState(object: *types.NativeObject) ?*ReaderState {
    if (object.type_id != .csv_reader and object.type_id != .csv_dict_reader) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn writerState(object: *types.NativeObject) ?*WriterState {
    if (object.type_id != .csv_writer and object.type_id != .csv_dict_writer) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn traceModuleState(header: *gc.Header, tracer: *gc.Tracer) void {
    const state: *ModuleState = @ptrCast(@alignCast(header));
    tracer.visit(&state.error_class.header);
}

fn traceReader(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const state: *ReaderState = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(state.source.asObject());
    tracer.visit(&state.error_class.header);
    tracer.visit(state.fieldnames.asObject());
    tracer.visit(state.restkey.asObject());
    tracer.visit(state.restval.asObject());
    for (state.dialect_values) |value| tracer.visit(value.asObject());
    for (state.pending.items) |value| tracer.visit(value.asObject());
}

fn destroyReader(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *ReaderState = @ptrCast(@alignCast(raw orelse return));
    state.core.deinit();
    state.pending.deinit(allocator);
    allocator.destroy(state);
}

fn traceWriter(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const state: *WriterState = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(state.target.asObject());
    tracer.visit(state.write_method.asObject());
    tracer.visit(&state.error_class.header);
    tracer.visit(state.fieldnames.asObject());
    tracer.visit(state.restval.asObject());
    for (state.dialect_values) |value| tracer.visit(value.asObject());
}

fn destroyWriter(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *WriterState = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(state);
}

fn traceWriterTask(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const payload: *WriterTaskPayload = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(payload.call_args[0].asObject());
}

fn destroyWriterTask(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *WriterTaskPayload = @ptrCast(@alignCast(raw orelse return));
    for (payload.fields.items) |field| if (field.text.len != 0) allocator.free(field.text);
    payload.fields.deinit(allocator);
    allocator.destroy(payload);
}

fn readerTaskFailure(self: anytype, state: *ReaderState, line: u32, column: u32) types.TaskStep {
    state.active = false;
    if (self.last_exception) |exception| return .{ .raise = exception };
    _ = line;
    _ = column;
    return .{ .raise = .{ .kind = .value_error, .message = "CSV parse error", .native_class = state.error_class } };
}

fn csvFailure(self: anytype, class: *exceptions.ExceptionClass, message: []const u8, line: u32, column: u32) bool {
    self.setException(.{ .kind = .exception, .message = message, .native_class = class }, line, column, null);
    return false;
}

fn currentExceptionTask(self: anytype) types.TaskStep { return .{ .raise = self.last_exception orelse exceptions.memoryError() }; }
fn runtimeTaskError(message: []const u8) types.TaskStep { return .{ .raise = .{ .kind = .runtime_error, .message = message } }; }
fn memoryFailure(self: anytype, line: u32, column: u32) bool { self.setException(exceptions.memoryError(), line, column, null); return false; }

test "reader core handles multiline quotes CRLF Unicode and empty fields" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        rows: std.ArrayList([]u8) = .empty,
        lines: std.ArrayList(usize) = .empty,

        fn row(self: *@This(), fields: []const Field, line_num: usize) !void {
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(self.allocator);
            for (fields, 0..) |field, index| {
                if (index != 0) try joined.append(self.allocator, '|');
                try joined.appendSlice(self.allocator, field.text);
                try joined.append(self.allocator, if (field.quoted) 'Q' else 'U');
            }
            try self.rows.append(self.allocator, try joined.toOwnedSlice(self.allocator));
            try self.lines.append(self.allocator, line_num);
        }

        fn deinit(self: *@This()) void {
            for (self.rows.items) |row_text| self.allocator.free(row_text);
            self.rows.deinit(self.allocator);
            self.lines.deinit(self.allocator);
        }
    };
    var collector = Collector{ .allocator = std.testing.allocator };
    defer collector.deinit();
    var reader = try ReaderCore.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feedItem("a,\"b\n", &collector);
    try reader.feedItem("c\",d\r\n", &collector);
    try reader.feedItem(",,\"雪\"\n", &collector);
    try std.testing.expectEqual(@as(usize, 2), collector.rows.items.len);
    try std.testing.expectEqualStrings("aU|b\ncQ|dU", collector.rows.items[0]);
    try std.testing.expectEqual(@as(usize, 2), collector.lines.items[0]);
    try std.testing.expectEqualStrings("U|U|雪Q", collector.rows.items[1]);
}

test "reader core accepts one-codepoint Unicode delimiter and doubled quote" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        result: []u8 = &.{},
        fn row(self: *@This(), fields: []const Field, _: usize) !void {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            for (fields, 0..) |field, index| {
                if (index != 0) try output.append(self.allocator, '|');
                try output.appendSlice(self.allocator, field.text);
            }
            self.result = try output.toOwnedSlice(self.allocator);
        }
    };
    var collector = Collector{ .allocator = std.testing.allocator };
    defer if (collector.result.len != 0) std.testing.allocator.free(collector.result);
    var reader = try ReaderCore.init(std.testing.allocator, .{ .delimiter = "§" });
    defer reader.deinit();
    try reader.feedItem("雪§\"x\"\"y\"\n", &collector);
    try std.testing.expectEqualStrings("雪|x\"y", collector.result);
}

test "writer core quotes minimally all and nonnumeric" {
    const fields = [_]WriteField{
        .{ .text = "a", .numeric = false },
        .{ .text = "b,c", .numeric = false },
        .{ .text = "x\"y", .numeric = false },
    };
    const minimal = try writeRow(std.testing.allocator, .{ .line_terminator = "\n" }, &fields);
    defer std.testing.allocator.free(minimal);
    try std.testing.expectEqualStrings("a,\"b,c\",\"x\"\"y\"\n", minimal);

    const values = [_]WriteField{ .{ .text = "1", .numeric = true }, .{ .text = "雪", .numeric = false } };
    const nonnumeric = try writeRow(std.testing.allocator, .{ .quoting = .nonnumeric, .line_terminator = "\n" }, &values);
    defer std.testing.allocator.free(nonnumeric);
    try std.testing.expectEqualStrings("1,\"雪\"\n", nonnumeric);

    const empty = [_]WriteField{.{ .text = "" }};
    const single_empty = try writeRow(std.testing.allocator, .{ .line_terminator = "\n" }, &empty);
    defer std.testing.allocator.free(single_empty);
    try std.testing.expectEqualStrings("\"\"\n", single_empty);
}

test "reader core completes unterminated final quoted record and empty source items" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        rows: std.ArrayList([]u8) = .empty,
        fn row(self: *@This(), fields: []const Field, _: usize) !void {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            for (fields, 0..) |field, index| {
                if (index != 0) try output.append(self.allocator, '|');
                try output.appendSlice(self.allocator, field.text);
            }
            try self.rows.append(self.allocator, try output.toOwnedSlice(self.allocator));
        }
        fn deinit(self: *@This()) void {
            for (self.rows.items) |row_text| if (row_text.len != 0) self.allocator.free(row_text);
            self.rows.deinit(self.allocator);
        }
    };
    var collector = Collector{ .allocator = std.testing.allocator };
    defer collector.deinit();
    var reader = try ReaderCore.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feedItem("", &collector);
    try reader.feedItem("\"unfinished", &collector);
    try reader.finish(&collector);
    try std.testing.expectEqual(@as(usize, 2), collector.rows.items.len);
    try std.testing.expectEqualStrings("", collector.rows.items[0]);
    try std.testing.expectEqualStrings("unfinished", collector.rows.items[1]);
}
