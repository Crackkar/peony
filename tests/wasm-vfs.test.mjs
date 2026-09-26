import assert from 'node:assert/strict';
import { instantiatePeony } from './wasm-files-host.mjs';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, invalidHandle: 2, invalidArgument: 3, outOfMemory: 4, completed: 5, pythonException: 6 });

async function newApi() {
  const bytes = await readFile(wasmPath);
  const { instance } = await instantiatePeony(bytes);
  return instance.exports;
}

function transfer(api, bytes) {
  const pointer = api.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function pathBytes(path) {
  return new TextEncoder().encode(path);
}

test('shipping WASM exports bulk VFS operations', async () => {
  const api = await newApi();
  for (const name of [
    'peony_vfs_mount',
    'peony_vfs_read',
    'peony_vfs_write',
    'peony_vfs_list',
    'peony_vfs_data_ptr',
    'peony_vfs_data_len',
  ]) assert.equal(typeof api[name], 'function', `${name} must be exported`);
});

test('raw reset preserves asset and home VFS entries and clears temporary entries', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  const other = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  assert.ok(other > 0);
  try {
    const assetPath = pathBytes('/assets/sample.txt');
    const assetText = new TextEncoder().encode('mounted sample');
    const assetPathBlock = transfer(api, assetPath);
    const assetTextBlock = transfer(api, assetText);
    const nestedAssetPath = transfer(api, pathBytes('/assets/unit/sample.txt'));
    const nestedAssetText = transfer(api, new TextEncoder().encode('nested sample'));
    try {
      assert.equal(api.peony_vfs_mount(handle, assetPathBlock.pointer, assetPathBlock.length, assetTextBlock.pointer, assetTextBlock.length), status.ok);
      assert.equal(api.peony_vfs_mount(handle, nestedAssetPath.pointer, nestedAssetPath.length, nestedAssetText.pointer, nestedAssetText.length), status.ok);
    } finally {
      api.peony_transfer_free(assetPathBlock.pointer, assetPathBlock.length);
      api.peony_transfer_free(assetTextBlock.pointer, assetTextBlock.length);
      api.peony_transfer_free(nestedAssetPath.pointer, nestedAssetPath.length);
      api.peony_transfer_free(nestedAssetText.pointer, nestedAssetText.length);
    }

    for (const [path, text] of [['/home/saved.txt', 'saved'], ['/tmp/throwaway.txt', 'throwaway']]) {
      const pathBlock = transfer(api, pathBytes(path));
      const dataBlock = transfer(api, new TextEncoder().encode(text));
      try {
        assert.equal(api.peony_vfs_write(handle, pathBlock.pointer, pathBlock.length, dataBlock.pointer, dataBlock.length), status.ok);
      } finally {
        api.peony_transfer_free(pathBlock.pointer, pathBlock.length);
        api.peony_transfer_free(dataBlock.pointer, dataBlock.length);
      }
    }

    assert.equal(api.peony_reset(handle), status.ok);
    for (const [path, expected] of [['/assets/sample.txt', 'mounted sample'], ['/home/saved.txt', 'saved']]) {
      const pathBlock = transfer(api, pathBytes(path));
      try {
        assert.equal(api.peony_vfs_read(handle, pathBlock.pointer, pathBlock.length), status.ok);
        const pointer = api.peony_vfs_data_ptr(handle);
        const length = api.peony_vfs_data_len(handle);
        assert.equal(new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, length).slice()), expected);
      } finally {
        api.peony_transfer_free(pathBlock.pointer, pathBlock.length);
      }
    }
    const tempPath = transfer(api, pathBytes('/tmp/throwaway.txt'));
    try {
      assert.notEqual(api.peony_vfs_read(handle, tempPath.pointer, tempPath.length), status.ok);
    } finally {
      api.peony_transfer_free(tempPath.pointer, tempPath.length);
    }

    const nestedDirectory = transfer(api, pathBytes('/assets/unit'));
    try {
      assert.equal(api.peony_vfs_list(handle, nestedDirectory.pointer, nestedDirectory.length), status.ok);
      const list = new TextDecoder().decode(new Uint8Array(api.memory.buffer, api.peony_vfs_data_ptr(handle), api.peony_vfs_data_len(handle)).slice());
      assert.equal(list, '/assets/unit/sample.txt\0');
    } finally {
      api.peony_transfer_free(nestedDirectory.pointer, nestedDirectory.length);
    }

    const isolatedPath = transfer(api, pathBytes('/home/saved.txt'));
    try {
      assert.equal(api.peony_vfs_read(other, isolatedPath.pointer, isolatedPath.length), status.invalidArgument);
    } finally {
      api.peony_transfer_free(isolatedPath.pointer, isolatedPath.length);
    }
  } finally {
    api.peony_session_destroy(handle);
    api.peony_session_destroy(other);
  }
});

