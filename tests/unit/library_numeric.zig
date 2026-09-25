const std = @import("std");
const vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testMathContract() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import math
        \\print(3.14 < math.pi < 3.15, 2.71 < math.e < 2.72, math.tau == 2 * math.pi)
        \\print(math.isinf(math.inf), math.isnan(math.nan), math.isfinite(1.5), math.isfinite(math.inf))
        \\print(math.sqrt(81), math.pow(2, 5), math.exp(0), math.log(math.e), math.log(8, 2))
        \\print(math.log2(8), math.log10(1000), math.sin(0), math.cos(0), math.tan(0))
        \\print(math.log2(2 ** 1000), 2302 < math.log(10 ** 1000) < 2303)
        \\print(math.asin(0), math.acos(1), math.atan(0), math.atan2(0, -1) == math.pi)
        \\print(math.floor(-1.2), math.ceil(-1.2), math.trunc(-1.8), math.fabs(-2.5))
        \\print(math.factorial(30))
        \\print(math.gcd(), math.gcd(84, -30, 18), math.lcm(), math.lcm(6, -15))
        \\print(math.factorial(True), math.gcd(True, 3), math.lcm(False, 5))
        \\print(math.degrees(math.pi), math.radians(180) == math.pi)
    , "library-numeric-math.py", 1);
    try std.testing.expectEqualStrings(
        "True True True\nTrue True True False\n9.0 32.0 1.0 1.0 3.0\n3.0 3.0 0.0 1.0 0.0\n1000.0 True\n0.0 0.0 0.0 True\n-2 -1 -1 2.5\n265252859812191058636308480000000\n0 6 1 30\n1 1 0\n180.0 True\n",
        runtime.stdout(),
    );
}

pub fn testMathErrorsAndBinding() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import math
        \\checks = [
        \\    (lambda: math.sqrt(-1), ValueError, 'ValueError'),
        \\    (lambda: math.log(0), ValueError, 'ValueError'),
        \\    (lambda: math.factorial(-1), ValueError, 'ValueError'),
        \\    (lambda: math.factorial(3.0), TypeError, 'TypeError'),
        \\    (lambda: math.gcd(1.0, 2), TypeError, 'TypeError'),
        \\    (lambda: math.exp(1000), OverflowError, 'OverflowError'),
        \\    (lambda: math.sqrt(x=4), TypeError, 'TypeError'),
        \\]
        \\for call, expected, label in checks:
        \\    try:
        \\        call()
        \\    except expected:
        \\        print(label)
    , "library-numeric-math-errors.py", 1);
    try std.testing.expectEqualStrings(
        "ValueError\nValueError\nValueError\nTypeError\nTypeError\nOverflowError\nTypeError\n",
        runtime.stdout(),
    );
}

pub fn testRandomContractAndValidation() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import random
        \\def snapshot(seed):
        \\    random.seed(seed)
        \\    values = [random.random(), random.randint(-4, 4), random.randrange(20, 3, -4)]
        \\    shuffled = [0, 1, 2, 3, 4]
        \\    random.shuffle(shuffled)
        \\    return values, shuffled, random.sample(range(100), 8)
        \\for seed in [None, True, 2 ** 100 + 3, 2.5, "snow 雪", b"seed"]:
        \\    if seed is not None:
        \\        print(snapshot(seed) == snapshot(seed))
        \\random.seed("weighted")
        \\print(random.choice([9]))
        \\print(random.choices(["a", "b"], weights=[0, 1], k=4))
        \\print(random.choices(["a", "b"], cum_weights=[0, 4], k=3))
        \\counted = random.sample(["x", "y"], 3, counts=[2, 2])
        \\print(len(counted), counted.count("x") <= 2, counted.count("y") <= 2)
        \\sparse_counts = random.sample(["a", "b", "c", "d"], 5, counts=[0, 2, 0, 3])
        \\print(len(sparse_counts), sparse_counts.count("a"), sparse_counts.count("b"), sparse_counts.count("c"), sparse_counts.count("d"))
        \\print(random.sample([], 0, counts=[]))
        \\large = random.randrange(10 ** 40)
        \\print(0 <= large < 10 ** 40, -5 <= random.uniform(-5, 7) <= 7)
        \\random.seed(99)
        \\expected = random.random()
        \\random.seed(99)
        \\try:
        \\    random.choices([1, 2], weights=[0, 0])
        \\except ValueError:
        \\    pass
        \\print(random.random() == expected)
        \\for call, expected_error, label in [
        \\    (lambda: random.choice([]), IndexError, 'IndexError'),
        \\    (lambda: random.randrange(1, 2, 0), ValueError, 'ValueError'),
        \\    (lambda: random.sample([1], 2), ValueError, 'ValueError'),
        \\    (lambda: random.seed([]), TypeError, 'TypeError'),
        \\    (lambda: random.seed(1, version=1), NotImplementedError, 'NotImplementedError'),
        \\]:
        \\    try:
        \\        call()
        \\    except expected_error:
        \\        print(label)
    , "library-numeric-random.py", 1);
    try std.testing.expectEqualStrings(
        "True\nTrue\nTrue\nTrue\nTrue\n9\n['b', 'b', 'b', 'b']\n['b', 'b', 'b']\n3 True True\n5 0 2 0 3\n[]\nTrue True\nTrue\nIndexError\nValueError\nValueError\nTypeError\nNotImplementedError\n",
        runtime.stdout(),
    );
}

