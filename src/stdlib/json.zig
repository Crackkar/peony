const std = @import("std");

pub const max_nesting: usize = 256;
pub const max_token_bytes: usize = 256 * 1024;

pub const DecodeOptions = struct {
    allow_nonfinite: bool = true,
    nesting_limit: usize = max_nesting,
    token_limit: usize = max_token_bytes,
};

pub const Diagnostic = struct {
    message: []const u8,
    pos: usize,
    line: usize,
    column: usize,
};

pub const Event = union(enum) {
    null_value,
    boolean: bool,
    integer: []const u8,
    float: []const u8,
    string: []const u8,
    name: []const u8,
    array_begin,
    array_end,
    object_begin,
    object_end,
};

/// A bounded JSON decoder that emits values directly to a caller-owned sink.
/// Integer and float events borrow their exact source token. Decoded string and
/// name slices are valid only for the duration of `sink.emit(event)`.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    options: DecodeOptions,
    cursor: usize = 0,
    diagnostic: ?Diagnostic = null,

    pub fn init(allocator: std.mem.Allocator, input: []const u8, options: DecodeOptions) Decoder {
        return .{ .allocator = allocator, .input = input, .options = options };
    }

    pub fn decode(self: *Decoder, sink: anytype) !void {
        var cursor = DecodeCursor.init(self.allocator, self.input, self.options);
        defer cursor.deinit();
        while (true) {
            const event = cursor.next() catch |err| {
                self.cursor = cursor.parser.cursor;
                self.diagnostic = cursor.diagnostic();
                return err;
            };
            if (event == null) break;
            try sink.emit(event.?);
        }
        self.cursor = cursor.parser.cursor;
        self.diagnostic = cursor.diagnostic();
    }

    fn parseNumber(self: *Decoder, sink: anytype) !void {
        const start = self.cursor;
        _ = self.take('-');
        if (self.cursor >= self.input.len) return self.fail("invalid number");
        if (self.take('0')) {
            // A following digit remains as extra data, matching Python's
            // rejection of leading-zero integer tokens.
        } else {
            if (!isDigitOneToNine(self.input[self.cursor])) return self.fail("invalid number");
            self.cursor += 1;
            while (self.cursor < self.input.len and isDigit(self.input[self.cursor])) self.cursor += 1;
        }
        var is_float = false;
        if (self.take('.')) {
            is_float = true;
            const fraction_start = self.cursor;
            while (self.cursor < self.input.len and isDigit(self.input[self.cursor])) self.cursor += 1;
            if (fraction_start == self.cursor) return self.fail("invalid number");
        }
        if (self.cursor < self.input.len and (self.input[self.cursor] == 'e' or self.input[self.cursor] == 'E')) {
            is_float = true;
            self.cursor += 1;
            if (self.cursor < self.input.len and (self.input[self.cursor] == '+' or self.input[self.cursor] == '-')) self.cursor += 1;
            const exponent_start = self.cursor;
            while (self.cursor < self.input.len and isDigit(self.input[self.cursor])) self.cursor += 1;
            if (exponent_start == self.cursor) return self.fail("invalid number");
        }
        const token = self.input[start..self.cursor];
        if (token.len > self.options.token_limit) return self.failAt(start, "JSON token exceeds maximum length");
        if (is_float) try sink.emit(.{ .float = token }) else try sink.emit(.{ .integer = token });
    }

    fn parseNonfinite(self: *Decoder, sink: anytype, literal: []const u8) !void {
        if (!self.options.allow_nonfinite) return self.fail("non-finite number is not permitted");
        try self.consumeLiteral(literal);
        try sink.emit(.{ .float = literal });
    }

    fn decodeString(self: *Decoder) !std.ArrayList(u8) {
        if (!self.take('"')) return self.fail("expecting string");
        const token_start = self.cursor;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        while (self.cursor < self.input.len) {
            if (self.cursor - token_start > self.options.token_limit) return self.failAt(token_start, "JSON token exceeds maximum length");
            const byte = self.input[self.cursor];
            if (byte == '"') {
                self.cursor += 1;
                return output;
            }
            if (byte < 0x20) return self.fail("invalid control character in string");
            if (byte != '\\') {
                const width = std.unicode.utf8ByteSequenceLength(byte) catch return self.fail("invalid UTF-8 in string");
                const end = std.math.add(usize, self.cursor, width) catch return self.fail("invalid UTF-8 in string");
                if (end > self.input.len) return self.fail("invalid UTF-8 in string");
                try output.appendSlice(self.allocator, self.input[self.cursor..end]);
                self.cursor = end;
                continue;
            }
            self.cursor += 1;
            if (self.cursor >= self.input.len) return self.fail("unterminated escape sequence");
            const escaped = self.input[self.cursor];
            self.cursor += 1;
            switch (escaped) {
                '"', '\\', '/' => try output.append(self.allocator, escaped),
                'b' => try output.append(self.allocator, 0x08),
                'f' => try output.append(self.allocator, 0x0c),
                'n' => try output.append(self.allocator, '\n'),
                'r' => try output.append(self.allocator, '\r'),
                't' => try output.append(self.allocator, '\t'),
                'u' => {
                    const first = try self.hexQuad();
                    const codepoint: u21 = if (first >= 0xd800 and first <= 0xdbff) blk: {
                        if (self.cursor + 2 > self.input.len or self.input[self.cursor] != '\\' or self.input[self.cursor + 1] != 'u') return self.fail("lone high surrogate escape");
                        self.cursor += 2;
                        const second = try self.hexQuad();
                        if (second < 0xdc00 or second > 0xdfff) return self.fail("invalid low surrogate escape");
                        break :blk @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
                    } else if (first >= 0xdc00 and first <= 0xdfff)
                        return self.fail("lone low surrogate escape")
                    else
                        @intCast(first);
                    var encoded: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(codepoint, &encoded) catch return self.fail("invalid Unicode escape");
                    try output.appendSlice(self.allocator, encoded[0..count]);
                },
                else => return self.fail("invalid escape sequence"),
            }
        }
        return self.fail("unterminated string");
    }

    fn hexQuad(self: *Decoder) !u16 {
        const end = std.math.add(usize, self.cursor, 4) catch return self.fail("invalid Unicode escape");
        if (end > self.input.len) return self.fail("invalid Unicode escape");
        var value: u16 = 0;
        while (self.cursor < end) : (self.cursor += 1) {
            const digit = hexValue(self.input[self.cursor]) orelse return self.fail("invalid Unicode escape");
            value = value * 16 + digit;
        }
        return value;
    }

    fn consumeLiteral(self: *Decoder, literal: []const u8) !void {
        if (!std.mem.startsWith(u8, self.input[self.cursor..], literal)) return self.fail("expecting value");
        self.cursor += literal.len;
    }

    fn skipWhitespace(self: *Decoder) void {
        while (self.cursor < self.input.len) {
            switch (self.input[self.cursor]) {
                ' ', '\t', '\r', '\n' => self.cursor += 1,
                else => return,
            }
        }
    }

    fn take(self: *Decoder, expected: u8) bool {
        if (self.cursor >= self.input.len or self.input[self.cursor] != expected) return false;
        self.cursor += 1;
        return true;
    }

    fn fail(self: *Decoder, message: []const u8) error{InvalidJson} {
        return self.failAt(self.cursor, message);
    }

    fn failAt(self: *Decoder, pos: usize, message: []const u8) error{InvalidJson} {
        var line: usize = 1;
        var column: usize = 1;
        var character_pos: usize = 0;
        var cursor: usize = 0;
        const end = @min(pos, self.input.len);
        while (cursor < end) {
            const byte = self.input[cursor];
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
            character_pos += 1;
            const width = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            cursor += @min(@as(usize, width), end - cursor);
        }
        self.diagnostic = .{ .message = message, .pos = character_pos, .line = line, .column = column };
        return error.InvalidJson;
    }
};

