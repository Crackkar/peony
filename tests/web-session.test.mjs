import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const facadePath = new URL('../web/peony.mjs', import.meta.url);

async function loadPeony(input) {
  const { Peony } = await import(facadePath);
  const artifact = input ?? new Uint8Array(await readFile(wasmPath));
  return Peony.load(artifact);
}

test('Peony ESM pumps real WASM input and flush output in source order', async () => {
  const peony = await loadPeony();
  const events = [];
  const session = peony.createSession({
    quantum: 1,
    stdout: (chunk) => events.push(['stdout', chunk]),
    input: async (prompt) => {
      events.push(['input', prompt]);
      return 'Ada\r\n';
    },
  });

  const result = await session.run('name = input("Name: ")\nprint("Hello", name)\n', { filename: 'lesson.py' });
  assert.equal(result.status, 'completed');
  assert.deepEqual(events, [
    ['stdout', 'Name: '],
    ['input', 'Name: '],
    ['stdout', 'Hello Ada\n'],
  ]);
  assert.equal(typeof result.counters.instructions, 'number');
  assert.deepEqual(result.frames, []);
});

test('Peony handles EOF and host callback rejection through Python exceptions', async () => {
  const peony = await loadPeony();
  const chunks = [];
  const eofSession = peony.createSession({ stdout: (chunk) => chunks.push(chunk), input: async () => null });
  const eofResult = await eofSession.run('try:\n    input("EOF: ")\nexcept EOFError:\n    print("closed")\n');
  assert.equal(eofResult.status, 'completed');
  assert.equal(chunks.join(''), 'EOF: closed\n');

  const rejectedOutput = [];
  const rejected = peony.createSession({
    stdout: (chunk) => rejectedOutput.push(chunk),
    input: async () => { throw new Error('device denied'); },
  });
  const rejectedResult = await rejected.run('try:\n    input("Host: ")\nexcept OSError as error:\n    print(error)\n');
  assert.equal(rejectedResult.status, 'completed');
  assert.match(rejectedOutput.join(''), /device denied/);
});

test('Peony flushes output before awaiting the next input prompt', async () => {
  const peony = await loadPeony();
  const events = [];
  const session = peony.createSession({
    stdout: (chunk) => events.push(['stdout', chunk]),
    input: async (prompt) => {
      events.push(['input', prompt]);
      return 'go';
    },
  });
  const result = await session.run('print("ready", flush=True)\ninput("Continue: ")\nprint("done")\n');
  assert.equal(result.status, 'completed');
  assert.deepEqual(events, [
    ['stdout', 'ready\n'],
    ['stdout', 'Continue: '],
    ['input', 'Continue: '],
    ['stdout', 'done\n'],
  ]);
});

test('Peony starts each run in a fresh Python world and reports structured exceptions', async () => {
  const peony = await loadPeony();
  const chunks = [];
  const session = peony.createSession({ stdout: (chunk) => chunks.push(chunk) });
  assert.equal((await session.run('value = 42\nprint(value)\n')).status, 'completed');
  const error = await session.run('print(value)\n', { filename: 'fresh.py' });
  assert.equal(error.status, 'error');
  assert.match(error.error.message, /value/);
  assert.equal(error.frames[0].filename, 'fresh.py');
  assert.equal(chunks.join(''), '42\n');
  const firstHandle = session.handle;
  const firstStart = chunks.length;
  assert.equal((await session.run('print(hash("per-run-seed"))\n')).status, 'completed');
  const firstHash = chunks.slice(firstStart).join('');
  assert.notEqual(session.handle, firstHandle, 'each run receives a newly created raw session');
  const secondStart = chunks.length;
  assert.equal((await session.run('print(hash("per-run-seed"))\n')).status, 'completed');
  assert.notEqual(chunks.slice(secondStart).join(''), firstHash, 'each fresh run receives a new per-session hash seed');
});

test('Peony enforces the configured instruction limit with a limit result', async () => {
  const peony = await loadPeony();
  const session = peony.createSession({ quantum: 2, maxInstructions: 25 });
  const result = await session.run('while True:\n    pass\n');
  assert.equal(result.status, 'limit');
  assert.ok(result.counters.instructions <= 25);
});

