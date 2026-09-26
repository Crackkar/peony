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
  const mounted = new TextEncoder().encode('course text');
  await session.mount({ '/course/lesson.txt': mounted }, { root: '/course' });
  await session.mount({ 'unit/part.txt': 'nested course text' }, { root: '/course' });
  mounted.fill(0);
  assert.equal(new TextDecoder().decode(await session.readFile('/course/lesson.txt')), 'course text');
  assert.equal(new TextDecoder().decode(await session.readFile('/course/unit/part.txt')), 'nested course text');
  await session.writeFile('/home/note.txt', new TextEncoder().encode('learner data'));
  const read = await session.readFile('/home/note.txt');
  assert.equal(new TextDecoder().decode(read), 'learner data');
  read.fill(0);
  assert.equal(new TextDecoder().decode(await session.readFile('/home/note.txt')), 'learner data');
  assert.deepEqual(await session.listFiles('/home'), ['/home/note.txt']);
  await assert.rejects(session.writeFile('/course/lesson.txt', new Uint8Array([1])), /read.only|permission/i);
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
    await assert.rejects(session.mount({ '/course/file.txt': 'x' }, { root: null }), TypeError);
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

test('persistent VFS snapshot does not need a second session copy of file contents', async () => {
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

test('ESM fresh runs retain course and home but clear temporary files and reset does too', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({ stdout: (chunk) => output.push(chunk) });
  await session.mount({ '/course/lesson.txt': new TextEncoder().encode('course') });
  let result = await session.run([
    'with open("/home/notes.txt", "w") as file:',
    '    file.write("home")',
    'with open("/tmp/notes.txt", "w") as file:',
    '    file.write("tmp")',
    '',
  ].join('\n'));
  assert.equal(result.status, 'completed');

  result = await session.run([
    'print(open("/course/lesson.txt").read())',
    'print(open("/home/notes.txt").read())',
    'try:',
    '    open("/tmp/notes.txt")',
    'except FileNotFoundError:',
    '    print("tmp cleared")',
    '',
  ].join('\n'));
  assert.equal(result.status, 'completed');
  assert.equal(output.join(''), 'course\nhome\ntmp cleared\n');

  await session.writeFile('/tmp/reset.txt', new TextEncoder().encode('tmp'));
  await session.reset();
  assert.equal(new TextDecoder().decode(await session.readFile('/home/notes.txt')), 'home');
  assert.equal(new TextDecoder().decode(await session.readFile('/course/lesson.txt')), 'course');
  await assert.rejects(session.readFile('/tmp/reset.txt'), /not found|missing/i);
  await session.destroy();
});