/// Event-at-a-time decoder used by VM tasks. Each call performs one bounded
/// grammar transition and emits at most one event. String event storage is
/// owned by the cursor and remains valid until the next call.
pub const DecodeCursor = struct {
    const FrameKind = enum { array, object };
    const State = enum {
        array_first,
        array_value,
        array_separator,
        object_first,
        object_key,
        object_colon,
        object_separator,
    };
    const DecodeFrame = struct { kind: FrameKind, state: State };

    parser: Decoder,
    frames: [max_nesting]DecodeFrame = undefined,
    depth: usize = 0,
    initialized: bool = false,
    root_started: bool = false,
    complete: bool = false,
    string_buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, input: []const u8, options: DecodeOptions) DecodeCursor {
        return .{ .parser = Decoder.init(allocator, input, options) };
    }

    pub fn deinit(self: *DecodeCursor) void {
        self.string_buffer.deinit(self.parser.allocator);
        self.* = undefined;
    }

    pub fn diagnostic(self: *const DecodeCursor) ?Diagnostic {
        return self.parser.diagnostic;
    }

    pub fn next(self: *DecodeCursor) !?Event {
        if (self.complete) return null;
        if (!self.initialized) {
            self.initialized = true;
            self.parser.cursor = 0;
            self.parser.diagnostic = null;
            if (!std.unicode.utf8ValidateSlice(self.parser.input)) return self.parser.failAt(0, "input is not valid UTF-8");
        }
        while (true) {
            if (self.depth == 0) {
                if (!self.root_started) {
                    self.root_started = true;
                    self.parser.skipWhitespace();
                    return try self.startValue();
                }
                self.parser.skipWhitespace();
                if (self.parser.cursor != self.parser.input.len) return self.parser.fail("extra data");
                self.complete = true;
                return null;
            }

            const frame = &self.frames[self.depth - 1];
            self.parser.skipWhitespace();
            switch (frame.state) {
                .array_first => {
                    if (self.parser.take(']')) return self.closeContainer(.array);
                    frame.state = .array_separator;
                    return try self.startValue();
                },
                .array_value => {
                    frame.state = .array_separator;
                    return try self.startValue();
                },
                .array_separator => {
                    if (self.parser.take(']')) return self.closeContainer(.array);
                    if (!self.parser.take(',')) return self.parser.fail("expecting ',' delimiter");
                    frame.state = .array_value;
                },
                .object_first => {
                    if (self.parser.take('}')) return self.closeContainer(.object);
                    frame.state = .object_colon;
                    return try self.readName();
                },
                .object_key => {
                    frame.state = .object_colon;
                    return try self.readName();
                },
                .object_colon => {
                    if (!self.parser.take(':')) return self.parser.fail("expecting ':' delimiter");
                    self.parser.skipWhitespace();
                    frame.state = .object_separator;
                    return try self.startValue();
                },
                .object_separator => {
                    if (self.parser.take('}')) return self.closeContainer(.object);
                    if (!self.parser.take(',')) return self.parser.fail("expecting ',' delimiter");
                    self.parser.skipWhitespace();
                    frame.state = .object_key;
                },
            }
        }
    }

    fn startValue(self: *DecodeCursor) !Event {
        if (self.parser.cursor >= self.parser.input.len) return self.parser.fail("expecting value");
        const byte = self.parser.input[self.parser.cursor];
        return switch (byte) {
            'n' => blk: {
                try self.parser.consumeLiteral("null");
                break :blk .null_value;
            },
            't' => blk: {
                try self.parser.consumeLiteral("true");
                break :blk .{ .boolean = true };
            },
            'f' => blk: {
                try self.parser.consumeLiteral("false");
                break :blk .{ .boolean = false };
            },
            '"' => .{ .string = try self.readString() },
            '[' => blk: {
                self.parser.cursor += 1;
                try self.push(.array, .array_first);
                break :blk .array_begin;
            },
            '{' => blk: {
                self.parser.cursor += 1;
                try self.push(.object, .object_first);
                break :blk .object_begin;
            },
            'N' => try self.numberEvent("NaN"),
            'I' => try self.numberEvent("Infinity"),
            '-' => if (std.mem.startsWith(u8, self.parser.input[self.parser.cursor..], "-Infinity"))
                try self.numberEvent("-Infinity")
            else
                try self.numberEvent(null),
            '0'...'9' => try self.numberEvent(null),
            else => self.parser.fail("expecting value"),
        };
    }

    fn numberEvent(self: *DecodeCursor, nonfinite: ?[]const u8) !Event {
        const Capture = struct {
            event: ?Event = null,
            fn emit(capture: *@This(), event: Event) !void {
                capture.event = event;
            }
        };
        var capture = Capture{};
        if (nonfinite) |literal| {
            try self.parser.parseNonfinite(&capture, literal);
        } else {
            try self.parser.parseNumber(&capture);
        }
        return capture.event orelse error.InvalidJson;
    }

    fn readName(self: *DecodeCursor) !Event {
        if (self.parser.cursor >= self.parser.input.len or self.parser.input[self.parser.cursor] != '"') return self.parser.fail("expecting property name enclosed in double quotes");
        return .{ .name = try self.readString() };
    }

    fn readString(self: *DecodeCursor) ![]const u8 {
        self.string_buffer.deinit(self.parser.allocator);
        self.string_buffer = .empty;
        self.string_buffer = try self.parser.decodeString();
        return self.string_buffer.items;
    }

    fn push(self: *DecodeCursor, kind: FrameKind, state: State) !void {
        if (self.depth >= self.parser.options.nesting_limit or self.depth >= self.frames.len) return self.parser.fail("maximum nesting exceeded");
        self.frames[self.depth] = .{ .kind = kind, .state = state };
        self.depth += 1;
    }

    fn closeContainer(self: *DecodeCursor, expected: FrameKind) Event {
        std.debug.assert(self.depth != 0 and self.frames[self.depth - 1].kind == expected);
        self.depth -= 1;
        return if (expected == .array) .array_end else .object_end;
    }
};

