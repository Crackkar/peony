import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/bin/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, unsupported: 1, completed: 5, pythonException: 6 });

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

function compile(api, handle, source, filename = 'formatting.py') {
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

test('WASM f-strings support conversions, format specs, nested expressions and order', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    const source = [
      'name = "\\u00e9"',
      'print(f"{{{name}}} {name!r} {name!a} {255:#06x} {12345.678:,.2f}")',
      'def mark(label, value): print(label); return value',
      'print(f"{mark(\'first\', 1)} {mark(\'second\', 2)}")',
      'print(f"{ {\'x\': 1}[\'x\'] }")',
      'print(f"{1 != 2}")',
      'print(f"{{x}} {name!r:>8}")',
      'print(f"{ "x" }")',
      'print(\'hello \' f\'{name}\')',
      "print(b'a' b'b')",
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "{\u00e9} '\u00e9' '\\xe9' 0x00ff 12,345.68\nfirst\nsecond\n1 2\n1\nTrue\n{x}      '\u00e9'\nx\nhello \u00e9\nb'ab'\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('WASM str.format, format and percent formatting use the shared formatter', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  try {
    const source = [
      'name = "\\u00e9"',
      'print("{0} {1:0>5d} {name:^7s}".format(name, 42, name="ok"))',
      'print(format(255, "#06x"), format(3.5, ",.2f"), format(name, "^5s"))',
      'print("%s %r %a %04d %.1f %%" % (name, name, name, 7, 2.5))',
      'print("%#x %d" % (31, 4))',
      'print(f"{123!r:.2}", format(-15, "#06x"), format(42, "+d"), format(42, " d"))',
      'print(format(65, "c"), format(3.5, ".1e"), format(1.2, ".2E"), format(1234.0, ".3g"), format(0.125, ".0%"))',
      'print(format(9.99, ".1g"), format(999.9, ".3g"), format(0.0000999, ".1g"), format(3.14159, ".12f"))',
      'print(format(3.14159265, "12"), format(3.14159265, "12g"))',
      'print(format(1234.5, ","), format(3.14159, ".2"))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), "\u00e9 00042   ok   \n0x00ff 3.50   \u00e9  \n\u00e9 '\u00e9' '\\xe9' 0007 2.5 %\n0x1f 4\n12 -0x00f +42  42\nA 3.5e+00 1.20E+00 1.23e+03 12%\n1e+01 1e+03 0.0001 3.141590000000\n  3.14159265      3.14159\n1,234.5 3.1\n");

    assert.equal(compile(api, handle, 'print(format(1, "z"))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /ValueError/);
    assert.equal(compile(api, handle, 'print("%s %s" % ("one",))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /TypeError/);
    assert.equal(compile(api, handle, 'print("}".format())\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /ValueError/);
    assert.equal(compile(api, handle, 'print("{0} {}".format(1, 2))\n'), status.ok);
    assert.equal(api.peony_run(handle, 0), status.pythonException);
    assert.match(errorText(api, handle), /ValueError/);
    assert.equal(compile(api, handle, 'print("must not run")\nwidth=4\nprint(f"{3:{width}}")\n'), status.unsupported);
    assert.match(errorText(api, handle), /nested f-string format specifications are not supported/);
    assert.equal(stdout(api, handle), '');
    assert.equal(compile(api, handle, 'value=3\nprint(f"{value=}")\n'), status.pythonException);
    assert.notEqual(errorText(api, handle), '');
    assert.equal(stdout(api, handle), '');
  } finally {
    api.peony_session_destroy(handle);
  }
});
