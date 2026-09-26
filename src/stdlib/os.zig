const std = @import("std");
const binder = @import("runtime_binder");
const exceptions = @import("runtime_exception");
const file_module = @import("runtime_file");
const gc = @import("runtime_gc");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const types = @import("types.zig");
const vfs_module = @import("runtime_vfs");
const pathlib = @import("pathlib.zig");

const Value = types.Value;

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "getcwd" },
    .{ .id = 2, .name = "listdir", .params = &.{.{ .name = "path", .default = .{ .text = "." } }} },
    .{ .id = 3, .name = "mkdir", .params = &.{ .{ .name = "path" }, .{ .name = "mode", .default = .{ .integer = 0o777 } } } },
    .{ .id = 4, .name = "makedirs", .params = &.{
        .{ .name = "name" },
        .{ .name = "mode", .default = .{ .integer = 0o777 } },
        .{ .name = "exist_ok", .flags = binder.parameter_flags_module.keyword_only, .default = .{ .boolean = false } },
    } },
    .{ .id = 5, .name = "remove", .params = &.{.{ .name = "path" }} },
    .{ .id = 6, .name = "unlink", .params = &.{.{ .name = "path" }} },
    .{ .id = 7, .name = "rename", .params = &.{ .{ .name = "src" }, .{ .name = "dst" } } },
    .{ .id = 8, .name = "replace", .params = &.{ .{ .name = "src" }, .{ .name = "dst" } } },
};

pub const path_functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "join", .params = &.{.{ .name = "paths", .flags = binder.parameter_flags_module.var_positional }} },
    .{ .id = 2, .name = "basename", .params = &.{.{ .name = "path" }} },
    .{ .id = 3, .name = "dirname", .params = &.{.{ .name = "path" }} },
    .{ .id = 4, .name = "exists", .params = &.{.{ .name = "path" }} },
    .{ .id = 5, .name = "isfile", .params = &.{.{ .name = "path" }} },
    .{ .id = 6, .name = "isdir", .params = &.{.{ .name = "path" }} },
};

/// POSIX `os.path.join` semantics. This intentionally does not normalize `.`,
/// `..`, repeated separators, or trailing separators.
pub fn pathJoin(allocator: std.mem.Allocator, segments: []const []const u8) ![]u8 {
    if (segments.len == 0) return error.MissingArgument;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (segments) |segment| {
        if (!std.unicode.utf8ValidateSlice(segment)) return error.InvalidUtf8;
        if (segment.len != 0 and segment[0] == '/') {
            output.clearRetainingCapacity();
            try output.appendSlice(allocator, segment);
            continue;
        }
        if (output.items.len == 0) {
            try output.appendSlice(allocator, segment);
            continue;
        }
        if (output.items[output.items.len - 1] != '/') try output.append(allocator, '/');
        try output.appendSlice(allocator, segment);
    }
    return output.toOwnedSlice(allocator);
}

fn pathJoinNative(allocator: std.mem.Allocator, segments: []const []const u8) ![]u8 {
    if (segments.len == 0) return error.MissingArgument;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (segments) |segment| {
        if (!std.unicode.utf8ValidateSlice(segment)) return error.InvalidUtf8;
        if (std.fs.path.isAbsolute(segment)) output.clearRetainingCapacity();
        if (output.items.len != 0 and segment.len != 0 and
            output.items[output.items.len - 1] != '/' and output.items[output.items.len - 1] != '\\' and
            segment[0] != '/' and segment[0] != '\\') try output.append(allocator, std.fs.path.sep);
        try output.appendSlice(allocator, segment);
    }
    return output.toOwnedSlice(allocator);
}

pub fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

pub fn dirname(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    var head_end = slash + 1;
    if (!allSlashes(path[0..head_end])) {
        while (head_end != 0 and path[head_end - 1] == '/') head_end -= 1;
    }
    return path[0..head_end];
}

fn allSlashes(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (byte != '/') return false;
    return true;
}

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    _ = self;
    _ = environment;
    _ = line;
    _ = column;
    // The registry attaches the separately importable native `os.path`
    // module after both environments are rooted in the import cache.
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
    _ = receiver;
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    return switch (function_id) {
        1 => storeString(self, destination, self.cwd_text, line, column),
        2 => listDirectory(Runtime, self, destination, args[0], line, column),
        3 => makeDirectory(self, destination, args[0], args[1], false, false, line, column),
        4 => makeDirectory(self, destination, args[0], args[1], true, args[2].asBool() orelse return self.nativeTypeError(line, column, "exist_ok must be bool"), line, column),
        5, 6 => removeFile(self, destination, args[0], line, column),
        7, 8 => renameEntry(self, destination, args[0], args[1], line, column),
        else => self.engineFault(),
    };
}

pub fn executePath(
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
    _ = receiver;
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    if (function_id == 1) return joinPaths(self, destination, args[0], line, column);
    const path = pathArgument(self, args[0], line, column) orelse return false;
    return switch (function_id) {
        2 => storeString(self, destination, if (self.vfs.native_paths) std.fs.path.basename(path) else basename(path), line, column),
        3 => storeString(self, destination, if (self.vfs.native_paths) std.fs.path.dirname(path) orelse "" else dirname(path), line, column),
        4 => storeBoolean(self, destination, self.vfs.exists(path)),
        5 => storeBoolean(self, destination, isFile(self, path)),
        6 => storeBoolean(self, destination, isDirectory(self, path)),
        else => self.engineFault(),
    };
}

