import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({
  ok: 0,
  invalidHandle: 2,
  invalidArgument: 3,
  completed: 5,
  pythonException: 6,
  timeslice: 7,
  cancelled: 8,
  internalError: 9,
  hostRequest: 10,
  outputEvent: 11,
  limit: 12,
});

async function newApi() {
  const bytes = await readFile(wasmPath);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return instance.exports;
}

function writeTransfer(api, bytes) {
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(api, handle, source, filename = 'host.py') {
  const encodedSource = writeTransfer(api, new TextEncoder().encode(source));
  const encodedFilename = writeTransfer(api, new TextEncoder().encode(filename));
  try {
    return api.peony_compile_and_start(handle, encodedSource.pointer, encodedSource.length, encodedFilename.pointer, encodedFilename.length);
  } finally {
    api.peony_transfer_free(encodedSource.pointer, encodedSource.length);
    api.peony_transfer_free(encodedFilename.pointer, encodedFilename.length);
  }
}

function borrowedText(api, pointerExport, lengthExport, handle) {
  const pointer = pointerExport(handle);
  const length = lengthExport(handle);
  return length === 0 ? '' : new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length));
}

function encodePacket({ kind = 1, requestId, statusCode = 0, text }) {
  const payload = text === undefined ? null : new TextEncoder().encode(text);
  const headerSize = 24;
  const descriptorSize = payload === null ? 0 : 12;
  const payloadOffset = headerSize + descriptorSize;
  const packet = new Uint8Array(payloadOffset + (payload?.length ?? 0));
  const view = new DataView(packet.buffer);
  packet.set([0x50, 0x45, 0x4f, 0x4e]); // PEON
  view.setUint16(4, 1, true);
  view.setUint16(6, kind, true);
  view.setUint32(8, requestId, true);
  view.setUint16(12, statusCode, true);
  view.setUint16(14, 0, true);
  view.setUint16(16, payload === null ? 0 : 1, true);
  view.setUint16(18, 0, true);
  view.setUint32(20, packet.length, true);
  if (payload !== null) {
    view.setUint16(24, 1, true); // UTF-8 section
    view.setUint16(26, 0, true);
    view.setUint32(28, payloadOffset, true);
    view.setUint32(32, payload.length, true);
    packet.set(payload, payloadOffset);
  }
  return packet;
}

function decodePacket(packet) {
  assert.equal(new TextDecoder().decode(packet.subarray(0, 4)), 'PEON');
  const view = new DataView(packet.buffer, packet.byteOffset, packet.byteLength);
  assert.equal(view.getUint16(4, true), 1);
  assert.equal(view.getUint32(20, true), packet.length);
  const sections = [];
  const count = view.getUint16(16, true);
  for (let index = 0; index < count; index += 1) {
    const descriptor = 24 + index * 12;
    const type = view.getUint16(descriptor, true);
    const offset = view.getUint32(descriptor + 4, true);
    const length = view.getUint32(descriptor + 8, true);
    assert.ok(offset >= 24 + count * 12);
    assert.ok(offset + length <= packet.length);
    sections.push({ type, bytes: packet.slice(offset, offset + length) });
  }
  return {
    kind: view.getUint16(6, true),
    requestId: view.getUint32(8, true),
    statusCode: view.getUint16(12, true),
    sections,
  };
}

function resumeWith(api, handle, packet) {
  const block = writeTransfer(api, packet);
  try {
    return api.peony_resume(handle, block.pointer, block.length);
  } finally {
    api.peony_transfer_free(block.pointer, block.length);
  }
}

function configBytes({ maxMemoryBytes = 8 * 1024 * 1024, maxInstructions = 50_000_000n, quantum = 50_000, seed = new Uint8Array() } = {}) {
  const encoded = new Uint8Array(28 + seed.length);
  const view = new DataView(encoded.buffer);
  encoded.set([0x50, 0x43, 0x46, 0x47]); // PCFG
  view.setUint16(4, 1, true);
  view.setUint16(6, seed.length === 0 ? 0 : 1, true);
  view.setUint32(8, maxMemoryBytes, true);
  view.setBigUint64(12, BigInt(maxInstructions), true);
  view.setUint32(20, quantum, true);
  view.setUint16(24, seed.length, true);
  view.setUint16(26, 0, true);
  encoded.set(seed, 28);
  return encoded;
}

