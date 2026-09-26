const std = @import("std");
const runtime_vm = @import("runtime_vm");
const number = @import("runtime_number");
const string = @import("runtime_string");
const exceptions = @import("runtime_exception");

pub fn testStringTailRuntimePrimitives() !void {
    var session = number.SessionAllocator.init(std.testing.allocator, 128 * 1024);
    var heap: number.Heap = .{};
    heap.init(&session, .{ .initial_threshold = 256 * 1024 });
    defer heap.deinit();

    const padded = try strOf(string.create(&heap, "\u{2003}--caf\xc3\xa9--\u{2003}"));
    try expectText(string.lstrip(&heap, padded, null), "--caf\xc3\xa9--\u{2003}");
    try expectText(string.rstrip(&heap, padded, null), "\u{2003}--caf\xc3\xa9--");
    try expectText(string.lstrip(&heap, padded, "\u{2003}-"), "caf\xc3\xa9--\u{2003}");
    try expectText(string.rstrip(&heap, padded, "\u{2003}-"), "\u{2003}--caf\xc3\xa9");

    const searched = try strOf(string.create(&heap, "a\xc3\xa9a\xc3\xa9"));
    try std.testing.expectEqual(@as(?usize, 3), string.rfind(searched, "\xc3\xa9", 0, null));
    try std.testing.expectEqual(@as(?usize, 1), string.rfind(searched, "\xc3\xa9", 0, 3));
    try std.testing.expectEqual(@as(?usize, 4), string.rfind(searched, "", -99, null));
    try std.testing.expectEqual(@as(?usize, null), string.rfind(searched, "", 99, null));

    var explicit = try splitOf(string.rsplit(searched, "a", 1));
    try std.testing.expectEqualStrings("\xc3\xa9", explicit.next().?);
    try std.testing.expectEqualStrings("a\xc3\xa9", explicit.next().?);
    try std.testing.expect(explicit.next() == null);

    const spaced = try strOf(string.create(&heap, "  one\u{2003}two  three  "));
    var whitespace = string.rsplitWhitespace(spaced, 1);
    try std.testing.expectEqualStrings("three", whitespace.next().?);
    try std.testing.expectEqualStrings("  one\u{2003}two", whitespace.next().?);
    try std.testing.expect(whitespace.next() == null);

    const lines_text = try strOf(string.create(&heap, "a\r\nb\u{0085}c\u{2028}\u{2029}"));
    var lines = string.splitlines(lines_text, true);
    try std.testing.expectEqualStrings("a\r\n", lines.next().?);
    try std.testing.expectEqualStrings("b\u{0085}", lines.next().?);
    try std.testing.expectEqualStrings("c\u{2028}", lines.next().?);
    try std.testing.expectEqualStrings("\u{2029}", lines.next().?);
    try std.testing.expect(lines.next() == null);
}

pub fn testStringTailVmMethods() !void {
    try expectOutput(
        \\text = "\u2003--caf\u00e9--\u2003"
        \\print(repr(text.lstrip()), repr(text.rstrip()))
        \\print(text.lstrip("\u2003-"), text.rstrip("\u2003-"))
        \\print(" a  b ".rsplit(), " a  b ".rsplit(None, 1))
        \\print("a--b--".rsplit("--", 1), "a--b--".rsplit("--", 0))
        \\print("a\r\nb\u0085c\u2028".splitlines(), "a\r\nb".splitlines(keepends=True))
        \\print("a\u00e9a\u00e9".rfind("\u00e9"), "a\u00e9a\u00e9".rfind("\u00e9", 0, 3))
        \\print("a\u00e9a\u00e9".rindex("\u00e9"))
        \\print("they're HERE".title(), "\u00dfETA".capitalize())
        \\print("\u00b2".isdigit(), "\u00b2".isdecimal(), "\U0001e4d0".isalpha())
        \\print("A\u00b2".isalnum(), "\u2003\u00a0".isspace(), "".isalpha())
        \\print("unhappy".removeprefix("un"), "archive.tar".removesuffix(".tar"))
        \\print("happy".removeprefix("un"), "archive".removesuffix(".tar"))
        \\print(" a  b ".rsplit(sep=None, maxsplit=1))
    ,
        "'--caf\xc3\xa9--\u{2003}' '\u{2003}--caf\xc3\xa9--'\n" ++
            "caf\xc3\xa9--\u{2003} \u{2003}--caf\xc3\xa9\n" ++
            "['a', 'b'] [' a', 'b']\n" ++
            "['a--b', ''] ['a--b--']\n" ++
            "['a', 'b', 'c'] ['a\\r\\n', 'b']\n" ++
            "3 1\n3\nThey'Re Here Sseta\n" ++
            "True False True\nTrue True False\n" ++
            "happy archive\nhappy archive\n[' a', 'b']\n",
    );
}

