const std = @import("std");
const vm = @import("runtime_vm");
const host = @import("runtime_host");
const types = vm.NativeTypes;

const native_chunk_ops = types.TaskOps{ .step = nativeChunkStep };

fn nativeChunkStep(context: *anyopaque, task: *types.Task) types.TaskStep {
    const runtime: *vm.Runtime = @ptrCast(@alignCast(context));
    const count = task.child_value.asSmallInt() orelse 0;
    if (count == 512) return .{ .complete = types.Value.noneValue() };
    if (!runtime.chargeBulkWork(64)) return .yield;
    task.child_value = types.Value.fromSmallInt(count + 1).?;
    return .yield;
}

pub fn testNativeTaskChunksShareOneRunQuantum() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime, "print('after')\n");
    const caller = runtime.top_frame orelse return error.MissingChunkTaskCaller;
    const task = try types.createTask(&runtime.heap, null, .sys, 999, caller, 0, 1, 1, &.{}, &native_chunk_ops);
    try std.testing.expect(runtime.startNativeTask(task));
    try std.testing.expectEqual(vm.RunStatus.timeslice, runtime.run(0));
    try std.testing.expectEqual(@as(i64, 253), task.child_value.asSmallInt().?);
    try std.testing.expectEqual(vm.RunStatus.timeslice, runtime.run(0));
    try std.testing.expectEqual(@as(i64, 506), task.child_value.asSmallInt().?);
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 0));
    try std.testing.expectEqualStrings("after\n", runtime.stdout());
}

pub fn testPrimitiveIntConstructorInCallbacks() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\print(int(), int("42"), int("-10"), int(True), int(3.9), int("ff", 16), int("0b101", 0), int("1_000"))
        \\try:
        \\    int("oops")
        \\except ValueError:
        \\    print("invalid")
        \\print(list(map(int, ["2", "3"])))
    );
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("0 42 -10 1 3 255 5 1000\ninvalid\n[2, 3]\n", runtime.stdout());
}

pub fn testSysArgvCopiedAndReset() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 512 * 1024);
    defer runtime.deinit();
    var argument = [_]u8{ 'o', 'n', 'e' };
    const argv = [_][]const u8{ &argument, "β" };
    switch (runtime.compileAndStartArgs("import sys\nprint(sys.argv)\n", "script.py", &argv)) {
        .ready => {},
        else => return error.ExpectedCompiledArgvProgram,
    }
    for (&argument) |*byte| byte.* = 'x';
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("['script.py', 'one', 'β']\n", runtime.stdout());
    switch (runtime.compileAndStart("import sys\nprint(sys.argv)\n", "<string>")) {
        .ready => {},
        else => return error.ExpectedCompiledDefaultArgvProgram,
    }
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("['<string>']\n", runtime.stdout());
}

pub fn testNativeExceptionClassIdentity() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\try:
        \\    raise ValueError("ordinary")
        \\except AlphaError:
        \\    print("wrong")
        \\except ValueError:
        \\    print("builtin")
        \\try:
        \\    raise AlphaError("specific")
        \\except AlphaError as error:
        \\    print("alpha", type(error) is AlphaError)
        \\try:
        \\    raise AlphaError("child")
        \\except ParentError:
        \\    print("parent")
    );
    const parent = switch (vm.NativeExceptions.createNativeClass(&runtime.heap, "ParentError", .value_error, null)) {
        .value => |class| class,
        else => return error.NoNativeExceptionParent,
    };
    try std.testing.expect(runtime.storeGlobal("ParentError", types.Value.object(&parent.header)));
    const alpha = switch (vm.NativeExceptions.createNativeClass(&runtime.heap, "AlphaError", .value_error, parent)) {
        .value => |class| class,
        else => return error.NoNativeExceptionClass,
    };
    try std.testing.expect(runtime.storeGlobal("AlphaError", types.Value.object(&alpha.header)));
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("native exception identity result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("builtin\nalpha True\nparent\n", runtime.stdout());
}

const native_error_ops = types.NativeObjectOps{ .get_item = nativeErrorGetItem };

