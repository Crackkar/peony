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

test('Peony ESM transports requests through injected fetch with browser-safe policy', async () => {
  const peony = await loadPeony();
  const output = [];
  const calls = [];
  const allowed = [];
  const session = peony.createSession({
    quantum: 1,
    stdout: (chunk) => output.push(chunk),
    allowUrl: async (url) => { allowed.push(url); return url.startsWith('https://api.test/'); },
    fetch: async (url, options) => {
      calls.push([url, options]);
      return new Response('{"answer":42}', {
        status: 201,
        headers: { 'Content-Type': 'application/json; charset=utf-8', 'X-Reply': 'yes' },
      });
    },
  });
  const result = await session.run([
    'import requests',
    'response = requests.post("https://api.test/items", params={"q": "x y"}, json={"name": "Ada"}, headers={"X-Test": "yes"}, timeout=2)',
    'print(response.status_code, response.ok, response.headers["x-reply"], response.json()["answer"])',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), '201 True yes 42\n');
  assert.deepEqual(allowed, ['https://api.test/items?q=x+y']);
  assert.equal(calls.length, 1);
  const [url, options] = calls[0];
  assert.equal(url, 'https://api.test/items?q=x+y');
  assert.equal(options.method, 'POST');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.redirect, 'error');
  assert.equal(options.headers.get('X-Test'), 'yes');
  assert.match(options.headers.get('Content-Type'), /^application\/json/);
  assert.match(new TextDecoder().decode(options.body), /"name"\s*:\s*"Ada"/);
  assert.ok(options.signal instanceof AbortSignal);
});

test('Peony ESM always requests redirect rejection', async () => {
  const peony = await loadPeony();
  const redirects = [];
  const fetch = async (_url, options) => {
    redirects.push(options.redirect);
    return new Response('ok', { status: 200, headers: { 'Content-Type': 'text/plain' } });
  };
  const firstOutput = [];
  const first = peony.createSession({ fetch, stdout: (chunk) => firstOutput.push(chunk) });
  assert.equal((await first.run('import requests\nprint(requests.get("https://api.test/a").text)\n')).status, 'completed');
  assert.throws(() => peony.createSession({ followRedirects: true }), TypeError);
  assert.deepEqual(redirects, ['error']);
  assert.equal(firstOutput.join(''), 'ok\n');
});

test('HTTP timeout prevents a delayed URL decision from starting transport', async () => {
  const peony = await loadPeony();
  let releaseDecision;
  let fetchCalls = 0;
  const output = [];
  const session = peony.createSession({
    stdout: chunk => output.push(chunk),
    allowUrl: () => new Promise(resolve => { releaseDecision = resolve; }),
    fetch: async () => { fetchCalls += 1; return new Response('unexpected'); },
  });
  try {
    const result = await session.run([
      'import requests',
      'try:',
      '    requests.get("https://api.test/slow-policy", timeout=0.02)',
      'except requests.exceptions.Timeout:',
      '    print("timed out")',
    ].join('\n'));
    assert.equal(result.status, 'completed', result.error?.message);
    releaseDecision(true);
    await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(fetchCalls, 0);
    assert.equal(output.join(''), 'timed out\n');
  } finally {
    await session.destroy();
  }
});

test('Peony ESM denies policy failures before fetch and maps them into requests errors', async () => {
  const peony = await loadPeony();
  let fetchCalls = 0;
  const output = [];
  const session = peony.createSession({
    stdout: (chunk) => output.push(chunk),
    allowUrl: () => false,
    fetch: async () => { fetchCalls += 1; return new Response('wrong'); },
  });
  const result = await session.run([
    'import requests',
    'try:',
    '    requests.get("https://denied.test/")',
    'except requests.RequestException:',
    '    print("denied")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(fetchCalls, 0);
  assert.equal(output.join(''), 'denied\n');
});

test('Peony ESM caps a streamed response while reading and aborts the transport', async () => {
  const peony = await loadPeony();
  const output = [];
  let cancelled = false;
  const body = new ReadableStream({
    pull(controller) {
      controller.enqueue(new Uint8Array(48));
      controller.enqueue(new Uint8Array(48));
    },
    cancel() { cancelled = true; },
  });
  const session = peony.createSession({
    stdout: (chunk) => output.push(chunk),
    maxHttpResponseBytes: 64,
    fetch: async () => new Response(body, { status: 200, headers: { 'Content-Type': 'application/octet-stream' } }),
  });
  const result = await session.run([
    'import requests',
    'try:',
    '    requests.get("https://api.test/large")',
    'except requests.RequestException:',
    '    print("too large")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'too large\n');
  assert.equal(cancelled, true);
});

test('Peony ESM includes response headers in the packet cap', async () => {
  const peony = await loadPeony();
  const output = [];
  const session = peony.createSession({
    stdout: (chunk) => output.push(chunk),
    fetch: async () => new Response('', { status: 200, headers: { 'X-Large': 'x'.repeat(1024 * 1024) } }),
  });
  const result = await session.run([
    'import requests',
    'try:',
    '    requests.get("https://api.test/large-header")',
    'except requests.ConnectionError:',
    '    print("header too large")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'header too large\n');
});

test('Peony ESM uses injectable wall clock, monotonic clock, and sleeper', async () => {
  const peony = await loadPeony();
  const output = [];
  const sleeps = [];
  const session = peony.createSession({
    quantum: 1,
    stdout: (chunk) => output.push(chunk),
    wallClock: () => 123.5,
    monotonicClock: () => 9.25,
    sleep: async (seconds, signal) => {
      assert.ok(signal instanceof AbortSignal);
      sleeps.push(seconds);
    },
  });
  const result = await session.run([
    'import time',
    'print(time.time(), time.monotonic())',
    'print(time.sleep(0))',
    'try:',
    '    time.sleep(-1)',
    'except ValueError:',
    '    print("negative")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), '123.5 9.25\nNone\nnegative\n');
  assert.deepEqual(sleeps, [0]);
});

test('Peony ESM distinguishes timeout from hard cancellation and ignores late completion', async () => {
  const peony = await loadPeony();
  const timeoutOutput = [];
  const timeoutSession = peony.createSession({
    stdout: (chunk) => timeoutOutput.push(chunk),
    fetch: (_url, options) => new Promise((_resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true });
    }),
  });
  const timeoutResult = await timeoutSession.run([
    'import requests',
    'try:',
    '    requests.get("https://api.test/slow", timeout=0.001)',
    'except requests.Timeout:',
    '    print("timeout")',
  ].join('\n'));
  assert.equal(timeoutResult.status, 'completed', timeoutResult.error?.message);
  assert.equal(timeoutOutput.join(''), 'timeout\n');

  let resolveFetch;
  let fetchStarted = false;
  const cancelled = peony.createSession({
    fetch: (_url, options) => {
      fetchStarted = true;
      return new Promise((resolve, reject) => {
        resolveFetch = resolve;
        options.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true });
      });
    },
  });
  const running = cancelled.run('import requests\nrequests.get("https://api.test/pending")\nprint("late")\n');
  for (let index = 0; index < 100 && !fetchStarted; index += 1) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(fetchStarted, true);
  cancelled.cancel();
  const cancelledResult = await running;
  assert.equal(cancelledResult.status, 'cancelled');
  resolveFetch?.(new Response('late'));
  await new Promise((resolve) => setImmediate(resolve));
});
