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
const pythonVersion = await identifyPython(python);
const wasm = new Uint8Array(await readFile(wasmPath));
const loadStarted = performance.now();
const peony = await Peony.load(wasm);
const peonyLoadMs = performance.now() - loadStarted;
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
    const peonySamples = [];
    let expected = null;

    for (let repetition = 0; repetition < warmups + samples; repetition++) {
      const repetitionRoot = join(caseRoot, String(repetition));
      await prepareCaseDirectory(repetitionRoot, item);
      let cpython;
      let peonyResult;
      if (repetition % 2 === 0) {
        cpython = await runCpython({ python, item, caseRoot: repetitionRoot, argv, timeoutMs });
        peonyResult = await runPeony({ peony, item, argv });
      } else {
        peonyResult = await runPeony({ peony, item, argv });
        cpython = await runCpython({ python, item, caseRoot: repetitionRoot, argv, timeoutMs });
      }
      assertCompleted(item.id, 'CPython', cpython);
      assertCompleted(item.id, 'Peony', peonyResult);
      assert.equal(peonyResult.stdout, cpython.stdout, mismatchMessage(item.id, 'stdout', cpython.stdout, peonyResult.stdout));
      assert.equal(peonyResult.stderr, cpython.stderr, mismatchMessage(item.id, 'stderr', cpython.stderr, peonyResult.stderr));
      const visible = `${cpython.stdout}\0${cpython.stderr}`;
      if (expected === null) expected = visible;
      else assert.equal(visible, expected, `${item.id}: output changed between repetitions`);
      if (repetition >= warmups) {
        cpythonSamples.push(cpython);
        peonySamples.push(peonyResult);
      }
    }

    const inputHash = createHash('sha256').update(item.sourceBytes);
    for (const fixture of item.fixtures) inputHash.update('\0').update(fixture.path).update('\0').update(fixture.bytes);
    inputHash.update('\0').update(JSON.stringify(argv));
    const cpythonTiming = timing(cpythonSamples.map(sample => sample.elapsedMs));
    const peonyTiming = timing(peonySamples.map(sample => sample.elapsedMs));
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
      peony: {
        ...peonyTiming,
        medianInstructions: percentile(peonySamples.map(sample => sample.instructions), 0.5),
        medianWork: percentile(peonySamples.map(sample => sample.work), 0.5),
        peakSessionBytes: Math.max(...peonySamples.map(sample => sample.peakSessionBytes)),
      },
      peonyToCpython: peonyTiming.medianMs / cpythonTiming.medianMs,
    });
  }

  const report = {
    schema: 1,
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
      peonyLoadMs,
    },
    summary: {
      compared: records.length,
      passed: records.length,
      geometricMeanPeonyToCpython: geometricMean(records.map(record => record.peonyToCpython)),
      totalMedianMs: {
        cpython: sum(records.map(record => record.cpython.medianMs)),
        peony: sum(records.map(record => record.peony.medianMs)),
      },
    },
    cases: records,
  };
  const serialized = `${JSON.stringify(report, null, 2)}\n`;
  if (options.jsonPath) await writeFile(resolve(options.jsonPath), serialized);
  const reportPath = resolve(options.reportPath ?? join(root, 'report.md'));
  await writeFile(reportPath, renderMarkdown(report));
  process.stdout.write(`${records.length}/${records.length} cases matched ${pythonVersion}; report: ${relative(repositoryRoot, reportPath).replaceAll(sep, '/')}\n`);
} finally {
  try {
    await peony.terminate();
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

async function runPeony({ peony, item, argv }) {
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
    `**${report.summary.passed}/${report.summary.compared} cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.`,
    '',
    '## Inputs',
    '',
    '| Input | Value |',
    '|---|---|',
    `| Corpus | v${report.corpus.version}, \`${report.corpus.sha256}\` |`,
    `| Profile | ${report.corpus.profile}; scale ${scaleText}; ${report.corpus.warmups} ${warmupLabel}; ${report.corpus.samples} ${sampleLabel} |`,
    `| CPython | ${report.environment.cpython} via \`${report.environment.cpythonExecutable}\` |`,
    `| Peony WASM | ${formatInteger(report.environment.wasmBytes)} bytes; \`${report.environment.wasmSha256}\` |`,
    `| Host | ${report.environment.platform}; ${report.environment.node}; Worker load ${formatMs(report.environment.peonyLoadMs)} ms |`,
    '',
    '## Aggregate',
    '',
    '| Measure | CPython | Peony |',
    '|---|---:|---:|',
    `| Sum of case medians | ${formatMs(report.summary.totalMedianMs.cpython)} ms | ${formatMs(report.summary.totalMedianMs.peony)} ms |`,
    `| Geometric mean Peony/CPython ratio | 1.00x | ${report.summary.geometricMeanPeonyToCpython.toFixed(2)}x |`,
    '',
    '## Case measurements',
    '',
    'Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.',
    '',
  ];
  const groups = [
    ['Core language and objects', 'core/'],
    ['Native libraries', 'libraries/'],
    ['Integrated workloads', 'workloads/'],
  ];
  for (const [heading, prefix] of groups) {
    lines.push(`### ${heading}`, '');
    lines.push('| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |');
    lines.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|');
    for (const record of report.cases.filter(item => item.id.startsWith(prefix))) {
      lines.push(`| \`${record.id.slice(prefix.length)}\` | ${formatMs(record.cpython.medianMs)} | ${formatMs(record.cpython.p95Ms)} | ${formatMs(record.peony.medianMs)} | ${formatMs(record.peony.p95Ms)} | ${record.peonyToCpython.toFixed(2)}x | ${formatInteger(record.peony.medianInstructions)} | ${formatInteger(record.peony.medianWork)} | ${(record.peony.peakSessionBytes / (1024 * 1024)).toFixed(2)} |`);
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
    `  --timeout-ms N      CPython process timeout per run\n` +
    `  --python PATH       CPython 3.12 executable\n` +
    `  --wasm PATH         shipping WASM artifact\n` +
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
