#!/usr/bin/env node
// Separate CPython oracle for stable learner-visible library results. It uses
// -c strings only; no Python implementation file or fixture is shipped.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { Peony } from '../web/peony.mjs';

const python = process.env.PEONY_CPYTHON ?? 'python';
const pythonOptions = { encoding: 'utf8', windowsHide: true, env: { ...process.env, PYTHONIOENCODING: 'utf-8' } };
const version = execFileSync(python, ['--version'], pythonOptions).trim();
if (!/^Python 3\.12\./.test(version)) throw new Error(`expected a CPython 3.12 oracle, found ${version}`);
const wasm = new Uint8Array(await readFile(new URL('../zig-out/peony.wasm', import.meta.url)));
const peony = await Peony.load(wasm);

const cases = [
  ['integer math', [
    'import math',
    'print(math.factorial(30))',
    'print(math.gcd(0, 18, -30), math.lcm(4, 6, 10))',
    'print(math.floor(-2.7), math.ceil(-2.7), math.isfinite(math.inf))',
  ].join('\n')],
  ['statistics', [
    'import statistics',
    'print(statistics.mean([2, 4, 6]), statistics.fmean([2, 4, 6]))',
    'print(statistics.median([8, 3, 4, 5]), statistics.mode(["b", "a", "b", "a"]))',
  ].join('\n')],
  ['json', [
    'import json',
    'value = json.loads("{\\"large\\":123456789012345678901234567890,\\"text\\":\\"\\u96ea\\"}")',
    'print(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")))',
  ].join('\n')],
  ['csv', [
    'import csv',
    'for row in csv.reader(["a,b\\n", "\\"c,d\\",e\\n"]): print(row)',
  ].join('\n')],
  ['regex', [
    'import re',
    'pattern = re.compile(r"(?P<word>[A-Za-z]+)(?P<digit>\\d+)")',
    'match = pattern.search("x abc12 y")',
    'print(match.group("word"), match.groupdict(), match.span())',
    'print(re.findall(r"a+?", "aaaa"))',
  ].join('\n')],
  ['collections', [
    'from collections import Counter, defaultdict',
    'left = Counter("abracadabra")',
    'right = Counter("banana")',
    'print(left.most_common(3), list((left & right).items()))',
    'values = defaultdict(list)',
    'values["x"].append(2)',
    'print(values["x"], list(values.items()))',
  ].join('\n')],
  ['copy graphs', [
    'import copy',
    'child = [1, 2]',
    'graph = [child, child]',
    'graph.append(graph)',
    'result = copy.deepcopy(graph)',
    'print(result[0] is result[1], result[2] is result, result[0] is child)',
  ].join('\n')],
];

const records = [];
for (const [name, source] of cases) {
  const reference = execFileSync(python, ['-c', source], pythonOptions).replaceAll('\r\n', '\n');
  const output = [];
  const session = peony.createSession({ stdout: text => output.push(text) });
  try {
    const result = await session.run(source, { filename: `${name.replaceAll(' ', '-')}.py` });
    assert.equal(result.status, 'completed', `${name}: ${result.error?.message ?? result.status}`);
    assert.equal(output.join(''), reference, `${name}: CPython ${version} differs`);
    records.push({ name, passed: true, bytes: Buffer.byteLength(reference) });
  } finally {
    session.destroy();
  }
}
process.stdout.write(`${JSON.stringify({ oracle: version, releaseTarget: 'CPython 3.12.14', reconciledToReleaseTarget: version === 'Python 3.12.14', cases: records })}\n`);
