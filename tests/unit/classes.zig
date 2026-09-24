const std = @import("std");
const runtime_vm = @import("runtime_vm");
const host = @import("runtime_host");
const parser = @import("frontend_parser");
const ast_module = @import("frontend_ast");
const scope_module = @import("frontend_scope");

pub fn testParserAndClassScope() !void {
    const source =
        "def outer():\n" ++
        "    captured = 'outer'\n" ++
        "    class Inner:\n" ++
        "        captured = 'class'\n" ++
        "        def read(self):\n" ++
        "            return captured\n" ++
        "    return Inner().read()\n" ++
        "@identity\n" ++
        "class Decorated(InnerBase):\n" ++
        "    pass\n";
    const parsed = try parser.parse(std.testing.allocator, source);
    if (parsed == .failure) {
        std.debug.print("class parse red: {s} at {d}:{d}\n", .{ parsed.failure.message, parsed.failure.line, parsed.failure.column });
        return error.ExpectedClassAst;
    }
    var ast = parsed.ast;
    defer ast.deinit();
    const outer = findNode(&ast, .function_definition, "outer") orelse return error.MissingOuterFunction;
    const outer_body = ast.children(outer)[ast.children(outer).len - 1];
    const inner = findNode(&ast, .class_definition, "Inner") orelse return error.MissingInnerClass;
    const method = findNode(&ast, .function_definition, "read") orelse return error.MissingReadMethod;
    const analyzed = try scope_module.analyze(std.testing.allocator, &ast);
    if (analyzed == .failure) return error.UnexpectedClassScopeError;
    var analysis = analyzed.analysis;
    defer analysis.deinit();

    const outer_scope = analysis.scopeForBlock(outer_body) orelse return error.MissingOuterScope;
    const class_scope = scopeForOwner(&analysis, inner) orelse return error.MissingClassScope;
    const method_scope = scopeForOwner(&analysis, method) orelse return error.MissingMethodScope;
    try std.testing.expectEqual(scope_module.Binding.cell, analysis.symbol(outer_scope, "captured").?.binding);
    try std.testing.expectEqual(scope_module.Binding.class_local, analysis.symbol(class_scope, "captured").?.binding);
    try std.testing.expectEqual(scope_module.Binding.free, analysis.symbol(method_scope, "captured").?.binding);
}

pub fn testClassDefinitionOrderAndMethodBinding() !void {
    try expectOutput(
        \\events = []
        \\def base(label, value):
        \\    events.append("base:" + label)
        \\    return value
        \\def decorate(label):
        \\    events.append("eval:" + label)
        \\    def apply(value):
        \\        events.append("apply:" + label)
        \\        return value
        \\    return apply
        \\class Root:
        \\    kind = "root"
        \\    def __init__(self, value):
        \\        self.value = value
        \\    def get(self):
        \\        return self.value
        \\@decorate("outer")
        \\@decorate("inner")
        \\class Child(base("child", Root)):
        \\    events.append("body")
        \\    kind = "class"
        \\    def get(self):
        \\        return self.value
        \\@decorate("function")
        \\def decorated():
        \\    return "function-ok"
        \\instance = Child("instance")
        \\instance.kind = "instance"
        \\print(events)
        \\print(instance.kind, Child.kind, instance.get(), decorated())
        \\print(type(instance) is Child, isinstance(instance, Root), issubclass(Child, Root))
        \\def outer():
        \\    captured = "outer"
        \\    class Nested:
        \\        captured = "class"
        \\        def read(self):
        \\            return captured
        \\    return Nested().read()
        \\print(outer())
    , "['eval:outer', 'eval:inner', 'base:child', 'body', 'apply:inner', 'apply:outer', 'eval:function', 'apply:function']\ninstance class instance function-ok\nTrue True True\nouter\n");
}

pub fn testClassBodyLoadNameFallsBackToGlobals() !void {
    try expectOutput(
        \\value = "global"
        \\class Lookup:
        \\    print(value)
        \\    value = "class"
    , "global\n");
}

pub fn testC3MroSuperAndClassCell() !void {
    try expectOutput(
        \\class A:
        \\    def chain(self):
        \\        return "A"
        \\class B(A):
        \\    def chain(self):
        \\        return "B" + super().chain()
        \\class C(A):
        \\    def chain(self):
        \\        return "C" + super().chain()
        \\class D(B, C):
        \\    def chain(self):
        \\        return "D" + super().chain()
        \\    def owner(self):
        \\        return __class__ is type(self)
        \\class E(D):
        \\    def chain(self):
        \\        return "E" + super(E, self).chain()
        \\print(D().chain(), E().chain(), D().owner())
        \\class X:
        \\    pass
        \\class Y:
        \\    pass
        \\class XY(X, Y):
        \\    pass
        \\class YX(Y, X):
        \\    pass
        \\try:
        \\    class Impossible(XY, YX):
        \\        pass
        \\except TypeError:
        \\    print("inconsistent mro")
    , "DBCA EDBCA True\ninconsistent mro\n");
}

