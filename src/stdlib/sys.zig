const std = @import("std");
const gc = @import("runtime_gc");
const binder = @import("runtime_binder");
const functions_module = @import("runtime_function");
const sequence = @import("runtime_sequence");
const types = @import("types.zig");

const Value = types.Value;

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "exit", .params = &.{.{ .name = "code", .default = .none }} },
    .{ .id = 2, .name = "write", .params = &.{.{ .name = "text", .flags = binder.parameter_flags_module.positional_only }} },
    .{ .id = 3, .name = "flush" },
};

const StreamState = struct { stderr: bool };

fn destroyStream(payload: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *StreamState = @ptrCast(@alignCast(payload orelse return));
    allocator.destroy(state);
}

fn store(comptime Runtime: type, self: *Runtime, environment: *gc.Header, name: []const u8, value: Value, line: u32, column: u32) bool {
    var root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    if (self.environmentStore(environment, name, value)) return true;
    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
    return false;
}

fn storeText(comptime Runtime: type, self: *Runtime, environment: *gc.Header, name: []const u8, content: []const u8, line: u32, column: u32) bool {
    const value = self.createStringValue(content, line, column) orelse return false;
    return store(Runtime, self, environment, name, value, line, column);
}

fn storeFunction(comptime Runtime: type, self: *Runtime, environment: *gc.Header, name: []const u8, id: u16, line: u32, column: u32) bool {
    const result = functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.sys), id, Value.noneValue());
    const function = switch (result) {
        .value => |selected| selected,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    };
    return store(Runtime, self, environment, name, Value.object(&function.header), line, column);
}

fn storeStream(comptime Runtime: type, self: *Runtime, environment: *gc.Header, name: []const u8, is_stderr: bool, line: u32, column: u32) bool {
    const class = self.ensureNativeClass(.sys_stream, "TextIO", line, column) orelse return false;
    const object = types.createObject(&self.heap, class, .sys_stream) catch {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return false;
    };
    var object_root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&object_root);
    defer roots.pop();
    const state = self.heap.allocator.create(StreamState) catch {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return false;
    };
    state.* = .{ .stderr = is_stderr };
    object.payload = state;
    object.destroy_payload = destroyStream;
    return store(Runtime, self, environment, name, Value.object(&object.header), line, column);
}

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const cache = self.moduleCache() orelse return self.engineFault();
    if (!store(Runtime, self, environment, "modules", Value.object(&cache.header), line, column)) return false;
    if (!storeText(Runtime, self, environment, "platform", "peony", line, column)) return false;
    if (!storeText(Runtime, self, environment, "version", "Peony 0.1 (Python 3.12 language subset)", line, column)) return false;
    if (!storeFunction(Runtime, self, environment, "exit", 1, line, column)) return false;
    if (!storeStream(Runtime, self, environment, "stdout", false, line, column)) return false;
    if (!storeStream(Runtime, self, environment, "stderr", true, line, column)) return false;

    const filename = if (self.code) |code| code.filename else "<string>";
    const filename_value = self.createStringValue(filename, line, column) orelse return false;
    var filename_root = gc.Root{ .object = filename_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&filename_root);
    defer roots.pop();
    const argv = switch (sequence.createList(&self.heap, &.{filename_value})) {
        .value => |list| list,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var argv_root = gc.Root{ .object = &argv.header };
    var argument_root = gc.Root{ .object = null };
    var argv_frame = gc.RootFrame{};
    argv_frame.push(&self.heap.roots);
    argv_frame.add(&argv_root);
    argv_frame.add(&argument_root);
    defer argv_frame.pop();
    for (self.argv_items.items) |argument| {
        const value = self.createStringValue(argument, line, column) orelse return false;
        argument_root.object = value.asObject();
        switch (sequence.append(&self.heap, argv, value)) {
            .value => {},
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        }
        argument_root.object = null;
    }
    if (!store(Runtime, self, environment, "argv", Value.object(&argv.header), line, column)) return false;

    const path_texts = [_][]const u8{ "/home", "/course", "/tmp" };
    var path_values: [path_texts.len]Value = undefined;
    var path_roots: [path_texts.len]gc.Root = @splat(.{ .object = null });
    var path_frame = gc.RootFrame{};
    path_frame.push(&self.heap.roots);
    for (&path_roots) |*root| path_frame.add(root);
    defer path_frame.pop();
    for (path_texts, 0..) |text, index| {
        path_values[index] = self.createStringValue(text, line, column) orelse return false;
        path_roots[index].object = path_values[index].asObject();
    }
    const path = switch (sequence.createList(&self.heap, &path_values)) {
        .value => |list| list,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    if (!store(Runtime, self, environment, "path", Value.object(&path.header), line, column)) return false;

    const implementation_class = self.ensureNativeClass(.implementation, "implementation", line, column) orelse return false;
    const implementation = types.createObject(&self.heap, implementation_class, .implementation) catch {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return false;
    };
    if (!store(Runtime, self, environment, "implementation", Value.object(&implementation.header), line, column)) return false;

    const version_class = self.ensureNativeClass(.version_info, "version_info", line, column) orelse return false;
    const version = types.createObject(&self.heap, version_class, .version_info) catch {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return false;
    };
    return store(Runtime, self, environment, "version_info", Value.object(&version.header), line, column);
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    switch (object.type_id) {
        .sys_stream => {
            const id: u16 = if (std.mem.eql(u8, name, "write")) 2 else if (std.mem.eql(u8, name, "flush")) 3 else return null;
            const created = functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.sys), id, Value.object(&object.header));
            return switch (created) {
                .value => |function| Value.object(&function.header),
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk null;
                },
            };
        },
        .implementation => {
            if (std.mem.eql(u8, name, "name")) return self.createStringValue("peony", line, column);
            if (std.mem.eql(u8, name, "version")) return versionTuple(Runtime, self, 0, line, column);
            return null;
        },
        .version_info => {
            if (std.mem.eql(u8, name, "major")) return Value.fromSmallInt(3);
            if (std.mem.eql(u8, name, "minor")) return Value.fromSmallInt(12);
            if (std.mem.eql(u8, name, "micro")) return Value.fromSmallInt(0);
            if (std.mem.eql(u8, name, "releaselevel")) return self.createStringValue("final", line, column);
            if (std.mem.eql(u8, name, "serial")) return Value.fromSmallInt(0);
            return null;
        },
        else => return null,
    }
}