pub fn testRandomWorkBudgetAndCancellation() !void {
    var limited: vm.Runtime = undefined;
    try limited.init(std.testing.allocator, 8 * 1024 * 1024);
    defer limited.deinit();
    limited.max_instructions = 1_000;
    try numericReady(&limited,
        \\import random
        \\random.seed(31)
        \\print(len(random.sample(range(4000), 1000)))
    );
    try std.testing.expectEqual(vm.RunStatus.limit, numericBoundary(&limited, 50_000));
    try std.testing.expect(limited.workCount() <= limited.max_instructions);
    try std.testing.expectEqualStrings("", limited.stdout());

    limited.reset();
    limited.max_instructions = 1_000;
    try numericReady(&limited,
        \\import random
        \\print(len(random.choices(range(10), k=4000)))
    );
    try std.testing.expectEqual(vm.RunStatus.limit, numericBoundary(&limited, 50_000));
    try std.testing.expect(limited.workCount() <= limited.max_instructions);
    try std.testing.expectEqualStrings("", limited.stdout());

    var resumed: vm.Runtime = undefined;
    try resumed.init(std.testing.allocator, 8 * 1024 * 1024);
    defer resumed.deinit();
    try numericReady(&resumed,
        \\import random
        \\print(random.choices([], k=0))
        \\try:
        \\    random.choices([], k=1)
        \\except IndexError:
        \\    print('empty positive')
        \\values = list(range(4000))
        \\print('shuffle ready')
        \\random.shuffle(values)
        \\print('late shuffle')
    );
    var saw_marker = false;
    for (0..100_000) |_| {
        const step = resumed.run(1);
        try std.testing.expect(step == .timeslice or step == .output_event);
        if (std.mem.endsWith(u8, resumed.stdout(), "shuffle ready\n")) {
            saw_marker = true;
            break;
        }
    }
    try std.testing.expect(saw_marker);
    try std.testing.expectEqualStrings("[]\nempty positive\nshuffle ready\n", resumed.stdout());
    resumed.max_instructions = resumed.workCount() + 100;
    try std.testing.expectEqual(vm.RunStatus.limit, numericBoundary(&resumed, 50_000));
    try std.testing.expect(resumed.workCount() <= resumed.max_instructions);
    try std.testing.expectEqualStrings("[]\nempty positive\nshuffle ready\n", resumed.stdout());

    resumed.reset();
    resumed.max_instructions = 50_000_000;
    try numericReady(&resumed,
        \\import random
        \\random.seed(19)
        \\random.sample(range(40000), 10000)
        \\print('late sample')
    );
    var saw_task = false;
    for (0..1000) |_| {
        try std.testing.expectEqual(vm.RunStatus.timeslice, resumed.run(1));
        if (resumed.currentNativeTask()) |task| {
            if (task.owner == .random) {
                saw_task = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_task);
    const work_before = resumed.workCount();
    try std.testing.expectEqual(vm.RunStatus.timeslice, resumed.run(1));
    try std.testing.expect(resumed.workCount() > work_before);
    resumed.cancel();
    try std.testing.expectEqual(vm.RunStatus.cancelled, resumed.run(1));
    try std.testing.expect(resumed.currentNativeTask() == null);
    resumed.reset();
    try runScript(&resumed, "import random\nprint(random.choices([], k=0))\n", "library-random-after-cancel.py", 1);
    try std.testing.expectEqualStrings("[]\n", resumed.stdout());

    var bigint: vm.Runtime = undefined;
    try bigint.init(std.testing.allocator, 8 * 1024 * 1024);
    defer bigint.deinit();
    try numericReady(&bigint,
        \\import random
        \\bound = 1 << 8192
        \\print('bigint ready')
        \\random.randrange(bound)
        \\print('late bigint')
    );
    var big_marker = false;
    for (0..1000) |_| {
        const step = bigint.run(1);
        try std.testing.expect(step == .timeslice or step == .output_event);
        if (std.mem.endsWith(u8, bigint.stdout(), "bigint ready\n")) {
            big_marker = true;
            break;
        }
    }
    try std.testing.expect(big_marker);
    bigint.max_instructions = bigint.workCount() + 32;
    try std.testing.expectEqual(vm.RunStatus.limit, numericBoundary(&bigint, 50_000));
    try std.testing.expect(bigint.workCount() <= bigint.max_instructions);
    try std.testing.expectEqualStrings("bigint ready\n", bigint.stdout());
}

fn numericReady(runtime: *vm.Runtime, source: []const u8) !void {
    switch (runtime.compileAndStart(source, "library-random-work.py")) {
        .ready => {},
        else => return error.ExpectedExecutableNumericProgram,
    }
}

fn numericBoundary(runtime: *vm.Runtime, quantum: u32) vm.RunStatus {
    var status = vm.RunStatus.timeslice;
    for (0..100_000) |_| {
        status = runtime.run(quantum);
        if (status != .timeslice) return status;
    }
    return status;
}

pub fn testStatisticsContractAndOnePassIterables() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import statistics
        \\def once():
        \\    for value in [1, 3, 8]:
        \\        print("yield", value)
        \\        yield value
        \\print(statistics.mean(once()))
        \\print(statistics.mean([10 ** 30, 10 ** 30]))
        \\print(statistics.fmean([1e16, 1.0, -1e16]))
        \\print(statistics.fmean([1, 2, 10], weights=[2, 1, 1]))
        \\print(statistics.median([5, 1, 9, 3]), statistics.median([3, 1, 2]))
        \\print(statistics.mode(["b", "a", "b", "a"]))
        \\print(issubclass(statistics.StatisticsError, ValueError))
        \\for call, expected, label in [
        \\    (lambda: statistics.mean([]), statistics.StatisticsError, 'StatisticsError'),
        \\    (lambda: statistics.fmean([], weights=[]), statistics.StatisticsError, 'StatisticsError'),
        \\    (lambda: statistics.median([]), statistics.StatisticsError, 'StatisticsError'),
        \\    (lambda: statistics.mode([]), statistics.StatisticsError, 'StatisticsError'),
        \\    (lambda: statistics.mean([1, "bad"]), TypeError, 'TypeError'),
        \\    (lambda: statistics.fmean([1, 2], weights=[1]), ValueError, 'ValueError'),
        \\]:
        \\    try:
        \\        call()
        \\    except expected:
        \\        print(label)
    , "library-numeric-statistics.py", 1);
    try std.testing.expectEqualStrings(
        "yield 1\nyield 3\nyield 8\n4\n1000000000000000000000000000000\n0.3333333333333333\n3.5\n4.0 2\nb\nTrue\nStatisticsError\nStatisticsError\nStatisticsError\nStatisticsError\nTypeError\nValueError\n",
        runtime.stdout(),
    );
}

