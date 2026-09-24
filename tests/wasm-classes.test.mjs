import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({
  ok: 0,
  unsupported: 1,
  completed: 5,
  pythonException: 6,
  timeslice: 7,
  cancelled: 8,
});

async function newApi() {
  const bytes = await readFile(wasmPath);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return instance.exports;
}

function writeTransfer(api, value) {
  const bytes = new TextEncoder().encode(value);
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(api, handle, source, filename = 'classes.py') {
  const sourceBlock = writeTransfer(api, source);
  const filenameBlock = writeTransfer(api, filename);
  try {
    return api.peony_compile_and_start(handle, sourceBlock.pointer, sourceBlock.length, filenameBlock.pointer, filenameBlock.length);
  } finally {
    api.peony_transfer_free(sourceBlock.pointer, sourceBlock.length);
    api.peony_transfer_free(filenameBlock.pointer, filenameBlock.length);
  }
}

function borrowedText(api, pointerExport, lengthExport, handle) {
  const pointer = pointerExport(handle);
  const length = lengthExport(handle);
  return length === 0 ? '' : new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length));
}

const stdout = (api, handle) => borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle);
const errorText = (api, handle) => borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle);

test('shipping WASM evaluates class decorators, bases and bodies in order', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'events = []',
      'def base(label, value):',
      '    events.append("base:" + label)',
      '    return value',
      'def decorate(label):',
      '    events.append("eval:" + label)',
      '    def apply(value):',
      '        events.append("apply:" + label)',
      '        return value',
      '    return apply',
      'class Root:',
      '    kind = "root"',
      '    def __init__(self, value):',
      '        self.value = value',
      '    def get(self):',
      '        return self.value',
      '@decorate("outer")',
      '@decorate("inner")',
      'class Child(base("child", Root)):',
      '    events.append("body")',
      '    kind = "class"',
      '    def get(self):',
      '        return self.value',
      '@decorate("function")',
      'def decorated():',
      '    return "function-ok"',
      'instance = Child("instance")',
      'instance.kind = "instance"',
      'print(events)',
      'print(instance.kind, Child.kind, instance.get(), decorated())',
      'print(type(instance) is Child, isinstance(instance, Root), issubclass(Child, Root))',
      'def outer():',
      '    captured = "outer"',
      '    class Nested:',
      '        captured = "class"',
      '        def read(self):',
      '            return captured',
      '    return Nested().read()',
      'print(outer())',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "['eval:outer', 'eval:inner', 'base:child', 'body', 'apply:inner', 'apply:outer', 'eval:function', 'apply:function']\ninstance class instance function-ok\nTrue True True\nouter\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM class-body LOAD_NAME falls back to globals when the namespace is empty', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, [
      'value = "global"',
      'class Lookup:',
      '    print(value)',
      '    value = "class"',
    ].join('\n')), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'global\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM classes use C3 super and supported descriptors', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class A:',
      '    def chain(self):',
      '        return "A"',
      'class B(A):',
      '    def chain(self):',
      '        return "B" + super().chain()',
      'class C(A):',
      '    def chain(self):',
      '        return "C" + super().chain()',
      'class D(B, C):',
      '    def chain(self):',
      '        return "D" + super().chain()',
      '    def owner(self):',
      '        return __class__ is type(self)',
      'class E(D):',
      '    def chain(self):',
      '        return "E" + super(E, self).chain()',
      'print(D().chain(), E().chain(), D().owner())',
      'class Box:',
      '    def __init__(self, value):',
      '        self._value = value',
      '    @property',
      '    def value(self):',
      '        return self._value',
      '    @value.setter',
      '    def value(self, value):',
      '        self._value = value',
      '    @value.deleter',
      '    def value(self):',
      '        del self._value',
      '    @staticmethod',
      '    def twice(value):',
      '        return value * 2',
      '    @classmethod',
      '    def from_value(cls, value):',
      '        return cls(value)',
      'box = Box(3)',
      'print(box.value, Box.twice(4), box.twice(5), Box.from_value(6).value)',
      'box.value = 9',
      'print(box.value)',
      'setattr(box, "extra", 11)',
      'print(getattr(box, "extra"), hasattr(box, "extra"))',
      'delattr(box, "extra")',
      'print(hasattr(box, "extra"))',
      'del box.value',
      'print(hasattr(box, "value"))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'DBCA EDBCA True\n3 8 10 6\n9\n11 True\nFalse\nFalse\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM super binds inherited property getters to the instance', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class A:',
      '    @property',
      '    def value(self):',
      '        return 4',
      'class B(A):',
      '    def get(self):',
      '        return super().value',
      '    def get_with_getattr(self):',
      '        return getattr(super(), "value")',
      'print(B().get(), B().get_with_getattr())',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '4 4\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM data descriptors shadow same-named instance attributes', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class C:',
      '    pass',
      'instance = C()',
      'instance.value = 1',
      'C.value = property(lambda self: 2)',
      'print(instance.value)',
      'try:',
      '    instance.value = 3',
      'except AttributeError:',
      '    print("read-only")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '2\nread-only\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM isinstance treats class objects as types, not primitives', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = 'class C:\n    pass\nprint(isinstance(1, type), isinstance(None, type), isinstance(C, type), isinstance(ValueError, type))\n';
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'False False True True\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM getattr default handles property AttributeError only', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class C:',
      '    @property',
      '    def value(self):',
      '        raise AttributeError("missing")',
      'instance = C()',
      'print(getattr(instance, "value", 7), hasattr(instance, "value"))',
      'try:',
      '    instance.value',
      'except AttributeError:',
      '    print("raised")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '7 False\nraised\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM AttributeError suppression preserves the handled exception for bare raise', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class C:',
      '    @property',
      '    def value(self):',
      '        raise AttributeError("hidden")',
      'instance = C()',
      'events = []',
      'try:',
      '    try:',
      '        raise ValueError("getattr")',
      '    except ValueError:',
      '        getattr(instance, "value", 7)',
      '        raise',
      'except ValueError as error:',
      '    events.append(str(error))',
      'try:',
      '    try:',
      '        raise ValueError("hasattr")',
      '    except ValueError:',
      '        hasattr(instance, "value")',
      '        raise',
      'except ValueError as error:',
      '    events.append(str(error))',
      'print(events)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "['getattr', 'hasattr']\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM getattr and hasattr expose file fields', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'file = open("/home/attribute-fields.txt", "w")',
      'print(getattr(file, "closed"), hasattr(file, "closed"))',
      'print(getattr(file, "name"), getattr(file, "mode"), getattr(file, "encoding"))',
      'print(hasattr(file, "name"), hasattr(file, "mode"), hasattr(file, "encoding"))',
      'file.close()',
      'print(getattr(file, "closed"))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'False True\n/home/attribute-fields.txt w UTF-8\nTrue True True\nTrue\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM truth-tests an exit result while the exception is pending', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'events = []',
      'class Truth:',
      '    def __init__(self):',
      '        self.text = "a"',
      '    def __bool__(self):',
      '        return self.text + "b" == "ab"',
      'class Manager:',
      '    def __enter__(self):',
      '        return self',
      '    def __exit__(self, exc_type, exc, traceback):',
      '        events.append("exit")',
      '        return Truth()',
      'try:',
      '    with Manager():',
      '        raise ValueError("handled")',
      'except ValueError:',
      '    events.append("not suppressed")',
      'print(events)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "['exit']\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM dispatches special methods by type and supports user context managers', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class Left:',
      '    def __add__(self, other):',
      '        return NotImplemented',
      'class Right:',
      '    def __radd__(self, other):',
      '        return "reflected"',
      'class Box:',
      '    def __repr__(self):',
      '        return "Box()"',
      '    def __str__(self):',
      '        return "Box str"',
      '    def __len__(self):',
      '        return 7',
      '    def __bool__(self):',
      '        return False',
      '    def __contains__(self, item):',
      '        return item == 3',
      '    def __getitem__(self, item):',
      '        return item + 1',
      '    def __setitem__(self, item, value):',
      '        self.assigned = item + value',
      'box = Box()',
      'box.__repr__ = lambda: "instance shadow"',
      'box.__len__ = lambda: 0',
      'print(box, repr(box), str(box), len(box), bool(box), 3 in box, box[4], Left() + Right())',
      'box[2] = 5',
      'print(box.assigned)',
      'class Counter:',
      '    def __init__(self):',
      '        self.value = 0',
      '    def __iter__(self):',
      '        return self',
      '    def __next__(self):',
      '        if self.value == 3:',
      '            raise StopIteration',
      '        result = self.value',
      '        self.value += 1',
      '        return result',
      'print(list(Counter()))',
      'class Number:',
      '    def __init__(self, value):',
      '        self.value = value',
      '    def __lt__(self, other):',
      '        return self.value < other.value',
      '    def __le__(self, other):',
      '        return self.value <= other.value',
      '    def __gt__(self, other):',
      '        return self.value > other.value',
      '    def __ge__(self, other):',
      '        return self.value >= other.value',
      '    def __ne__(self, other):',
      '        return self.value != other.value',
      'first = Number(1)',
      'second = Number(2)',
      'print(first < second, first <= first, second > first, second >= first, first != second)',
      'class Arithmetic:',
      '    def __init__(self, value):',
      '        self.value = value',
      '    def __add__(self, other):',
      '        return self.value + other',
      '    def __radd__(self, other):',
      '        return other + self.value',
      '    def __sub__(self, other):',
      '        return self.value - other',
      '    def __rsub__(self, other):',
      '        return other - self.value',
      '    def __mul__(self, other):',
      '        return self.value * other',
      '    def __rmul__(self, other):',
      '        return other * self.value',
      '    def __truediv__(self, other):',
      '        return self.value / other',
      '    def __rtruediv__(self, other):',
      '        return other / self.value',
      '    def __floordiv__(self, other):',
      '        return self.value // other',
      '    def __rfloordiv__(self, other):',
      '        return other // self.value',
      '    def __mod__(self, other):',
      '        return self.value % other',
      '    def __rmod__(self, other):',
      '        return other % self.value',
      '    def __pow__(self, other):',
      '        return self.value ** other',
      '    def __rpow__(self, other):',
      '        return other ** self.value',
      'number = Arithmetic(8)',
      'square = Arithmetic(2)',
      'print(number + 2, 2 + number, number - 2, 10 - number, number * 2, 2 * number)',
      'print(number / 2, 16 / number, number // 3, 17 // number, number % 3, 10 % number)',
      'print(square ** 3, 3 ** square)',
      'class EqualValue:',
      '    def __init__(self, value):',
      '        self.value = value',
      '    def __eq__(self, other):',
      '        return self.value == other.value',
      'left = EqualValue(4)',
      'right = EqualValue(4)',
      'print(left == right)',
      'try:',
      '    hash(left)',
      'except TypeError:',
      '    print("unhashable")',
      'class Hashable:',
      '    def __init__(self, value):',
      '        self.value = value',
      '    def __eq__(self, other):',
      '        return self.value == other.value',
      '    def __hash__(self):',
      '        return 42',
      'first = Hashable(7)',
      'same = Hashable(7)',
      'table = {first: "value"}',
      'keys = {first, same}',
      'print(hash(first), table[same], len(keys), same in keys)',
      'events = []',
      'class Manager:',
      '    def __init__(self, name):',
      '        self.name = name',
      '    def __enter__(self):',
      '        events.append("enter:" + self.name)',
      '        return self',
      '    def __exit__(self, exc_type, exc, traceback):',
      '        events.append("exit:" + self.name)',
      '        return exc_type is ValueError',
      'with Manager("outer") as first, Manager("inner") as second:',
      '    events.append("body")',
      'try:',
      '    with Manager("suppress"):',
      '        raise ValueError("caught by exit")',
      'except ValueError:',
      '    events.append("not suppressed")',
      'print(events)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "Box str Box() Box str 7 False True 5 reflected\n7\n[0, 1, 2]\nTrue True True True True\n10 10 6 2 16 16\n4.0 2.0 2 2 2 2\n8 9\nTrue\nunhashable\n42 value 1 True\n['enter:outer', 'enter:inner', 'body', 'exit:inner', 'exit:outer', 'enter:suppress', 'exit:suppress']\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('class programs timeslice and can be cancelled and reused', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class Item:',
      '    def value(self):',
      '        return "ok"',
      'while True:',
      '    method = Item().value',
      '    method()',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    let result = status.timeslice;
    for (let step = 0; step < 40 && result === status.timeslice; step += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.timeslice);
    assert.equal(api.peony_cancel(handle), status.ok);
    assert.equal(api.peony_run(handle, 1), status.cancelled);

    assert.equal(compile(api, handle, 'class Again:\n    pass\nprint(type(Again()) is Again)\n', 'class-reset.py'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'True\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('dynamic type construction and metaclass keywords are explicit exclusions', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'class Dynamic(metaclass=Meta):\n    pass\n'), status.unsupported);
    assert.equal(compile(api, handle, 'type("Dynamic", (), {})\n'), status.unsupported);
    assert.equal(stdout(api, handle), '');
    assert.equal(errorText(api, handle).length > 0, true);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM leaves a shadowed type name callable in module and local scopes', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'type = lambda a, b, c: a + b + c',
      'def call_with_shadow(type):',
      '    return type(4, 5, 6)',
      'print(type(1, 2, 3), call_with_shadow(lambda a, b, c: a + b + c))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '6 15\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM makes a subclass unhashable when it defines equality only', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class Base:',
      '    def __hash__(self):',
      '        return 19',
      'class Derived(Base):',
      '    def __eq__(self, other):',
      '        return True',
      'try:',
      '    hash(Derived())',
      'except TypeError:',
      '    print("unhashable")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'unhashable\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM dict equality tries the user lookup key right equality', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class Key:',
      '    def __hash__(self):',
      '        return 1',
      '    def __eq__(self, other):',
      '        return other == 1',
      'print({1: "hit"}.get(Key(), "miss"))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'hit\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM dict string keys try the user lookup key right equality', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class Key:',
      '    def __hash__(self):',
      '        return hash("a")',
      '    def __eq__(self, other):',
      '        return other == "a"',
      'key = Key()',
      'print(hash(key) == hash("a"), {"a": "hit"}.get(key, "miss"))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'True hit\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM gives a right subclass reflected method priority', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class A:',
      '    def __add__(self, other):',
      '        return "left"',
      'class B(A):',
      '    def __radd__(self, other):',
      '        return "right"',
      'print(A() + B())',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'right\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM containment falls back to a user iterator', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class C:',
      '    def __iter__(self):',
      '        return iter([1, 2])',
      'print(2 in C())',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'True\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM roots a fresh iterator item during allocating user equality', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class Candidate:',
      '    def __eq__(self, other):',
      '        junk = [str(index) for index in range(2000)]',
      '        return other == 7',
      'class C:',
      '    def __iter__(self):',
      '        return self',
      '    def __next__(self):',
      '        return Candidate()',
      'print(7 in C())',
    ].join('\n');
    assert.equal(compile(api, handle, source, 'contains-allocating-equality.py'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'True\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM reports suspended membership iteration as catchable and recovers at quantum one', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'class C:',
      '    def __iter__(self):',
      '        return (value for value in range(10))',
      'items = (2 in C() for _ in range(1))',
      'try:',
      '    print(list(items))',
      'except RuntimeError as error:',
      '    print(str(error))',
    ].join('\n');
    assert.equal(compile(api, handle, source, 'contains-suspended.py'), status.ok);
    let result = status.timeslice;
    for (let step = 0; step < 10000 && result === status.timeslice; step += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(stdout(api, handle), 'iterator suspended during membership test\n');

    assert.equal(compile(api, handle, "print('recovered')\n", 'contains-suspended-recovery.py'), status.ok);
    result = status.timeslice;
    for (let step = 0; step < 1000 && result === status.timeslice; step += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(stdout(api, handle), 'recovered\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});
