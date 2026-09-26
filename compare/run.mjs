#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { mkdir, readFile, rm, rmdir, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { performance } from 'node:perf_hooks';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Peony } from '../web/peony.mjs';

const execFileAsync = promisify(execFile);
const root = resolve(fileURLToPath(new URL('./', import.meta.url)));
const repositoryRoot = resolve(root, '..');
const options = parseArguments(process.argv.slice(2));
const manifestBytes = await readFile(join(root, 'corpus.json'));
const manifest = JSON.parse(manifestBytes);
validateManifest(manifest);

const selected = manifest.cases.filter(item => matches(item, options.filter));
if (options.list) {
  for (const item of selected) process.stdout.write(`${item.id}\t${item.tags.join(',')}\n`);
  process.exit(0);
}
if (selected.length === 0) throw new Error(`no corpus cases match ${JSON.stringify(options.filter)}`);

const profile = manifest.profiles[options.profile];
const warmups = options.warmups ?? profile.warmups;
const samples = options.samples ?? profile.samples;
const timeoutMs = options.timeoutMs ?? profile.timeoutMs;
const python = options.python ?? process.env.PEONY_CPYTHON ?? 'python';
const wasmPath = resolve(repositoryRoot, options.wasm ?? process.env.PEONY_COMPARE_WASM ?? 'zig-out/peony.wasm');
const nativePath = resolve(repositoryRoot, options.native ?? process.env.PEONY_COMPARE_NATIVE ?? join('zig-out', process.platform === 'win32' ? 'peony.exe' : 'peony'));
const pythonVersion = await identifyPython(python);
const wasm = new Uint8Array(await readFile(wasmPath));
const nativeBinary = new Uint8Array(await readFile(nativePath));
const nativeVersion = await identifyNative(nativePath);
const loadStarted = performance.now();
const peonyWasm = await Peony.load(wasm);
const wasmLoadMs = performance.now() - loadStarted;
const workspaceRoot = join(repositoryRoot, 'zig-out', 'compare-work');
const runWorkspace = join(workspaceRoot, randomUUID());
await mkdir(runWorkspace, { recursive: true });