pub fn testNumericGcAndResetIsolation() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runScript(&runtime,
        \\import math, random, statistics
        \\random.seed(123456)
        \\print(math.factorial(100) > 10 ** 150, len(random.sample(range(10000), 100)), statistics.median(range(101)))
    , "library-numeric-gc.py", 1);
    try std.testing.expectEqualStrings("True 100 50\n", runtime.stdout());
    try std.testing.expect(runtime.heap.collection_count > 0);

    runtime.reset();
    try runScript(&runtime,
        \\import random
        \\random.seed(123456)
        \\first = [random.random(), random.randrange(10 ** 20)]
        \\random.seed(123456)
        \\print(first == [random.random(), random.randrange(10 ** 20)])
    , "library-numeric-reset.py", 1);
    try std.testing.expectEqualStrings("True\n", runtime.stdout());
}

fn runScript(runtime: *vm.Runtime, source: []const u8, filename: []const u8, quantum: u32) !void {
    switch (runtime.compileAndStart(source, filename)) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("numeric syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableNumericProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("numeric unsupported feature at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableNumericProgram;
        },
        .python_exception => |exception| {
            std.debug.print("numeric compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableNumericProgram;
        },
    }
    var status = runtime.run(quantum);
    for (0..200_000) |_| {
        if (status != .timeslice) break;
        status = runtime.run(quantum);
    }
    if (status != .completed) std.debug.print("numeric status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(vm.RunStatus.completed, status);
}

pub fn expectNumericException(runtime: *vm.Runtime, source: []const u8, kind: exceptions.PythonExceptionKind) !void {
    switch (runtime.compileAndStart(source, "library-numeric-error.py")) {
        .ready => {},
        else => return error.ExpectedExecutableNumericProgram,
    }
    var status = runtime.run(1);
    for (0..100_000) |_| {
        if (status != .timeslice) break;
        status = runtime.run(1);
    }
    try std.testing.expectEqual(vm.RunStatus.python_exception, status);
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
}
