const std = @import("std");
const runtime_vm = @import("runtime_vm");
const bytecode = @import("frontend_bytecode");
const exceptions = @import("runtime_exception");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const iterator = @import("runtime_iterator");
const slice_module = @import("runtime_slice");

const Value = value_module.Value;

pub fn testListAliasMutationMethodsCyclesAndEquality() !void {
    try expectOutput(
        \\items = [3, 1, 2]
        \\alias = items
        \\items.append(4)
        \\items.extend([5, 6])
        \\items.insert(1, 9)
        \\print(alias)
        \\print(items.pop(), items.pop(1), items)
        \\print(items.remove(2), items.copy() == items, items.count(3), items.index(4))
        \\items.reverse()
        \\print(items)
        \\items.sort(reverse=True)
        \\print(items)
        \\loop = []
        \\loop.append(loop)
        \\print(loop)
        \\print([[1], [2]] == [[1], [2]], [2] in [[1], [2]])
    ,
        "[3, 9, 1, 2, 4, 5, 6]\n6 9 [3, 1, 2, 4, 5]\nNone True 1 2\n[5, 4, 1, 3]\n[5, 4, 3, 1]\n[[...]]\nTrue True\n",
    );
    try expectRuntimeException("left = []\nleft.append(left)\nright = []\nright.append(right)\nprint(left == right)\n", .recursion_error, "sequence.py:5:");
}

pub fn testListExtendAcceptsRangesStringsAndExistingIterators() !void {
    try expectOutput(
        \\values = []
        \\values.extend(range(3))
        \\values.extend("ab")
        \\cursor = iter(range(5, 7))
        \\values.extend(cursor)
        \\print(values)
    , "[0, 1, 2, 'a', 'b', 5, 6]\n");
}

pub fn testListExtendKeepsIteratorItemsRootedDuringGrowth() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        "values = []\nfor index in range(100):\n    values.extend(\"abcdefghij\")\nprint(len(values), values[0], values[-1])\n",
        "sequence-extend-gc.py",
    ));
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runToCompletion(&runtime, 7);
    try std.testing.expect(runtime.heap.collection_count > 0);
    try std.testing.expectEqualStrings("1000 a j\n", runtime.stdout());
}

pub fn testListExtendSelfIteratorStopsAtSessionCap() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("values = [1]\nvalues.extend(iter(values))\n", "sequence-self-iterator.py"));
    runtime.heap.collection_threshold = std.math.maxInt(usize);
    runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes + 16 * 1024;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, runtime.pythonException().?.kind);
}

pub fn testNoArgumentSplitUsesUnicodeWhitespace() !void {
    try expectOutput(
        "print(\" \\tA\\u2003B\\n\\u00a0\".split(), \" \\u2003\".split())\n",
        "['A', 'B'] []\n",
    );
}

pub fn testBytesTruthinessUsesLength() !void {
    try expectOutput(
        \\if b"":
        \\    print("bad empty bytes")
        \\else:
        \\    print("empty")
        \\if b"x":
        \\    print("nonempty")
    , "empty\nnonempty\n");
}

pub fn testBytesMembershipMatchesPythonProbes() !void {
    try expectOutput("print(True in b\"\\x01a\", b\"a\" in b\"\\x01a\")\n", "True True\n");
    try expectRuntimeException("print(256 in b\"a\")\n", .value_error, "sequence.py:1:");
    try expectRuntimeException("print(\"a\" in b\"a\")\n", .type_error, "sequence.py:1:");
}

pub fn testListMethodBoundParity() !void {
    try expectRuntimeException("items = [1]\nitems.pop(10 ** 100)\n", .overflow_error, "sequence.py:2:");
    try expectOutput("items = [2, 1]\nitems.sort(reverse=1)\nprint(items)\n", "[2, 1]\n");
}

pub fn testSequenceRepresentationQuotesEscapesAndBoundsDepth() !void {
    try expectOutput("print([\"it's\", \"\\x01\", \"\\x7f\", b\"it's\", b\"\\x01\"])\n", "[\"it's\", '\\x01', '\\x7f', b\"it's\", b'\\x01']\n");
    try expectRuntimeException("value = []\nfor index in range(130):\n    value = [value]\nprint(value)\n", .recursion_error, "sequence.py:4:");
}

pub fn testTupleValuesAndMutableIteration() !void {
    try expectOutput(
        \\first = (1, "a")
        \\second = (2,)
        \\print(first + second, first * 2, len(first), not ())
        \\print((1, [2]) == (1, [2]), [2] in (1, [2]))
        \\items = [1, 2, 3]
        \\for item in items:
        \\    print(item)
        \\    if item == 2:
        \\        items.append(4)
        \\items = [1, 2, 3, 4]
        \\for item in items:
        \\    print(item)
        \\    if item == 2:
        \\        del items[2]
    ,
        "(1, 'a', 2) (1, 'a', 1, 'a') 2 True\nTrue True\n1\n2\n3\n4\n1\n2\n4\n",
    );
    try expectRuntimeException("items = (1, 2)\nitems[0] = 3\n", .type_error, "sequence.py:2:");
}

