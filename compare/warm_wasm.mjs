import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { performance } from 'node:perf_hooks';
import { Peony } from '../web/peony.mjs';

const wasm = new Uint8Array(await readFile(process.argv[2]));
const peony = await Peony.load(wasm);
const send = value => process.stdout.write(`${JSON.stringify(value)}\n`);
let source;
let filename;
let fixtures;
send({ ready: true, rss_bytes: process.memoryUsage().rss });

try {
  for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
    try {
      const request = JSON.parse(line);
      if (request.op === 'setup') {
        source = request.source;
        filename = request.filename;
        fixtures = request.fixtures.map(item => ({ path: item.path, bytes: Buffer.from(item.base64, 'base64') }));
        send({ ok: true });
        continue;
      }
      if (request.op !== 'run' || source === undefined) throw new Error('expected a configured run');
      const stdout = [];
      const stderr = [];
      const session = peony.createSession({
        stdout: text => stdout.push(text),
        stderr: text => stderr.push(text),
        quantum: 100_000,
        maxInstructions: 2_000_000_000,
        maxMemoryBytes: 256 * 1024 * 1024,
        maxVfsBytes: 32 * 1024 * 1024,
        maxFileBytes: 16 * 1024 * 1024,
        seed: 'peony-comparison-corpus-v1',
      });
      try {
        const directories = new Set();
        for (const fixture of fixtures) {
          const parts = fixture.path.split('/').slice(0, -1);
          for (let length = 1; length <= parts.length; length += 1) directories.add(`/home/${parts.slice(0, length).join('/')}`);
        }
        for (const directory of [...directories].sort()) await session.vfsMkdir(directory);
        for (const fixture of fixtures) await session.writeFile(`/home/${fixture.path}`, fixture.bytes);
        await session.stats();
        const baseline = process.memoryUsage().rss;
        const highWaterBefore = process.resourceUsage().maxRSS * 1024;
        let peak = baseline;
        const sample = () => { peak = Math.max(peak, process.memoryUsage().rss); };
        const poll = setInterval(sample, 1);
        let result;
        let elapsedMs;
        try {
          const started = performance.now();
          result = await session.run(source, { filename, argv: request.argv });
          elapsedMs = performance.now() - started;
        } finally {
          clearInterval(poll);
          sample();
          const highWaterAfter = process.resourceUsage().maxRSS * 1024;
          if (highWaterAfter > highWaterBefore) peak = Math.max(peak, highWaterAfter);
        }
        const stats = await session.stats();
        send({ ok: true, status: result.status, error: result.error?.message ?? '',
          stdout: stdout.join(''), stderr: stderr.join(''), elapsed_ns: Math.round(elapsedMs * 1e6),
          baseline_rss_bytes: baseline, peak_rss_bytes: peak,
          instructions: result.counters.instructions, work: result.counters.work,
          peak_session_bytes: stats.peakSessionBytes });
      } finally {
        await session.destroy();
      }
    } catch (error) {
      send({ ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  }
} finally {
  await peony.terminate();
}