function newSession(api, config = new Uint8Array()) {
  if (config.length === 0) return api.peony_session_new(0, 0);
  const block = writeTransfer(api, config);
  try {
    return api.peony_session_new(block.pointer, block.length);
  } finally {
    api.peony_transfer_free(block.pointer, block.length);
  }
}

function eventBytes(api, handle) {
  const pointer = api.peony_event_ptr(handle);
  const length = api.peony_event_len(handle);
  return length === 0 ? new Uint8Array() : new Uint8Array(api.memory.buffer, pointer, length).slice();
}

test('host ABI appends scheduling statuses and accepts a copied versioned config', async () => {
  const api = await newApi();
  const session = newSession(api, configBytes({ maxInstructions: 321, quantum: 7, seed: Uint8Array.of(1, 2, 3) }));
  assert.ok(session > 0);
  try {
    assert.equal(compile(api, session, 'while True:\n    pass\n'), status.ok);
    let result = status.timeslice;
    for (let i = 0; i < 100 && result === status.timeslice; i += 1) result = api.peony_run(session, 7);
    assert.equal(result, status.limit);
  } finally {
    api.peony_session_destroy(session);
  }

  const invalid = configBytes();
  new DataView(invalid.buffer).setUint16(4, 2, true);
  assert.equal(newSession(api, invalid), 0);
});

test('raw WASM input request validates packet envelopes before consuming the pending call', async () => {
  const api = await newApi();
  const first = newSession(api);
  const second = newSession(api);
  assert.ok(first > 0 && second > 0 && first !== second);
  try {
    assert.equal(compile(api, first, 'name = input("Name: ")\nprint("Hello", name)\n'), status.ok);
    assert.equal(api.peony_run(first, 0), status.hostRequest);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, first), 'Name: ');

    const originalPacket = eventBytes(api, first);
    const request = decodePacket(originalPacket);
    assert.equal(request.kind, 1);
    assert.ok(request.requestId > 0);
    assert.equal(request.statusCode, 0);
    assert.equal(request.sections.length, 1);
    assert.equal(request.sections[0].type, 1);
    assert.equal(new TextDecoder().decode(request.sections[0].bytes), 'Name: ');

    const valid = encodePacket({ requestId: request.requestId, text: 'Ada\r\n' });
    const oversized = encodePacket({ requestId: request.requestId, text: 'x'.repeat(1024 * 1024) });
    assert.equal(resumeWith(api, first, oversized), status.invalidArgument, 'oversized response is rejected before session mutation');
    assert.deepEqual(eventBytes(api, first), originalPacket, 'oversized response preserves the pending request');
    assert.equal(resumeWith(api, second, valid), status.invalidArgument);
    assert.equal(resumeWith(api, first, encodePacket({ requestId: request.requestId + 1, text: 'wrong' })), status.invalidArgument);
    const malformed = valid.slice();
    malformed[0] ^= 0xff;
    assert.equal(resumeWith(api, first, malformed), status.invalidArgument);
    assert.deepEqual(eventBytes(api, first), originalPacket, 'failed resumes leave the request intact');

    assert.equal(resumeWith(api, first, valid), status.ok);
    assert.equal(resumeWith(api, first, valid), status.invalidArgument, 'duplicate response is rejected');
    assert.equal(api.peony_run(first, 0), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, first), 'Name: Hello Ada\n');
  } finally {
    api.peony_session_destroy(first);
    api.peony_session_destroy(second);
  }
});

