const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    InvalidPath,
    InvalidMove,
    NotFound,
    Exists,
    NotDirectory,
    IsDirectory,
    PermissionDenied,
    IoFailure,
    TooLarge,
    OutOfMemory,
};

pub const EntryKind = enum { directory, file };
pub const WriteMode = enum { replace, append, exclusive };

/// File contents have identity independent of a namespace entry. Open files retain
/// their node across rename and unlink; the byte budget is released with the last
/// namespace link or open handle.
pub const FileNode = struct {
    bytes: []u8 = &.{},
    links: usize = 1,
    handles: usize = 0,
    read_only: bool = false,
    host_handle: u32 = 0,
};

pub const HostKind = enum { missing, file, directory };
pub const FileAccess = enum { read_only, write_only, read_write };

/// Filesystem storage belongs to the host. The VM retains Python file and
/// path semantics while an adapter supplies real OS or Worker-owned storage.
pub const HostBackend = struct {
    context: *anyopaque,
    ops: *const Ops,

    pub const Ops = struct {
        stat: *const fn (*anyopaque, []const u8) HostKind,
        read: *const fn (*anyopaque, std.mem.Allocator, []const u8, usize) Error![]u8,
        write: *const fn (*anyopaque, []const u8, []const u8, WriteMode) Error!void,
        open: *const fn (*anyopaque, []const u8, FileAccess) Error!u32,
        read_open: *const fn (*anyopaque, std.mem.Allocator, u32, usize) Error![]u8,
        read_at: *const fn (*anyopaque, u32, u64, []u8) Error!usize,
        replace_open: *const fn (*anyopaque, u32, []const u8) Error!void,
        length_open: *const fn (*anyopaque, u32) Error!usize,
        write_at: *const fn (*anyopaque, u32, u64, []const u8) Error!void,
        truncate_open: *const fn (*anyopaque, u32, u64) Error!void,
        close: *const fn (*anyopaque, u32) void,
        mkdir: *const fn (*anyopaque, []const u8, bool, bool) Error!void,
        remove: *const fn (*anyopaque, []const u8, bool) Error!void,
        rename: *const fn (*anyopaque, []const u8, []const u8, bool) Error!void,
        list: *const fn (*anyopaque, std.mem.Allocator, []const u8, bool, usize) Error![]u8,
        mount_asset: *const fn (*anyopaque, []const u8, []const u8) Error!void,
        clear_temporary: *const fn (*anyopaque) void,
        total_bytes: *const fn (*anyopaque) usize,
        normalize: *const fn (*anyopaque, std.mem.Allocator, []const u8) Error![]u8,
        writable: *const fn (*anyopaque, []const u8) bool,
        destroy: *const fn (*anyopaque) void,
    };
};

pub const Entry = struct {
    path: []u8,
    kind: EntryKind,
    node: ?*FileNode = null,
    read_only: bool = false,
};

