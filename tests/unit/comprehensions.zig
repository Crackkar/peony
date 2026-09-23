const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testComprehensionScopesNestedClausesAndLateBinding() !void {
    try expectOutput(
        \\def build(offset):
        \\    matrix = [[offset + row + column for column in range(3) if column != 1] for row in range(2)]
        \\    makers = [lambda: offset + index for index in range(3)]
        \\    print(matrix)
        \\    print(makers[0](), makers[1](), makers[2]())
        \\    index = 99
        \\    print(index)
        \\build(10)
    ,
        "[[10, 12], [11, 13]]\n12 12 12\n99\n",
    );
    try expectOutput(
        \\def key(value):
        \\    print("key", value)
        \\    return value
        \\def result(value):
        \\    print("value", value)
        \\    return value
        \\mapping = {key(item): result(item) for item in [1, 2]}
        \\values = {item % 2 for item in [1, 2, 3]}
        \\print(mapping, len(values), 0 in values, 1 in values)
    ,
        "key 1\nvalue 1\nkey 2\nvalue 2\n{1: 1, 2: 2} 2 True True\n",
    );
}

pub fn testGeneratorExpressionsAreLazyAndRooted() !void {
    try expectOutput(
        \\def accept(value):
        \\    print("filter", value)
        \\    return value % 2
        \\def emit(value):
        \\    print("body", value)
        \\    return value
        \\items = (emit(value) for value in [1, 2, 3] if accept(value))
        \\print("created")
        \\print(next(items))
        \\print("between")
        \\print(next(items))
    ,
        "created\nfilter 1\nbody 1\n1\nbetween\nfilter 2\nfilter 3\nbody 3\n3\n",
    );

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        \\def source():
        \\    print("outer iterable")
        \\    return [1, 2, 3]
        \\def accept(value):
        \\    print("filter", value)
        \\    return value % 2
        \\def emit(value):
        \\    print("body", value)
        \\    return value
        \\def create():
        \\    prefix = 100
        \\    return (emit(prefix + value) for value in source() if accept(value))
        \\items = create()
        \\print("created")
        \\print(next(items))
        \\print(next(items))
        \\print(list(items))
    , "generator-lazy.py"));
    runtime.heap.collection_threshold = 1;
    try runToCompletion(&runtime, 3);
    try std.testing.expect(runtime.heap.collection_count > 0);
    try std.testing.expectEqualStrings(
        "outer iterable\ncreated\nfilter 1\nbody 101\n101\nfilter 2\nfilter 3\nbody 103\n103\n[]\n",
        runtime.stdout(),
    );

    try expectReady(runtime.compileAndStart("dangling = (value for value in [7, 8])\nprint(next(dangling))\n", "generator-reset.py"));
    runtime.heap.collection_threshold = 1;
    try runToCompletion(&runtime, 2);
    try std.testing.expectEqualStrings("7\n", runtime.stdout());
    try expectReady(runtime.compileAndStart("print(\"reused\")\n", "generator-reuse.py"));
    try runToCompletion(&runtime, 2);
    try std.testing.expectEqualStrings("reused\n", runtime.stdout());

    try expectRuntimeExceptionOutput("items = (value for value in 1)\nprint(\"after\")\n", .type_error, "");
}