fn listDirectory(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, line: u32, column: u32) bool {
    const path = pathArgument(self, value, line, column) orelse return false;
    const names = self.vfs.listDirectory(path) catch |err| return vfsFailure(self, err, line, column);
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
        const item = self.createStringValue(names[cursor..end], line, column) orelse return false;
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
    self.setRegister(destination, Value.object(&list.header));
    return true;
}

fn makeDirectory(self: anytype, destination: u16, path_value: Value, mode_value: Value, parents: bool, exist_ok: bool, line: u32, column: u32) bool {
    const path = pathArgument(self, path_value, line, column) orelse return false;
    if (!number.isIntegerValue(mode_value)) return self.nativeTypeError(line, column, "mode must be an integer");
    self.vfs.mkdir(path, parents, exist_ok) catch |err| return vfsFailure(self, err, line, column);
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn removeFile(self: anytype, destination: u16, value: Value, line: u32, column: u32) bool {
    const path = pathArgument(self, value, line, column) orelse return false;
    self.vfs.remove(path, false) catch |err| return vfsFailure(self, err, line, column);
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn renameEntry(self: anytype, destination: u16, source_value: Value, target_value: Value, line: u32, column: u32) bool {
    const source = pathArgument(self, source_value, line, column) orelse return false;
    const target = pathArgument(self, target_value, line, column) orelse return false;
    self.vfs.rename(source, target, true) catch |err| return vfsFailure(self, err, line, column);
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn joinPaths(self: anytype, destination: u16, tuple_value: Value, line: u32, column: u32) bool {
    const tuple = sequence.tupleFromHeader(tuple_value.asObject() orelse return self.engineFault()) orelse return self.engineFault();
    if (tuple.items.len == 0) return self.nativeTypeError(line, column, "join() missing path argument");
    const segments = self.heap.allocator.alloc([]const u8, tuple.items.len) catch return memoryFailure(self, line, column);
    defer self.heap.allocator.free(segments);
    for (tuple.items, 0..) |value, index| segments[index] = pathArgument(self, value, line, column) orelse return false;
    const joined = (if (self.vfs.native_paths) pathJoinNative(self.heap.allocator, segments) else pathJoin(self.heap.allocator, segments)) catch |err| {
        if (err == error.OutOfMemory) return memoryFailure(self, line, column);
        return self.nativeTypeError(line, column, "invalid path");
    };
    defer self.heap.allocator.free(joined);
    return storeString(self, destination, joined, line, column);
}

fn pathArgument(self: anytype, value: Value, line: u32, column: u32) ?[]const u8 {
    if (self.valueString(value)) |text| return text;
    if (pathlib.pathText(value)) |text| return text;
    _ = self.nativeTypeError(line, column, "path must be str or Path");
    return null;
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

fn storeString(self: anytype, destination: u16, text: []const u8, line: u32, column: u32) bool {
    const value = self.createStringValue(text, line, column) orelse return false;
    self.setRegister(destination, value);
    return true;
}

fn storeBoolean(self: anytype, destination: u16, enabled: bool) bool {
    self.setRegister(destination, if (enabled) Value.trueValue() else Value.falseValue());
    return true;
}

fn vfsFailure(self: anytype, err: vfs_module.Error, line: u32, column: u32) bool {
    self.setException(file_module.pathException(err), line, column, null);
    return false;
}

fn memoryFailure(self: anytype, line: u32, column: u32) bool {
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}

test "os.path lexical join preserves separators and resets absolute segments" {
    const cases = [_]struct { segments: []const []const u8, expected: []const u8 }{
        .{ .segments = &.{ "/a", "b", "/c", "d" }, .expected = "/c/d" },
        .{ .segments = &.{ "a", "" }, .expected = "a/" },
        .{ .segments = &.{ "", "b" }, .expected = "b" },
        .{ .segments = &.{ "//root", "child" }, .expected = "//root/child" },
        .{ .segments = &.{ "a//", "b" }, .expected = "a//b" },
    };
    for (cases) |case| {
        const result = try pathJoin(std.testing.allocator, case.segments);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case.expected, result);
    }
}

test "os.path basename and dirname retain POSIX trailing slash behavior" {
    const cases = [_]struct { path: []const u8, base: []const u8, dir: []const u8 }{
        .{ .path = "", .base = "", .dir = "" },
        .{ .path = "/", .base = "", .dir = "/" },
        .{ .path = "//", .base = "", .dir = "//" },
        .{ .path = "///", .base = "", .dir = "///" },
        .{ .path = "/a/b/", .base = "", .dir = "/a/b" },
        .{ .path = "a", .base = "a", .dir = "" },
        .{ .path = "a/", .base = "", .dir = "a" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.base, basename(case.path));
        try std.testing.expectEqualStrings(case.dir, dirname(case.path));
    }
}
