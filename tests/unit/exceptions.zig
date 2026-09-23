const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");
const Value = @import("runtime_value").Value;

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    const outcome = runtime.compileAndStart(source, "exceptions.py");
    if (outcome != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(10_000));
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectException(source: []const u8, expected: exceptions.PythonExceptionKind) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    const outcome = runtime.compileAndStart(source, "exceptions.py");
    if (outcome != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    try std.testing.expectEqual(expected, runtime.pythonException().?.kind);
}

fn expectQuantumExceptionOutput(source: []const u8, expected_output: []const u8, expected_kind: exceptions.PythonExceptionKind) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    const outcome = runtime.compileAndStart(source, "finally-quantum.py");
    if (outcome != .ready) return error.ExpectedReadyProgram;
    var status = runtime_vm.RunStatus.timeslice;
    for (0..1000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, status);
    try std.testing.expectEqual(expected_kind, runtime.pythonException().?.kind);
    try std.testing.expectEqualStrings(expected_output, runtime.stdout());
}

pub fn testTryExceptElseFinallyAndAssert() !void {
    try expectOutput(
        \\try:
        \\    print("body")
        \\except TypeError:
        \\    print("wrong handler")
        \\else:
        \\    print("else")
        \\finally:
        \\    print("finally")
        \\try:
        \\    raise ValueError("broken")
        \\except (TypeError, ValueError) as error:
        \\    print(error)
        \\finally:
        \\    print("caught finally")
        \\assert True, print("lazy message")
    ,
        "body\nelse\nfinally\nbroken\ncaught finally\n",
    );
}

pub fn testExceptionHierarchy() !void {
    try std.testing.expect(exceptions.isSubclass(.unbound_local_error, .name_error));
    try std.testing.expect(exceptions.isSubclass(.tab_error, .indentation_error));
    try std.testing.expect(exceptions.isSubclass(.indentation_error, .syntax_error));
    try std.testing.expect(exceptions.isSubclass(.syntax_error, .exception));
    try std.testing.expect(exceptions.isSubclass(.module_not_found_error, .import_error));
    try std.testing.expect(exceptions.isSubclass(.module_not_found_error, .base_exception));
    try std.testing.expect(exceptions.isSubclass(.unicode_decode_error, .value_error));
    try std.testing.expect(exceptions.isSubclass(.file_not_found_error, .os_error));
    try std.testing.expect(exceptions.isSubclass(.generator_exit, .base_exception));
    try std.testing.expect(!exceptions.isSubclass(.generator_exit, .exception));
}

pub fn testFinallyRunsForReturnBreakAndContinue() !void {
    try expectOutput(
        \\def answer():
        \\    try:
        \\        return 7
        \\    finally:
        \\        print("return finally")
        \\print(answer())
        \\for item in range(3):
        \\    try:
        \\        if item == 1:
        \\            continue
        \\        if item == 2:
        \\            break
        \\        print(item)
        \\    finally:
        \\        print("loop finally", item)
    ,
        "return finally\n7\n0\nloop finally 0\nloop finally 1\nloop finally 2\n",
    );
}

pub fn testRaiseCauseAndExceptTargetCleanup() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    const outcome = runtime.compileAndStart(
        "try:\n    raise ValueError('inner')\nexcept ValueError as error:\n    try:\n        raise TypeError('outer') from error\n    except TypeError as outer:\n        print(outer)\nprint(error)\n",
        "cause.py",
    );
    if (outcome != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.name_error, runtime.pythonException().?.kind);
}

