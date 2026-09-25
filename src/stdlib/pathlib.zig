const std = @import("std");
const binder = @import("runtime_binder");
const bytes_module = @import("runtime_bytes");
const exceptions = @import("runtime_exception");
const file_module = @import("runtime_file");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const types = @import("types.zig");
const vfs_module = @import("runtime_vfs");

const Value = types.Value;

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "__Path_constructor", .params = &.{.{ .name = "segments", .flags = binder.parameter_flags_module.var_positional }}, .exported = false },
    methodSpec(101, "exists"),
    methodSpec(102, "is_file"),
    methodSpec(103, "is_dir"),
    methodSpec(104, "read_text"),
    .{ .id = 105, .name = "write_text", .params = &.{.{ .name = "data" }}, .exported = false },
    methodSpec(106, "read_bytes"),
    .{ .id = 107, .name = "write_bytes", .params = &.{.{ .name = "data" }}, .exported = false },
    .{ .id = 108, .name = "mkdir", .params = &.{
        .{ .name = "mode", .default = .{ .integer = 0o777 } },
        .{ .name = "parents", .flags = binder.parameter_flags_module.keyword_only, .default = .{ .boolean = false } },
        .{ .name = "exist_ok", .flags = binder.parameter_flags_module.keyword_only, .default = .{ .boolean = false } },
    }, .exported = false },
    methodSpec(109, "iterdir"),
};

pub const classes = [_]types.TypeSpec{
    .{ .type_id = .path, .module = .pathlib, .name = "Path", .constructor_id = 1 },
};

fn methodSpec(comptime id: u16, comptime method_name: []const u8) types.FunctionSpec {
    return .{ .id = id, .name = method_name, .exported = false };
}

/// Native Path payload data. The Runtime adapter owns one of these through a
/// `types.NativeObject`; VFS normalization is deliberately deferred until an
/// actual filesystem operation.
pub const PathData = struct {
    text: []u8,

    pub fn deinit(self: *PathData, allocator: std.mem.Allocator) void {
        if (self.text.len != 0) allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn construct(allocator: std.mem.Allocator, segments: []const []const u8) !PathData {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    if (segments.len == 0) return .{ .text = try allocator.dupe(u8, ".") };
    for (segments) |segment| {
        if (!std.unicode.utf8ValidateSlice(segment)) return error.InvalidUtf8;
        if (segment.len != 0 and segment[0] == '/') raw.clearRetainingCapacity();
        if (raw.items.len != 0 and raw.items[raw.items.len - 1] != '/') try raw.append(allocator, '/');
        try raw.appendSlice(allocator, segment);
    }
    return .{ .text = try normalizeLexical(allocator, raw.items) };
}

pub fn join(allocator: std.mem.Allocator, base: []const u8, child: []const u8) !PathData {
    return construct(allocator, &.{ base, child });
}

pub fn name(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, ".") or isAnchor(path)) return "";
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

pub fn suffix(path: []const u8) []const u8 {
    const basename = name(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return "";
    if (dot == 0 or dot + 1 == basename.len) return "";
    return basename[dot..];
}

pub fn stem(path: []const u8) []const u8 {
    const basename = name(path);
    const ending = suffix(path);
    return if (ending.len == 0) basename else basename[0 .. basename.len - ending.len];
}

pub fn parent(allocator: std.mem.Allocator, path: []const u8) !PathData {
    if (std.mem.eql(u8, path, ".") or isAnchor(path)) return .{ .text = try allocator.dupe(u8, path) };
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .text = try allocator.dupe(u8, ".") };
    if (slash == 0) return .{ .text = try allocator.dupe(u8, "/") };
    if (slash == 1 and path[0] == '/' and path[1] == '/') return .{ .text = try allocator.dupe(u8, "//") };
    return .{ .text = try allocator.dupe(u8, path[0..slash]) };
}

fn normalizeLexical(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const leading = countLeadingSlashes(raw);
    const anchor: []const u8 = if (leading == 2) "//" else if (leading != 0) "/" else "";
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, raw[leading..], '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        try components.append(allocator, component);
    }
    if (anchor.len == 0 and components.items.len == 0) return allocator.dupe(u8, ".");
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, anchor);
    for (components.items, 0..) |component, index| {
        if (index != 0 or (output.items.len != 0 and output.items[output.items.len - 1] != '/')) try output.append(allocator, '/');
        try output.appendSlice(allocator, component);
    }
    return output.toOwnedSlice(allocator);
}

