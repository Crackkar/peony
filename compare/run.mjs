#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { mkdir, readFile, rm, rmdir, stat, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

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

async function main() {
const profile = manifest.profiles[options.profile];
const warmups = options.warmups ?? profile.warmups;
const samples = options.samples ?? profile.samples;
const timeoutMs = options.timeoutMs ?? profile.timeoutMs;
const python = options.python ?? process.env.PEONY_CPYTHON ?? 'python';
const wasmPath = resolve(repositoryRoot, options.wasm ?? process.env.PEONY_COMPARE_WASM ?? 'zig-out/peony.wasm');
const nativePath = resolve(repositoryRoot, options.native ?? process.env.PEONY_COMPARE_NATIVE ?? join('zig-out', process.platform === 'win32' ? 'peony.exe' : 'peony'));
const pythonVersion = await identifyPython(python);
const nativeVersion = await identifyNative(nativePath);
const wasm = await readFile(wasmPath);
const native = await readFile(nativePath);
const probePath = await ensureProbe();
const pythonEnv = { ...process.env, PYTHONHASHSEED: '0', PYTHONIOENCODING: 'utf-8', PYTHONDONTWRITEBYTECODE: '1', PYTHONUTF8: '1' };
const workspaceRoot = join(repositoryRoot, 'zig-out', 'compare-work');
const runWorkspace = join(workspaceRoot, randomUUID());
await mkdir(runWorkspace, { recursive: true });

let corpusHasher = createHash('sha256').update(manifestBytes);
try {
  const prepared = [];
  for (const item of manifest.cases) {
    const sourceBytes = await readFile(containedPath(root, item.file));
    const fixtures = [];
    for (const fixture of item.fixtures ?? []) {
      validateRelativePath(fixture.path, `${item.id} fixture path`);
      fixtures.push({ path: fixture.path.replaceAll('\\', '/'), bytes: await readFile(containedPath(root, fixture.source)) });
    }
    corpusHasher.update('\0').update(item.id).update('\0').update(sourceBytes);
    for (const fixture of fixtures) corpusHasher.update('\0').update(fixture.path).update('\0').update(fixture.bytes);
    if (matches(item, options.filter)) prepared.push({ ...item, sourceBytes, source: sourceBytes.toString('utf8'), fixtures });
  }

  const records = [];
  for (let index = 0; index < prepared.length; index += 1) {
    const item = prepared[index];
    const scale = item.scales?.[options.profile] ?? profile.scale;
    const argv = [String(scale), ...(item.argv ?? [])];
    const caseRoot = join(runWorkspace, item.id.replaceAll('/', '__'));
    await mkdir(caseRoot, { recursive: true });
    progress(`[${index + 1}/${prepared.length}] ${item.id} (scale ${scale})`);
    const warmPython = new JsonProcess(python, ['-I', '-B', '-X', 'utf8', '-u', join(root, 'warm_python.py')], caseRoot, pythonEnv);
    const warmWasm = new JsonProcess(process.execPath, [join(root, 'warm_wasm.mjs'), wasmPath], caseRoot, process.env);
    const runs = { cliPython: [], cliPeony: [], warmPython: [], warmWasm: [] };
    let expectedCli = null;
    let expectedWarm = null;
    try {
      await warmPython.start(timeoutMs);
      await warmWasm.start(timeoutMs);
      await warmPython.request({ op: 'setup', source: item.source, filename: item.file }, timeoutMs);
      await warmWasm.request({ op: 'setup', source: item.source, filename: item.file,
        fixtures: item.fixtures.map(fixture => ({ path: fixture.path, base64: fixture.bytes.toString('base64') })) }, timeoutMs);

      for (let repetition = 0; repetition < warmups + samples; repetition += 1) {
        const repetitionRoot = join(caseRoot, String(repetition));
        const directories = {
          cliPython: join(repetitionRoot, 'cli-python'),
          cliPeony: join(repetitionRoot, 'cli-peony'),
          warmPython: join(repetitionRoot, 'warm-python'),
        };
        for (const directory of Object.values(directories)) await prepareCaseDirectory(directory, item);
        const results = {};
        const runners = [
          async () => { results.cliPython = await runCli(probePath, python, directories.cliPython, argv, timeoutMs, pythonEnv); },
          async () => { results.cliPeony = await runCli(probePath, nativePath, directories.cliPeony, argv, timeoutMs, process.env); },
          async () => { results.warmPython = await warmPython.request({ op: 'run', cwd: directories.warmPython, argv }, timeoutMs); },
          async () => { results.warmWasm = await warmWasm.request({ op: 'run', argv }, timeoutMs); },
        ];
        for (let offset = 0; offset < runners.length; offset += 1) await runners[(repetition + offset) % runners.length]();
        for (const [engine, result] of Object.entries(results)) assertCompleted(item.id, engine, result);
        assert.equal(normalizeCli(results.cliPeony.stdout), normalizeCli(results.cliPython.stdout), mismatchMessage(item.id, 'CLI stdout', results.cliPython.stdout, results.cliPeony.stdout));
        assert.equal(normalizeCli(results.cliPeony.stderr), normalizeCli(results.cliPython.stderr), mismatchMessage(item.id, 'CLI stderr', results.cliPython.stderr, results.cliPeony.stderr));
        assert.equal(results.warmWasm.stdout, results.warmPython.stdout, mismatchMessage(item.id, 'warm stdout', results.warmPython.stdout, results.warmWasm.stdout));
        assert.equal(results.warmWasm.stderr, results.warmPython.stderr, mismatchMessage(item.id, 'warm stderr', results.warmPython.stderr, results.warmWasm.stderr));
        const cliOutput = `${normalizeCli(results.cliPython.stdout)}\0${normalizeCli(results.cliPython.stderr)}`;
        const warmOutput = `${results.warmPython.stdout}\0${results.warmPython.stderr}`;
        if (expectedCli === null) expectedCli = cliOutput;
        else assert.equal(cliOutput, expectedCli, `${item.id}: CLI output changed between repetitions`);
        if (expectedWarm === null) expectedWarm = warmOutput;
        else assert.equal(warmOutput, expectedWarm, `${item.id}: warm output changed between repetitions`);
        if (repetition >= warmups) for (const key of Object.keys(runs)) runs[key].push(results[key]);
      }
    } finally {
      await Promise.allSettled([warmPython.close(), warmWasm.close()]);
    }

    const inputHash = createHash('sha256').update(item.sourceBytes);
    for (const fixture of item.fixtures) inputHash.update('\0').update(fixture.path).update('\0').update(fixture.bytes);
    inputHash.update('\0').update(JSON.stringify(argv));
    const cliPython = measurement(runs.cliPython);
    const cliPeony = measurement(runs.cliPeony);
    const replPython = measurement(runs.warmPython);
    const replWasm = measurement(runs.warmWasm);
    records.push({
      id: item.id, tags: item.tags, scale, argv,
      inputSha256: inputHash.digest('hex'),
      cli: { outputSha256: sha(expectedCli), python: cliPython, peony: cliPeony,
        latencyRatio: cliPeony.medianMs / cliPython.medianMs,
        rssRatio: cliPeony.peakRssBytes / cliPython.peakRssBytes },
      warm: { outputSha256: sha(expectedWarm), python: replPython, wasm: replWasm,
        latencyRatio: replWasm.medianMs / replPython.medianMs,
        rssRatio: replWasm.peakRssBytes / replPython.peakRssBytes },
    });
  }

  const report = {
    schema: 3,
    corpus: { version: manifest.version, sha256: corpusHasher.digest('hex'), profile: options.profile,
      cases: records.length, warmups, samples },
    environment: { node: process.version, platform: `${process.platform}-${process.arch}`,
      cpython: pythonVersion, cpythonExecutable: python,
      wasmPath: relative(repositoryRoot, wasmPath).replaceAll(sep, '/'), wasmSha256: sha(wasm), wasmBytes: wasm.length,
      nativePath: relative(repositoryRoot, nativePath).replaceAll(sep, '/'), nativeSha256: sha(native), nativeBytes: native.length,
      nativeVersion, probeSha256: sha(await readFile(join(root, 'process_probe.c'))) },
    summary: {
      compared: records.length, passed: records.length,
      cli: summary(records.map(record => record.cli)),
      warm: summary(records.map(record => record.warm)),
    },
    cases: records,
  };
  if (options.jsonPath) await writeFile(resolve(options.jsonPath), `${JSON.stringify(report, null, 2)}\n`);
  const reportPath = options.reportPath ? resolve(options.reportPath) : options.filter ? null : join(root, 'report.md');
  if (reportPath) await writeFile(reportPath, renderMarkdown(report));
  process.stdout.write(`${records.length}/${records.length} cases matched in both comparisons` +
    (reportPath ? `; report: ${relative(repositoryRoot, reportPath).replaceAll(sep, '/')}` : '') + '\n');
  if (options.filter) for (const record of records) process.stdout.write(
    `${record.id}: CLI Python ${formatMs(record.cli.python.medianMs)} / Peony ${formatMs(record.cli.peony.medianMs)} ms; ` +
    `warm Python ${formatMs(record.warm.python.medianMs)} / WASM ${formatMs(record.warm.wasm.medianMs)} ms\n`);
} finally {
  await rm(runWorkspace, { recursive: true, force: true });
  try { await rmdir(workspaceRoot); }
  catch (error) { if (error?.code !== 'ENOENT' && error?.code !== 'ENOTEMPTY') throw error; }
}
}

