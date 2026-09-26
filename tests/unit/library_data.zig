const std = @import("std");
const vm = @import("runtime_vm");
const host = @import("runtime_host");

pub fn testNativeJsonValueAdapter() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;

    const source = "{\"text\":\"\\u96ea\",\"big\":123456789012345678901234567890,\"a\":1,\"a\":2}";
    const parsed = vm.JsonValues.parseUtf8Detailed(vm.Runtime, &runtime, source, 1, 1);
    const value = switch (parsed) {
        .value => |selected| selected,
        .decode_error => |diagnostic| {
            std.debug.print("unexpected native JSON decode error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedNativeJsonValue;
        },
        .python_exception => |exception| {
            std.debug.print("unexpected native JSON exception: {s}\n", .{exception.message});
            return error.ExpectedNativeJsonValue;
        },
        .engine_error => return error.ExpectedNativeJsonValue,
    };
    const encoded_result = vm.JsonValues.serializeUtf8(vm.Runtime, &runtime, value, .{
        .sort_keys = true,
        .ensure_ascii = true,
        .item_separator = ",",
        .key_separator = ":",
    }, 1, 1);
    const encoded = switch (encoded_result) {
        .value => |bytes| bytes,
        .python_exception => |exception| {
            std.debug.print("unexpected native JSON encode exception: {s}\n", .{exception.message});
            return error.ExpectedNativeJsonText;
        },
        .engine_error => return error.ExpectedNativeJsonText,
    };
    defer runtime.heap.allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"a\":2,\"big\":123456789012345678901234567890,\"text\":\"\\u96ea\"}", encoded);
    try std.testing.expect(runtime.heap.collection_count > 0);

    const malformed = vm.JsonValues.parseUtf8Detailed(vm.Runtime, &runtime, "{\n\"x\":}", 1, 1);
    switch (malformed) {
        .decode_error => |diagnostic| {
            try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
            try std.testing.expect(diagnostic.column >= 5);
            try std.testing.expect(diagnostic.pos >= 6);
        },
        else => return error.ExpectedNativeJsonDecodeError,
    }

    const baseline = runtime.session_allocator.live_bytes;
    runtime.session_allocator.max_bytes = baseline + 8;
    const capped = vm.JsonValues.parseUtf8Detailed(vm.Runtime, &runtime, "\"a string longer than the remaining session budget\"", 1, 1);
    switch (capped) {
        .python_exception => |exception| try std.testing.expectEqual(vm.PythonExceptionKind.memory_error, exception.kind),
        else => return error.ExpectedNativeJsonMemoryError,
    }
}

pub fn testJsonLoadsDumpsAndOptions() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import json, math
        \\doc = '{"n":123456789012345678901234567890,"text":"\\u96ea \\ud834\\udd1e","same":1,"same":2}'
        \\value = json.loads(doc)
        \\print(value["n"], value["text"], value["same"])
        \\print(json.loads(doc.encode("utf-8")) == value)
        \\print(json.dumps({"b": [True, None, 1], "a": "雪"}, sort_keys=True, ensure_ascii=True, separators=(",", ":")))
        \\print(json.dumps({"snow": "雪"}, ensure_ascii=False))
        \\pretty = json.dumps({"a": [1, 2]}, indent=2)
        \\print("\n" in pretty, pretty.startswith("{"), pretty.endswith("}"))
        \\tabbed = json.dumps({"a": 1}, indent="\t")
        \\print("\n\t\"a\"" in tabbed)
        \\print(json.dumps([math.nan, math.inf, -math.inf]))
        \\parsed = json.loads('[NaN, Infinity, -Infinity]')
        \\print(math.isnan(parsed[0]), parsed[1] == math.inf, parsed[2] == -math.inf)
        \\print(json.loads(json.dumps({1: "one", None: "none"})))
    , "library-data-json.py", 1);
    try std.testing.expectEqualStrings(
        "123456789012345678901234567890 雪 𝄞 2\nTrue\n{\"a\":\"\\u96ea\",\"b\":[true,null,1]}\n{\"snow\": \"雪\"}\nTrue True True\nTrue\n[NaN, Infinity, -Infinity]\nTrue True True\n{'1': 'one', 'null': 'none'}\n",
        runtime.stdout(),
    );
}

pub fn testJsonErrorsMetadataAndCycles() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import json
        \\for text in ['{"a":}', '"\\ud800"']:
        \\    try:
        \\        json.loads(text)
        \\    except json.JSONDecodeError as error:
        \\        print(isinstance(error, ValueError), error.doc == text, error.pos >= 0, error.lineno >= 1, error.colno >= 1, len(error.msg) > 0)
        \\cycle = []
        \\cycle.append(cycle)
        \\try:
        \\    json.dumps(cycle)
        \\except ValueError:
        \\    print("cycle")
        \\try:
        \\    json.dumps(float("nan"), allow_nan=False)
        \\except ValueError:
        \\    print("nan")
        \\try:
        \\    json.loads(b"\xff")
        \\except UnicodeDecodeError:
        \\    print("utf8")
        \\try:
        \\    json.loads("{}", object_hook=lambda value: value)
        \\except (TypeError, NotImplementedError):
        \\    print("hook")
        \\try:
        \\    json.dumps({1, 2})
        \\except TypeError:
        \\    print("type")
    , "library-data-json-errors.py", 1);
    try std.testing.expectEqualStrings(
        "True True True True True True\nTrue True True True True True\ncycle\nnan\nutf8\nhook\ntype\n",
        runtime.stdout(),
    );
}

