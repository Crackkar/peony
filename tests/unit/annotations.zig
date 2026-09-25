const std = @import("std");
const runtime_vm = @import("runtime_vm");

pub fn testFunctionAnnotationsEvaluateInPythonOrderAndAreStored() !void {
    try expectOutput(
        \\events = []
        \\def note(value):
        \\    events.append(value)
        \\    return value
        \\def function(a: note("a"), b: note("b") = note("default")) -> note("return"):
        \\    pass
        \\print(events)
        \\print(function.__annotations__)
    , "['default', 'a', 'b', 'return']\n{'a': 'a', 'b': 'b', 'return': 'return'}\n");
}

pub fn testModuleClassTargetAndLocalAnnotationRules() !void {
    try expectOutput(
        \\events = []
        \\def note(value):
        \\    events.append(value)
        \\    return value
        \\class Holder:
        \\    pass
        \\holder = Holder()
        \\items = {}
        \\module_name: note("module")
        \\module_value: note("module annotation") = note("module value")
        \\holder.value: note("attribute annotation")
        \\items[note("index")]: note("subscript annotation")
        \\class Annotated:
        \\    class_name: note("class name")
        \\    class_value: note("class annotation") = note("class value")
        \\def local_annotation():
        \\    local_name: missing_annotation
        \\    return "local annotation was not evaluated"
        \\print(events)
        \\print(__annotations__)
        \\print(Annotated.__annotations__)
        \\print(local_annotation())
    , "['module', 'module value', 'module annotation', 'attribute annotation', 'index', 'subscript annotation', 'class name', 'class value', 'class annotation']\n{'module_name': 'module', 'module_value': 'module annotation'}\n{'class_name': 'class name', 'class_value': 'class annotation'}\nlocal annotation was not evaluated\n");
}

pub fn testFutureAnnotationsIsExplicitlyUnsupported() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(
        "from __future__ import annotations\nprint('must not execute')\n",
        "future-annotations.py",
    )) {
        .unsupported => {},
        .syntax_error => |diagnostic| {
            std.debug.print("future annotations syntax diagnostic: {s}\n", .{diagnostic.message});
            return error.ExpectedExplicitUnsupportedDiagnostic;
        },
        else => return error.ExpectedExplicitUnsupportedDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "annotations.py")) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("annotation syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableAnnotationProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("annotation unsupported at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableAnnotationProgram;
        },
        .python_exception => |exception| {
            std.debug.print("annotation compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableAnnotationProgram;
        },
    }
    var status = runtime.run(10_000);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 10_000) : (resumes += 1) status = runtime.run(10_000);
    if (status != .completed) std.debug.print("annotation status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}
