import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, unsupported: 1, completed: 5, pythonException: 6 });

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

function compile(api, handle, source, filename = 'match.py') {
  const sourceBlock = writeTransfer(api, source);
  const filenameBlock = writeTransfer(api, filename);
  try {
    return api.peony_compile_and_start(handle, sourceBlock.pointer, sourceBlock.length, filenameBlock.pointer, filenameBlock.length);
  } finally {
    api.peony_transfer_free(sourceBlock.pointer, sourceBlock.length);
    api.peony_transfer_free(filenameBlock.pointer, filenameBlock.length);
  }
}

function stdout(api, handle) {
  const pointer = api.peony_stdout_ptr(handle);
  const length = api.peony_stdout_len(handle);
  return length === 0 ? '' : new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length));
}

test('shipping WASM executes literal, singleton, capture, OR, guard, and soft-keyword match cases', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'events = []',
      'def subject():',
      '    events.append("subject")',
      '    return 3',
      'def guard(value):',
      '    events.append("guard")',
      '    return value == 3',
      'match subject():',
      '    case 1:',
      '        events.append("literal")',
      '    case 2 | 3:',
      '        events.append("or")',
      '    case _:',
      '        events.append("wildcard")',
      'match subject():',
      '    case value if guard(value):',
      '        events.append("capture")',
      '    case _:',
      '        events.append("fallthrough")',
      'match False:',
      '    case True:',
      '        events.append("true")',
      '    case False:',
      '        events.append("false")',
      'match = 8',
      'case = 9',
      'print(events, match, case)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "['subject', 'or', 'subject', 'guard', 'capture', 'false'] 8 9\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM matches singleton patterns by identity', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'match 1:',
      '    case True:',
      '        print("wrong true")',
      '    case _:',
      '        print("integer one")',
      'match 0:',
      '    case False:',
      '        print("wrong false")',
      '    case _:',
      '        print("integer zero")',
      'match True:',
      '    case 1:',
      '        print("numeric literal equality")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'integer one\ninteger zero\nnumeric literal equality\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM accepts signed numeric match patterns', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'match 0:',
      '    case -1:',
      '        print("wrong integer")',
      '    case -1.5:',
      '        print("wrong float")',
      '    case _:',
      '        print("zero")',
      'match -1:',
      '    case -1:',
      '        print("negative integer")',
      'match -1.5:',
      '    case -1.5:',
      '        print("negative float")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'zero\nnegative integer\nnegative float\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM rejects irrefutable OR alternatives before execution', async () => {
  for (const source of [
    'print("must not run")\nmatch 1:\n    case x | x:\n        pass\n',
    'print("must not run")\nmatch 1:\n    case _ | _:\n        pass\n',
  ]) {
    const api = await newApi();
    const handle = api.peony_session_new(0, 0);
    assert.ok(handle > 0);
    try {
      assert.equal(compile(api, handle, source), status.pythonException);
      assert.equal(stdout(api, handle), '');
    } finally {
      api.peony_session_destroy(handle);
    }
  }
});

test('shipping WASM diagnoses parenthesized sequence patterns explicitly', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'print("must not run")\nmatch 1:\n    case (left, right):\n        pass\n'), status.unsupported);
    assert.equal(stdout(api, handle), '');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM rejects excluded pattern forms before executing the module', async () => {
  for (const source of [
    "print('must not run')\nmatch value:\n    case [item]:\n        pass\n",
    "print('must not run')\nmatch value:\n    case {'key': item}:\n        pass\n",
    "print('must not run')\nmatch value:\n    case Point(item):\n        pass\n",
  ]) {
    const api = await newApi();
    const handle = api.peony_session_new(0, 0);
    assert.ok(handle > 0);
    try {
      assert.equal(compile(api, handle, source), status.unsupported);
      assert.equal(stdout(api, handle), '');
    } finally {
      api.peony_session_destroy(handle);
    }
  }
});
