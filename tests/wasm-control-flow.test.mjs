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

function compile(api, handle, source, filename = 'control-flow.py') {
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

test('WASM executes branches, loops, nested calls, range repr and Unicode iteration', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  const source = [
    'score = 0',
    'for n in range(4):',
    '    if n == 1:',
    '        continue',
    '    if n == 3:',
    '        break',
    '    score += n',
    'else:',
    '    print("broken for-else")',
    'print(score)',
    'index = 0',
    'while index < 2:',
    '    print(index)',
    '    index += 1',
    'else:',
    '    print("while-else")',
    'for character in "A\\u96ea":',
    '    print(character)',
    'print(range(1, 5, 2))',
    'print(1, print(2), 3)',
  ].join('\n');
  try {
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '2\n0\n1\nwhile-else\nA\n\u96ea\nrange(1, 5, 2)\n2\n1 None 3\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM loop back edges timeslice cleanly and infinite loops cancel', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'for item in range(5):\n    print(item)\n'), status.ok);
    let runStatus = api.peony_run(handle, 1);
    let observed = '';
    for (let resumes = 0; resumes < 200 && runStatus === status.timeslice; resumes += 1) {
      const chunk = stdout(api, handle);
      observed += chunk;
      if (chunk.length > 0) {
        assert.equal(api.peony_stdout_consume(handle, new TextEncoder().encode(chunk).length), status.ok);
      }
      runStatus = api.peony_run(handle, 1);
    }
    observed += stdout(api, handle);
    assert.equal(runStatus, status.completed);
    assert.equal(observed, '0\n1\n2\n3\n4\n');

    assert.equal(compile(api, handle, 'while True:\n    pass\n'), status.ok);
    assert.equal(api.peony_run(handle, 1), status.timeslice);
    assert.equal(api.peony_cancel(handle), status.ok);
    assert.equal(api.peony_run(handle, 1), status.cancelled);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM range failures are Python exceptions and sessions remain isolated', async () => {
  const api = await newApi();
  const first = api.peony_session_new(0, 0);
  const second = api.peony_session_new(0, 0);
  assert.ok(first > 0 && second > 0 && first !== second);
  try {
    assert.equal(compile(api, first, 'for item in range(0, 3, 0):\n    print("bad")\n', 'zero.py'), status.ok);
    assert.equal(api.peony_run(first, 1000), status.pythonException);
    assert.match(errorText(api, first), /File "zero\.py", line 1[\s\S]*ValueError: range\(\) arg 3 must not be zero/);
    assert.equal(stdout(api, first), '');

    assert.equal(compile(api, first, 'range = 7\nfor item in range(2):\n    print("bad")\n', 'shadow.py'), status.ok);
    assert.equal(api.peony_run(first, 1000), status.pythonException);
    assert.match(errorText(api, first), /File "shadow\.py", line 2[\s\S]*TypeError/);
    assert.equal(stdout(api, first), '');

    assert.equal(compile(api, first, 'for left, right in range(2):\n    print("bad")\n'), status.ok);
    assert.equal(api.peony_run(first, 1000), status.pythonException);
    assert.match(errorText(api, first), /File "control-flow\.py", line 1[\s\S]*TypeError/);
    assert.equal(stdout(api, first), '');
    assert.equal(compile(api, second, 'for item in range(2):\n    print(item)\n'), status.ok);
    assert.equal(api.peony_stdout_len(first), 0);
    assert.equal(api.peony_run(second, 0), status.completed);
    assert.equal(stdout(api, second), '0\n1\n');
  } finally {
    api.peony_session_destroy(first);
    api.peony_session_destroy(second);
  }
});
