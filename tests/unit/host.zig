const std = @import("std");
const runtime_vm = @import("runtime_vm");
const host = @import("runtime_host");

fn runUntilBoundary(runtime: *runtime_vm.Runtime, instruction_limit: usize) runtime_vm.RunStatus {
    var status = runtime_vm.RunStatus.timeslice;
    for (0..instruction_limit) |_| {
        status = runtime.run(1);
        if (status != .timeslice) return status;
    }
    return status;
}

fn expectChunkedOutput(source: []const u8, expected: []const u8, effect_count: usize) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(source, "chunked-work.py") != .ready) return error.ExpectedReadyProgram;

    var status = runtime_vm.RunStatus.timeslice;
    var first_output = false;
    for (0..10_000) |_| {
        status = runtime.run(1);
        if (runtime.stdout().len != 0) {
            first_output = true;
            try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
            const first_chunk_effects = std.mem.count(u8, runtime.stdout(), "\n");
            try std.testing.expect(first_chunk_effects > 0);
            try std.testing.expect(first_chunk_effects < effect_count);
            break;
        }
        if (status != .timeslice) break;
    }
    try std.testing.expect(first_output);

    for (0..10_000) |_| {
        if (status != .timeslice) break;
        status = runtime.run(1);
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectChunkedCancelRecovery(source: []const u8, effect_count: usize) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(source, "cancel-work.py") != .ready) return error.ExpectedReadyProgram;

    var status = runtime_vm.RunStatus.timeslice;
    for (0..10_000) |_| {
        status = runtime.run(1);
        if (runtime.stdout().len != 0) break;
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
    try std.testing.expect(std.mem.count(u8, runtime.stdout(), "\n") < effect_count);
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(1));
    try std.testing.expect(std.mem.indexOf(u8, runtime.stdout(), "finally") == null);

    if (runtime.compileAndStart("print('recovered')\n", "after-work-cancel.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testInputEvaluatesPromptOnceAndSuspends() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    if (runtime.compileAndStart(
        \\def make_prompt():
        \\    print("prompt expression")
        \\    return "Name: "
        \\answer = input(make_prompt())
        \\print("answer", answer)
    , "input.py") != .ready) return error.ExpectedReadyProgram;

    const status = runUntilBoundary(&runtime, 1000);
    try std.testing.expectEqualStrings("host_request", @tagName(status));
    try std.testing.expectEqualStrings("prompt expression\nName: ", runtime.stdout());
}

pub fn testPrintFlushProducesOutputBoundary() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    if (runtime.compileAndStart(
        \\print("ready", flush=True)
        \\print("after")
    , "flush.py") != .ready) return error.ExpectedReadyProgram;

    const status = runUntilBoundary(&runtime, 1000);
    try std.testing.expectEqualStrings("output_event", @tagName(status));
    try std.testing.expectEqualStrings("ready\n", runtime.stdout());
    var packet = try host.decode(std.testing.allocator, runtime.eventBytes());
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(host.Kind.output, packet.kind);
    try std.testing.expectEqual(@as(usize, 0), packet.sections.len);
    try std.testing.expectEqualStrings("ready\n", runtime.stdout());
}

pub fn testLargeFlushedOutputUsesOnlyAnEventMarker() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();

    if (runtime.compileAndStart("print(list(range(200000)), flush=True)\n", "large-flush.py") != .ready) return error.ExpectedReadyProgram;
    var status = runtime_vm.RunStatus.timeslice;
    for (0..100) |_| {
        status = runtime.run(0);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.output_event, status);
    try std.testing.expect(runtime.stdout().len > host.max_packet_bytes);
    var packet = try host.decode(std.testing.allocator, runtime.eventBytes());
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(host.Kind.output, packet.kind);
    try std.testing.expectEqual(@as(usize, 0), packet.sections.len);
}