test('input resumes into a nested Python frame with quantum one', async () => {
  const api = await newApi();
  const handle = newSession(api);
  try {
    assert.equal(compile(api, handle, 'def ask():\n    return input("Nested: ")\nanswer = ask()\nprint("answer", answer)\n'), status.ok);
    let result = status.timeslice;
    for (let index = 0; index < 1000 && result === status.timeslice; index += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.hostRequest);
    const request = decodePacket(eventBytes(api, handle));
    assert.equal(new TextDecoder().decode(request.sections[0].bytes), 'Nested: ');
    assert.equal(resumeWith(api, handle, encodePacket({ requestId: request.requestId, text: 'Lin\n' })), status.ok);
    result = status.timeslice;
    for (let index = 0; index < 1000 && result === status.timeslice; index += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'Nested: answer Lin\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('raw WASM EOF is a catchable EOFError and host rejection is an OSError', async () => {
  const api = await newApi();
  const handle = newSession(api);
  try {
    assert.equal(compile(api, handle, 'try:\n    input("EOF: ")\nexcept EOFError:\n    print("eof")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.hostRequest);
    const eofRequest = decodePacket(eventBytes(api, handle));
    assert.equal(resumeWith(api, handle, encodePacket({ requestId: eofRequest.requestId, statusCode: 1 })), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'EOF: eof\n');

    assert.equal(compile(api, handle, 'try:\n    input("Host: ")\nexcept OSError as error:\n    print(error)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.hostRequest);
    const errorRequest = decodePacket(eventBytes(api, handle));
    assert.equal(resumeWith(api, handle, encodePacket({ requestId: errorRequest.requestId, statusCode: 2, text: 'denied' })), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.match(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), /denied/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('flush=True returns a drainable output event before later execution', async () => {
  const api = await newApi();
  const handle = newSession(api);
  try {
    assert.equal(compile(api, handle, 'print("ready", flush=True)\nprint("after")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.outputEvent);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'ready\n');
    const outputEvent = decodePacket(eventBytes(api, handle));
    assert.equal(outputEvent.kind, 5);
    assert.equal(outputEvent.sections.length, 0);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'ready\n');
    assert.equal(api.peony_stdout_consume(handle, api.peony_stdout_len(handle)), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'after\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('large flush output uses a small marker packet and preserves borrowed stdout', async () => {
  const api = await newApi();
  const handle = newSession(api, configBytes({ maxMemoryBytes: 16 * 1024 * 1024 }));
  try {
    assert.equal(compile(api, handle, 'print(list(range(200000)), flush=True)\n'), status.ok);
    let result = status.timeslice;
    for (let index = 0; index < 100 && result === status.timeslice; index += 1) result = api.peony_run(handle, 0);
    assert.equal(result, status.outputEvent);
    const output = borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle);
    assert.ok(new TextEncoder().encode(output).length > 1024 * 1024);
    const event = decodePacket(eventBytes(api, handle));
    assert.equal(event.kind, 5);
    assert.equal(event.sections.length, 0);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('wrong-id large response is rejected before capped session allocation', async () => {
  const api = await newApi();
  const handle = newSession(api, configBytes({ maxMemoryBytes: 256 * 1024 }));
  try {
    assert.equal(compile(api, handle, 'answer = input("Name: ")\nprint(answer)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.hostRequest);
    const original = eventBytes(api, handle);
    const request = decodePacket(original);
    const wrongIdLarge = encodePacket({ requestId: request.requestId + 1, text: 'x'.repeat(300 * 1024) });
    assert.equal(resumeWith(api, handle, wrongIdLarge), status.invalidArgument);
    assert.deepEqual(eventBytes(api, handle), original);
    assert.equal(resumeWith(api, handle, encodePacket({ requestId: request.requestId, text: 'Ada' })), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'Name: Ada\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('hard cancellation while input is pending skips finally and invalidates late replies', async () => {
  const api = await newApi();
  const handle = newSession(api);
  try {
    assert.equal(compile(api, handle, 'try:\n    input("stop: ")\nfinally:\n    print("must not run")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.hostRequest);
    const request = decodePacket(eventBytes(api, handle));
    assert.equal(api.peony_cancel(handle), status.ok);
    assert.equal(api.peony_run(handle, 1), status.cancelled);
    assert.equal(resumeWith(api, handle, encodePacket({ requestId: request.requestId, text: 'late' })), status.invalidArgument);
    assert.equal(compile(api, handle, 'print("recovered")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'recovered\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('real WASM preserves multi-source map values when a generator source suspends', async () => {
  const api = await newApi();
  const handle = newSession(api);
  try {
    assert.equal(compile(api, handle, [
      'def combine(left, right):',
      '    print("pair", left, right)',
      '    return left + right',
      'source = (print("source", value) or value for value in [10, 20])',
      'result = list(map(combine, [1, 2], source))',
      'print(result)',
      '',
    ].join('\n')), status.ok);
    let result = status.timeslice;
    for (let index = 0; index < 2000 && result === status.timeslice; index += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'source 10\npair 1 10\nsource 20\npair 2 20\n[11, 22]\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('real WASM preempts a long Python map callback and cancels without finally', async () => {
  const api = await newApi();
  const handle = newSession(api);
  try {
    assert.equal(compile(api, handle, [
      'def visit(value):',
      '    for index in range(1000):',
      '        pass',
      '    print("callback done")',
      '    return value',
      'print("before")',
      'try:',
      '    result = list(map(visit, [1]))',
      'finally:',
      '    print("finally")',
      '',
    ].join('\n')), status.ok);
    let result = status.timeslice;
    for (let index = 0; index < 100 && result === status.timeslice && !borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle); index += 1) {
      result = api.peony_run(handle, 1);
    }
    assert.equal(result, status.timeslice);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'before\n');
    for (let index = 0; index < 20; index += 1) assert.equal(api.peony_run(handle, 1), status.timeslice);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'before\n');
    assert.equal(api.peony_cancel(handle), status.ok);
    assert.equal(api.peony_run(handle, 1), status.cancelled);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'before\n');
    assert.equal(compile(api, handle, 'print("recovered")\n'), status.ok);
    assert.equal(api.peony_run(handle, 10), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'recovered\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('nested callback materialization obeys the configured native-work limit', async () => {
  const api = await newApi();
  const handle = newSession(api, configBytes({ maxInstructions: 200n }));
  try {
    assert.equal(compile(api, handle, [
      'def key(value):',
      '    items = list(range(100000))',
      '    print("materialized")',
      '    return value',
      'values = [2, 1]',
      'print("before")',
      'values.sort(key=key)',
      'print("after")',
      '',
    ].join('\n')), status.ok);
    assert.equal(api.peony_run(handle, 0), status.limit);
    assert.ok(api.peony_work_count(handle) <= 200);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'before\n');
    assert.equal(compile(api, handle, 'print("recovered")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'recovered\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('raw WASM enumerate and zip resume generator and map children at quantum one', async () => {
  const api = await newApi();
  const handle = newSession(api);
  try {
    assert.equal(compile(api, handle, [
      'def identity(value):',
      '    return value',
      'print(list(enumerate((value for value in range(3)), 4)))',
      'print(list(enumerate(map(identity, (value for value in range(2))), 7)))',
      'print(list(zip((value for value in range(3)), (value for value in range(3, 6)))))',
      'print(list(zip([10, 20, 30], (value for value in range(3, 6)))))',
      'print(list(zip((value for value in range(3)), map(identity, [10, 20, 30]))))',
      'print(list(zip()))',
      '',
    ].join('\n')), status.ok);
    let result = status.timeslice;
    for (let index = 0; index < 5000 && result === status.timeslice; index += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle),
      '[(4, 0), (5, 1), (6, 2)]\n[(7, 0), (8, 1)]\n[(0, 3), (1, 4), (2, 5)]\n[(10, 3), (20, 4), (30, 5)]\n[(0, 10), (1, 20), (2, 30)]\n[]\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('raw WASM repetition observes the native-work cap and recovers', async () => {
  const api = await newApi();
  const handle = newSession(api, configBytes({ maxInstructions: 30n, quantum: 1000 }));
  try {
    assert.equal(compile(api, handle, 'items = [0] * 100000\nprint(len(items))\n'), status.ok);
    assert.equal(api.peony_run(handle, 1000), status.limit);
    assert.ok(api.peony_work_count(handle) <= 30n);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), '');

    assert.equal(compile(api, handle, 'print(len([0] * 5))\n'), status.ok);
    assert.equal(api.peony_run(handle, 1000), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), '5\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('sequence repetition keeps MemoryError precedence when the heap cannot fit the result', async () => {
  const api = await newApi();
  const source = 'items = [0] * 1000\nprint(len(items))\n';
  for (const maxInstructions of [1_000_000n, 30n]) {
    const handle = newSession(api, configBytes({ maxMemoryBytes: 20_000, maxInstructions, quantum: 1000 }));
    assert.ok(handle > 0);
    try {
      assert.equal(compile(api, handle, source), status.ok);
      assert.equal(api.peony_run(handle, 1000), status.pythonException);
      assert.match(borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle), /MemoryError/);
    } finally {
      api.peony_session_destroy(handle);
    }
  }
});
