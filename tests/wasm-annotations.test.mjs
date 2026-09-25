import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, unsupported: 1, completed: 5, timeslice: 7 });

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

function compile(api, handle, source, filename = 'annotations.py') {
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

test('shipping WASM stores Python 3.12 function, module, and class annotations', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'events = []',
      'def note(value):',
      '    events.append(value)',
      '    return value',
      'def function(a: note("a"), b: note("b") = note("default")) -> note("return"):',
      '    pass',
      'class Holder:',
      '    pass',
      'holder = Holder()',
      'items = {}',
      'module_name: note("module")',
      'module_value: note("module annotation") = note("module value")',
      'holder.value: note("attribute annotation")',
      'items[note("index")]: note("subscript annotation")',
      'class Annotated:',
      '    class_name: note("class name")',
      '    class_value: note("class annotation") = note("class value")',
      'def local_annotation():',
      '    local_name: missing_annotation',
      '    return "local annotation was not evaluated"',
      'print(events)',
      'print(function.__annotations__)',
      'print(__annotations__)',
      'print(Annotated.__annotations__)',
      'print(local_annotation())',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(
      stdout(api, handle),
      "['default', 'a', 'b', 'return', 'module', 'module value', 'module annotation', 'attribute annotation', 'index', 'subscript annotation', 'class name', 'class value', 'class annotation']\n" +
      "{'a': 'a', 'b': 'b', 'return': 'return'}\n" +
      "{'module_name': 'module', 'module_value': 'module annotation'}\n" +
      "{'class_name': 'class name', 'class_value': 'class annotation'}\n" +
      'local annotation was not evaluated\n',
    );
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM rejects future annotations before executing the module', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, "from __future__ import annotations\nprint('must not run')\n"), status.unsupported);
    assert.equal(stdout(api, handle), '');
  } finally {
    api.peony_session_destroy(handle);
  }
});
