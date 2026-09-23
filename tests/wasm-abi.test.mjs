import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/bin/peony.wasm', import.meta.url));

async function instantiateBytes() {
  const bytes = await readFile(wasmPath);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return { bytes, instance };
}

test('ABI v1 exports linear memory and the documented entry points', async () => {
  const { instance } = await instantiateBytes();
  const exports = instance.exports;

  assert.equal(exports.peony_abi_version(), 1);
  assert.ok(exports.memory instanceof WebAssembly.Memory);
  for (const name of [
    'peony_transfer_alloc',
    'peony_transfer_free',
    'peony_session_new',
    'peony_session_destroy',
    'peony_compile_and_start',
    'peony_run',
    'peony_resume',
    'peony_cancel',
    'peony_event_ptr',
    'peony_event_len',
    'peony_stdout_ptr',
    'peony_stdout_len',
    'peony_stdout_consume',
    'peony_stderr_ptr',
    'peony_stderr_len',
    'peony_stderr_consume',
    'peony_error_ptr',
    'peony_error_len',
  ]) {
    assert.equal(typeof exports[name], 'function', `missing export ${name}`);
  }
});

test('transfer allocator returns writable memory and accepts the matching free', async () => {
  const { instance } = await instantiateBytes();
  const { memory, peony_transfer_alloc: alloc, peony_transfer_free: free } = instance.exports;
  const bytes = Uint8Array.of(0x50, 0x65, 0x6f, 0x6e, 0x79);
  const ptr = alloc(bytes.length);

  assert.ok(ptr > 0, 'zero is reserved for allocation failure');
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  assert.deepEqual([...new Uint8Array(memory.buffer, ptr, bytes.length)], [...bytes]);
  free(ptr, bytes.length);
});

test('session handles are distinct, stale handles fail, and execution statuses are explicit', async () => {
  const { instance } = await instantiateBytes();
  const api = instance.exports;
  const ok = 0;
  const unsupported = 1;
  const invalidHandle = 2;
  const invalidArgument = 3;
  const first = api.peony_session_new(0, 0);
  const second = api.peony_session_new(0, 0);

  assert.notEqual(first, 0);
  assert.notEqual(second, 0);
  assert.notEqual(first, second);

  const sourcePtr = api.peony_transfer_alloc(8);
  const filenamePtr = api.peony_transfer_alloc(7);
  assert.ok(sourcePtr > 0);
  assert.ok(filenamePtr > 0);
  new Uint8Array(api.memory.buffer, sourcePtr, 8).set(new TextEncoder().encode('print(1)'));
  new Uint8Array(api.memory.buffer, filenamePtr, 7).set(new TextEncoder().encode('main.py'));
  assert.equal(api.peony_compile_and_start(first, sourcePtr, 8, filenamePtr, 7), ok);
  assert.equal(api.peony_run(first, 0), 5);
  const outputPtr = api.peony_stdout_ptr(first);
  assert.equal(new TextDecoder().decode(new Uint8Array(api.memory.buffer, outputPtr, api.peony_stdout_len(first))), '1\n');
  assert.equal(api.peony_compile_and_start(first, 1, 8, 0, 0), invalidArgument);
  assert.equal(api.peony_error_len(first), 0);
  assert.equal(api.peony_resume(first, 0, 0), unsupported);
  assert.equal(api.peony_cancel(first), ok);
  assert.equal(api.peony_run(first, 1), 8);
  api.peony_transfer_free(sourcePtr, 8);
  api.peony_transfer_free(filenamePtr, 7);
  assert.equal(api.peony_compile_and_start(first, sourcePtr, 8, 0, 0), invalidArgument);
  assert.equal(api.peony_error_len(first), 0);
  assert.equal(api.peony_session_destroy(first), ok);
  assert.equal(api.peony_run(first, 1), invalidHandle);
  assert.equal(api.peony_session_destroy(first), invalidHandle);
  assert.equal(api.peony_run(second, 1), 5);
  assert.equal(api.peony_session_destroy(second), ok);
  const reusedSlot = api.peony_session_new(0, 0);
  assert.notEqual(reusedSlot, 0);
  assert.notEqual(reusedSlot, first);
  assert.equal(api.peony_run(first, 1), invalidHandle);
  assert.equal(api.peony_run(reusedSlot, 1), 5);
  assert.equal(api.peony_session_destroy(reusedSlot), ok);
});

test('memory views are reacquired after linear memory grows', async () => {
  const { instance } = await instantiateBytes();
  const { memory } = instance.exports;
  const previousBuffer = memory.buffer;
  const previousView = new Uint8Array(previousBuffer);

  memory.grow(1);

  assert.notEqual(memory.buffer, previousBuffer);
  assert.equal(previousView.byteLength, 0, 'the old typed view is detached');
  const freshView = new Uint8Array(memory.buffer);
  assert.equal(freshView.byteLength, memory.buffer.byteLength);
  assert.notEqual(freshView, previousView);
});

test('shipping artifact instantiates from bytes and streaming with the WASM MIME type', async () => {
  const { bytes } = await instantiateBytes();
  const response = new Response(bytes, {
    headers: { 'Content-Type': 'application/wasm' },
  });
  const { instance } = await WebAssembly.instantiateStreaming(response, {});

  assert.equal(instance.exports.peony_abi_version(), 1);
  assert.ok(instance.exports.memory instanceof WebAssembly.Memory);
});
