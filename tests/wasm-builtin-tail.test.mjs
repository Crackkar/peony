import assert from 'node:assert/strict';
import { instantiatePeony } from './wasm-files-host.mjs';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, completed: 5, pythonException: 6, timeslice: 7, cancelled: 8 });

async function newApi() {
  const bytes = await readFile(wasmPath);
  const { instance } = await instantiatePeony(bytes);
  return instance.exports;
}

function transfer(api, text) {
  const bytes = new TextEncoder().encode(text);
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(api, handle, source, filename = 'builtin-tail.py') {
  const sourceBlock = transfer(api, source);
  const filenameBlock = transfer(api, filename);
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

async function run(source, quantum = 3) {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    assert.equal(compile(api, handle, source), status.ok);
    let runStatus = api.peony_run(handle, quantum);
    for (let count = 0; count < 100000 && runStatus === status.timeslice; count += 1) runStatus = api.peony_run(handle, quantum);
    return { api, handle, runStatus, output: stdout(api, handle), error: errorText(api, handle) };
  } finally {
    api.peony_session_destroy(handle);
  }
}

test('WASM exposes numeric and text builtin tail semantics', async () => {
  const result = await run([
    'print(abs(-7), abs(-2.5), bin(-10), oct(9), hex(255))',
    'print(chr(9731), ord("☃"), ord(b"A"), ascii("é☃"))',
    'print(divmod(17, 5), divmod(-17, 5), pow(2, 80), pow(5, 117, 19))',
    'print(round(2.5), round(3.5), round(125, -1), round(2.675, 2))',
  ].join('\n'));
  assert.equal(result.runStatus, status.completed, result.error);
  assert.equal(result.output, "7 2.5 -0b1010 0o11 0xff\n☃ 9731 65 '\\xe9\\u2603'\n(3, 2) (-4, 3) 1208925819614629174706176 1\n2 4 120 2.67\n");
});

test('WASM reductions suspend, short circuit, invoke key, and resume', async () => {
  const result = await run([
    'def values():', '    print("first")', '    yield 1', '    print("second")', '    yield 0', '    print("bad")', '    yield 1',
    'def key(value):', '    print("key", value)', '    return -value',
    'print(all(values()))',
    'print(any(value for value in [0, 0, 4, 0]))',
    'print(min([3, 1, 2]), max(3, 1, 2), min([3, 1, 2], key=key))',
    'print(min([], default=9), max([], default=8, key=key))',
    'print(sum(value for value in range(6)), sum([1, 2, 3], 10))',
  ].join('\n'), 1);
  assert.equal(result.runStatus, status.completed, result.error);
  assert.equal(result.output, 'first\nsecond\nFalse\nTrue\nkey 3\nkey 1\nkey 2\n1 3 3\n9 8\n15 16\n');
});

test('WASM bytes constructor supports the contracted forms', async () => {
  const result = await run([
    'print(bytes(), bytes(3), bytes([65, 0, 255]))',
    'print(bytes("snow", "utf-8"), bytes("snow", encoding="ascii"))',
    'print(bytes("é", "UTF8"), bytes(b"AB"))',
  ].join('\n'));
  assert.equal(result.runStatus, status.completed, result.error);
  assert.equal(result.output, "b'' b'\\x00\\x00\\x00' b'A\\x00\\xff'\nb'snow' b'snow'\nb'\\xc3\\xa9' b'AB'\n");
});

test('WASM builtin tail errors are typed and located', async () => {
  for (const [source, pattern] of [
    ['ord("ab")', /TypeError/], ['chr(0x110000)', /ValueError/], ['min([])', /ValueError/],
    ['max(1, 2, default=3)', /TypeError/], ['sum([1, "x"])', /TypeError/],
    ['bytes("é", "ascii")', /UnicodeEncodeError/], ['bytes("x", "latin-1")', /LookupError/],
  ]) {
    const result = await run(`${source}\n`);
    assert.equal(result.runStatus, status.pythonException);
    assert.match(result.error, /File "builtin-tail\.py", line 1/);
    assert.match(result.error, pattern);
  }
});

test('WASM long builtin reduction yields and remains cancellable', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    assert.equal(compile(api, handle, 'print(sum(range(20000)))\n'), status.ok);
    assert.equal(api.peony_run(handle, 1), status.timeslice);
    api.peony_cancel(handle);
    assert.equal(api.peony_run(handle, 1), status.cancelled);
  } finally {
    api.peony_session_destroy(handle);
  }
});
