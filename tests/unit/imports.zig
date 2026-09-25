const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");
const host = @import("runtime_host");

pub fn testImportCacheMetadataAndModuleGlobals() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/alpha.py",
        \\print("loaded")
        \\value = 7
        \\__all__ = ["value", "read"]
        \\_hidden = 99
        \\def read():
        \\    return value
    );
    try runToCompletion(&runtime,
        \\try:
        \\    print(sys)
        \\except NameError:
        \\    print("sys is not preloaded")
        \\import alpha as first
        \\import alpha
        \\from alpha import value as imported_value
        \\from alpha import *
        \\import sys
        \\print(first is alpha, imported_value, read(), value)
        \\print(first.__name__, first.__package__, first.__file__)
        \\print(sys.modules["alpha"] is alpha)
        \\def local_import():
        \\    import alpha as local
        \\    from alpha import value as local_value
        \\    return local.read() + local_value
        \\class ClassImport:
        \\    import alpha as local
        \\    value = local.value
        \\print(local_import(), ClassImport.value, ClassImport.local is alpha)
    , "import-main.py", 1);
    try std.testing.expectEqualStrings(
        "sys is not preloaded\nloaded\nTrue 7 7 7\nalpha  /home/alpha.py\nTrue\n14 7 True\n",
        runtime.stdout(),
    );
}

pub fn testPackagesRelativeImportsAndPackagePrecedence() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.mountCourseFile("/course/pkg.py", "print('wrong sibling')\nsibling = True\n");
    try runtime.mountCourseFile("/course/pkg/__init__.py", "print('package init')\n__all__ = ['root']\nroot = 'package'\nfrom . import child\n");
    try runtime.mountCourseFile("/course/pkg/child.py", "print('child init')\nvalue = 'child'\n");
    try runtime.mountCourseFile("/course/pkg/sub/__init__.py", "local = 'sub'\n");
    try runtime.mountCourseFile("/course/pkg/sub/mod.py", "from .. import root\nfrom . import local\n");
    try runToCompletion(&runtime,
        \\import pkg
        \\import pkg.child
        \\from pkg import root
        \\from pkg.sub import mod
        \\print(root, pkg.child.value, mod.root, mod.local, hasattr(pkg, "sibling"))
    , "package-main.py", 1);
    try std.testing.expectEqualStrings("package init\nchild init\npackage child package sub False\n", runtime.stdout());
}

pub fn testCircularImportsAndFailedImportRollback() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/circle_a.py", "before = 'A'\nimport circle_b\nseen = circle_b.seen\n");
    try runtime.writeVfsFile("/home/circle_b.py", "import circle_a\nseen = circle_a.before\n");
    try runtime.writeVfsFile("/home/broken.py", "print('first attempt')\nraise RuntimeError('broken')\n");
    try runToCompletion(&runtime,
        \\import sys
        \\import circle_a
        \\import circle_a
        \\print(circle_a.seen, circle_a is sys.modules["circle_a"])
        \\try:
        \\    import broken
        \\except RuntimeError:
        \\    print("failed")
        \\with open("/home/broken.py", "w") as replacement:
        \\    replacement.write("value = 'fixed'\n")
        \\import broken
        \\print(broken.value)
    , "import-cycle.py", 1);
    try std.testing.expectEqualStrings("A True\nfirst attempt\nfailed\nfixed\n", runtime.stdout());
}

pub fn testMissingTopLevelModuleUsesModuleNotFoundError() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectException(&runtime, "import absent_peony_module\n", .module_not_found_error);
}

pub fn testMissingModuleMemberUsesImportError() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/present.py", "value = 1\n");
    try expectException(&runtime, "from present import absent\n", .import_error);
}

pub fn testMissingPackageMemberUsesImportError() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.mountCourseFile("/course/present_package/__init__.py", "value = 1\n");
    try expectException(&runtime, "from present_package import absent\n", .import_error);
}

pub fn testRelativeImportOutsidePackageUsesImportError() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectException(&runtime, "from . import sibling\n", .import_error);
}

pub fn testStarImportsHonorVisibilityAndTupleAll() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/public_names.py", "public = 3\n_private = 4\n");
    try runtime.writeVfsFile("/home/tuple_all.py", "__all__ = ('_private',)\n_private = 9\n");
    try runToCompletion(&runtime,
        \\from public_names import *
        \\try:
        \\    print(_private)
        \\except NameError:
        \\    print("private skipped")
        \\from tuple_all import *
        \\print(public, _private)
    , "star-imports.py", 1);
    try std.testing.expectEqualStrings("private skipped\n3 9\n", runtime.stdout());
}

pub fn testPackageAllLoadsUninitializedChildThroughScheduledFrame() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.mountCourseFile("/course/star_pkg/__init__.py", "__all__ = ['child']\n");
    try runtime.mountCourseFile("/course/star_pkg/child.py", "answer = input('Child: ')\n");
    try expectReady(&runtime, runtime.compileAndStart("from star_pkg import *\nprint(child.answer)\n", "star-child.py"));

    var status = runtime_vm.RunStatus.timeslice;
    for (0..20_000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, status);
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingStarChildInputRequest;
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = "42" }};
    var response = host.DecodedPacket{
        .kind = .input,
        .request_id = request_id,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&response));
    try runUntilComplete(&runtime, 1);
    try std.testing.expectEqualStrings("Child: 42\n", runtime.stdout());
}

pub fn testStarImportMissingListedNameRaisesAttributeError() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.mountCourseFile("/course/missing_all/__init__.py", "__all__ = ['missing']\n");
    try expectException(&runtime, "from missing_all import *\n", .attribute_error);
}

