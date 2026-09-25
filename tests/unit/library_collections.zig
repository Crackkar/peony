const std = @import("std");
const vm = @import("runtime_vm");
const host = @import("runtime_host");

pub fn testCounterConstructionAndMethods() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\from collections import Counter
        \\counter = Counter('ababa')
        \\print(type(counter) is Counter, isinstance(counter, dict), dict(counter))
        \\print(counter['missing'], 'missing' in counter, list(counter.keys()))
        \\counter.update('bcc')
        \\counter.subtract({'a': 1, 'b': 5, 'd': 2})
        \\print(dict(counter))
        \\print(list(counter.elements()), counter.most_common(), counter.total())
        \\print(dict(+counter), dict(-counter))
        \\copy = counter.copy()
        \\copy['a'] = 99
        \\print(type(copy) is Counter, counter['a'], copy['a'])
        \\print(dict(Counter({'x': 2}, y=3)))
        \\from_counter = Counter(Counter({'x': 2}))
        \\from_counter.update(Counter({'x': 3, 'y': 1}))
        \\from_counter.subtract(Counter({'x': 1}))
        \\print(dict(from_counter), list(from_counter.values()), list(from_counter.items()))
    , "library-collections-counter.py", 1);
    try std.testing.expectEqualStrings(
        "True True {'a': 3, 'b': 2}\n0 False ['a', 'b']\n{'a': 2, 'b': -2, 'c': 2, 'd': -2}\n['a', 'a', 'c', 'c'] [('a', 2), ('c', 2), ('b', -2), ('d', -2)] 0\n{'a': 2, 'c': 2} {'b': 2, 'd': 2}\nTrue 2 99\n{'x': 2, 'y': 3}\n{'x': 4, 'y': 1} [4, 1] [('x', 4), ('y', 1)]\n",
        runtime.stdout(),
    );
}

pub fn testCounterOperatorsAndComparisons() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\from collections import Counter
        \\left = Counter({'a': 3, 'b': 1})
        \\right = Counter({'a': 1, 'b': 2, 'c': 4})
        \\print(dict(left + right))
        \\print(dict(left - right))
        \\print(dict(left & right))
        \\print(dict(left | right))
        \\print(Counter(a=1) == Counter(a=1, b=0))
        \\print(Counter(a=1) <= Counter(a=1, b=0), Counter(a=2) > Counter(a=1))
        \\print(Counter(a=1) < Counter(a=2), Counter(a=2) >= Counter(a=1), Counter(a=1) != Counter(a=2))
        \\ties = Counter()
        \\ties.update(['first', 'second', 'third', 'second', 'first', 'third'])
        \\print(ties.most_common(2))
    , "library-collections-counter-ops.py", 1);
    try std.testing.expectEqualStrings(
        "{'a': 4, 'b': 3, 'c': 4}\n{'a': 2}\n{'a': 1, 'b': 1}\n{'a': 3, 'b': 2, 'c': 4}\nTrue\nTrue True\nTrue True True\n[('first', 2), ('second', 2)]\n",
        runtime.stdout(),
    );
}

pub fn testDefaultdictContract() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\from collections import defaultdict
        \\calls = 0
        \\def factory():
        \\    global calls
        \\    calls += 1
        \\    return []
        \\values = defaultdict(factory, {'ready': [1]})
        \\print(type(values) is defaultdict, isinstance(values, dict), values.default_factory is factory)
        \\print(values.get('absent'), 'absent' in values, calls)
        \\first = values['absent']
        \\first.append(7)
        \\print(values['absent'] is first, values['absent'], calls)
        \\values.default_factory = lambda: 9
        \\print(values['next'])
        \\values.default_factory = None
        \\try:
        \\    values['missing']
        \\except KeyError:
        \\    print('key error', 'missing' in values)
        \\try:
        \\    defaultdict(3)
        \\except TypeError:
        \\    print('factory type')
        \\def broken():
        \\    raise ValueError('broken')
        \\failed = defaultdict(broken)
        \\try:
        \\    failed['x']
        \\except ValueError:
        \\    print('factory error', 'x' in failed)
        \\values.update({'more': [2]})
        \\clone = values.copy()
        \\print(type(clone) is defaultdict, clone.default_factory is values.default_factory, list(clone.values()), list(clone.items()))
        \\print(clone.setdefault('set', 5), clone.pop('set'), 'set' in clone)
        \\clone.clear()
        \\print(len(clone))
    , "library-collections-defaultdict.py", 1);
    try std.testing.expectEqualStrings(
        "True True True\nNone False 0\nTrue [7] 1\n9\nkey error False\nfactory type\nfactory error False\nTrue True [[1], [7], 9, [2]] [('ready', [1]), ('absent', [7]), ('next', 9), ('more', [2])]\n5 5 False\n0\n",
        runtime.stdout(),
    );
}