async function ensureProbe() {
  const source = join(root, 'process_probe.c');
  const binary = join(repositoryRoot, 'zig-out', process.platform === 'win32' ? 'compare-probe.exe' : 'compare-probe');
  let stale = true;
  try { stale = (await stat(binary)).mtimeMs < (await stat(source)).mtimeMs; }
  catch (error) { if (error?.code !== 'ENOENT') throw error; }
  if (stale) {
    progress('Building the process RSS probe');
    await execFileAsync('zig', ['cc', '-O2', source, '-o', binary,
      ...(process.platform === 'win32' ? ['-lpsapi', '-lshell32'] : [])],
    { cwd: repositoryRoot, windowsHide: true, maxBuffer: 2 * 1024 * 1024 });
  }
  return binary;
}

async function prepareCaseDirectory(directory, item) {
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, '__corpus_case__.py'), item.sourceBytes);
  for (const fixture of item.fixtures) {
    const path = join(directory, ...fixture.path.split('/'));
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, fixture.bytes);
  }
}

async function runCli(probe, executable, directory, argv, timeoutMs, env) {
  const metricsPath = join(directory, '__process_metrics__.json');
  const scriptPath = join(directory, '__corpus_case__.py');
  const { stdout, stderr } = await execFileAsync(probe, [metricsPath, String(timeoutMs), executable, scriptPath, ...argv],
    { cwd: directory, env, encoding: 'utf8', maxBuffer: 2 * 1024 * 1024,
      timeout: timeoutMs + 10_000, windowsHide: true });
  const metrics = JSON.parse(await readFile(metricsPath, 'utf8'));
  return { status: metrics.exit_code === 0 && !metrics.timed_out ? 'completed' : 'error',
    error: metrics.timed_out ? 'timed out' : `exit ${metrics.exit_code}`,
    stdout, stderr, elapsed_ns: metrics.elapsed_ns, peak_rss_bytes: metrics.peak_rss_bytes };
}

