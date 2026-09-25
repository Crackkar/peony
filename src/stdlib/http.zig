const std = @import("std");

pub const max_packet_bytes: usize = 1024 * 1024;
pub const packet_header_bytes: usize = 24;
pub const section_descriptor_bytes: usize = 12;
pub const max_packet_sections: usize = 64;
pub const max_header_count: usize = 256;

pub const Error = error{
    OutOfMemory,
    InvalidUrl,
    InvalidHeader,
    UnsupportedEncoding,
    InvalidText,
    PacketTooLarge,
};

pub const Header = struct {
    name: []u8,
    value: []u8,
};

pub const Headers = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Header) = .empty,

    pub fn init(allocator: std.mem.Allocator) Headers {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Headers) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Headers, name: []const u8, value: []const u8) Error!void {
        if (self.entries.items.len >= max_header_count or !validHeaderName(name) or !validHeaderValue(value)) return error.InvalidHeader;
        const owned_name = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_name);
        const owned_value = self.allocator.dupe(u8, trimOws(value)) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_value);
        self.entries.append(self.allocator, .{ .name = owned_name, .value = owned_value }) catch return error.OutOfMemory;
    }

    pub fn set(self: *Headers, name: []const u8, value: []const u8) Error!void {
        if (!validHeaderName(name) or !validHeaderValue(value)) return error.InvalidHeader;
        var first: ?usize = null;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!asciiEqualIgnoreCase(self.entries.items[index].name, name)) {
                index += 1;
                continue;
            }
            if (first == null) {
                first = index;
                index += 1;
            } else {
                const removed = self.entries.orderedRemove(index);
                self.allocator.free(removed.name);
                self.allocator.free(removed.value);
            }
        }
        if (first) |existing| {
            const owned = self.allocator.dupe(u8, trimOws(value)) catch return error.OutOfMemory;
            self.allocator.free(self.entries.items[existing].value);
            self.entries.items[existing].value = owned;
            return;
        }
        try self.append(name, value);
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| if (asciiEqualIgnoreCase(entry.name, name)) return entry.value;
        return null;
    }

    pub fn contains(self: *const Headers, name: []const u8) bool {
        return self.get(name) != null;
    }

    pub fn parse(allocator: std.mem.Allocator, block: []const u8) Error!Headers {
        if (!std.unicode.utf8ValidateSlice(block)) return error.InvalidHeader;
        var headers = Headers.init(allocator);
        errdefer headers.deinit();
        if (block.len == 0) return headers;
        var offset: usize = 0;
        while (offset < block.len) {
            const relative = std.mem.indexOf(u8, block[offset..], "\r\n") orelse return error.InvalidHeader;
            const relative_end = offset + relative;
            const line = block[offset..relative_end];
            offset = relative_end + 2;
            if (line.len == 0) {
                if (offset != block.len) return error.InvalidHeader;
                break;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
            if (colon == 0) return error.InvalidHeader;
            try headers.append(line[0..colon], trimOws(line[colon + 1 ..]));
        }
        return headers;
    }

    pub fn serialize(self: *const Headers, allocator: std.mem.Allocator) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        for (self.entries.items) |entry| {
            output.appendSlice(allocator, entry.name) catch return error.OutOfMemory;
            output.appendSlice(allocator, ": ") catch return error.OutOfMemory;
            output.appendSlice(allocator, entry.value) catch return error.OutOfMemory;
            output.appendSlice(allocator, "\r\n") catch return error.OutOfMemory;
        }
        return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }
};

pub const Encoding = enum { utf8, ascii, latin1 };

pub fn parseEncoding(name: []const u8) Error!Encoding {
    const trimmed = trimAsciiWhitespace(name);
    if (asciiEqualIgnoreCase(trimmed, "utf-8") or asciiEqualIgnoreCase(trimmed, "utf8")) return .utf8;
    if (asciiEqualIgnoreCase(trimmed, "ascii") or asciiEqualIgnoreCase(trimmed, "us-ascii")) return .ascii;
    if (asciiEqualIgnoreCase(trimmed, "latin-1") or asciiEqualIgnoreCase(trimmed, "latin1") or asciiEqualIgnoreCase(trimmed, "iso-8859-1") or asciiEqualIgnoreCase(trimmed, "iso8859-1")) return .latin1;
    return error.UnsupportedEncoding;
}

pub fn contentTypeEncoding(content_type: ?[]const u8) Error!Encoding {
    const value = content_type orelse return .utf8;
    var iterator = std.mem.splitScalar(u8, value, ';');
    _ = iterator.next();
    while (iterator.next()) |parameter| {
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const name = trimAsciiWhitespace(parameter[0..equals]);
        if (!asciiEqualIgnoreCase(name, "charset")) continue;
        var encoding = trimAsciiWhitespace(parameter[equals + 1 ..]);
        if (encoding.len >= 2 and ((encoding[0] == '"' and encoding[encoding.len - 1] == '"') or (encoding[0] == '\'' and encoding[encoding.len - 1] == '\''))) {
            encoding = encoding[1 .. encoding.len - 1];
        }
        return parseEncoding(encoding);
    }
    return .utf8;
}

