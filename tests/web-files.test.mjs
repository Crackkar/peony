import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const facadePath = new URL('../web/peony.mjs', import.meta.url);

async function loadPeony() {
  const { Peony } = await import(facadePath);
  return Peony.load(new Uint8Array(await readFile(wasmPath)));
}

test('Peony session mounts, reads, writes and lists copied file bytes', async () => {
  const peony = await loadPeony();
  const session = peony.createSession();
  const mounted = new TextEncoder().encode('asset text');
  await session.mount({ '/assets/sample.txt': mounted }, { root: '/assets' });
  await session.mount({ 'unit/part.txt': 'nested asset text' }, { root: '/assets' });
  mounted.fill(0);
  assert.equal(new TextDecoder().decode(await session.readFile('/assets/sample.txt')), 'asset text');
  assert.equal(new TextDecoder().decode(await session.readFile('/assets/unit/part.txt')), 'nested asset text');
  await session.writeFile('/home/note.txt', new TextEncoder().encode('user data'));
  const read = await session.readFile('/home/note.txt');
  assert.equal(new TextDecoder().decode(read), 'user data');
  read.fill(0);
  assert.equal(new TextDecoder().decode(await session.readFile('/home/note.txt')), 'user data');
  assert.deepEqual(await session.listFiles('/home'), ['/home/note.txt']);
  await assert.rejects(session.writeFile('/assets/sample.txt', new Uint8Array([1])), /read.only|permission/i);
  await assert.rejects(session.readFile('/../../escape'), /path|traversal|invalid/i);
  await session.destroy();
});

test('ESM VFS file APIs reject non-string paths without coercion', async () => {
  const peony = await loadPeony();
  const session = peony.createSession();
  try {
    assert.throws(() => session.writeFile(null, 'x'), TypeError);
    assert.throws(() => session.readFile(null), TypeError);
    assert.throws(() => session.listFiles(null), TypeError);
    const symbolPaths = { [Symbol('path')]: 'x' };
    await assert.rejects(session.mount(symbolPaths), TypeError);
    await assert.rejects(session.mount({ '/assets/file.txt': 'x' }, { root: null }), TypeError);
    assert.deepEqual(await session.listFiles('/home'), []);
  } finally {
    await session.destroy();
  }
});

test('session VFS and per-file byte limits are configurable', async () => {
  const peony = await loadPeony();
  assert.throws(() => peony.createSession({ maxVfsBytes: 64, maxFileBytes: 65 }), RangeError);
  const session = peony.createSession({ maxVfsBytes: 128, maxFileBytes: 64 });
  await session.writeFile('/home/first.bin', new Uint8Array(64));
  await session.writeFile('/home/second.bin', new Uint8Array(64));
  await assert.rejects(session.writeFile('/home/third.bin', new Uint8Array(1)), /memory|limit|large/i);
  await assert.rejects(session.writeFile('/home/oversized.bin', new Uint8Array(65)), /memory|limit|large/i);
  assert.equal((await session.readFile('/home/first.bin')).length, 64);
  await session.destroy();
});

test('file modes, encoding, binary writes and text seek cookies follow Python', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({ stdout: (chunk) => output.push(chunk) });
  const source = [
    'with open(\"/home/modes.txt\", \"w\") as file:',
    '    file.write(\"abc\")',
    'with open(\"/home/modes.txt\", \"a+\") as file:',
    '    print(file.read())',
    '    file.seek(0)',
    '    print(file.read())',
    '    file.seek(0)',
    '    file.write(\"d\")',
    '    file.seek(0)',
    '    print(file.read())',
    'with open(\"/home/modes.txt\", \"r+\") as file:',
    '    file.read(1)',
    '    file.write(\"X\")',
    '    file.seek(0)',
    '    print(file.read())',
    'with open(\"/home/unicode.txt\", \"w\") as file:',
    '    file.write(\"αβ\")',
    'with open(\"/home/unicode.txt\", \"r+\") as file:',
    '    print(file.read(1))',
    '    cookie = file.tell()',
    '    print(file.read(1))',
    '    file.seek(cookie)',
    '    print(file.read())',
    'try:',
    '    open(\"/home/modes.txt\", \"rr\")',
    'except ValueError:',
    '    print(\"mode error\")',
    'try:',
    '    open(\"/home/modes.txt\", encoding=\"latin-1\")',
    'except LookupError:',
    '    print(\"encoding error\")',
    'try:',
    '    with open(\"/home/binary.dat\", \"wb\") as file:',
    '        file.write(\"text\")',
    'except TypeError:',
    '    print(\"binary type error\")',
    '',
  ].join('\n');
  const result = await session.run(source);
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), "\nabc\nabcd\naXcd\nα\nβ\nβ\nmode error\nencoding error\nbinary type error\n");
  await session.destroy();
});

