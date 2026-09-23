import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/bin/peony.wasm', import.meta.url));
const status = Object.freeze({
  ok: 0,
  unsupported: 1,
  invalidHandle: 2,
  invalidArgument: 3,
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

function compile(api, handle, source, filename = 'functions.py') {
  const sourceBlock = writeTransfer(api, source);
  const filenameBlock = writeTransfer(api, filename);
  try {
    return api.peony_compile_and_start(
      handle,
      sourceBlock.pointer,
      sourceBlock.length,
      filenameBlock.pointer,
      filenameBlock.length,
    );
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

test('WASM executes recursive functions, mutable closures and builtin aliases', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  const source = [
    'def factorial(value):',
    '    if value < 2:',
    '        return 1',
    '    return value * factorial(value - 1)',
    'def counter_factory():',
    '    value = 0',
    '    def increment():',
    '        nonlocal value',
    '        value += 1',
    '        return value',
    '    return increment',
    'increment = counter_factory()',
    'printer = print',
    'stepper = range',
    'printer(factorial(6), increment(), increment())',
    'printer(stepper(2))',
    'printer("a", "b", sep=":", end="!")',
  ].join('\n');
  try {
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '720 1 2\nrange(0, 2)\na:b!');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM evaluates definition-time defaults and annotations and reports binder errors', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'def mark(label):',
      '    print(label)',
      '    return label',
      'def choose(a=mark("a-default"), b: mark("b-annotation")=mark("b-default")) -> mark("return-annotation"):',
      '    return a',
      'print(choose(), choose())',
      'def total(a, /, b=2, *, c=3):',
      '    return a + b + c',
      'print(total(1, c=4))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'a-default\nb-default\nb-annotation\nreturn-annotation\na-default a-default\n7\n');

    assert.equal(compile(api, handle, 'def one(value):\n    return value\none(1, 2)\n', 'too-many.py'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /TypeError.*too-many\.py:3:/);

    assert.equal(compile(api, handle, 'print("must not execute")\ndef collect(*items):\n    return items\n'), status.unsupported);
    assert.equal(stdout(api, handle), '');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM timeslices nested frames without replay, cancellation resets calls, and sessions isolate globals', async () => {
  const api = await newApi();
  const first = api.peony_session_new(0, 0);
  const second = api.peony_session_new(0, 0);
  assert.ok(first > 0 && second > 0 && first !== second);
  try {
    const source = [
      'def descend(value):',
      '    print(value)',
      '    if value == 0:',
      '        return 0',
      '    return descend(value - 1) + value',
      'print(descend(4))',
    ].join('\n');
    assert.equal(compile(api, first, source), status.ok);
    let runStatus = api.peony_run(first, 1);
    let observed = '';
    for (let resumes = 0; resumes < 1000 && runStatus === status.timeslice; resumes += 1) {
      const chunk = stdout(api, first);
      observed += chunk;
      if (chunk.length > 0) assert.equal(api.peony_stdout_consume(first, new TextEncoder().encode(chunk).length), status.ok);
      runStatus = api.peony_run(first, 1);
    }
    observed += stdout(api, first);
    assert.equal(runStatus, status.completed);
    assert.equal(observed, '4\n3\n2\n1\n0\n10\n');

    assert.equal(compile(api, first, 'def spin():\n    while True:\n        pass\ndef invoke():\n    spin()\ninvoke()\n'), status.ok);
    assert.equal(api.peony_run(first, 12), status.timeslice);
    assert.equal(api.peony_cancel(first), status.ok);
    assert.equal(api.peony_run(first, 1), status.cancelled);
    assert.equal(compile(api, first, 'print("clean after cancel")\n'), status.ok);
    assert.equal(api.peony_run(first, 0), status.completed);
    assert.equal(stdout(api, first), 'clean after cancel\n');

    assert.equal(compile(api, first, 'def secret():\n    return 42\nprint(secret())\n'), status.ok);
    assert.equal(api.peony_run(first, 0), status.completed);
    assert.equal(stdout(api, first), '42\n');
    assert.equal(compile(api, second, 'print(secret())\n'), status.ok);
    assert.equal(api.peony_run(second, 0), status.pythonException);
    assert.match(errorText(api, second), /NameError.*functions\.py:1:/);
  } finally {
    api.peony_session_destroy(first);
    api.peony_session_destroy(second);
  }
});
