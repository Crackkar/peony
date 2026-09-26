import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, completed: 5, pythonException: 6 });

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

function compile(api, handle, source, filename = 'string-tail.py') {
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

const stdout = (api, handle) => borrowedText(api, api.peony_stdout_ptr, api.peony_stdout_len, handle);
const errorText = (api, handle) => borrowedText(api, api.peony_error_ptr, api.peony_error_len, handle);

async function withSession(callback) {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    await callback(api, handle);
  } finally {
    api.peony_session_destroy(handle);
  }
}

test('shipping WASM exposes every promised string tail method', async () => {
  await withSession((api, handle) => {
    const names = 'lstrip rstrip rsplit splitlines rfind rindex title capitalize isdigit isdecimal isalpha isalnum isspace removeprefix removesuffix'.split(' ');
    const source = names.map((name) => `print(hasattr('', '${name}'))`).join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 100_000), status.completed);
    assert.equal(stdout(api, handle), names.map(() => 'True\n').join(''));
  });
});

test('shipping WASM string tail methods preserve Unicode and codepoint semantics', async () => {
  await withSession((api, handle) => {
    const source = [
      'text = "\\u2003--caf\\u00e9--\\u2003"',
      'print(repr(text.lstrip()), repr(text.rstrip()))',
      'print(text.lstrip("\\u2003-"), text.rstrip("\\u2003-"))',
      'print(" a  b ".rsplit(), " a  b ".rsplit(None, 1))',
      'print("a--b--".rsplit("--", 1), "a--b--".rsplit("--", 0))',
      'print("a\\r\\nb\\u0085c\\u2028".splitlines(), "a\\r\\nb".splitlines(keepends=True))',
      'print("a\\u00e9a\\u00e9".rfind("\\u00e9"), "a\\u00e9a\\u00e9".rfind("\\u00e9", 0, 3))',
      'print("a\\u00e9a\\u00e9".rindex("\\u00e9"))',
      'print("they\'re HERE".title(), "\\u00dfETA".capitalize())',
      'print("\\u00b2".isdigit(), "\\u00b2".isdecimal(), "\\U0001e4d0".isalpha())',
      'print("A\\u00b2".isalnum(), "\\u2003\\u00a0".isspace(), "".isalpha())',
      'print("unhappy".removeprefix("un"), "archive.tar".removesuffix(".tar"))',
      'print(" a  b ".rsplit(sep=None, maxsplit=1))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 100_000), status.completed);
    assert.equal(stdout(api, handle), [
      "'--café-- ' ' --café--'",
      'café--   --café',
      "['a', 'b'] [' a', 'b']",
      "['a--b', ''] ['a--b--']",
      "['a', 'b', 'c'] ['a\\r\\n', 'b']",
      '3 1',
      '3',
      "They'Re Here Sseta",
      'True False True',
      'True True False',
      'happy archive',
      "[' a', 'b']",
      '',
    ].join('\n'));
  });
});

test('shipping WASM string tail methods report Python binding and value errors', async () => {
  await withSession((api, handle) => {
    const cases = [
      ["print('abc'.rindex('z'))\n", /ValueError/],
      ["print('abc'.rfind())\n", /TypeError/],
      ["print('abc'.rfind(1))\n", /TypeError/],
      ["print('abc'.lstrip(1))\n", /TypeError/],
      ["print('abc'.removeprefix(prefix='a'))\n", /TypeError/],
      ["print('abc'.rsplit('', 1))\n", /ValueError/],
      ["print('abc'.rsplit(None, maxsplit='x'))\n", /TypeError/],
      ["print('abc'.splitlines(other=True))\n", /TypeError/],
    ];
    for (const [source, expected] of cases) {
      assert.equal(compile(api, handle, source), status.ok);
      assert.equal(api.peony_run(handle, 100_000), status.pythonException);
      assert.match(errorText(api, handle), expected);
    }
  });
});