let corpusHasher = createHash('sha256').update(manifestBytes);
const prepared = [];
try {
  for (const item of manifest.cases) {
    const sourcePath = containedPath(root, item.file);
    const sourceBytes = await readFile(sourcePath);
    const source = sourceBytes.toString('utf8');
    const fixtures = [];
    for (const fixture of item.fixtures ?? []) {
      const bytes = await readFile(containedPath(root, fixture.source));
      validateRelativePath(fixture.path, `${item.id} fixture path`);
      fixtures.push({ path: fixture.path.replaceAll('\\', '/'), bytes });
    }
    corpusHasher.update('\0').update(item.id).update('\0').update(sourceBytes);
    for (const fixture of fixtures) corpusHasher.update('\0').update(fixture.path).update('\0').update(fixture.bytes);
    if (matches(item, options.filter)) prepared.push({ ...item, source, sourceBytes, fixtures });
  }

  const records = [];
  for (let index = 0; index < prepared.length; index++) {
    const item = prepared[index];
    const scale = item.scales?.[options.profile] ?? profile.scale;
    const argv = [String(scale), ...(item.argv ?? [])];
    progress(`[${index + 1}/${prepared.length}] ${item.id} (scale ${scale})`);
    const caseRoot = join(runWorkspace, item.id.replaceAll('/', '__'));
    const cpythonSamples = [];
    const wasmSamples = [];
    const nativeSamples = [];
    let expected = null;

    for (let repetition = 0; repetition < warmups + samples; repetition++) {
      const repetitionRoot = join(caseRoot, String(repetition));
      await prepareCaseDirectory(repetitionRoot, item);
      let cpython;
      let wasmResult;
      let nativeResult;
      const runners = [
        () => runCpython({ python, item, caseRoot: repetitionRoot, argv, timeoutMs }).then(result => { cpython = result; }),
        () => runPeonyWasm({ peony: peonyWasm, item, argv }).then(result => { wasmResult = result; }),
        () => runPeonyNative({ nativePath, item, caseRoot: repetitionRoot, argv, timeoutMs }).then(result => { nativeResult = result; }),
      ];
      for (let offset = 0; offset < runners.length; offset++) {
        await runners[(repetition + offset) % runners.length]();
      }
      assertCompleted(item.id, 'CPython', cpython);
      assertCompleted(item.id, 'Peony WASM', wasmResult);
      assertCompleted(item.id, 'Peony native', nativeResult);
      assert.equal(wasmResult.stdout, cpython.stdout, mismatchMessage(item.id, 'Peony WASM stdout', cpython.stdout, wasmResult.stdout));
      assert.equal(wasmResult.stderr, cpython.stderr, mismatchMessage(item.id, 'Peony WASM stderr', cpython.stderr, wasmResult.stderr));
      assert.equal(nativeResult.stdout, cpython.stdout, mismatchMessage(item.id, 'Peony native stdout', cpython.stdout, nativeResult.stdout));
      assert.equal(nativeResult.stderr, cpython.stderr, mismatchMessage(item.id, 'Peony native stderr', cpython.stderr, nativeResult.stderr));
      const visible = `${cpython.stdout}\0${cpython.stderr}`;
      if (expected === null) expected = visible;
      else assert.equal(visible, expected, `${item.id}: output changed between repetitions`);
      if (repetition >= warmups) {
        cpythonSamples.push(cpython);
        wasmSamples.push(wasmResult);
        nativeSamples.push(nativeResult);
      }
    }

    const inputHash = createHash('sha256').update(item.sourceBytes);
    for (const fixture of item.fixtures) inputHash.update('\0').update(fixture.path).update('\0').update(fixture.bytes);
    inputHash.update('\0').update(JSON.stringify(argv));
    const cpythonTiming = timing(cpythonSamples.map(sample => sample.elapsedMs));
    const wasmTiming = timing(wasmSamples.map(sample => sample.elapsedMs));
    const nativeTiming = timing(nativeSamples.map(sample => sample.elapsedMs));
    records.push({
      id: item.id,
      tags: item.tags,
      scale,
      argv,
      inputSha256: inputHash.digest('hex'),
      output: {
        sha256: sha(expected),
        stdoutBytes: Buffer.byteLength(cpythonSamples[0].stdout),
        stderrBytes: Buffer.byteLength(cpythonSamples[0].stderr),
      },
      cpython: cpythonTiming,
      wasm: {
        ...wasmTiming,
        medianInstructions: percentile(wasmSamples.map(sample => sample.instructions), 0.5),
        medianWork: percentile(wasmSamples.map(sample => sample.work), 0.5),
        peakSessionBytes: Math.max(...wasmSamples.map(sample => sample.peakSessionBytes)),
      },
      native: {
        ...nativeTiming,
        medianInstructions: percentile(nativeSamples.map(sample => sample.instructions), 0.5),
        medianWork: percentile(nativeSamples.map(sample => sample.work), 0.5),
        peakSessionBytes: Math.max(...nativeSamples.map(sample => sample.peakSessionBytes)),
      },
      wasmToCpython: wasmTiming.medianMs / cpythonTiming.medianMs,
      nativeToCpython: nativeTiming.medianMs / cpythonTiming.medianMs,
    });
  }

  const report = {
    schema: 2,
    corpus: {
      version: manifest.version,
      sha256: corpusHasher.digest('hex'),
      profile: options.profile,
      cases: records.length,
      warmups,
      samples,
    },
    environment: {
      node: process.version,
      platform: `${process.platform}-${process.arch}`,
      cpython: pythonVersion,
      cpythonExecutable: python,
      wasmPath: relative(repositoryRoot, wasmPath).replaceAll(sep, '/'),
      wasmSha256: sha(wasm),
      wasmBytes: wasm.length,
      wasmLoadMs,
      nativePath: relative(repositoryRoot, nativePath).replaceAll(sep, '/'),
      nativeSha256: sha(nativeBinary),
      nativeBytes: nativeBinary.length,
      nativeVersion,
    },
    summary: {
      compared: records.length,
      passed: records.length,
      geometricMeanWasmToCpython: geometricMean(records.map(record => record.wasmToCpython)),
      geometricMeanNativeToCpython: geometricMean(records.map(record => record.nativeToCpython)),
      totalMedianMs: {
        cpython: sum(records.map(record => record.cpython.medianMs)),
        wasm: sum(records.map(record => record.wasm.medianMs)),
        native: sum(records.map(record => record.native.medianMs)),
      },
    },
    cases: records,
  };
  const serialized = `${JSON.stringify(report, null, 2)}\n`;
  if (options.jsonPath) await writeFile(resolve(options.jsonPath), serialized);
  const reportPath = options.reportPath ? resolve(options.reportPath) : options.filter ? null : join(root, 'report.md');
  if (reportPath) await writeFile(reportPath, renderMarkdown(report));
  process.stdout.write(`${records.length}/${records.length} cases matched ${pythonVersion}` + (reportPath ? `; report: ${relative(repositoryRoot, reportPath).replaceAll(sep, '/')}` : '') + '\n');
  if (options.filter) {
    for (const record of records) process.stdout.write(`${record.id}: CPython ${formatMs(record.cpython.medianMs)} ms, Peony WASM ${formatMs(record.wasm.medianMs)} ms (${record.wasmToCpython.toFixed(2)}x), Peony native ${formatMs(record.native.medianMs)} ms (${record.nativeToCpython.toFixed(2)}x)\n`);
  }
} finally {
  try {
    await peonyWasm.terminate();
  } finally {
    await rm(runWorkspace, { recursive: true, force: true });
    try {
      await rmdir(workspaceRoot);
    } catch (error) {
      if (error?.code !== 'ENOENT' && error?.code !== 'ENOTEMPTY') throw error;
    }
  }
}