pub const Vfs = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    nodes: std.ArrayList(*FileNode) = .empty,
    total_bytes: usize = 0,
    max_total_bytes: usize,
    max_file_bytes: usize,
    host: ?HostBackend = null,
    native_paths: bool = false,
    host_nodes: std.ArrayList(*FileNode) = .empty,
    borrowed: []u8 = &.{},

    pub fn bindHost(self: *Vfs, backend: HostBackend) void {
        self.host = backend;
    }

    pub fn init(allocator: std.mem.Allocator, max_total_bytes: usize, max_file_bytes: usize) Error!Vfs {
        var fs = Vfs{
            .allocator = allocator,
            .max_total_bytes = max_total_bytes,
            .max_file_bytes = @min(max_file_bytes, max_total_bytes),
        };
        errdefer fs.deinit();
        // The in-Zig store exists for direct engine unit tests. Shipping
        // adapters bind OS or Worker storage before exposing a session.
        if (builtin.is_test) {
            try fs.addDirectory("/", false);
            try fs.addDirectory("/assets", true);
            try fs.addDirectory("/home", false);
            try fs.addDirectory("/tmp", false);
        }
        return fs;
    }

    pub fn deinit(self: *Vfs) void {
        if (self.host) |backend| {
            for (self.host_nodes.items) |node| {
                backend.ops.close(backend.context, node.host_handle);
                if (node.bytes.len != 0) self.allocator.free(node.bytes);
                self.allocator.destroy(node);
            }
            self.host_nodes.deinit(self.allocator);
            if (self.borrowed.len != 0) self.allocator.free(self.borrowed);
            backend.ops.destroy(backend.context);
        }
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.deinit(self.allocator);
        for (self.nodes.items) |node| {
            if (node.bytes.len != 0) self.allocator.free(node.bytes);
            self.allocator.destroy(node);
        }
        self.nodes.deinit(self.allocator);
        self.total_bytes = 0;
    }

    pub fn normalizeOwned(self: *const Vfs, path: []const u8) Error![]u8 {
        if (self.host) |backend| return backend.ops.normalize(backend.context, self.allocator, path);
        return normalizePath(self.allocator, path);
    }

    pub fn writable(self: *const Vfs, path: []const u8) bool {
        if (self.host) |backend| return backend.ops.writable(backend.context, path);
        return isWritablePath(path);
    }

    pub fn read(self: *const Vfs, path: []const u8) Error![]const u8 {
        if (self.host) |backend| {
            const mutable: *Vfs = @constCast(self);
            if (mutable.borrowed.len != 0) self.allocator.free(mutable.borrowed);
            mutable.borrowed = &.{};
            mutable.borrowed = try backend.ops.read(backend.context, self.allocator, path, self.max_file_bytes);
            return mutable.borrowed;
        }
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        return self.readNormalized(normalized);
    }

    pub fn exists(self: *const Vfs, path: []const u8) bool {
        if (self.host) |backend| return backend.ops.stat(backend.context, path) != .missing;
        const normalized = normalizePath(self.allocator, path) catch return false;
        defer self.allocator.free(normalized);
        return self.find(normalized) != null;
    }

    pub fn existsNormalized(self: *const Vfs, normalized: []const u8) bool {
        if (self.host) |backend| return backend.ops.stat(backend.context, normalized) != .missing;
        return self.find(normalized) != null;
    }

    pub fn readNormalized(self: *const Vfs, normalized: []const u8) Error![]const u8 {
        if (self.host != null) return self.read(normalized);
        return self.readNode(try self.fileNodeNormalized(normalized));
    }

    pub fn openNode(self: *Vfs, normalized: []const u8, access: FileAccess) Error!*FileNode {
        if (self.host) |backend| {
            const handle = try backend.ops.open(backend.context, normalized, access);
            errdefer backend.ops.close(backend.context, handle);
            const node = self.allocator.create(FileNode) catch return error.OutOfMemory;
            errdefer self.allocator.destroy(node);
            node.* = .{ .host_handle = handle, .links = 0, .handles = 1 };
            self.host_nodes.append(self.allocator, node) catch return error.OutOfMemory;
            return node;
        }
        return self.fileNodeNormalized(normalized);
    }

    pub fn fileNodeNormalized(self: *const Vfs, normalized: []const u8) Error!*FileNode {
        const index = self.find(normalized) orelse return error.NotFound;
        const entry = self.entries.items[index];
        if (entry.kind == .directory) return error.IsDirectory;
        return entry.node.?;
    }

    pub fn readNode(self: *const Vfs, node: *const FileNode) Error![]const u8 {
        if (self.host) |backend| {
            const mutable: *FileNode = @constCast(node);
            if (mutable.bytes.len != 0) self.allocator.free(mutable.bytes);
            mutable.bytes = &.{};
            mutable.bytes = try backend.ops.read_open(backend.context, self.allocator, node.host_handle, self.max_file_bytes);
            return mutable.bytes;
        }
        return node.bytes;
    }

    pub fn readAtNode(self: *const Vfs, node: *const FileNode, offset: u64, output: []u8) Error!usize {
        const backend = self.host orelse return error.IoFailure;
        return backend.ops.read_at(backend.context, node.host_handle, offset, output);
    }

    pub fn totalBytes(self: *const Vfs) usize {
        if (self.host) |backend| return backend.ops.total_bytes(backend.context);
        return self.total_bytes;
    }

    pub fn lengthNode(self: *const Vfs, node: *const FileNode) Error!usize {
        if (self.host) |backend| return backend.ops.length_open(backend.context, node.host_handle);
        return node.bytes.len;
    }

    pub fn writeAtNode(self: *Vfs, node: *FileNode, offset: u64, bytes: []const u8) Error!void {
        const backend = self.host orelse return error.IoFailure;
        return backend.ops.write_at(backend.context, node.host_handle, offset, bytes);
    }

    pub fn truncateNode(self: *Vfs, node: *FileNode, length: u64) Error!void {
        const backend = self.host orelse return error.IoFailure;
        return backend.ops.truncate_open(backend.context, node.host_handle, length);
    }

    pub fn retainFile(_: *Vfs, node: *FileNode) void {
        node.handles += 1;
    }

    pub fn releaseFile(self: *Vfs, node: *FileNode) void {
        std.debug.assert(node.handles != 0);
        node.handles -= 1;
        if (self.host) |backend| {
            if (node.handles == 0) {
                backend.ops.close(backend.context, node.host_handle);
                if (node.bytes.len != 0) self.allocator.free(node.bytes);
                for (self.host_nodes.items, 0..) |item, index| if (item == node) {
                    _ = self.host_nodes.orderedRemove(index);
                    break;
                };
                self.allocator.destroy(node);
            }
            return;
        }
        self.maybeDestroyNode(node);
    }

    pub fn isDirectoryNormalized(self: *const Vfs, normalized: []const u8) bool {
        if (self.host) |backend| return backend.ops.stat(backend.context, normalized) == .directory;
        const index = self.find(normalized) orelse return false;
        return self.entries.items[index].kind == .directory;
    }

    pub fn write(self: *Vfs, path: []const u8, bytes: []const u8, mode: WriteMode) Error!void {
        if (self.host) |backend| return backend.ops.write(backend.context, path, bytes, mode);
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        try self.writeNormalized(normalized, bytes, mode);
    }

    pub fn writeNormalized(self: *Vfs, normalized: []const u8, bytes: []const u8, mode: WriteMode) Error!void {
        if (self.host) |backend| return backend.ops.write(backend.context, normalized, bytes, mode);
        if (!isWritablePath(normalized)) return error.PermissionDenied;
        if (bytes.len > self.max_file_bytes) return error.TooLarge;
        const parent = parentPath(normalized) orelse return error.InvalidPath;
        const parent_index = self.find(parent) orelse return error.NotFound;
        if (self.entries.items[parent_index].kind != .directory) return error.NotDirectory;

        if (self.find(normalized)) |index| {
            const entry = self.entries.items[index];
            if (entry.kind == .directory) return error.IsDirectory;
            if (entry.read_only) return error.PermissionDenied;
            if (mode == .exclusive) return error.Exists;
            return self.writeNode(entry.node.?, bytes, mode);
        }

        if (mode == .append or mode == .replace or mode == .exclusive) {
            try self.addFile(normalized, bytes, false);
        }
    }

    pub fn writeNode(self: *Vfs, node: *FileNode, bytes: []const u8, mode: WriteMode) Error!void {
        if (self.host) |backend| {
            if (mode == .exclusive) return error.Exists;
            if (mode == .replace) return backend.ops.replace_open(backend.context, node.host_handle, bytes);
            const old = try self.readNode(node);
            const combined = self.allocator.alloc(u8, old.len + bytes.len) catch return error.OutOfMemory;
            defer self.allocator.free(combined);
            @memcpy(combined[0..old.len], old);
            @memcpy(combined[old.len..], bytes);
            return backend.ops.replace_open(backend.context, node.host_handle, combined);
        }
        if (node.read_only) return error.PermissionDenied;
        if (mode == .exclusive) return error.Exists;
        const old_len = node.bytes.len;
        const new_len = if (mode == .append)
            std.math.add(usize, old_len, bytes.len) catch return error.TooLarge
        else
            bytes.len;
        if (new_len > self.max_file_bytes) return error.TooLarge;
        const new_total = std.math.add(usize, self.total_bytes - old_len, new_len) catch return error.TooLarge;
        if (new_total > self.max_total_bytes) return error.TooLarge;
        const replacement = if (new_len == 0) @as([]u8, &.{}) else self.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
        errdefer if (replacement.len != 0) self.allocator.free(replacement);
        if (mode == .append) {
            @memcpy(replacement[0..old_len], node.bytes);
            @memcpy(replacement[old_len..], bytes);
        } else if (bytes.len != 0) {
            @memcpy(replacement, bytes);
        }
        try self.replaceNodeOwned(node, replacement);
    }

    /// On success the VFS takes ownership of `replacement` without copying it.
    pub fn replaceNodeOwned(self: *Vfs, node: *FileNode, replacement: []u8) Error!void {
        if (self.host) |backend| {
            try backend.ops.replace_open(backend.context, node.host_handle, replacement);
            if (replacement.len != 0) self.allocator.free(replacement);
            return;
        }
        if (node.read_only) return error.PermissionDenied;
        if (replacement.len > self.max_file_bytes) return error.TooLarge;
        const new_total = std.math.add(usize, self.total_bytes - node.bytes.len, replacement.len) catch return error.TooLarge;
        if (new_total > self.max_total_bytes) return error.TooLarge;
        if (node.bytes.len != 0) self.allocator.free(node.bytes);
        node.bytes = replacement;
        self.total_bytes = new_total;
    }

    /// Mounts read-only asset content. Missing parent directories are created
    /// transactionally so an allocation failure leaves the visible tree intact.
    pub fn mountAsset(self: *Vfs, path: []const u8, bytes: []const u8) Error!void {
        if (self.host) |backend| return backend.ops.mount_asset(backend.context, path, bytes);
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        if (!std.mem.startsWith(u8, normalized, "/assets/") or normalized.len <= "/assets/".len) return error.PermissionDenied;
        if (bytes.len > self.max_file_bytes) return error.TooLarge;
        if (self.find(normalized)) |index| {
            const entry = self.entries.items[index];
            if (entry.kind != .file or !entry.read_only) return error.Exists;
            return self.replaceMountedBytes(entry.node.?, bytes);
        }
        const new_total = std.math.add(usize, self.total_bytes, bytes.len) catch return error.TooLarge;
        if (new_total > self.max_total_bytes) return error.TooLarge;

        const original_len = self.entries.items.len;
        errdefer self.rollbackEntries(original_len);
        const parent = parentPath(normalized) orelse return error.InvalidPath;
        try self.createMissingAssetParents(parent);
        try self.addFile(normalized, bytes, true);
    }

    pub fn mkdir(self: *Vfs, path: []const u8, parents: bool, exist_ok: bool) Error!void {
        if (self.host) |backend| return backend.ops.mkdir(backend.context, path, parents, exist_ok);
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        try self.mkdirNormalized(normalized, parents, exist_ok);
    }

    pub fn mkdirNormalized(self: *Vfs, normalized: []const u8, parents: bool, exist_ok: bool) Error!void {
        if (self.host) |backend| return backend.ops.mkdir(backend.context, normalized, parents, exist_ok);
        if (!isWritablePath(normalized) or std.mem.eql(u8, normalized, "/home") or std.mem.eql(u8, normalized, "/tmp")) {
            if (self.find(normalized)) |index| {
                if (self.entries.items[index].kind == .directory and exist_ok) return;
                return error.Exists;
            }
            return error.PermissionDenied;
        }
        if (self.find(normalized)) |index| {
            if (self.entries.items[index].kind == .directory and exist_ok) return;
            return error.Exists;
        }
        if (!parents) {
            const parent = parentPath(normalized) orelse return error.InvalidPath;
            const parent_index = self.find(parent) orelse return error.NotFound;
            if (self.entries.items[parent_index].kind != .directory) return error.NotDirectory;
            return self.addDirectory(normalized, false);
        }

        var pending: std.ArrayList(Entry) = .empty;
        defer {
            for (pending.items) |entry| self.allocator.free(entry.path);
            pending.deinit(self.allocator);
        }
        var cursor: usize = 1;
        while (cursor <= normalized.len) {
            const separator = std.mem.indexOfScalarPos(u8, normalized, cursor, '/') orelse normalized.len;
            const prefix = normalized[0..separator];
            if (self.find(prefix)) |index| {
                if (self.entries.items[index].kind != .directory) return error.NotDirectory;
            } else {
                const owned = self.allocator.dupe(u8, prefix) catch return error.OutOfMemory;
                pending.append(self.allocator, .{ .path = owned, .kind = .directory }) catch {
                    self.allocator.free(owned);
                    return error.OutOfMemory;
                };
            }
            if (separator == normalized.len) break;
            cursor = separator + 1;
        }
        self.entries.ensureUnusedCapacity(self.allocator, pending.items.len) catch return error.OutOfMemory;
        for (pending.items) |entry| self.entries.appendAssumeCapacity(entry);
        pending.clearRetainingCapacity();
    }

    /// Removes a file (`directory == false`) or an empty directory.
    pub fn remove(self: *Vfs, path: []const u8, directory: bool) Error!void {
        if (self.host) |backend| return backend.ops.remove(backend.context, path, directory);
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        try self.removeNormalized(normalized, directory);
    }

    pub fn removeNormalized(self: *Vfs, normalized: []const u8, directory: bool) Error!void {
        if (self.host) |backend| return backend.ops.remove(backend.context, normalized, directory);
        if (!isWritablePath(normalized)) return error.PermissionDenied;
        const index = self.find(normalized) orelse return error.NotFound;
        const entry = self.entries.items[index];
        if (directory) {
            if (entry.kind != .directory) return error.NotDirectory;
            if (self.hasDescendants(normalized)) return error.Exists;
        } else if (entry.kind == .directory) {
            return error.IsDirectory;
        }
        self.removeEntryAt(index);
    }

    /// Moves a file or complete directory subtree. When `replace_destination` is
    /// true, a same-kind file or empty directory destination is removed first.
    pub fn rename(self: *Vfs, source: []const u8, destination: []const u8, replace_destination: bool) Error!void {
        if (self.host) |backend| return backend.ops.rename(backend.context, source, destination, replace_destination);
        const normalized_source = try normalizePath(self.allocator, source);
        defer self.allocator.free(normalized_source);
        const normalized_destination = try normalizePath(self.allocator, destination);
        defer self.allocator.free(normalized_destination);
        try self.renameNormalized(normalized_source, normalized_destination, replace_destination);
    }

    pub fn renameNormalized(self: *Vfs, source: []const u8, destination: []const u8, replace_destination: bool) Error!void {
        if (self.host) |backend| return backend.ops.rename(backend.context, source, destination, replace_destination);
        if (!isWritablePath(source) or !isWritablePath(destination)) return error.PermissionDenied;
        if (std.mem.eql(u8, source, destination)) return;
        const source_index = self.find(source) orelse return error.NotFound;
        const source_kind = self.entries.items[source_index].kind;
        if (source_kind == .directory and isDescendant(source, destination)) return error.InvalidMove;
        const destination_parent = parentPath(destination) orelse return error.InvalidPath;
        const parent_index = self.find(destination_parent) orelse return error.NotFound;
        if (self.entries.items[parent_index].kind != .directory) return error.NotDirectory;

        const destination_index = self.find(destination);
        if (destination_index) |index| {
            if (!replace_destination) return error.Exists;
            const destination_kind = self.entries.items[index].kind;
            if (source_kind == .directory and destination_kind != .directory) return error.NotDirectory;
            if (source_kind == .file and destination_kind == .directory) return error.IsDirectory;
            if (destination_kind == .directory and self.hasDescendants(destination)) return error.Exists;
        }

        const Move = struct { old_path: []const u8, new_path: []u8 };
        var moves: std.ArrayList(Move) = .empty;
        defer {
            for (moves.items) |move| if (move.new_path.len != 0) self.allocator.free(move.new_path);
            moves.deinit(self.allocator);
        }
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.path, source) and !isDescendant(source, entry.path)) continue;
            const suffix = entry.path[source.len..];
            const new_path = std.mem.concat(self.allocator, u8, &.{ destination, suffix }) catch return error.OutOfMemory;
            moves.append(self.allocator, .{ .old_path = entry.path, .new_path = new_path }) catch {
                self.allocator.free(new_path);
                return error.OutOfMemory;
            };
        }
        for (moves.items) |move| {
            if (self.find(move.new_path)) |index| {
                const existing_path = self.entries.items[index].path;
                if (!std.mem.eql(u8, existing_path, destination) and !std.mem.eql(u8, existing_path, source) and !isDescendant(source, existing_path)) return error.Exists;
            }
        }

        if (destination_index != null) self.removeEntryAt(self.find(destination).?);
        for (moves.items) |*move| {
            const index = self.find(move.old_path).?;
            self.allocator.free(self.entries.items[index].path);
            self.entries.items[index].path = move.new_path;
            move.new_path = &.{};
        }
    }

    pub fn list(self: *const Vfs, path: []const u8) Error![]u8 {
        if (self.host) |backend| return backend.ops.list(backend.context, self.allocator, path, false, 0);
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        return self.listNormalized(normalized);
    }

    /// Returns NUL-separated full file paths below a directory, sorted by bytes.
    pub fn listNormalized(self: *const Vfs, normalized: []const u8) Error![]u8 {
        if (self.host) |backend| return backend.ops.list(backend.context, self.allocator, normalized, false, 0);
        const index = self.find(normalized) orelse return error.NotFound;
        if (self.entries.items[index].kind != .directory) return error.NotDirectory;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (self.entries.items) |entry| {
            if (entry.kind != .file or !isDescendant(normalized, entry.path)) continue;
            paths.append(self.allocator, entry.path) catch return error.OutOfMemory;
        }
        sortSlices(paths.items);
        return joinNul(self.allocator, paths.items);
    }

    /// Returns sorted, NUL-separated immediate child names, including directories.
    pub fn listDirectory(self: *const Vfs, path: []const u8) Error![]u8 {
        if (self.host) |backend| return backend.ops.list(backend.context, self.allocator, path, false, 1);
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        return self.listDirectoryNormalized(normalized);
    }

    pub fn listDirectoryNormalized(self: *const Vfs, normalized: []const u8) Error![]u8 {
        if (self.host) |backend| return backend.ops.list(backend.context, self.allocator, normalized, false, 1);
        const index = self.find(normalized) orelse return error.NotFound;
        if (self.entries.items[index].kind != .directory) return error.NotDirectory;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        for (self.entries.items) |entry| {
            if (!isDescendant(normalized, entry.path)) continue;
            const offset = if (std.mem.eql(u8, normalized, "/")) 1 else normalized.len + 1;
            const remainder = entry.path[offset..];
            if (std.mem.indexOfScalar(u8, remainder, '/') != null) continue;
            names.append(self.allocator, remainder) catch return error.OutOfMemory;
        }
        sortSlices(names.items);
        return joinNul(self.allocator, names.items);
    }

    /// Returns sorted, NUL-separated full directory paths beneath `path`.
    /// The queried directory itself is excluded. Lexical sorting places every
    /// parent before its descendants, which makes the result directly usable
    /// by persistence restore code.
    pub fn listDirectories(self: *const Vfs, path: []const u8) Error![]u8 {
        if (self.host) |backend| return backend.ops.list(backend.context, self.allocator, path, true, 0);
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        return self.listDirectoriesNormalized(normalized);
    }

    pub fn listDirectoriesNormalized(self: *const Vfs, normalized: []const u8) Error![]u8 {
        if (self.host) |backend| return backend.ops.list(backend.context, self.allocator, normalized, true, 0);
        const index = self.find(normalized) orelse return error.NotFound;
        if (self.entries.items[index].kind != .directory) return error.NotDirectory;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (self.entries.items) |entry| {
            if (entry.kind != .directory or !isDescendant(normalized, entry.path)) continue;
            paths.append(self.allocator, entry.path) catch return error.OutOfMemory;
        }
        sortSlices(paths.items);
        return joinNul(self.allocator, paths.items);
    }

    pub fn clearTemporary(self: *Vfs) void {
        if (self.host) |backend| return backend.ops.clear_temporary(backend.context);
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!isDescendant("/tmp", self.entries.items[index].path)) {
                index += 1;
                continue;
            }
            self.removeEntryAt(index);
        }
    }

    pub fn clearBorrowedOutput(self: *Vfs, output: *[]u8) void {
        if (output.*.len != 0) self.allocator.free(output.*);
        output.* = &.{};
    }

    fn find(self: *const Vfs, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
    }

    fn addDirectory(self: *Vfs, path: []const u8, read_only: bool) Error!void {
        const owned = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);
        self.entries.append(self.allocator, .{ .path = owned, .kind = .directory, .read_only = read_only }) catch return error.OutOfMemory;
    }

    fn addFile(self: *Vfs, path: []const u8, bytes: []const u8, read_only: bool) Error!void {
        const new_total = std.math.add(usize, self.total_bytes, bytes.len) catch return error.TooLarge;
        if (bytes.len > self.max_file_bytes or new_total > self.max_total_bytes) return error.TooLarge;
        const node = self.allocator.create(FileNode) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(node);
        node.* = .{ .read_only = read_only };
        if (bytes.len != 0) node.bytes = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        errdefer if (node.bytes.len != 0) self.allocator.free(node.bytes);
        self.nodes.append(self.allocator, node) catch return error.OutOfMemory;
        errdefer _ = self.nodes.pop();
        const owned_path = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_path);
        self.entries.append(self.allocator, .{ .path = owned_path, .kind = .file, .node = node, .read_only = read_only }) catch return error.OutOfMemory;
        self.total_bytes = new_total;
    }

    fn replaceMountedBytes(self: *Vfs, node: *FileNode, bytes: []const u8) Error!void {
        const new_total = std.math.add(usize, self.total_bytes - node.bytes.len, bytes.len) catch return error.TooLarge;
        if (bytes.len > self.max_file_bytes or new_total > self.max_total_bytes) return error.TooLarge;
        const replacement = if (bytes.len == 0) @as([]u8, &.{}) else self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        if (node.bytes.len != 0) self.allocator.free(node.bytes);
        node.bytes = replacement;
        self.total_bytes = new_total;
    }

    fn removeEntryAt(self: *Vfs, index: usize) void {
        const entry = self.entries.orderedRemove(index);
        self.allocator.free(entry.path);
        if (entry.node) |node| {
            std.debug.assert(node.links != 0);
            node.links -= 1;
            self.maybeDestroyNode(node);
        }
    }

    fn maybeDestroyNode(self: *Vfs, node: *FileNode) void {
        if (node.links != 0 or node.handles != 0) return;
        for (self.nodes.items, 0..) |candidate, index| {
            if (candidate != node) continue;
            self.total_bytes -= node.bytes.len;
            if (node.bytes.len != 0) self.allocator.free(node.bytes);
            self.allocator.destroy(node);
            _ = self.nodes.orderedRemove(index);
            return;
        }
        unreachable;
    }

    fn hasDescendants(self: *const Vfs, path: []const u8) bool {
        for (self.entries.items) |entry| if (isDescendant(path, entry.path)) return true;
        return false;
    }

    fn createMissingAssetParents(self: *Vfs, path: []const u8) Error!void {
        if (!std.mem.startsWith(u8, path, "/assets")) return error.PermissionDenied;
        var start: usize = "/assets".len + 1;
        while (start <= path.len) {
            const separator = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
            const directory_path = path[0..separator];
            if (self.find(directory_path)) |index| {
                if (self.entries.items[index].kind != .directory) return error.NotDirectory;
            } else {
                try self.addDirectory(directory_path, true);
            }
            if (separator == path.len) break;
            start = separator + 1;
        }
    }

    fn rollbackEntries(self: *Vfs, original_len: usize) void {
        while (self.entries.items.len > original_len) self.removeEntryAt(self.entries.items.len - 1);
    }
};

pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(allocator);
    normalized.append(allocator, '/') catch return error.OutOfMemory;
    if (path[0] != '/') {
        normalized.appendSlice(allocator, "home") catch return error.OutOfMemory;
        ends.append(allocator, normalized.items.len) catch return error.OutOfMemory;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (ends.items.len == 0) return error.InvalidPath;
            _ = ends.pop();
            normalized.shrinkRetainingCapacity(if (ends.items.len == 0) 1 else ends.items[ends.items.len - 1]);
            continue;
        }
        if (normalized.items.len > 1) normalized.append(allocator, '/') catch return error.OutOfMemory;
        normalized.appendSlice(allocator, component) catch return error.OutOfMemory;
        ends.append(allocator, normalized.items.len) catch return error.OutOfMemory;
    }
    return normalized.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parentPath(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return "/";
    return path[0..slash];
}

fn isWritablePath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/home") or std.mem.eql(u8, path, "/tmp") or
        std.mem.startsWith(u8, path, "/home/") or std.mem.startsWith(u8, path, "/tmp/");
}

fn isDescendant(directory: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, directory, "/")) return path.len > 1 and path[0] == '/';
    return path.len > directory.len and std.mem.startsWith(u8, path, directory) and path[directory.len] == '/';
}

fn sortSlices(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

fn joinNul(allocator: std.mem.Allocator, items: []const []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (items) |item| {
        output.appendSlice(allocator, item) catch return error.OutOfMemory;
        output.append(allocator, 0) catch return error.OutOfMemory;
    }
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

test "directory mutations are atomic and retain empty directories" {
    var fs = try Vfs.init(std.testing.allocator, 1024, 512);
    defer fs.deinit();
    try fs.mkdir("/home/tree/empty", true, false);
    try fs.write("/home/tree/data", "value", .replace);
    const before = try fs.listDirectory("/home/tree");
    defer fs.allocator.free(before);
    try std.testing.expectEqualStrings("data\x00empty\x00", before);
    try std.testing.expectError(error.InvalidMove, fs.rename("/home/tree", "/home/tree/empty/moved", true));
    try std.testing.expect(fs.exists("/home/tree/empty"));
    try fs.rename("/home/tree", "/home/moved", true);
    try std.testing.expect(fs.exists("/home/moved/empty"));
    try std.testing.expectError(error.IsDirectory, fs.remove("/home/moved/empty", false));
    try fs.remove("/home/moved/empty", true);
}

test "open file node survives rename and unlink" {
    var fs = try Vfs.init(std.testing.allocator, 1024, 512);
    defer fs.deinit();
    try fs.write("/home/live", "old", .replace);
    const node = try fs.fileNodeNormalized("/home/live");
    fs.retainFile(node);
    defer fs.releaseFile(node);
    try fs.rename("/home/live", "/home/renamed", true);
    try std.testing.expectEqualStrings("old", try fs.readNode(node));
    try fs.remove("/home/renamed", false);
    try fs.writeNode(node, "new", .replace);
    try std.testing.expectEqualStrings("new", try fs.readNode(node));
    try std.testing.expect(!fs.exists("/home/renamed"));
}

test "directory snapshot includes nested empty and read-only parents" {
    var fs = try Vfs.init(std.testing.allocator, 1024, 512);
    defer fs.deinit();
    try fs.mkdir("/home/persist/nested/empty", true, false);
    try fs.mountAsset("/assets/unit/sample.txt", "sample");
    const directories = try fs.listDirectories("/");
    defer fs.allocator.free(directories);
    try std.testing.expectEqualStrings(
        "/assets\x00/assets/unit\x00/home\x00/home/persist\x00/home/persist/nested\x00/home/persist/nested/empty\x00/tmp\x00",
        directories,
    );
    const nested = try fs.listDirectories("/home/persist");
    defer fs.allocator.free(nested);
    try std.testing.expectEqualStrings("/home/persist/nested\x00/home/persist/nested/empty\x00", nested);
}
