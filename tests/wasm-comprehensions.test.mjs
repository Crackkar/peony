import assert from 'node:assert/strict';
import { instantiatePeony } from './wasm-files-host.mjs';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, unsupported: 1, completed: 5, pythonException: 6, timeslice: 7, cancelled: 8, limit: 12 });

async function newApi() {
  const bytes = await readFile(wasmPath);
  const { instance } = await instantiatePeony(bytes);
  return instance.exports;
}

function writeTransfer(api, value) {
  const bytes = new TextEncoder().encode(value);
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(api, handle, source, filename = 'comprehensions.py') {
  const sourceBlock = writeTransfer(api, source);
  const filenameBlock = writeTransfer(api, filename);
  try {
    return api.peony_compile_and_start(handle, sourceBlock.pointer, sourceBlock.length, filenameBlock.pointer, filenameBlock.length);
  } finally {
    api.peony_transfer_free(sourceBlock.pointer, sourceBlock.length);
    api.peony_transfer_free(filenameBlock.pointer, filenameBlock.length);
  }
}

function limitedSession(api, maxInstructions, quantum = 50_000) {
  const config = new Uint8Array(28);
  const view = new DataView(config.buffer);
  config.set([0x50, 0x43, 0x46, 0x47]);
  view.setUint16(4, 1, true);
  view.setUint32(8, 8 * 1024 * 1024, true);
  view.setBigUint64(12, BigInt(maxInstructions), true);
  view.setUint32(20, quantum, true);
  const pointer = api.peony_transfer_alloc(config.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, config.length).set(config);
  try {
    return api.peony_session_new(pointer, config.length);
  } finally {
    api.peony_transfer_free(pointer, config.length);
  }
}

function borrowedText(api, pointerExport, lengthExport, handle) {
  const pointer = pointerExport(handle);
  const length = lengthExport(handle);
  return length === 0 ? '' : new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length));
}

const stdout = (api, handle) => borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle);
const errorText = (api, handle) => borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle);

function runToCompletion(api, handle, quantum = 0) {
  let result = api.peony_run(handle, quantum);
  for (let resumes = 0; result === status.timeslice && resumes < 100_000; resumes += 1) result = api.peony_run(handle, quantum);
  return result;
}