async function prepareCaseDirectory(caseRoot, item) {
  await mkdir(caseRoot, { recursive: true });
  await writeFile(join(caseRoot, '__corpus_case__.py'), item.sourceBytes);
  for (const fixture of item.fixtures) {
    const path = join(caseRoot, ...fixture.path.split('/'));
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, fixture.bytes);
  }
}

async function runCpython({ python, item, caseRoot, argv, timeoutMs }) {
  const scriptPath = join(caseRoot, '__corpus_case__.py');
  const { stdout, stderr } = await execFileAsync(python, ['-I', '-B', '-X', 'utf8', '-c', cpythonDriver(), scriptPath, item.file, ...argv], {
    cwd: caseRoot,
    encoding: 'utf8',
    env: { ...process.env, PYTHONHASHSEED: '0', PYTHONIOENCODING: 'utf-8' },
    maxBuffer: 2 * 1024 * 1024,
    timeout: timeoutMs,
    windowsHide: true,
  });
  if (stderr !== '') throw new Error(`${item.id}: CPython harness stderr: ${stderr}`);
  const line = stdout.replace(/\r?\n$/, '');
  const fields = line.split('\t');
  if (fields.length !== 6 || fields[0] !== 'PEONY-COMPARE-1') throw new Error(`${item.id}: invalid CPython harness response`);
  return {
    status: fields[1],
    elapsedMs: Number(fields[2]) / 1e6,
    stdout: decodeHex(fields[3]),
    stderr: decodeHex(fields[4]),
    error: decodeHex(fields[5]),
  };
}