fn nativeErrorGetItem(raw_runtime: *anyopaque, _: *types.NativeObject, _: types.Value, _: u16, line: u32, column: u32) ?types.Value {
    const runtime: *vm.Runtime = @ptrCast(@alignCast(raw_runtime));
    const class_value = runtime.globalValue("AlphaError") orelse return null;
    const class = vm.NativeExceptions.classFromHeader(class_value.asObject() orelse return null) orelse return null;
    runtime.setException(.{ .kind = .value_error, .message = "bad input", .native_class = class }, line, column, null);
    const instance = runtime.active_exception orelse return null;
    vm.NativeExceptions.setAttribute(&runtime.heap, instance, "msg", runtime.createStringValue("bad input", line, column) orelse return null) catch return null;
    vm.NativeExceptions.setAttribute(&runtime.heap, instance, "pos", types.Value.fromSmallInt(3).?) catch return null;
    return null;
}

pub fn testNativeExceptionTransportAndAttributes() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\try:
        \\    native[0]
        \\except AlphaError as error:
        \\    print(error.msg, error.pos, type(error) is AlphaError)
    );
    const class = switch (vm.NativeExceptions.createNativeClass(&runtime.heap, "AlphaError", .value_error, null)) {
        .value => |created| created,
        else => return error.NoNativeExceptionClass,
    };
    try std.testing.expect(runtime.storeGlobal("AlphaError", types.Value.object(&class.header)));
    const object_class = runtime.ensureNativeClass(.regex_match, "NativeErrorProbe", 1, 1) orelse return error.NoNativeErrorProbeClass;
    const object = try types.createObject(&runtime.heap, object_class, .regex_match);
    object.ops = &native_error_ops;
    try std.testing.expect(runtime.storeGlobal("native", types.Value.object(&object.header)));
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("native exception attrs result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("bad input 3 True\n", runtime.stdout());
}

const NativeProtocolState = struct { next_index: u8 = 0 };

const native_protocol_ops = types.NativeObjectOps{
    .get_item = nativeProtocolGetItem,
    .contains = nativeProtocolContains,
    .iter = nativeProtocolIter,
    .next = nativeProtocolNext,
    .enter = nativeProtocolEnter,
    .exit = nativeProtocolExit,
};

fn nativeProtocolGetItem(_: *anyopaque, _: *types.NativeObject, _: types.Value, _: u16, _: u32, _: u32) ?types.Value {
    return types.Value.fromSmallInt(21);
}

fn nativeProtocolContains(_: *anyopaque, _: *types.NativeObject, _: types.Value, _: u32, _: u32) ?bool {
    return true;
}

fn nativeProtocolIter(_: *anyopaque, object: *types.NativeObject, _: u32, _: u32) ?types.Value {
    return types.Value.object(&object.header);
}

fn nativeProtocolNext(_: *anyopaque, object: *types.NativeObject, _: u16, _: u32, _: u32) types.NativeNextResult {
    const state: *NativeProtocolState = @ptrCast(@alignCast(object.payload.?));
    if (state.next_index == 2) return .done;
    state.next_index += 1;
    return .{ .item = types.Value.fromSmallInt(state.next_index).? };
}

fn nativeProtocolEnter(_: *anyopaque, object: *types.NativeObject, _: u32, _: u32) ?types.Value {
    return types.Value.object(&object.header);
}

fn nativeProtocolExit(_: *anyopaque, _: *types.NativeObject, _: u32, _: u32) ?bool {
    return true;
}

pub fn testNativeObjectProtocols() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\print(native[0], 5 in native)
        \\print(iter(native) is native)
        \\print([x for x in native])
        \\with native as same:
        \\    print(same is native)
    );
    const class = runtime.ensureNativeClass(.regex_find_iterator, "NativeProbe", 1, 1) orelse return error.NoNativeProbeClass;
    const object = try types.createObject(&runtime.heap, class, .regex_find_iterator);
    var state = NativeProtocolState{};
    object.payload = &state;
    object.ops = &native_protocol_ops;
    try std.testing.expect(runtime.storeGlobal("native", types.Value.object(&object.header)));
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("native ops result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("21 True\nTrue\n[1, 2]\nTrue\n", runtime.stdout());
}

