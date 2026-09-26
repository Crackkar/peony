import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Peony } from '../web/peony.mjs';

const wasmUrl = new URL('../zig-out/peony.wasm', import.meta.url);

test('public Peony loads and runs only inside a Worker', { concurrency: false }, async () => {
  const bytes = new Uint8Array(await readFile(wasmUrl));
  const originalInstantiate = WebAssembly.instantiate;
  const originalCompile = WebAssembly.compile;
  WebAssembly.instantiate = () => { throw new Error('WASM ran on the calling thread'); };
  WebAssembly.compile = () => { throw new Error('WASM compiled on the calling thread'); };
  let peony;
  try {
    peony = await Peony.load(bytes);
    const output = [];
    const session = peony.createSession({ stdout: text => output.push(text) });
    const result = await session.run('print(6 * 7)\n');
    assert.equal(result.status, 'completed', result.error?.message);
    assert.equal(output.join(''), '42\n');
    const stats = await session.stats();
    assert.ok(stats.work >= result.counters.work);
    assert.ok(stats.peakSessionBytes >= stats.liveSessionBytes);
    assert.ok(stats.gcObjects >= 0);
    const collected = await session.collectGarbage();
    assert.ok(collected.gcCollections > stats.gcCollections);
    await session.destroy();
  } finally {
    WebAssembly.instantiate = originalInstantiate;
    WebAssembly.compile = originalCompile;
    if (peony?.terminate) await peony.terminate();
  }
});

test('Worker session keeps host callbacks, files, input and cancellation usable', async () => {
  const peony = await Peony.load(new Uint8Array(await readFile(wasmUrl)));
  const output = [];
  const prompts = [];
  try {
    const session = peony.createSession({
      quantum: 256,
      stdout: text => output.push(text),
      input: async prompt => { prompts.push(prompt); return 'Ada'; },
    });
    await session.writeFile('/home/note.txt', 'saved');
    assert.equal(new TextDecoder().decode(await session.readFile('/home/note.txt')), 'saved');
    const first = await session.run('name = input("Name? ")\nprint(name)\n');
    assert.equal(first.status, 'completed', first.error?.message);
    assert.deepEqual(prompts, ['Name? ']);
    assert.ok(output.join('').includes('Ada\n'));

    const second = await session.run('print(open("/home/note.txt").read())\n');
    assert.equal(second.status, 'completed', second.error?.message);
    assert.ok(output.join('').includes('saved\n'));

    let markerResolve;
    const marker = new Promise(resolve => { markerResolve = resolve; });
    const looping = peony.createSession({
      quantum: 128,
      stdout: text => { if (text.includes('ready')) markerResolve(); },
    });
    const pending = looping.run('print("ready", flush=True)\nwhile True:\n    pass\n');
    await marker;
    looping.cancel();
    assert.equal((await pending).status, 'cancelled');
    await looping.destroy();
    await session.destroy();
  } finally {
    await peony.terminate();
  }
});