pub fn testSuperBindsInheritedPropertyGetter() !void {
    try expectOutput(
        \\class A:
        \\    @property
        \\    def value(self):
        \\        return 4
        \\class B(A):
        \\    def get(self):
        \\        return super().value
        \\    def get_with_getattr(self):
        \\        return getattr(super(), "value")
        \\print(B().get(), B().get_with_getattr())
    , "4 4\n");
}

pub fn testDescriptorsAndConstructorValidation() !void {
    try expectOutput(
        \\class Box:
        \\    def __init__(self, value):
        \\        self._value = value
        \\    @property
        \\    def value(self):
        \\        return self._value
        \\    @value.setter
        \\    def value(self, value):
        \\        self._value = value
        \\    @value.deleter
        \\    def value(self):
        \\        del self._value
        \\    @staticmethod
        \\    def twice(value):
        \\        return value * 2
        \\    @classmethod
        \\    def from_value(cls, value):
        \\        return cls(value)
        \\box = Box(3)
        \\print(box.value, Box.twice(4), box.twice(5), Box.from_value(6).value)
        \\box.value = 9
        \\print(box.value)
        \\setattr(box, "extra", 11)
        \\print(getattr(box, "extra"), hasattr(box, "extra"))
        \\delattr(box, "extra")
        \\print(hasattr(box, "extra"))
        \\del box.value
        \\print(hasattr(box, "value"))
        \\try:
        \\    print(box.value)
        \\except AttributeError:
        \\    print("deleted")
        \\class Bad:
        \\    def __init__(self):
        \\        return 1
        \\try:
        \\    Bad()
        \\except TypeError:
        \\    print("init must return None")
    , "3 8 10 6\n9\n11 True\nFalse\nFalse\ndeleted\ninit must return None\n");
}

pub fn testDataDescriptorShadowsInstanceAttribute() !void {
    try expectOutput(
        \\class C:
        \\    pass
        \\instance = C()
        \\instance.value = 1
        \\C.value = property(lambda self: 2)
        \\print(instance.value)
        \\try:
        \\    instance.value = 3
        \\except AttributeError:
        \\    print("read-only")
    , "2\nread-only\n");
}

pub fn testIsinstanceTypeObjectDistinguishesInstances() !void {
    try expectOutput(
        \\class C:
        \\    pass
        \\print(isinstance(1, type), isinstance(None, type), isinstance(C, type), isinstance(ValueError, type))
    , "False False True True\n");
}

pub fn testGetattrDefaultHandlesPropertyAttributeError() !void {
    try expectOutput(
        \\class C:
        \\    @property
        \\    def value(self):
        \\        raise AttributeError("missing")
        \\instance = C()
        \\print(getattr(instance, "value", 7), hasattr(instance, "value"))
        \\try:
        \\    instance.value
        \\except AttributeError:
        \\    print("raised")
    , "7 False\nraised\n");
}

pub fn testAttributeErrorSuppressionPreservesHandledException() !void {
    try expectOutput(
        \\class C:
        \\    @property
        \\    def value(self):
        \\        raise AttributeError("hidden")
        \\instance = C()
        \\events = []
        \\try:
        \\    try:
        \\        raise ValueError("getattr")
        \\    except ValueError:
        \\        getattr(instance, "value", 7)
        \\        raise
        \\except ValueError as error:
        \\    events.append(str(error))
        \\try:
        \\    try:
        \\        raise ValueError("hasattr")
        \\    except ValueError:
        \\        hasattr(instance, "value")
        \\        raise
        \\except ValueError as error:
        \\    events.append(str(error))
        \\print(events)
    , "['getattr', 'hasattr']\n");
}