pub fn testIndexingSlicingAndUnicodeStringBytesBridge() !void {
    try expectOutput(
        \\values = [0, 1, 2, 3, 4]
        \\print(values[-1], values[4:0:-2], values[::-1])
        \\pair = (0, 1, 2, 3, 4)
        \\print(pair[-2], pair[1:4:2])
        \\text = "A雪B𝄞"
        \\print(len(text), text[-1], text[3::-2])
        \\print("A雪B".find("B"), "A雪B".index("雪"), "A雪B".split("雪"))
        \\print("-".join(["A", "雪", "B"]), " ß ".strip().upper())
        \\payload = "A雪".encode()
        \\print(payload, payload[1], payload[::-1], payload.decode())
        \\print(b"A:B".split(b":"), b"abc".find(b"b"))
    ,
        "4 [4, 2] [4, 3, 2, 1, 0]\n3 (1, 3)\n4 𝄞 𝄞雪\n2 1 ['A', 'B']\nA-雪-B SS\nb'A\\xe9\\x9b\\xaa' 233 b'\\xaa\\x9b\\xe9A' A雪\n[b'A', b'B'] 1\n",
    );
    try expectRuntimeException("print([1, 2][::0])\n", .value_error, "sequence.py:1:");
    try expectRuntimeException("print([1, 2][4])\n", .index_error, "sequence.py:1:");
    try expectRuntimeException("print([1][10 ** 100])\n", .index_error, "sequence.py:1:");
    try expectRuntimeException("print(\"A\"[10 ** 100])\n", .index_error, "sequence.py:1:");
    try expectOutput("print(\"A\"[10 ** 100:])\n", "\n");
    try expectOutput(
        \\items = [1]
        \\items.insert(999999, 2)
        \\items.insert(-999999, 0)
        \\print(items)
    , "[0, 1, 2]\n");
    try expectRuntimeException("items = [1]\nitems.insert(10 ** 100, 2)\n", .overflow_error, "sequence.py:2:");
    try expectRuntimeException("items = [1]\nitems.insert(2 ** 80, 2)\n", .overflow_error, "sequence.py:2:");
    try expectRuntimeException("print([] * (10 ** 100))\n", .overflow_error, "sequence.py:1:");
    try expectRuntimeException("print([1] * -(10 ** 100))\n", .overflow_error, "sequence.py:1:");
    try expectRuntimeException("print([] * (2 ** 80))\n", .overflow_error, "sequence.py:1:");
    try expectRuntimeException("print([1] * (2 ** 40))\n", .memory_error, "sequence.py:1:");
}

pub fn testInsertUsesPythonSsizeRange() !void {
    try expectRuntimeException("items = [1]\nitems.insert(2 ** 80, 2)\n", .overflow_error, "sequence.py:2:");
}

pub fn testRepeatUsesPythonSsizeRangeEvenForEmptyInput() !void {
    try expectRuntimeException("print([] * (2 ** 80))\n", .overflow_error, "sequence.py:1:");
    try expectRuntimeException("print([] * (2 ** 63))\n", .overflow_error, "sequence.py:1:");
}

pub fn testPythonSsizeValuesBeyondWasmIndexRange() !void {
    try expectOutput(
        "items = [1]\nitems.insert(2 ** 40, 2)\nprint(items, [] * (2 ** 40), () * (2 ** 40))\nprint(len(range(2 ** 40)))\n",
        "[1, 2] [] ()\n1099511627776\n",
    );
    try expectRuntimeException("print(len(range(2 ** 63)))\n", .overflow_error, "sequence.py:1:");
}

pub fn testRepeatSupportsIntegerLeftOperand() !void {
    try expectOutput("print(2 * [1], 2 * (1,))\n", "[1, 1] (1, 1)\n");
}

