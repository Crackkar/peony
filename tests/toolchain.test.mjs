import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import test from 'node:test';

test('the required Zig compiler is exactly 0.16.0', () => {
  assert.equal(execFileSync('zig', ['version'], { encoding: 'utf8', windowsHide: true }).trim(), '0.16.0');
});