pub fn testSpecialMethodsAndReflectedFallback() !void {
    try expectOutput(
        \\class Left:
        \\    def __add__(self, other):
        \\        return NotImplemented
        \\class Right:
        \\    def __radd__(self, other):
        \\        return "reflected"
        \\class Box:
        \\    def __repr__(self):
        \\        return "Box()"
        \\    def __str__(self):
        \\        return "Box str"
        \\    def __len__(self):
        \\        return 7
        \\    def __bool__(self):
        \\        return False
        \\    def __contains__(self, item):
        \\        return item == 3
        \\    def __getitem__(self, item):
        \\        return item + 1
        \\    def __setitem__(self, item, value):
        \\        self.assigned = item + value
        \\box = Box()
        \\box.__repr__ = lambda: "instance shadow"
        \\box.__len__ = lambda: 0
        \\print(box, repr(box), str(box), len(box), bool(box), 3 in box, box[4], Left() + Right())
        \\box[2] = 5
        \\print(box.assigned)
        \\class Counter:
        \\    def __init__(self):
        \\        self.value = 0
        \\    def __iter__(self):
        \\        return self
        \\    def __next__(self):
        \\        if self.value == 3:
        \\            raise StopIteration
        \\        result = self.value
        \\        self.value += 1
        \\        return result
        \\print(list(Counter()))
        \\class Number:
        \\    def __init__(self, value):
        \\        self.value = value
        \\    def __lt__(self, other):
        \\        return self.value < other.value
        \\    def __le__(self, other):
        \\        return self.value <= other.value
        \\    def __gt__(self, other):
        \\        return self.value > other.value
        \\    def __ge__(self, other):
        \\        return self.value >= other.value
        \\    def __ne__(self, other):
        \\        return self.value != other.value
        \\first = Number(1)
        \\second = Number(2)
        \\print(first < second, first <= first, second > first, second >= first, first != second)
        \\class Arithmetic:
        \\    def __init__(self, value):
        \\        self.value = value
        \\    def __add__(self, other):
        \\        return self.value + other
        \\    def __radd__(self, other):
        \\        return other + self.value
        \\    def __sub__(self, other):
        \\        return self.value - other
        \\    def __rsub__(self, other):
        \\        return other - self.value
        \\    def __mul__(self, other):
        \\        return self.value * other
        \\    def __rmul__(self, other):
        \\        return other * self.value
        \\    def __truediv__(self, other):
        \\        return self.value / other
        \\    def __rtruediv__(self, other):
        \\        return other / self.value
        \\    def __floordiv__(self, other):
        \\        return self.value // other
        \\    def __rfloordiv__(self, other):
        \\        return other // self.value
        \\    def __mod__(self, other):
        \\        return self.value % other
        \\    def __rmod__(self, other):
        \\        return other % self.value
        \\    def __pow__(self, other):
        \\        return self.value ** other
        \\    def __rpow__(self, other):
        \\        return other ** self.value
        \\number = Arithmetic(8)
        \\square = Arithmetic(2)
        \\print(number + 2, 2 + number, number - 2, 10 - number, number * 2, 2 * number)
        \\print(number / 2, 16 / number, number // 3, 17 // number, number % 3, 10 % number)
        \\print(square ** 3, 3 ** square)
        \\class Callable:
        \\    def __call__(self):
        \\        return "called"
        \\print(callable(Callable), callable(Callable()), Callable()())
    , "Box str Box() Box str 7 False True 5 reflected\n7\n[0, 1, 2]\nTrue True True True True\n10 10 6 2 16 16\n4.0 2.0 2 2 2 2\n8 9\nTrue True called\n");
}

pub fn testUserClassWithProtocol() !void {
    try expectOutput(
        \\events = []
        \\class Manager:
        \\    def __init__(self, name):
        \\        self.name = name
        \\    def __enter__(self):
        \\        events.append("enter:" + self.name)
        \\        return self
        \\    def __exit__(self, exc_type, exc, traceback):
        \\        events.append("exit:" + self.name)
        \\        return exc_type is ValueError
        \\with Manager("outer") as first, Manager("inner") as second:
        \\    events.append("body")
        \\try:
        \\    with Manager("suppress"):
        \\        raise ValueError("caught by exit")
        \\except ValueError:
        \\    events.append("not suppressed")
        \\print(events)
    , "['enter:outer', 'enter:inner', 'body', 'exit:inner', 'exit:outer', 'enter:suppress', 'exit:suppress']\n");
}

pub fn testWithExitTruthinessWhileExceptionIsPending() !void {
    try expectOutput(
        \\events = []
        \\class Truth:
        \\    def __init__(self):
        \\        self.text = "a"
        \\    def __bool__(self):
        \\        return self.text + "b" == "ab"
        \\class Manager:
        \\    def __enter__(self):
        \\        return self
        \\    def __exit__(self, exc_type, exc, traceback):
        \\        events.append("exit")
        \\        return Truth()
        \\try:
        \\    with Manager():
        \\        raise ValueError("handled")
        \\except ValueError:
        \\    events.append("not suppressed")
        \\print(events)
    , "['exit']\n");
}

pub fn testEqualityDisablesHashWithoutOverride() !void {
    try expectOutput(
        \\class EqualValue:
        \\    def __init__(self, value):
        \\        self.value = value
        \\    def __eq__(self, other):
        \\        return self.value == other.value
        \\left = EqualValue(4)
        \\right = EqualValue(4)
        \\print(left == right)
        \\try:
        \\    hash(left)
        \\except TypeError:
        \\    print("unhashable")
        \\class Hashable:
        \\    def __init__(self, value):
        \\        self.value = value
        \\    def __eq__(self, other):
        \\        return self.value == other.value
        \\    def __hash__(self):
        \\        return 42
        \\first = Hashable(7)
        \\same = Hashable(7)
        \\table = {first: "value"}
        \\keys = {first, same}
        \\print(hash(first), table[same], len(keys), same in keys)
    , "True\nunhashable\n42 value 1 True\n");
}

pub fn testSubclassEqWithoutHashOverridesInheritedHash() !void {
    try expectOutput(
        \\class Base:
        \\    def __hash__(self):
        \\        return 19
        \\class Derived(Base):
        \\    def __eq__(self, other):
        \\        return True
        \\try:
        \\    hash(Derived())
        \\except TypeError:
        \\    print("unhashable")
    , "unhashable\n");
}

pub fn testDictKeyEqualityTriesLookupKeyRightEq() !void {
    try expectOutput(
        \\class Key:
        \\    def __hash__(self):
        \\        return 1
        \\    def __eq__(self, other):
        \\        return other == 1
        \\print({1: "hit"}.get(Key(), "miss"))
    , "hit\n");
}

pub fn testDictStringKeyEqualityTriesLookupKeyRightEq() !void {
    try expectOutput(
        \\class Key:
        \\    def __hash__(self):
        \\        return hash("a")
        \\    def __eq__(self, other):
        \\        return other == "a"
        \\key = Key()
        \\print(hash(key) == hash("a"), {"a": "hit"}.get(key, "miss"))
    , "True hit\n");
}

pub fn testRightSubclassReflectedArithmeticHasPriority() !void {
    try expectOutput(
        \\class A:
        \\    def __add__(self, other):
        \\        return "left"
        \\class B(A):
        \\    def __radd__(self, other):
        \\        return "right"
        \\print(A() + B())
    , "right\n");
}

pub fn testContainsFallsBackToUserIterator() !void {
    try expectOutput(
        \\class C:
        \\    def __iter__(self):
        \\        return iter([1, 2])
        \\print(2 in C())
    , "True\n");
}

pub fn testContainsSuspendedIteratorRaisesCatchableRuntimeErrorAndRecovers() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    try expectReady(runtime.compileAndStart(
        \\class C:
        \\    def __iter__(self):
        \\        return (value for value in range(10))
        \\items = (2 in C() for _ in range(1))
        \\try:
        \\    print(list(items))
        \\except RuntimeError as error:
        \\    print(str(error))
    , "contains-suspended.py"));
    try runToCompletion(&runtime, 1);
    try std.testing.expectEqualStrings("iterator suspended during membership test\n", runtime.stdout());

    try expectReady(runtime.compileAndStart("print('recovered')\n", "contains-suspended-recovery.py"));
    try runToCompletion(&runtime, 1);
    try std.testing.expectEqualStrings("recovered\n", runtime.stdout());
}

