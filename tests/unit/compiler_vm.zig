const std = @import("std");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testInstructionPackingAndOperandLimits() !void {
    const instruction = try bytecode.Instruction.init(.load_const, 7, 0x89ab, 0xcdef, 0x5a);
    try std.testing.expectEqual(@as(u64, 0x5a_cdef_89ab_0007_01), instruction.encode());

    const decoded = bytecode.Instruction.decode(instruction.encode());
    try std.testing.expectEqual(bytecode.Opcode.load_const, decoded.opcode());
    try std.testing.expectEqual(@as(u16, 7), decoded.a());
    try std.testing.expectEqual(@as(u16, 0x89ab), decoded.b());
    try std.testing.expectEqual(@as(u16, 0xcdef), decoded.c());
    try std.testing.expectEqual(@as(u8, 0x5a), decoded.flags());
    try std.testing.expectEqual(@as(u32, 0x89ab_cdef), decoded.index32());

    const indexed = try bytecode.Instruction.withIndex32(.load_const, 3, 0xdead_beef, 0);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), indexed.index32());
    try std.testing.expectError(error.RegisterOutOfRange, bytecode.Instruction.init(.move, 65_536, 0, 0, 0));
    try std.testing.expectError(error.RegisterOutOfRange, bytecode.Instruction.init(.move, 0, 0, 65_536, 0));
}

pub fn testTemporaryRegistersAreReusedAndBounded() !void {
    var temporaries = compiler.TempAllocator.init(4);
    const first = try temporaries.acquire();
    const second = try temporaries.acquire();
    try std.testing.expectEqual(@as(u16, 4), first);
    try std.testing.expectEqual(@as(u16, 5), second);
    temporaries.release(second);
    try std.testing.expectEqual(second, try temporaries.acquire());
    temporaries.release(second);
    temporaries.release(first);

    var at_limit = compiler.TempAllocator.init(65_536);
    try std.testing.expectError(error.RegisterOutOfRange, at_limit.acquire());
}

pub fn testStraightLineCompilationAndOwnership() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    const source = try std.testing.allocator.dupe(u8, "first = second = 2 + 3 * 4\nprint(first, second, -2**2, 2**3**2)\nprint(None, True, False, 1.25)\n");
    try expectReady(runtime.compileAndStart(source, "owned.py"));
    std.testing.allocator.free(source);

    const code = runtime.code orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("owned.py", code.filename);
    try std.testing.expectEqualStrings("<module>", code.display_name);
    try std.testing.expect(code.instructions.len > 0);
    try std.testing.expectEqual(code.instructions.len, code.positions.len);
    try std.testing.expect(code.register_count <= 8);
    for (code.positions) |position| try std.testing.expect(position.line >= 1 and position.column >= 1);

    _ = runtime.heap.collect();
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(10_000));
    try std.testing.expectEqualStrings("14 14 -4 512\nNone True False 1.25\n", runtime.stdout());
}

pub fn testBigIntegersStringsAndTemporaryReuse() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    try expectReady(runtime.compileAndStart(
        "print(9007199254740992, 170141183460469231731687303715884105728)\nprint(0x_FF, 1_000)\nprint(\"line\\nnext\", 'tab\\tend', \"utf-8: é\")\n1 + 2\n3 + 4\n5 + 6\n",
        "literals.py",
    ));
    const code = runtime.code orelse return error.TestUnexpectedResult;
    try std.testing.expect(code.register_count <= 8);
    _ = runtime.heap.collect();
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(10_000));
    try std.testing.expectEqualStrings(
        "9007199254740992 170141183460469231731687303715884105728\n255 1000\nline\nnext tab\tend utf-8: é\n",
        runtime.stdout(),
    );
}

pub fn testBuiltinFallbackShadowingAndPythonExceptions() !void {
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart("print(4 + 5)\n", "builtin.py"));
        try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
        try std.testing.expectEqualStrings("9\n", runtime.stdout());
    }
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart("print(1, print(2), 3)\n", "nested-print.py"));
        try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
        try std.testing.expectEqualStrings("2\n1 None 3\n", runtime.stdout());
    }
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart("print = 7\nprint(4)\n", "shadow.py"));
        try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100));
        try std.testing.expectEqual(exceptions.PythonExceptionKind.type_error, runtime.pythonException().?.kind);
    }
    try expectRuntimeException("print(missing_name)\n", .name_error, "NameError");
    try expectRuntimeException("print(1 / 0)\n", .zero_division_error, "ZeroDivisionError");
    try expectRuntimeException("print(\"word\" + 1)\n", .type_error, "TypeError");
}

pub fn testInternalBytecodeFaultIsNotAPythonException() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("print(1)\n", "corrupt.py"));
    const code = runtime.code orelse return error.TestUnexpectedResult;
    code.instructions[0] = .{ .word = 0xff };
    try std.testing.expectEqual(runtime_vm.RunStatus.engine_error, runtime.run(100));
    try std.testing.expect(runtime.pythonException() == null);
}

pub fn testUnboundLocalErrorHierarchy() !void {
    try std.testing.expect(exceptions.isSubclass(.unbound_local_error, .name_error));
    try std.testing.expect(exceptions.isSubclass(.unbound_local_error, .exception));
    try std.testing.expect(exceptions.isSubclass(.unbound_local_error, .base_exception));
}

pub fn testUnsupportedSyntaxAndMemoryLimitTransport() !void {
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
        defer runtime.deinit();
        switch (runtime.compileAndStart("if True:\n    print(1)\n", "later.py")) {
            .ready => {},
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
        try std.testing.expectEqualStrings("1\n", runtime.stdout());
    }
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 1024);
        defer runtime.deinit();
        const large_source = try std.testing.allocator.alloc(u8, 8192);
        defer std.testing.allocator.free(large_source);
        @memset(large_source, 'x');
        @memcpy(large_source[0..7], "print(\"");
        @memcpy(large_source[large_source.len - 3 ..], "\")\n");
        switch (runtime.compileAndStart(large_source, "memory.py")) {
            .python_exception => |exception| try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, exception.kind),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 6 * 1024);
        defer runtime.deinit();
        const digit_count = 100_000;
        const large_integer = try std.testing.allocator.alloc(u8, digit_count + 8);
        defer std.testing.allocator.free(large_integer);
        @memcpy(large_integer[0..6], "print(");
        @memset(large_integer[6 .. large_integer.len - 2], '9');
        @memcpy(large_integer[large_integer.len - 2 ..], ")\n");
        switch (runtime.compileAndStart(large_integer, "big-memory.py")) {
            .python_exception => |exception| try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, exception.kind),
            else => return error.TestUnexpectedResult,
        }
    }
}

fn expectRuntimeException(source: []const u8, kind: exceptions.PythonExceptionKind, type_name: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "error.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100));
    const exception = runtime.pythonException() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(kind, exception.kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), type_name) != null);
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
}
