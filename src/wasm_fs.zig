const std = @import("std");
const vfs = @import("runtime_vfs");

const Error = vfs.Error;

/// Synchronous Worker imports implement filesystem storage outside WASM.
/// Calls never leave the Worker thread and cannot run page callbacks.
extern "env" fn peony_fs_call(
    session: u32,
    operation: u32,
    path_pointer: u32,
    path_length: u32,
    data_pointer: u32,
    data_length: u32,
    auxiliary: u32,
    output_pointer: u32,
    output_length: u32,
) i32;

fn session(context: *anyopaque) u32 {
    const selected: *u32 = @ptrCast(@alignCast(context));
    return selected.*;
}

fn pointer(bytes: []const u8) u32 {
    return if (bytes.len == 0) 0 else @intCast(@intFromPtr(bytes.ptr));
}

fn call(context: *anyopaque, operation: u32, path: []const u8, data: []const u8, auxiliary: u32, output: []u8) i32 {
    return peony_fs_call(session(context), operation, pointer(path), @intCast(path.len), pointer(data), @intCast(data.len), auxiliary, pointer(output), @intCast(output.len));
}

fn checked(result: i32) Error!u32 {
    if (result >= 0) return @intCast(result);
    return switch (result) {
        -1 => error.InvalidPath,
        -2 => error.NotFound,
        -3 => error.Exists,
        -4 => error.NotDirectory,
        -5 => error.IsDirectory,
        -6 => error.PermissionDenied,
        -7 => error.TooLarge,
        -8 => error.OutOfMemory,
        -9 => error.InvalidMove,
        else => error.IoFailure,
    };
}

fn receive(context: *anyopaque, allocator: std.mem.Allocator, operation: u32, path: []const u8, auxiliary: u32, limit: usize) Error![]u8 {
    const length = try checked(call(context, operation, path, &.{}, auxiliary, &.{}));
    if (length > limit) return error.TooLarge;
    if (length == 0) return &.{};
    const bytes = allocator.alloc(u8, length) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    const actual = try checked(call(context, operation, path, &.{}, auxiliary, bytes));
    if (actual != length) return error.IoFailure;
    return bytes;
}

fn stat(context: *anyopaque, path: []const u8) vfs.HostKind {
    return switch (call(context, 1, path, &.{}, 0, &.{})) {
        1 => .file,
        2 => .directory,
        else => .missing,
    };
}
fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error![]u8 {
    return receive(context, allocator, 2, path, 0, limit);
}
fn write(context: *anyopaque, path: []const u8, bytes: []const u8, mode: vfs.WriteMode) Error!void {
    _ = try checked(call(context, 3, path, bytes, @intFromEnum(mode), &.{}));
}
fn open(context: *anyopaque, path: []const u8, access: vfs.FileAccess) Error!u32 {
    const handle = try checked(call(context, 4, path, &.{}, @intFromEnum(access), &.{}));
    if (handle == 0) return error.IoFailure;
    return handle;
}
fn readOpen(context: *anyopaque, allocator: std.mem.Allocator, handle: u32, limit: usize) Error![]u8 {
    return receive(context, allocator, 5, &.{}, handle, limit);
}
fn readAt(context: *anyopaque, handle: u32, offset: u64, output: []u8) Error!usize {
    var position: [8]u8 = undefined;
    std.mem.writeInt(u64, &position, offset, .little);
    return try checked(call(context, 21, &position, &.{}, handle, output));
}
fn replaceOpen(context: *anyopaque, handle: u32, bytes: []const u8) Error!void {
    _ = try checked(call(context, 6, &.{}, bytes, handle, &.{}));
}
fn lengthOpen(context: *anyopaque, handle: u32) Error!usize {
    return try checked(call(context, 18, &.{}, &.{}, handle, &.{}));
}
fn writeAt(context: *anyopaque, handle: u32, offset: u64, bytes: []const u8) Error!void {
    var position: [8]u8 = undefined;
    std.mem.writeInt(u64, &position, offset, .little);
    _ = try checked(call(context, 19, &position, bytes, handle, &.{}));
}
fn truncateOpen(context: *anyopaque, handle: u32, length: u64) Error!void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, length, .little);
    _ = try checked(call(context, 20, &size, &.{}, handle, &.{}));
}
fn close(context: *anyopaque, handle: u32) void {
    _ = call(context, 7, &.{}, &.{}, handle, &.{});
}
fn mkdir(context: *anyopaque, path: []const u8, parents: bool, exist_ok: bool) Error!void {
    _ = try checked(call(context, 8, path, &.{}, @as(u32, @intFromBool(parents)) | (@as(u32, @intFromBool(exist_ok)) << 1), &.{}));
}
fn remove(context: *anyopaque, path: []const u8, directory: bool) Error!void {
    _ = try checked(call(context, 9, path, &.{}, @intFromBool(directory), &.{}));
}
fn rename(context: *anyopaque, source: []const u8, target: []const u8, replace: bool) Error!void {
    _ = try checked(call(context, 10, source, target, @intFromBool(replace), &.{}));
}
fn list(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, directories: bool, depth: usize) Error![]u8 {
    const variant: u32 = if (depth == 1) 2 else if (directories) 1 else 0;
    return receive(context, allocator, 11, path, variant, std.math.maxInt(i32));
}
fn mountAsset(context: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
    _ = try checked(call(context, 12, path, bytes, 0, &.{}));
}
fn clearTemporary(context: *anyopaque) void {
    _ = call(context, 13, &.{}, &.{}, 0, &.{});
}
fn totalBytes(context: *anyopaque) usize {
    return @intCast(@max(0, call(context, 14, &.{}, &.{}, 0, &.{})));
}
fn normalize(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    return vfs.normalizePath(allocator, path);
}
fn writable(_: *anyopaque, path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/home/") or std.mem.startsWith(u8, path, "/tmp/");
}
fn destroy(context: *anyopaque) void {
    _ = call(context, 17, &.{}, &.{}, 0, &.{});
}

const ops: vfs.HostBackend.Ops = .{
    .stat = stat, .read = read, .write = write, .open = open,
    .read_open = readOpen, .read_at = readAt, .replace_open = replaceOpen, .close = close,
    .length_open = lengthOpen, .write_at = writeAt, .truncate_open = truncateOpen,
    .mkdir = mkdir, .remove = remove, .rename = rename, .list = list,
    .mount_asset = mountAsset, .clear_temporary = clearTemporary,
    .total_bytes = totalBytes, .normalize = normalize, .writable = writable,
    .destroy = destroy,
};

pub fn backend(handle: *u32) vfs.HostBackend {
    return .{ .context = handle, .ops = &ops };
}

pub fn configure(handle: u32, max_total: u32, max_file: u32) bool {
    return peony_fs_call(handle, 16, 0, 0, 0, max_total, max_file, 0, 0) == 0;
}