pub fn testCappedMemoryErrorHandlerAndSessionRecovery() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    const outcome = runtime.compileAndStart(
        "try:\n    raise ValueError('allocation fault')\nexcept MemoryError:\n    pass\n",
        "memory-error.py",
    );
    if (outcome != .ready) return error.ExpectedReadyProgram;

    const original_cap = runtime.session_allocator.max_bytes;
    _ = runtime.heap.collect();
    runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes;
    var status = runtime_vm.RunStatus.timeslice;
    for (0..100) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expect(runtime.pythonException() == null);
    try std.testing.expectEqualStrings("", runtime.stdout());

    runtime.session_allocator.max_bytes = original_cap;
    const reused = runtime.compileAndStart("print('recovered')\n", "recovery.py");
    if (reused != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testNestedFinallyLoopTransferAndHandlerCleanup() !void {
    try expectOutput(
        \\try:
        \\    for item in range(2):
        \\        if item == 0:
        \\            continue
        \\        print(item)
        \\    print("after")
        \\finally:
        \\    print("fin")
    , "1\nafter\nfin\n");

    try expectException(
        \\try:
        \\    raise ValueError("original")
        \\finally:
        \\    try:
        \\        raise TypeError("inner")
        \\    except TypeError:
        \\        pass
    , .value_error);

    try expectException(
        \\def f():
        \\    try:
        \\        raise ValueError()
        \\    except ValueError as error:
        \\        return
        \\    finally:
        \\        print(error)
        \\f()
    , .unbound_local_error);
}

pub fn testRaiseContextCauseAndTracebackFrames() !void {
    var context_runtime: runtime_vm.Runtime = undefined;
    try context_runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer context_runtime.deinit();
    if (context_runtime.compileAndStart(
        "try:\n    raise ValueError('first')\nexcept ValueError:\n    raise TypeError('second') from None\n",
        "context.py",
    ) != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, context_runtime.run(10_000));
    const context_error = context_runtime.active_exception orelse return error.ExpectedExceptionInstance;
    try std.testing.expectEqual(exceptions.PythonExceptionKind.type_error, context_error.kind);
    try std.testing.expect(context_error.suppress_context);
    try std.testing.expect(context_error.cause == null);
    try std.testing.expect(context_error.context != null);
    try std.testing.expectEqual(exceptions.PythonExceptionKind.value_error, context_error.context.?.kind);

    var cause_runtime: runtime_vm.Runtime = undefined;
    try cause_runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer cause_runtime.deinit();
    if (cause_runtime.compileAndStart(
        "try:\n    raise ValueError('first')\nexcept ValueError:\n    raise TypeError('second') from RuntimeError\n",
        "cause.py",
    ) != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, cause_runtime.run(10_000));
    const cause_error = cause_runtime.active_exception orelse return error.ExpectedExceptionInstance;
    try std.testing.expect(cause_error.suppress_context);
    try std.testing.expectEqual(exceptions.PythonExceptionKind.runtime_error, cause_error.cause.?.kind);
    try std.testing.expectEqual(exceptions.PythonExceptionKind.value_error, cause_error.context.?.kind);
    try std.testing.expect(std.mem.indexOf(u8, cause_runtime.errorText(), "The above exception was the direct cause") != null);
    try std.testing.expect(std.mem.indexOf(u8, cause_runtime.errorText(), "Traceback (most recent call last):") != null);
    try std.testing.expect(std.mem.indexOf(u8, cause_runtime.tracebackJson(), "\"filename\":\"cause.py\"") != null);

    var bare_runtime: runtime_vm.Runtime = undefined;
    try bare_runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer bare_runtime.deinit();
    if (bare_runtime.compileAndStart(
        "def f():\n    try:\n        raise ValueError('bare')\n    except ValueError:\n        raise\nf()\n",
        "bare.py",
    ) != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, bare_runtime.run(10_000));
    const bare_error = bare_runtime.active_exception orelse return error.ExpectedExceptionInstance;
    try std.testing.expectEqual(@as(usize, 2), bare_error.frames.items.len);

    var explicit_runtime: runtime_vm.Runtime = undefined;
    try explicit_runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer explicit_runtime.deinit();
    if (explicit_runtime.compileAndStart(
        "def f():\n    try:\n        raise ValueError('explicit')\n    except ValueError as error:\n        raise error\nf()\n",
        "explicit.py",
    ) != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, explicit_runtime.run(10_000));
    const explicit_error = explicit_runtime.active_exception orelse return error.ExpectedExceptionInstance;
    try std.testing.expectEqual(exceptions.PythonExceptionKind.value_error, explicit_error.kind);
    try std.testing.expectEqual(@as(usize, 3), explicit_error.frames.items.len);

    try expectOutput(
        \\def outer():
        \\    try:
        \\        raise ValueError("cell")
        \\    except ValueError as error:
        \\        def inner():
        \\            return error
        \\        print(inner())
        \\outer()
    , "cell\n");
}

pub fn testGeneratorAndCallbackFailuresRunInnerFinally() !void {
    try expectOutput(
        \\def fail():
        \\    try:
        \\        raise ValueError("generator")
        \\    finally:
        \\        print("generator finally")
        \\items = (fail() for item in range(1))
        \\try:
        \\    list(items)
        \\except ValueError:
        \\    print("generator caught")
        \\def key(value):
        \\    try:
        \\        raise TypeError("callback")
        \\    finally:
        \\        print("callback finally")
        \\try:
        \\    sorted([1], key=key)
        \\except TypeError:
        \\    print("callback caught")
    , "generator finally\ngenerator caught\ncallback finally\ncallback caught\n");
}

pub fn testUnhandledSynchronousCallbackAddsCallerTraceback() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(
        \\def fail():
        \\    raise ValueError("callback")
        \\sorted([1], key=fail)
    , "callback-trace.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    const trace = runtime.tracebackJson();
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"name\":\"<module>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"source_line\":\"sorted([1], key=fail)\"") != null);
}

