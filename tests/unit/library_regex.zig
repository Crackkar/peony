const std = @import("std");
const vm = @import("runtime_vm");
const host = @import("runtime_host");

fn compileRegexDraftGeneric(runtime: *vm.Runtime) bool {
    const Value = vm.NativeTypes.Value;
    const args = [_]Value{Value.noneValue()};
    return vm.RegexDraft.execute(vm.Runtime, runtime, 0, 10, Value.noneValue(), &args, &.{}, 1, 1);
}

fn ready(runtime: *vm.Runtime, source: []const u8) !void {
    switch (runtime.compileAndStart(source, "library-regex.py")) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("regex test syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedCompiledRegexProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("regex test unsupported syntax at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedCompiledRegexProgram;
        },
        .python_exception => |exception| {
            std.debug.print("regex test compile exception: {s}\n", .{exception.message});
            return error.ExpectedCompiledRegexProgram;
        },
    }
}

fn boundary(runtime: *vm.Runtime, quantum: u32) !vm.RunStatus {
    var status = vm.RunStatus.timeslice;
    for (0..200_000) |_| {
        status = runtime.run(quantum);
        if (status != .timeslice and status != .output_event) return status;
    }
    return error.NoRegexExecutionBoundary;
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime, source);
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("regex result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

pub fn testRegexSyntaxFlagsUnicodeAndBytes() !void {
    _ = &compileRegexDraftGeneric;
    const semantics = vm.RegexDraft.character_semantics;
    try std.testing.expect(semantics.has('9', .decimal));
    try std.testing.expect(!semantics.has('A', .decimal));
    try std.testing.expect(semantics.has('A', .alnum));
    try std.testing.expect(semantics.has(' ', .whitespace));
    try std.testing.expect(semantics.has('\t', .whitespace));
    try std.testing.expect(!semantics.has('_', .alnum));
    try std.testing.expect(semantics.has(0x0661, .decimal));
    try std.testing.expect(semantics.has(0x03b1, .alnum));
    try expectOutput(
        \\import re
        \\print(re.findall(r"a.+?c", "a12c a34c"))
        \\print(re.findall(r"^[a-c]{2,3}$", "ab\nabc\nabcd", re.M))
        \\print(bool(re.search(r"a.b", "a\nb", re.S)))
        \\print(bool(re.search("k", "\u212a", re.I)), bool(re.search("k", "\u212a", re.I | re.A)))
        \\print(re.findall(r"\d+", "x\u0661\u0662 34"), re.findall(r"\d+", "x\u0661\u0662 34", re.A))
        \\print(re.findall(rb"\w+", b"a_1 \xff"))
        \\print(re.A == re.ASCII, re.I == re.IGNORECASE, re.M == re.MULTILINE, re.S == re.DOTALL, re.U == re.UNICODE)
        \\print(bool(re.fullmatch(r"\D\W\s\S", "a \tx")), bool(re.search(r"\bword\b", " word ")), re.findall(r"[^a]+", "abca"), bool(re.fullmatch(r"a\+b", "a+b")), re.findall(r"a{2,3}?", "aaaaa"))
        \\for pattern in [r"(a)\1", r"(?=a)", r"(?!a)", r"(?<=a)b", r"(?>a)", r"(?i:a)", r"(?(1)a|b)"]:
        \\    try:
        \\        re.compile(pattern)
        \\    except re.error as problem:
        \\        print(type(problem) is re.error, isinstance(problem, ValueError), bool(problem.msg), problem.pattern is pattern, problem.pos >= 0)
        \\try:
        \\    re.compile(b"a", 4)
        \\except re.error as problem:
        \\    print(type(problem) is re.error, problem.pos == 0)
        \\try:
        \\    re.compile(b"a", re.U)
        \\except ValueError:
        \\    print("unicode bytes rejected")
        \\try:
        \\    re.search("a", b"a")
        \\except TypeError:
        \\    print("mixed rejected")
    ,
        "['a12c', 'a34c']\n['ab', 'abc']\nTrue\nTrue False\n['\u{0661}\u{0662}', '34'] ['34']\n[b'a_1']\n" ++
            "True True True True True\nTrue True ['bc'] True ['aa', 'aa']\n" ++
            "True True True True True\nTrue True True True True\nTrue True True True True\nTrue True True True True\n" ++
            "True True True True True\nTrue True True True True\nTrue True True True True\nTrue True\n" ++
            "unicode bytes rejected\nmixed rejected\n",
    );
}

pub fn testRegexOrderedCapturesObjectsAndPositions() !void {
    try expectOutput(
        \\import re
        \\print(re.search(r"a|ab", "ab").group(), re.search(r"ab|a", "ab").group())
        \\print(re.search(r"a.*b", "axxbxxb").group(), re.search(r"a.*?b", "axxbxxb").group())
        \\pattern = re.compile(r"(?P<word>\w+?)(?P<digits>\d+)", re.I)
        \\match = pattern.search("xxAb12yy", 2, 8)
        \\print(pattern.pattern, pattern.flags, pattern.groups, pattern.groupindex)
        \\print(match.group(0, 1, "digits"))
        \\print(match["digits"], match[True])
        \\print(match.groups("X"), match.groupdict("X"))
        \\print(match.start(1), match.end("digits"), match.span(), match.string, match.re is pattern)
        \\print(pattern.match("--Ab12", 2).group(), pattern.fullmatch("--Ab12", 2).group())
        \\print([item.span() for item in re.finditer(r"|a", "a")])
        \\print(re.findall(r"(a)|(b)", "ab"))
        \\print(re.findall(r"\B", ""))
        \\optional = re.match(r"(a)?b", "b")
        \\print(optional.group(1), optional.groups("missing"), optional.start(1), optional.span(1))
        \\print(optional.group(False), optional.group(True))
        \\try:
        \\    optional.group(2)
        \\except IndexError:
        \\    print("bad group")
        \\for abstract in [re.Pattern, re.Match]:
        \\    try:
        \\        abstract()
        \\    except TypeError:
        \\        print("abstract")
    ,
        "a ab\naxxbxxb axxb\n(?P<word>\\w+?)(?P<digits>\\d+) 34 2 {'word': 1, 'digits': 2}\n" ++
            "('Ab12', 'Ab', '12')\n12 Ab\n('Ab', '12') {'word': 'Ab', 'digits': '12'}\n" ++
            "2 6 (2, 6) xxAb12yy True\nAb12 Ab12\n[(0, 0), (0, 1), (1, 1)]\n" ++
            "[('a', ''), ('', 'b')]\n[]\nNone ('missing',) -1 (-1, -1)\nb None\nbad group\nabstract\nabstract\n",
    );
}

pub fn testRegexSplitSubTemplatesEscapeAndPatternMethods() !void {
    try expectOutput(
        \\import re
        \\pattern = re.compile(r"(?P<x>a)")
        \\print(re.split(r"(,)", "a,b,,c", maxsplit=2))
        \\print(pattern.sub(r"[\g<x>]-\1", "aba"))
        \\print(pattern.subn("X", "aba", count=1))
        \\print(pattern.findall("caba", 1, 3))
        \\print([item.span() for item in pattern.finditer("caba", 1, 4)])
        \\print(pattern.split("aba", maxsplit=1))
        \\print(pattern.sub("Z", "aba", count=1), pattern.subn("Z", "aba", count=1))
        \\print(re.escape("a.b-c_ /"))
        \\print(re.escape(pattern="a.b"))
        \\print(re.compile(pattern="a", flags=0).pattern, re.search(pattern="a", string="ba", flags=0).span(), bool(re.match(pattern="a", string="ab", flags=0)), bool(re.fullmatch(pattern="a", string="a", flags=0)))
        \\print(re.findall(pattern="a", string="aba", flags=0), [item.span() for item in re.finditer(pattern="a", string="aba", flags=0)])
        \\print(re.split(pattern="a", string="aba", maxsplit=1, flags=0), re.sub(pattern="a", repl="X", string="aba", count=1, flags=0), re.subn(pattern="a", repl="X", string="aba", count=1, flags=0))
        \\print(re.findall(r"(.)", "é中"), re.split(r"(é)", "aéb"), re.sub(r"(é)", r"<\1>", "aéb"))
        \\bytes_pattern = re.compile(rb"(?P<x>a)")
        \\print(bytes_pattern.sub(rb"<\g<x>>", b"aba"))
        \\try:
        \\    pattern.sub(b"x", "a")
        \\except TypeError:
        \\    print("replacement type")
        \\try:
        \\    pattern.sub(r"\g<missing>", "a")
        \\except (IndexError, re.error):
        \\    print("replacement group")
        \\try:
        \\    re.match("a", "a").group(groups=0)
        \\except TypeError:
        \\    print("match positional only")
        \\try:
        \\    re.match("a", "a").groups(default="x")
        \\except TypeError:
        \\    print("match positional only")
        \\try:
        \\    re.match("a", "a").groupdict(default="x")
        \\except TypeError:
        \\    print("match positional only")
        \\try:
        \\    re.match("a", "a").start(group=0)
        \\except TypeError:
        \\    print("match positional only")
        \\try:
        \\    re.match("a", "a").end(group=0)
        \\except TypeError:
        \\    print("match positional only")
        \\try:
        \\    re.match("a", "a").span(group=0)
        \\except TypeError:
        \\    print("match positional only")
    ,
        "['a', ',', 'b', ',', ',c']\n[a]-ab[a]-a\n('Xba', 1)\n['a']\n[(1, 2), (3, 4)]\n['', 'a', 'ba']\nZba ('Zba', 1)\n" ++
            "a\\.b\\-c_\\ /\na\\.b\na (1, 2) True True\n['a', 'a'] [(0, 1), (2, 3)]\n['', 'ba'] Xba ('Xba', 1)\n" ++
            "['é', '中'] ['a', 'é', 'b'] a<é>b\n" ++
            "b'<a>b<a>'\nreplacement type\nreplacement group\n" ++
            "match positional only\nmatch positional only\nmatch positional only\nmatch positional only\nmatch positional only\nmatch positional only\n",
    );
}

pub fn testRegexCallableReplacementResumesInputExactlyOnce() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import re
        \\calls = 0
        \\def replace(match):
        \\    global calls
        \\    calls += 1
        \\    return input("R: ") + match.group(0)
        \\print(re.sub(r"[ab]", replace, "ab"), calls)
    );

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("R: ", runtime.stdout());
    try resumeInput(&runtime, "X");
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("R: R: ", runtime.stdout());
    try resumeInput(&runtime, "Y");
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("regex callback result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("R: R: XaYb 2\n", runtime.stdout());
}