test('Peony yields to browser tasks between timeslices so timers can cancel', async () => {
  const peony = await loadPeony();
  const session = peony.createSession({ quantum: 1, maxInstructions: 5000 });
  const timer = setTimeout(() => session.cancel(), 0);
  const result = await session.run('while True:\n    pass\n');
  clearTimeout(timer);
  assert.equal(result.status, 'cancelled');
  assert.ok(result.counters.work < 5000);
});

test('Peony rejects invalid session limits instead of coercing them', async () => {
  const peony = await loadPeony();
  for (const options of [
    { quantum: -1 },
    { quantum: 1.5 },
    { quantum: 2 ** 32 },
    { maxMemoryBytes: 0 },
    { maxMemoryBytes: 2 ** 32 },
    { maxMemoryBytes: 16.5 },
    { maxInstructions: 0 },
    { maxInstructions: Number.MAX_SAFE_INTEGER + 1 },
    { maxInstructions: 1n << 64n },
  ]) {
    assert.throws(() => peony.createSession(options), RangeError, JSON.stringify(options, (_, value) => typeof value === 'bigint' ? value.toString() : value));
  }
});

test('Peony rejects overlapping runs and hard-cancels pending input without finally', async () => {
  const peony = await loadPeony();
  const output = [];
  let resolveInput;
  let inputCalled = false;
  const session = peony.createSession({
    stdout: (chunk) => output.push(chunk),
    input: () => {
      inputCalled = true;
      return new Promise((resolve) => { resolveInput = resolve; });
    },
  });
  const running = session.run('try:\n    input("stop: ")\nfinally:\n    print("must not run")\n');
  for (let index = 0; index < 100 && !inputCalled; index += 1) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(inputCalled, true);
  await assert.rejects(session.run('print("overlap")\n'), /already running/i);
  session.cancel();
  const result = await running;
  assert.equal(result.status, 'cancelled');
  assert.equal(output.join(''), 'stop: ');
  assert.equal(resolveInput instanceof Function, true);
});

test('Peony reset aborts a pending run and restores a clean session', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({
    stdout: (chunk) => output.push(chunk),
    input: () => new Promise(() => {}),
  });
  const running = session.run('try:\n    input("reset: ")\nfinally:\n    print("must not run")\n');
  for (let index = 0; index < 100 && !output.join('').includes('reset: '); index += 1) await new Promise((resolve) => setImmediate(resolve));
  const reset = session.reset();
  const result = await running;
  await reset;
  assert.equal(result.status, 'cancelled');
  assert.equal(output.join(''), 'reset: ');
  const recovered = await session.run('print("recovered")\n');
  assert.equal(recovered.status, 'completed');
  assert.equal(output.join(''), 'reset: recovered\n');
});

test('Peony ESM pumps multi-source map across generator suspension and callback quanta', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({ quantum: 1, stdout: (chunk) => output.push(chunk) });
  const result = await session.run([
    'def combine(left, right):',
    '    print("pair", left, right)',
    '    return left + right',
    'source = (print("source", value) or value for value in [10, 20])',
    'result = list(map(combine, [1, 2], source))',
    'print(result)',
    '',
  ].join('\n'));
  assert.equal(result.status, 'completed');
  assert.equal(output.join(''), 'source 10\npair 1 10\nsource 20\npair 2 20\n[11, 22]\n');
});

test('Peony.load accepts a URL string for the real WASM artifact', async () => {
  const bytes = await readFile(wasmPath);
  const server = createServer((_request, response) => {
    response.writeHead(200, { 'Content-Type': 'application/wasm' });
    response.end(bytes);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const address = server.address();
    const { Peony } = await import(facadePath);
    const loaded = await Peony.load(`http://127.0.0.1:${address.port}/peony.wasm`);
    assert.ok(loaded.createSession());
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test('Peony.load accepts Response and ArrayBuffer inputs backed by the shipped artifact', async () => {
  const bytes = await readFile(wasmPath);
  const { Peony } = await import(facadePath);
  const responseLoaded = await Peony.load(new Response(bytes, { headers: { 'Content-Type': 'application/wasm' } }));
  const arrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const bufferLoaded = await Peony.load(arrayBuffer);
  assert.ok(responseLoaded.createSession());
  assert.ok(bufferLoaded.createSession());
});