pub fn decodeText(allocator: std.mem.Allocator, input: []const u8, encoding: Encoding) Error![]u8 {
    return switch (encoding) {
        .utf8 => decodeUtf8Replacing(allocator, input),
        .ascii => decodeAsciiReplacing(allocator, input),
        .latin1 => decodeLatin1(allocator, input),
    };
}

pub fn validateUrl(url: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(url) or url.len == 0) return error.InvalidUrl;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const scheme = url[0..scheme_end];
    if (!asciiEqualIgnoreCase(scheme, "http") and !asciiEqualIgnoreCase(scheme, "https")) return error.InvalidUrl;
    const authority_start = scheme_end + 3;
    if (authority_start >= url.len) return error.InvalidUrl;
    var authority_end = url.len;
    for (url[authority_start..], authority_start..) |byte, index| {
        if (byte == '/' or byte == '?' or byte == '#') {
            authority_end = index;
            break;
        }
    }
    if (authority_end == authority_start) return error.InvalidUrl;
    for (url) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidUrl;
}

pub fn appendQuery(allocator: std.mem.Allocator, url: []const u8, encoded_query: []const u8) Error![]u8 {
    try validateUrl(url);
    if (encoded_query.len == 0) return allocator.dupe(u8, url) catch error.OutOfMemory;
    const fragment = std.mem.indexOfScalar(u8, url, '#');
    const prefix = if (fragment) |position| url[0..position] else url;
    const suffix = if (fragment) |position| url[position..] else "";
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    output.appendSlice(allocator, prefix) catch return error.OutOfMemory;
    if (std.mem.indexOfScalar(u8, prefix, '?') == null) {
        output.append(allocator, '?') catch return error.OutOfMemory;
    } else if (!std.mem.endsWith(u8, prefix, "?") and !std.mem.endsWith(u8, prefix, "&")) {
        output.append(allocator, '&') catch return error.OutOfMemory;
    }
    output.appendSlice(allocator, encoded_query) catch return error.OutOfMemory;
    output.appendSlice(allocator, suffix) catch return error.OutOfMemory;
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn appendFormPair(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8, value: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(key) or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    if (output.items.len != 0) output.append(allocator, '&') catch return error.OutOfMemory;
    try appendFormComponent(allocator, output, key);
    output.append(allocator, '=') catch return error.OutOfMemory;
    try appendFormComponent(allocator, output, value);
}

pub fn appendFormComponent(allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8) Error!void {
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (isFormSafe(byte)) {
            output.append(allocator, byte) catch return error.OutOfMemory;
        } else if (byte == ' ') {
            output.append(allocator, '+') catch return error.OutOfMemory;
        } else {
            output.append(allocator, '%') catch return error.OutOfMemory;
            output.append(allocator, hex[byte >> 4]) catch return error.OutOfMemory;
            output.append(allocator, hex[byte & 0x0f]) catch return error.OutOfMemory;
        }
    }
}

pub fn packetSize(section_lengths: []const usize) Error!usize {
    if (section_lengths.len > max_packet_sections) return error.PacketTooLarge;
    const descriptors = std.math.mul(usize, section_lengths.len, section_descriptor_bytes) catch return error.PacketTooLarge;
    var total = std.math.add(usize, packet_header_bytes, descriptors) catch return error.PacketTooLarge;
    for (section_lengths) |length| total = std.math.add(usize, total, length) catch return error.PacketTooLarge;
    if (total > max_packet_bytes) return error.PacketTooLarge;
    return total;
}

pub fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!isToken(byte)) return false;
    return true;
}

pub fn validHeaderValue(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte == '\r' or byte == '\n' or byte == 0 or byte == 0x7f or byte < 0x20 and byte != '\t') return false;
    return true;
}

pub fn asciiEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (asciiLower(a) != asciiLower(b)) return false;
    return true;
}

