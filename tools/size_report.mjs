import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { brotliCompressSync, constants as zlibConstants } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const unicodeBlob = path.join(root, '.zig-cache', 'size-probes', 'unicode15-property-prototype.bin');
const quality = 11;
const probes = ['bigint', 'json', 'unicode15'];
const toolchain = exec('zig', ['version']);

if (toolchain !== '0.16.0') {
  throw new Error(`Peony requires Zig 0.16.0, found ${toolchain}`);
}

await mkdir(path.dirname(unicodeBlob), { recursive: true });
exec('node', ['tools/generate_unicode15_probe.mjs', '.zig-cache/size-probes/unicode15-property-prototype.bin']);
await prepareProbeSources();
exec('zig', ['build', 'wasm']);

for (const name of probes) exec('zig', ['build', `probe-${name}`]);

const baseline = await measure('zig-out/peony.wasm');
const results = {};
for (const name of probes) {
  const probe = await measure(`zig-out/peony-probe-${name}.wasm`);
  results[name] = {
    artifact: `zig-out/peony-probe-${name}.wasm`,
    rawBytes: probe.rawBytes,
    brotliQ11Bytes: probe.brotliQ11Bytes,
    rawDeltaBytes: probe.rawBytes - baseline.rawBytes,
    brotliQ11DeltaBytes: probe.brotliQ11Bytes - baseline.brotliQ11Bytes,
  };
}

const report = {
  toolchain,
  unicodeVersion: '15.0.0',
  brotliQuality: quality,
  baseline: {
    artifact: 'zig-out/peony.wasm',
    rawBytes: baseline.rawBytes,
    brotliQ11Bytes: baseline.brotliQ11Bytes,
  },
  probes: results,
  commands: [
    'zig version',
    'node tools/generate_unicode15_probe.mjs .zig-cache/size-probes/unicode15-property-prototype.bin',
    'zig build wasm',
    ...probes.map((name) => `zig build probe-${name}`),
    'node tools/size_report.mjs [--json]',
  ],
};

if (process.argv.includes('--json')) {
  process.stdout.write(`${JSON.stringify(report)}\n`);
} else {
  process.stdout.write(`Zig ${report.toolchain}; Brotli quality ${quality}\n`);
  process.stdout.write(`Unicode prototype: ${unicodeBlob}\n`);
  process.stdout.write(`Baseline: ${baseline.rawBytes} raw, ${baseline.brotliQ11Bytes} Brotli-q11 bytes\n`);
  for (const [name, item] of Object.entries(results)) {
    process.stdout.write(
      `${name}: ${item.rawBytes} raw (${signed(item.rawDeltaBytes)}), ` +
      `${item.brotliQ11Bytes} Brotli-q11 (${signed(item.brotliQ11DeltaBytes)})\n`,
    );
  }
  process.stdout.write(`Commands: ${report.commands.join(' ; ')}\n`);
}

function exec(command, args) {
  return execFileSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'inherit'],
    maxBuffer: 4 * 1024 * 1024,
  }).trim();
}

async function measure(relativePath) {
  const bytes = await readFile(path.join(root, relativePath));
  const compressed = brotliCompressSync(bytes, {
    params: { [zlibConstants.BROTLI_PARAM_QUALITY]: quality },
  });
  return { rawBytes: bytes.length, brotliQ11Bytes: compressed.length };
}

async function prepareProbeSources() {
  const probeDir = path.join(root, '.zig-cache', 'size-probes');
  const probeRuntimeDir = path.join(probeDir, 'runtime');
  const runtimeSource = await readFile(path.join(root, 'src', 'wasm.zig'), 'utf8');
  await copyFile(path.join(root, 'src', 'abi.zig'), path.join(probeDir, 'abi.zig'));
  await mkdir(probeRuntimeDir, { recursive: true });
  for (const name of ['allocator', 'gc', 'object', 'roots']) {
    await copyFile(
      path.join(root, 'src', 'runtime', `${name}.zig`),
      path.join(probeRuntimeDir, `${name}.zig`),
    );
  }
  for (const name of probes) {
    const fragment = await readFile(path.join(root, 'tools', 'size-probes', `${name}.zig`), 'utf8');
    await writeFile(path.join(probeDir, `${name}-root.zig`), `${runtimeSource}\n\n${fragment}`);
  }
}

function signed(value) {
  return value >= 0 ? `+${value}` : `${value}`;
}