pub fn testLazyRangeIndexingSlicingAndSequenceBuiltins() !void {
    try expectOutput(
        \\base = 2 ** 100
        \\items = range(base, base + 10, 2)
        \\print(items[-1] == base + 8, items[1] == base + 2)
        \\print(items[1:4])
        \\print(items[::-1])
        \\print(2.0 ** 200 in range(2 ** 200, 2 ** 200 + 1))
        \\print(list((1, 2)), tuple([3, 4]), len("A雪"))
        \\print(list(enumerate("A雪", 2)))
        \\print(list(zip([1, 2], ("a", "b"))), list(reversed([3, 4])))
        \\iterator = iter([5, 6])
        \\print(next(iterator), next(iterator))
    ,
        "True True\nrange(1267650600228229401496703205378, 1267650600228229401496703205384, 2)\nrange(1267650600228229401496703205384, 1267650600228229401496703205374, -2)\nTrue\n[1, 2] (3, 4) 2\n[(2, 'A'), (3, '雪')]\n[(1, 'a'), (2, 'b')] [4, 3]\n5 6\n",
    );
    try expectRuntimeException("print(len(range(10 ** 100)))\n", .overflow_error, "sequence.py:1:");
}

pub fn testNegativeBigintRangeSliceSurvivesCollection() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        "selected = range(0, 2 ** 200, 3)[-(2 ** 100)::-2]\nprint(selected[0] > selected[1], selected[-1] >= 0)\n",
        "sequence-negative-bigint-slice.py",
    ));
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runToCompletion(&runtime, 3);
    try std.testing.expect(runtime.heap.collection_count > 0);
    try std.testing.expectEqualStrings("True True\n", runtime.stdout());
}

pub fn testRangeSliceReportsCappedNegativeStepMemoryError() !void {
    var measurement: runtime_vm.Runtime = undefined;
    try measurement.init(std.testing.allocator, 8 * 1024 * 1024);
    defer measurement.deinit();
    measurement.heap.collection_threshold = std.math.maxInt(usize);
    const measured_range = try prepareHugeRange(&measurement);
    const before_length = measurement.session_allocator.live_bytes;
    measurement.session_allocator.peak_bytes = before_length;
    switch (iterator.rangeLength(&measurement.heap, measured_range)) {
        .value => {},
        .python_exception, .engine_error => return error.ExpectedRangeLength,
    }
    const length_allocation_bytes = measurement.session_allocator.live_bytes - before_length;
    const length_peak_bytes = measurement.session_allocator.peak_bytes - before_length;
    try std.testing.expect(length_peak_bytes > length_allocation_bytes + @sizeOf(iterator.Range));
    try std.testing.expect(length_allocation_bytes > 0);

    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = std.math.maxInt(usize);
    const range = try prepareHugeRange(&runtime);
    const slice = try prepareNegativeStepSlice(&runtime);
    var range_root = gc.Root{ .object = &range.header };
    var slice_root = gc.Root{ .object = &slice.header };
    var roots = gc.RootFrame{};
    roots.push(&runtime.heap.roots);
    roots.add(&range_root);
    roots.add(&slice_root);
    defer roots.pop();

    // Match rangeLength's measured peak: it can finish, then the remaining
    // slack is enough for a Range object but not the next large integer copy.
    runtime.session_allocator.peak_bytes = runtime.session_allocator.live_bytes;
    runtime.session_allocator.max_bytes = std.math.add(usize, runtime.session_allocator.live_bytes, length_peak_bytes) catch return error.TestOverflow;
    const result = iterator.rangeSlice(&runtime.heap, range, slice);
    switch (result) {
        .python_exception => |exception| try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, exception.kind),
        .value => return error.ExpectedMemoryError,
        .engine_error => return error.ExpectedMemoryError,
    }
}

fn prepareHugeRange(runtime: *runtime_vm.Runtime) !*iterator.Range {
    const stop = try takeInteger(number.shiftLeft(&runtime.heap, Value.fromSmallInt(1).?, Value.fromSmallInt(10_000).?));
    return switch (iterator.createRange(&runtime.heap, &.{ Value.fromSmallInt(0).?, stop, Value.fromSmallInt(1).? })) {
        .value => |range| range,
        .python_exception => error.ExpectedRange,
        .engine_error => error.ExpectedRange,
    };
}

fn prepareNegativeStepSlice(runtime: *runtime_vm.Runtime) !*slice_module.Slice {
    return switch (slice_module.create(&runtime.heap, Value.noneValue(), Value.noneValue(), Value.fromSmallInt(-2).?)) {
        .value => |slice| slice,
        .python_exception => error.ExpectedSlice,
        .engine_error => error.ExpectedSlice,
    };
}

pub fn testUnpackingVariadicCallsAndNameDeletion() !void {
    try expectOutput(
        \\def collect(first, second=2, *items, flag):
        \\    return (first, second, items, flag)
        \\print(collect(*[1, 3, 4], flag=5))
        \\print(*["a", "b"], sep=":")
        \\head, *middle, tail = [1, 2, 3, 4]
        \\print(head, middle, tail)
        \\first, second = (7, 8)
        \\print(first, second)
        \\for item, *rest in [(1, 2, 3), (4, 5)]:
        \\    print(item, rest)
        \\values = [10, 20, 30]
        \\del values[1]
        \\print(values)
        \\print(1, **{})
        \\del values
    ,
        "(1, 3, (4,), 5)\na:b\n1 [2, 3] 4\n7 8\n1 [2, 3]\n4 [5]\n[10, 30]\n1\n",
    );
    try expectRuntimeException("def local():\n    item = 1\n    del item\n    return item\nlocal()\n", .unbound_local_error, "sequence.py:4:");
}