const async_native_ops = types.NativeObjectOps{ .iter = nativeProtocolIter, .next = asyncNativeNext };
const async_next_task_ops = types.TaskOps{ .step = asyncNativeNextStep };

fn asyncNativeNext(raw_runtime: *anyopaque, object: *types.NativeObject, destination: u16, line: u32, column: u32) types.NativeNextResult {
    const runtime: *vm.Runtime = @ptrCast(@alignCast(raw_runtime));
    const caller = runtime.top_frame orelse return .{ .engine_error = .internal_invariant };
    const task = types.createTask(&runtime.heap, runtime.currentNativeTask(), .re, 991, caller, destination, line, column, &.{types.Value.object(&object.header)}, &async_next_task_ops) catch return .{ .python_exception = vm.NativeExceptions.memoryError() };
    if (!runtime.startNativeTask(task)) return .{ .engine_error = .internal_invariant };
    return .suspended;
}

fn asyncNativeNextStep(_: *anyopaque, task: *types.Task) types.TaskStep {
    const header = task.inputs[0].asObject() orelse return .{ .raise = .{ .kind = .runtime_error, .message = "missing native iterator" } };
    const object = types.fromHeader(header) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "missing native iterator" } };
    const state: *NativeProtocolState = @ptrCast(@alignCast(object.payload.?));
    if (state.next_index == 2) return .done;
    state.next_index += 1;
    return .{ .complete = types.Value.fromSmallInt(state.next_index).? };
}

pub fn testSuspendedNativeNextAndTerminalDone() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\print([item for item in native])
        \\try:
        \\    next(native)
        \\except StopIteration:
        \\    print("done")
    );
    const class = runtime.ensureNativeClass(.regex_find_iterator, "AsyncNativeProbe", 1, 1) orelse return error.NoAsyncNativeProbeClass;
    const object = try types.createObject(&runtime.heap, class, .regex_find_iterator);
    var state = NativeProtocolState{};
    object.payload = &state;
    object.ops = &async_native_ops;
    try std.testing.expect(runtime.storeGlobal("native", types.Value.object(&object.header)));
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("async native next result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("[1, 2]\ndone\n", runtime.stdout());
}

fn ready(runtime: *vm.Runtime, source: []const u8) !void {
    switch (runtime.compileAndStart(source, "library-bridge.py")) {
        .ready => {},
        else => return error.ExpectedCompiledLibraryProgram,
    }
}

fn boundary(runtime: *vm.Runtime, quantum: u32) !vm.RunStatus {
    var status = vm.RunStatus.timeslice;
    for (0..100_000) |_| {
        status = runtime.run(quantum);
        if (status != .timeslice) return status;
    }
    return error.NoExecutionBoundary;
}

pub fn testNativeRegistryPrecedenceAndFirstClassBinder() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/math.py", "print('wrong VFS math')\n");
    try ready(&runtime,
        \\import math
        \\from math import sqrt
        \\alias = math.sqrt
        \\print(math is __import__("math"), math is __import__("math"), alias(9), sqrt(16))
        \\try:
        \\    alias(9, bad=1)
        \\except TypeError:
        \\    print("binder rejected")
    );
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("registry result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("True True 3.0 4.0\nbinder rejected\n", runtime.stdout());
}

pub fn testPrimitiveTypeIdentityAndCallableKeywords() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\print(type(1) is int, type(True) is bool, type([]) is list)
        \\print(isinstance(True, int), type(1) is not type(""))
        \\class Callable:
        \\    def __call__(self, *, value):
        \\        return value + 1
        \\print(Callable()(value=6))
    );
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("types result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("True True True\nTrue True\n7\n", runtime.stdout());
}