pub fn testJsonFileLikeCallbacks() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import json
        \\class Reader:
        \\    def __init__(self, value):
        \\        self.value = value
        \\        self.calls = 0
        \\    def read(self):
        \\        self.calls += 1
        \\        return self.value
        \\class Writer:
        \\    def __init__(self):
        \\        self.parts = []
        \\    def write(self, text):
        \\        self.parts.append(text)
        \\        return len(text)
        \\reader = Reader('{"answer": 42}')
        \\print(json.load(reader)["answer"], reader.calls)
        \\writer = Writer()
        \\print(json.dump({"answer": 42}, writer, sort_keys=True))
        \\print(type(writer.parts[0]) is str, writer.parts[0] == '{"answer": 42}')
        \\print("".join(writer.parts))
    , "library-data-json-file.py", 1);
    try std.testing.expectEqualStrings("42 1\nNone\nTrue True\n{\"answer\": 42}\n", runtime.stdout());
}

pub fn testCsvReaderWriterAndUnicode() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import csv
        \\rows = csv.reader(['a,"b\n', 'c",d\r\n', '1,2\r\n'])
        \\print(next(rows), rows.line_num)
        \\print(next(rows), rows.line_num)
        \\print(list(csv.reader(['雪§花\n'], delimiter='§')))
        \\print(list(csv.reader(['1,2.5,"3"\n'], quoting=csv.QUOTE_NONNUMERIC)))
        \\class Sink:
        \\    def __init__(self):
        \\        self.parts = []
        \\    def write(self, text):
        \\        self.parts.append(text)
        \\        return len(text)
        \\sink = Sink()
        \\writer = csv.writer(sink, lineterminator='\n')
        \\print(writer.writerow(['a', 'b,c', 'x"y']))
        \\print("".join(sink.parts), end='')
        \\all_sink = Sink()
        \\csv.writer(all_sink, quoting=csv.QUOTE_ALL, lineterminator='\n').writerows([[1, None], ['雪', '']])
        \\print("".join(all_sink.parts), end='')
        \\with open('/home/roundtrip.csv', 'w', newline='') as file:
        \\    csv.writer(file, lineterminator='\n').writerow(['a', 'b\nc'])
        \\with open('/home/roundtrip.csv', newline='') as file:
        \\    print(list(csv.reader(file)))
        \\print(issubclass(csv.Error, Exception))
    , "library-data-csv.py", 1);
    try std.testing.expectEqualStrings(
        "['a', 'b\\nc', 'd'] 2\n['1', '2'] 3\n[['雪', '花']]\n[[1.0, 2.5, '3']]\n15\na,\"b,c\",\"x\"\"y\"\n\"1\",\"\"\n\"雪\",\"\"\n[['a', 'b\\nc']]\nTrue\n",
        runtime.stdout(),
    );
}

pub fn testCsvDictionaryVariantsAndErrors() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import csv
        \\reader = csv.DictReader(['a,b\n', '1,2,3\n', '4\n'], restkey='extra', restval='missing')
        \\print(reader.fieldnames)
        \\first = next(reader)
        \\print(reader.fieldnames, first)
        \\print(next(reader))
        \\def names():
        \\    print('fieldnames once')
        \\    yield 'left'
        \\    yield 'right'
        \\explicit = csv.DictReader(['7,8\n'], fieldnames=names())
        \\print(next(explicit))
        \\class Sink:
        \\    def __init__(self): self.parts = []
        \\    def write(self, text):
        \\        self.parts.append(text)
        \\        return len(text)
        \\sink = Sink()
        \\writer = csv.DictWriter(sink, fieldnames=['a', 'b'], restval='R', extrasaction='ignore', lineterminator='\n')
        \\print(writer.fieldnames, writer.writeheader())
        \\writer.writerows([{'a': 1, 'extra': 9}, {'b': 2}])
        \\print("".join(sink.parts), end='')
        \\try:
        \\    csv.DictWriter(Sink(), fieldnames=['a'], extrasaction='raise').writerow({'a': 1, 'x': 2})
        \\except ValueError:
        \\    print("extras")
        \\for make in [lambda: csv.reader([], delimiter='ab'), lambda: csv.reader([], quotechar=''), lambda: csv.writer(Sink(), quoting=99)]:
        \\    try:
        \\        make()
        \\    except (TypeError, csv.Error):
        \\        print("dialect")
    , "library-data-csv-dict.py", 1);
    try std.testing.expectEqualStrings(
        "None\n['a', 'b'] {'a': '1', 'b': '2', 'extra': ['3']}\n{'a': '4', 'b': 'missing'}\nfieldnames once\n{'left': '7', 'right': '8'}\n['a', 'b'] 4\na,b\n1,R\nR,2\nextras\ndialect\ndialect\ndialect\n",
        runtime.stdout(),
    );
}