test('raw VFS paths are validated and file bytes are copied across memory growth', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const invalid = transfer(api, pathBytes('/../../escape'));
    assert.equal(api.peony_vfs_read(0, 0, 0), status.invalidHandle);
    const text = transfer(api, new Uint8Array(128 * 1024).fill(0x61));
    try {
      assert.equal(api.peony_vfs_write(handle, invalid.pointer, invalid.length, text.pointer, text.length), status.invalidArgument);
      const safePath = transfer(api, pathBytes('/home/big.bin'));
      try {
      assert.equal(api.peony_vfs_write(handle, safePath.pointer, safePath.length, text.pointer, text.length), status.ok);
      assert.equal(api.peony_vfs_read(handle, safePath.pointer, safePath.length), status.ok);
        const beforeGrowth = new Uint8Array(api.memory.buffer, api.peony_vfs_data_ptr(handle), api.peony_vfs_data_len(handle)).slice();
        const growth = transfer(api, new Uint8Array(256 * 1024).fill(0x62));
        api.peony_transfer_free(growth.pointer, growth.length);
        assert.equal(beforeGrowth.length, 128 * 1024);
        assert.equal(beforeGrowth[0], 0x61);
      assert.equal(beforeGrowth.at(-1), 0x61);
      const tooLarge = transfer(api, new Uint8Array(2 * 1024 * 1024 + 1).fill(0x62));
      try {
        assert.equal(api.peony_vfs_write(handle, safePath.pointer, safePath.length, tooLarge.pointer, tooLarge.length), status.outOfMemory);
        assert.equal(api.peony_vfs_read(handle, safePath.pointer, safePath.length), status.ok);
        const preserved = new Uint8Array(api.memory.buffer, api.peony_vfs_data_ptr(handle), api.peony_vfs_data_len(handle));
        assert.equal(preserved.length, 128 * 1024);
        assert.equal(preserved[0], 0x61);
      } finally {
        api.peony_transfer_free(tooLarge.pointer, tooLarge.length);
      }
      } finally {
        api.peony_transfer_free(safePath.pointer, safePath.length);
      }
    } finally {
      api.peony_transfer_free(invalid.pointer, invalid.length);
      api.peony_transfer_free(text.pointer, text.length);
    }
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('Python file writes invalidate borrowed raw VFS read views', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const path = transfer(api, pathBytes('/home/live.txt'));
    const oldData = transfer(api, new TextEncoder().encode('old'));
    try {
      assert.equal(api.peony_vfs_write(handle, path.pointer, path.length, oldData.pointer, oldData.length), status.ok);
    } finally {
      api.peony_transfer_free(path.pointer, path.length);
      api.peony_transfer_free(oldData.pointer, oldData.length);
    }

    const source = transfer(api, new TextEncoder().encode([
      'with open(\"/home/live.txt\", \"w\") as file:',
      '    file.write(\"new\")',
      '',
    ].join('\n')));
    const filename = transfer(api, new TextEncoder().encode('borrowed-view.py'));
    try {
      assert.equal(api.peony_compile_and_start(handle, source.pointer, source.length, filename.pointer, filename.length), status.ok);
    } finally {
      api.peony_transfer_free(source.pointer, source.length);
      api.peony_transfer_free(filename.pointer, filename.length);
    }

    const readPath = transfer(api, pathBytes('/home/live.txt'));
    try {
      assert.equal(api.peony_vfs_read(handle, readPath.pointer, readPath.length), status.ok);
      assert.equal(new TextDecoder().decode(new Uint8Array(api.memory.buffer, api.peony_vfs_data_ptr(handle), api.peony_vfs_data_len(handle))), 'old');
    } finally {
      api.peony_transfer_free(readPath.pointer, readPath.length);
    }

    assert.equal(api.peony_run(handle, 100), status.completed);
    assert.equal(api.peony_vfs_data_ptr(handle), 0);
    assert.equal(api.peony_vfs_data_len(handle), 0);
    const refreshedPath = transfer(api, pathBytes('/home/live.txt'));
    try {
      assert.equal(api.peony_vfs_read(handle, refreshedPath.pointer, refreshedPath.length), status.ok);
      assert.equal(new TextDecoder().decode(new Uint8Array(api.memory.buffer, api.peony_vfs_data_ptr(handle), api.peony_vfs_data_len(handle))), 'new');
    } finally {
      api.peony_transfer_free(refreshedPath.pointer, refreshedPath.length);
    }
  } finally {
    api.peony_session_destroy(handle);
  }
});

test('raw WASM binary read after seek past EOF preserves the file position', async () => {
  const api = await newApi();
  const handle = api.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = transfer(api, new TextEncoder().encode([
      'with open("/home/past-end.bin", "wb+") as file:',
      '    file.write(b"x")',
      '    file.seek(10)',
      '    print(file.read())',
      '    print(file.tell())',
      '    file.seek(10)',
      '    print(file.readline())',
      '    print(file.tell())',
      '',
    ].join('\n')));
    const filename = transfer(api, new TextEncoder().encode('past-end.py'));
    try {
      assert.equal(api.peony_compile_and_start(handle, source.pointer, source.length, filename.pointer, filename.length), status.ok);
    } finally {
      api.peony_transfer_free(source.pointer, source.length);
      api.peony_transfer_free(filename.pointer, filename.length);
    }
    assert.equal(api.peony_run(handle, 100), status.completed);
    const output = new Uint8Array(api.memory.buffer, api.peony_stdout_ptr(handle), api.peony_stdout_len(handle)).slice();
    assert.equal(new TextDecoder().decode(output), "b''\n10\nb''\n10\n");
  } finally {
    api.peony_session_destroy(handle);
  }
});