pub fn testInputResumeRootsValueAndDispatchesEofAndHostErrors() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    if (runtime.compileAndStart(
        \\answer = input("Name: ")
        \\print("answer", answer)
    , "resume-input.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, runUntilBoundary(&runtime, 1000));
    var request = try host.decode(std.testing.allocator, runtime.eventBytes());
    defer request.deinit(std.testing.allocator);
    const request_id = request.request_id;
    const wrong = host.DecodedPacket{
        .kind = .input,
        .request_id = request_id + 1,
        .status = .ok,
        .flags = 0,
        .sections = &.{},
        .storage = &.{},
    };
    const borrowed_event = try std.testing.allocator.dupe(u8, runtime.eventBytes());
    defer std.testing.allocator.free(borrowed_event);
    try std.testing.expect(!runtime.resumeHost(&wrong));
    try std.testing.expectEqualSlices(u8, borrowed_event, runtime.eventBytes());

    const response_sections = [_]host.Section{.{ .kind = .utf8, .bytes = "Ada\r\n" }};
    const response_bytes = try host.encode(std.testing.allocator, .{ .kind = .input, .request_id = request_id, .sections = &response_sections });
    defer std.testing.allocator.free(response_bytes);
    var response = try host.decode(std.testing.allocator, response_bytes);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(runtime.resumeHost(&response));
    _ = runtime.heap.collect();
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(1000));
    try std.testing.expectEqualStrings("Name: answer Ada\n", runtime.stdout());

    if (runtime.compileAndStart(
        \\try:
        \\    input("EOF: ")
        \\except EOFError:
        \\    print("eof")
    , "resume-eof.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, runUntilBoundary(&runtime, 1000));
    var eof_request = try host.decode(std.testing.allocator, runtime.eventBytes());
    defer eof_request.deinit(std.testing.allocator);
    const eof_bytes = try host.encode(std.testing.allocator, .{ .kind = .input, .request_id = eof_request.request_id, .status = .eof });
    defer std.testing.allocator.free(eof_bytes);
    var eof_response = try host.decode(std.testing.allocator, eof_bytes);
    defer eof_response.deinit(std.testing.allocator);
    try std.testing.expect(runtime.resumeHost(&eof_response));
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(1000));
    try std.testing.expectEqualStrings("EOF: eof\n", runtime.stdout());

    if (runtime.compileAndStart(
        \\try:
        \\    input("Host: ")
        \\except OSError as problem:
        \\    print(problem)
    , "resume-error.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, runUntilBoundary(&runtime, 1000));
    var error_request = try host.decode(std.testing.allocator, runtime.eventBytes());
    defer error_request.deinit(std.testing.allocator);
    const error_sections = [_]host.Section{.{ .kind = .utf8, .bytes = "device denied" }};
    const error_bytes = try host.encode(std.testing.allocator, .{ .kind = .input, .request_id = error_request.request_id, .status = .host_error, .sections = &error_sections });
    defer std.testing.allocator.free(error_bytes);
    var error_response = try host.decode(std.testing.allocator, error_bytes);
    defer error_response.deinit(std.testing.allocator);
    try std.testing.expect(runtime.resumeHost(&error_response));
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(1000));
    try std.testing.expectEqualStrings("Host: device denied\n", runtime.stdout());
}

pub fn testInputSuspendsInsideNestedFrameAtQuantumOne() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(
        \\def ask():
        \\    return input("Nested: ")
        \\answer = ask()
        \\print("answer", answer)
    , "nested-input.py") != .ready) return error.ExpectedReadyProgram;

    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, runUntilBoundary(&runtime, 1000));
    try std.testing.expectEqualStrings("Nested: ", runtime.stdout());
    var request = try host.decode(std.testing.allocator, runtime.eventBytes());
    defer request.deinit(std.testing.allocator);
    const response_sections = [_]host.Section{.{ .kind = .utf8, .bytes = "Lin\n" }};
    const response_bytes = try host.encode(std.testing.allocator, .{
        .kind = .input,
        .request_id = request.request_id,
        .sections = &response_sections,
    });
    defer std.testing.allocator.free(response_bytes);
    var response = try host.decode(std.testing.allocator, response_bytes);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(runtime.resumeHost(&response));
    _ = runtime.heap.collect();
    var status = runtime_vm.RunStatus.timeslice;
    for (0..1000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings("Nested: answer Lin\n", runtime.stdout());
}

pub fn testLongGeneratorYieldsAcrossRunQuantumWithoutReplay() !void {
    try expectChunkedOutput(
        \\values = list((print(item) or item for item in range(20)))
    , "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n", 20);
}

pub fn testLongMapAndFilterCallbacksYieldAcrossRunQuantum() !void {
    try expectChunkedOutput(
        \\def visit(item):
        \\    print(item)
        \\    return item
        \\values = list(map(visit, range(20)))
    , "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n", 20);

    try expectChunkedOutput(
        \\def keep(item):
        \\    print(item)
        \\    return item % 2 == 0
        \\values = list(filter(keep, range(20)))
    , "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n", 20);
}