pub fn testNativeStreamCallableIdentityAndBinder() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 256 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import sys
        \\write = sys.stdout.write
        \\print(type(sys.stdout) is type(sys.stderr))
        \\print(write("ok\n"))
        \\try:
        \\    write(text="no")
        \\except TypeError:
        \\    print("positional only")
        \\try:
        \\    sys.exit(7)
        \\except SystemExit as error:
        \\    print(error.code)
    );
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("native stream result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("True\nok\n3\npositional only\n7\n", runtime.stdout());
}

pub fn testLazySysStreamsAndRunMetadataUnderCap() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 256 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import sys
        \\print(sys.modules["sys"] is sys, sys.platform, sys.implementation.name)
        \\print(sys.argv)
        \\print("stream", file=sys.stderr)
        \\print(sys.stdout.write("out\n"))
    );
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("sys result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("True peony peony\n['library-bridge.py']\nout\n4\n", runtime.stdout());
}

pub fn testNestedNativeFactoryCallbackResumesInputOnce() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\from collections import defaultdict
        \\calls = 0
        \\def make():
        \\    global calls
        \\    calls += 1
        \\    return input("Factory: ")
        \\d = defaultdict(make)
        \\print(d["missing"], d["missing"], calls)
    );
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingFactoryInput;
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = "yes" }};
    var response = host.DecodedPacket{
        .kind = .input,
        .request_id = request_id,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&response));
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("factory result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("Factory: yes yes 1\n", runtime.stdout());
}

fn taskCallbackStep(comptime Runtime: type, runtime: *Runtime, task: *types.Task) types.TaskStep {
    if (!task.child_ready) {
        if (task.operation == 902) return .{ .call = .{
            .callable = task.inputs[0],
            .positional = &.{},
            .keywords = &.{.{ .name = "value", .value = types.Value.fromSmallInt(6).? }},
        } };
        return .{ .call = .{ .callable = task.inputs[0], .positional = &.{} } };
    }
    if (task.child_error != null) return .propagate;
    const content = runtime.valueString(task.child_value) orelse return .{ .raise = .{ .kind = .type_error, .message = "callback returned non-string" } };
    if (!runtime.appendOutput(content) or !runtime.appendOutput("\n")) return .{ .raise = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
    return .{ .complete = task.child_value };
}

pub fn testNativeTaskCallableInstanceKeywordsInput() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\class Callable:
        \\    def __call__(self, *, value):
        \\        return input("Call: ") + str(value)
        \\obj = Callable()
        \\print("after")
    );
    var callable: ?types.Value = null;
    for (0..1000) |_| {
        callable = runtime.globalValue("obj");
        if (callable != null) break;
        try std.testing.expectEqual(vm.RunStatus.timeslice, runtime.run(1));
    }
    const value = callable orelse return error.MissingTaskCallable;
    const caller = runtime.top_frame orelse return error.MissingTaskCaller;
    const task = try types.createTask(
        &runtime.heap,
        null,
        .sys,
        902,
        caller,
        0,
        1,
        1,
        &.{value},
        taskCallbackOps(vm.Runtime),
    );
    try std.testing.expect(runtime.startNativeTask(task));
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingCallableInput;
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = "yes" }};
    var response = host.DecodedPacket{
        .kind = .input,
        .request_id = request_id,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&response));
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("Call: yes6\nafter\n", runtime.stdout());
}

fn taskCallbackOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const runtime: *Runtime = @ptrCast(@alignCast(context));
            return taskCallbackStep(Runtime, runtime, task);
        }
        const ops = types.TaskOps{ .step = step };
    }.ops;
}

pub fn testNativeTaskCallInputQuantumOneNoReplay() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\def callback():
        \\    return input("Task: ")
        \\print("after")
    );
    var callback: ?types.Value = null;
    for (0..1000) |_| {
        callback = runtime.globalValue("callback");
        if (callback != null) break;
        try std.testing.expectEqual(vm.RunStatus.timeslice, runtime.run(1));
    }
    const function = callback orelse return error.MissingTaskCallback;
    const caller = runtime.top_frame orelse return error.MissingTaskCaller;
    const task = try types.createTask(
        &runtime.heap,
        null,
        .sys,
        900,
        caller,
        0,
        1,
        1,
        &.{function},
        taskCallbackOps(vm.Runtime),
    );
    try std.testing.expect(runtime.startNativeTask(task));
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingTaskInputRequest;
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = "yes" }};
    var response = host.DecodedPacket{
        .kind = .input,
        .request_id = request_id,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&response));
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("Task: yes\nafter\n", runtime.stdout());
    try std.testing.expect(runtime.currentNativeTask() == null);
}

