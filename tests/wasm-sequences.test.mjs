import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/bin/peony.wasm', import.meta.url));
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

function compile(api, handle, source, filename = 'sequences.py') {
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

test('WASM mutates lists and executes tuple, slice, string and bytes operations', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'items = [3, 1, 2]','alias = items','items.append(4)','items.extend([5, 6])','items.insert(1, 9)',
      'print(alias)','print(items.pop(), items.pop(1), items)','items.sort(reverse=True)','print(items)',
      'print((1, "a") + (2,), [0, 1, 2, 3][::-1])','text = "A雪B𝄞"','print(len(text), text[-1], text.find("B"))',
      'payload = "A雪".encode()','print(payload, payload[::-1], payload.decode())',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '[3, 9, 1, 2, 4, 5, 6]\n6 9 [3, 1, 2, 4, 5]\n[5, 4, 3, 2, 1]\n(1, \'a\', 2) [3, 2, 1, 0]\n4 𝄞 2\nb\'A\\xe9\\x9b\\xaa\' b\'\\xaa\\x9b\\xe9A\' A雪\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM extends lists from ranges, strings and existing iterators', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'values = []',
      'values.extend(range(3))',
      'values.extend("ab")',
      'cursor = iter(range(5, 7))',
      'values.extend(cursor)',
      'print(values)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "[0, 1, 2, 'a', 'b', 5, 6]\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM str.split without a separator uses Unicode whitespace', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = String.raw`print(" \tA\u2003B\n\u00a0".split(), " \u2003".split())` + '\n';
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "['A', 'B'] []\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM bytes truthiness follows its length', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'if b"":',
      '    print("bad empty bytes")',
      'else:',
      '    print("empty")',
      'if b"x":',
      '    print("nonempty")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'empty\nnonempty\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM bytes containment handles integer and bytes probes', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, String.raw`print(True in b"\x01a", b"a" in b"\x01a")` + '\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'True True\n');

    assert.equal(compile(api, handle, 'print(256 in b"a")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "sequences\.py", line 1[\s\S]*ValueError/);

    assert.equal(compile(api, handle, 'print("a" in b"a")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "sequences\.py", line 1[\s\S]*TypeError/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM list pop and sort keyword bounds match Python', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'items = [1]\nitems.pop(10 ** 100)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "sequences\.py", line 2[\s\S]*OverflowError/);

    assert.equal(compile(api, handle, 'items = [2, 1]\nitems.sort(reverse=1)\nprint(items)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '[2, 1]\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM iterates ranges and mutable sequences and expands positional iterables', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'def collect(first, *items, flag):','    return (first, items, flag)','print(collect(*[1, 2, 3], flag=4))',
      'items = [1, 2, 3]','for value in items:','    print(value)','    if value == 2:','        items.append(4)',
      'print(list(enumerate("A雪", 2)))','print(list(zip([1, 2], ("a", "b"))))','print(list(reversed([3, 4])))',
      'base = 10 ** 100','print(range(base, base + 4, 2)[-1] == base + 2)',
      'print(2.0 ** 200 in range(2 ** 200, 2 ** 200 + 1))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    let runStatus = api.peony_run(handle, 2);
    for (let count = 0; count < 1000 && runStatus === status.timeslice; count += 1) runStatus = api.peony_run(handle, 2);
    assert.equal(runStatus, status.completed);
    assert.equal(stdout(api, handle), '(1, (2, 3), 4)\n1\n2\n3\n4\n[(2, \'A\'), (3, \'雪\')]\n[(1, \'a\'), (2, \'b\')]\n[4, 3]\nTrue\nTrue\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM rejects bad sequence operations and supports empty **call expansion', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'print([1, 2][::0])\n', 'step-zero.py'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "step-zero\.py", line 1[\s\S]*ValueError/);

    assert.equal(compile(api, handle, 'print("before")\nprint(1, **{})\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'before\n1\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM sequence bounds match the shared 64-bit Python integer model', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'items = [1]\nitems.insert(2 ** 40, 2)\nprint(items, [] * (2 ** 40), () * (2 ** 40))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '[1, 2] [] ()\n');

    assert.equal(compile(api, handle, 'print(len(range(2 ** 40)))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '1099511627776\n');

    assert.equal(compile(api, handle, 'print(len(range(2 ** 63)))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "sequences\.py", line 1[\s\S]*OverflowError/);

    assert.equal(compile(api, handle, 'print([1] * (2 ** 40))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "sequences\.py", line 1[\s\S]*MemoryError/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM repeats list and tuple values when the integer is on the left', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'print(2 * [1], 2 * (1,))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '[1, 1] (1, 1)\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM starred unpack sizes a known large range exactly', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'head, *rest = range(70000)\nprint(head, len(rest), rest[-1])\n'), status.ok);
    let runStatus = api.peony_run(handle, 50000);
    for (let count = 0; count < 10 && runStatus === status.timeslice; count += 1) runStatus = api.peony_run(handle, 50000);
    assert.equal(runStatus, status.completed);
    assert.equal(stdout(api, handle), '0 69999 69999\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM bounds recursive structural equality with RecursionError', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = 'left = []\nleft.append(left)\nright = []\nright.append(right)\nprint(left == right)\n';
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "sequences\.py", line 5[\s\S]*RecursionError/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM repr escapes control bytes, selects readable quotes and bounds nesting', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, String.raw`print(["it's", "\x01", "\x7f", b"it's", b"\x01"])` + '\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), String.raw`["it's", '\x01', '\x7f', b"it's", b'\x01']` + '\n');

    const nested = 'value = []\nfor index in range(130):\n    value = [value]\nprint(value)\n';
    assert.equal(compile(api, handle, nested), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "sequences\.py", line 4[\s\S]*RecursionError/);
  } finally {
    api.peony_session_destroy(handle);
  }
});