async function runPeonyWasm({ peony, item, argv }) {
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
    for (const fixture of item.fixtures) {
      const parts = fixture.path.split('/').slice(0, -1);
      for (let length = 1; length <= parts.length; length++) directories.add(`/home/${parts.slice(0, length).join('/')}`);
    }
    for (const directory of [...directories].sort()) await session.vfsMkdir(directory);
    for (const fixture of item.fixtures) await session.writeFile(`/home/${fixture.path}`, fixture.bytes);
    await session.stats();
    const started = performance.now();
    const result = await session.run(item.source, { filename: item.file, argv });
    const elapsedMs = performance.now() - started;
    const stats = await session.stats();
    return {
      status: result.status,
      error: result.error?.message ?? '',
      stdout: stdout.join(''),
      stderr: stderr.join(''),
      elapsedMs,
      instructions: result.counters.instructions,
      work: result.counters.work,
      peakSessionBytes: stats.peakSessionBytes,
    };
  } finally {
    await session.destroy();
  }
}

async function runPeonyNative({ nativePath, item, caseRoot, argv, timeoutMs }) {
  const nativeRoot = `${caseRoot}__native`;
  await mkdir(nativeRoot, { recursive: true });
  const scriptPath = join(nativeRoot, '__corpus_case__.py');
  const metricsPath = join(nativeRoot, '__peony_native_metrics__.json');
  await writeFile(scriptPath, item.sourceBytes);
  for (const fixture of item.fixtures) {
    const fixturePath = join(nativeRoot, ...fixture.path.split('/'));
    await mkdir(dirname(fixturePath), { recursive: true });
    await writeFile(fixturePath, fixture.bytes);
  }
  const arguments_ = [
    '--filename', item.file,
    '--max-memory', String(256 * 1024 * 1024),
    '--max-work', '2000000000',
    '--quantum', '100000',
    '--max-vfs', String(32 * 1024 * 1024),
    '--max-file', String(16 * 1024 * 1024),
    '--seed', 'peony-comparison-corpus-v1',
    '--metrics', metricsPath,
  ];
  for (const fixture of item.fixtures) {
    arguments_.push('--mount', join(nativeRoot, ...fixture.path.split('/')), `/home/${fixture.path}`);
  }
  arguments_.push(scriptPath, ...argv);
  const { stdout, stderr } = await execFileAsync(nativePath, arguments_, {
    cwd: nativeRoot,
    encoding: 'utf8',
    maxBuffer: 2 * 1024 * 1024,
    timeout: timeoutMs,
    windowsHide: true,
  });
  const metrics = JSON.parse(await readFile(metricsPath, 'utf8'));
  if (metrics.schema !== 1) throw new Error(`${item.id}: unsupported native metrics schema`);
  return {
    status: metrics.status,
    error: '',
    stdout,
    stderr,
    elapsedMs: metrics.elapsed_ns / 1e6,
    instructions: metrics.instructions,
    work: metrics.work,
    peakSessionBytes: metrics.peak_session_bytes,
  };
}

function assertCompleted(id, engine, result) {
  assert.equal(result.status, 'completed', `${id}: ${engine} ${result.status}: ${result.error}`);
}

function mismatchMessage(id, stream, expected, actual) {
  return `${id}: ${stream} differs\nCPython: ${JSON.stringify(abbreviate(expected))}\nPeony:  ${JSON.stringify(abbreviate(actual))}`;
}

function abbreviate(value) {
  return value.length <= 500 ? value : `${value.slice(0, 500)}... (${value.length} characters)`;
}

function timing(values) {
  return {
    medianMs: percentile(values, 0.5),
    p95Ms: percentile(values, 0.95),
    minMs: Math.min(...values),
    maxMs: Math.max(...values),
  };
}