pub fn testCopyGraphsInstancesAndResources() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import copy
        \\child = [1]
        \\source = [child, child]
        \\shallow = copy.copy(source)
        \\deep = copy.deepcopy(source)
        \\print(shallow is not source, shallow[0] is child, shallow[0] is shallow[1])
        \\print(deep is not source, deep[0] is not child, deep[0] is deep[1])
        \\cycle = []
        \\cycle.append(cycle)
        \\cycle_copy = copy.deepcopy(cycle)
        \\print(cycle_copy is not cycle, cycle_copy[0] is cycle_copy)
        \\cached = ['cached']
        \\memo_source = []
        \\print(copy.deepcopy(memo_source, {id(memo_source): cached}) is cached)
        \\inner = []
        \\tuple_cycle = (inner,)
        \\inner.append(tuple_cycle)
        \\tuple_copy = copy.deepcopy(tuple_cycle)
        \\print(tuple_copy is not tuple_cycle, tuple_copy[0][0] is tuple_copy)
        \\class Box:
        \\    def __init__(self):
        \\        self.value = child
        \\box = Box()
        \\box_shallow = copy.copy(box)
        \\box_deep = copy.deepcopy(box)
        \\print(type(box_shallow) is Box, box_shallow is not box, box_shallow.value is child)
        \\print(type(box_deep) is Box, box_deep.value is not child, box_deep.value == child)
        \\immutable_tuple = (1, 2)
        \\immutable_text = 'text'
        \\print(copy.copy(1) is 1, copy.deepcopy(immutable_text) is immutable_text, copy.copy(immutable_tuple) is immutable_tuple)
        \\with open('/home/resource.txt', 'w') as resource:
        \\    try:
        \\        copy.deepcopy(resource)
        \\    except (copy.Error, TypeError):
        \\        print('resource')
        \\print(issubclass(copy.Error, Exception))
    , "library-collections-copy.py", 1);
    try std.testing.expectEqualStrings(
        "True True True\nTrue True True\nTrue True\nTrue\nTrue True\nTrue True True\nTrue True True\nTrue True True\nresource\nTrue\n",
        runtime.stdout(),
    );
}

pub fn testCollectionAndCopyHooksResumeInputOnce() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\from collections import defaultdict
        \\import copy
        \\factory_calls = 0
        \\def factory():
        \\    global factory_calls
        \\    factory_calls += 1
        \\    return input('Factory: ')
        \\values = defaultdict(factory)
        \\print(values['x'], values['x'], factory_calls)
        \\class Hook:
        \\    def __copy__(self):
        \\        return input('Shallow: ')
        \\    def __deepcopy__(self, memo):
        \\        print(isinstance(memo, dict))
        \\        return input('Copy: ')
        \\hook = Hook()
        \\print(copy.copy(hook))
        \\print(copy.deepcopy(hook))
        \\class NestedHook:
        \\    def __deepcopy__(self, memo):
        \\        return input('Nested: ')
        \\print(copy.deepcopy([NestedHook()]))
    );
    try resumeInput(&runtime, "made");
    try resumeInput(&runtime, "shallow");
    try resumeInput(&runtime, "cloned");
    try resumeInput(&runtime, "nested");
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("Factory: made made 1\nShallow: shallow\nTrue\nCopy: cloned\nNested: ['nested']\n", runtime.stdout());
}

pub fn testCollectionsGcCapAndReset() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 3 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runScript(&runtime,
        \\from collections import Counter, defaultdict
        \\import copy
        \\counter = Counter([i % 17 for i in range(5000)])
        \\graph = [counter, counter]
        \\cloned = copy.deepcopy(graph)
        \\print(counter.total(), cloned[0] is cloned[1], cloned[0] is not counter)
        \\child = [1]
        \\cycle = [child, child]
        \\cycle.append(cycle)
        \\for _ in range(100):
        \\    repeated = copy.deepcopy(cycle)
        \\print(repeated[0] is repeated[1], repeated[2] is repeated)
        \\d = defaultdict(list)
        \\for i in range(100): d[i].append(i)
        \\print(len(d))
    , "library-collections-gc.py", 1);
    try std.testing.expectEqualStrings("5000 True True\nTrue True\n100\n", runtime.stdout());
    try std.testing.expect(runtime.heap.collection_count > 0);
    runtime.reset();
    try runScript(&runtime,
        \\from collections import Counter
        \\import copy
        \\print(Counter('aba').most_common(), copy.deepcopy([1, 2]))
    , "library-collections-reset.py", 1);
    try std.testing.expectEqualStrings("[('a', 2), ('b', 1)] [1, 2]\n", runtime.stdout());
}

fn ready(runtime: *vm.Runtime, source: []const u8) !void {
    switch (runtime.compileAndStart(source, "library-collections-callback.py")) {
        .ready => {},
        else => return error.ExpectedExecutableCollectionsProgram,
    }
}

fn boundary(runtime: *vm.Runtime, quantum: u32) !vm.RunStatus {
    var status = vm.RunStatus.timeslice;
    for (0..200_000) |_| {
        status = runtime.run(quantum);
        if (status != .timeslice) return status;
    }
    return error.NoCollectionsExecutionBoundary;
}

fn resumeInput(runtime: *vm.Runtime, text: []const u8) !void {
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(runtime, 1));
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingCollectionsInputRequest;
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
            std.debug.print("collections syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableCollectionsProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("collections unsupported at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableCollectionsProgram;
        },
        .python_exception => |exception| {
            std.debug.print("collections compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableCollectionsProgram;
        },
    }
    const status = try boundary(runtime, quantum);
    if (status != .completed) std.debug.print("collections status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(vm.RunStatus.completed, status);
}