pub fn testStringTailErrorsAndMemoryCap() !void {
    try expectRuntimeException("print('abc'.rindex('z'))\n", .value_error);
    try expectRuntimeException("print('abc'.rfind())\n", .type_error);
    try expectRuntimeException("print('abc'.rfind(1))\n", .type_error);
    try expectRuntimeException("print('abc'.lstrip(1))\n", .type_error);
    try expectRuntimeException("print('abc'.title(1))\n", .type_error);
    try expectRuntimeException("print('abc'.removeprefix(prefix='a'))\n", .type_error);
    try expectRuntimeException("print('abc'.rsplit('', 1))\n", .value_error);
    try expectRuntimeException("print('abc'.rsplit(None, maxsplit='x'))\n", .type_error);
    try expectRuntimeException("print('abc'.splitlines(other=True))\n", .type_error);

    var session = number.SessionAllocator.init(std.testing.allocator, 128 * 1024);
    var heap: number.Heap = .{};
    heap.init(&session, .{ .initial_threshold = 256 * 1024 });
    defer heap.deinit();
    const source = try strOf(string.create(&heap, "a long STRING that requires an allocated transformed result"));
    session.max_bytes = session.live_bytes + 1;
    switch (string.title(&heap, source)) {
        .python_exception => |exception| try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, exception.kind),
        else => return error.ExpectedMemoryError,
    }
    session.max_bytes = 128 * 1024;
    try expectText(string.capitalize(&heap, source), "A long string that requires an allocated transformed result");

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    const literal_size = 4096;
    const prefix = "print(\"";
    const suffix = "\".title())\n";
    const program = try std.testing.allocator.alloc(u8, prefix.len + literal_size + suffix.len);
    defer std.testing.allocator.free(program);
    @memcpy(program[0..prefix.len], prefix);
    @memset(program[prefix.len .. prefix.len + literal_size], 'x');
    @memcpy(program[prefix.len + literal_size ..], suffix);
    try expectReady(runtime.compileAndStart(program, "string-tail-work.py"));
    runtime.max_instructions = runtime.workCount() + 100;
    try std.testing.expectEqual(runtime_vm.RunStatus.limit, runtime.run(100_000));

    runtime.max_instructions = 50_000_000;
    try expectReady(runtime.compileAndStart("print('ok'.title())\n", "string-tail-recover.py"));
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(100_000));
    try expectReady(runtime.compileAndStart("print('ok'.title())\n", "string-tail-recover.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100_000));
    try std.testing.expectEqualStrings("Ok\n", runtime.stdout());
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "string-tail.py"));
    var status = runtime.run(100_000);
    while (status == .timeslice) status = runtime.run(100_000);
    if (status != .completed) std.debug.print("string tail status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectRuntimeException(source: []const u8, kind: exceptions.PythonExceptionKind) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "string-tail-error.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        else => return error.ExpectedExecutableProgram,
    }
}

fn strOf(result: string.StringResult) !*string.Str {
    return switch (result) {
        .value => |value| value,
        else => error.UnexpectedStringResult,
    };
}

fn splitOf(result: string.SplitResult) !string.SplitIterator {
    return switch (result) {
        .value => |value| value,
        else => error.UnexpectedSplitResult,
    };
}

fn expectText(result: string.StringResult, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, string.content(try strOf(result)));
}