function renderMarkdown(report) {
  const scales = [...new Set(report.cases.map(record => record.scale))];
  const scaleText = scales.length === 1 ? String(scales[0]) : 'case-specific';
  const warmupLabel = report.corpus.warmups === 1 ? 'warmup' : 'warmups';
  const sampleLabel = report.corpus.samples === 1 ? 'measured sample' : 'measured samples';
  const lines = [
    '# Peony comparison report',
    '',
    `**${report.summary.passed}/${report.summary.compared} cases matched CPython exactly on Peony WASM and Peony native.** Every measured repetition completed on all three engines with identical standard output and standard error.`,
    '',
    '## Inputs',
    '',
    '| Input | Value |',
    '|---|---|',
    `| Corpus | v${report.corpus.version}, \`${report.corpus.sha256}\` |`,
    `| Profile | ${report.corpus.profile}; scale ${scaleText}; ${report.corpus.warmups} ${warmupLabel}; ${report.corpus.samples} ${sampleLabel} |`,
    `| CPython | ${report.environment.cpython} via \`${report.environment.cpythonExecutable}\` |`,
    `| Peony WASM | \`${report.environment.wasmPath}\`; ${formatInteger(report.environment.wasmBytes)} bytes; \`${report.environment.wasmSha256}\` |`,
    `| Peony native | \`${report.environment.nativePath}\`; ${formatInteger(report.environment.nativeBytes)} bytes; \`${report.environment.nativeSha256}\`; ${report.environment.nativeVersion} |`,
    `| Host | ${report.environment.platform}; ${report.environment.node}; Worker load ${formatMs(report.environment.wasmLoadMs)} ms |`,
    '',
    '## Aggregate',
    '',
    '| Measure | CPython | Peony WASM | Peony native |',
    '|---|---:|---:|---:|',
    `| Sum of case medians | ${formatMs(report.summary.totalMedianMs.cpython)} ms | ${formatMs(report.summary.totalMedianMs.wasm)} ms | ${formatMs(report.summary.totalMedianMs.native)} ms |`,
    `| Geometric mean runtime/CPython ratio | 1.00x | ${report.summary.geometricMeanWasmToCpython.toFixed(2)}x | ${report.summary.geometricMeanNativeToCpython.toFixed(2)}x |`,
    '',
    '## Case measurements',
    '',
    'Times are median/p95 compile plus execution milliseconds; p95 uses the nearest-rank sample. Instructions and work are shown as WASM/native medians, followed by maximum peak session memory for each target.',
    '',
  ];
  const groups = [
    ['Core language and objects', 'core/'],
    ['Native libraries', 'libraries/'],
    ['Integrated workloads', 'workloads/'],
  ];
  for (const [heading, prefix] of groups) {
    lines.push(`### ${heading}`, '');
    lines.push('| Case | CP ms | WASM ms | W/CP | Native ms | N/CP | Instructions W/N | Work W/N | Peak MiB W/N |');
    lines.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|');
    for (const record of report.cases.filter(item => item.id.startsWith(prefix))) {
      lines.push(`| \`${record.id.slice(prefix.length)}\` | ${formatPair(record.cpython)} | ${formatPair(record.wasm)} | ${record.wasmToCpython.toFixed(2)}x | ${formatPair(record.native)} | ${record.nativeToCpython.toFixed(2)}x | ${formatInteger(record.wasm.medianInstructions)}/${formatInteger(record.native.medianInstructions)} | ${formatInteger(record.wasm.medianWork)}/${formatInteger(record.native.medianWork)} | ${formatMiB(record.wasm.peakSessionBytes)}/${formatMiB(record.native.peakSessionBytes)} |`);
    }
    lines.push('');
  }
  lines.push('The runner and interpretation rules are documented in [the comparison corpus guide](README.md).');
  return `${lines.join('\n')}\n`;
}

function formatMs(value) {
  if (value < 10) return value.toFixed(3);
  if (value < 100) return value.toFixed(2);
  return value.toFixed(1);
}

function formatPair(timingValue) { return `${formatMs(timingValue.medianMs)}/${formatMs(timingValue.p95Ms)}`; }
function formatMiB(bytes) { return (bytes / (1024 * 1024)).toFixed(2); }

function formatInteger(value) { return Math.round(value).toLocaleString('en-US'); }

