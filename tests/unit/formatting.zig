const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testFStringConversionsFormattingAndEvaluationOrder() !void {
    try expectOutput(
        \\name = "\u00e9"
        \\print(f"{{{name}}} {name!r} {name!a} {255:#06x} {12345.678:,.2f}")
        \\def mark(label, value):
        \\    print(label)
        \\    return value
        \\print(f"{mark('first', 1)} {mark('second', 2)}")
        \\print(f"{ {'x': 1}['x'] }")
        \\print(f"{1 != 2}")
        \\print(f"{{x}} {name!r:>8}")
        \\print(f"{ "x" }")
        \\print('hello ' f'{name}')
        \\print(b'a' b'b')
    ,
        "{\xc3\xa9} '\xc3\xa9' '\\xe9' 0x00ff 12,345.68\nfirst\nsecond\n1 2\n1\nTrue\n{x}      'é'\nx\nhello \xc3\xa9\nb'ab'\n",
    );
}

pub fn testSharedFormatBuiltinStringFormatAndPercentOperators() !void {
    try expectOutput(
        \\name = "\u00e9"
        \\print("{0} {1:0>5d} {name:^7s}".format(name, 42, name="ok"))
        \\print(format(255, "#06x"), format(3.5, ",.2f"), format(name, "^5s"))
        \\print("%s %r %a %04d %.1f %%" % (name, name, name, 7, 2.5))
        \\print("%#x %d" % (31, 4))
    ,
        "\xc3\xa9 00042   ok   \n0x00ff 3.50   \xc3\xa9  \n\xc3\xa9 '\xc3\xa9' '\\xe9' 0007 2.5 %\n0x1f 4\n",
    );
}

pub fn testFormattingErrorsAndHugePrecisionAreBounded() !void {
    try expectRuntimeException("print(format(1, \"z\"))\n", .value_error, "format-invalid.py", "format-invalid.py:1:");
    try expectRuntimeException("print(\"%s %s\" % (\"one\",))\n", .type_error, "format-percent.py", "format-percent.py:1:");
    try expectRuntimeException("print(\"}\".format())\n", .value_error, "format-close-brace.py", "format-close-brace.py:1:");
    try expectRuntimeException("print(\"{0} {}\".format(1, 2))\n", .value_error, "format-mixed-numbering.py", "format-mixed-numbering.py:1:");

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("print(format(1, \"10000000\"))\n", "format-cap.py"));
    runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes + 4096;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, runtime.pythonException().?.kind);
}

pub fn testDeferredFStringSpecAndDebugSyntaxBoundaries() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();

    const dynamic_spec = runtime.compileAndStart("print(\"must not run\")\nwidth = 4\nprint(f\"{3:{width}}\")\n", "fstring-dynamic-spec.py");
    switch (dynamic_spec) {
        .unsupported => |diagnostic| try std.testing.expectEqualStrings("nested f-string format specifications are not supported", diagnostic.message),
        .ready => return error.ExpectedUnsupportedDynamicFormatSpec,
        .syntax_error => return error.ExpectedUnsupportedDynamicFormatSpec,
        .python_exception => return error.ExpectedCompileDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());

    const debug_field = runtime.compileAndStart("value = 3\nprint(f\"{value=}\")\n", "fstring-debug-equals.py");
    switch (debug_field) {
        .syntax_error => |diagnostic| try std.testing.expect(diagnostic.message.len != 0),
        .ready => return error.ExpectedUnsupportedDebugEquals,
        .unsupported => return error.ExpectedSyntaxError,
        .python_exception => return error.ExpectedCompileDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

pub fn testFormatSignsCharacterFloatTypesAndConvertedStringSpec() !void {
    try expectOutput(
        \\print(f"{123!r:.2}")
        \\print(format(-15, "#06x"), format(42, "+d"), format(42, " d"))
        \\print(format(65, "c"), format(3.5, ".1e"), format(1234.0, ".3g"), format(0.125, ".0%"))
        \\print(format(1.2, ".2e"), format(1.2, ".2E"), format(3.14159, ".12f"))
        \\print(format(9.99, ".1g"), format(999.9, ".3g"), format(0.0000999, ".1g"))
        \\print(format(3.14159265, "12"), format(3.14159265, "12g"))
        \\print(format(1234.5, ","), format(3.14159, ".2"))
    , "12\n-0x00f +42  42\nA 3.5e+00 1.23e+03 12%\n1.20e+00 1.20E+00 3.141590000000\n1e+01 1e+03 0.0001\n  3.14159265      3.14159\n1,234.5 3.1\n");
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "formatting.py"));
    var status = runtime.run(100_000);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(100_000);
    if (status != .completed) std.debug.print("formatting VM status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectRuntimeException(source: []const u8, kind: exceptions.PythonExceptionKind, filename: []const u8, location: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, filename));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
    try expectTraceLocation(runtime.errorText(), location);
}

fn expectTraceLocation(text: []const u8, location: []const u8) !void {
    var parts = std.mem.splitScalar(u8, location, ':');
    const filename = parts.next() orelse return error.InvalidTestLocation;
    const line = parts.next() orelse return error.InvalidTestLocation;
    const pattern = try std.fmt.allocPrint(std.testing.allocator, "File \"{s}\", line {s}", .{ filename, line });
    defer std.testing.allocator.free(pattern);
    try std.testing.expect(std.mem.indexOf(u8, text, pattern) != null);
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        .unsupported => |diagnostic| {
            std.debug.print("format source unsupported: {s}\n", .{diagnostic.message});
            return error.ExpectedExecutableProgram;
        },
        .syntax_error => |diagnostic| {
            std.debug.print("format source syntax error: {s}\n", .{diagnostic.message});
            return error.ExpectedExecutableProgram;
        },
        .python_exception => |exception| {
            std.debug.print("format compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableProgram;
        },
    }
}
