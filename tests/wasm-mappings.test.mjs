import assert from 'node:assert/strict';
import { instantiatePeony } from './wasm-files-host.mjs';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, unsupported: 1, completed: 5, pythonException: 6, timeslice: 7 });

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

function compile(api, handle, source, filename = 'mappings.py') {
  const input = writeTransfer(api, source);
  const filenameInput = writeTransfer(api, filename);
  try {
    return api.peony_compile_and_start(handle, input.pointer, input.length, filenameInput.pointer, filenameInput.length);
  } finally {
    api.peony_transfer_free(input.pointer, input.length);
    api.peony_transfer_free(filenameInput.pointer, filenameInput.length);
  }
}

function borrowedText(api, pointerExport, lengthExport, handle) {
  const pointer = pointerExport(handle);
  const length = lengthExport(handle);
  return length === 0 ? '' : new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length));
}

const stdout = (api, handle) => borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle);
const errorText = (api, handle) => borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle);

test('WASM dictionaries preserve numeric key equality, insertion and reinsertion order', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'mapping = {1: "a", True: "b", 1.0: "c"}',
      'print(len(mapping), mapping[1], mapping)',
      'mapping[2] = "d"',
      'mapping[1] = "e"',
      'del mapping[2]',
      'mapping[2] = "f"',
      'print(mapping, list(mapping), 2 in mapping)',
      'values = {1, True, 1.0, 2}',
      'print(len(values), 1 in values, 2 in values)',
      'print(hash(True) == hash(1), hash(1) == hash(1.0), hash(-0.0) == hash(0), hash(2 ** 100) == hash(2.0 ** 100))',
      'print(hash(-1) == -2, hash(-2) < 0, hash(-(2 ** 100)) < 0, hash(-(2 ** 100)) == hash(-(2.0 ** 100)))',
      'collisions = {0: "zero", 2 ** 61 - 1: "prime", 3 * (2 ** 61 - 1): "triple"}',
      'del collisions[0]',
      'del collisions[2 ** 61 - 1]',
      'collisions[5 * (2 ** 61 - 1)] = "five"',
      'print(len(collisions), collisions[3 * (2 ** 61 - 1)], collisions[5 * (2 ** 61 - 1)])',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "1 c {1: 'c'}\n{1: 'e', 2: 'f'} [1, 2] True\n2 True True\nTrue True True True\nTrue True True True\n2 triple five\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM dict methods and live views follow Python behavior', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'mapping = dict([("a", 1), ("b", 2)])',
      'keys = mapping.keys()',
      'mapping["c"] = 3',
      'print(list(keys))',
      'mapping["a"] = 9',
      'print(list(mapping.values()), list(mapping.items()))',
      'print(mapping.get("missing", 7), mapping.setdefault("d", 4), mapping.pop("b"), mapping)',
      'copy = mapping.copy()',
      'copy.update({"a": 5, "e": 6})',
      'print(copy, mapping)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "['a', 'b', 'c']\n[9, 2, 3] [('a', 9), ('b', 2), ('c', 3)]\n7 4 2 {'a': 9, 'c': 3, 'd': 4}\n{'a': 5, 'c': 3, 'd': 4, 'e': 6} {'a': 9, 'c': 3, 'd': 4}\n");

    assert.equal(compile(api, handle, 'mapping = {"a": 1}\nkeys = mapping.keys()\ncursor = iter(keys)\nnext(cursor)\nmapping["b"] = 2\nnext(cursor)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "mappings\.py", line 6[\s\S]*RuntimeError/);

    assert.equal(compile(api, handle, 'mapping = {}\nview = mapping.values()\nmapping["view"] = view\nprint(view)\nprint(mapping)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "dict_values([...])\n{'view': dict_values([...])}\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM exposes set methods, mapping view repr and tuple hashing', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'values = set()',
      'values.add(1)',
      'values.update([2, 3], (3, 4))',
      'values.discard(99)',
      'values.remove(2)',
      'clone = values.copy()',
      'popped = {9}.pop()',
      'values.clear()',
      'print(len(clone), 1 in clone, 4 in clone, popped, len(values))',
      'mapping = {"a": 1}',
      'print(mapping.keys(), mapping.values(), mapping.items())',
      'mapping.update([("b", 2)], c=3)',
      'print(mapping)',
      'print(hash((True, "x")) == hash((1, "x")))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "3 True True 9 0\ndict_keys(['a']) dict_values([1]) dict_items([('a', 1)])\n{'a': 1, 'b': 2, 'c': 3}\nTrue\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM expands dict displays and **kwargs in source order', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'source = {"x": 1, "y": 2}',
      'print({**source, "x": 3, "z": 4})',
      'print(dict(**{"a": 1, "b": 2}))',
      'def show(first, **keywords): print(first, keywords)',
      'show(1, **{"b": 2})',
      'def mutate(): source["late"] = 9; return 3',
      'def collect(**keywords): print(keywords)',
      'collect(**source, tail=mutate())',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "{'x': 3, 'y': 2, 'z': 4}\n{'a': 1, 'b': 2}\n1 {'b': 2}\n{'x': 1, 'y': 2, 'tail': 3}\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM routes positional-only names into **kwargs without binding the slot', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = 'def show(value, /, **keywords): print(value, keywords)\nshow(1, value=2)\n';
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "1 {'value': 2}\n");

    assert.equal(compile(api, handle, 'def show(value, /, **keywords): print(value, keywords)\nshow(value=2)\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /File "mappings\.py", line 2[\s\S]*TypeError: missing required argument/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM rejects unhashable keys and invalid keyword mappings', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(api, handle, 'mapping = {[]: 1}\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /TypeError.*unhashable type/);

    assert.equal(compile(api, handle, 'def collect(**values):\n    pass\ncollect(**{1: "bad"})\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /TypeError.*keywords must be strings/);

    assert.equal(compile(api, handle, 'def collect(**values):\n    pass\ncollect(**{"x": 1}, **{"x": 2})\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /TypeError.*multiple values/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM preserves ** expansion error timing around side effects', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const invalidName = [
      'def collect(**keywords): return keywords',
      'def side(): print("side effect"); return 1',
      'collect(**{1: 2}, tail=side())',
    ].join('\n');
    assert.equal(compile(api, handle, invalidName), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.equal(stdout(api, handle), 'side effect\n');
    assert.match(errorText(api, handle), /TypeError.*keywords must be strings/);

    const duplicate = [
      'def collect(**keywords): return keywords',
      'def side(): print("must not run"); return 1',
      'collect(**{"x": 1}, **{"x": 2}, y=side())',
    ].join('\n');
    assert.equal(compile(api, handle, duplicate), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.equal(stdout(api, handle), '');
    assert.match(errorText(api, handle), /TypeError.*multiple values/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM sessions use distinct string and bytes hash seeds', async () => {
  const api = await newApi();
  const first = api.peony_session_new(0, 0);
  const second = api.peony_session_new(0, 0);
  assert.ok(first > 0 && second > 0 && first !== second);
  try {
    const source = 'print(hash("peony fixed hash seed probe"), hash(b"peony fixed hash seed probe"))\n';
    assert.equal(compile(api, first, source), status.ok);
    assert.equal(compile(api, second, source), status.ok);
    assert.equal(api.peony_run(first, 0), status.completed);
    assert.equal(api.peony_run(second, 0), status.completed);
    assert.notEqual(stdout(api, first), stdout(api, second));
  } finally {
    api.peony_session_destroy(first);
    api.peony_session_destroy(second);
  }
});