pub const Indent = union(enum) {
    none,
    spaces: usize,
    text: []const u8,
};

pub const EncodeOptions = struct {
    indent: Indent = .none,
    sort_keys: bool = false,
    ensure_ascii: bool = true,
    allow_nan: bool = true,
    item_separator: ?[]const u8 = null,
    key_separator: ?[]const u8 = null,
    nesting_limit: usize = max_nesting,
    token_limit: usize = max_token_bytes,
};

const ContainerKind = enum { array, object };

const Frame = struct {
    kind: ContainerKind,
    count: usize = 0,
    waiting_for_value: bool = false,
};

/// An event encoder used by the Runtime's native-value traversal. It owns only
/// its checked output and structural stack; cycle detection, key conversion,
/// key sorting, and work scheduling remain with the caller that owns Values.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    options: EncodeOptions,
    output: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    root_written: bool = false,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: EncodeOptions) Encoder {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Encoder) void {
        self.output.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn emit(self: *Encoder, event: Event) !void {
        if (self.finished) return error.InvalidEventStream;
        switch (event) {
            .name => |name| try self.writeName(name),
            .array_end => try self.closeContainer(.array, ']'),
            .object_end => try self.closeContainer(.object, '}'),
            .array_begin => {
                try self.beforeValue();
                try self.output.append(self.allocator, '[');
                try self.pushFrame(.array);
            },
            .object_begin => {
                try self.beforeValue();
                try self.output.append(self.allocator, '{');
                try self.pushFrame(.object);
            },
            .null_value => {
                try self.beforeValue();
                try self.output.appendSlice(self.allocator, "null");
            },
            .boolean => |boolean| {
                try self.beforeValue();
                try self.output.appendSlice(self.allocator, if (boolean) "true" else "false");
            },
            .integer => |token| {
                if (!validNumberToken(token, false)) return error.InvalidNumberToken;
                try self.beforeValue();
                try self.output.appendSlice(self.allocator, token);
            },
            .float => |token| {
                const nonfinite = isNonfiniteToken(token);
                if (nonfinite and !self.options.allow_nan) return error.NonFiniteFloat;
                if (!nonfinite and !validNumberToken(token, true)) return error.InvalidNumberToken;
                try self.beforeValue();
                try self.output.appendSlice(self.allocator, token);
            },
            .string => |text| {
                try self.beforeValue();
                try self.writeString(text);
            },
        }
    }

    pub fn finish(self: *Encoder) ![]u8 {
        if (self.finished or !self.root_written or self.stack.items.len != 0) return error.InvalidEventStream;
        self.finished = true;
        return self.output.toOwnedSlice(self.allocator);
    }

    fn pushFrame(self: *Encoder, kind: ContainerKind) !void {
        if (self.stack.items.len >= self.options.nesting_limit) return error.NestingTooDeep;
        try self.stack.append(self.allocator, .{ .kind = kind });
    }

    fn beforeValue(self: *Encoder) !void {
        if (self.stack.items.len == 0) {
            if (self.root_written) return error.InvalidEventStream;
            self.root_written = true;
            return;
        }
        const frame = &self.stack.items[self.stack.items.len - 1];
        switch (frame.kind) {
            .array => {
                if (frame.count != 0) try self.output.appendSlice(self.allocator, self.itemSeparator());
                try self.writePrettyLine(self.stack.items.len);
                frame.count += 1;
            },
            .object => {
                if (!frame.waiting_for_value) return error.InvalidEventStream;
                frame.waiting_for_value = false;
            },
        }
    }

    fn writeName(self: *Encoder, name: []const u8) !void {
        if (self.stack.items.len == 0) return error.InvalidEventStream;
        const frame = &self.stack.items[self.stack.items.len - 1];
        if (frame.kind != .object or frame.waiting_for_value) return error.InvalidEventStream;
        if (frame.count != 0) try self.output.appendSlice(self.allocator, self.itemSeparator());
        try self.writePrettyLine(self.stack.items.len);
        try self.writeString(name);
        try self.output.appendSlice(self.allocator, self.keySeparator());
        frame.count += 1;
        frame.waiting_for_value = true;
    }

    fn closeContainer(self: *Encoder, kind: ContainerKind, close: u8) !void {
        if (self.stack.items.len == 0) return error.InvalidEventStream;
        const frame = self.stack.items[self.stack.items.len - 1];
        if (frame.kind != kind or frame.waiting_for_value) return error.InvalidEventStream;
        _ = self.stack.pop();
        if (frame.count != 0) try self.writePrettyLine(self.stack.items.len);
        try self.output.append(self.allocator, close);
    }

    fn writePrettyLine(self: *Encoder, depth: usize) !void {
        switch (self.options.indent) {
            .none => return,
            .spaces => |count| {
                try self.output.append(self.allocator, '\n');
                try appendRepeated(&self.output, self.allocator, " ", count, depth);
            },
            .text => |text| {
                try self.output.append(self.allocator, '\n');
                try appendRepeated(&self.output, self.allocator, text, 1, depth);
            },
        }
    }

    fn itemSeparator(self: *const Encoder) []const u8 {
        if (self.options.item_separator) |separator| return separator;
        return switch (self.options.indent) {
            .none => ", ",
            else => ",",
        };
    }

    fn keySeparator(self: *const Encoder) []const u8 {
        return self.options.key_separator orelse ": ";
    }

    fn writeString(self: *Encoder, text: []const u8) !void {
        if (text.len > self.options.token_limit) return error.TokenTooLong;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        try self.output.append(self.allocator, '"');
        var cursor: usize = 0;
        while (cursor < text.len) {
            const byte = text[cursor];
            switch (byte) {
                '"' => try self.output.appendSlice(self.allocator, "\\\""),
                '\\' => try self.output.appendSlice(self.allocator, "\\\\"),
                0x08 => try self.output.appendSlice(self.allocator, "\\b"),
                0x0c => try self.output.appendSlice(self.allocator, "\\f"),
                '\n' => try self.output.appendSlice(self.allocator, "\\n"),
                '\r' => try self.output.appendSlice(self.allocator, "\\r"),
                '\t' => try self.output.appendSlice(self.allocator, "\\t"),
                0x00...0x07, 0x0b, 0x0e...0x1f => try self.appendHexEscape(byte),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7f => try self.output.append(self.allocator, byte),
                else => {
                    const width = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
                    const end = cursor + width;
                    if (end > text.len) return error.InvalidUtf8;
                    const codepoint = std.unicode.utf8Decode(text[cursor..end]) catch return error.InvalidUtf8;
                    if (!self.options.ensure_ascii) {
                        try self.output.appendSlice(self.allocator, text[cursor..end]);
                    } else if (codepoint <= 0xffff) {
                        try self.appendHexEscape(@intCast(codepoint));
                    } else {
                        const adjusted: u32 = @as(u32, codepoint) - 0x10000;
                        const high: u16 = @intCast(0xd800 + (adjusted >> 10));
                        const low: u16 = @intCast(0xdc00 + (adjusted & 0x3ff));
                        try self.appendHexEscape(high);
                        try self.appendHexEscape(low);
                    }
                    cursor = end;
                    continue;
                },
            }
            cursor += 1;
        }
        try self.output.append(self.allocator, '"');
    }

    fn appendHexEscape(self: *Encoder, value: u16) !void {
        const digits = "0123456789abcdef";
        const bytes = [_]u8{
            '\\', 'u',
            digits[(value >> 12) & 0xf],
            digits[(value >> 8) & 0xf],
            digits[(value >> 4) & 0xf],
            digits[value & 0xf],
        };
        try self.output.appendSlice(self.allocator, &bytes);
    }
};

