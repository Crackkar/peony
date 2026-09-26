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

function writeTransfer(api, value) {
  const bytes = new TextEncoder().encode(value);
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(api, handle, source, filename = 'exceptions.py') {
  const sourceBlock = writeTransfer(api, source);
  const filenameBlock = writeTransfer(api, filename);
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

function runOneAtATime(api, handle, limit = 1000) {
  let result = status.timeslice;
  for (let i = 0; i < limit && result === status.timeslice; i += 1) result = api.peony_run(handle, 1);
  return result;
}

test('WASM catches Python exceptions and runs finally exactly once across timeslices', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'try:',
      '    raise ValueError("bad")',
      'except (TypeError, ValueError) as error:',
      '    print(error)',
      'finally:',
      '    print("finally")',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    let result = api.peony_run(handle, 1);
    for (let i = 0; i < 50 && result !== status.completed; i += 1) result = api.peony_run(handle, 1);
    assert.equal(result, status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'bad\nfinally\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM keeps loop jumps inside the active finally region', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, [
      'try:',
      '    print("body")',
      'finally:',
      '    for i in range(2):',
      '        if i == 0:',
      '            continue',
      '        print(i)',
      '    print("done")',
    ].join('\n')), status.ok);
    assert.equal(runOneAtATime(api, handle), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'body\n1\ndone\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM resumes a pending exception through nested finally across run(1)', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, [
      'try:',
      '    raise ValueError("original")',
      'finally:',
      '    try:',
      '        print("inner")',
      '    finally:',
      '        print("done")',
    ].join('\n')), status.ok);
    assert.equal(runOneAtATime(api, handle), status.pythonException);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'inner\ndone\n');
    assert.match(borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle), /ValueError: original/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM resumes a pending exception across a called frame during run(1)', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, [
      'def finish():',
      '    print("inner")',
      'try:',
      '    raise ValueError("original")',
      'finally:',
      '    finish()',
      '    print("done")',
    ].join('\n')), status.ok);
    assert.equal(runOneAtATime(api, handle), status.pythonException);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), 'inner\ndone\n');
    assert.match(borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle), /ValueError: original/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM exposes borrowed structured traceback frames for unhandled errors', async () => {
  const api = await newApi();
  assert.equal(typeof api.peony_traceback_ptr, 'function');
  assert.equal(typeof api.peony_traceback_len, 'function');
  const handle = api.peony_session_new(0, 0);
  try {
    assert.equal(compile(api, handle, 'def fail():\n    raise ValueError("bad")\nfail()\n', 'trace.py'), status.ok);
    assert.equal(api.peony_run(handle, 100), status.pythonException);
    const pointer = api.peony_traceback_ptr(handle);
    const length = api.peony_traceback_len(handle);
    const frames = JSON.parse(new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length)));
    assert.deepEqual(frames.map((frame) => frame.name), ['<module>', 'fail']);
    assert.equal(frames[1].filename, 'trace.py');
    assert.equal(frames[1].line, 2);
    assert.equal(frames[0].source_line, 'fail()');

    api.memory.grow(1);
    const afterGrow = JSON.parse(new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length)));
    assert.deepEqual(afterGrow.map((frame) => frame.name), ['<module>', 'fail']);

    assert.equal(compile(api, handle, 'pass\n', 'reset.py'), status.ok);
    assert.equal(api.peony_traceback_len(handle), 0);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM reports invalid context managers as Python TypeError with source frames', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'with 1:\n    pass\n', 'with-type.py'), status.ok);
    assert.equal(api.peony_run(handle, 100), status.pythonException);
    const errorText = borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle);
    assert.match(errorText, /TypeError: object does not support the context manager protocol/);
    const frames = JSON.parse(borrowedText(api, api.peony_traceback_ptr, api.peony_traceback_len, handle));
    assert.equal(frames.length, 1);
    assert.equal(frames[0].filename, 'with-type.py');
    assert.equal(frames[0].line, 1);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM cancellation skips finally and leaves another sessions trace intact', async () => {
  const api = await newApi();
  const first = api.peony_session_new(0, 0);
  const second = api.peony_session_new(0, 0);
  assert.ok(first > 0 && second > 0 && first !== second);
  try {
    assert.equal(compile(api, first, 'try:\n    while True:\n        pass\nfinally:\n    print("must not print")\n', 'cancel.py'), status.ok);
    assert.equal(api.peony_run(first, 1), status.timeslice);

    assert.equal(compile(api, second, 'def fail():\n    raise ValueError("second")\nfail()\n', 'second.py'), status.ok);
    assert.equal(api.peony_run(second, 100), status.pythonException);
    const traceBefore = borrowedText(api, api.peony_traceback_ptr, api.peony_traceback_len, second);
    assert.deepEqual(JSON.parse(traceBefore).map((frame) => frame.filename), ['second.py', 'second.py']);

    assert.equal(api.peony_cancel(first), status.ok);
    assert.equal(api.peony_run(first, 1), status.cancelled);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, first), '');
    assert.equal(borrowedText(api, api.peony_traceback_ptr, api.peony_traceback_len, second), traceBefore);

    assert.equal(compile(api, first, 'print("recovered")\n'), status.ok);
    assert.equal(api.peony_run(first, 100), status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, first), 'recovered\n');
    assert.equal(borrowedText(api, api.peony_traceback_ptr, api.peony_traceback_len, second), traceBefore);
  } finally {
    api.peony_session_destroy(first);
    api.peony_session_destroy(second);
  }
});

test('WASM assert message remains valid after allocations and collection', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    const source = [
      'try:',
      '    assert False, [1, 2]',
      'except AssertionError as error:',
      '    for item in range(10000):',
      '        text = str(item)',
      '    print(error)',
    ].join('\n');
    assert.equal(compile(api, handle, source, 'assert-message.py'), status.ok);
    let result = api.peony_run(handle, 100000);
    for (let resumes = 0; resumes < 10 && result === status.timeslice; resumes += 1) result = api.peony_run(handle, 100000);
    assert.equal(result, status.completed);
    assert.equal(borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle), '[1, 2]\n');

    assert.equal(compile(api, handle, 'assert False, [1, 2]\n', 'assert-unhandled.py'), status.ok);
    assert.equal(api.peony_run(handle, 100), status.pythonException);
    assert.match(borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle), /AssertionError: \[1, 2\]/);
  } finally {
    api.peony_session_destroy(handle);
  }
});
