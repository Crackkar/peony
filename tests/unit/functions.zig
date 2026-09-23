const std = @import("std");
const runtime_vm = @import("runtime_vm");
const bytecode = @import("frontend_bytecode");

pub fn testBasicFunctionsReturnsAndCallableValues() !void {
    try expectOutput(
        \\def add(left, right):
        \\    return left + right
        \\def empty():
        \\    pass
        \\printer = print
        \\stepper = range
        \\print(add(2, 3), empty())
        \\printer("alias", "output", sep=":", end="!")
        \\printer(stepper(3))
        \\for item in stepper(2):
        \\    printer(item)
    , "5 None\nalias:output!range(0, 3)\n0\n1\n");
}

pub fn testCallsEvaluateCalleeAndArgumentsOnceLeftToRight() !void {
    try expectOutput(
        \\def mark(value):
        \\    print(value)
        \\    return value
        \\def combine(a, b):
        \\    return a + b
        \\def choose():
        \\    print("callee")
        \\    return combine
        \\print(choose()(mark("left"), mark("right")))
        \\print(1, print(2), 3)
    , "callee\nleft\nright\nleftright\n2\n1 None 3\n");
}

pub fn testStarredArgumentsExpandBeforeLaterArguments() !void {
    try expectOutput(
        \\def collect(*items):
        \\    print(items)
        \\values = [1]
    \\collect(*values, values.append(2))
    , "(1, None)\n");

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        \\def mark():
        \\    print("late argument ran")
        \\    return 1
        \\def collect(*items):
        \\    return items
        \\collect(*1, mark())
    , "star-error-order.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100));
    try std.testing.expectEqual(runtime_vm.PythonExceptionKind.type_error, runtime.pythonException().?.kind);
    try std.testing.expectEqualStrings("", runtime.stdout());
}

pub fn testDefinitionTimeDefaultsAndAnnotations() !void {
    try expectOutput(
        \\def mark(label):
        \\    print(label)
        \\    return label
        \\def choose(a=mark("a-default"), b: mark("b-annotation")=mark("b-default")) -> mark("return-annotation"):
        \\    return a
        \\print(choose(), choose())
    , "a-default\nb-default\nb-annotation\nreturn-annotation\na-default a-default\n");
}

pub fn testPositionalOnlyKeywordOnlyAndDefaultBinding() !void {
    try expectOutput(
        \\def total(a, /, b=2, *, c=3):
        \\    return a + b + c
        \\print(total(1), total(1, c=4), total(1, 5, c=6))
    , "6 7 12\n");
}

pub fn testFunctionBinderErrorsAndCallSiteLines() !void {
    try expectRuntimeException("def one(value):\n    return value\none(1, 2)\n", "type_error", "too-many.py:3:");
    try expectRuntimeException("def one(value):\n    return value\none()\n", "type_error", "missing.py:3:");
    try expectRuntimeException("def one(value):\n    return value\none(1, value=2)\n", "type_error", "duplicate.py:3:");
    try expectRuntimeException("def one(value):\n    return value\none(value=1, extra=2)\n", "type_error", "unexpected.py:3:");
    try expectRuntimeException("def one(value, /):\n    return value\none(value=1)\n", "type_error", "positional-only.py:3:");
    try expectRuntimeException("def one(*, value):\n    return value\none()\n", "type_error", "keyword-only.py:3:");
    try expectRuntimeException("target = 4\ntarget()\n", "type_error", "not-callable.py:2:");
    try expectRuntimeException(
        "def inner():\n    return missing\ndef outer():\n    return inner()\nouter()\n",
        "name_error",
        "nested-error.py:2:",
    );
}

pub fn testWholeBlockLocalsAndExplicitGlobal() !void {
    try expectRuntimeException(
        \\value = 99
        \\def read_then_assign():
        \\    print(value)
        \\    value = 1
        \\read_then_assign()
    , "unbound_local_error", "local-before-assignment.py:3:");

    try expectOutput(
        \\shared = 1
        \\def update():
        \\    global shared
        \\    shared += 1
        \\    return shared
        \\print(update(), shared)
    , "2 2\n");
}

pub fn testClosuresCaptureMutableCellsAndTransitiveFreeNames() !void {
    try expectOutput(
        \\def counter_factory():
        \\    value = 0
        \\    def increment():
        \\        nonlocal value
        \\        value += 1
        \\        return value
        \\    return increment
        \\increment = counter_factory()
        \\print(increment(), increment())
        \\def outer():
        \\    captured = 40
        \\    def middle():
        \\        def inner():
        \\            return captured + 2
        \\        return inner
        \\    return middle()
        \\reader = outer()
        \\print(reader())
    , "1 2\n42\n");
}