fn decodeUtf8Replacing(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (std.unicode.utf8ValidateSlice(input)) return allocator.dupe(u8, input) catch error.OutOfMemory;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        const width = std.unicode.utf8ByteSequenceLength(input[index]) catch {
            try appendReplacement(allocator, &output);
            index += 1;
            continue;
        };
        if (index + width > input.len) {
            try appendReplacement(allocator, &output);
            index += invalidSequenceLength(input[index..], width);
            continue;
        }
        _ = std.unicode.utf8Decode(input[index..][0..width]) catch {
            try appendReplacement(allocator, &output);
            index += invalidSequenceLength(input[index..], width);
            continue;
        };
        output.appendSlice(allocator, input[index..][0..width]) catch return error.OutOfMemory;
        index += width;
    }
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn decodeAsciiReplacing(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (input) |byte| {
        if (byte < 0x80) {
            output.append(allocator, byte) catch return error.OutOfMemory;
        } else {
            try appendReplacement(allocator, &output);
        }
    }
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn decodeLatin1(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (input) |byte| {
        if (byte < 0x80) {
            output.append(allocator, byte) catch return error.OutOfMemory;
        } else {
            output.append(allocator, 0xc0 | (byte >> 6)) catch return error.OutOfMemory;
            output.append(allocator, 0x80 | (byte & 0x3f)) catch return error.OutOfMemory;
        }
    }
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn appendReplacement(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) Error!void {
    output.appendSlice(allocator, "\xef\xbf\xbd") catch return error.OutOfMemory;
}

fn invalidSequenceLength(input: []const u8, expected: usize) usize {
    var length: usize = 1;
    while (length < input.len and length < expected and input[length] & 0xc0 == 0x80) length += 1;
    return length;
}

fn isFormSafe(byte: u8) bool {
    return byte >= 'a' and byte <= 'z' or byte >= 'A' and byte <= 'Z' or byte >= '0' and byte <= '9' or byte == '*' or byte == '-' or byte == '.' or byte == '_';
}

fn isToken(byte: u8) bool {
    if (byte >= 'a' and byte <= 'z' or byte >= 'A' and byte <= 'Z' or byte >= '0' and byte <= '9') return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn trimOws(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) start += 1;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[start..end];
}

fn trimAsciiWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isAsciiWhitespace(value[start])) start += 1;
    while (end > start and isAsciiWhitespace(value[end - 1])) end -= 1;
    return value[start..end];
}

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

test "HTTP form and query encoding is deterministic" {
    var form: std.ArrayList(u8) = .empty;
    defer form.deinit(std.testing.allocator);
    try appendFormPair(std.testing.allocator, &form, "q", "x y");
    try appendFormPair(std.testing.allocator, &form, "slash", "/");
    try std.testing.expectEqualStrings("q=x+y&slash=%2F", form.items);
    const url = try appendQuery(std.testing.allocator, "https://api.test/items#part", form.items);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.test/items?q=x+y&slash=%2F#part", url);
    try std.testing.expectError(error.InvalidUrl, validateUrl("ftp://api.test/items"));
}

test "HTTP headers validate roundtrip and lookup case-insensitively" {
    var headers = try Headers.parse(std.testing.allocator, "Content-Type: text/plain; charset=latin-1\r\nX-Test:\tyes \r\n");
    defer headers.deinit();
    try std.testing.expectEqualStrings("text/plain; charset=latin-1", headers.get("content-type").?);
    try std.testing.expectEqualStrings("yes", headers.get("X-TEST").?);
    try headers.set("x-test", "new");
    try std.testing.expectEqualStrings("new", headers.get("X-Test").?);
    const block = try headers.serialize(std.testing.allocator);
    defer std.testing.allocator.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "x-test: new\r\n") != null or std.mem.indexOf(u8, block, "X-Test: new\r\n") != null);
    try std.testing.expectError(error.InvalidHeader, headers.append("Bad Name", "value"));
    try std.testing.expectError(error.InvalidHeader, headers.append("Good", "bad\r\nInjected: yes"));
}

test "HTTP text decoding follows explicit charset and replacement policy" {
    try std.testing.expectEqual(Encoding.latin1, try contentTypeEncoding("text/plain; Charset=\"latin-1\""));
    const latin1 = try decodeText(std.testing.allocator, "caf\xe9", .latin1);
    defer std.testing.allocator.free(latin1);
    try std.testing.expectEqualStrings("caf\xc3\xa9", latin1);
    const ascii = try decodeText(std.testing.allocator, "caf\xe9", .ascii);
    defer std.testing.allocator.free(ascii);
    try std.testing.expectEqualStrings("caf\xef\xbf\xbd", ascii);
    const invalid_utf8 = try decodeText(std.testing.allocator, "a\xffb", .utf8);
    defer std.testing.allocator.free(invalid_utf8);
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb", invalid_utf8);
    try std.testing.expectError(error.UnsupportedEncoding, parseEncoding("utf-16"));
}

test "HTTP packet size includes envelope and descriptors" {
    try std.testing.expectEqual(@as(usize, 24 + 5 * 12 + 3 + 20 + 10 + 100 + 8), try packetSize(&.{ 3, 20, 10, 100, 8 }));
    try std.testing.expectError(error.PacketTooLarge, packetSize(&.{max_packet_bytes}));
}
