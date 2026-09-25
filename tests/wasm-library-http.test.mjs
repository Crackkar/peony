import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, invalidArgument: 3, completed: 5, pythonException: 6, timeslice: 7, cancelled: 8, hostRequest: 10, outputEvent: 11 });
const kind = Object.freeze({ input: 1, http: 2, sleep: 3, clock: 4 });
const sectionKind = Object.freeze({ utf8: 1, binary: 2 });
const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function api() {
  const bytes = await readFile(wasmPath);
  return (await WebAssembly.instantiate(bytes, {})).instance.exports;
}

function transfer(instance, value) {
  const bytes = typeof value === 'string' ? encoder.encode(value) : value;
  const pointer = instance.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(instance.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(instance, handle, source) {
  const code = transfer(instance, source);
  const filename = transfer(instance, 'wasm-library-http.py');
  try {
    return instance.peony_compile_and_start(handle, code.pointer, code.length, filename.pointer, filename.length);
  } finally {
    instance.peony_transfer_free(code.pointer, code.length);
    instance.peony_transfer_free(filename.pointer, filename.length);
  }
}

function runBoundary(instance, handle, quantum = 1) {
  let result = status.timeslice;
  for (let step = 0; step < 250_000; step += 1) {
    result = instance.peony_run(handle, quantum);
    if (result !== status.timeslice && result !== status.outputEvent) return result;
  }
  throw new Error('HTTP program did not reach an execution boundary');
}

function borrowedText(instance, handle, prefix) {
  const pointer = instance[`${prefix}_ptr`](handle);
  const length = instance[`${prefix}_len`](handle);
  return length === 0 ? '' : decoder.decode(new Uint8Array(instance.memory.buffer, pointer, length));
}

function parsePacket(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.deepEqual([...bytes.slice(0, 4)], [0x50, 0x45, 0x4f, 0x4e]);
  assert.equal(view.getUint32(20, true), bytes.length);
  const sections = [];
  for (let index = 0; index < view.getUint16(16, true); index += 1) {
    const descriptor = 24 + index * 12;
    const offset = view.getUint32(descriptor + 4, true);
    const length = view.getUint32(descriptor + 8, true);
    sections.push({ kind: view.getUint16(descriptor, true), bytes: bytes.slice(offset, offset + length) });
  }
  return { kind: view.getUint16(6, true), requestId: view.getUint32(8, true), status: view.getUint16(12, true), sections };
}

function event(instance, handle) {
  const pointer = instance.peony_event_ptr(handle);
  const length = instance.peony_event_len(handle);
  return parsePacket(new Uint8Array(instance.memory.buffer, pointer, length).slice());
}

function encodePacket({ kind: packetKind, requestId, packetStatus = 0, sections = [] }) {
  const normalized = sections.map((section) => ({
    kind: section.kind,
    bytes: typeof section.bytes === 'string' ? encoder.encode(section.bytes) : section.bytes,
  }));
  const headerLength = 24 + normalized.length * 12;
  const total = normalized.reduce((sum, section) => sum + section.bytes.length, headerLength);
  const bytes = new Uint8Array(total);
  const view = new DataView(bytes.buffer);
  bytes.set([0x50, 0x45, 0x4f, 0x4e]);
  view.setUint16(4, 1, true);
  view.setUint16(6, packetKind, true);
  view.setUint32(8, requestId, true);
  view.setUint16(12, packetStatus, true);
  view.setUint16(16, normalized.length, true);
  view.setUint32(20, total, true);
  let offset = headerLength;
  normalized.forEach((section, index) => {
    const descriptor = 24 + index * 12;
    view.setUint16(descriptor, section.kind, true);
    view.setUint32(descriptor + 4, offset, true);
    view.setUint32(descriptor + 8, section.bytes.length, true);
    bytes.set(section.bytes, offset);
    offset += section.bytes.length;
  });
  return bytes;
}

function resume(instance, handle, packet) {
  const block = transfer(instance, packet);
  try {
    return instance.peony_resume(handle, block.pointer, block.length);
  } finally {
    instance.peony_transfer_free(block.pointer, block.length);
  }
}

function statusBytes(code) {
  const bytes = new Uint8Array(2);
  new DataView(bytes.buffer).setUint16(0, code, true);
  return bytes;
}

function floatBytes(value) {
  const bytes = new Uint8Array(8);
  new DataView(bytes.buffer).setFloat64(0, value, true);
  return bytes;
}

function httpReply(requestId, code, headers, body) {
  return encodePacket({ kind: kind.http, requestId, sections: [
    { kind: sectionKind.binary, bytes: statusBytes(code) },
    { kind: sectionKind.utf8, bytes: headers },
    { kind: sectionKind.binary, bytes: typeof body === 'string' ? encoder.encode(body) : body },
  ] });
}

function sectionText(packet, index) {
  return decoder.decode(packet.sections[index].bytes);
}

test('shipping WASM urlopen emits bounded HTTP packets and exposes response protocols', async () => {
  const instance = await api();
  const handle = instance.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'from urllib.request import urlopen',
      'from urllib.error import URLError, HTTPError',
      'import ssl',
      'context = ssl.create_default_context()',
      'context.check_hostname = False',
      'context.verify_mode = ssl.CERT_NONE',
      'with urlopen("https://example.test/data", data=b"payload", timeout=2.5, context=context) as response:',
      '    print(response.status, response.getcode(), response.headers["content-type"])',
      '    print(response.read(2), response.read(), response.read())',
      'try:',
      '    urlopen("https://example.test/missing")',
      'except HTTPError as error:',
      '    print("http", isinstance(error, URLError), isinstance(error, OSError))',
      'try:',
      '    urlopen("https://example.test/offline")',
      'except URLError:',
      '    print("transport")',
    ].join('\n');
    assert.equal(compile(instance, handle, source), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    const request = event(instance, handle);
    assert.equal(request.kind, kind.http);
    assert.equal(sectionText(request, 0), 'POST');
    assert.equal(sectionText(request, 1), 'https://example.test/data');
    assert.equal(decoder.decode(request.sections[3].bytes), 'payload');
    assert.equal(new DataView(request.sections[4].bytes.buffer).getFloat64(0, true), 2.5);
    assert.equal(resume(instance, handle, httpReply(request.requestId, 201, 'Content-Type: text/plain; charset=utf-8\r\n', 'hello')), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    let nextRequest = event(instance, handle);
    assert.equal(resume(instance, handle, httpReply(nextRequest.requestId, 404, 'Content-Type: text/plain\r\n', 'missing')), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    nextRequest = event(instance, handle);
    const transportError = encodePacket({ kind: kind.http, requestId: nextRequest.requestId, packetStatus: 2, sections: [
      { kind: sectionKind.utf8, bytes: 'connection' },
      { kind: sectionKind.utf8, bytes: 'offline' },
    ] });
    assert.equal(resume(instance, handle, transportError), status.ok);
    assert.equal(runBoundary(instance, handle), status.completed, borrowedText(instance, handle, 'peony_error'));
    assert.equal(borrowedText(instance, handle, 'peony_stdout'), "201 201 text/plain; charset=utf-8\nb'he' b'llo' b''\nhttp True True\ntransport\n");
  } finally {
    instance.peony_session_destroy(handle);
  }
});

test('shipping WASM requests serializes query, form and JSON in Zig and parses JSON responses', async () => {
  const instance = await api();
  const handle = instance.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'import requests',
      'print(requests.exceptions.Timeout is requests.Timeout, requests.exceptions.ConnectionError is requests.ConnectionError)',
      'first = requests.get("https://api.test/items", params={"q": "x y", "page": 2}, headers={"X-Test": "yes"})',
      'print(first.status_code, first.ok, first.headers["CONTENT-TYPE"], "content-type" in first.headers, first.content, first.text)',
      'first.encoding = "ascii"',
      'print(first.encoding, first.text)',
      'first.encoding = None',
      'print(first.encoding)',
      'try:',
      '    first.encoding = "utf-16"',
      'except LookupError:',
      '    print("codec")',
      'form = requests.post("https://api.test/form", data={"a": "x y", "b": "/"})',
      'print(form.status_code, form.text)',
      'created = requests.post("https://api.test/json", json={"number": 12345678901234567890})',
      'print(created.json()["number"])',
      'invalid = requests.get("https://api.test/invalid-json")',
      'try:',
      '    invalid.json()',
      'except ValueError as error:',
      '    import json',
      '    print("json decode", type(error) is json.JSONDecodeError)',
      'large = requests.get("https://api.test/large-json")',
      'print(len(large.json()))',
    ].join('\n');
    assert.equal(compile(instance, handle, source), status.ok);

    assert.equal(runBoundary(instance, handle), status.hostRequest);
    let request = event(instance, handle);
    assert.equal(sectionText(request, 0), 'GET');
    assert.equal(sectionText(request, 1), 'https://api.test/items?q=x+y&page=2');
    assert.match(sectionText(request, 2), /X-Test: yes\r\n/);
    assert.equal(resume(instance, handle, httpReply(request.requestId, 200, 'Content-Type: text/plain; charset=utf-8\r\n', 'items')), status.ok);

    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    assert.equal(sectionText(request, 0), 'POST');
    assert.equal(sectionText(request, 1), 'https://api.test/form');
    assert.equal(sectionText(request, 3), 'a=x+y&b=%2F');
    assert.match(sectionText(request, 2), /Content-Type: application\/x-www-form-urlencoded/);
    assert.equal(resume(instance, handle, httpReply(request.requestId, 202, 'Content-Type: text/plain\r\n', 'accepted')), status.ok);

    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    assert.equal(sectionText(request, 1), 'https://api.test/json');
    assert.match(sectionText(request, 2), /Content-Type: application\/json/);
    assert.match(sectionText(request, 3), /12345678901234567890/);
    assert.equal(resume(instance, handle, httpReply(request.requestId, 201, 'Content-Type: application/json\r\n', '{"number":12345678901234567890}')), status.ok);

    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    assert.equal(sectionText(request, 1), 'https://api.test/invalid-json');
    assert.equal(resume(instance, handle, httpReply(request.requestId, 200, 'Content-Type: application/json\r\n', '{')), status.ok);

    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    assert.equal(sectionText(request, 1), 'https://api.test/large-json');
    const largeJson = `[${'0,'.repeat(19_999)}0]`;
    assert.equal(resume(instance, handle, httpReply(request.requestId, 200, 'Content-Type: application/json\r\n', largeJson)), status.ok);
    const workBeforeParse = Number(instance.peony_work_count(handle));
    let sawParsingTimeslice = false;
    for (let step = 0; step < 20; step += 1) {
      const parseStatus = instance.peony_run(handle, 1);
      if (parseStatus === status.timeslice) sawParsingTimeslice = true;
      assert.ok(parseStatus === status.timeslice || parseStatus === status.outputEvent, borrowedText(instance, handle, 'peony_error'));
    }
    assert.equal(sawParsingTimeslice, true);
    assert.ok(Number(instance.peony_work_count(handle)) > workBeforeParse);
    const completion = runBoundary(instance, handle, 50_000);
    assert.equal(completion, status.completed, `large Response.json boundary=${completion}: ${borrowedText(instance, handle, 'peony_error')}`);

    assert.equal(borrowedText(instance, handle, 'peony_stdout'), "True True\n200 True text/plain; charset=utf-8 True b'items' items\nascii items\nutf-8\ncodec\n202 accepted\n12345678901234567890\njson decode True\n20000\n");
  } finally {
    instance.peony_session_destroy(handle);
  }
});

test('shipping WASM cancels a large resumable Response.json parse without replay', async () => {
  const instance = await api();
  const handle = instance.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = 'import requests\nresponse = requests.get("https://api.test/cancel-json")\nprint(len(response.json()))\nprint("late")\n';
    assert.equal(compile(instance, handle, source), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    const request = event(instance, handle);
    const largeJson = `[${'0,'.repeat(19_999)}0]`;
    assert.equal(resume(instance, handle, httpReply(request.requestId, 200, 'Content-Type: application/json\r\n', largeJson)), status.ok);
    for (let step = 0; step < 20; step += 1) {
      const parseStatus = instance.peony_run(handle, 1);
      assert.ok(parseStatus === status.timeslice || parseStatus === status.outputEvent, borrowedText(instance, handle, 'peony_error'));
    }
    assert.equal(instance.peony_cancel(handle), status.ok);
    assert.equal(runBoundary(instance, handle), status.cancelled);
    assert.equal(borrowedText(instance, handle, 'peony_stdout'), '');
  } finally {
    instance.peony_session_destroy(handle);
  }
});

test('shipping WASM maps HTTP status and host transport classifications to native exceptions', async () => {
  const instance = await api();
  const handle = instance.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'import requests',
      'response = requests.get("https://api.test/fail")',
      'print(response.status_code, response.ok)',
      'try:',
      '    response.raise_for_status()',
      'except requests.HTTPError as error:',
      '    print(isinstance(error, requests.RequestException))',
      'try:',
      '    requests.get("https://api.test/slow", timeout=0.01)',
      'except requests.Timeout as error:',
      '    print(isinstance(error, requests.RequestException))',
      'try:',
      '    requests.get("https://api.test/offline")',
      'except requests.ConnectionError as error:',
      '    print(isinstance(error, requests.RequestException))',
    ].join('\n');
    assert.equal(compile(instance, handle, source), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    let request = event(instance, handle);
    assert.equal(resume(instance, handle, httpReply(request.requestId, 500, 'Content-Type: text/plain\r\n', 'failure')), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    const timeout = encodePacket({ kind: kind.http, requestId: request.requestId, packetStatus: 2, sections: [
      { kind: sectionKind.utf8, bytes: 'timeout' },
      { kind: sectionKind.utf8, bytes: 'deadline exceeded' },
    ] });
    assert.equal(resume(instance, handle, timeout), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    const connection = encodePacket({ kind: kind.http, requestId: request.requestId, packetStatus: 2, sections: [
      { kind: sectionKind.utf8, bytes: 'connection' },
      { kind: sectionKind.utf8, bytes: 'offline' },
    ] });
    assert.equal(resume(instance, handle, connection), status.ok);
    assert.equal(runBoundary(instance, handle), status.completed, borrowedText(instance, handle, 'peony_error'));
    assert.equal(borrowedText(instance, handle, 'peony_stdout'), '500 False\nTrue\nTrue\nTrue\n');
  } finally {
    instance.peony_session_destroy(handle);
  }
});

test('shipping WASM time uses CLOCK and SLEEP packets and validates stale or malformed replies', async () => {
  const instance = await api();
  const handle = instance.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(instance, handle, 'import time\nprint(time.time())\nprint(time.monotonic())\nprint(time.sleep(0))\n'), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    let request = event(instance, handle);
    assert.equal(request.kind, kind.clock);
    assert.equal(sectionText(request, 0), 'wall');

    const malformed = encodePacket({ kind: kind.clock, requestId: request.requestId, sections: [] });
    assert.equal(resume(instance, handle, malformed), status.invalidArgument);
    assert.equal(event(instance, handle).requestId, request.requestId);
    const wrongId = encodePacket({ kind: kind.clock, requestId: request.requestId + 1, sections: [{ kind: sectionKind.binary, bytes: floatBytes(1) }] });
    assert.equal(resume(instance, handle, wrongId), status.invalidArgument);
    assert.equal(event(instance, handle).requestId, request.requestId);
    assert.equal(resume(instance, handle, encodePacket({ kind: kind.clock, requestId: request.requestId, sections: [{ kind: sectionKind.binary, bytes: floatBytes(123.5) }] })), status.ok);

    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    assert.equal(sectionText(request, 0), 'monotonic');
    assert.equal(resume(instance, handle, encodePacket({ kind: kind.clock, requestId: request.requestId, sections: [{ kind: sectionKind.binary, bytes: floatBytes(9.25) }] })), status.ok);

    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    assert.equal(request.kind, kind.sleep);
    assert.equal(new DataView(request.sections[0].bytes.buffer).getFloat64(0, true), 0);
    assert.equal(resume(instance, handle, encodePacket({ kind: kind.sleep, requestId: request.requestId })), status.ok);
    assert.equal(runBoundary(instance, handle), status.completed, borrowedText(instance, handle, 'peony_error'));
    assert.equal(borrowedText(instance, handle, 'peony_stdout'), '123.5\n9.25\nNone\n');
  } finally {
    instance.peony_session_destroy(handle);
  }
});
