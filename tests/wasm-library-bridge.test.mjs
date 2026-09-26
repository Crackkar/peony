import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Peony } from '../web/peony.mjs';

const wasmPath = new URL('../zig-out/peony.wasm', import.meta.url);
const load = async () => Peony.load(new Uint8Array(await readFile(wasmPath)));

test('session.run validates and copies Unicode argv before execution', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ stdout: text => output.push(text) });
  await assert.rejects(session.run('print("never")', { argv: 'bad' }), TypeError);
  await assert.rejects(session.run('print("never")', { argv: [3] }), TypeError);
  await assert.rejects(session.run('print("never")', { argv: ['bad\0value'] }), TypeError);
  await assert.rejects(session.run('print("never")', { argv: ['x'.repeat(65_536)] }), RangeError);
  const result = await session.run('import sys\nprint(sys.argv)\n', { filename: 'args.py', argv: ['é', ''] });
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), "['args.py', 'é', '']\n");
});

test('shipping WASM native registry owns names ahead of VFS and retains first-class functions', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ stdout: (text) => output.push(text), quantum: 1 });
  await session.writeFile('/home/math.py', "print('wrong VFS math')\n");
  const result = await session.run([
    'import math',
    'from math import sqrt',
    'alias = math.sqrt',
    'print(math is __import__("math"), alias(9), sqrt(16))',
    'try:',
    '    alias(9, bad=1)',
    'except TypeError:',
    '    print("binder rejected")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'True 3.0 4.0\nbinder rejected\n');
});

test('shipping WASM exposes real primitive types and lazy sys streams and metadata', async () => {
  const peony = await load();
  const stdout = [];
  const stderr = [];
  const session = peony.createSession({
    stdout: (text) => stdout.push(text),
    stderr: (text) => stderr.push(text),
    maxMemoryBytes: 256 * 1024,
    quantum: 1,
  });
  const result = await session.run([
    'import sys',
    'print(type(1) is int, type(True) is bool, type([]) is list, isinstance(True, int))',
    'print(sys.modules["sys"] is sys, sys.platform, sys.implementation.name)',
    'print(sys.argv)',
    'print("stream", file=sys.stderr)',
    'print(sys.stdout.write("out\\n"))',
    'class Callable:',
    '    def __call__(self, *, value):',
    '        return value + 1',
    'print(Callable()(value=6))',
  ].join('\n'), { filename: 'bridge.py', argv: ['one'] });
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(stdout.join(''), "True True True True\nTrue peony peony\n['bridge.py', 'one']\nout\n4\n7\n");
  assert.equal(stderr.join(''), 'stream\n');
});

test('shipping WASM uses one resumable pump for CLOCK and SLEEP without replay', async () => {
  const peony = await load();
  const output = [];
  const events = [];
  const session = peony.createSession({
    quantum: 1,
    stdout: (text) => output.push(text),
    wallClock: async () => {
      events.push(['clock', 'wall']);
      return 12.5;
    },
    monotonicClock: async () => {
      events.push(['clock', 'monotonic']);
      return 7.25;
    },
    sleep: async (seconds) => {
      events.push(['sleep', seconds]);
    },
  });
  const result = await session.run([
    'import time',
    'print(time.time(), time.monotonic())',
    'time.sleep(0)',
    'print("resumed")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), '12.5 7.25\nresumed\n');
  assert.deepEqual(events, [['clock', 'wall'], ['clock', 'monotonic'], ['sleep', 0]]);
});

test('shipping WASM requests HTTP reply and keeps native response data across a callback', async () => {
  const peony = await load();
  const output = [];
  const calls = [];
  const session = peony.createSession({
    quantum: 1,
    stdout: (text) => output.push(text),
    fetch: async (url, init) => {
      calls.push([url, init.method]);
      return new Response('{"answer": 42}', {
        status: 200,
        headers: { 'content-type': 'application/json; charset=utf-8' },
      });
    },
    input: async () => 'yes',
  });
  const result = await session.run([
    'import requests',
    'import re',
    'response = requests.get("https://example.test/data")',
    'print(response.status_code, response.json()["answer"])',
    'calls = 0',
    'def replacement(match):',
    '    global calls',
    '    calls += 1',
    '    return input("Replace: ")',
    'print(re.sub("x", replacement, "x"), calls)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), '200 42\nReplace: yes 1\n');
  assert.deepEqual(calls, [['https://example.test/data', 'GET']]);
});