fn appendRepeated(output: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, multiplier: usize, depth: usize) !void {
    const repetitions = std.math.mul(usize, multiplier, depth) catch return error.OutOfMemory;
    const added = std.math.mul(usize, repetitions, text.len) catch return error.OutOfMemory;
    try output.ensureUnusedCapacity(allocator, added);
    for (0..repetitions) |_| output.appendSliceAssumeCapacity(text);
}

fn validNumberToken(token: []const u8, allow_float: bool) bool {
    if (token.len == 0) return false;
    var cursor: usize = 0;
    if (token[cursor] == '-') {
        cursor += 1;
        if (cursor == token.len) return false;
    }
    if (token[cursor] == '0') {
        cursor += 1;
        if (cursor < token.len and isDigit(token[cursor])) return false;
    } else {
        if (!isDigitOneToNine(token[cursor])) return false;
        cursor += 1;
        while (cursor < token.len and isDigit(token[cursor])) cursor += 1;
    }
    if (cursor < token.len and token[cursor] == '.') {
        if (!allow_float) return false;
        cursor += 1;
        const start = cursor;
        while (cursor < token.len and isDigit(token[cursor])) cursor += 1;
        if (cursor == start) return false;
    }
    if (cursor < token.len and (token[cursor] == 'e' or token[cursor] == 'E')) {
        if (!allow_float) return false;
        cursor += 1;
        if (cursor < token.len and (token[cursor] == '+' or token[cursor] == '-')) cursor += 1;
        const start = cursor;
        while (cursor < token.len and isDigit(token[cursor])) cursor += 1;
        if (cursor == start) return false;
    }
    return cursor == token.len;
}

