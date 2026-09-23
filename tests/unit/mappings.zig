const std = @import("std");
const runtime_vm = @import("runtime_vm");
const exceptions = @import("runtime_exception");
const gc = @import("runtime_gc");
const dict_module = @import("runtime_dict");
const value_module = @import("runtime_value");
const string = @import("runtime_string");
const Value = value_module.Value;

pub fn testOrderedDictAndSetNumericKeys() !void {
    try expectOutput(
        \\mapping = {1: "a", True: "b", 1.0: "c"}
        \\print(len(mapping), mapping[1], mapping)
        \\mapping[2] = "d"
        \\mapping[1] = "e"
        \\del mapping[2]
        \\mapping[2] = "f"
        \\print(mapping, list(mapping), 2 in mapping)
        \\values = {1, True, 1.0, 2}
        \\print(len(values), 1 in values, 2 in values)
        \\print(hash(True) == hash(1), hash(1) == hash(1.0), hash(-0.0) == hash(0), hash(2 ** 100) == hash(2.0 ** 100))
    ,
        "1 c {1: 'c'}\n{1: 'e', 2: 'f'} [1, 2] True\n2 True True\nTrue True True True\n",
    );
}

pub fn testDictMethodsAndLiveViews() !void {
    try expectOutput(
        \\mapping = dict([("a", 1), ("b", 2)])
        \\keys = mapping.keys()
        \\mapping["c"] = 3
        \\print(list(keys))
        \\mapping["a"] = 9
        \\print(list(mapping.values()), list(mapping.items()))
        \\print(mapping.get("missing", 7), mapping.setdefault("d", 4), mapping.pop("b"), mapping)
        \\copy = mapping.copy()
        \\copy.update({"a": 5, "e": 6})
        \\print(copy, mapping)
        \\copy.clear()
        \\print(copy)
    ,
        "['a', 'b', 'c']\n[9, 2, 3] [('a', 9), ('b', 2), ('c', 3)]\n7 4 2 {'a': 9, 'c': 3, 'd': 4}\n{'a': 5, 'c': 3, 'd': 4, 'e': 6} {'a': 9, 'c': 3, 'd': 4}\n{}\n",
    );
    try expectRuntimeException(
        "mapping = {\"a\": 1}\nkeys = mapping.keys()\ncursor = iter(keys)\nnext(cursor)\nmapping[\"b\"] = 2\nnext(cursor)\n",
        "RuntimeError",
        "mapping.py:6:",
    );
    try expectOutputWithCollectionThreshold(
        "mapping = dict([(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8), (9, 9), (10, 10), (11, 11), (12, 12), (13, 13), (14, 14), (15, 15), (16, 16), (17, 17), (18, 18), (19, 19)])\nkeys = mapping.keys()\nfor key in range(15):\n    del mapping[key]\nmapping[20] = 20\nprint(list(keys))\n",
        "[15, 16, 17, 18, 19, 20]\n",
    );
    try expectOutput(
        "mapping = {\"a\": 1, \"b\": 2}\ncursor = iter(mapping.items())\nprint(next(cursor))\nmapping[\"b\"] = 9\nprint(next(cursor))\n",
        "('a', 1)\n('b', 9)\n",
    );
}

pub fn testMappingConstructorsDisplaysAndSetOperators() !void {
    try expectOutput(
        \\source = {"x": 1, "y": 2}
        \\print({**source, "x": 3, "z": 4})
        \\print(dict(**{"a": 1, "b": 2}))
        \\print(set([1, True, 2, 2]) == {1, 2}, len(set([1, True, 2, 2])))
        \\print(({1, 2} | {2, 3}) == {1, 2, 3}, ({1, 2} & {2, 3}) == {2}, ({1, 2} - {2}) == {1})
        \\print(dict() == {}, set() == set())
    ,
        "{'x': 3, 'y': 2, 'z': 4}\n{'a': 1, 'b': 2}\nTrue 2\nTrue True True\nTrue True\n",
    );
}

pub fn testSetMethodsAndMappingViewRepresentations() !void {
    try expectOutput(
        "values = set()\nvalues.add(1)\nvalues.update([2, 3], (3, 4))\nvalues.discard(99)\nvalues.remove(2)\nclone = values.copy()\npopped = {9}.pop()\nvalues.clear()\nprint(len(clone), 1 in clone, 4 in clone, popped, len(values))\nmapping = {\"a\": 1}\nprint(mapping.keys(), mapping.values(), mapping.items())\nmapping.update([(\"b\", 2)], c=3)\nprint(mapping)\n",
        "3 True True 9 0\ndict_keys(['a']) dict_values([1]) dict_items([('a', 1)])\n{'a': 1, 'b': 2, 'c': 3}\n",
    );
}