fn iteratorTaskStep(comptime Runtime: type, runtime: *Runtime, task: *types.Task) types.TaskStep {
    if (task.child_ready) {
        if (task.child_error != null) return .propagate;
        if (task.child_done) return .{ .complete = types.Value.noneValue() };
        const content = runtime.valueString(task.child_value) orelse return .{ .raise = .{ .kind = .type_error, .message = "generator yielded non-string" } };
        if (!runtime.appendOutput(content) or !runtime.appendOutput("\n")) return .{ .raise = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
        task.child_ready = false;
        task.child_value = types.Value.noneValue();
    }
    return .{ .next = task.inputs[0] };
}

fn iteratorTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const runtime: *Runtime = @ptrCast(@alignCast(context));
            return iteratorTaskStep(Runtime, runtime, task);
        }
        const ops = types.TaskOps{ .step = step };
    }.ops;
}

pub fn testNativeTaskNextGeneratorInputQuantumOne() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\def values():
        \\    yield input("First: ")
        \\    yield input("Second: ")
        \\g = values()
        \\print("after")
    );
    var generator: ?types.Value = null;
    for (0..1000) |_| {
        generator = runtime.globalValue("g");
        if (generator != null) break;
        try std.testing.expectEqual(vm.RunStatus.timeslice, runtime.run(1));
    }
    const value = generator orelse return error.MissingTaskGenerator;
    const caller = runtime.top_frame orelse return error.MissingTaskCaller;
    const task = try types.createTask(
        &runtime.heap,
        null,
        .sys,
        901,
        caller,
        0,
        1,
        1,
        &.{value},
        iteratorTaskOps(vm.Runtime),
    );
    try std.testing.expect(runtime.startNativeTask(task));
    const replies = [_][]const u8{ "a", "b" };
    for (replies) |reply| {
        try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
        const request_id = runtime.pendingInputRequestId() orelse return error.MissingGeneratorInput;
        var sections = [_]host.Section{.{ .kind = .utf8, .bytes = reply }};
        var response = host.DecodedPacket{
            .kind = .input,
            .request_id = request_id,
            .status = .ok,
            .flags = 0,
            .sections = &sections,
            .storage = &.{},
        };
        try std.testing.expect(runtime.resumeHost(&response));
    }
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("First: a\nSecond: b\nafter\n", runtime.stdout());
    try std.testing.expect(runtime.currentNativeTask() == null);
}

pub fn testNativeTaskNextUserIteratorStopIteration() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\class Items:
        \\    def __init__(self):
        \\        self.n = 0
        \\    def __iter__(self):
        \\        return self
        \\    def __next__(self):
        \\        if self.n:
        \\            raise StopIteration
        \\        self.n = 1
        \\        return input("Item: ")
        \\it = iter(Items())
        \\print("after")
    );
    var iterator_value: ?types.Value = null;
    for (0..1000) |_| {
        iterator_value = runtime.globalValue("it");
        if (iterator_value != null) break;
        try std.testing.expectEqual(vm.RunStatus.timeslice, runtime.run(1));
    }
    const value = iterator_value orelse return error.MissingUserIterator;
    const caller = runtime.top_frame orelse return error.MissingTaskCaller;
    const task = try types.createTask(
        &runtime.heap,
        null,
        .sys,
        903,
        caller,
        0,
        1,
        1,
        &.{value},
        iteratorTaskOps(vm.Runtime),
    );
    try std.testing.expect(runtime.startNativeTask(task));
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingUserIteratorInput;
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = "one" }};
    var response = host.DecodedPacket{
        .kind = .input,
        .request_id = request_id,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&response));
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("Item: one\nafter\n", runtime.stdout());
}