fn countLeadingSlashes(path: []const u8) usize {
    var count: usize = 0;
    while (count < path.len and path[count] == '/') count += 1;
    return count;
}

fn isAnchor(path: []const u8) bool {
    return std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "//");
}

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const class = self.ensureNativeClass(.path, "Path", line, column) orelse return false;
    if (self.environmentStore(environment, "Path", Value.object(&class.header))) return true;
    self.setException(exceptions.memoryError(), line, column, null);
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
    if (function_id == 1) return constructPath(Runtime, self, destination, args[0], line, column);
    const state = stateFromValue(receiver) orelse return self.engineFault();
    return switch (function_id) {
        101 => storeBoolean(self, destination, self.vfs.exists(state.text)),
        102 => storeBoolean(self, destination, isFile(self, state.text)),
        103 => storeBoolean(self, destination, isDirectory(self, state.text)),
        104 => readText(self, destination, state.text, line, column),
        105 => writeText(self, destination, state.text, args[0], line, column),
        106 => readBytes(self, destination, state.text, line, column),
        107 => writeBytes(self, destination, state.text, args[0], line, column),
        108 => makeDirectory(Runtime, self, destination, state.text, args, line, column),
        109 => iterateDirectory(Runtime, self, destination, state.text, line, column),
        else => self.engineFault(),
    };
}

fn constructPath(comptime Runtime: type, self: *Runtime, destination: u16, tuple_value: Value, line: u32, column: u32) bool {
    const tuple = sequence.tupleFromHeader(tuple_value.asObject() orelse return self.engineFault()) orelse return self.engineFault();
    const segments = self.heap.allocator.alloc([]const u8, tuple.items.len) catch return memoryFailure(self, line, column);
    defer self.heap.allocator.free(segments);
    for (tuple.items, 0..) |value, index| {
        segments[index] = self.valueString(value) orelse pathText(value) orelse return self.nativeTypeError(line, column, "Path segments must be str or Path");
    }
    const data = construct(self.heap.allocator, segments) catch |err| return pathDataFailure(self, err, line, column);
    return storePathData(Runtime, self, destination, data, line, column);
}