fn versionTuple(comptime Runtime: type, self: *Runtime, _: u8, line: u32, column: u32) ?Value {
    const values = [_]Value{ Value.fromSmallInt(0).?, Value.fromSmallInt(1).?, Value.fromSmallInt(0).? };
    return switch (sequence.createTuple(&self.heap, &values)) {
        .value => |tuple| Value.object(&tuple.header),
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

pub fn writePrint(
    comptime Runtime: type,
    self: *Runtime,
    object: *types.NativeObject,
    values: []const Value,
    separator: []const u8,
    ending: []const u8,
    line: u32,
    column: u32,
) bool {
    if (object.type_id != .sys_stream) return self.engineFault();
    const state: *StreamState = @ptrCast(@alignCast(object.payload orelse return self.engineFault()));
    if (!state.stderr) return self.executePrintValues(values, separator, ending, line, column);
    for (values, 0..) |value, index| {
        if (index != 0 and !self.appendStderr(separator)) break;
        const rendered = self.renderValueOwned(value, false, line, column) orelse return false;
        defer self.heap.allocator.free(rendered);
        if (!self.appendStderr(rendered)) break;
    } else {
        if (self.appendStderr(ending)) return true;
    }
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
    switch (function_id) {
        1 => {
            self.setException(.{ .kind = .system_exit, .message = "" }, line, column, null);
            if (self.active_exception) |exception| exception.value = args[0];
            return false;
        },
        2 => {
            const header = receiver.asObject() orelse return self.engineFault();
            const object = types.fromHeader(header) orelse return self.engineFault();
            if (object.type_id != .sys_stream) return self.engineFault();
            const state: *StreamState = @ptrCast(@alignCast(object.payload orelse return self.engineFault()));
            const content = self.valueString(args[0]) orelse return self.nativeTypeError(line, column, "write() argument must be str");
            const ok = if (state.stderr) self.appendStderr(content) else self.appendOutput(content);
            if (!ok) {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
            const count = std.unicode.utf8CountCodepoints(content) catch return self.engineFault();
            const value = Value.fromSmallInt(@intCast(count)) orelse return self.engineFault();
            self.setRegister(destination, value);
            return true;
        },
        3 => {
            self.setRegister(destination, Value.noneValue());
            return self.beginOutputEvent(line, column);
        },
        else => return self.engineFault(),
    }
}
