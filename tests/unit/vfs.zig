const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testHomeSurvivesResetAndTemporaryFilesClear() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    try runToCompletion(&runtime,
        \\with open("/home/a/../notes.txt", "w") as handle:
        \\    handle.write("saved")
        \\with open("/tmp/only-this-run.txt", "w") as handle:
        \\    handle.write("temporary")
    , "vfs-first-run.py");

    runtime.reset();
    try runToCompletion(&runtime,
        \\with open("/home/notes.txt") as handle:
        \\    print(handle.read())
        \\try:
        \\    open("/tmp/only-this-run.txt").read()
        \\except FileNotFoundError:
        \\    print("tmp cleared")
    , "vfs-after-reset.py");
    try std.testing.expectEqualStrings("saved\ntmp cleared\n", runtime.stdout());
}

pub fn testVfsPathsAreCaseSensitiveAndSessionLocal() !void {
    var first: runtime_vm.Runtime = undefined;
    try first.init(std.testing.allocator, 8 * 1024 * 1024);
    defer first.deinit();
    try runToCompletion(&first,
        \\with open("/home/Case.txt", "w") as handle:
        \\    handle.write("first")
        \\print(open("/home/./Case.txt").read())
        \\try:
        \\    open("/home/case.txt")
        \\except FileNotFoundError:
        \\    print("case-sensitive")
    , "vfs-case.py");
    try std.testing.expectEqualStrings("first\ncase-sensitive\n", first.stdout());

    var second: runtime_vm.Runtime = undefined;
    try second.init(std.testing.allocator, 8 * 1024 * 1024);
    defer second.deinit();
    try expectException(&second, "open('/home/Case.txt')\n", .file_not_found_error);
}

pub fn testVfsRejectsTraversalAndMissingParentsWithoutMutation() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runToCompletion(&runtime,
        \\with open("/home/safe.txt", "w") as handle:
        \\    handle.write("unchanged")
        \\try:
        \\    open("/../../home/safe.txt", "w")
        \\except ValueError:
        \\    print("escape rejected")
        \\try:
        \\    open("/home/missing/child.txt", "w")
        \\except FileNotFoundError:
        \\    print("parent required")
        \\print(open("/home/safe.txt").read())
    , "vfs-path-errors.py");
    try std.testing.expectEqualStrings("escape rejected\nparent required\nunchanged\n", runtime.stdout());
}

pub fn testNestedAssetMountCreatesEveryParentDirectory() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.mountAssetFile("/assets/unit/sample.txt", "sample");
    const files = try runtime.listVfsFiles("/assets/unit");
    try std.testing.expectEqualStrings("/assets/unit/sample.txt\x00", files);
}

pub fn testHomeSurvivesNewProgramWhileTemporaryFilesClear() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runToCompletion(&runtime,
        \\with open("/home/kept.txt", "w") as handle:
        \\    handle.write("persistent")
        \\with open("/tmp/gone.txt", "w") as handle:
        \\    handle.write("temporary")
    , "vfs-run-1.py");
    try runToCompletion(&runtime,
        \\print(open("/home/kept.txt").read())
        \\try:
        \\    open("/tmp/gone.txt")
        \\except FileNotFoundError:
        \\    print("cleared")
    , "vfs-run-2.py");
    try std.testing.expectEqualStrings("persistent\ncleared\n", runtime.stdout());
}

pub fn testVfsCapacityFailureIsAtomicAndRecovers() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 32 * 1024 * 1024);
    defer runtime.deinit();
    const chunk = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'a');
    for (0..4) |index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/home/chunk-{d}.bin", .{index});
        defer std.testing.allocator.free(path);
        try runtime.writeVfsFile(path, chunk);
    }
    try std.testing.expectError(error.TooLarge, runtime.writeVfsFile("/home/overflow.bin", "x"));
    const preserved = try runtime.readVfsFile("/home/chunk-0.bin");
    try std.testing.expectEqual(chunk.len, preserved.len);
    try std.testing.expectEqual(@as(u8, 'a'), preserved[0]);
}

pub fn testVfsReadReturnsBorrowedContentWithoutSessionDuplication() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    const content = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(content);
    @memset(content, 0x61);
    try runtime.writeVfsFile("/home/borrowed.bin", content);
    const bytes_before_read = runtime.session_allocator.live_bytes;
    const read = try runtime.readVfsFile("/home/borrowed.bin");
    try std.testing.expectEqual(content.len, read.len);
    try std.testing.expectEqual(bytes_before_read, runtime.session_allocator.live_bytes);
}

pub fn testPythonFileWriteInvalidatesBorrowedVfsRead() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/live.txt", "old");
    switch (runtime.compileAndStart(
        \\with open("/home/live.txt", "w") as file:
        \\    file.write("new")
    , "vfs-borrow-invalidated.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    const borrowed = try runtime.readVfsFile("/home/live.txt");
    try std.testing.expectEqualStrings("old", borrowed);
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
    try std.testing.expectEqual(@as(usize, 0), runtime.vfsData().len);
    const replacement = try runtime.readVfsFile("/home/live.txt");
    try std.testing.expectEqualStrings("new", replacement);
}

fn runToCompletion(runtime: *runtime_vm.Runtime, source: []const u8, filename: []const u8) !void {
    switch (runtime.compileAndStart(source, filename)) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    var status = runtime.run(10_000);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 10_000) : (resumes += 1) status = runtime.run(10_000);
    if (status != .completed) std.debug.print("VFS status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}

fn expectException(runtime: *runtime_vm.Runtime, source: []const u8, kind: exceptions.PythonExceptionKind) !void {
    switch (runtime.compileAndStart(source, "vfs-isolation.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
}
