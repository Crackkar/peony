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
  outOfMemory: 4,
  completed: 5,
  pythonException: 6,
  timeslice: 7,
  cancelled: 8,
  internalError: 9,
});

async function newApi() {
  const bytes = await readFile(wasmPath);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return instance.exports;
}

function writeTransfer(api, value) {
  const bytes = new TextEncoder().encode(value);
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0, 'transfer allocation succeeds');
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(api, handle, source, filename = 'main.py') {
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
  if (length === 0) return '';
  return new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length));
}

function stdout(api, handle) {
  return borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle);
}

function errorText(api, handle) {
  return borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle);
}

test('WASM compiles and runs straight-line Python, then resets its output', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'answer = 6 * 7\nprint(answer, None, True)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '42 None True\n');
    const length = api.peony_stdout_len(handle);
    assert.equal(api.peony_stdout_consume(handle, length), status.ok);
    assert.equal(api.peony_stdout_len(handle), 0);

    assert.equal(compile(api, handle, 'print("fresh")\n'), status.ok);
    assert.equal(api.peony_stdout_len(handle), 0, 'compile reset clears prior output');
    assert.equal(api.peony_run(handle, 100), status.completed);
    assert.equal(stdout(api, handle), 'fresh\n');

    assert.equal(compile(api, handle, 'print(1 / 0)\n'), status.ok);
    assert.equal(api.peony_run(handle, 100), status.pythonException);
    assert.match(errorText(api, handle), /ZeroDivisionError: division by zero/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM timeslices resume without replaying output, and cancellation is distinct', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'print("one")\nprint("two")\nprint("three")\n'), status.ok);
    let runStatus = api.peony_run(handle, 1);
    assert.equal(runStatus, status.timeslice);
    let observed = '';
    for (let resumes = 0; resumes < 20 && runStatus === status.timeslice; resumes += 1) {
      const chunk = stdout(api, handle);
      observed += chunk;
      if (chunk.length > 0) assert.equal(api.peony_stdout_consume(handle, new TextEncoder().encode(chunk).length), status.ok);
      runStatus = api.peony_run(handle, 1);
    }
    observed += stdout(api, handle);
    assert.equal(runStatus, status.completed);
    assert.equal(observed, 'one\ntwo\nthree\n');

    assert.equal(compile(api, handle, 'print("must not run")\n'), status.ok);
    assert.equal(api.peony_cancel(handle), status.ok);
    assert.equal(api.peony_run(handle, 1), status.cancelled);
    assert.equal(stdout(api, handle), '');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM session output is isolated and branches execute between runs', async () => {
  const api = await newApi();
  const first = api.peony_session_new(0, 0);
  const second = api.peony_session_new(0, 0);
  assert.ok(first > 0 && second > 0 && first !== second);
  try {
    assert.equal(compile(api, first, 'print("left")\n'), status.ok);
    assert.equal(compile(api, second, 'print("right")\n'), status.ok);
    assert.equal(api.peony_run(first, 100), status.completed);
    assert.equal(stdout(api, first), 'left\n');
    assert.equal(api.peony_stdout_len(second), 0);
    assert.equal(api.peony_run(second, 100), status.completed);
    assert.equal(stdout(api, second), 'right\n');

    assert.equal(compile(api, first, 'if True:\n    print(1)\n'), status.ok);
    assert.equal(api.peony_run(first, 100), status.completed);
    assert.equal(stdout(api, first), '1\n');
    assert.equal(compile(api, first, 'print("works again")\n'), status.ok);
    assert.equal(api.peony_run(first, 100), status.completed);
    assert.equal(stdout(api, first), 'works again\n');
  } finally {
    api.peony_session_destroy(first);
    api.peony_session_destroy(second);
  }
});
