const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");
const host = @import("runtime_host");

pub fn testYieldSendReturnValueAndExhaustion() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(&runtime, runtime.compileAndStart(
        \\events = []
        \\def exchange():
        \\    events.append("started")
        \\    first = yield "ready"
        \\    second = yield first
        \\    return second
        \\generator = exchange()
        \\print("created", events)
        \\try:
        \\    generator.send(9)
        \\except TypeError:
        \\    print("initial send rejected")
        \\print(generator.send(None))
        \\print(next(generator))
        \\try:
        \\    generator.send(4)
        \\except StopIteration as stopped:
        \\    print("returned", stopped.value)
        \\try:
        \\    next(generator)
        \\except StopIteration as stopped:
        \\    print("exhausted", stopped.value)
    , "yield-send.py"));
    runtime.heap.collection_threshold = 1;
    try runToCompletion(&runtime, 1);
    try std.testing.expectEqualStrings(
        "created []\ninitial send rejected\nready\nNone\nreturned 4\nexhausted None\n",
        runtime.stdout(),
    );
    try std.testing.expect(runtime.heap.collection_count > 0);
}

pub fn testGeneratorExceptionsInsideAndOutsideResumedFrame() !void {
    try expectOutput(
        \\def source():
        \\    try:
        \\        sent = yield "ready"
        \\        if sent:
        \\            raise ValueError("inside")
        \\    except ValueError:
        \\        yield "caught inside"
        \\    raise TypeError("outside")
        \\generator = source()
        \\print(next(generator))
        \\print(generator.send(True))
        \\try:
        \\    next(generator)
        \\except TypeError:
        \\    print("caller caught")
    , "ready\ncaught inside\ncaller caught\n");
}

pub fn testGeneratorCloseRunsFinallyOnceAndRejectsYieldDuringClose() !void {
    try expectOutput(
        \\def closeable():
        \\    try:
        \\        yield "ready"
        \\        yield "later"
        \\    finally:
        \\        print("finally")
        \\generator = closeable()
        \\print(next(generator))
        \\generator.close()
        \\generator.close()
        \\print("closed")
        \\def invalid_close():
        \\    try:
        \\        yield "ready"
        \\    finally:
        \\        yield "not allowed"
        \\broken = invalid_close()
        \\next(broken)
        \\try:
        \\    broken.close()
        \\except RuntimeError:
        \\    print("yield rejected")
    , "ready\nfinally\nclosed\nyield rejected\n");
}

pub fn testGeneratorResumesAcrossHostInputAtQuantumOne() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(&runtime, runtime.compileAndStart(
        \\def conversation():
        \\    sent = yield "ready"
        \\    name = input("Name: ")
        \\    yield sent
        \\    yield name
        \\generator = conversation()
        \\first = next(generator)
        \\second = generator.send("token")
        \\third = next(generator)
        \\print(first, second, third)
    , "yield-host.py"));
    var status = runtime_vm.RunStatus.timeslice;
    for (0..10_000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, status);
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingGeneratorInputRequest;
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = "Ada" }};
    var response = host.DecodedPacket{
        .kind = .input,
        .request_id = request_id,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&response));
    try runToCompletion(&runtime, 1);
    try std.testing.expectEqualStrings("Name: ready token Ada\n", runtime.stdout());
}

pub fn testYieldFromAndThrowRemainExplicitlyUnsupported() !void {
    try expectUnsupported("def values():\n    yield from (1, 2)\n");
    try expectUnsupported("def values():\n    yield 1\nvalues().throw(ValueError())\n");
}

pub fn testYieldIsRejectedInClassSuiteButAllowedInMethod() !void {
    try expectSyntaxError(
        "def outer():\n    class C:\n        yield 1\n",
        "yield outside function",
    );
    try expectOutput(
        \\def outer():
        \\    class C:
        \\        def values(self):
        \\            yield 1
        \\    return C
        \\C = outer()
        \\print(next(C().values()))
    , "1\n");
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(&runtime, runtime.compileAndStart(source, "generators.py"));
    try runToCompletion(&runtime, 1);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectReady(runtime: *runtime_vm.Runtime, outcome: runtime_vm.CompileOutcome) !void {
    _ = runtime;
    switch (outcome) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("unexpected generator syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableGeneratorProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("unexpected generator unsupported feature at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableGeneratorProgram;
        },
        .python_exception => |exception| {
            std.debug.print("unexpected generator compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableGeneratorProgram;
        },
    }
}

fn expectUnsupported(source: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "excluded-generator.py")) {
        .unsupported => {},
        else => return error.ExpectedExplicitUnsupportedDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

fn expectSyntaxError(source: []const u8, expected_message: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "invalid-yield.py")) {
        .syntax_error => |diagnostic| try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, expected_message) != null),
        else => return error.ExpectedSyntaxError,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

fn runToCompletion(runtime: *runtime_vm.Runtime, quantum: u32) !void {
    var status = runtime.run(quantum);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(quantum);
    if (status != .completed) std.debug.print("generator runtime status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}