pub fn testContainsRootsFreshUserIteratorItemDuringAllocatingEquality() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();

    try expectReady(runtime.compileAndStart(
        \\class Candidate:
        \\    def __eq__(self, other):
        \\        junk = [str(index) for index in range(50)]
        \\        return other == 7
        \\class C:
        \\    def __iter__(self):
        \\        return self
        \\    def __next__(self):
        \\        return Candidate()
        \\print(7 in C())
    , "contains-allocating-equality.py"));
    runtime.heap.collection_threshold = 1;
    const collections_before = runtime.heap.collection_count;
    try runToCompletion(&runtime, 10_000);
    try std.testing.expect(runtime.heap.collection_count > collections_before);
    try std.testing.expectEqualStrings("True\n", runtime.stdout());
}

pub fn testClassGcQuantumCancelAndReset() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 16;
    const source =
        "class Item:\n" ++
        "    def value(self):\n" ++
        "        return 'ok'\n" ++
        "counter = 0\n" ++
        "while True:\n" ++
        "    method = Item().value\n" ++
        "    method()\n";
    try expectReady(runtime.compileAndStart(source, "class-cancel.py"));
    const collections_before = runtime.heap.collection_count;
    var status = runtime.run(1);
    var steps: usize = 0;
    while (status == .timeslice and steps < 40) : (steps += 1) status = runtime.run(1);
    try std.testing.expectEqual(runtime_vm.RunStatus.timeslice, status);
    try std.testing.expect(runtime.heap.collection_count > collections_before);
    runtime.cancel();
    try std.testing.expectEqual(runtime_vm.RunStatus.cancelled, runtime.run(1));
    runtime.reset();
    try expectReady(runtime.compileAndStart("class Again:\n    pass\nprint(type(Again()) is Again)\n", "class-reset.py"));
    try runToCompletion(&runtime, 1);
    try std.testing.expectEqualStrings("True\n", runtime.stdout());
}

