const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");

pub fn testTextFileMethodsAndUniversalNewlines() !void {
    try expectOutput(
        \\with open("/home/lines.txt", "w", newline="") as output:
        \\    output.write("α\r\nβ\rγ\n")
        \\with open("/home/lines.txt", newline=None) as source:
        \\    print(source.readline(), end="")
        \\    print(source.readlines())
        \\with open("/home/lines.txt", newline="") as source:
        \\    print(list(source))
    , "α\n['β\\n', 'γ\\n']\n['α\\r\\n', 'β\\r', 'γ\\n']\n");
}

pub fn testBinaryFilesSeekTellAndTruncate() !void {
    try expectOutput(
        \\with open("/home/data.bin", "wb+") as file:
        \\    file.write(b"abc")
        \\    print(file.tell())
        \\    file.seek(1)
        \\    print(file.read(1))
        \\    file.seek(0)
        \\    file.truncate(2)
        \\    file.seek(0)
        \\    print(file.read())
    , "3\nb'b'\nb'ab'\n");
}

pub fn testBinaryReadAfterSeekPastEndPreservesPosition() !void {
    try expectOutput(
        \\with open("/home/past-end.bin", "wb+") as file:
        \\    file.write(b"x")
        \\    file.seek(10)
        \\    print(file.read())
        \\    print(file.tell())
        \\    file.seek(10)
        \\    print(file.readline())
        \\    print(file.tell())
    , "b''\n10\nb''\n10\n");
}

pub fn testOpenModeErrorsAndTextTellSeekCookie() !void {
    try expectOutput(
        \\with open("/home/modes.txt", "w") as file:
        \\    file.write("abc")
        \\with open("/home/modes.txt", "a+") as file:
        \\    print(file.read())
        \\    file.seek(0)
        \\    print(file.read())
        \\    file.seek(0)
        \\    file.write("d")
        \\    file.seek(0)
        \\    print(file.read())
        \\with open("/home/modes.txt", "r+") as file:
        \\    file.read(1)
        \\    file.write("X")
        \\    file.seek(0)
        \\    print(file.read())
        \\with open("/home/unicode.txt", "w") as file:
        \\    file.write("αβ")
        \\with open("/home/unicode.txt", "r+") as file:
        \\    print(file.read(1))
        \\    cookie = file.tell()
        \\    print(file.read(1))
        \\    file.seek(cookie)
        \\    print(file.read())
        \\try:
        \\    open("/home/modes.txt", "rr")
        \\except ValueError:
        \\    print("mode error")
        \\try:
        \\    open("/home/modes.txt", encoding="latin-1")
        \\except LookupError:
        \\    print("encoding error")
        \\try:
        \\    with open("/home/binary.dat", "wb") as file:
        \\        file.write("text")
        \\except TypeError:
        \\    print("binary type error")
    , "\nabc\nabcd\naXcd\nα\nβ\nβ\nmode error\nencoding error\nbinary type error\n");
}

pub fn testPreservedCrLfReadsRespectTextCharacterSize() !void {
    try expectOutput(
        \\with open("/home/crlf.txt", "w", newline="") as file:
        \\    file.write("a\r\nb")
        \\with open("/home/crlf.txt", newline="") as file:
        \\    print([file.read(1), file.read(1), file.read(2)])
    , "['a', '\\r', '\\nb']\n");
}

pub fn testReadlinesHintCountsTextCharacters() !void {
    try expectOutput(
        \\with open("/home/hinted.txt", "w") as file:
        \\    file.write("a\nbb\nc\n")
        \\with open("/home/hinted.txt") as file:
        \\    print(file.readlines(3))
    , "['a\\n', 'bb\\n']\n");
}

pub fn testWritelinesAcceptsGeneratorExpression() !void {
    try expectOutput(
        \\with open("/home/generated-lines.txt", "w") as file:
        \\    file.writelines((line for line in ["a\n", "b\n"]))
        \\with open("/home/generated-lines.txt") as file:
        \\    print(file.read(), end="")
    , "a\nb\n");
}