pub fn testWithManagersEnterInOrderAndExitInReverse() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(
        "with first as a, second as b:\n    print(a, b)\n",
        "with-order.py",
    ) != .ready) return error.ExpectedReadyProgram;
    try runtime.installTestContextManager("first", "first", Value.fromSmallInt(1).?, false, null);
    try runtime.installTestContextManager("second", "second", Value.fromSmallInt(2).?, false, null);
    runtime.heap.collection_threshold = 1;
    const collections_before_run = runtime.heap.collection_count;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(10_000));
    try std.testing.expect(runtime.heap.collection_count > collections_before_run);
    try std.testing.expectEqualStrings(
        "enter first\nenter second\n1 2\nexit second None\nexit first None\n",
        runtime.stdout(),
    );
}

pub fn testWithSuppressionAndEnterFailure() !void {
    var suppressed: runtime_vm.Runtime = undefined;
    try suppressed.init(std.testing.allocator, 8 * 1024 * 1024);
    defer suppressed.deinit();
    if (suppressed.compileAndStart(
        "with outer, suppressor:\n    raise ValueError('hidden')\nprint('after')\n",
        "with-suppress.py",
    ) != .ready) return error.ExpectedReadyProgram;
    try suppressed.installTestContextManager("outer", "outer", Value.noneValue(), false, null);
    try suppressed.installTestContextManager("suppressor", "suppressor", Value.noneValue(), true, null);
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, suppressed.run(10_000));
    try std.testing.expectEqualStrings(
        "enter outer\nenter suppressor\nexit suppressor ValueError\nexit outer None\nafter\n",
        suppressed.stdout(),
    );

    var failed_enter: runtime_vm.Runtime = undefined;
    try failed_enter.init(std.testing.allocator, 8 * 1024 * 1024);
    defer failed_enter.deinit();
    if (failed_enter.compileAndStart("with broken:\n    print('body')\n", "with-enter.py") != .ready) return error.ExpectedReadyProgram;
    try failed_enter.installTestContextManager("broken", "broken", Value.noneValue(), false, .value_error);
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, failed_enter.run(10_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.value_error, failed_enter.pythonException().?.kind);
    try std.testing.expectEqualStrings("enter broken\n", failed_enter.stdout());
}

