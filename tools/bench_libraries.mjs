#!/usr/bin/env node
// Opt-in ReleaseSmall end-to-end measurements. Python below is learner workload,
// while this host code only supplies fixed files, runs sessions, and records data.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { brotliCompressSync, constants as zlibConstants } from 'node:zlib';
import { Peony } from '../web/peony.mjs';

const wasm = new Uint8Array(await readFile(new URL('../zig-out/peony.wasm', import.meta.url)));
const started = performance.now();
const peony = await Peony.load(wasm);
const instantiateMs = performance.now() - started;
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const filter = process.argv[2] ?? process.env.PEONY_BENCH_FILTER;
const warmups = Number(process.argv[3] ?? process.env.PEONY_BENCH_WARMUPS ?? 3);
const repetitions = Number(process.argv[4] ?? process.env.PEONY_BENCH_REPS ?? 10);
if (!Number.isInteger(warmups) || warmups < 0 || !Number.isInteger(repetitions) || repetitions < 1) throw new RangeError('invalid benchmark repetition counts');
const words = Array.from({ length: 8000 }, (_, index) => ['red', 'blue', 'green', 'gold', 'black', 'white', 'pink', 'gray'][index % 8]).join(' ');
const csv = Array.from({ length: 4000 }, (_, index) => `${index},${index % 17}\n`).join('');
const json = JSON.stringify({ rows: Array.from({ length: 4000 }, (_, index) => ({ id: index, value: index % 17, text: 'é' })) });
const pathText = 'abcdefghij\n'.repeat(1500);

const workloads = [
  {
    name: 'counter-word-frequency',
    files: { '/course/words.txt': words },
    source: 'from collections import Counter\nwith open("/course/words.txt") as f: counts = Counter(f.read().split())\nprint(counts["red"], counts.total())\n',
    expected: '1000 8000\n',
  },
  {
    name: 'csv-aggregation',
    files: { '/course/rows.csv': csv },
    source: 'import csv\ntotal = 0\nwith open("/course/rows.csv", newline="") as f:\n    for row in csv.reader(f): total += int(row[1])\nprint(total)\n',
    expected: `${Array.from({ length: 4000 }, (_, index) => index % 17).reduce((left, right) => left + right, 0)}\n`,
  },
  {
    name: 'json-parse-dump',
    files: { '/course/rows.json': json },
    source: 'import json\nwith open("/course/rows.json") as f: data = json.load(f)\nencoded = json.dumps(data, ensure_ascii=False, sort_keys=True)\nprint(len(data["rows"]), len(encoded) > 100000)\n',
    expected: '4000 True\n',
  },
  {
    name: 'path-vfs-read',
    files: { '/course/text.txt': pathText },
    source: 'from pathlib import Path\npath = Path("/course/text.txt")\ntotal = 0\nfor unused in range(30): total += len(path.read_text())\nprint(total)\n',
    expected: `${pathText.length * 30}\n`,
  },
  {
    name: 'deepcopy-alias-cycle',
    files: {},
    source: 'import copy\nchild = [1, 2, 3]\nsource = [child, child]\nsource.append(source)\ncount = 0\nfor unused in range(100):\n    result = copy.deepcopy(source)\n    count += result[0] is result[1] and result[2] is result\nprint(count)\n',
    expected: '100\n',
  },
  {
    name: 'random-sample-25k-of-100k',
    files: {},
    source: 'import random\nrandom.seed(1)\nprint(len(random.sample(range(100000), 25000)))\n',
    expected: '25000\n',
  },
];

const records = [];
for (const workload of workloads.filter(item => !filter || item.name === filter)) {
  process.stderr.write(`PEONY_BENCH_START ${workload.name}\n`);
  const samples = [];
  let peakLinearBytes = peony.exports.memory.buffer.byteLength;
  for (let repetition = 0; repetition < warmups + repetitions; repetition++) {
    const output = [];
    const session = peony.createSession({ stdout: text => output.push(text), quantum: 50_000, maxInstructions: 50_000_000 });
    try {
      session.mount(workload.files);
      const start = performance.now();
      const result = await session.run(workload.source, { filename: `${workload.name}.py` });
      const elapsedMs = performance.now() - start;
      if (result.status !== 'completed') throw new Error(`${workload.name}: ${result.status}: ${result.error?.message ?? ''}`);
      if (output.join('') !== workload.expected) throw new Error(`${workload.name}: output ${JSON.stringify(output.join(''))}`);
      peakLinearBytes = Math.max(peakLinearBytes, peony.exports.memory.buffer.byteLength);
      if (repetition >= warmups) samples.push({ elapsedMs, ...result.counters });
    } finally {
      session.destroy();
    }
  }
  const input = JSON.stringify({ source: workload.source, files: workload.files });
  records.push({
    name: workload.name,
    inputSha256: sha(input),
    inputBytes: Buffer.byteLength(input),
    warmups,
    repetitions,
    medianRunMsIncludingCompile: percentile(samples.map(item => item.elapsedMs), 0.5),
    p95RunMsIncludingCompile: percentile(samples.map(item => item.elapsedMs), 0.95),
    medianInstructions: percentile(samples.map(item => item.instructions), 0.5),
    medianWork: percentile(samples.map(item => item.work), 0.5),
    peakLinearBytes,
  });
}
const compressed = brotliCompressSync(wasm, { params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 11 } });
process.stdout.write(`${JSON.stringify({ node: process.version, artifactSha256: sha(wasm), rawBytes: wasm.length, brotliQ11Bytes: compressed.length, instantiateMs, workloads: records })}\n`);

function percentile(values, fraction) {
  const sorted = values.slice().sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}
