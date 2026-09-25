#!/usr/bin/env node
// Compare scalar and 16-byte vector JSON byte classification in Node's WASM
// engine. Both variants see identical learner JSON bytes and boundary cases.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { brotliCompressSync, constants as zlibConstants } from 'node:zlib';

const files = {
  scalar: new URL('../.zig-cache/size-probes/simd-scalar.wasm', import.meta.url),
  vector: new URL('../.zig-cache/size-probes/simd-vector.wasm', import.meta.url),
};
const artifacts = {};
for (const [name, file] of Object.entries(files)) {
  const bytes = new Uint8Array(await readFile(file));
  const started = performance.now();
  const { instance, module } = await WebAssembly.instantiate(bytes, {});
  artifacts[name] = {
    bytes,
    instance,
    module,
    instantiateMs: performance.now() - started,
    rawBytes: bytes.length,
    brotliQ11Bytes: brotliCompressSync(bytes, { params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 11 } }).length,
    codeSimdPrefixes: countSimdPrefixes(bytes),
    targetFeatures: WebAssembly.Module.customSections(module, 'target_features').map(section => Buffer.from(section).toString('hex')),
  };
}

const encoder = new TextEncoder();
const json = JSON.stringify({ rows: Array.from({ length: 4000 }, (_, index) => ({ id: index, value: index % 17, text: 'é' })) });
const inputs = [
  ['short-8', encoder.encode('a"é\\"{}')],
  ['short-31', encoder.encode('a'.repeat(29) + '"\\')],
  ['unaligned-65', encoder.encode('a'.repeat(61) + '"\\é')],
  ['json-136k', encoder.encode(json)],
  ['invalid-utf8', Uint8Array.from([0x61, 0xc0, 0xaf, 0x22, 0x5c, 0x00, 0x80, 0x62, 0x63])],
];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const records = [];
for (const [name, input] of inputs) {
  const row = { name, inputBytes: input.length, inputSha256: hash(input), warmups: 3, repetitions: 10 };
  for (const [variant, artifact] of Object.entries(artifacts)) {
    const { memory, probe_alloc: alloc, probe_scalar: scalar, probe_vector: vector } = artifact.instance.exports;
    const pointer = alloc(input.length);
    if (!pointer) throw new Error(`${variant}: allocation failed`);
    new Uint8Array(memory.buffer, pointer, input.length).set(input);
    const expected = scalar(pointer, input.length);
    if (vector(pointer, input.length) !== expected) throw new Error(`${variant}/${name}: scalar/vector mismatch`);
    const calls = input.length < 100 ? 20_000 : 500;
    for (const [method, fn] of [['scalar', scalar], ['vector', vector]]) {
      const samples = [];
      for (let repetition = 0; repetition < 13; repetition++) {
        const start = performance.now();
        let result = 0;
        for (let index = 0; index < calls; index++) result = fn(pointer, input.length);
        const elapsedMs = performance.now() - start;
        if (result !== expected) throw new Error(`${variant}/${name}/${method}: result changed`);
        if (repetition >= 3) samples.push(elapsedMs / calls);
      }
      row[`${variant}_${method}`] = {
        classifications: expected,
        callsPerSample: calls,
        medianMsPerCall: percentile(samples, 0.5),
        p95MsPerCall: percentile(samples, 0.95),
        peakLinearBytes: memory.buffer.byteLength,
      };
    }
  }
  records.push(row);
}
process.stdout.write(`${JSON.stringify({ node: process.version, mode: 'ReleaseSmall', artifacts: Object.fromEntries(Object.entries(artifacts).map(([name, item]) => [name, {
  sha256: hash(item.bytes), rawBytes: item.rawBytes, brotliQ11Bytes: item.brotliQ11Bytes,
  instantiateMs: item.instantiateMs, codeSimdPrefixes: item.codeSimdPrefixes, targetFeatures: item.targetFeatures,
}])), workloads: records })}\n`);

function percentile(values, fraction) {
  const sorted = values.slice().sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}

function countSimdPrefixes(bytes) {
  let cursor = 8;
  while (cursor < bytes.length) {
    const id = bytes[cursor++];
    const length = leb();
    if (id === 10) {
      let count = 0;
      for (const byte of bytes.subarray(cursor, cursor + length)) if (byte === 0xfd) count++;
      return count;
    }
    cursor += length;
  }
  return 0;
  function leb() {
    let result = 0;
    let shift = 0;
    while (true) {
      const byte = bytes[cursor++];
      result += (byte & 0x7f) * 2 ** shift;
      if ((byte & 0x80) === 0) return result;
      shift += 7;
    }
  }
}