test('WASM comprehensions use implicit scopes, filters, nested clauses and late cells', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    const source = [
      'def build(offset):',
      '    matrix = [[offset + row + column for column in range(3) if column != 1] for row in range(2)]',
      '    makers = [lambda: offset + index for index in range(3)]',
      '    print(matrix)',
      '    print(makers[0](), makers[1](), makers[2]())',
      '    index = 99',
      '    print(index)',
      'build(10)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(runToCompletion(api, handle, 2), status.completed);
    assert.equal(stdout(api, handle), '[[10, 12], [11, 13]]\n12 12 12\n99\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM generator expressions evaluate outer iter once and defer filters and bodies', async () => {
  const api = await newApi();
  const handle = limitedSession(api, 50_000n);
  try {
    const source = [
      'def source(): print("outer iterable"); return [1, 2, 3]',
      'def accept(value): print("filter", value); return value % 2',
      'def emit(value): print("body", value); return value',
      'def create():',
      '    prefix = 100',
      '    return (emit(prefix + value) for value in source() if accept(value))',
      'items = create()',
      'print("created")',
      'print(list(items))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(runToCompletion(api, handle, 3), status.completed);
    assert.equal(stdout(api, handle), 'outer iterable\ncreated\nfilter 1\nbody 101\nfilter 2\nfilter 3\nbody 103\n[101, 103]\n');

    assert.equal(compile(api, handle, [
      'def accept(value): print("filter", value); return value % 2',
      'def emit(value): print("body", value); return value',
      'items = (emit(value) for value in [1, 2, 3] if accept(value))',
      'print("created")',
      'print(next(items))',
      'print("between")',
      'print(next(items))',
    ].join('\n')), status.ok);
    assert.equal(runToCompletion(api, handle, 2), status.completed);
    assert.equal(stdout(api, handle), 'created\nfilter 1\nbody 1\n1\nbetween\nfilter 2\nfilter 3\nbody 3\n3\n');

    assert.equal(compile(api, handle, 'dangling = (value for value in [7, 8])\nprint(next(dangling))\n'), status.ok);
    assert.equal(runToCompletion(api, handle, 1), status.completed);
    assert.equal(stdout(api, handle), '7\n');
    assert.equal(compile(api, handle, 'print("reused")\n'), status.ok);
    assert.equal(runToCompletion(api, handle, 1), status.completed);
    assert.equal(stdout(api, handle), 'reused\n');

    assert.equal(compile(api, handle, 'items=(value for value in range(10000000) if False)\nnext(items)\n'), status.ok);
    let result = api.peony_run(handle, 0);
    for (let checkpoint = 0; result === status.timeslice && checkpoint < 1000; checkpoint += 1) result = api.peony_run(handle, 0);
    assert.equal(result, status.limit);
    assert.ok(api.peony_work_count(handle) <= 50_000);
    assert.equal(compile(api, handle, 'print("recovered")\n'), status.ok);
    assert.equal(runToCompletion(api, handle, 2), status.completed);
    assert.equal(stdout(api, handle), 'recovered\n');

    assert.equal(compile(api, handle, 'items=(value for value in [1,2])\nprint(next(items))\n'), status.ok);
    let nextResult = api.peony_run(handle, 1);
    for (let checkpoint = 0; nextResult === status.timeslice && stdout(api, handle) === '' && checkpoint < 100; checkpoint += 1) {
      nextResult = api.peony_run(handle, 1);
    }
    assert.equal(stdout(api, handle), '1\n');
    api.peony_cancel(handle);
    assert.equal(api.peony_run(handle, 1), status.cancelled);

    assert.equal(compile(api, handle, [
      'def accept(value): print("filter", value); return value % 2',
      'def emit(value): print("body", value); return value',
      'items = (emit(value) for value in [1, 2, 3] if accept(value))',
      'print("created")',
      'print(next(items))',
      'print("between")',
      'print(next(items))',
    ].join('\n')), status.ok);
    assert.equal(runToCompletion(api, handle, 2), status.completed);
    assert.equal(stdout(api, handle), 'created\nfilter 1\nbody 1\n1\nbetween\nfilter 2\nfilter 3\nbody 3\n3\n');

    assert.equal(compile(api, handle, 'items = (value for value in 1)\nprint("after")\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.equal(stdout(api, handle), '');
    assert.match(errorText(api, handle), /TypeError/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM lambdas, walrus, lazy map and filter, stable keyed sorting and list.index bounds', async () => {
  const api = await newApi();
  const handle = limitedSession(api, 50_000n);
  try {
    const source = [
      'calls = 0',
      'def bump():',
      '    global calls',
      '    calls += 1',
      '    return calls',
      'def make(offset): return lambda value=2: offset + value',
      'function = make(5)',
      'print(function(), function(9))',
      'print((saved := bump()), saved, calls)',
      'values = [("first", 2), ("second", 1), ("third", 2)]',
      'def key(item): print("key", item[0]); return item[1]',
      'values.sort(key=key, reverse=True)',
      'print(values)',
      'def mapped(value): print("map", value); return value + 1',
      'items = map(mapped, [1, 2])',
      'print("mapped")',
      'print(list(items))',
      'def odd(value): print("filter", value); return value % 2',
      'print(list(filter(odd, [1, 2, 3, 4])))',
      'print(sorted([3, 1, 2], reverse=True))',
      'numbers = [0, 1, 0, 2]',
      'print(numbers.index(0, 1), numbers.index(1, -3, 4))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(runToCompletion(api, handle, 0), status.completed);
    assert.equal(stdout(api, handle), '7 14\n1 1 1\nkey first\nkey second\nkey third\n[(\'first\', 2), (\'third\', 2), (\'second\', 1)]\nmapped\nmap 1\nmap 2\n[2, 3]\nfilter 1\nfilter 2\nfilter 3\nfilter 4\n[1, 3]\n[3, 2, 1]\n2 1\n');

    assert.equal(compile(api, handle, [
      'print(list(map(lambda left, right: left + right, [1, 2, 3], [10, 20])))',
      'print(list(filter(None, [0, 1, 2])))',
      'print(list(map(str, [1, 2])))',
      'print(sorted(["aa", "b"], key=len))',
    ].join('\n')), status.ok);
    assert.equal(runToCompletion(api, handle), status.completed, errorText(api, handle));
    assert.equal(stdout(api, handle), '[11, 22]\n[1, 2]\n[\'1\', \'2\']\n[\'b\', \'aa\']\n');

    assert.equal(compile(api, handle, 'items = map(1, [1])\nprint("created")\nprint(list(items))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.equal(stdout(api, handle), 'created\n');
    assert.match(errorText(api, handle), /TypeError/);

    assert.equal(compile(api, handle, 'values=[3,2,1]\ndef key(value): values.clear(); return value\nvalues.sort(key=key)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /ValueError.*list modified during sort/);

    assert.equal(compile(api, handle, 'print("must not run")\n[(saved := value) for value in [1, 2]]\n'), status.pythonException);
    assert.match(errorText(api, handle), /assignment expressions are not supported in comprehensions/);
    assert.equal(stdout(api, handle), '');
    assert.equal(compile(api, handle, 'numbers = [1, 2]\nprint(numbers.index(1, -(2 ** 100)))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), '0\n');
    assert.equal(compile(api, handle, 'numbers = [1, 2]\nprint(numbers.index(1, 2 ** 100))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /ValueError/);

    assert.equal(compile(api, handle, 'values=list(range(10000))\nvalues.reverse()\nvalues.sort()\n'), status.ok);
    let result = api.peony_run(handle, 0);
    for (let checkpoint = 0; result === status.timeslice && checkpoint < 1000; checkpoint += 1) result = api.peony_run(handle, 0);
    assert.equal(result, status.limit);
    assert.ok(api.peony_work_count(handle) <= 50_000);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM keyed sort roots a temporary receiver and callback during collection', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    const source = [
      'print("before sort")',
      '[2, 1].sort(key=lambda value: str([value] * 30000))',
      'print("sort survived")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(runToCompletion(api, handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'before sort\nsort survived\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});
