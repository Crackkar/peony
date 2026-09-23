const std = @import("std");
const gc = @import("runtime_gc");
const unicode = @import("runtime_unicode");
const exceptions = @import("runtime_exception");
const slice_utils = @import("runtime_slice");

pub const StringResult = exceptions.Result(*Str);
pub const SplitResult = exceptions.Result(SplitIterator);
pub const PythonExceptionKind = exceptions.PythonExceptionKind;

pub const Str = struct {
    header: gc.Header align(8),
    data: []u8,
    cached_codepoints: ?usize = null,
    cached_hash: ?u64 = null,
};

pub const SplitIterator = struct {
    source: []const u8,
    separator: []const u8,
    position: usize = 0,
    finished: bool = false,
    whitespace: bool = false,

    pub fn next(self: *SplitIterator) ?[]const u8 {
        if (self.whitespace) {
            while (self.position < self.source.len and unicode.hasProperty(codepointAt(self.source, self.position), .whitespace)) {
                self.position = nextOffset(self.source, self.position);
            }
            if (self.position >= self.source.len) return null;
            const start = self.position;
            while (self.position < self.source.len and !unicode.hasProperty(codepointAt(self.source, self.position), .whitespace)) {
                self.position = nextOffset(self.source, self.position);
            }
            return self.source[start..self.position];
        }
        if (self.finished) return null;
        if (std.mem.indexOf(u8, self.source[self.position..], self.separator)) |relative| {
            const found = self.position + relative;
            const item = self.source[self.position..found];
            self.position = found + self.separator.len;
            return item;
        }
        self.finished = true;
        const item = self.source[self.position..];
        self.position = self.source.len;
        return item;
    }
};

const str_kind = gc.Kind{ .destroy = destroyStr };

pub fn create(heap: *gc.Heap, input: []const u8) StringResult {
    if (!std.unicode.utf8ValidateSlice(input)) return pythonError(*Str, .value_error, "str data must be valid UTF-8");
    const data = heap.allocator.dupe(u8, input) catch return memoryError();
    return createOwned(heap, data);
}

pub fn content(value: *const Str) []const u8 {
    return value.data;
}