fn storePathData(comptime Runtime: type, self: *Runtime, destination: u16, data: PathData, line: u32, column: u32) bool {
    var owned = data;
    const class = self.ensureNativeClass(.path, "Path", line, column) orelse {
        owned.deinit(self.heap.allocator);
        return false;
    };
    const object = types.createObject(&self.heap, class, .path) catch {
        owned.deinit(self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    var object_root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&object_root);
    defer roots.pop();
    const state = self.heap.allocator.create(PathData) catch {
        owned.deinit(self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    state.* = owned;
    object.payload = state;
    object.destroy_payload = destroyPath;
    object.ops = pathOps(Runtime);
    self.setRegister(destination, Value.object(&object.header));
    return true;
}

fn createPathValue(comptime Runtime: type, self: *Runtime, text: []const u8, line: u32, column: u32) ?Value {
    var data = PathData{ .text = self.heap.allocator.dupe(u8, text) catch {
        _ = memoryFailure(self, line, column);
        return null;
    } };
    const class = self.ensureNativeClass(.path, "Path", line, column) orelse {
        data.deinit(self.heap.allocator);
        return null;
    };
    const object = types.createObject(&self.heap, class, .path) catch {
        data.deinit(self.heap.allocator);
        _ = memoryFailure(self, line, column);
        return null;
    };
    var object_root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&object_root);
    defer roots.pop();
    const state = self.heap.allocator.create(PathData) catch {
        data.deinit(self.heap.allocator);
        _ = memoryFailure(self, line, column);
        return null;
    };
    state.* = data;
    object.payload = state;
    object.destroy_payload = destroyPath;
    object.ops = pathOps(Runtime);
    return Value.object(&object.header);
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, attribute: []const u8, line: u32, column: u32) ?Value {
    const state = stateFromObject(object) orelse return null;
    if (std.mem.eql(u8, attribute, "name")) return self.createStringValue(name(state.text), line, column);
    if (std.mem.eql(u8, attribute, "suffix")) return self.createStringValue(suffix(state.text), line, column);
    if (std.mem.eql(u8, attribute, "stem")) return self.createStringValue(stem(state.text), line, column);
    if (std.mem.eql(u8, attribute, "parent")) {
        var parent_data = parent(self.heap.allocator, state.text) catch {
            _ = memoryFailure(self, line, column);
            return null;
        };
        const parent_text = parent_data.text;
        parent_data.text = &.{};
        defer if (parent_text.len != 0) self.heap.allocator.free(parent_text);
        return createPathValue(Runtime, self, parent_text, line, column);
    }
    const id: ?u16 = if (std.mem.eql(u8, attribute, "exists")) 101 else if (std.mem.eql(u8, attribute, "is_file")) 102 else if (std.mem.eql(u8, attribute, "is_dir")) 103 else if (std.mem.eql(u8, attribute, "read_text")) 104 else if (std.mem.eql(u8, attribute, "write_text")) 105 else if (std.mem.eql(u8, attribute, "read_bytes")) 106 else if (std.mem.eql(u8, attribute, "write_bytes")) 107 else if (std.mem.eql(u8, attribute, "mkdir")) 108 else if (std.mem.eql(u8, attribute, "iterdir")) 109 else null;
    return if (id) |method_id| boundMethod(self, method_id, Value.object(&object.header), line, column) else null;
}

pub fn pathText(value: Value) ?[]const u8 {
    const state = stateFromValue(value) orelse return null;
    return state.text;
}

fn readText(self: anytype, destination: u16, path: []const u8, line: u32, column: u32) bool {
    const content = self.vfs.read(path) catch |err| return vfsFailure(self, err, line, column);
    if (!std.unicode.utf8ValidateSlice(content)) {
        self.setException(.{ .kind = .unicode_decode_error, .message = "invalid UTF-8 data in file" }, line, column, null);
        return false;
    }
    const value = self.createStringValue(content, line, column) orelse return false;
    self.setRegister(destination, value);
    return true;
}

fn writeText(self: anytype, destination: u16, path: []const u8, value: Value, line: u32, column: u32) bool {
    const content = self.valueString(value) orelse return self.nativeTypeError(line, column, "write_text() data must be str");
    self.vfs.write(path, content, .replace) catch |err| return vfsFailure(self, err, line, column);
    const count = std.unicode.utf8CountCodepoints(content) catch unreachable;
    return self.setSmallInt(destination, count, line, column);
}

fn readBytes(self: anytype, destination: u16, path: []const u8, line: u32, column: u32) bool {
    const content = self.vfs.read(path) catch |err| return vfsFailure(self, err, line, column);
    return switch (bytes_module.create(&self.heap, content)) {
        .value => |bytes| blk: {
            self.setRegister(destination, Value.object(&bytes.header));
            break :blk true;
        },
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk false;
        },
        .engine_error => self.engineFault(),
    };
}

fn writeBytes(self: anytype, destination: u16, path: []const u8, value: Value, line: u32, column: u32) bool {
    const content = self.valueBytes(value) orelse return self.nativeTypeError(line, column, "write_bytes() data must be bytes");
    self.vfs.write(path, content, .replace) catch |err| return vfsFailure(self, err, line, column);
    return self.setSmallInt(destination, content.len, line, column);
}

fn makeDirectory(comptime Runtime: type, self: *Runtime, destination: u16, path: []const u8, args: []const Value, line: u32, column: u32) bool {
    if (!number.isIntegerValue(args[0])) return self.nativeTypeError(line, column, "mode must be an integer");
    const parents = args[1].asBool() orelse return self.nativeTypeError(line, column, "parents must be bool");
    const exist_ok = args[2].asBool() orelse return self.nativeTypeError(line, column, "exist_ok must be bool");
    self.vfs.mkdir(path, parents, exist_ok) catch |err| return vfsFailure(self, err, line, column);
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn iterateDirectory(comptime Runtime: type, self: *Runtime, destination: u16, base: []const u8, line: u32, column: u32) bool {
    const names = self.vfs.listDirectory(base) catch |err| return vfsFailure(self, err, line, column);
    defer if (names.len != 0) self.heap.allocator.free(names);
    const list = switch (sequence.createList(&self.heap, &.{})) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    var list_root = gc.Root{ .object = &list.header };
    var item_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&list_root);
    roots.add(&item_root);
    defer roots.pop();
    var cursor: usize = 0;
    while (cursor < names.len) {
        const end = std.mem.indexOfScalarPos(u8, names, cursor, 0) orelse names.len;
        var child = join(self.heap.allocator, base, names[cursor..end]) catch return memoryFailure(self, line, column);
        defer child.deinit(self.heap.allocator);
        const item = createPathValue(Runtime, self, child.text, line, column) orelse return false;
        item_root.object = item.asObject();
        switch (sequence.append(&self.heap, list, item)) {
            .value => {},
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        }
        cursor = end + 1;
    }
    const iterator = switch (self.createVmIterator(Value.object(&list.header), line, column)) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    self.setRegister(destination, Value.object(&iterator.header));
    return true;
}

fn isFile(self: anytype, path: []const u8) bool {
    const normalized = self.vfs.normalizeOwned(path) catch return false;
    defer self.heap.allocator.free(normalized);
    return self.vfs.existsNormalized(normalized) and !self.vfs.isDirectoryNormalized(normalized);
}

fn isDirectory(self: anytype, path: []const u8) bool {
    const normalized = self.vfs.normalizeOwned(path) catch return false;
    defer self.heap.allocator.free(normalized);
    return self.vfs.isDirectoryNormalized(normalized);
}

fn storeBoolean(self: anytype, destination: u16, enabled: bool) bool {
    self.setRegister(destination, if (enabled) Value.trueValue() else Value.falseValue());
    return true;
}

fn pathOps(comptime Runtime: type) *const types.NativeObjectOps {
    return &struct {
        fn string(context: *anyopaque, object: *types.NativeObject, line: u32, column: u32) ?[]u8 {
            const self: *Runtime = @ptrCast(@alignCast(context));
            _ = line;
            _ = column;
            const state = stateFromObject(object) orelse return null;
            return self.heap.allocator.dupe(u8, state.text) catch null;
        }
        fn representation(context: *anyopaque, object: *types.NativeObject, line: u32, column: u32) ?[]u8 {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return null;
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.heap.allocator);
            output.appendSlice(self.heap.allocator, "Path('") catch return representationMemory(self, line, column);
            for (state.text) |byte| switch (byte) {
                '\\' => output.appendSlice(self.heap.allocator, "\\\\") catch return representationMemory(self, line, column),
                '\'' => output.appendSlice(self.heap.allocator, "\\'") catch return representationMemory(self, line, column),
                '\n' => output.appendSlice(self.heap.allocator, "\\n") catch return representationMemory(self, line, column),
                '\r' => output.appendSlice(self.heap.allocator, "\\r") catch return representationMemory(self, line, column),
                '\t' => output.appendSlice(self.heap.allocator, "\\t") catch return representationMemory(self, line, column),
                else => output.append(self.heap.allocator, byte) catch return representationMemory(self, line, column),
            };
            output.appendSlice(self.heap.allocator, "')") catch return representationMemory(self, line, column);
            return output.toOwnedSlice(self.heap.allocator) catch {
                return representationMemory(self, line, column);
            };
        }
        fn hash(_: *anyopaque, object: *types.NativeObject, _: u32, _: u32) ?u64 {
            const state = stateFromObject(object) orelse return null;
            return std.hash.Wyhash.hash(0x5061_7468, state.text);
        }
        fn equals(_: *anyopaque, object: *types.NativeObject, other: Value, _: u32, _: u32) ?bool {
            const state = stateFromObject(object) orelse return null;
            const other_text = pathText(other) orelse return false;
            return std.mem.eql(u8, state.text, other_text);
        }
        fn binary(context: *anyopaque, object: *types.NativeObject, other: Value, operation: u8, reflected: bool, line: u32, column: u32) ?Value {
            if (operation != 3) return null;
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = stateFromObject(object) orelse return null;
            const other_text = self.valueString(other) orelse pathText(other) orelse return null;
            var combined = (if (reflected)
                join(self.heap.allocator, other_text, state.text)
            else
                join(self.heap.allocator, state.text, other_text)) catch {
                _ = memoryFailure(self, line, column);
                return null;
            };
            defer combined.deinit(self.heap.allocator);
            return createPathValue(Runtime, self, combined.text, line, column);
        }
        const ops = types.NativeObjectOps{ .str = string, .repr = representation, .hash = hash, .equals = equals, .binary = binary };
    }.ops;
}