fn isNonfiniteToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "NaN") or std.mem.eql(u8, token, "Infinity") or std.mem.eql(u8, token, "-Infinity");
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isDigitOneToNine(byte: u8) bool {
    return byte >= '1' and byte <= '9';
}

fn hexValue(byte: u8) ?u16 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "decoder preserves number tokens and decodes Unicode strings" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        events: std.ArrayList([]u8) = .empty,

        fn emit(self: *@This(), event: Event) !void {
            const text = switch (event) {
                .integer => |value| value,
                .float => |value| value,
                .string => |value| value,
                .name => |value| value,
                else => return,
            };
            try self.events.append(self.allocator, try self.allocator.dupe(u8, text));
        }

        fn deinit(self: *@This()) void {
            for (self.events.items) |item| self.allocator.free(item);
            self.events.deinit(self.allocator);
        }
    };
    var collector = Collector{ .allocator = std.testing.allocator };
    defer collector.deinit();
    var decoder = Decoder.init(std.testing.allocator, "{\"n\":123456789012345678901234567890,\"s\":\"\\u96ea \\ud834\\udd1e\",\"f\":-1.25e+3}", .{});
    try decoder.decode(&collector);
    try std.testing.expectEqual(@as(usize, 6), collector.events.items.len);
    try std.testing.expectEqualStrings("n", collector.events.items[0]);
    try std.testing.expectEqualStrings("123456789012345678901234567890", collector.events.items[1]);
    try std.testing.expectEqualStrings("s", collector.events.items[2]);
    try std.testing.expectEqualStrings("雪 𝄞", collector.events.items[3]);
    try std.testing.expectEqualStrings("f", collector.events.items[4]);
    try std.testing.expectEqualStrings("-1.25e+3", collector.events.items[5]);
}

