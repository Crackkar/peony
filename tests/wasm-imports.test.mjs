import assert from 'node:assert/strict';
import { instantiatePeony } from './wasm-files-host.mjs';
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
  const { instance } = await instantiatePeony(bytes);
  return instance.exports;
}

function transfer(api, value) {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function writeVfs(api, handle, path, source, asset = false) {
  const pathBlock = transfer(api, path);
  const sourceBlock = transfer(api, source);
  try {
    return asset
      ? api.peony_vfs_mount(handle, pathBlock.pointer, pathBlock.length, sourceBlock.pointer, sourceBlock.length)
      : api.peony_vfs_write(handle, pathBlock.pointer, pathBlock.length, sourceBlock.pointer, sourceBlock.length);
  } finally {
    api.peony_transfer_free(pathBlock.pointer, pathBlock.length);
    api.peony_transfer_free(sourceBlock.pointer, sourceBlock.length);
  }
}

function compile(api, handle, source, filename = 'import-main.py') {
  const sourceBlock = transfer(api, source);
  const filenameBlock = transfer(api, filename);
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

function errorText(api, handle) {
  const pointer = api.peony_error_ptr(handle);
  const length = api.peony_error_len(handle);
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
  const block = transfer(api, packet);
  try {
    return api.peony_resume(handle, block.pointer, block.length);
  } finally {
    api.peony_transfer_free(block.pointer, block.length);
  }
}

function runAtQuantum(api, handle, quantum, terminalStatuses) {
  let result = status.timeslice;
  for (let step = 0; step < 20_000 && result === status.timeslice; step += 1) {
    result = api.peony_run(handle, quantum);
    if (terminalStatuses.includes(result)) break;
  }
  return result;
}

test('shipping WASM imports cache modules and bind functions to their module globals', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/home/alpha.py', [
      'print("loaded")',
      'value = 7',
      '__all__ = ["value", "read"]',
      '_hidden = 99',
      'def read():',
      '    return value',
    ].join('\n')), status.ok);
    const source = [
      'import alpha as first',
      'import alpha',
      'from alpha import value as imported_value',
      'from alpha import *',
      'import sys',
      'print(first is alpha, imported_value, read(), value)',
      'print(first.__name__, first.__package__, first.__file__)',
      'print(sys.modules["alpha"] is alpha)',
      'def local_import():',
      '    import alpha as local',
      '    from alpha import value as local_value',
      '    return local.read() + local_value',
      'class ClassImport:',
      '    import alpha as local',
      '    value = local.value',
      'print(local_import(), ClassImport.value, ClassImport.local is alpha)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.completed]), status.completed);
    assert.equal(stdout(api, handle), 'loaded\nTrue 7 7 7\nalpha  /home/alpha.py\nTrue\n14 7 True\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM resolves packages and explicit relative imports from the VFS', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/assets/pkg.py', 'print("wrong sibling")\nsibling = True\n', true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/pkg/__init__.py', "print('package init')\n__all__ = ['root']\nroot = 'package'\nfrom . import child\n", true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/pkg/child.py', "print('child init')\nvalue = 'child'\n", true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/pkg/sub/__init__.py', "local = 'sub'\n", true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/pkg/sub/mod.py', 'from .. import root\nfrom . import local\n', true), status.ok);
    const source = [
      'import pkg',
      'import pkg.child',
      'from pkg import root',
      'from pkg.sub import mod',
      'print(root, pkg.child.value, mod.root, mod.local, hasattr(pkg, "sibling"))',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(api.peony_run(handle, 0), status.completed);
    assert.equal(stdout(api, handle), 'package init\nchild init\npackage child package sub False\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM reports ImportError when a package member and child module are absent', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/assets/present_package/__init__.py', 'value = 1\n', true), status.ok);
    assert.equal(compile(api, handle, 'from present_package import absent\n'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.pythonException]), status.pythonException);
    assert.match(errorText(api, handle), /ImportError: cannot import name from package/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM wildcard imports honor default visibility and tuple __all__', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/home/public_names.py', 'public = 3\n_private = 4\n'), status.ok);
    assert.equal(writeVfs(api, handle, '/home/tuple_all.py', "__all__ = ('_private',)\n_private = 9\n"), status.ok);
    const source = [
      'from public_names import *',
      'try:',
      '    print(_private)',
      'except NameError:',
      '    print("private skipped")',
      'from tuple_all import *',
      'print(public, _private)',
    ].join('\n');
    assert.equal(compile(api, handle, source), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.completed]), status.completed);
    assert.equal(stdout(api, handle), 'private skipped\n3 9\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM star import raises AttributeError for a missing __all__ name and child', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/assets/missing_all/__init__.py', "__all__ = ['missing']\n", true), status.ok);
    assert.equal(compile(api, handle, 'from missing_all import *\n'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.pythonException]), status.pythonException);
    assert.match(errorText(api, handle), /AttributeError: module does not define name in __all__/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM resolves dotted imports only under the selected parent package', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/home/pkgmod.py', "value = 'module'\n"), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/pkgmod/__init__.py', "value = 'package'\n", true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/pkgmod/child.py', "value = 'wrong parent'\n", true), status.ok);
    assert.equal(compile(api, handle, 'import pkgmod.child\n'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.pythonException]), status.pythonException);
    assert.match(errorText(api, handle), /No module named in the session VFS/);
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM initializes main metadata before any import opcode and after reset', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = 'if __name__ == "__main__":\n    print(__name__, __package__, __file__)\n';
    assert.equal(compile(api, handle, source, 'plain-main.py'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.completed]), status.completed);
    assert.equal(stdout(api, handle), '__main__  plain-main.py\n');

    assert.equal(api.peony_reset(handle), status.ok);
    assert.equal(compile(api, handle, source, 'plain-reuse.py'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.completed]), status.completed);
    assert.equal(stdout(api, handle), '__main__  plain-reuse.py\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM star import schedules an __all__ child that suspends for input', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/assets/star_pkg/__init__.py', "__all__ = ['child']\n", true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/star_pkg/child.py', "answer = input('Child: ')\n", true), status.ok);
    assert.equal(compile(api, handle, 'from star_pkg import *\nprint(child.answer)\n', 'star-child.py'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.hostRequest]), status.hostRequest);
    const eventPointer = api.peony_event_ptr(handle);
    const eventLength = api.peony_event_len(handle);
    const event = new Uint8Array(api.memory.buffer, eventPointer, eventLength);
    const requestId = new DataView(event.buffer, event.byteOffset, event.byteLength).getUint32(8, true);
    assert.ok(requestId > 0);
    assert.equal(resume(api, handle, encodeInput(requestId, '42')), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.completed]), status.completed);
    assert.equal(stdout(api, handle), 'Child: 42\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM dotted relative imports initialize intermediate packages', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/assets/relative_pkg/__init__.py', "print('package init')\nfrom .sub.mod import value\n", true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/relative_pkg/sub/__init__.py', "print('sub init')\nready = 'sub'\n", true), status.ok);
    assert.equal(writeVfs(api, handle, '/assets/relative_pkg/sub/mod.py', "print('module init')\nvalue = 8\n", true), status.ok);
    const source = [
      'import relative_pkg',
      'print(relative_pkg.sub.ready, relative_pkg.sub.mod.value, relative_pkg.value)',
    ].join('\n');
    assert.equal(compile(api, handle, source, 'relative-prefixes.py'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.completed, status.pythonException]), status.completed);
    assert.equal(stdout(api, handle), 'package init\nsub init\nmodule init\nsub 8 8\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('shipping WASM schedules imported module bodies across an input request', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(writeVfs(api, handle, '/home/ask.py', "name = input('Name: ')\nprint('module', name)\n"), status.ok);
    assert.equal(compile(api, handle, 'import ask\nprint("main done")\n'), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.hostRequest, status.completed]), status.hostRequest);
    const eventPointer = api.peony_event_ptr(handle);
    const eventLength = api.peony_event_len(handle);
    const event = new Uint8Array(api.memory.buffer, eventPointer, eventLength);
    const requestId = new DataView(event.buffer, event.byteOffset, event.byteLength).getUint32(8, true);
    assert.ok(requestId > 0);
    assert.equal(resume(api, handle, encodeInput(requestId, 'Ada')), status.ok);
    assert.equal(runAtQuantum(api, handle, 1, [status.completed]), status.completed);
    assert.equal(stdout(api, handle), 'Name: module Ada\nmain done\n');
  } finally {
    api.peony_session_destroy(handle);
  }
});
