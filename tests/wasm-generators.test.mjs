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
  hostRequest: 10,
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

function compile(api, handle, source, filename = 'generators.py') {
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

function encodeInput(requestId, text) {
  const payload = new TextEncoder().encode(text);
  const packet = new Uint8Array(36 + payload.length);
  const view = new DataView(packet.buffer);
  packet.set([0x50, 0x45, 0x4f, 0x4e]);
  view.setUint16(4, 1, true);
  view.setUint16(6, 1, true);
  view.setUint32(8, requestId, true);
  view.setUint16(12, 0, true);
  view.setUint16(16, 1, true);
  view.setUint32(20, packet.length, true);
  view.setUint16(24, 1, true);
  view.setUint32(28, 36, true);
  view.setUint32(32, payload.length, true);
  packet.set(payload, 36);
  return packet;
}

function resume(api, handle, packet) {
  const block = api.peony_transfer_alloc(packet.length);
  assert.ok(block > 0);
  new Uint8Array(api.memory.buffer, block, packet.length).set(packet);
  try {
    return api.peony_resume(handle, block, packet.length);
  } finally {
    api.peony_transfer_free(block, packet.length);
  }
}

test('shipping WASM generators preserve send values and StopIteration.value', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'events = []',
      'def exchange():',
      '    events.append("started")',
      '    first = yield "ready"',
      '    second = yield first',
      '    return second',
      'generator = exchange()',
      'print("created", events)',
      'try:',
      '    generator.send(9)',
      'except TypeError:',
      '    print("initial send rejected")',
      'print(generator.send(None))',
      'print(next(generator))',
      'try:',
      '    generator.send(4)',
      'except StopIteration as stopped:',
      '    print("returned", stopped.value)',
      'try:',
      '    next(generator)',
      'except StopIteration as stopped:',
      '    print("exhausted", stopped.value)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    let result = status.timeslice;
    for (let step = 0; step < 10000 && result === status.timeslice; step += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(stdout(api, handle), 'created []\ninitial send rejected\nready\nNone\nreturned 4\nexhausted None\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM close runs finally once and rejects yielding during close', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'def closeable():',
      '    try:',
      '        yield "ready"',
      '        yield "later"',
      '    finally:',
      '        print("finally")',
      'generator = closeable()',
      'print(next(generator))',
      'generator.close()',
      'generator.close()',
      'print("closed")',
      'def invalid_close():',
      '    try:',
      '        yield "ready"',
      '    finally:',
      '        yield "not allowed"',
      'broken = invalid_close()',
      'next(broken)',
      'try:',
      '    broken.close()',
      'except RuntimeError:',
      '    print("yield rejected")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'ready\nfinally\nclosed\nyield rejected\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM preserves a generator handler continuation across quantum one', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'def source():',
      '    try:',
      '        sent = yield "ready"',
      '        if sent:',
      '            raise ValueError("inside")',
      '    except ValueError:',
      '        yield "caught inside"',
      '    raise TypeError("outside")',
      'generator = source()',
      'print(next(generator))',
      'print(generator.send(True))',
      'try:',
      '    next(generator)',
      'except TypeError:',
      '    print("caller caught")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    let result = status.timeslice;
    for (let step = 0; step < 10000 && result === status.timeslice; step += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(stdout(api, handle), 'ready\ncaught inside\ncaller caught\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM generator resumes across input without replay at quantum one', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'def conversation():',
      '    sent = yield "ready"',
      '    name = input("Name: ")',
      '    yield sent',
      '    yield name',
      'generator = conversation()',
      'first = next(generator)',
      'second = generator.send("token")',
      'third = next(generator)',
      'print(first, second, third)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    let result = status.timeslice;
    for (let step = 0; step < 10000 && result === status.timeslice; step += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.hostRequest);
    const eventPointer = api.peony_event_ptr(handle);
    const eventLength = api.peony_event_len(handle);
    const event = new Uint8Array(api.memory.buffer, eventPointer, eventLength);
    const view = new DataView(event.buffer, event.byteOffset, event.byteLength);
    const requestId = view.getUint32(8, true);
    assert.ok(requestId > 0);
    assert.equal(resume(api, handle, encodeInput(requestId, 'Ada')), status.ok);
    result = status.timeslice;
    for (let step = 0; step < 10000 && result === status.timeslice; step += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(stdout(api, handle), 'Name: ready token Ada\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});