test('Worker file host treats positional offsets as bytes', async () => {
  const peony = await loadPeony();
  const session = peony.createSession();
  try {
    const result = await session.run([
      'with open("/home/offset.bin", "wb+") as file:',
      '    file.seek(255)',
      '    file.write(b"x")',
      '    file.truncate(256)',
      '    file.seek(254)',
      '    assert file.read() == b"\\x00x"',
    ].join('\n'));
    assert.equal(result.status, 'completed', result.error?.message);
    const bytes = await session.readFile('/home/offset.bin');
    assert.equal(bytes.length, 256);
    assert.equal(bytes[254], 0);
    assert.equal(bytes[255], 120);
  } finally {
    await session.destroy();
  }
});

test('Worker file host keeps unlinked open bytes charged until close', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({
    stdout: chunk => output.push(chunk),
    maxVfsBytes: 32,
    maxFileBytes: 32,
  });
  try {
    const result = await session.run([
      'import os',
      'with open("/home/old.bin", "wb+") as stream:',
      '    stream.write(b"a" * 32)',
      '    os.unlink("/home/old.bin")',
      '    try:',
      '        open("/home/new.bin", "wb").write(b"x")',
      '    except OSError:',
      '        print("held")',
      'with open("/home/new.bin", "wb") as stream:',
      '    stream.write(b"b" * 32)',
      'print(open("/home/new.bin", "rb").read() == b"b" * 32)',
    ].join('\n'));
    assert.equal(result.status, 'completed', result.error?.message);
    assert.equal(output.join(''), 'held\nTrue\n');
    assert.equal((await session.readFile('/home/new.bin')).length, 32);
    assert.equal((await session.stats()).vfsBytes, 32);
  } finally {
    await session.destroy();
  }
});

test('persistent Worker files survive raw runtime replacement without a file copy', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({
    stdout: (chunk) => output.push(chunk),
    maxMemoryBytes: 700_000,
    maxVfsBytes: 500_000,
    maxFileBytes: 450_000,
  });
  await session.writeFile('/home/bulk.bin', new Uint8Array(400_000).fill(0x61));
  let result = await session.run('print(\"first\")\n');
  assert.equal(result.status, 'completed');
  result = await session.run('print(\"second\")\n');
  assert.equal(result.status, 'completed', result.error?.message);
  const copied = await session.readFile('/home/bulk.bin');
  assert.equal(copied.length, 400_000);
  assert.equal(copied[0], 0x61);
  assert.equal(output.join(''), 'first\nsecond\n');
  await session.destroy();
});

test('ESM fresh runs retain asset and home but clear temporary files and reset does too', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({ stdout: (chunk) => output.push(chunk) });
  await session.mount({ '/assets/sample.txt': new TextEncoder().encode('asset') });
  let result = await session.run([
    'with open("/home/notes.txt", "w") as file:',
    '    file.write("home")',
    'with open("/tmp/notes.txt", "w") as file:',
    '    file.write("tmp")',
    '',
  ].join('\n'));
  assert.equal(result.status, 'completed');

  result = await session.run([
    'print(open("/assets/sample.txt").read())',
    'print(open("/home/notes.txt").read())',
    'try:',
    '    open("/tmp/notes.txt")',
    'except FileNotFoundError:',
    '    print("tmp cleared")',
    '',
  ].join('\n'));
  assert.equal(result.status, 'completed');
  assert.equal(output.join(''), 'asset\nhome\ntmp cleared\n');

  await session.writeFile('/tmp/reset.txt', new TextEncoder().encode('tmp'));
  await session.reset();
  assert.equal(new TextDecoder().decode(await session.readFile('/home/notes.txt')), 'home');
  assert.equal(new TextDecoder().decode(await session.readFile('/assets/sample.txt')), 'asset');
  await assert.rejects(session.readFile('/tmp/reset.txt'), /not found|missing/i);
  await session.destroy();
});