pub fn testMappingViewReprIsCycleSafe() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart("mapping = {}\nview = mapping.values()\nmapping[\"view\"] = view\nprint(view)\nprint(mapping)\n", "mapping-cycle.py"));
    runtime.session_allocator.max_bytes = runtime.session_allocator.live_bytes + 4096;
    const status = runtime.run(100_000);
    if (status != .completed) std.debug.print("mapping cycle repr status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings("dict_values([...])\n{'view': dict_values([...])}\n", runtime.stdout());
}

pub fn testMappingCollisionsSurviveTombstones() !void {
    try expectOutput(
        "mapping = {0: \"zero\", 2 ** 61 - 1: \"prime\", 3 * (2 ** 61 - 1): \"triple\"}\nprint(len(mapping), mapping[0], mapping[2 ** 61 - 1], mapping[3 * (2 ** 61 - 1)])\ndel mapping[0]\ndel mapping[2 ** 61 - 1]\nmapping[5 * (2 ** 61 - 1)] = \"five\"\nprint(len(mapping), mapping[3 * (2 ** 61 - 1)], mapping[5 * (2 ** 61 - 1)])\n",
        "3 zero prime triple\n2 triple five\n",
    );
}

pub fn testKeywordMappingsExpandInSourceOrder() !void {
    try expectOutput(
        \\def show(first, **keywords):
        \\    print(first, keywords)
        \\source = {"b": 2}
        \\show(1, **source)
        \\def mutate():
        \\    source["late"] = 9
        \\    return 3
        \\def collect(**keywords):
        \\    print(keywords)
        \\collect(**source, tail=mutate())
    ,
        "1 {'b': 2}\n{'b': 2, 'tail': 3}\n",
    );
}

pub fn testPositionalOnlyNameCanBeCapturedByKwargs() !void {
    try expectOutput(
        \\def show(value, /, **keywords):
        \\    print(value, keywords)
        \\show(1, value=2)
    ,
        "1 {'value': 2}\n",
    );
    try expectRuntimeException(
        "def show(value, /, **keywords):\n    print(value, keywords)\nshow(value=2)\n",
        "TypeError",
        "mapping.py:3:",
    );
}

pub fn testDstarErrorsFollowPythonEvaluationOrder() !void {
    try expectRuntimeExceptionOutput(
        "def collect(**keywords):\n    return keywords\ndef side():\n    print(\"side effect\")\n    return 1\ncollect(**{1: 2}, tail=side())\n",
        "side effect\n",
    );
    try expectRuntimeExceptionOutput(
        "def collect(**keywords):\n    return keywords\ndef side():\n    print(\"must not run\")\n    return 1\ncollect(**{\"x\": 1}, **{\"x\": 2}, y=side())\n",
        "",
    );
}

pub fn testHashingAndMappingErrors() !void {
    try expectOutput("print(hash(2 ** 100) == hash(2.0 ** 100))\n", "True\n");
    try expectOutput("print(hash(-1) == -2, hash(-2) < 0, hash(-(2 ** 100)) < 0, hash(-(2 ** 100)) == hash(-(2.0 ** 100)))\n", "True True True True\n");
    try expectOutput("print(hash((True, \"x\")) == hash((1, \"x\")))\nprint({\"a\": 1, \"b\": 2} == {\"b\": 2, \"a\": 1})\n", "True\nTrue\n");
    try expectOutput("mapping = {2 ** 100: \"big\"}\nprint(mapping[2.0 ** 100], hash(2 ** 100) == hash(2.0 ** 100))\n", "big True\n");
    try expectRuntimeException("mapping = {[]: 1}\n", "TypeError", "mapping.py:1:");
    try expectRuntimeException("values = {[1]}\n", "TypeError", "mapping.py:1:");
    try expectRuntimeException("mapping = {{1: 2}: 3}\n", "TypeError", "mapping.py:1:");
    try expectRuntimeException("print(hash({}))\n", "TypeError", "mapping.py:1:");
    try expectRuntimeException("mapping = {\"a\": 1}\nprint(mapping[\"b\"])\n", "KeyError", "mapping.py:2:");
    try expectRuntimeException("def collect(**values):\n    pass\ncollect(**{1: \"bad\"})\n", "TypeError", "mapping.py:3:");
    try expectRuntimeException("def collect(**values):\n    pass\ncollect(**{\"x\": 1}, **{\"x\": 2})\n", "TypeError", "mapping.py:3:");
}