pub fn fromHeader(header: *gc.Header) ?*Str {
    if (header.kind != &str_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn length(value: *Str) usize {
    if (value.cached_codepoints) |cached| return cached;
    const computed = std.unicode.utf8CountCodepoints(value.data) catch unreachable;
    value.cached_codepoints = computed;
    return computed;
}

pub fn index(heap: *gc.Heap, value: *Str, index_value: i64) StringResult {
    const codepoint_count = length(value);
    const count_i64 = std.math.cast(i64, codepoint_count) orelse return pythonError(*Str, .overflow_error, "string is too large to index");
    const index_normalized = if (index_value < 0) index_value + count_i64 else index_value;
    if (index_normalized < 0 or index_normalized >= count_i64) return pythonError(*Str, .index_error, "string index out of range");
    const start = byteOffset(value.data, @intCast(index_normalized));
    const end = byteOffset(value.data, @intCast(index_normalized + 1));
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();
    return create(heap, value.data[start..end]);
}

pub fn slice(
    heap: *gc.Heap,
    value: *Str,
    start: ?i64,
    stop: ?i64,
    step: i64,
) StringResult {
    if (step == 0) return pythonError(*Str, .value_error, "slice step cannot be zero");
    const codepoint_count = std.math.cast(i64, length(value)) orelse return pythonError(*Str, .overflow_error, "string is too large to slice");
    return sliceNormalized(heap, value, slice_utils.normalizeI64(codepoint_count, start, stop, step));
}

pub fn sliceNormalized(heap: *gc.Heap, value: *Str, indices: slice_utils.BoundedIndices) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(heap.allocator);
    var index_value = indices.start;
    while (if (indices.step > 0) index_value < indices.stop else index_value > indices.stop) {
        const byte_start = byteOffset(value.data, @intCast(index_value));
        const byte_end = byteOffset(value.data, @intCast(index_value + 1));
        output.appendSlice(heap.allocator, value.data[byte_start..byte_end]) catch return memoryError();
        index_value = std.math.add(i128, index_value, indices.step) catch break;
    }
    return finishBuffer(heap, &output);
}

pub fn concat(heap: *gc.Heap, left: *Str, right: *Str) StringResult {
    const total = std.math.add(usize, left.data.len, right.data.len) catch return memoryError();
    var roots = RootScope{};
    roots.push(heap, left, right);
    defer roots.pop();

    const output = heap.allocator.alloc(u8, total) catch return memoryError();
    @memcpy(output[0..left.data.len], left.data);
    @memcpy(output[left.data.len..], right.data);
    return createOwned(heap, output);
}

pub fn equal(left: *const Str, right: *const Str) bool {
    return std.mem.eql(u8, left.data, right.data);
}

pub fn hash(value: *Str) u64 {
    if (value.cached_hash) |cached| return cached;
    const computed = hashBytes(value.data);
    value.cached_hash = computed;
    return computed;
}

pub fn find(value: *const Str, needle: []const u8) ?usize {
    const byte_index = std.mem.indexOf(u8, value.data, needle) orelse return null;
    return std.unicode.utf8CountCodepoints(value.data[0..byte_index]) catch unreachable;
}

pub fn startsWith(value: *const Str, prefix: []const u8) bool {
    return std.mem.startsWith(u8, value.data, prefix);
}

pub fn endsWith(value: *const Str, suffix: []const u8) bool {
    return std.mem.endsWith(u8, value.data, suffix);
}

pub fn split(value: *Str, separator: []const u8) SplitResult {
    if (separator.len == 0) return pythonError(SplitIterator, .value_error, "empty separator");
    return .{ .value = .{ .source = value.data, .separator = separator } };
}

pub fn splitWhitespace(value: *Str) SplitIterator {
    return .{ .source = value.data, .separator = "", .whitespace = true };
}

pub fn join(heap: *gc.Heap, separator: []const u8, parts: []const []const u8) StringResult {
    var total: usize = 0;
    for (parts, 0..) |part, index_value| {
        total = std.math.add(usize, total, part.len) catch return memoryError();
        if (index_value != 0) total = std.math.add(usize, total, separator.len) catch return memoryError();
    }
    const output = heap.allocator.alloc(u8, total) catch return memoryError();
    var offset: usize = 0;
    for (parts, 0..) |part, index_value| {
        if (index_value != 0) {
            @memcpy(output[offset..][0..separator.len], separator);
            offset += separator.len;
        }
        @memcpy(output[offset..][0..part.len], part);
        offset += part.len;
    }
    return createOwned(heap, output);
}

pub fn strip(heap: *gc.Heap, value: *Str, strip_chars: ?[]const u8) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();

    var start: usize = 0;
    var end = value.data.len;
    while (start < end) {
        const cp = codepointAt(value.data, start);
        if (!isStripChar(cp, strip_chars)) break;
        start = nextOffset(value.data, start);
    }
    while (end > start) {
        const previous = previousOffset(value.data, end);
        const cp = codepointAt(value.data, previous);
        if (!isStripChar(cp, strip_chars)) break;
        end = previous;
    }
    return create(heap, value.data[start..end]);
}

pub fn replace(
    heap: *gc.Heap,
    value: *Str,
    old: []const u8,
    replacement: []const u8,
    max_count: ?usize,
) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(heap.allocator);

    if (old.len == 0) {
        const limit = max_count orelse std.math.maxInt(usize);
        var position: usize = 0;
        var inserted: usize = 0;
        while (true) {
            if (inserted < limit) {
                output.appendSlice(heap.allocator, replacement) catch return memoryError();
                inserted += 1;
            }
            if (position == value.data.len) break;
            const next = nextOffset(value.data, position);
            output.appendSlice(heap.allocator, value.data[position..next]) catch return memoryError();
            position = next;
        }
        return finishBuffer(heap, &output);
    }

    const limit = max_count orelse std.math.maxInt(usize);
    var cursor: usize = 0;
    var replaced: usize = 0;
    while (replaced < limit) {
        const found = std.mem.indexOf(u8, value.data[cursor..], old) orelse break;
        const end = cursor + found;
        output.appendSlice(heap.allocator, value.data[cursor..end]) catch return memoryError();
        output.appendSlice(heap.allocator, replacement) catch return memoryError();
        cursor = end + old.len;
        replaced += 1;
    }
    output.appendSlice(heap.allocator, value.data[cursor..]) catch return memoryError();
    return finishBuffer(heap, &output);
}