pub fn testWithTargetBindFailureStillExitsAndReturnExits() !void {
    var binding: runtime_vm.Runtime = undefined;
    try binding.init(std.testing.allocator, 8 * 1024 * 1024);
    defer binding.deinit();
    if (binding.compileAndStart("with manager as (left, right):\n    pass\n", "with-target.py") != .ready) return error.ExpectedReadyProgram;
    try binding.installTestContextManager("manager", "manager", Value.fromSmallInt(1).?, false, null);
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, binding.run(10_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.type_error, binding.pythonException().?.kind);
    try std.testing.expectEqualStrings("enter manager\nexit manager TypeError\n", binding.stdout());

    var returned: runtime_vm.Runtime = undefined;
    try returned.init(std.testing.allocator, 8 * 1024 * 1024);
    defer returned.deinit();
    if (returned.compileAndStart(
        \\def f():
        \\    with manager:
        \\        return 3
        \\print(f())
    , "with-return.py") != .ready) return error.ExpectedReadyProgram;
    try returned.installTestContextManager("manager", "manager", Value.noneValue(), false, null);
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, returned.run(10_000));
    try std.testing.expectEqualStrings("enter manager\nexit manager None\n3\n", returned.stdout());

    try expectException("with 1:\n    pass\n", .type_error);
}

pub fn testWithCancellationSkipsExit() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart("with manager:\n    print('body')\n", "with-cancel.py") != .ready) return error.ExpectedReadyProgram;
    try runtime.installTestContextManager("manager", "manager", Value.noneValue(), false, null);
    runtime.heap.collection_threshold = 1;
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, runtime.run(2));
    try std.testing.expectEqualStrings("enter manager\n", runtime.stdout());
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(1));
    try std.testing.expectEqualStrings("enter manager\n", runtime.stdout());
    if (runtime.compileAndStart("print('recovered')\n", "after-with-cancel.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testAssertionMessageSurvivesCollectionAndReset() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart("assert False, [1, 2]\n", "assert-message.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100));
    _ = runtime.heap.collect();
    const python_error = runtime.pythonException() orelse return error.ExpectedPythonException;
    try std.testing.expectEqual(exceptions.PythonExceptionKind.assertion_error, python_error.kind);
    try std.testing.expect(std.mem.indexOf(u8, python_error.message, "[1, 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), "AssertionError: [1, 2]") != null);

    if (runtime.compileAndStart("pass\n", "assert-reset.py") != .ready) return error.ExpectedReadyProgram;
    try std.testing.expect(runtime.pythonException() == null);
    try std.testing.expectEqualStrings("", runtime.tracebackJson());
}

pub fn testWithExitRunsForLoopTransfers() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    if (runtime.compileAndStart(
        \\for index in range(3):
        \\    with manager:
        \\        print(index)
        \\        if index == 0:
        \\            continue
        \\        break
        \\    print("after")
    , "with-loop.py") != .ready) return error.ExpectedReadyProgram;
    try runtime.installTestContextManager("manager", "manager", Value.noneValue(), false, null);
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(10_000));
    try std.testing.expectEqualStrings(
        "enter manager\n0\nexit manager None\nenter manager\n1\nexit manager None\n",
        runtime.stdout(),
    );
}

pub fn testJumpInsideFinallyPreservesTheTryBlock() !void {
    try expectOutput(
        \\try:
        \\    print("body")
        \\finally:
        \\    for i in range(2):
        \\        if i == 0:
        \\            continue
        \\        print(i)
        \\    print("done")
    , "body\n1\ndone\n");
}

pub fn testPendingExceptionContinuationSurvivesNestedTryAcrossTimeslices() !void {
    try expectQuantumExceptionOutput(
        \\try:
        \\    raise ValueError("original")
        \\finally:
        \\    try:
        \\        print("inner")
        \\    finally:
        \\        print("done")
    , "inner\ndone\n", .value_error);
}

pub fn testPendingExceptionContinuationSurvivesCalledFrameAcrossTimeslices() !void {
    try expectQuantumExceptionOutput(
        \\def finish():
        \\    print("inner")
        \\try:
        \\    raise ValueError("original")
        \\finally:
        \\    finish()
        \\    print("done")
    , "inner\ndone\n", .value_error);
}
