const std = @import("std");
const number = @import("runtime_number");
const string = @import("runtime_string");
const bytes = @import("runtime_bytes");
const unicode = @import("runtime_unicode");

const Str = string.Str;
const Bytes = bytes.Bytes;

pub fn testUtf8IndexAndSlice() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const empty = try strOf(string.create(&heap, ""));
    try std.testing.expectEqual(@as(usize, 0), string.length(empty));
    const text = try strOf(string.create(&heap, "aéλ🙂"));
    try std.testing.expectEqual(@as(usize, 4), string.length(text));
    try expectText(string.index(&heap, text, 0), "a");
    try expectText(string.index(&heap, text, 1), "é");
    try expectText(string.index(&heap, text, -1), "🙂");
    try expectText(string.slice(&heap, text, null, null, 2), "aλ");
    try expectText(string.slice(&heap, text, null, null, -1), "🙂λéa");
    try expectText(string.slice(&heap, text, -3, -1, 1), "éλ");
    try expectPythonError(string.index(&heap, text, 4), .index_error);
    try expectPythonError(string.slice(&heap, text, null, null, 0), .value_error);

    try expectPythonError(string.create(&heap, &.{ 0xc3, 0x28 }), .value_error);
}

pub fn testStringEqualityAndConcat() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const left = try strOf(string.create(&heap, "café"));
    const same = try strOf(string.create(&heap, "café"));
    const different = try strOf(string.create(&heap, "caffè"));
    try std.testing.expect(string.equal(left, same));
    try std.testing.expect(!string.equal(left, different));
    try std.testing.expectEqual(string.hash(left), string.hash(same));
    try expectText(string.concat(&heap, left, different), "cafécaffè");
}

pub fn testUnicodeOperations() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    try std.testing.expectEqualStrings("15.0.0", unicode.version);
    try std.testing.expect(unicode.hasProperty(0x1e4d0, .alphabetic));
    try std.testing.expect(unicode.hasProperty(0x1e4f0, .decimal));
    try std.testing.expect(unicode.hasProperty(0x2003, .whitespace));
    try std.testing.expectEqual(@as(u21, 0x69), unicode.simpleMapping(0x130, .lower));
    try std.testing.expectEqual(@as(u21, 0xdf), unicode.simpleMapping(0x1e9e, .casefold));

    const cased = try strOf(string.create(&heap, "ßİΩ"));
    try expectText(string.upper(&heap, cased), "SSİΩ");
    try expectText(string.lower(&heap, cased), "ßi̇ω");
    try expectText(string.title(&heap, try strOf(string.create(&heap, "hello WORLD"))), "Hello World");
    try expectText(string.title(&heap, try strOf(string.create(&heap, "they're"))), "They'Re");
    try expectText(string.capitalize(&heap, try strOf(string.create(&heap, "ßETA"))), "Sseta");
    try expectText(string.casefold(&heap, try strOf(string.create(&heap, "Straße"))), "strasse");
    try expectText(string.lower(&heap, try strOf(string.create(&heap, "ΟΣ"))), "ος");

    try std.testing.expect(string.isAlpha(try strOf(string.create(&heap, "\u{1e4d0}"))));
    try std.testing.expect(string.isAlnum(try strOf(string.create(&heap, "A²"))));
    try std.testing.expect(!string.isDecimal(try strOf(string.create(&heap, "\u{1e4d0}"))));
    try std.testing.expect(string.isDecimal(try strOf(string.create(&heap, "\u{1e4f0}"))));
    try std.testing.expect(string.isDigit(try strOf(string.create(&heap, "²"))));
    try std.testing.expect(string.isSpace(try strOf(string.create(&heap, "\u{2003}\u{00a0}"))));
}

pub fn testStringOperations() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const text = try strOf(string.create(&heap, "  green,blue,green  "));
    try std.testing.expectEqual(@as(?usize, 8), string.find(text, "blue"));
    try std.testing.expect(string.startsWith(text, "  green"));
    try std.testing.expect(string.endsWith(text, "green  "));
    try std.testing.expectEqual(@as(usize, 2), string.count(text, "green"));
    try expectText(string.strip(&heap, text, null), "green,blue,green");

    var parts = try splitOf(string.split(text, ","));
    try std.testing.expectEqualStrings("  green", parts.next().?);
    try std.testing.expectEqualStrings("blue", parts.next().?);
    try std.testing.expectEqualStrings("green  ", parts.next().?);
    try std.testing.expect(parts.next() == null);
    try expectPythonError(string.split(text, ""), .value_error);

    try expectText(string.join(&heap, "/", &.{ "green", "blue", "green" }), "green/blue/green");
    try expectText(string.replace(&heap, text, "green", "red", null), "  red,blue,red  ");
    try expectText(string.strip(&heap, try strOf(string.create(&heap, "--hello--")), "-"), "hello");
    try expectText(string.removePrefix(&heap, text, "  "), "green,blue,green  ");
    try expectText(string.removeSuffix(&heap, text, "  "), "  green,blue,green");
}