pub fn count(value: *Str, needle: []const u8) usize {
    if (needle.len == 0) return length(value) + 1;
    var result: usize = 0;
    var cursor: usize = 0;
    while (cursor <= value.data.len) {
        const relative = std.mem.indexOf(u8, value.data[cursor..], needle) orelse break;
        cursor += relative + needle.len;
        result += 1;
    }
    return result;
}

pub fn removePrefix(heap: *gc.Heap, value: *Str, prefix: []const u8) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();
    const remaining = if (std.mem.startsWith(u8, value.data, prefix)) value.data[prefix.len..] else value.data;
    return create(heap, remaining);
}

pub fn removeSuffix(heap: *gc.Heap, value: *Str, suffix: []const u8) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();
    const remaining = if (std.mem.endsWith(u8, value.data, suffix)) value.data[0 .. value.data.len - suffix.len] else value.data;
    return create(heap, remaining);
}

pub fn lower(heap: *gc.Heap, value: *Str) StringResult {
    return transform(heap, value, .lower);
}

pub fn upper(heap: *gc.Heap, value: *Str) StringResult {
    return transform(heap, value, .upper);
}

pub fn title(heap: *gc.Heap, value: *Str) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(heap.allocator);

    var previous_cased = false;
    var offset: usize = 0;
    while (offset < value.data.len) {
        const cp = codepointAt(value.data, offset);
        if (unicode.hasProperty(cp, .cased)) {
            const kind: unicode.MappingKind = if (previous_cased) .lower else .title;
            appendMapped(&output, heap.allocator, value.data, offset, cp, kind) catch return memoryError();
            previous_cased = true;
        } else {
            appendCodepoint(&output, heap.allocator, cp) catch return memoryError();
            if (!unicode.hasProperty(cp, .title_ignorable)) previous_cased = false;
        }
        offset = nextOffset(value.data, offset);
    }
    return finishBuffer(heap, &output);
}

pub fn capitalize(heap: *gc.Heap, value: *Str) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(heap.allocator);

    var offset: usize = 0;
    var first = true;
    while (offset < value.data.len) {
        const cp = codepointAt(value.data, offset);
        const kind: unicode.MappingKind = if (first) .title else .lower;
        appendMapped(&output, heap.allocator, value.data, offset, cp, kind) catch return memoryError();
        first = false;
        offset = nextOffset(value.data, offset);
    }
    return finishBuffer(heap, &output);
}

pub fn casefold(heap: *gc.Heap, value: *Str) StringResult {
    return transform(heap, value, .casefold);
}

pub fn isAlpha(value: *const Str) bool {
    return allProperty(value, .alphabetic);
}

pub fn isAlnum(value: *const Str) bool {
    return allProperty(value, .alnum);
}

pub fn isDecimal(value: *const Str) bool {
    return allProperty(value, .decimal);
}

pub fn isDigit(value: *const Str) bool {
    return allProperty(value, .digit);
}

pub fn isNumeric(value: *const Str) bool {
    return allProperty(value, .numeric);
}

pub fn isSpace(value: *const Str) bool {
    return allProperty(value, .whitespace);
}

fn transform(heap: *gc.Heap, value: *Str, kind: unicode.MappingKind) StringResult {
    var roots = RootScope{};
    roots.push(heap, value, null);
    defer roots.pop();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(heap.allocator);

    var offset: usize = 0;
    while (offset < value.data.len) {
        const cp = codepointAt(value.data, offset);
        appendMapped(&output, heap.allocator, value.data, offset, cp, kind) catch return memoryError();
        offset = nextOffset(value.data, offset);
    }
    return finishBuffer(heap, &output);
}

fn appendMapped(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize,
    cp: u21,
    kind: unicode.MappingKind,
) std.mem.Allocator.Error!void {
    if (kind == .lower and cp == 0x03a3 and isFinalSigma(source, offset, nextOffset(source, offset))) {
        try appendCodepoint(output, allocator, 0x03c2);
        return;
    }
    const mapping = unicode.fullMapping(cp, kind);
    for (mapping.codepoints[0..mapping.count]) |mapped| {
        try appendCodepoint(output, allocator, mapped);
    }
}