class JsonProcess {
  constructor(executable, args, cwd, env) {
    this.executable = executable;
    this.args = args;
    this.cwd = cwd;
    this.env = env;
    this.queue = [];
    this.pending = [];
    this.buffer = '';
    this.stderr = '';
    this.closed = false;
    this.child = null;
  }

  async start(timeoutMs) {
    this.child = spawn(this.executable, this.args,
      { cwd: this.cwd, env: this.env, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdout.setEncoding('utf8').on('data', chunk => {
      this.buffer += chunk;
      for (;;) {
        const end = this.buffer.indexOf('\n');
        if (end < 0) break;
        const line = this.buffer.slice(0, end);
        this.buffer = this.buffer.slice(end + 1);
        let value;
        try { value = JSON.parse(line); }
        catch { value = { ok: false, error: `invalid driver response: ${line.slice(0, 200)}` }; }
        const pending = this.pending.shift();
        if (pending) pending.resolve(value);
        else this.queue.push(value);
      }
    });
    this.child.stderr.setEncoding('utf8').on('data', chunk => { this.stderr += chunk; });
    this.exit = new Promise(resolve => {
      this.child.once('error', error => this.fail(error));
      this.child.once('close', code => {
        this.closed = true;
        this.fail(new Error(`${this.executable} driver exited (${code}): ${this.stderr.slice(0, 1000)}`));
        resolve(code);
      });
    });
    const ready = await this.next(timeoutMs);
    if (ready.ready !== true) throw new Error(`${this.executable} driver did not become ready: ${JSON.stringify(ready)}`);
  }

  fail(error) {
    for (const pending of this.pending.splice(0)) pending.reject(error);
  }

  next(timeoutMs) {
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    if (this.closed) return Promise.reject(new Error(`${this.executable} driver is closed: ${this.stderr.slice(0, 1000)}`));
    return new Promise((resolveValue, rejectValue) => {
      let pending;
      const timer = setTimeout(() => {
        this.pending = this.pending.filter(item => item !== pending);
        this.child.kill();
        rejectValue(new Error(`${this.executable} driver exceeded ${timeoutMs} ms`));
      }, timeoutMs);
      pending = {
        resolve: value => { clearTimeout(timer); resolveValue(value); },
        reject: error => { clearTimeout(timer); rejectValue(error); },
      };
      this.pending.push(pending);
    });
  }

  async request(value, timeoutMs) {
    if (!this.child || this.closed) throw new Error(`${this.executable} driver is unavailable`);
    const reply = this.next(timeoutMs);
    this.child.stdin.write(`${JSON.stringify(value)}\n`);
    const response = await reply;
    if (response.ok !== true) throw new Error(`${this.executable} driver: ${response.error ?? 'unknown error'}`);
    return response;
  }

  async close() {
    if (!this.child || this.closed) return;
    this.child.stdin.end();
    const timer = setTimeout(() => this.child.kill(), 5000);
    try { await this.exit; }
    finally { clearTimeout(timer); }
  }
}

function measurement(runs) {
  const result = timing(runs.map(run => run.elapsed_ns / 1e6));
  result.peakRssBytes = Math.max(...runs.map(run => run.peak_rss_bytes));
  if (runs[0].baseline_rss_bytes !== undefined) {
    result.baselineRssBytes = percentile(runs.map(run => run.baseline_rss_bytes), 0.5);
    result.peakGrowthBytes = Math.max(...runs.map(run => Math.max(0, run.peak_rss_bytes - run.baseline_rss_bytes)));
  }
  if (runs[0].instructions !== undefined) {
    result.medianInstructions = percentile(runs.map(run => run.instructions), 0.5);
    result.medianWork = percentile(runs.map(run => run.work), 0.5);
    result.peakSessionBytes = Math.max(...runs.map(run => run.peak_session_bytes));
  }
  return result;
}

function summary(pairs) {
  return { totalMedianMs: { python: sum(pairs.map(pair => pair.python.medianMs)),
    peony: sum(pairs.map(pair => (pair.peony ?? pair.wasm).medianMs)) },
    geometricMeanLatencyRatio: geometricMean(pairs.map(pair => pair.latencyRatio)),
    geometricMeanRssRatio: geometricMean(pairs.map(pair => pair.rssRatio)) };
}

function renderMarkdown(report) {
  const lines = [
    '# Peony comparison report', '',
    `**${report.summary.passed}/${report.summary.compared} cases passed each two-way comparison.** Each repetition matched stdout and stderr, with Windows CLI newlines normalized for comparison.`,
    '', '## Inputs', '', '| Input | Value |', '|---|---|',
    `| Corpus | v${report.corpus.version}; \`${report.corpus.sha256}\` |`,
    `| Profile | ${report.corpus.profile}; ${report.corpus.warmups} warmups; ${report.corpus.samples} measured samples |`,
    `| CPython | ${report.environment.cpython} via \`${report.environment.cpythonExecutable}\` |`,
    `| Peony native | \`${report.environment.nativePath}\`; ${formatInteger(report.environment.nativeBytes)} bytes; \`${report.environment.nativeSha256}\` |`,
    `| Peony WASM | \`${report.environment.wasmPath}\`; ${formatInteger(report.environment.wasmBytes)} bytes; \`${report.environment.wasmSha256}\` |`,
    `| Host | ${report.environment.platform}; ${report.environment.node} |`,
    '',
    '## One-shot command-line processes', '',
    'A fresh `python __corpus_case__.py ARG...` or `peony __corpus_case__.py ARG...` process runs for every repetition. The timer spans process creation through exit, including startup, source loading, compilation, execution, and output. Peak RSS belongs to that child process.',
    '', '| Measure | CPython | Peony native |', '|---|---:|---:|',
    `| Sum of case median wall times | ${formatMs(report.summary.cli.totalMedianMs.python)} ms | ${formatMs(report.summary.cli.totalMedianMs.peony)} ms |`,
    `| Geometric mean Peony/CPython wall ratio | 1.00x | ${report.summary.cli.geometricMeanLatencyRatio.toFixed(2)}x |`,
    `| Geometric mean Peony/CPython peak RSS ratio | 1.00x | ${report.summary.cli.geometricMeanRssRatio.toFixed(2)}x |`,
    '',
    '## Started interpreters', '',
    'A persistent CPython process and a loaded Peony Worker process start before timing each case. Each job receives the same source, arguments, and fixture bytes in fresh program state. CPython times `compile` plus `exec`; Peony times the public `session.run` call, including Worker messaging. Process startup and fixture setup are outside both intervals.',
    '',
    'Peak RSS is the full host process resident set during the job. The Peony process includes Node and its Worker; CPython includes its driver. The growth column is peak RSS above the process baseline immediately before the job. Both drivers sample current RSS and check for new OS high-water marks; brief spikes below an earlier high-water mark can fall between samples.',
    '', '| Measure | CPython | Peony WASM |', '|---|---:|---:|',
    `| Sum of case median job times | ${formatMs(report.summary.warm.totalMedianMs.python)} ms | ${formatMs(report.summary.warm.totalMedianMs.peony)} ms |`,
    `| Geometric mean Peony/CPython wall ratio | 1.00x | ${report.summary.warm.geometricMeanLatencyRatio.toFixed(2)}x |`,
    `| Geometric mean Peony/CPython peak RSS ratio | 1.00x | ${report.summary.warm.geometricMeanRssRatio.toFixed(2)}x |`,
    '', '## Case measurements', '',
    'Wall time is median/p95 milliseconds. RSS is the maximum measured peak across samples. Ratios use median wall time. All memory values are MiB.',
    '',
  ];
  const groups = [['Core language and objects', 'core/'], ['Native libraries', 'libraries/'], ['Integrated workloads', 'workloads/']];
  for (const [heading, prefix] of groups) {
    lines.push(`### ${heading}: one-shot CLI`, '',
      '| Case | CP ms | Peony ms | P/CP | CP RSS | Peony RSS |',
      '|---|---:|---:|---:|---:|---:|');
    for (const record of report.cases.filter(item => item.id.startsWith(prefix))) {
      lines.push(`| \`${record.id.slice(prefix.length)}\` | ${formatPair(record.cli.python)} | ${formatPair(record.cli.peony)} | ${record.cli.latencyRatio.toFixed(2)}x | ${formatMiB(record.cli.python.peakRssBytes)} | ${formatMiB(record.cli.peony.peakRssBytes)} |`);
    }
    lines.push('', `### ${heading}: started interpreters`, '',
      '| Case | CP ms | WASM ms | W/CP | CP RSS | WASM RSS | RSS growth CP/W |',
      '|---|---:|---:|---:|---:|---:|---:|');
    for (const record of report.cases.filter(item => item.id.startsWith(prefix))) {
      lines.push(`| \`${record.id.slice(prefix.length)}\` | ${formatPair(record.warm.python)} | ${formatPair(record.warm.wasm)} | ${record.warm.latencyRatio.toFixed(2)}x | ${formatMiB(record.warm.python.peakRssBytes)} | ${formatMiB(record.warm.wasm.peakRssBytes)} | ${formatMiB(record.warm.python.peakGrowthBytes)}/${formatMiB(record.warm.wasm.peakGrowthBytes)} |`);
    }
    lines.push('');
  }
  lines.push('The [comparison guide](README.md) defines fixtures, commands, output checks, and memory measurement.');
  return `${lines.join('\n')}\n`;
}

function formatMs(value) { return value < 10 ? value.toFixed(3) : value < 100 ? value.toFixed(2) : value.toFixed(1); }
function formatPair(value) { return `${formatMs(value.medianMs)}/${formatMs(value.p95Ms)}`; }
function formatMiB(value) { return (value / (1024 * 1024)).toFixed(1); }
function formatInteger(value) { return Math.round(value).toLocaleString('en-US'); }
function percentile(values, fraction) { const sorted = values.slice().sort((a, b) => a - b); return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)]; }
function timing(values) { return { medianMs: percentile(values, 0.5), p95Ms: percentile(values, 0.95), minMs: Math.min(...values), maxMs: Math.max(...values) }; }
function geometricMean(values) { return Math.exp(sum(values.map(value => Math.log(value))) / values.length); }
function sum(values) { return values.reduce((total, value) => total + value, 0); }
function sha(value) { return createHash('sha256').update(value).digest('hex'); }
function normalizeCli(value) { return process.platform === 'win32' ? value.replaceAll('\r\n', '\n') : value; }
function progress(value) { if (!options.quiet) process.stderr.write(`${value}\n`); }
function abbreviate(value) { return value.length <= 500 ? value : `${value.slice(0, 500)}... (${value.length} characters)`; }
function mismatchMessage(id, stream, expected, actual) { return `${id}: ${stream} differs\nCPython: ${JSON.stringify(abbreviate(expected))}\nPeony: ${JSON.stringify(abbreviate(actual))}`; }
function assertCompleted(id, engine, result) { assert.equal(result.status, 'completed', `${id}: ${engine} ${result.status}: ${result.error}`); }