pub fn testKeyedSortingYieldsAcrossRunQuantumWithoutRepeatingKeys() !void {
    try expectChunkedOutput(
        \\def key(item):
        \\    print(item)
        \\    return item
        \\values = sorted([19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], key=key)
    , "19\n18\n17\n16\n15\n14\n13\n12\n11\n10\n9\n8\n7\n6\n5\n4\n3\n2\n1\n0\n", 20);

    try expectChunkedOutput(
        \\def key(item):
        \\    print(item)
        \\    return item
        \\values = [19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
        \\values.sort(key=key)
    , "19\n18\n17\n16\n15\n14\n13\n12\n11\n10\n9\n8\n7\n6\n5\n4\n3\n2\n1\n0\n", 20);
}

pub fn testLongPythonCallbackYieldsAndCanBeCancelled() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(
        \\def visit(value):
        \\    for index in range(1000):
        \\        pass
        \\    print("callback done")
        \\    return value
        \\print("before")
        \\try:
        \\    result = list(map(visit, [1]))
        \\finally:
        \\    print("finally")
    , "callback-quantum.py") != .ready) return error.ExpectedReadyProgram;

    var status = runtime_vm.RunStatus.timeslice;
    for (0..1000) |_| {
        status = runtime.run(1);
        if (std.mem.endsWith(u8, runtime.stdout(), "before\n")) break;
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
    try std.testing.expectEqualStrings("before\n", runtime.stdout());
    for (0..30) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
    try std.testing.expectEqualStrings("before\n", runtime.stdout());
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(1));
    try std.testing.expectEqualStrings("before\n", runtime.stdout());
    if (runtime.compileAndStart("print(\"recovered\")\n", "callback-quantum-reuse.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(10));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testNestedCallbackMaterializationHonorsConfiguredWorkLimit() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    var config = host.Config.defaults();
    config.max_instructions = 200;
    runtime.configureHost(config);
    if (runtime.compileAndStart(
        \\def key(value):
        \\    items = list(range(100000))
        \\    print("materialized")
        \\    return value
        \\values = [2, 1]
        \\print("before")
        \\values.sort(key=key)
        \\print("after")
    , "nested-callback-work-limit.py") != .ready) return error.ExpectedReadyProgram;

    try std.testing.expectEqual(runtime_vm.RunStatus.limit, runtime.run(50_000));
    try std.testing.expect(runtime.workCount() <= config.max_instructions);
    try std.testing.expectEqualStrings("before\n", runtime.stdout());
    if (runtime.compileAndStart("print(\"recovered\")\n", "nested-callback-recovery.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testEnumerateAndZipResumeGeneratorAndMapChildrenAtQuantumOne() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    if (runtime.compileAndStart(
        \\def identity(value):
        \\    return value
        \\print(list(enumerate((value for value in range(3)), 4)))
        \\print(list(enumerate(map(identity, (value for value in range(2))), 7)))
        \\print(list(zip((value for value in range(3)), (value for value in range(3, 6)))))
        \\print(list(zip([10, 20, 30], (value for value in range(3, 6)))))
        \\print(list(zip((value for value in range(3)), map(identity, [10, 20, 30]))))
        \\print(list(zip()))
    , "composed-iterators.py") != .ready) return error.ExpectedReadyProgram;

    var status = runtime_vm.RunStatus.timeslice;
    for (0..5_000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(
        "[(4, 0), (5, 1), (6, 2)]\n[(7, 0), (8, 1)]\n[(0, 3), (1, 4), (2, 5)]\n[(10, 3), (20, 4), (30, 5)]\n[(0, 10), (1, 20), (2, 30)]\n[]\n",
        runtime.stdout(),
    );
}

pub fn testMultiSourceMapPreservesValuesAcrossGeneratorSuspension() !void {
    try expectChunkedOutput(
        \\def combine(left, right):
        \\    print("pair", left, right)
        \\    return left + right
        \\source = (print("source", value) or value for value in [10, 20])
        \\result = list(map(combine, [1, 2], source))
        \\print(result)
    , "source 10\npair 1 10\nsource 20\npair 2 20\n[11, 22]\n", 4);
}

pub fn testCancellationInsideChunkedGeneratorStopsWithoutFinally() !void {
    try expectChunkedCancelRecovery(
        \\try:
        \\    values = list((print(item) or item for item in range(20)))
        \\finally:
        \\    print("finally")
    , 20);
}

pub fn testPlainSortUsesResumableWorkBudget() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(
        \\values = list(range(1600, 0, -1))
        \\values.sort()
        \\print(values[0], values[-1])
    , "plain-sort-work.py") != .ready) return error.ExpectedReadyProgram;

    var status = runtime_vm.RunStatus.timeslice;
    for (0..128) |_| {
        status = runtime.run(50_000);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings("1 1600\n", runtime.stdout());
}

pub fn testSortLimitCapsNativeWorkBeforeOvershoot() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    var config = host.Config.defaults();
    runtime.configureHost(config);
    if (runtime.compileAndStart(
        \\values = list(range(400))
        \\values.reverse()
        \\print("before sort")
        \\values.sort()
        \\print("after sort")
    , "sort-budget.py") != .ready) return error.ExpectedReadyProgram;
    var status = runtime_vm.RunStatus.timeslice;
    for (0..10_000) |_| {
        status = runtime.run(1);
        if (std.mem.endsWith(u8, runtime.stdout(), "before sort\n")) break;
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
    try std.testing.expectEqualStrings("before sort\n", runtime.stdout());
    const work_before_sort = runtime.workCount();
    config.max_instructions = work_before_sort + 10;
    runtime.configureHost(config);
    try std.testing.expectEqual(runtime_vm.RunStatus.limit, runtime.run(50_000));
    try std.testing.expectEqualStrings("before sort\n", runtime.stdout());
    try std.testing.expect(runtime.workCount() <= work_before_sort + 10);
    try std.testing.expect(runtime.instructionCount() <= config.max_instructions);
    if (runtime.compileAndStart("print(\"recovered\")\n", "sort-budget-recovery.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testBytecodeContinuationCannotOvershootNativeWorkLimit() !void {
    const source =
        \\values = list(range(240, 0, -1))
        \\values.reverse()
        \\print("before sort")
        \\values.sort()
        \\input()
    ;
    var baseline: runtime_vm.Runtime = undefined;
    try baseline.init(std.testing.allocator, 16 * 1024 * 1024);
    defer baseline.deinit();
    if (baseline.compileAndStart(source, "sort-continuation-budget.py") != .ready) return error.ExpectedReadyProgram;
    var status = runtime_vm.RunStatus.timeslice;
    for (0..10_000) |_| {
        status = baseline.run(1);
        if (std.mem.endsWith(u8, baseline.stdout(), "before sort\n")) break;
        if (status != .timeslice and status != .output_event) break;
    }
    try std.testing.expectEqualStrings("before sort\n", baseline.stdout());
    status = baseline.run(50_000);
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, status);
    const cap = baseline.workCount() - 1;

    var limited: runtime_vm.Runtime = undefined;
    try limited.init(std.testing.allocator, 16 * 1024 * 1024);
    defer limited.deinit();
    var config = host.Config.defaults();
    limited.configureHost(config);
    if (limited.compileAndStart(source, "sort-continuation-budget.py") != .ready) return error.ExpectedReadyProgram;
    status = .timeslice;
    for (0..10_000) |_| {
        status = limited.run(1);
        if (std.mem.endsWith(u8, limited.stdout(), "before sort\n")) break;
        if (status != .timeslice and status != .output_event) break;
    }
    try std.testing.expectEqualStrings("before sort\n", limited.stdout());
    config.max_instructions = cap;
    limited.configureHost(config);
    try std.testing.expectEqual(runtime_vm.RunStatus.limit, limited.run(50_000));
    try std.testing.expect(limited.workCount() <= cap);
    try std.testing.expect(limited.instructionCount() <= cap);
    try std.testing.expectEqualStrings("before sort\n", limited.stdout());
}

pub fn testPlainSortYieldsInsideSortAndCancellationSkipsFinally() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(
        \\values = list(range(1200, 0, -1))
        \\print("before")
        \\try:
        \\    values.sort()
        \\    print("done")
        \\finally:
        \\    print("finally")
    , "plain-sort-cancel.py") != .ready) return error.ExpectedReadyProgram;

    var status = runtime_vm.RunStatus.timeslice;
    for (0..5000) |_| {
        status = runtime.run(1);
        if (std.mem.endsWith(u8, runtime.stdout(), "before\n")) break;
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
    try std.testing.expectEqualStrings("before\n", runtime.stdout());
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, runtime.run(1)); // enter the try region
    const before_work = runtime.workCount();
    status = runtime.run(1);
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
    try std.testing.expect(runtime.workCount() - before_work <= 2);
    try std.testing.expectEqualStrings("before\n", runtime.stdout());
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(1));
    try std.testing.expectEqualStrings("before\n", runtime.stdout());

    if (runtime.compileAndStart("print(\"recovered\")\n", "sort-cancel-reuse.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(10));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}