function percentile(values, fraction) {
  const sorted = values.slice().sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}

function geometricMean(values) {
  return Math.exp(sum(values.map(value => Math.log(value))) / values.length);
}

function sum(values) { return values.reduce((total, value) => total + value, 0); }
function sha(value) { return createHash('sha256').update(value).digest('hex'); }
function decodeHex(value) { return Buffer.from(value, 'hex').toString('utf8'); }
function progress(message) { if (!options.quiet) process.stderr.write(`${message}\n`); }

async function identifyPython(executable) {
  const { stdout, stderr } = await execFileAsync(executable, ['--version'], { encoding: 'utf8', windowsHide: true });
  const version = `${stdout}${stderr}`.trim();
  if (!/^Python 3\.12\.\d+$/.test(version)) throw new Error(`comparison requires CPython 3.12, found ${version}`);
  return version;
}

async function identifyNative(executable) {
  const { stdout, stderr } = await execFileAsync(executable, ['--version'], { encoding: 'utf8', windowsHide: true });
  if (stderr !== '') throw new Error(`native Peony version check wrote to stderr: ${stderr}`);
  const version = stdout.trim();
  if (version !== 'Peony 0.1.0 (Python 3.12 subset)') throw new Error(`unexpected native Peony identity: ${version}`);
  return version;
}

function containedPath(base, path) {
  validateRelativePath(path, 'corpus path');
  const result = resolve(base, path);
  if (result !== base && !result.startsWith(`${base}${sep}`)) throw new Error(`path escapes compare directory: ${path}`);
  return result;
}

function validateRelativePath(path, label) {
  if (typeof path !== 'string' || path.length === 0 || isAbsolute(path) || path.split(/[\\/]/).includes('..')) throw new Error(`${label} must be a contained relative path`);
}

function validateManifest(value) {
  assert.equal(value.schema, 1, 'unsupported corpus schema');
  assert.equal(typeof value.version, 'string');
  assert.ok(value.profiles && typeof value.profiles === 'object');
  assert.ok(Array.isArray(value.cases) && value.cases.length > 0);
  const ids = new Set();
  for (const [name, profileValue] of Object.entries(value.profiles)) {
    assert.ok(Number.isInteger(profileValue.scale) && profileValue.scale > 0, `${name}: invalid scale`);
    assert.ok(Number.isInteger(profileValue.warmups) && profileValue.warmups >= 0, `${name}: invalid warmups`);
    assert.ok(Number.isInteger(profileValue.samples) && profileValue.samples > 0, `${name}: invalid samples`);
    assert.ok(Number.isInteger(profileValue.timeoutMs) && profileValue.timeoutMs > 0, `${name}: invalid timeout`);
  }
  if (!Object.hasOwn(value.profiles, options.profile)) throw new Error(`unknown profile ${options.profile}`);
  for (const item of value.cases) {
    assert.match(item.id, /^[a-z0-9][a-z0-9-]*(\/[a-z0-9][a-z0-9-]*)+$/, `invalid case id ${item.id}`);
    assert.ok(!ids.has(item.id), `duplicate case id ${item.id}`);
    ids.add(item.id);
    validateRelativePath(item.file, `${item.id} file`);
    assert.ok(Array.isArray(item.tags) && item.tags.length > 0, `${item.id}: tags required`);
    for (const fixture of item.fixtures ?? []) {
      validateRelativePath(fixture.source, `${item.id} fixture source`);
      validateRelativePath(fixture.path, `${item.id} fixture path`);
    }
    for (const [name, scale] of Object.entries(item.scales ?? {})) {
      assert.ok(Object.hasOwn(value.profiles, name), `${item.id}: unknown scale profile ${name}`);
      assert.ok(Number.isInteger(scale) && scale > 0, `${item.id}: invalid ${name} scale`);
    }
  }
}

function matches(item, filter) {
  if (!filter) return true;
  const needle = filter.toLowerCase();
  return item.id.includes(needle) || item.tags.some(tag => tag.toLowerCase().includes(needle));
}