pub fn testUnpackCapacityAndKnownRangeSizing() !void {
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart("values = [0] * 1000\nfirst, second = values\n", "sequence-unpack-cap.py"));
        runtime.heap.collection_threshold = std.math.maxInt(usize);
        try runToNextUnpack(&runtime);
        runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes + 1024;
        try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
        try std.testing.expectEqual(exceptions.PythonExceptionKind.value_error, runtime.pythonException().?.kind);
    }
    try expectOutput(
        "head, *rest = range(70000)\nprint(head, len(rest), rest[-1])\n",
        "0 69999 69999\n",
    );
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart("head, *rest = range(3)\nprint(head, rest)\n", "sequence-unpack-small-cap.py"));
        runtime.heap.collection_threshold = std.math.maxInt(usize);
        runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes + 8 * 1024;
        try runToCompletion(&runtime, 100_000);
        try std.testing.expectEqualStrings("0 [1, 2]\n", runtime.stdout());
    }
}

pub fn testSequenceGrowthSurvivesCollectionAndReportsMemoryError() !void {
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart(
            "def collect(*items):\n    return items\nprint(list(enumerate(\"AB\", 3)))\nprint(list(zip([1, 2], (3, 4))))\nprint(list(reversed([5, 6])))\nprint(collect(*[\"x\", \"y\"]))\n",
            "sequence-iterator-gc.py",
        ));
        runtime.heap.collection_threshold = 1;
        runtime.heap.threshold_growth_floor = 1;
        try runToCompletion(&runtime, 2);
        try std.testing.expect(runtime.heap.collection_count > 0);
        try std.testing.expectEqualStrings("[(3, 'A'), (4, 'B')]\n[(1, 3), (2, 4)]\n[6, 5]\n('x', 'y')\n", runtime.stdout());
    }
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart(
            "values = []\nfor value in range(150):\n    values.append(value)\nvalues.extend(values)\nprint(values[0], values[149], len(values))\n",
            "sequence-gc.py",
        ));
        runtime.heap.collection_threshold = 64;
        runtime.heap.threshold_growth_floor = 16;
        try runToCompletion(&runtime, 3);
        try std.testing.expect(runtime.heap.collection_count > 0);
        try std.testing.expectEqualStrings("0 149 300\n", runtime.stdout());
    }
    {
        var runtime: runtime_vm.Runtime = undefined;
        try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
        defer runtime.deinit();
        try expectReady(runtime.compileAndStart("values = []\nfor value in range(1000):\n    values.append(value)\n", "sequence-memory.py"));
        const original_cap = runtime.session_allocator.max_bytes;
        runtime.heap.collection_threshold = std.math.maxInt(usize);
        runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes + 1024;
        try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
        try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, runtime.pythonException().?.kind);
        runtime.session_allocator.max_bytes = original_cap;
        try expectReady(runtime.compileAndStart("print([1, 2, 3])\n", "sequence-recovery.py"));
        try runToCompletion(&runtime, 100_000);
        try std.testing.expectEqualStrings("[1, 2, 3]\n", runtime.stdout());
    }
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "sequence.py"));
    try runToCompletion(&runtime, 10_000);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn takeInteger(result: number.ValueResult) !Value {
    return switch (result) {
        .value => |value| value,
        .python_exception => error.ExpectedInteger,
        .engine_error => error.ExpectedInteger,
    };
}

fn expectRuntimeException(source: []const u8, kind: exceptions.PythonExceptionKind, location: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "sequence.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    const exception = runtime.pythonException() orelse return error.ExpectedPythonException;
    try std.testing.expectEqual(kind, exception.kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), location) != null);
}

fn expectUnsupported(source: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "sequence-unsupported.py")) {
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
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(quantum);
    if (status != .completed) std.debug.print("sequence VM status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}

fn runToNextUnpack(runtime: *runtime_vm.Runtime) !void {
    const code = runtime.code orelse return error.ExpectedCode;
    var unpack_ip: ?usize = null;
    for (code.instructions, 0..) |instruction, index| {
        if (instruction.opcode() == .unpack) {
            unpack_ip = index;
            break;
        }
    }
    const target = unpack_ip orelse return error.ExpectedUnpackInstruction;
    while (runtime.instruction_pointer < target) {
        if (runtime.run(1) != .timeslice) return error.ProgramStoppedBeforeUnpack;
    }
}