pub fn testVariadicClosureRootsSurviveCellConstructionCollection() !void {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "def f(*items):\n");
    for (0..4096) |index| {
        const statement = try std.fmt.allocPrint(allocator, "    captured{d} = {d}\n", .{ index, @as(u8, if (index == 0) 1 else 0) });
        defer allocator.free(statement);
        try source.appendSlice(allocator, statement);
    }
    try source.appendSlice(allocator, "    def g():\n        return items, captured0");
    for (1..4096) |index| {
        const term = try std.fmt.allocPrint(allocator, " + captured{d}", .{index});
        defer allocator.free(term);
        try source.appendSlice(allocator, term);
    }
    try source.appendSlice(allocator, "\n    return g()\nprint(f(\"kept\"))\n");

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 32 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source.items, "variadic-closure-roots.py"));
    const module = runtime.code.?;
    const function_code = module.nested_codes[0];
    try std.testing.expect(function_code.cell_names.len > 2);
    var items_cell: ?usize = null;
    for (function_code.cell_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "items")) items_cell = index;
    }
    try std.testing.expectEqual(@as(?usize, 0), items_cell);
    const first_call = for (module.instructions, 0..) |instruction, index| {
        if (instruction.opcode() == .call) break index;
    } else return error.MissingVariadicCall;
    while (runtime.instruction_pointer < first_call) {
        try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, runtime.run(1));
    }
    runtime.heap.collection_threshold = runtime.session_allocator.live_bytes + 128 * 1024;
    runtime.heap.threshold_growth_floor = 1;
    const collections_before_call = runtime.heap.collection_count;
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, runtime.run(1));
    try std.testing.expect(runtime.heap.collection_count > collections_before_call);
    try runToCompletion(&runtime, 2);
    try std.testing.expectEqualStrings("(('kept',), 1)\n", runtime.stdout());
}

pub fn testRecursiveFramesSurviveCollectionAndTimeslices() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        \\def factorial(n):
        \\    if n < 2:
        \\        return 1
        \\    return n * factorial(n - 1)
        \\def factory():
        \\    captured = 10 ** 100
        \\    def read():
        \\        return captured
        \\    return read
        \\reader = factory()
        \\print(factorial(10), reader() - 10 ** 100)
    , "frames.py"));
    runtime.heap.collection_threshold = 64;
    runtime.heap.threshold_growth_floor = 16;
    try runToCompletion(&runtime, 1);
    try std.testing.expect(runtime.heap.collection_count > 0);
    try std.testing.expectEqualStrings("3628800 0\n", runtime.stdout());
}

pub fn testBuiltinCallableCollectionAndReset() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("printer = print\n", "builtin-root.py"));
    try runToCompletion(&runtime, 100);
    _ = runtime.heap.collect();
    try expectReady(runtime.compileAndStart("print(1)\n", "builtin-reset.py"));
    try runToCompletion(&runtime, 100);
    try std.testing.expectEqualStrings("1\n", runtime.stdout());
}

pub fn testUnsupportedFunctionDefaultCleansNestedCodeOnce() !void {
    try expectOutput("def default_mapping(value={}):\n    return value\nprint(default_mapping())\n", "{}\n");
}

pub fn testFunctionConstructionMemoryErrorAndRecovery() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("def identity(value=123):\n    return value\nprint(identity())\n", "function-cap.py"));
    const original_cap = runtime.session_allocator.max_bytes;
    runtime.heap.collection_threshold = std.math.maxInt(usize);
    runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes + 16;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100));
    try std.testing.expectEqual(runtime_vm.PythonExceptionKind.memory_error, runtime.pythonException().?.kind);
    runtime.session_allocator.max_bytes = original_cap;
    try expectReady(runtime.compileAndStart("print(\"recovered\")\n", "function-cap-recovered.py"));
    try runToCompletion(&runtime, 100);
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testEmptyDoubleStarExpansion() !void {
    try expectOutput("print(1, **{})\n", "1\n");
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "functions.py"));
    try runToCompletion(&runtime, 10_000);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectRuntimeException(source: []const u8, expected_tag: []const u8, location: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    const colon = std.mem.indexOfScalar(u8, location, ':') orelse location.len;
    try expectReady(runtime.compileAndStart(source, location[0..colon]));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    const exception = runtime.pythonException() orelse return error.ExpectedPythonException;
    try std.testing.expectEqualStrings(expected_tag, @tagName(exception.kind));
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), location) != null);
}

fn expectUnsupported(source: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "unsupported-function.py")) {
        .unsupported => {},
        else => return error.ExpectedExplicitUnsupportedDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        else => return error.ExpectedExecutableProgram,
    }
}

fn runToCompletion(runtime: *runtime_vm.Runtime, quantum: u32) !void {
    var status = runtime.run(quantum);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 50_000) : (resumes += 1) status = runtime.run(quantum);
    if (status != .completed) std.debug.print("runtime status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}