pub fn testStringHashSeedVariesAcrossSessions() !void {
    var first: runtime_vm.Runtime = undefined;
    try first.init(std.testing.allocator, 1024 * 1024);
    defer first.deinit();
    var second: runtime_vm.Runtime = undefined;
    try second.init(std.testing.allocator, 1024 * 1024);
    defer second.deinit();
    try expectReady(first.compileAndStart("print(hash(\"peony fixed hash seed probe\"), hash(b\"peony fixed hash seed probe\"))\n", "mapping.py"));
    try expectReady(second.compileAndStart("print(hash(\"peony fixed hash seed probe\"), hash(b\"peony fixed hash seed probe\"))\n", "mapping.py"));
    try runToCompletion(&first, 1000);
    try runToCompletion(&second, 1000);
    try std.testing.expect(!std.mem.eql(u8, first.stdout(), second.stdout()));
}

pub fn testDictSetRootsObjectKeyAndValueAcrossGrowth() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    const created = dict_module.create(&runtime.heap, false);
    const mapping = switch (created) {
        .value => |dict| dict,
        else => return error.ExpectedMapping,
    };
    var mapping_root = gc.Root{ .object = &mapping.header };
    var root_frame = gc.RootFrame{};
    root_frame.push(&runtime.heap.roots);
    root_frame.add(&mapping_root);
    defer root_frame.pop();

    const created_key = string.create(&runtime.heap, "object key");
    const key = switch (created_key) {
        .value => |text| Value.object(&text.header),
        else => return error.ExpectedString,
    };
    const created_value = string.create(&runtime.heap, "object value");
    const stored_value = switch (created_value) {
        .value => |text| Value.object(&text.header),
        else => return error.ExpectedString,
    };
    const original_threshold = runtime.heap.collection_threshold;
    runtime.heap.collection_threshold = 1;
    defer runtime.heap.collection_threshold = original_threshold;
    switch (dict_module.set(&runtime.heap, mapping, key, stored_value, 77, undefined, identityEqual)) {
        .value => {},
        .python_exception => |exception| {
            std.debug.print("mapping set exception: {s}\n", .{exception.message});
            return error.ExpectedMappingInsertion;
        },
        .engine_error => return error.ExpectedMappingInsertion,
    }
    try std.testing.expect(runtime.heap.collection_count > 0);
    switch (dict_module.get(mapping, key, 77, undefined, identityEqual)) {
        .value => |actual| try std.testing.expect(actual.identical(stored_value)),
        else => return error.ExpectedStoredValue,
    }
    try std.testing.expect(string.fromHeader(key.asObject().?) != null);
    try std.testing.expect(string.fromHeader(stored_value.asObject().?) != null);
}

pub fn testDictResizeAllocationFailureReleasesBuckets() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    const created = dict_module.create(&runtime.heap, false);
    const mapping = switch (created) {
        .value => |dict| dict,
        else => return error.ExpectedMapping,
    };
    var mapping_root = gc.Root{ .object = &mapping.header };
    var root_frame = gc.RootFrame{};
    root_frame.push(&runtime.heap.roots);
    root_frame.add(&mapping_root);
    defer root_frame.pop();
    runtime.heap.collection_threshold = std.math.maxInt(usize);
    for (0..5) |index| {
        const key = Value.fromSmallInt(@intCast(index)).?;
        const result = dict_module.set(&runtime.heap, mapping, key, key, index + 1, undefined, identityEqual);
        try std.testing.expect(result == .value);
    }

    const baseline_live_bytes = runtime.session_allocator.live_bytes;
    const original_cap = runtime.session_allocator.max_bytes;
    const next_capacity_bucket_bytes = 16 * @sizeOf(usize);
    const live_entry_bytes = mapping.size * @sizeOf(dict_module.Entry);
    runtime.session_allocator.max_bytes = baseline_live_bytes + next_capacity_bucket_bytes + live_entry_bytes - 1;
    const failed = dict_module.set(
        &runtime.heap,
        mapping,
        Value.fromSmallInt(5).?,
        Value.fromSmallInt(5).?,
        6,
        undefined,
        identityEqual,
    );
    switch (failed) {
        .python_exception => |exception| try std.testing.expectEqual(exceptions.PythonExceptionKind.memory_error, exception.kind),
        else => return error.ExpectedMemoryError,
    }
    try std.testing.expectEqual(baseline_live_bytes, runtime.session_allocator.live_bytes);
    runtime.session_allocator.max_bytes = original_cap;
    const recovered = dict_module.set(&runtime.heap, mapping, Value.fromSmallInt(5).?, Value.fromSmallInt(5).?, 6, undefined, identityEqual);
    try std.testing.expect(recovered == .value);
    try std.testing.expectEqual(@as(usize, 6), mapping.size);
}

