const std = @import("std");
const runtime_vm = @import("runtime_vm");

pub fn testLiteralSingletonOrCaptureGuardAndSubjectOnce() !void {
    try expectOutput(
        \\events = []
        \\def subject():
        \\    events.append("subject")
        \\    return 3
        \\def guard(value):
        \\    events.append("guard")
        \\    return value == 3
        \\match subject():
        \\    case 1:
        \\        events.append("literal")
        \\    case 2 | 3:
        \\        events.append("or")
        \\    case _:
        \\        events.append("wildcard")
        \\match subject():
        \\    case value if guard(value):
        \\        events.append("capture")
        \\    case _:
        \\        events.append("guard-fallthrough")
        \\match False:
        \\    case True:
        \\        events.append("true")
        \\    case False:
        \\        events.append("false")
        \\match 5:
        \\    case value if guard(0):
        \\        events.append("bad-guard")
        \\    case 5:
        \\        events.append("fallthrough")
        \\match = 8
        \\case = 9
        \\_ = 10
        \\print(events, match, case, _)
    , "['subject', 'or', 'subject', 'guard', 'capture', 'false', 'guard', 'fallthrough'] 8 9 10\n");
}

pub fn testSingletonPatternsUseIdentity() !void {
    try expectOutput(
        \\match 1:
        \\    case True:
        \\        print("wrong true")
        \\    case _:
        \\        print("integer one")
        \\match 0:
        \\    case False:
        \\        print("wrong false")
        \\    case _:
        \\        print("integer zero")
        \\match True:
        \\    case 1:
        \\        print("numeric literal equality")
    , "integer one\ninteger zero\nnumeric literal equality\n");
}

pub fn testInvalidMatchCapturesAndIrrefutableCaseDiagnostics() !void {
    try expectSyntaxErrorContaining(
        "match 1:\n    case value:\n        pass\n    case 1:\n        pass\n",
        "unreachable",
    );
    try expectSyntaxErrorContaining(
        "match 1:\n    case value | other:\n        pass\n",
        "bind different names",
    );
}

pub fn testSignedNumericPatterns() !void {
    try expectOutput(
        \\match 0:
        \\    case -1:
        \\        print("wrong integer")
        \\    case -1.5:
        \\        print("wrong float")
        \\    case _:
        \\        print("zero")
        \\match -1:
        \\    case -1:
        \\        print("negative integer")
        \\match -1.5:
        \\    case -1.5:
        \\        print("negative float")
    , "zero\nnegative integer\nnegative float\n");
}

pub fn testIrrefutableOrAlternativesHaveSyntaxDiagnostics() !void {
    try expectSyntaxErrorContaining(
        "match 1:\n    case x | x:\n        pass\n",
        "unreachable",
    );
    try expectSyntaxErrorContaining(
        "match 1:\n    case _ | _:\n        pass\n",
        "unreachable",
    );
}

pub fn testExcludedPatternFormsHaveSpecificDiagnostics() !void {
    try expectUnsupportedContaining("match 1:\n    case [value]:\n        pass\n", "sequence pattern");
    try expectUnsupportedContaining("match 1:\n    case (left, right):\n        pass\n", "sequence pattern");
    try expectUnsupportedContaining("match {}:\n    case {\"value\": value}:\n        pass\n", "mapping pattern");
    try expectUnsupportedContaining("match value:\n    case Point(x):\n        pass\n", "class pattern");
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "match.py")) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("match syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableMatchProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("match unsupported at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableMatchProgram;
        },
        .python_exception => |exception| {
            std.debug.print("match compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableMatchProgram;
        },
    }
    var status = runtime.run(10_000);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 10_000) : (resumes += 1) status = runtime.run(10_000);
    if (status != .completed) std.debug.print("match status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectSyntaxErrorContaining(source: []const u8, expected_fragment: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "invalid-match.py")) {
        .syntax_error => |diagnostic| try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, expected_fragment) != null),
        else => return error.ExpectedMatchSyntaxError,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

fn expectUnsupportedContaining(source: []const u8, expected_fragment: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "unsupported-pattern.py")) {
        .unsupported => |diagnostic| try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, expected_fragment) != null),
        .syntax_error => |diagnostic| {
            std.debug.print("pattern syntax diagnostic: {s}\n", .{diagnostic.message});
            return error.ExpectedSpecificPatternUnsupportedDiagnostic;
        },
        else => return error.ExpectedSpecificPatternUnsupportedDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}