function parseArguments(arguments_) {
  const parsed = { profile: 'standard', filter: '', quiet: false, list: false };
  for (let index = 0; index < arguments_.length; index++) {
    const argument = arguments_[index];
    if (argument === '--profile') parsed.profile = requiredValue(arguments_, ++index, argument);
    else if (argument === '--filter') parsed.filter = requiredValue(arguments_, ++index, argument);
    else if (argument === '--warmups') parsed.warmups = positiveInteger(requiredValue(arguments_, ++index, argument), true);
    else if (argument === '--samples') parsed.samples = positiveInteger(requiredValue(arguments_, ++index, argument), false);
    else if (argument === '--timeout-ms') parsed.timeoutMs = positiveInteger(requiredValue(arguments_, ++index, argument), false);
    else if (argument === '--python') parsed.python = requiredValue(arguments_, ++index, argument);
    else if (argument === '--wasm') parsed.wasm = requiredValue(arguments_, ++index, argument);
    else if (argument === '--native') parsed.native = requiredValue(arguments_, ++index, argument);
    else if (argument === '--json') parsed.jsonPath = requiredValue(arguments_, ++index, argument);
    else if (argument === '--report') parsed.reportPath = requiredValue(arguments_, ++index, argument);
    else if (argument === '--quiet') parsed.quiet = true;
    else if (argument === '--list') parsed.list = true;
    else if (argument === '--help') { usage(); process.exit(0); }
    else throw new Error(`unknown argument ${argument}`);
  }
  return parsed;
}

function requiredValue(arguments_, index, flag) {
  if (index >= arguments_.length) throw new Error(`${flag} requires a value`);
  return arguments_[index];
}

function positiveInteger(value, allowZero) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < (allowZero ? 0 : 1)) throw new Error(`invalid count ${value}`);
  return number;
}

function usage() {
  process.stdout.write(`Usage: node compare/run.mjs [options]\n\n` +
    `  --profile smoke|standard|stress\n` +
    `  --filter TEXT       select by case id or tag\n` +
    `  --warmups N         override untimed repetitions\n` +
    `  --samples N         override measured repetitions\n` +
    `  --timeout-ms N      CPython/native process timeout per run\n` +
    `  --python PATH       CPython 3.12 executable\n` +
    `  --wasm PATH         shipping WASM artifact\n` +
    `  --native PATH       shipping native Peony executable\n` +
    `  --json PATH         also write the JSON report to PATH\n` +
    `  --report PATH       write the Markdown report to PATH\n` +
    `  --list              list selected cases without running\n` +
    `  --quiet             suppress progress on stderr\n`);
}

function cpythonDriver() { return String.raw`
import io, sys, time
source_path, display_name, *program_args = sys.argv[1:]
with open(source_path, "r", encoding="utf-8") as source_file:
    source = source_file.read()
sys.path.insert(0, ".")
sys.argv = [display_name, *program_args]
captured_stdout = io.StringIO()
captured_stderr = io.StringIO()
real_stdout, real_stderr = sys.stdout, sys.stderr
status = "completed"
error = ""
started = time.perf_counter_ns()
try:
    sys.stdout, sys.stderr = captured_stdout, captured_stderr
    namespace = {"__name__": "__main__", "__file__": display_name, "__builtins__": __builtins__}
    exec(compile(source, display_name, "exec"), namespace, namespace)
except BaseException as exception:
    status = "error"
    error = type(exception).__name__ + ": " + str(exception)
finally:
    elapsed = time.perf_counter_ns() - started
    sys.stdout, sys.stderr = real_stdout, real_stderr
encode = lambda text: text.encode("utf-8").hex()
real_stdout.write("\t".join(("PEONY-COMPARE-1", status, str(elapsed), encode(captured_stdout.getvalue()), encode(captured_stderr.getvalue()), encode(error))) + "\n")
`; }
