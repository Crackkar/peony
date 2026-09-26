const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const exceptions = @import("runtime_exception");
const vfs_module = @import("runtime_vfs");

const Value = value_module.Value;
const Heap = gc.Heap;

pub const Mode = struct {
    readable: bool,
    writable: bool,
    append: bool,
    exclusive: bool,
    binary: bool,
    update: bool,
    truncate: bool,
};

pub const File = struct {
    header: gc.Header align(8),
    fs: *vfs_module.Vfs,
    node: *vfs_module.FileNode,
    node_retained: bool = true,
    path: []u8,
    mode_text: []u8,
    mode: Mode,
    universal_newlines: bool,
    recognize_newlines: bool,
    cursor: usize = 0,
    closed: bool = false,
};

const file_kind = gc.Kind{ .destroy = destroyFile };

pub fn fromHeader(header: *gc.Header) ?*File {
    if (header.kind != &file_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn open(
    heap: *Heap,
    fs: *vfs_module.Vfs,
    path: []const u8,
    mode_text: []const u8,
    encoding: ?[]const u8,
    newline: ?[]const u8,
) exceptions.Result(*File) {
    const mode = parseMode(mode_text) orelse return pythonError(*File, .value_error, "invalid mode");
    if (mode.binary) {
        if (encoding != null) return pythonError(*File, .value_error, "binary mode doesn't take an encoding argument");
        if (newline != null) return pythonError(*File, .value_error, "binary mode doesn't take a newline argument");
    } else if (encoding) |selected| {
        if (!isUtf8Encoding(selected)) return pythonError(*File, .lookup_error, "unknown encoding");
    }
    if (newline) |selected| {
        if (selected.len != 0) return pythonError(*File, .value_error, "newline must be None or an empty string");
    }

    const normalized = vfs_module.normalizePath(heap.allocator, path) catch |err| return .{ .python_exception = pathException(err) };
    var node: ?*vfs_module.FileNode = fs.fileNodeNormalized(normalized) catch |err| switch (err) {
        error.NotFound => null,
        else => {
            heap.allocator.free(normalized);
            return .{ .python_exception = pathException(err) };
        },
    };
    const exists = node != null;
    const existing_len = if (node) |selected| selected.bytes.len else 0;
    if (mode.exclusive and exists) {
        heap.allocator.free(normalized);
        return pythonError(*File, .file_exists_error, "file already exists");
    }
    if (mode.readable and !exists and !mode.truncate and !mode.append and !mode.exclusive) {
        heap.allocator.free(normalized);
        return .{ .python_exception = pathException(error.NotFound) };
    }

    if (mode.writable and !std.mem.startsWith(u8, normalized, "/home/") and !std.mem.startsWith(u8, normalized, "/tmp/")) {
        heap.allocator.free(normalized);
        return .{ .python_exception = pathException(error.PermissionDenied) };
    }
    if (mode.truncate or mode.exclusive or (mode.append and !exists)) {
        const write_mode: vfs_module.WriteMode = if (mode.exclusive) .exclusive else .replace;
        fs.writeNormalized(normalized, &.{}, write_mode) catch |err| {
            heap.allocator.free(normalized);
            return .{ .python_exception = pathException(err) };
        };
    }

    if (node == null) node = fs.fileNodeNormalized(normalized) catch |err| {
        heap.allocator.free(normalized);
        return .{ .python_exception = pathException(err) };
    };

    const owned_mode = heap.allocator.dupe(u8, mode_text) catch {
        heap.allocator.free(normalized);
        return pythonError(*File, .memory_error, "session memory limit exceeded");
    };
    const object = heap.createObject(File, &file_kind) catch {
        heap.allocator.free(owned_mode);
        heap.allocator.free(normalized);
        return pythonError(*File, .memory_error, "session memory limit exceeded");
    };
    object.* = .{
        .header = object.header,
        .fs = fs,
        .node = node.?,
        .path = normalized,
        .mode_text = owned_mode,
        .mode = mode,
        .universal_newlines = newline == null,
        .recognize_newlines = newline == null or (newline != null and newline.?.len == 0),
        .cursor = if (mode.append) existing_len else 0,
    };
    fs.retainFile(node.?);
    return .{ .value = object };
}

pub fn readBuffer(heap: *Heap, fs: *vfs_module.Vfs, file: *File, size: ?i64, line_mode: bool) exceptions.Result([]u8) {
    if (file.closed) return pythonError([]u8, .value_error, "I/O operation on closed file");
    if (!file.mode.readable) return pythonError([]u8, .os_error, "file not open for reading");
    const contents = fs.readNode(file.node) catch |err| return .{ .python_exception = pathException(err) };
    const limit: ?usize = if (size) |selected| if (selected < 0) null else std.math.cast(usize, selected) orelse return pythonError([]u8, .overflow_error, "read length is too large") else null;
    if (!line_mode and file.cursor <= contents.len and (file.mode.binary or limit == null)) {
        const end = if (file.mode.binary and limit != null)
            @min(contents.len, file.cursor +| limit.?)
        else
            contents.len;
        const direct = contents[file.cursor..end];
        if (file.mode.binary or (!file.universal_newlines or std.mem.indexOfScalar(u8, direct, '\r') == null)) {
            if (!file.mode.binary and !std.unicode.utf8ValidateSlice(direct)) return pythonError([]u8, .unicode_decode_error, "invalid UTF-8 data in file");
            const result = heap.allocator.dupe(u8, direct) catch return pythonError([]u8, .memory_error, "session memory limit exceeded");
            file.cursor = end;
            return .{ .value = result };
        }
    }
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(heap.allocator);
    var cursor = file.cursor;
    var characters: usize = 0;
    while (cursor < contents.len and (limit == null or characters < limit.?)) {
        const start = cursor;
        const first = contents[cursor];
        if (first == '\r' and file.recognize_newlines and !file.mode.binary) {
            cursor += 1;
            const paired_lf = cursor < contents.len and contents[cursor] == '\n';
            if (file.universal_newlines) {
                if (paired_lf) cursor += 1;
                output.append(heap.allocator, '\n') catch return pythonError([]u8, .memory_error, "session memory limit exceeded");
                characters += 1;
            } else {
                output.append(heap.allocator, '\r') catch return pythonError([]u8, .memory_error, "session memory limit exceeded");
                characters += 1;
                if (line_mode and paired_lf and (limit == null or characters < limit.?)) {
                    cursor += 1;
                    output.append(heap.allocator, '\n') catch return pythonError([]u8, .memory_error, "session memory limit exceeded");
                    characters += 1;
                }
            }
            if (line_mode) break;
            continue;
        }
        const width = std.unicode.utf8ByteSequenceLength(first) catch 0;
        if (!file.mode.binary and width == 0) return pythonError([]u8, .unicode_decode_error, "invalid UTF-8 data in file");
        cursor += if (file.mode.binary) 1 else width;
        if (cursor > contents.len or (!file.mode.binary and !std.unicode.utf8ValidateSlice(contents[start..cursor]))) return pythonError([]u8, .unicode_decode_error, "invalid UTF-8 data in file");
        output.appendSlice(heap.allocator, contents[start..cursor]) catch return pythonError([]u8, .memory_error, "session memory limit exceeded");
        characters += 1;
        if (line_mode and (first == '\n' or (!file.recognize_newlines and first == '\r'))) break;
    }
    const result = output.toOwnedSlice(heap.allocator) catch return pythonError([]u8, .memory_error, "session memory limit exceeded");
    file.cursor = cursor;
    return .{ .value = result };
}

pub fn writeBuffer(heap: *Heap, fs: *vfs_module.Vfs, file: *File, bytes: []const u8) exceptions.Result(usize) {
    if (file.closed) return pythonError(usize, .value_error, "I/O operation on closed file");
    if (!file.mode.writable) return pythonError(usize, .os_error, "file not open for writing");
    if (!file.mode.binary and !std.unicode.utf8ValidateSlice(bytes)) return pythonError(usize, .unicode_encode_error, "text file write contains invalid UTF-8");
    const old = fs.readNode(file.node) catch |err| return .{ .python_exception = pathException(err) };
    const position = if (file.mode.append) old.len else file.cursor;
    const end = std.math.add(usize, position, bytes.len) catch return pythonError(usize, .memory_error, "session memory limit exceeded");
    const new_len = @max(old.len, end);
    const replacement = heap.allocator.alloc(u8, new_len) catch return pythonError(usize, .memory_error, "session memory limit exceeded");
    if (old.len != 0) @memcpy(replacement[0..old.len], old);
    if (position > old.len) @memset(replacement[old.len..position], 0);
    @memcpy(replacement[position..end], bytes);
    if (end < old.len) @memcpy(replacement[end..], old[end..]);
    fs.replaceNodeOwned(file.node, replacement) catch |err| {
        if (replacement.len != 0) heap.allocator.free(replacement);
        return .{ .python_exception = pathException(err) };
    };
    file.cursor = end;
    return .{ .value = if (file.mode.binary) bytes.len else std.unicode.utf8CountCodepoints(bytes) catch bytes.len };
}

pub fn seek(fs: *vfs_module.Vfs, file: *File, offset: i64, whence: i64) exceptions.Result(usize) {
    if (file.closed) return pythonError(usize, .value_error, "I/O operation on closed file");
    if (whence < 0 or whence > 2) return pythonError(usize, .value_error, "invalid whence value");
    if (!file.mode.binary and ((whence != 0 and offset != 0) or (whence == 0 and offset < 0))) return pythonError(usize, .value_error, "invalid seek in text mode");
    const contents = fs.readNode(file.node) catch |err| return .{ .python_exception = pathException(err) };
    const base: i128 = switch (whence) {
        0 => 0,
        1 => @intCast(file.cursor),
        2 => @intCast(contents.len),
        else => unreachable,
    };
    const target = base + offset;
    if (target < 0 or target > std.math.maxInt(usize)) return pythonError(usize, .value_error, "negative seek position");
    file.cursor = @intCast(target);
    return .{ .value = file.cursor };
}

pub fn truncate(heap: *Heap, fs: *vfs_module.Vfs, file: *File, requested: ?i64) exceptions.Result(usize) {
    if (file.closed) return pythonError(usize, .value_error, "I/O operation on closed file");
    if (!file.mode.writable) return pythonError(usize, .os_error, "file not open for writing");
    const target = if (requested) |selected| if (selected < 0) return pythonError(usize, .value_error, "negative size value") else std.math.cast(usize, selected) orelse return pythonError(usize, .overflow_error, "file size is too large") else file.cursor;
    const old = fs.readNode(file.node) catch |err| return .{ .python_exception = pathException(err) };
    const replacement = heap.allocator.alloc(u8, target) catch return pythonError(usize, .memory_error, "session memory limit exceeded");
    const copied = @min(old.len, target);
    if (copied != 0) @memcpy(replacement[0..copied], old[0..copied]);
    if (target > copied) @memset(replacement[copied..], 0);
    fs.replaceNodeOwned(file.node, replacement) catch |err| {
        if (replacement.len != 0) heap.allocator.free(replacement);
        return .{ .python_exception = pathException(err) };
    };
    return .{ .value = target };
}

pub fn close(file: *File) void {
    if (file.node_retained) {
        file.fs.releaseFile(file.node);
        file.node_retained = false;
    }
    file.closed = true;
}

pub fn flush(file: *File) exceptions.Result(void) {
    if (file.closed) return pythonError(void, .value_error, "I/O operation on closed file");
    return .{ .value = {} };
}

pub fn valueException(kind: exceptions.PythonExceptionKind, message: []const u8) exceptions.PythonException {
    return .{ .kind = kind, .message = message };
}

pub fn pathException(err: vfs_module.Error) exceptions.PythonException {
    return switch (err) {
        error.InvalidPath => valueException(.value_error, "invalid or unsafe path"),
        error.InvalidMove => valueException(.os_error, "cannot move a directory into itself"),
        error.NotFound => valueException(.file_not_found_error, "file or directory not found"),
        error.Exists => valueException(.file_exists_error, "file already exists"),
        error.NotDirectory => valueException(.os_error, "parent path is not a directory"),
        error.IsDirectory => valueException(.os_error, "is a directory"),
        error.PermissionDenied => valueException(.permission_error, "permission denied"),
        error.TooLarge => valueException(.os_error, "file or VFS size limit exceeded"),
        error.OutOfMemory => valueException(.memory_error, "session memory limit exceeded"),
    };
}

pub fn exceptionName(kind: exceptions.PythonExceptionKind) []const u8 {
    return switch (kind) {
        .file_not_found_error => "FileNotFoundError",
        .file_exists_error => "FileExistsError",
        .permission_error => "PermissionError",
        .lookup_error => "LookupError",
        .unicode_decode_error => "UnicodeDecodeError",
        .unicode_encode_error => "UnicodeEncodeError",
        .value_error => "ValueError",
        .os_error => "OSError",
        .memory_error => "MemoryError",
        .overflow_error => "OverflowError",
        .type_error => "TypeError",
        else => "Exception",
    };
}

fn parseMode(text: []const u8) ?Mode {
    if (text.len == 0) return null;
    var base: ?u8 = null;
    var plus = false;
    var binary = false;
    var text_mode = false;
    for (text) |character| {
        switch (character) {
            'r', 'w', 'a', 'x' => {
                if (base != null) return null;
                base = character;
            },
            '+' => {
                if (plus) return null;
                plus = true;
            },
            'b' => {
                if (binary or text_mode) return null;
                binary = true;
            },
            't' => {
                if (text_mode or binary) return null;
                text_mode = true;
            },
            else => return null,
        }
    }
    const selected = base orelse return null;
    return .{
        .readable = selected == 'r' or plus,
        .writable = selected != 'r' or plus,
        .append = selected == 'a',
        .exclusive = selected == 'x',
        .binary = binary,
        .update = plus,
        .truncate = selected == 'w',
    };
}

fn isUtf8Encoding(encoding: []const u8) bool {
    var normalized: [16]u8 = undefined;
    if (encoding.len > normalized.len) return false;
    var index: usize = 0;
    for (encoding) |character| {
        if (character == '-' or character == '_' or character == ' ') continue;
        normalized[index] = std.ascii.toLower(character);
        index += 1;
    }
    return std.mem.eql(u8, normalized[0..index], "utf8");
}

fn destroyFile(header: *gc.Header, allocator: std.mem.Allocator) void {
    const file: *File = @ptrCast(@alignCast(header));
    close(file);
    allocator.free(file.path);
    file.path = &.{};
    allocator.free(file.mode_text);
    file.mode_text = &.{};
}

fn pythonError(comptime T: type, kind: exceptions.PythonExceptionKind, message: []const u8) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}