test "decode cursor emits one event per bounded step" {
    var cursor = DecodeCursor.init(std.testing.allocator, "{\"a\":[1,\"\\u96ea\"],\"b\":true}", .{});
    defer cursor.deinit();
    const expected = [_]std.meta.Tag(Event){
        .object_begin,
        .name,
        .array_begin,
        .integer,
        .string,
        .array_end,
        .name,
        .boolean,
        .object_end,
    };
    for (expected) |tag| {
        const event = (try cursor.next()) orelse return error.ExpectedJsonCursorEvent;
        try std.testing.expectEqual(tag, std.meta.activeTag(event));
    }
    try std.testing.expect((try cursor.next()) == null);
}

test "decoder reports lone surrogates with location" {
    const Sink = struct { fn emit(_: *@This(), _: Event) !void {} };
    var sink = Sink{};
    var decoder = Decoder.init(std.testing.allocator, "{\n\"x\":\"\\ud800\"}", .{});
    try std.testing.expectError(error.InvalidJson, decoder.decode(&sink));
    try std.testing.expect(decoder.diagnostic != null);
    try std.testing.expectEqual(@as(usize, 2), decoder.diagnostic.?.line);
}

test "encoder streams compact and pretty JSON without a DOM" {
    var compact = Encoder.init(std.testing.allocator, .{ .ensure_ascii = true, .item_separator = ",", .key_separator = ":" });
    defer compact.deinit();
    try compact.emit(.object_begin);
    try compact.emit(.{ .name = "n" });
    try compact.emit(.{ .integer = "123456789012345678901234567890" });
    try compact.emit(.{ .name = "s" });
    try compact.emit(.{ .string = "雪 𝄞" });
    try compact.emit(.object_end);
    const encoded = try compact.finish();
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"n\":123456789012345678901234567890,\"s\":\"\\u96ea \\ud834\\udd1e\"}", encoded);

    var pretty = Encoder.init(std.testing.allocator, .{ .indent = .{ .text = "\t" }, .ensure_ascii = false });
    defer pretty.deinit();
    try pretty.emit(.array_begin);
    try pretty.emit(.{ .string = "雪" });
    try pretty.emit(.{ .boolean = true });
    try pretty.emit(.array_end);
    const pretty_text = try pretty.finish();
    defer std.testing.allocator.free(pretty_text);
    try std.testing.expectEqualStrings("[\n\t\"雪\",\n\ttrue\n]", pretty_text);
}

test "decoder rejects malformed numbers containers escapes and trailing data" {
    const Sink = struct { fn emit(_: *@This(), _: Event) !void {} };
    const invalid = [_][]const u8{
        "01",
        "1.",
        "1e",
        "+1",
        "[1,]",
        "{\"a\":1,}",
        "\"\\udc00\"",
        "\"\\ud800x\"",
        "true false",
    };
    for (invalid) |input| {
        var sink = Sink{};
        var decoder = Decoder.init(std.testing.allocator, input, .{});
        try std.testing.expectError(error.InvalidJson, decoder.decode(&sink));
        try std.testing.expect(decoder.diagnostic != null);
    }
}

test "encoder enforces nonfinite and structural event policy" {
    var finite = Encoder.init(std.testing.allocator, .{ .allow_nan = false });
    defer finite.deinit();
    try std.testing.expectError(error.NonFiniteFloat, finite.emit(.{ .float = "NaN" }));

    var invalid = Encoder.init(std.testing.allocator, .{});
    defer invalid.deinit();
    try invalid.emit(.object_begin);
    try invalid.emit(.{ .name = "missing" });
    try std.testing.expectError(error.InvalidEventStream, invalid.emit(.object_end));
}