fn isFinalSigma(source: []const u8, current_start: usize, current_end: usize) bool {
    var before = current_start;
    while (before > 0) {
        before = previousOffset(source, before);
        const cp = codepointAt(source, before);
        if (unicode.hasProperty(cp, .case_ignorable)) continue;
        if (!unicode.hasProperty(cp, .cased)) return false;
        break;
    } else return false;

    var after = current_end;
    while (after < source.len) {
        const cp = codepointAt(source, after);
        if (unicode.hasProperty(cp, .case_ignorable)) {
            after = nextOffset(source, after);
            continue;
        }
        return !unicode.hasProperty(cp, .cased);
    }
    return true;
}

fn appendCodepoint(output: *std.ArrayList(u8), allocator: std.mem.Allocator, codepoint: u21) std.mem.Allocator.Error!void {
    var encoded: [4]u8 = undefined;
    const length_encoded = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
    try output.appendSlice(allocator, encoded[0..length_encoded]);
}

fn finishBuffer(heap: *gc.Heap, output: *std.ArrayList(u8)) StringResult {
    const data = output.toOwnedSlice(heap.allocator) catch return memoryError();
    return createOwned(heap, data);
}

fn createOwned(heap: *gc.Heap, data: []u8) StringResult {
    const object = heap.createObject(Str, &str_kind) catch {
        heap.allocator.free(data);
        return memoryError();
    };
    const header = object.header;
    object.* = .{ .header = header, .data = data };
    return .{ .value = object };
}

fn destroyStr(header: *gc.Header, allocator: std.mem.Allocator) void {
    const value: *Str = @ptrCast(@alignCast(header));
    allocator.free(value.data);
    value.data = &.{};
}

fn allProperty(value: *const Str, property: unicode.Property) bool {
    if (value.data.len == 0) return false;
    var offset: usize = 0;
    while (offset < value.data.len) {
        if (!unicode.hasProperty(codepointAt(value.data, offset), property)) return false;
        offset = nextOffset(value.data, offset);
    }
    return true;
}

fn isStripChar(codepoint: u21, strip_chars: ?[]const u8) bool {
    if (strip_chars) |chars| return containsCodepoint(chars, codepoint);
    return unicode.hasProperty(codepoint, .whitespace);
}

fn containsCodepoint(value: []const u8, target: u21) bool {
    var offset: usize = 0;
    while (offset < value.len) {
        if (codepointAt(value, offset) == target) return true;
        offset = nextOffset(value, offset);
    }
    return false;
}

fn byteOffset(value: []const u8, codepoint_index: usize) usize {
    var offset: usize = 0;
    var index_value: usize = 0;
    while (index_value < codepoint_index) : (index_value += 1) offset = nextOffset(value, offset);
    return offset;
}

fn codepointAt(value: []const u8, offset: usize) u21 {
    const length_encoded = std.unicode.utf8ByteSequenceLength(value[offset]) catch unreachable;
    return std.unicode.utf8Decode(value[offset..][0..length_encoded]) catch unreachable;
}

fn nextOffset(value: []const u8, offset: usize) usize {
    const length_encoded = std.unicode.utf8ByteSequenceLength(value[offset]) catch unreachable;
    return offset + length_encoded;
}

fn previousOffset(value: []const u8, offset: usize) usize {
    var previous = offset - 1;
    while (previous > 0 and value[previous] & 0xc0 == 0x80) previous -= 1;
    return previous;
}

fn hashBytes(data: []const u8) u64 {
    var hash_value: u64 = 14_695_981_039_346_656_037;
    for (data) |byte| hash_value = (hash_value ^ byte) *% 1_099_511_628_211;
    return hash_value;
}

const RootScope = struct {
    frame: gc.RootFrame = .{},
    first: gc.Root = .{ .object = null },
    second: gc.Root = .{ .object = null },

    fn push(self: *RootScope, heap: *gc.Heap, first: *Str, second: ?*Str) void {
        self.frame.push(&heap.roots);
        self.first.object = &first.header;
        self.frame.add(&self.first);
        if (second) |value| {
            self.second.object = &value.header;
            self.frame.add(&self.second);
        }
    }

    fn pop(self: *RootScope) void {
        self.frame.pop();
    }
};

fn pythonError(comptime T: type, kind: PythonExceptionKind, message: []const u8) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}

fn memoryError() StringResult {
    return pythonError(*Str, .memory_error, "session memory limit exceeded");
}
