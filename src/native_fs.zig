const std = @import("std");
const vfs = @import("runtime_vfs");

const Error = vfs.Error;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// Host storage for the native process. Python paths are OS paths resolved by
/// Zig relative to the process working directory, with normal OS permissions.
pub const NativeFs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    handles: std.ArrayList(?File) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) NativeFs {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *NativeFs) void {
        for (self.handles.items) |entry| if (entry) |file| file.close(self.io);
        self.handles.deinit(self.allocator);
    }

    pub fn backend(self: *NativeFs) vfs.HostBackend {
        return .{ .context = self, .ops = &ops };
    }

    fn from(context: *anyopaque) *NativeFs {
        return @ptrCast(@alignCast(context));
    }

    fn fileAt(self: *NativeFs, handle: u32) Error!File {
        if (handle == 0 or handle > self.handles.items.len) return error.InvalidPath;
        return self.handles.items[handle - 1] orelse error.InvalidPath;
    }

    fn stat(context: *anyopaque, path: []const u8) vfs.HostKind {
        const self = from(context);
        const info = Dir.cwd().statFile(self.io, path, .{}) catch return .missing;
        return switch (info.kind) {
            .directory => .directory,
            .file => .file,
            else => .missing,
        };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, limit: usize) Error![]u8 {
        const self = from(context);
        const bytes = Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(limit +| 1)) catch |err| return mapError(err);
        if (bytes.len != 0) return bytes;
        allocator.free(bytes);
        return &.{};
    }

    fn write(context: *anyopaque, path: []const u8, bytes: []const u8, mode: vfs.WriteMode) Error!void {
        const self = from(context);
        if (mode == .append) {
            const file = Dir.cwd().openFile(self.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => return write(context, path, bytes, .exclusive),
                else => return mapError(err),
            };
            defer file.close(self.io);
            const end = file.length(self.io) catch |err| return mapError(err);
            file.writePositionalAll(self.io, bytes, end) catch |err| return mapError(err);
            return;
        }
        const file = Dir.cwd().createFile(self.io, path, .{ .read = false, .truncate = mode == .replace, .exclusive = mode == .exclusive }) catch |err| return mapError(err);
        defer file.close(self.io);
        file.writePositionalAll(self.io, bytes, 0) catch |err| return mapError(err);
    }

    fn open(context: *anyopaque, path: []const u8, access: vfs.FileAccess) Error!u32 {
        const self = from(context);
        const mode: Dir.OpenFileOptions.Mode = switch (access) {
            .read_only => .read_only,
            .write_only => .write_only,
            .read_write => .read_write,
        };
        const file = Dir.cwd().openFile(self.io, path, .{ .mode = mode, .allow_directory = false }) catch |err| return mapError(err);
        errdefer file.close(self.io);
        for (self.handles.items, 0..) |entry, index| if (entry == null) {
            self.handles.items[index] = file;
            return @intCast(index + 1);
        };
        self.handles.append(self.allocator, file) catch return error.OutOfMemory;
        return @intCast(self.handles.items.len);
    }

    fn readOpen(context: *anyopaque, allocator: std.mem.Allocator, handle: u32, limit: usize) Error![]u8 {
        const self = from(context);
        const file = try self.fileAt(handle);
        const length = file.length(self.io) catch |err| return mapError(err);
        if (length > limit) return error.TooLarge;
        if (length == 0) return &.{};
        const bytes = allocator.alloc(u8, @intCast(length)) catch return error.OutOfMemory;
        errdefer allocator.free(bytes);
        const count = file.readPositionalAll(self.io, bytes, 0) catch |err| return mapError(err);
        if (count == bytes.len) return bytes;
        if (count == 0) {
            allocator.free(bytes);
            return &.{};
        }
        return allocator.realloc(bytes, count) catch return error.OutOfMemory;
    }

    fn readAt(context: *anyopaque, handle: u32, offset: u64, output: []u8) Error!usize {
        const self = from(context);
        const file = try self.fileAt(handle);
        return file.readPositionalAll(self.io, output, offset) catch |err| mapError(err);
    }

    fn replaceOpen(context: *anyopaque, handle: u32, bytes: []const u8) Error!void {
        const self = from(context);
        const file = try self.fileAt(handle);
        file.writePositionalAll(self.io, bytes, 0) catch |err| return mapError(err);
        file.setLength(self.io, bytes.len) catch |err| return mapError(err);
    }

    fn lengthOpen(context: *anyopaque, handle: u32) Error!usize {
        const self = from(context);
        const file = try self.fileAt(handle);
        const length = file.length(self.io) catch |err| return mapError(err);
        return std.math.cast(usize, length) orelse error.TooLarge;
    }

    fn writeAt(context: *anyopaque, handle: u32, offset: u64, bytes: []const u8) Error!void {
        const self = from(context);
        const file = try self.fileAt(handle);
        file.writePositionalAll(self.io, bytes, offset) catch |err| return mapError(err);
    }

    fn truncateOpen(context: *anyopaque, handle: u32, length: u64) Error!void {
        const self = from(context);
        const file = try self.fileAt(handle);
        file.setLength(self.io, length) catch |err| return mapError(err);
    }

    fn close(context: *anyopaque, handle: u32) void {
        const self = from(context);
        if (handle == 0 or handle > self.handles.items.len) return;
        if (self.handles.items[handle - 1]) |file| {
            file.close(self.io);
            self.handles.items[handle - 1] = null;
        }
    }

    fn mkdir(context: *anyopaque, path: []const u8, parents: bool, exist_ok: bool) Error!void {
        const self = from(context);
        if (!exist_ok and stat(context, path) != .missing) return error.Exists;
        if (parents) return Dir.cwd().createDirPath(self.io, path) catch |err| mapError(err);
        Dir.cwd().createDir(self.io, path, .default_dir) catch |err| return mapError(err);
    }

    fn remove(context: *anyopaque, path: []const u8, directory: bool) Error!void {
        const self = from(context);
        if (directory) return Dir.cwd().deleteDir(self.io, path) catch |err| mapError(err);
        Dir.cwd().deleteFile(self.io, path) catch |err| return mapError(err);
    }

    fn rename(context: *anyopaque, source: []const u8, target: []const u8, replace: bool) Error!void {
        const self = from(context);
        if (!replace and stat(context, target) != .missing) return error.Exists;
        Dir.rename(.cwd(), source, .cwd(), target, self.io) catch |err| return mapError(err);
    }

    fn list(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, directories: bool, depth: usize) Error![]u8 {
        const self = from(context);
        const dir = Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| return mapError(err);
        defer dir.close(self.io);
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |item| allocator.free(item);
            paths.deinit(allocator);
        }
        try collect(self, allocator, dir, if (depth == 1) "" else path, directories, depth, &paths);
        std.mem.sort([]u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool { return std.mem.lessThan(u8, a, b); }
        }.lessThan);
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        for (paths.items) |item| {
            result.appendSlice(allocator, item) catch return error.OutOfMemory;
            result.append(allocator, 0) catch return error.OutOfMemory;
        }
        return result.toOwnedSlice(allocator) catch error.OutOfMemory;
    }

    fn collect(self: *NativeFs, allocator: std.mem.Allocator, dir: Dir, prefix: []const u8, directories: bool, depth: usize, result: *std.ArrayList([]u8)) Error!void {
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch |err| return mapError(err)) |entry| {
            const is_dir = entry.kind == .directory;
            if (depth == 1 or is_dir == directories) {
                const name = if (prefix.len == 0) allocator.dupe(u8, entry.name) else std.fs.path.join(allocator, &.{ prefix, entry.name });
                result.append(allocator, name catch return error.OutOfMemory) catch return error.OutOfMemory;
            }
            if (depth != 1 and is_dir) {
                const child = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch |err| return mapError(err);
                defer child.close(self.io);
                const child_path = std.fs.path.join(allocator, &.{ prefix, entry.name }) catch return error.OutOfMemory;
                defer allocator.free(child_path);
                try self.collect(allocator, child, child_path, directories, depth, result);
            }
        }
    }

    fn mountAsset(_: *anyopaque, _: []const u8, _: []const u8) Error!void { return error.InvalidPath; }
    fn clearTemporary(_: *anyopaque) void {}
    fn totalBytes(_: *anyopaque) usize { return 0; }
    fn normalize(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
        return allocator.dupe(u8, path) catch error.OutOfMemory;
    }
    fn writable(_: *anyopaque, _: []const u8) bool { return true; }
    fn destroy(_: *anyopaque) void {}

    const ops: vfs.HostBackend.Ops = .{
        .stat = stat, .read = read, .write = write, .open = open,
        .read_open = readOpen, .read_at = readAt, .replace_open = replaceOpen, .close = close,
        .length_open = lengthOpen, .write_at = writeAt, .truncate_open = truncateOpen,
        .mkdir = mkdir, .remove = remove, .rename = rename, .list = list,
        .mount_asset = mountAsset, .clear_temporary = clearTemporary,
        .total_bytes = totalBytes, .normalize = normalize, .writable = writable,
        .destroy = destroy,
    };
};

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound, error.PathNotFound => error.NotFound,
        error.PathAlreadyExists, error.FileAlreadyExists => error.Exists,
        error.NotDir => error.NotDirectory,
        error.IsDir => error.IsDirectory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.PermissionDenied,
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        else => error.IoFailure,
    };
}
