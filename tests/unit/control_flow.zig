const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testTruthinessShortCircuitAndConditionalExpressions() !void {
    try expectOutput(
        \\big = 10 ** 80
        \\big_zero = big - big
        \\if big_zero:
        \\    print("bad big zero")
        \\elif big_zero:
        \\    print("bad elif")
        \\else:
        \\    print("big zero")
        \\if big:
        \\    print("big nonzero")
        \\if "":
        \\    print("bad empty")
        \\else:
        \\    print("empty")
        \\if "\u96ea":
        \\    print("unicode")
        \\if 0.0:
        \\    print("bad zero float")
        \\else:
        \\    print("zero float")
        \\nan = 1e309 - 1e309
        \\if nan:
        \\    print("nan truthy")
        \\0 and print("and side effect must skip")
        \\1 or print("or side effect must skip")
        \\print(0 and 8, 0 or 9, "x" and 7, "x" or 8, None or "fallback")
        \\print(not 0, not 3, not "", not "x", not range(0), not range(1))
        \\print("yes" if 1 else "no", "no" if 0 else "yes")
    ,
        "big zero\nbig nonzero\nempty\nunicode\nzero float\nnan truthy\n0 9 7 x fallback\nTrue False True False True False\nyes yes\n",
    );
}

pub fn testComparisonsIdentityMembershipAndChaining() !void {
    try expectOutput(
        \\print(1 < 2 < 3, 1 < 2 > 3, 1.0 == 1, "a" < "b", "\u96ea" > "z")
        \\print(None is None, True is not 1, "\u96ea" in "a\u96eab", 4 in range(0, 10, 2), -2 in range(1, -4, -1))
        \\print(6 not in range(3), "x" not in "peony", "y" not in "peony")
        \\print(None in range(3), "x" in range(3))
        \\print(None is print("once") is None)
        \\print(1 is 2 is print("must skip"))
    ,
        "True False True True True\nTrue True True True True\nTrue True False\nFalse False\nonce\nTrue\nFalse\n",
    );
}

pub fn testIfWhileForBreakContinueAndLoopElse() !void {
    try expectOutput(
        \\total = 0
        \\for x in range(4):
        \\    if x == 1:
        \\        continue
        \\    if x == 3:
        \\        break
        \\    total += x
        \\else:
        \\    print("for else must be skipped")
        \\print(total)
        \\j = 0
        \\while j < 4:
        \\    j += 1
        \\    if j == 2:
        \\        continue
        \\    print(j)
        \\else:
        \\    print("while else")
        \\for x in range(2):
        \\    for y in range(3):
        \\        if y == 1:
        \\            continue
        \\        if x == 1 and y == 2:
        \\            break
        \\        total += 1
        \\    else:
        \\        print("inner", x)
        \\else:
        \\    print("outer")
        \\print(total)
    ,
        "2\n1\n3\n4\nwhile else\ninner 0\nouter\n5\n",
    );
}

pub fn testLazyBigIntRangesAndUnicodeStringIteration() !void {
    try expectOutput(
        \\for item in range(3):
        \\    print(item)
        \\for item in range(2, -3, -2):
        \\    print(item)
        \\for character in "A\u96ea\U0001d11e":
        \\    print(character)
        \\big = 10 ** 100
        \\print(big + 6 in range(big, big + 10, 3), 7 in range(10, 1, -1))
        \\for item in range(big + 1, big + 4):
        \\    print(item - big)
        \\if range(0):
        \\    print("bad empty range")
        \\else:
        \\    print("empty range")
        \\if range(1):
        \\    print("range truthy")
        \\print(range(1, 5, 2))
        \\for item in range(True, False, -1):
        \\    print(item)
        \\print(range(True, False, -1))
        \\for item in range(False, True, True):
        \\    print(item)
    ,
        "0\n1\n2\n2\n0\n-2\nA\n\xe9\x9b\xaa\n\xf0\x9d\x84\x9e\nTrue True\n1\n2\n3\nempty range\nrange truthy\nrange(1, 5, 2)\n1\nrange(1, 0, -1)\n0\n",
    );
}

pub fn testRangeErrorsShadowingAndUnsupportedInputs() !void {
    try expectRuntimeException(
        \\print("before")
        \\for item in range(0, 3, 0):
        \\    print("body")
    ,
        .value_error,
        "zero-step.py:2:",
    );
    try expectRuntimeException(
        \\result = range()
    , .type_error, "range-arity.py:1:");
    try expectRuntimeException(
        \\result = range(1, 2, 3, 4)
    , .type_error, "range-arity.py:1:");
    try expectRuntimeException(
        \\result = range(1, 2, False)
    , .value_error, "bool-step.py:1:");
    try expectRuntimeException(
        \\range = 7
        \\for item in range(2):
        \\    print("body")
    ,
        .type_error,
        "shadow-range.py:2:",
    );
    try expectRuntimeException(
        \\for item in 3:
        \\    print("body")
    ,
        .type_error,
        "not-iterable.py:1:",
    );
    try expectRuntimeException(
        \\for item in range("3"):
        \\    print("body")
    ,
        .type_error,
        "range-type.py:1:",
    );
    try expectRuntimeException(
        \\for left, right in range(2):
        \\    print("must not partially execute")
    ,
        .type_error,
        "range-target.py:1:",
    );
    try expectOutput(
        \\for item in [1, 2]:
        \\    print("body")
    , "body\nbody\n");
    try expectOutput("print(1 in [1])\n", "True\n");
}

pub fn testRangeAndIteratorStayRootedDuringCollection() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        \\start = 10 ** 50
        \\for item in range(start, start + 6):
        \\    print(item - start)
    ,
        "collect-loop.py",
    ));
    runtime.heap.collection_threshold = 64;
    runtime.heap.threshold_growth_floor = 16;
    try runToCompletion(&runtime, 10_000);
    try std.testing.expect(runtime.heap.collection_count > 0);
    try std.testing.expectEqualStrings("0\n1\n2\n3\n4\n5\n", runtime.stdout());
}

pub fn testRangeFloatMembershipAndMembershipRooting() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        \\print(5.0 in range(0, 10, 5), 5.5 in range(0, 10, 5))
        \\base = 10 ** 50
        \\print(base + 6 in range(base, base + 10, 3))
        \\float_base = 2 ** 100
        \\print(2.0 ** 100 in range(float_base, float_base + 1))
    , "range-membership.py"));
    runtime.heap.collection_threshold = 64;
    runtime.heap.threshold_growth_floor = 16;
    try runToCompletion(&runtime, 10_000);
    try std.testing.expect(runtime.heap.collection_count > 0);
    try std.testing.expectEqualStrings("True False\nTrue\nTrue\n", runtime.stdout());
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "control-flow.py"));
    try runToCompletion(&runtime, 10_000);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectRuntimeException(source: []const u8, kind: exceptions.PythonExceptionKind, location: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, location[0 .. std.mem.indexOfScalar(u8, location, ':') orelse location.len]));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    const exception = runtime.pythonException() orelse return error.ExpectedPythonException;
    try std.testing.expectEqual(kind, exception.kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), location) != null);
}

fn expectUnsupported(source: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "unsupported-loop.py")) {
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
    while (status == .timeslice and resumes < 10_000) : (resumes += 1) status = runtime.run(quantum);
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}
