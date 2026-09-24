const std = @import("std");

pub const Error = error{
    InvalidPath,
    NotFound,
    Exists,
    NotDirectory,
    IsDirectory,
    PermissionDenied,
    TooLarge,
    OutOfMemory,
};

pub const EntryKind = enum { directory, file };
pub const WriteMode = enum { replace, append, exclusive };

pub const Entry = struct {
    path: []u8,
    kind: EntryKind,
    bytes: []u8 = &.{},
    read_only: bool = false,
};

pub const Vfs = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    total_bytes: usize = 0,
    max_total_bytes: usize,
    max_file_bytes: usize,

    pub fn init(allocator: std.mem.Allocator, max_total_bytes: usize, max_file_bytes: usize) Error!Vfs {
        var fs = Vfs{
            .allocator = allocator,
            .max_total_bytes = max_total_bytes,
            .max_file_bytes = @min(max_file_bytes, max_total_bytes),
        };
        errdefer fs.deinit();
        try fs.addDirectory("/", false);
        try fs.addDirectory("/course", true);
        try fs.addDirectory("/home", false);
        try fs.addDirectory("/tmp", false);
        return fs;
    }

    pub fn deinit(self: *Vfs) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
            if (entry.bytes.len != 0) self.allocator.free(entry.bytes);
        }
        self.entries.deinit(self.allocator);
        self.total_bytes = 0;
    }

    pub fn normalizeOwned(self: *const Vfs, path: []const u8) Error![]u8 {
        return normalizePath(self.allocator, path);
    }

    pub fn read(self: *const Vfs, path: []const u8) Error![]const u8 {
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        const index = self.find(normalized) orelse return error.NotFound;
        const entry = self.entries.items[index];
        if (entry.kind == .directory) return error.IsDirectory;
        return entry.bytes;
    }

    pub fn exists(self: *const Vfs, path: []const u8) bool {
        const normalized = normalizePath(self.allocator, path) catch return false;
        defer self.allocator.free(normalized);
        return self.find(normalized) != null;
    }

    pub fn existsNormalized(self: *const Vfs, normalized: []const u8) bool {
        return self.find(normalized) != null;
    }

    pub fn readNormalized(self: *const Vfs, normalized: []const u8) Error![]const u8 {
        const index = self.find(normalized) orelse return error.NotFound;
        const entry = self.entries.items[index];
        if (entry.kind == .directory) return error.IsDirectory;
        return entry.bytes;
    }

    pub fn isDirectoryNormalized(self: *const Vfs, normalized: []const u8) bool {
        const index = self.find(normalized) orelse return false;
        return self.entries.items[index].kind == .directory;
    }

    pub fn write(self: *Vfs, path: []const u8, bytes: []const u8, mode: WriteMode) Error!void {
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        try self.writeNormalized(normalized, bytes, mode);
    }

    pub fn writeNormalized(self: *Vfs, normalized: []const u8, bytes: []const u8, mode: WriteMode) Error!void {
        if (!isWritablePath(normalized)) return error.PermissionDenied;
        if (bytes.len > self.max_file_bytes) return error.TooLarge;
        const parent = parentPath(normalized) orelse return error.InvalidPath;
        const parent_index = self.find(parent) orelse return error.NotFound;
        if (self.entries.items[parent_index].kind != .directory) return error.NotDirectory;

        if (self.find(normalized)) |index| {
            var entry = &self.entries.items[index];
            if (entry.kind == .directory) return error.IsDirectory;
            if (entry.read_only) return error.PermissionDenied;
            if (mode == .exclusive) return error.Exists;
            const old_len = entry.bytes.len;
            const new_len = if (mode == .append) std.math.add(usize, old_len, bytes.len) catch return error.TooLarge else bytes.len;
            if (new_len > self.max_file_bytes) return error.TooLarge;
            const total_without_old = self.total_bytes - old_len;
            const new_total = std.math.add(usize, total_without_old, new_len) catch return error.TooLarge;
            if (new_total > self.max_total_bytes) return error.TooLarge;
            const replacement = self.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
            if (mode == .append) {
                @memcpy(replacement[0..old_len], entry.bytes);
                @memcpy(replacement[old_len..], bytes);
            } else {
                @memcpy(replacement, bytes);
            }
            if (entry.bytes.len != 0) self.allocator.free(entry.bytes);
            entry.bytes = replacement;
            self.total_bytes = new_total;
            return;
        }

        const new_total = std.math.add(usize, self.total_bytes, bytes.len) catch return error.TooLarge;
        if (new_total > self.max_total_bytes) return error.TooLarge;
        const owned_bytes = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        errdefer if (owned_bytes.len != 0) self.allocator.free(owned_bytes);
        const owned_path = self.allocator.dupe(u8, normalized) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_path);
        self.entries.append(self.allocator, .{ .path = owned_path, .kind = .file, .bytes = owned_bytes }) catch return error.OutOfMemory;
        self.total_bytes = new_total;
    }

    /// Mounts read-only course content. Missing parent directories are created
    /// transactionally so an allocation failure leaves the visible tree intact.
    pub fn mountCourse(self: *Vfs, path: []const u8, bytes: []const u8) Error!void {
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        if (!std.mem.startsWith(u8, normalized, "/course/") or normalized.len <= "/course/".len) return error.PermissionDenied;
        if (bytes.len > self.max_file_bytes) return error.TooLarge;
        const existing = self.find(normalized);
        if (existing) |index| {
            if (self.entries.items[index].kind != .file or !self.entries.items[index].read_only) return error.Exists;
            const new_total = self.total_bytes - self.entries.items[index].bytes.len + bytes.len;
            if (new_total > self.max_total_bytes) return error.TooLarge;
            const replacement = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
            self.allocator.free(self.entries.items[index].bytes);
            self.entries.items[index].bytes = replacement;
            self.total_bytes = new_total;
            return;
        }
        const new_total = std.math.add(usize, self.total_bytes, bytes.len) catch return error.TooLarge;
        if (new_total > self.max_total_bytes) return error.TooLarge;

        const original_len = self.entries.items.len;
        errdefer self.rollbackEntries(original_len);
        const parent = parentPath(normalized) orelse return error.InvalidPath;
        try self.createMissingCourseParents(parent);

        const owned_path = self.allocator.dupe(u8, normalized) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_path);
        const owned_bytes = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        errdefer if (owned_bytes.len != 0) self.allocator.free(owned_bytes);
        self.entries.append(self.allocator, .{ .path = owned_path, .kind = .file, .bytes = owned_bytes, .read_only = true }) catch return error.OutOfMemory;
        self.total_bytes = new_total;
    }

    pub fn list(self: *const Vfs, path: []const u8) Error![]u8 {
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        return self.listNormalized(normalized);
    }

    /// Returns NUL-separated full file paths below a directory, sorted by bytes.
    pub fn listNormalized(self: *const Vfs, normalized: []const u8) Error![]u8 {
        const index = self.find(normalized) orelse return error.NotFound;
        if (self.entries.items[index].kind != .directory) return error.NotDirectory;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (self.entries.items) |entry| {
            if (entry.kind != .file or !isDescendant(normalized, entry.path)) continue;
            paths.append(self.allocator, entry.path) catch return error.OutOfMemory;
        }
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (paths.items) |file_path| {
            output.appendSlice(self.allocator, file_path) catch return error.OutOfMemory;
            output.append(self.allocator, 0) catch return error.OutOfMemory;
        }
        return output.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    pub fn clearTemporary(self: *Vfs) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (!std.mem.startsWith(u8, entry.path, "/tmp/")) {
                index += 1;
                continue;
            }
            self.total_bytes -= entry.bytes.len;
            self.allocator.free(entry.path);
            if (entry.bytes.len != 0) self.allocator.free(entry.bytes);
            _ = self.entries.orderedRemove(index);
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

    fn createMissingCourseParents(self: *Vfs, path: []const u8) Error!void {
        if (!std.mem.startsWith(u8, path, "/course")) return error.PermissionDenied;
        var start: usize = "/course".len + 1;
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
        while (self.entries.items.len > original_len) {
            const entry = self.entries.pop().?;
            self.allocator.free(entry.path);
            if (entry.bytes.len != 0) self.allocator.free(entry.bytes);
        }
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
    return std.mem.startsWith(u8, path, "/home/") or std.mem.startsWith(u8, path, "/tmp/");
}

fn isDescendant(directory: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, directory, "/")) return path.len > 1 and path[0] == '/';
    return path.len > directory.len and std.mem.startsWith(u8, path, directory) and path[directory.len] == '/';
}