pub fn testDataCallbacksResumeInputOnce() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import json, csv
        \\class JsonReader:
        \\    def read(self):
        \\        return input("JSON: ")
        \\print(json.load(JsonReader())["value"])
        \\class Lines:
        \\    def __init__(self): self.done = False
        \\    def __iter__(self): return self
        \\    def __next__(self):
        \\        if self.done: raise StopIteration
        \\        self.done = True
        \\        return input("CSV: ")
        \\print(next(csv.reader(Lines())))
    );
    try resumeInput(&runtime, "{\"value\": 7}");
    try resumeInput(&runtime, "a,b\n");
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("JSON: 7\nCSV: ['a', 'b']\n", runtime.stdout());
}

pub fn testDataGcCapAndReset() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 3 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runScript(&runtime,
        \\import json, csv
        \\data = [{"i": i, "text": "雪" * 4} for i in range(1000)]
        \\encoded = json.dumps(data)
        \\print(len(json.loads(encoded)), len(list(csv.reader(["a,b\n"] * 1000))))
    , "library-data-gc.py", 1);
    try std.testing.expectEqualStrings("1000 1000\n", runtime.stdout());
    try std.testing.expect(runtime.heap.collection_count > 0);
    runtime.reset();
    try runScript(&runtime, "import json\nprint(json.loads('{\"ok\": true}')[\"ok\"])\n", "library-data-reset.py", 1);
    try std.testing.expectEqualStrings("True\n", runtime.stdout());
}

pub fn testJsonLargeQuantumAndCancellation() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import json
        \\doc = '[' + ('"snow",' * 24000) + '"end"]'
        \\value = json.loads(doc)
        \\encoded = json.dumps(value, separators=(',', ':'))
        \\print(len(value), len(encoded), encoded.startswith('["snow"'), encoded.endswith('"end"]'))
        \\giant = 'x' * 262145
        \\try:
        \\    json.loads('"' + giant + '"')
        \\except json.JSONDecodeError:
        \\    print('decode token limit')
        \\try:
        \\    json.dumps(giant)
        \\except ValueError:
        \\    print('encode token limit')
    , "library-data-json-large.py", 1);
    try std.testing.expectEqualStrings("24001 168007 True True\ndecode token limit\nencode token limit\n", runtime.stdout());

    runtime.reset();
    try ready(&runtime,
        \\import json
        \\doc = '[' + ('"snow",' * 24000) + '"end"]'
        \\json.loads(doc)
        \\print('late parse')
    );
    try waitForJsonTask(&runtime);
    runtime.cancel();
    try std.testing.expectEqual(vm.RunStatus.cancelled, runtime.run(1));
    try std.testing.expect(runtime.currentNativeTask() == null);

    runtime.reset();
    try ready(&runtime,
        \\import json
        \\value = ['snow' for _ in range(24000)]
        \\json.dumps(value)
        \\print('late dump')
    );
    try waitForJsonTask(&runtime);
    runtime.cancel();
    try std.testing.expectEqual(vm.RunStatus.cancelled, runtime.run(1));
    try std.testing.expect(runtime.currentNativeTask() == null);

    runtime.reset();
    try runScript(&runtime, "import json\nprint(json.loads('[1,2]'))\n", "library-data-json-after-cancel.py", 1);
    try std.testing.expectEqualStrings("[1, 2]\n", runtime.stdout());
}

fn waitForJsonTask(runtime: *vm.Runtime) !void {
    for (0..400_000) |_| {
        const status = runtime.run(1);
        if (status != .timeslice) return error.ExpectedPendingJsonTask;
        if (runtime.currentNativeTask()) |task| if (task.owner == .json) return;
    }
    return error.ExpectedPendingJsonTask;
}

fn ready(runtime: *vm.Runtime, source: []const u8) !void {
    switch (runtime.compileAndStart(source, "library-data-callback.py")) {
        .ready => {},
        else => return error.ExpectedExecutableDataProgram,
    }
}

fn boundary(runtime: *vm.Runtime, quantum: u32) !vm.RunStatus {
    var status = vm.RunStatus.timeslice;
    for (0..200_000) |_| {
        status = runtime.run(quantum);
        if (status != .timeslice) return status;
    }
    return error.NoDataExecutionBoundary;
}

fn resumeInput(runtime: *vm.Runtime, text: []const u8) !void {
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(runtime, 1));
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingDataInputRequest;
    var sections = [_]host.Section{.{ .kind = .utf8, .bytes = text }};
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

fn runScript(runtime: *vm.Runtime, source: []const u8, filename: []const u8, quantum: u32) !void {
    switch (runtime.compileAndStart(source, filename)) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("data syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableDataProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("data unsupported at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableDataProgram;
        },
        .python_exception => |exception| {
            std.debug.print("data compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableDataProgram;
        },
    }
    const status = try boundary(runtime, quantum);
    if (status != .completed) std.debug.print("data status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(vm.RunStatus.completed, status);
}