async function identifyPython(executable) {
  const { stdout, stderr } = await execFileAsync(executable, ['--version'], { encoding: 'utf8', windowsHide: true });
  const version = `${stdout}${stderr}`.trim();
  if (!/^Python 3\.12\.\d+$/.test(version)) throw new Error(`comparison requires CPython 3.12, found ${version}`);
  return version;
}
async function identifyNative(executable) {
  const { stdout, stderr } = await execFileAsync(executable, ['--version'], { encoding: 'utf8', windowsHide: true });
  if (stderr !== '' || stdout.trim() !== 'Peony 0.1.0') throw new Error('unexpected native Peony identity');
  return stdout.trim();
}
function containedPath(base, path) {
  validateRelativePath(path, 'corpus path');
  const selected = resolve(base, path);
  if (selected !== base && !selected.startsWith(`${base}${sep}`)) throw new Error(`path escapes compare directory: ${path}`);
  return selected;
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
  for (const [name, profile] of Object.entries(value.profiles)) {
    assert.ok(Number.isInteger(profile.scale) && profile.scale > 0, `${name}: invalid scale`);
    assert.ok(Number.isInteger(profile.warmups) && profile.warmups >= 0, `${name}: invalid warmups`);
    assert.ok(Number.isInteger(profile.samples) && profile.samples > 0, `${name}: invalid samples`);
    assert.ok(Number.isInteger(profile.timeoutMs) && profile.timeoutMs > 0, `${name}: invalid timeout`);
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
  const result = { profile: 'standard', filter: '', quiet: false, list: false };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === '--profile') result.profile = requiredValue(arguments_, ++index, argument);
    else if (argument === '--filter') result.filter = requiredValue(arguments_, ++index, argument);
    else if (argument === '--warmups') result.warmups = positiveInteger(requiredValue(arguments_, ++index, argument), true);
    else if (argument === '--samples') result.samples = positiveInteger(requiredValue(arguments_, ++index, argument), false);
    else if (argument === '--timeout-ms') result.timeoutMs = positiveInteger(requiredValue(arguments_, ++index, argument), false);
    else if (argument === '--python') result.python = requiredValue(arguments_, ++index, argument);
    else if (argument === '--wasm') result.wasm = requiredValue(arguments_, ++index, argument);
    else if (argument === '--native') result.native = requiredValue(arguments_, ++index, argument);
    else if (argument === '--json') result.jsonPath = requiredValue(arguments_, ++index, argument);
    else if (argument === '--report') result.reportPath = requiredValue(arguments_, ++index, argument);
    else if (argument === '--quiet') result.quiet = true;
    else if (argument === '--list') result.list = true;
    else if (argument === '--help') { usage(); process.exit(0); }
    else throw new Error(`unknown argument ${argument}`);
  }
  return result;
}
function requiredValue(arguments_, index, flag) { if (index >= arguments_.length) throw new Error(`${flag} requires a value`); return arguments_[index]; }
function positiveInteger(value, allowZero) { const number = Number(value); if (!Number.isInteger(number) || number < (allowZero ? 0 : 1)) throw new Error(`invalid count ${value}`); return number; }
function usage() {
  process.stdout.write('Usage: node compare/run.mjs [options]\n\n' +
    '  --profile smoke|standard|stress\n  --filter TEXT\n  --warmups N\n  --samples N\n' +
    '  --timeout-ms N\n  --python PATH\n  --wasm PATH\n  --native PATH\n' +
    '  --json PATH\n  --report PATH\n  --list\n  --quiet\n');
}

await main();
