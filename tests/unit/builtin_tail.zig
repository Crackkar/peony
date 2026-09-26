const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testNumericAndTextBuiltins() !void {
    try expectOutput(
        \\print(abs(-7), abs(-2.5), bin(-10), oct(9), hex(255))
        \\print(chr(9731), ord("☃"), ord(b"A"), ascii("é☃"))
        \\print(divmod(17, 5), divmod(-17, 5), pow(2, 80), pow(5, 117, 19))
        \\print(round(2.5), round(3.5), round(125, -1), round(2.675, 2))
    ,
        "7 2.5 -0b1010 0o11 0xff\n☃ 9731 65 '\\xe9\\u2603'\n(3, 2) (-4, 3) 1208925819614629174706176 1\n2 4 120 2.67\n",
    );
}

pub fn testIterableReductionsAndShortCircuit() !void {
    try expectOutput(
        \\def all_values():
        \\    print("all-1")
        \\    yield 1
        \\    print("all-2")
        \\    yield 0
        \\    print("all-bad")
        \\    yield 1
        \\def any_values():
        \\    print("any-1")
        \\    yield 0
        \\    print("any-2")
        \\    yield 2
        \\    print("any-bad")
        \\    yield 0
        \\def key(value):
        \\    print("key", value)
        \\    return -value
        \\print(all(all_values()), any(any_values()))
        \\print(min([3, 1, 2]), max(3, 1, 2), min([3, 1, 2], key=key))
        \\print(min([], default=9), max([], default=8, key=key))
        \\print(sum(value for value in range(6)), sum([1, 2, 3], 10))
    ,
        "all-1\nall-2\nany-1\nany-2\nFalse True\nkey 3\nkey 1\nkey 2\n1 3 3\n9 8\n15 16\n",
    );
}

pub fn testBytesConstructorFormsAndErrors() !void {
    try expectOutput(
        \\print(bytes(), bytes(3), bytes([65, 0, 255]))
        \\print(bytes("snow", "utf-8"), bytes("snow", encoding="ascii"))
        \\print(bytes("é", "UTF8"), bytes(b"AB"))
    ,
        "b'' b'\\x00\\x00\\x00' b'A\\x00\\xff'\nb'snow' b'snow'\nb'\\xc3\\xa9' b'AB'\n",
    );
    try expectRuntimeException("bytes(\"x\")\n", .type_error);
    try expectRuntimeException("bytes(-1)\n", .value_error);
    try expectRuntimeException("bytes([256])\n", .value_error);
    try expectRuntimeException("bytes(\"é\", \"ascii\")\n", .unicode_encode_error);
    try expectRuntimeException("bytes(\"x\", \"latin-1\")\n", .lookup_error);
}

pub fn testBuiltinErrorsAndResumableWork() !void {
    try expectRuntimeException("ord(\"ab\")\n", .type_error);
    try expectRuntimeException("chr(0x110000)\n", .value_error);
    try expectRuntimeException("min([])\n", .value_error);
    try expectRuntimeException("max(1, 2, default=3)\n", .type_error);
    try expectRuntimeException("sum([1, \"x\"])\n", .type_error);
    try expectRuntimeException("pow(2, -1, 4)\n", .value_error);

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("print(sum(range(20000)))\n", "builtin-work.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, runtime.run(1));
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(1));
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "builtin-tail.py"));
    var status = runtime.run(3);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(3);
    if (status != .completed) std.debug.print("builtin-tail status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectRuntimeException(source: []const u8, kind: exceptions.PythonExceptionKind) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "builtin-error.py"));
    var status = runtime.run(3);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(3);
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, status);
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), "File \"builtin-error.py\", line 1") != null);
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        .syntax_error, .unsupported => |diagnostic| {
            std.debug.print("builtin-tail compile failure at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableProgram;
        },
        else => return error.ExpectedExecutableProgram,
    }
}