pub fn testRegexWorkLimitGcAndReset() !void {
    var config = host.Config.defaults();
    config.max_memory_bytes = 8 * 1024 * 1024;
    config.max_instructions = 600;
    config.quantum = 1;
    var limited: vm.Runtime = undefined;
    try limited.initWithConfig(std.testing.allocator, config);
    defer limited.deinit();
    const long_subject = try std.testing.allocator.alloc(u8, 4000);
    defer std.testing.allocator.free(long_subject);
    @memset(long_subject, 'a');
    const limited_source = try std.fmt.allocPrint(std.testing.allocator, "import re\nprint(bool(re.search(r\"(?:a|aa)*b\", \"{s}\")))\n", .{long_subject});
    defer std.testing.allocator.free(limited_source);
    try ready(&limited, limited_source);
    const limited_result = try boundary(&limited, 1);
    if (limited_result != .limit) std.debug.print("regex limit result={s}: {s}\n", .{ @tagName(limited_result), limited.errorText() });
    try std.testing.expectEqual(vm.RunStatus.limit, limited_result);
    try std.testing.expect(limited.work_executed <= config.max_instructions);

    var cancelled: vm.Runtime = undefined;
    try cancelled.init(std.testing.allocator, 8 * 1024 * 1024);
    defer cancelled.deinit();
    try ready(&cancelled, limited_source);
    for (0..10_000) |_| {
        const status = cancelled.run(1);
        if (cancelled.currentNativeTask() != null) break;
        try std.testing.expect(status == .timeslice or status == .output_event);
    }
    try std.testing.expect(cancelled.currentNativeTask() != null);
    cancelled.cancel();
    try std.testing.expectEqual(vm.RunStatus.cancelled, cancelled.run(1));
    try std.testing.expect(cancelled.currentNativeTask() == null);

    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try ready(&runtime, "import re\nprint(re.fullmatch(r'(ab){2,4}', 'ababab').group())\n");
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("ababab\n", runtime.stdout());
    runtime.reset();
    try ready(&runtime, "import re\nprint(re.search('x', 'xyz').span())\n");
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("(0, 1)\n", runtime.stdout());
    try std.testing.expect(runtime.heap.collection_count > 0);
}

fn resumeInput(runtime: *vm.Runtime, text: []const u8) !void {
    var request = try host.decode(std.testing.allocator, runtime.eventBytes());
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(host.Kind.input, request.kind);
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = text }};
    var response = host.DecodedPacket{
        .kind = .input,
        .request_id = request.request_id,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&response));
}