pub fn testMainMetadataIsInitializedWithoutImportStatements() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 64 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runToCompletion(&runtime,
        \\if __name__ == "__main__":
        \\    print(__name__, __package__, __file__)
    , "plain-main.py", 1);
    try std.testing.expectEqualStrings("__main__  plain-main.py\n", runtime.stdout());

    runtime.reset();
    try runToCompletion(&runtime,
        \\if __name__ == "__main__":
        \\    print(__name__, __package__, __file__)
    , "plain-reuse.py", 1);
    try std.testing.expectEqualStrings("__main__  plain-reuse.py\n", runtime.stdout());
}

pub fn testMainMetadataAllocationFailureIsReportedAndRecoverable() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    const baseline = runtime.session_allocator.live_bytes;
    runtime.session_allocator.max_bytes = baseline + 2 * 1024;

    const outcome = runtime.compileAndStart("", "low-cap-main.py");
    switch (outcome) {
        .ready => return error.MainModuleSetupMemoryErrorWasReportedReady,
        .python_exception => |exception| try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, exception.kind),
        .syntax_error, .unsupported => return error.ExpectedMemoryErrorWhileInitializingMainModule,
    }
    try std.testing.expect(runtime.top_frame != null);
    const status = runtime.run(1);
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, status);
    try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, runtime.pythonException().?.kind);

    runtime.session_allocator.max_bytes = 8 * 1024 * 1024;
    runtime.reset();
    try runToCompletion(&runtime, "print('recovered')\n", "recovered-main.py", 1);
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testDottedRelativeFromImportInitializesIntermediatePackages() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.mountCourseFile("/course/relative_pkg/__init__.py", "print('package init')\nfrom .sub.mod import value\n");
    try runtime.mountCourseFile("/course/relative_pkg/sub/__init__.py", "print('sub init')\nready = 'sub'\n");
    try runtime.mountCourseFile("/course/relative_pkg/sub/mod.py", "print('module init')\nvalue = 8\n");
    try runToCompletion(&runtime,
        \\import relative_pkg
        \\print(relative_pkg.sub.ready, relative_pkg.sub.mod.value, relative_pkg.value)
    , "relative-prefixes.py", 1);
    try std.testing.expectEqualStrings("package init\nsub init\nmodule init\nsub 8 8\n", runtime.stdout());
}

pub fn testCannotImportChildOfSelectedModule() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/pkgmod.py", "value = 'module'\n");
    try runtime.mountCourseFile("/course/pkgmod/__init__.py", "value = 'package'\n");
    try runtime.mountCourseFile("/course/pkgmod/child.py", "value = 'wrong parent'\n");
    try expectException(&runtime, "import pkgmod.child\n", .module_not_found_error);
}

pub fn testImportedModuleRunsOnMainFrameAndSuspendsForInput() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/ask.py", "name = input('Name: ')\nprint('module', name)\n");
    try expectReady(&runtime, runtime.compileAndStart("import ask\nprint('main done')\n", "import-input-main.py"));

    var status = runtime_vm.RunStatus.timeslice;
    for (0..20_000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, status);
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingImportInputRequest;
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
    try runUntilComplete(&runtime, 1);
    try std.testing.expectEqualStrings("Name: module Ada\nmain done\n", runtime.stdout());
}

pub fn testImportCacheResetsAndHomeModulesPersistWithoutRetention() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runtime.writeVfsFile("/home/reloadable.py", "print('module body')\nvalue = 42\n");
    const baseline_objects = runtime.heap.object_count;

    try runToCompletion(&runtime, "import reloadable\nprint(reloadable.value)\n", "reload-first.py", 1);
    try std.testing.expectEqualStrings("module body\n42\n", runtime.stdout());
    runtime.reset();
    try std.testing.expectEqual(baseline_objects, runtime.heap.object_count);

    try runToCompletion(&runtime, "import reloadable\nprint(reloadable.value)\n", "reload-second.py", 1);
    try std.testing.expectEqualStrings("module body\n42\n", runtime.stdout());
    try std.testing.expect(runtime.heap.collection_count > 0);
}

fn runToCompletion(runtime: *runtime_vm.Runtime, source: []const u8, filename: []const u8, quantum: u32) !void {
    try expectReady(runtime, runtime.compileAndStart(source, filename));
    try runUntilComplete(runtime, quantum);
}

fn expectReady(_: *runtime_vm.Runtime, outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("unexpected import syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableImportProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("unexpected import unsupported feature at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableImportProgram;
        },
        .python_exception => |exception| {
            std.debug.print("unexpected import compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableImportProgram;
        },
    }
}

fn runUntilComplete(runtime: *runtime_vm.Runtime, quantum: u32) !void {
    var status = runtime.run(quantum);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(quantum);
    if (status != .completed) std.debug.print("import status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}

fn expectException(runtime: *runtime_vm.Runtime, source: []const u8, kind: exceptions.PythonExceptionKind) !void {
    try expectReady(runtime, runtime.compileAndStart(source, "import-error.py"));
    const status = runtime.run(10_000);
    if (status != .python_exception) std.debug.print("expected Python import exception, got {s} for {s}: {s}\n", .{ @tagName(status), source, runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, status);
    const actual = runtime.pythonException().?.kind;
    if (actual != kind) std.debug.print("expected import exception {s}, got {s} for {s}: {s}\n", .{ @tagName(kind), @tagName(actual), source, runtime.errorText() });
    try std.testing.expectEqual(kind, actual);
}