pub fn testEmptyDictClearDoesNotInvalidateIterator() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    const empty_result = dict_module.create(&runtime.heap, false);
    const empty_mapping = switch (empty_result) {
        .value => |mapping| mapping,
        else => return error.ExpectedMapping,
    };
    var empty_mapping_root = gc.Root{ .object = &empty_mapping.header };
    var empty_iterator_root = gc.Root{ .object = null };
    var empty_roots = gc.RootFrame{};
    empty_roots.push(&runtime.heap.roots);
    empty_roots.add(&empty_mapping_root);
    empty_roots.add(&empty_iterator_root);
    defer empty_roots.pop();
    const empty_iterator = switch (dict_module.createIterator(&runtime.heap, empty_mapping, .keys)) {
        .value => |iterator| iterator,
        else => return error.ExpectedIterator,
    };
    empty_iterator_root.object = &empty_iterator.header;
    dict_module.clear(&runtime.heap, empty_mapping);
    try expectIteratorDone(&runtime.heap, empty_iterator);
}

pub fn testExhaustedDictIteratorStaysExhaustedAfterGrowth() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 2 * 1024 * 1024);
    defer runtime.deinit();
    const populated_result = dict_module.create(&runtime.heap, false);
    const populated = switch (populated_result) {
        .value => |mapping| mapping,
        else => return error.ExpectedMapping,
    };
    var populated_root = gc.Root{ .object = &populated.header };
    var iterator_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&runtime.heap.roots);
    roots.add(&populated_root);
    roots.add(&iterator_root);
    defer roots.pop();
    try expectDictSet(&runtime.heap, populated, 1, 1);
    const iterator_object = switch (dict_module.createIterator(&runtime.heap, populated, .keys)) {
        .value => |iterator| iterator,
        else => return error.ExpectedIterator,
    };
    iterator_root.object = &iterator_object.header;
    switch (dict_module.next(&runtime.heap, iterator_object)) {
        .item => {},
        else => return error.ExpectedFirstItem,
    }
    try expectIteratorDone(&runtime.heap, iterator_object);
    try expectDictSet(&runtime.heap, populated, 2, 2);
    try expectIteratorDone(&runtime.heap, iterator_object);
}

fn identityEqual(_: *anyopaque, left: Value, right: Value) ?bool {
    return left.identical(right);
}

fn expectDictSet(heap: *gc.Heap, mapping: *dict_module.Dict, key_value: i64, entry_value: i64) !void {
    const key = Value.fromSmallInt(key_value).?;
    const value = Value.fromSmallInt(entry_value).?;
    switch (dict_module.set(heap, mapping, key, value, @intCast(key_value), undefined, identityEqual)) {
        .value => {},
        else => return error.ExpectedMappingInsertion,
    }
}

fn expectIteratorDone(heap: *gc.Heap, iterator: *dict_module.DictIterator) !void {
    switch (dict_module.next(heap, iterator)) {
        .done => {},
        else => return error.ExpectedIteratorDone,
    }
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "mapping.py"));
    try runToCompletion(&runtime, 100_000);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectOutputWithCollectionThreshold(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "mapping-gc.py"));
    runtime.heap.collection_threshold = 1;
    try runToCompletion(&runtime, 100_000);
    try std.testing.expect(runtime.heap.collection_count > 0);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectRuntimeException(source: []const u8, kind_name: []const u8, location: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "mapping.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    _ = runtime.pythonException() orelse return error.ExpectedPythonException;
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), kind_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errorText(), location) != null);
}

fn expectRuntimeExceptionOutput(source: []const u8, expected_output: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "mapping-order.py"));
    try std.testing.expectEqual(runtime_vm.RunStatus.python_exception, runtime.run(100_000));
    try std.testing.expectEqual(exceptions.PythonExceptionKind.type_error, runtime.pythonException().?.kind);
    try std.testing.expectEqualStrings(expected_output, runtime.stdout());
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        .unsupported => |diagnostic| {
            std.debug.print("mapping source unsupported: {s}\n", .{diagnostic.message});
            return error.ExpectedExecutableProgram;
        },
        .syntax_error => |diagnostic| {
            std.debug.print("mapping source syntax error: {s}\n", .{diagnostic.message});
            return error.ExpectedExecutableProgram;
        },
        .python_exception => |exception| {
            std.debug.print("mapping compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableProgram;
        },
    }
}

fn runToCompletion(runtime: *runtime_vm.Runtime, quantum: u32) !void {
    var status = runtime.run(quantum);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 100_000) : (resumes += 1) status = runtime.run(quantum);
    if (status != .completed) std.debug.print("mapping VM status={s}, error={s}\n", .{ @tagName(status), runtime.errorText() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}
