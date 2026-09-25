import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import test from 'node:test';

test('the required Zig compiler is exactly 0.16.0', () => {
  assert.equal(execFileSync('zig', ['version'], { encoding: 'utf8', windowsHide: true }).trim(), '0.16.0');
});

test('size report is repeatable and includes the baseline plus all feature deltas', () => {
  const run = () => JSON.parse(execFileSync('node', ['tools/size_report.mjs', '--json'], {
    encoding: 'utf8',
    windowsHide: true,
    maxBuffer: 1024 * 1024,
  }));
  const first = run();
  const second = run();

  assert.deepEqual(second, first);
  assert.equal(first.baseline.artifact, 'zig-out/peony.wasm');
  assert.ok(first.baseline.rawBytes > 0);
  assert.ok(first.baseline.brotliQ11Bytes > 0);
  assert.deepEqual(Object.keys(first.probes).sort(), ['bigint', 'json', 'unicode15']);
  for (const [name, result] of Object.entries(first.probes)) {
    assert.equal(result.artifact, `zig-out/peony-probe-${name}.wasm`);
    assert.ok(result.rawDeltaBytes > 0);
    assert.ok(Number.isFinite(result.brotliQ11DeltaBytes));
    assert.ok(Number.isInteger(result.brotliQ11DeltaBytes));
  }
});