pub fn testBytesOperations() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const text = try strOf(string.create(&heap, "aé🙂"));
    const encoded = try bytesOf(bytes.encode(&heap, text));
    try std.testing.expectEqualSlices(u8, "aé🙂", bytes.content(encoded));
    try expectByte(bytes.index(encoded, 1), 0xc3);
    try expectPythonError(bytes.index(encoded, -99), .index_error);

    const slice = try bytesOf(bytes.slice(&heap, encoded, 1, 3, 1));
    try std.testing.expectEqualSlices(u8, "é", bytes.content(slice));
    const copy = try bytesOf(bytes.create(&heap, bytes.content(encoded)));
    try std.testing.expect(bytes.equal(encoded, copy));
    try std.testing.expectEqual(bytes.hash(encoded), bytes.hash(copy));
    const values = try bytesOf(bytes.fromIntegers(&heap, &.{ 0, 128, 255 }));
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 255 }, bytes.content(values));
    try expectPythonError(bytes.fromIntegers(&heap, &.{256}), .value_error);
    try expectText(bytes.decode(&heap, encoded), "aé🙂");
}

pub fn testInvalidBytesDecode() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const malformed = try bytesOf(bytes.create(&heap, &.{ 0xc3, 0x28 }));
    try expectPythonError(bytes.decode(&heap, malformed), .unicode_decode_error);
}

pub fn testStringBytesAccounting() !void {
    var limited_session = number.SessionAllocator.init(std.testing.allocator, 32);
    var limited_heap: number.Heap = .{};
    limited_heap.init(&limited_session, .{ .initial_threshold = 4096 });
    defer limited_heap.deinit();
    try expectPythonError(string.create(&limited_heap, "this backing buffer exceeds the session cap"), .memory_error);
    try expectPythonError(bytes.create(&limited_heap, "this backing buffer exceeds the session cap"), .memory_error);
    try std.testing.expectEqual(@as(usize, 0), limited_session.live_bytes);

    var session = number.SessionAllocator.init(std.testing.allocator, 64 * 1024);
    var heap: number.Heap = .{};
    heap.init(&session, .{ .initial_threshold = 4096 });
    defer heap.deinit();
    _ = try strOf(string.create(&heap, "a long enough string to own backing storage"));
    _ = try bytesOf(bytes.create(&heap, "a long enough byte sequence to own backing storage"));
    try std.testing.expect(session.live_bytes > 0);
    try std.testing.expectEqual(@as(usize, 2), heap.collect());
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
}

fn initHeap(session: *number.SessionAllocator, heap: *number.Heap, cap: usize) void {
    session.* = number.SessionAllocator.init(std.testing.allocator, cap);
    heap.* = .{};
    heap.init(session, .{ .initial_threshold = 128 * 1024 });
}

fn strOf(result: string.StringResult) !*Str {
    return switch (result) {
        .value => |str| str,
        .python_exception => error.UnexpectedPythonException,
        .engine_error => error.EngineFailure,
    };
}

fn bytesOf(result: bytes.BytesResult) !*Bytes {
    return switch (result) {
        .value => |value| value,
        .python_exception => error.UnexpectedPythonException,
        .engine_error => error.EngineFailure,
    };
}

fn splitOf(result: string.SplitResult) !string.SplitIterator {
    return switch (result) {
        .value => |iterator| iterator,
        .python_exception => error.UnexpectedPythonException,
        .engine_error => error.EngineFailure,
    };
}

fn expectText(result: string.StringResult, expected: []const u8) !void {
    try std.testing.expectEqualSlices(u8, expected, string.content(try strOf(result)));
}

fn expectByte(result: bytes.ByteResult, expected: u8) !void {
    switch (result) {
        .value => |value| try std.testing.expectEqual(expected, value),
        .python_exception => return error.UnexpectedPythonException,
        .engine_error => return error.EngineFailure,
    }
}

fn expectValueInt(result: anytype, expected: i128) !void {
    const value = switch (result) {
        .value => |actual| actual,
        .python_exception => return error.UnexpectedPythonException,
        .engine_error => return error.EngineFailure,
    };
    try std.testing.expectEqual(expected, number.toInt(i128, value) orelse return error.ExpectedInteger);
}

fn expectPythonError(result: anytype, expected: anytype) !void {
    switch (result) {
        .python_exception => |exception| try std.testing.expectEqual(expected, exception.kind),
        .value => return error.ExpectedPythonException,
        .engine_error => return error.EngineFailure,
    }
}