pub fn testLambdaWalrusAndComprehensionWalrusBoundary() !void {
    try expectOutput(
        \\calls = 0
        \\def bump():
        \\    global calls
        \\    calls += 1
        \\    return calls
        \\def make(offset):
        \\    return lambda value=2: offset + value
        \\function = make(5)
        \\print(function(), function(9))
        \\print((saved := bump()), saved, calls)
        \\def choose():
        \\    if (answer := 7):
        \\        return answer
        \\print(choose())
    ,
        "7 14\n1 1 1\n7\n",
    );

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    const outcome = runtime.compileAndStart("print(\"must not run\")\n[(saved := value) for value in [1, 2]]\n", "walrus-comp.py");
    switch (outcome) {
        .syntax_error => |diagnostic| try std.testing.expectEqualStrings("assignment expressions are not supported in comprehensions", diagnostic.message),
        .unsupported => return error.ExpectedSyntaxErrorDiagnostic,
        .ready => return error.ExpectedRejectedComprehensionWalrus,
        .python_exception => return error.ExpectedCompileDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

pub fn testLazyMapFilterSortedStableSortAndListIndexBounds() !void {
    try expectOutput(
        \\values = [("first", 2), ("second", 1), ("third", 2)]
        \\def key(item):
        \\    print("key", item[0])
        \\    return item[1]
        \\values.sort(key=key, reverse=True)
        \\print(values)
        \\def bump(value):
        \\    print("map", value)
        \\    return value + 1
        \\mapped = map(bump, [1, 2])
        \\print("mapped")
        \\print(list(mapped))
        \\def odd(value):
        \\    print("filter", value)
        \\    return value % 2
        \\print(list(filter(odd, [1, 2, 3, 4])))
        \\print(sorted([3, 1, 2], reverse=True))
        \\numbers = [0, 1, 0, 2]
        \\print(numbers.index(0, 1), numbers.index(1, -3, 4))
    ,
        "key first\nkey second\nkey third\n[('first', 2), ('third', 2), ('second', 1)]\nmapped\nmap 1\nmap 2\n[2, 3]\nfilter 1\nfilter 2\nfilter 3\nfilter 4\n[1, 3]\n[3, 2, 1]\n2 1\n",
    );
    try expectOutput("numbers = [1, 2]\nprint(numbers.index(1, -(2 ** 100)))\n", "0\n");
    try expectRuntimeException("numbers = [1, 2]\nprint(numbers.index(1, 2 ** 100))\n", .value_error, "list-index.py:2:");
}

pub fn testMapMultipleIterablesFilterNoneAndNativeCallbacks() !void {
    try expectOutput(
        \\print(list(map(lambda left, right: left + right, [1, 2, 3], [10, 20])))
        \\print(list(filter(None, [0, 1, 2])))
        \\print(list(map(len, ["x", "ab"])))
        \\print(sorted(["aa", "b"], key=len))
    ,
        "[11, 22]\n[1, 2]\n[1, 2]\n['b', 'aa']\n",
    );
    try expectRuntimeExceptionOutput(
        "items = map(1, [1])\nprint(\"created\")\nprint(list(items))\n",
        .type_error,
        "created\n",
    );
}

pub fn testKeySortRejectsListMutation() !void {
    try expectRuntimeException(
        \\values = [3, 2, 1]
        \\def key(value):
        \\    values.clear()
        \\    return value
        \\values.sort(key=key)
    ,
        .value_error,
        "list-index.py:5:",
    );
}

pub fn testTemporaryReceiverAndCallbackSurviveSortCollection() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("print(\"before sort\")\n[2, 1].sort(key=lambda value: str([value] * 30000))\nprint(\"sort survived\")\n", "sort-temporary-receiver.py"));
    runtime.heap.collection_threshold = 1;
    while (!std.mem.endsWith(u8, runtime.stdout(), "before sort\n")) {
        try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, runtime.run(1));
    }
    const collections_before_sort = runtime.heap.collection_count;
    try runToCompletion(&runtime, 100_000);
    try std.testing.expect(runtime.heap.collection_count > collections_before_sort);
    try std.testing.expectEqualStrings("before sort\nsort survived\n", runtime.stdout());
}

pub fn testSortUsesSharedSynchronousWorkLimit() !void {
    try expectRuntimeExceptionOutput(
        "values = list(range(1500))\nvalues.reverse()\nvalues.sort()\n",
        .runtime_error,
        "",
    );
}

pub fn testGeneratorWorkLimitCancelCheckpointAndReuse() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("items = (value for value in range(10000000) if False)\nnext(items)\n", "generator-limit.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.runtime_error, runtime.pythonException().?.kind);
    try expectReady(runtime.compileAndStart("print(\"recovered\")\n", "generator-recovery.py"));
    try runToCompletion(&runtime, 2);
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());

    try expectReady(runtime.compileAndStart("items = (value for value in [1, 2])\nprint(next(items))\n", "generator-cancel.py"));
    var status = runtime.run(1);
    var checkpoints: usize = 0;
    while (status == .timeslice and runtime.stdout().len == 0 and checkpoints < 100) : (checkpoints += 1) status = runtime.run(1);
    try std.testing.expectEqualStrings("1\n", runtime.stdout());
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(1));
}

pub fn testSyncCallbackAllocationFailureRecoversSession() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        \\def make():
        \\    captured = 10
        \\    def key(value):
        \\        local = value
        \\        def read():
        \\            return local + captured
        \\        return value
        \\    print("callback starts")
        \\    print(sorted([2, 1], key=key))
        \\make()
    , "sync-callback-cap.py"));
    const original_cap = runtime.session_allocator.max_bytes;
    while (runtime.stdout().len == 0) {
        try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, runtime.run(1));
    }
    const live_before_callback = runtime.session_allocator.live_bytes;
    runtime.heap.collection_threshold = std.math.maxInt(usize);
    runtime.session_allocator.max_bytes = live_before_callback + 1536;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, runtime.pythonException().?.kind);
    runtime.session_allocator.max_bytes = original_cap;
    try expectReady(runtime.compileAndStart("print(\"recovered\")\n", "sync-callback-recovery.py"));
    try runToCompletion(&runtime, 100);
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "comprehensions.py"));
    try runToCompletion(&runtime, 100_000);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectRuntimeException(source: []const u8, kind: exceptions.PythonExceptionKind, location: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "list-index.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), location) != null);
}

fn expectRuntimeExceptionOutput(source: []const u8, kind: exceptions.PythonExceptionKind, expected_output: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "generator-outer.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
    try std.testing.expectEqualStrings(expected_output, runtime.stdout());
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        .unsupported => |diagnostic| {
            std.debug.print("comprehension source unsupported: {s}\n", .{diagnostic.message});
            return error.ExpectedExecutableProgram;
        },
        .syntax_error => |diagnostic| {
            std.debug.print("comprehension source syntax error: {s}\n", .{diagnostic.message});
            return error.ExpectedExecutableProgram;
        },
        .python_exception => |exception| {
            std.debug.print("comprehension compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableProgram;
        },
    }
}

fn runToCompletion(runtime: *runtime_vm.Runtime, quantum: u32) !void {
    var status = runtime.run(quantum);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(quantum);
    if (status != .completed) std.debug.print("comprehension VM status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}