pub fn testLongInitializerTimeslicesAndSuspendsForInput() !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(
        \\class Box:
        \\    def __init__(self):
        \\        self.count = 0
        \\        while self.count < 10:
        \\            print("init", self.count)
        \\            self.count += 1
        \\        self.name = input("Name: ")
        \\box = Box()
        \\print(box.name, box.count)
    , "class-init-input.py"));

    var status = runtime_vm.RunStatus.timeslice;
    for (0..10_000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.host_request, status);
    const expected_before_resume = "init 0\ninit 1\ninit 2\ninit 3\ninit 4\ninit 5\ninit 6\ninit 7\ninit 8\ninit 9\nName: ";
    try std.testing.expectEqualStrings(expected_before_resume, runtime.stdout());
    const request_id = runtime.pendingInputRequestId() orelse return error.MissingClassInputRequest;
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
    status = .timeslice;
    for (0..1000) |_| {
        status = runtime.run(1);
        if (status != .timeslice) break;
    }
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
    try std.testing.expectEqualStrings("init 0\ninit 1\ninit 2\ninit 3\ninit 4\ninit 5\ninit 6\ninit 7\ninit 8\ninit 9\nName: Ada 10\n", runtime.stdout());
}

pub fn testUnsupportedDynamicTypeAndMetaclass() !void {
    try expectUnsupported("class Dynamic(metaclass=Meta):\n    pass\n");
    try expectUnsupported("type(\"Dynamic\", (), {})\n");
}

pub fn testShadowedTypeNameRemainsCallable() !void {
    try expectOutput(
        \\type = lambda a, b, c: a + b + c
        \\def call_with_shadow(type):
        \\    return type(4, 5, 6)
        \\print(type(1, 2, 3), call_with_shadow(lambda a, b, c: a + b + c))
    , "6 15\n");
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try expectReady(runtime.compileAndStart(source, "classes.py"));
    try runToCompletion(&runtime, 10_000);
    try std.testing.expectEqualStrings(expected, runtime.stdout());
}

fn expectReady(outcome: runtime_vm.CompileOutcome) !void {
    switch (outcome) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("unexpected class syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableClassProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("unexpected class unsupported feature at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableClassProgram;
        },
        .python_exception => |exception| {
            std.debug.print("unexpected class compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableClassProgram;
        },
    }
}

fn expectUnsupported(source: []const u8) !void {
    var runtime: runtime_vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    switch (runtime.compileAndStart(source, "excluded-class.py")) {
        .unsupported => {},
        else => return error.ExpectedExplicitUnsupportedDiagnostic,
    }
    try std.testing.expectEqualStrings("", runtime.stdout());
}

fn runToCompletion(runtime: *runtime_vm.Runtime, quantum: u32) !void {
    var status = runtime.run(quantum);
    var resumes: usize = 0;
    while (status == .timeslice and resumes < 50_000) : (resumes += 1) status = runtime.run(quantum);
    if (status != .completed) std.debug.print("class runtime status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(runtime_vm.RunStatus.completed, status);
}

fn findNode(ast: *const ast_module.Ast, kind: ast_module.Kind, name: []const u8) ?ast_module.NodeId {
    for (ast.nodes, 0..) |node, index| {
        if (node.kind == kind and std.mem.eql(u8, node.text, name)) return @intCast(index);
    }
    return null;
}

fn scopeForOwner(analysis: *const scope_module.Analysis, owner: ast_module.NodeId) ?scope_module.ScopeId {
    for (analysis.scopes, 0..) |scope, index| if (scope.owner_node == owner) return @intCast(index);
    return null;
}