fn representationMemory(self: anytype, line: u32, column: u32) ?[]u8 {
    _ = memoryFailure(self, line, column);
    return null;
}

fn boundMethod(self: anytype, id: u16, receiver: Value, line: u32, column: u32) ?Value {
    return switch (functions_module.createLibrary(&self.heap, @intFromEnum(types.ModuleId.pathlib), id, receiver)) {
        .value => |function| Value.object(&function.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
    };
}

fn stateFromValue(value: Value) ?*PathData {
    const object = types.fromHeader(value.asObject() orelse return null) orelse return null;
    return stateFromObject(object);
}

fn stateFromObject(object: *types.NativeObject) ?*PathData {
    if (object.type_id != .path) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn destroyPath(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *PathData = @ptrCast(@alignCast(raw orelse return));
    state.deinit(allocator);
    allocator.destroy(state);
}

fn vfsFailure(self: anytype, err: vfs_module.Error, line: u32, column: u32) bool {
    self.setException(file_module.pathException(err), line, column, null);
    return false;
}

fn pathDataFailure(self: anytype, err: anyerror, line: u32, column: u32) bool {
    if (err == error.OutOfMemory) return memoryFailure(self, line, column);
    return self.nativeTypeError(line, column, "invalid Path segment");
}

fn memoryFailure(self: anytype, line: u32, column: u32) bool {
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}

test "Path lexical construction retains dot-dot and normalizes separators" {
    var value = try construct(std.testing.allocator, &.{ "a", "..", "b.txt" });
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a/../b.txt", value.text);
    try std.testing.expectEqualStrings("b.txt", name(value.text));
    try std.testing.expectEqualStrings(".txt", suffix(value.text));
    try std.testing.expectEqualStrings("b", stem(value.text));
    var parent_value = try parent(std.testing.allocator, value.text);
    defer parent_value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a/..", parent_value.text);
}

test "Path absolute segments anchors and empty construction follow PurePosixPath" {
    const cases = [_]struct { segments: []const []const u8, expected: []const u8 }{
        .{ .segments = &.{ "/a", "/b" }, .expected = "/b" },
        .{ .segments = &.{ "a", "", ".", "b" }, .expected = "a/b" },
        .{ .segments = &.{ "//a", "b" }, .expected = "//a/b" },
        .{ .segments = &.{ "///a", "b" }, .expected = "/a/b" },
        .{ .segments = &.{ "", "" }, .expected = "." },
    };
    for (cases) |case| {
        var value = try construct(std.testing.allocator, case.segments);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, value.text);
    }
}

test "Path suffix and parent edge behavior matches Python 3.12" {
    try std.testing.expectEqualStrings(".gz", suffix("archive.tar.gz"));
    try std.testing.expectEqualStrings("", suffix(".hidden"));
    try std.testing.expectEqualStrings("", suffix("name."));
    try std.testing.expectEqualStrings("archive.tar", stem("archive.tar.gz"));
    var root_parent = try parent(std.testing.allocator, "/");
    defer root_parent.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/", root_parent.text);
    var relative_parent = try parent(std.testing.allocator, "leaf");
    defer relative_parent.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(".", relative_parent.text);
}
