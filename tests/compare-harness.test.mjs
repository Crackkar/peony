import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));

test('comparison harness separates timing, host memory, and runtime memory', { timeout: 120_000 }, async () => {
  const scratch = path.join(repositoryRoot, '.zig-cache', 'compare-harness-test');
  const jsonPath = path.join(scratch, 'report.json');
  const markdownPath = path.join(scratch, 'report.md');
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  try {
    await execFileAsync(process.execPath, [
      path.join(repositoryRoot, 'compare', 'run.mjs'),
      '--profile', 'smoke', '--filter', 'bytes-codecs',
      '--warmups', '0', '--samples', '1',
      '--json', jsonPath, '--report', markdownPath, '--quiet',
    ], { cwd: repositoryRoot, windowsHide: true, timeout: 115_000 });

    const report = JSON.parse(await readFile(jsonPath, 'utf8'));
    assert.equal(report.schema, 4);
    assert.equal(report.summary.compared, 1);
    assert.ok(report.summary.cli.startup.python.peakPrivateBytes > 0);
    assert.ok(report.summary.cli.startup.peony.peakPrivateBytes > 0);
    assert.ok(report.cases[0].cli.python.peakPrivateBytes > 0);
    assert.ok(report.cases[0].cli.peony.peakPrivateBytes > 0);
    assert.ok(report.cases[0].warm.python.runtimeJobBytes > 0);
    assert.ok(report.cases[0].warm.wasm.runtimeJobBytes > 0);
    assert.ok(report.cases[0].warm.wasm.wasmLinearBytes > 0);
    assert.ok(report.cases[0].warm.wasm.vfsBytes >= 0);
    assert.equal(Object.hasOwn(report.cases[0].warm, 'rssRatio'), false);

    const markdown = await readFile(markdownPath, 'utf8');
    assert.match(markdown, /Timing, host RSS, and runtime allocation are separate executions/);
    assert.match(markdown, /Empty-script wall median\/p95/);
    assert.match(markdown, /WASM linear\/VFS/);
    assert.doesNotMatch(markdown.slice(markdown.indexOf('## Started interpreters')), /peak RSS ratio/);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});