pub fn testWritelinesGeneratorResumesAtTinyQuantumWithoutReplay() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(
        \\with open("/home/tiny-lines.txt", "w") as file:
        \\    file.writelines((str(x) + "\n" for x in range(3)))
        \\with open("/home/tiny-lines.txt") as file:
        \\    print(file.read(), end="")
    , "tiny-writelines.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    var status = runtime.run(1);
    var steps: usize = 0;
    var timeslices: usize = 0;
    while (status == .timeslice and steps < 1000) : (steps += 1) {
        timeslices += 1;
        status = runtime.run(1);
    }
    if (status != .completed) std.debug.print("tiny writelines status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expect(timeslices > 0);
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings("0\n1\n2\n", runtime.stdout());
}

pub fn testWritelinesChargesLongSynchronousWorkAndRecovers() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(
        \\items = ["x\n"] * 200
        \\with open("/home/long-lines.txt", "w") as file:
        \\    print("before")
        \\    file.writelines(items)
        \\print("after")
    , "limited-writelines.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    var status = runtime.run(1);
    var steps: usize = 0;
    while (runtime.stdout().len == 0 and status == .timeslice and steps < 100) : (steps += 1) status = runtime.run(1);
    try std.testing.expectEqualStrings("before\n", runtime.stdout());
    runtime.max_instructions = runtime.workCount() + 10;
    status = runtime.run(1000);
    try std.testing.expectEqual(runtime_vm.RunStatus.limit, status);
    try std.testing.expect(runtime.workCount() <= runtime.max_instructions);
    const partial = try runtime.readVfsFile("/home/long-lines.txt");
    try std.testing.expect(partial.len > 0 and partial.len < 400);

    runtime.reset();
    runtime.max_instructions = 50_000_000;
    switch (runtime.compileAndStart("print('recovered')\n", "writelines-recovery.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, runtime.run(100));
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testFileModesContextAndClosedErrors() !void {
    try expectOutput(
        \\with open("/home/value.txt", "x") as file:
        \\    print(file.write("ok"))
        \\try:
        \\    open("/home/value.txt", "x")
        \\except FileExistsError:
        \\    print("exists")
        \\file = open("/home/value.txt")
        \\file.close()
        \\try:
        \\    file.read()
        \\except ValueError:
        \\    print("closed")
    , "2\nexists\nclosed\n");
    try expectException("open('/home/missing.txt')\n", .file_not_found_error);
    try expectException("open('/assets/sample.txt', 'w')\n", .permission_error);
}

pub fn testFileContextClosesDuringExceptionAndReturn() !void {
    try expectOutput(
        \\try:
        \\    with open("/home/context.txt", "w") as file:
        \\        file.write("before")
        \\        raise ValueError("stop")
        \\except ValueError:
        \\    print(file.closed)
        \\def finish():
        \\    with open("/home/return.txt", "w") as output:
        \\        output.write("returned")
        \\        return 7
        \\print(finish(), open("/home/return.txt").read())
    , "True\n7 returned\n");
}

pub fn testClosedTellRaisesValueError() !void {
    try expectException(
        \\file = open("/home/closed-tell.txt", "w")
        \\file.close()
        \\file.tell()
    , .value_error);
}

pub fn testGetattrAndHasattrExposeFileFields() !void {
    try expectOutput(
        \\file = open("/home/attribute-fields.txt", "w")
        \\print(getattr(file, "closed"), hasattr(file, "closed"))
        \\print(getattr(file, "name"), getattr(file, "mode"), getattr(file, "encoding"))
        \\print(hasattr(file, "name"), hasattr(file, "mode"), hasattr(file, "encoding"))
        \\file.close()
        \\print(getattr(file, "closed"))
    , "False True\n/home/attribute-fields.txt w UTF-8\nTrue True True\nTrue\n");
}

pub fn testInvalidTextReadReleasesPartialBufferAndAllowsReuse() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runtime.writeVfsFile("/home/invalid-utf8.txt", &.{ 'a', 'b', 0xff });
    const baseline = runtime.session_allocator.live_bytes;
    switch (runtime.compileAndStart("open('/home/invalid-utf8.txt').read()\n", "invalid-text.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.unicode_decode_error, runtime.pythonException().?.kind);
    runtime.reset();
    try std.testing.expectEqual(baseline, runtime.session_allocator.live_bytes);
    try expectRuntimeCompletes(&runtime, "print('reused')\n", "reused\n");
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "files.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    var status = runtime.run(10_000);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 10_000) : (resumes += 1) status = runtime.run(10_000);
    if (status != .completed) std.debug.print("file status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectException(source: []const u8, kind: exceptions.PythonExceptionKind) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "files.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(10_000));
    try std.testing.expectEqual(kind, runtime.pythonException().?.kind);
}

fn expectRuntimeCompletes(runtime: *runtime_vm.Runtime, source: []const u8, expected: []const u8) !void {
    switch (runtime.compileAndStart(source, "files-reuse.py")) {
        .ready => {},
        else => return error.ExpectedReadyProgram,
    }
    var status = runtime.run(10_000);
    while (status == .timeslice) status = runtime.run(10_000);
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}
