import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Peony } from '../web/peony.mjs';

const wasmPath = new URL('../zig-out/peony.wasm', import.meta.url);
const load = async () => Peony.load(new Uint8Array(await readFile(wasmPath)));

async function run(source, options = {}) {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ quantum: 1, stdout: (text) => output.push(text), ...options });
  const result = await session.run(source, { filename: 'wasm-library-numeric.py' });
  return { result, output: output.join(''), session };
}

test('shipping WASM implements math bigint, float, domain, and binder behavior', async () => {
  const { result, output } = await run([
    'import math',
    'print(math.sqrt(81), math.log(8, 2), math.floor(-1.2), math.ceil(-1.2), math.trunc(-1.8))',
    'print(math.factorial(30))',
    'print(math.gcd(), math.gcd(84, -30, 18), math.lcm(), math.lcm(6, -15))',
    'print(math.factorial(True), math.gcd(True, 3), math.lcm(False, 5))',
    'print(math.log2(2 ** 1000), 2302 < math.log(10 ** 1000) < 2303)',
    'print(math.isfinite(1.0), math.isinf(math.inf), math.isnan(math.nan))',
    'print(math.sin(0), math.cos(0), math.tan(0), math.asin(0), math.acos(1), math.atan(0), math.atan2(0, -1) == math.pi)',
    'print(math.pow(2, 5), math.log10(1000), math.fabs(-2.5), math.degrees(math.pi), math.radians(180) == math.pi)',
    'for call, expected, label in [(lambda: math.sqrt(-1), ValueError, "ValueError"), (lambda: math.factorial(2.5), TypeError, "TypeError"), (lambda: math.exp(1000), OverflowError, "OverflowError"), (lambda: math.sqrt(x=4), TypeError, "TypeError")]:',
    '    try:',
    '        call()',
    '    except expected:',
    '        print(label)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, [
    '9.0 3.0 -2 -1 -1',
    '265252859812191058636308480000000',
    '0 6 1 30',
    '1 1 0',
    '1000.0 True',
    'True True True',
    '0.0 1.0 0.0 0.0 0.0 0.0 True',
    '32.0 3.0 2.5 180.0 True',
    'ValueError',
    'TypeError',
    'OverflowError',
    'TypeError',
    '',
  ].join('\n'));
});

test('shipping WASM owns deterministic random state and validates before mutation', async () => {
  const { result, output } = await run([
    'import random',
    'def snapshot(seed):',
    '    random.seed(seed)',
    '    values = [random.random(), random.randrange(10 ** 30), random.randint(-10, 10)]',
    '    shuffled = list(range(8))',
    '    random.shuffle(shuffled)',
    '    return values, shuffled, random.sample(range(1000), 20)',
    'for seed in [True, 2 ** 90, 2.5, "seed 雪", b"bytes"]:',
    '    print(snapshot(seed) == snapshot(seed))',
    'random.seed(77)',
    'expected = random.random()',
    'random.seed(77)',
    'try:',
    '    random.choices([1, 2], weights=[0, 0])',
    'except ValueError:',
    '    pass',
    'print(random.random() == expected)',
    'print(random.choice([9]))',
    'print(random.choices(["a", "b"], weights=[0, 1], k=3))',
    'picked = random.sample(["x", "y"], 3, counts=[2, 2])',
    'print(len(picked), picked.count("x") <= 2, picked.count("y") <= 2)',
    'sparse_counts = random.sample(["a", "b", "c", "d"], 5, counts=[0, 2, 0, 3])',
    'print(len(sparse_counts), sparse_counts.count("a"), sparse_counts.count("b"), sparse_counts.count("c"), sparse_counts.count("d"))',
    'print(random.sample([], 0, counts=[]))',
    'print(random.choices(["a", "b"], cum_weights=[0, 4], k=2))',
    'print(-5 <= random.uniform(-5, 7) <= 7)',
    'for call, expected, label in [(lambda: random.randrange(1, 2, 0), ValueError, "step"), (lambda: random.sample([1], 2), ValueError, "sample"), (lambda: random.seed([], version=2), TypeError, "seed"), (lambda: random.seed(1, version=1), NotImplementedError, "version")]:',
    '    try:',
    '        call()',
    '    except expected:',
    '        print(label)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, "True\nTrue\nTrue\nTrue\nTrue\nTrue\n9\n['b', 'b', 'b']\n3 True True\n5 0 2 0 3\n[]\n['b', 'b']\nTrue\nstep\nsample\nseed\nversion\n");
});

test('shipping WASM random work is bounded, cancellable, and keeps zero-draw semantics', async () => {
  const peony = await load();
  for (const expression of [
    'random.sample(range(4000), 1000)',
    'random.choices(range(10), k=4000)',
    'random.randrange(1 << 8192)',
  ]) {
    const output = [];
    const session = peony.createSession({ quantum: 50_000, maxInstructions: 1000, maxMemoryBytes: 8 * 1024 * 1024, stdout: (text) => output.push(text) });
    const result = await session.run(`import random\n${expression}\nprint('late')\n`);
    assert.equal(result.status, 'limit', expression);
    assert.ok(result.counters.work <= 1000, expression);
    assert.equal(output.join(''), '');
  }

  const { result, output } = await run([
    'import random',
    'print(random.choices([], k=0))',
    'try:',
    '    random.choices([], k=1)',
    'except IndexError:',
    '    print("empty positive")',
    'random.seed(31)',
    'picked = random.sample(range(4000), 1000)',
    'seen = {}',
    'for value in picked:',
    '    seen[value] = 1',
    'print(len(picked), len(seen))',
  ].join('\n'), { quantum: 50_000 });
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, '[]\nempty positive\n1000 1000\n');

  let markerResolve;
  const marker = new Promise((resolve) => { markerResolve = resolve; });
  const cancelledOutput = [];
  const cancellable = peony.createSession({
    quantum: 1,
    maxMemoryBytes: 8 * 1024 * 1024,
    stdout: (text) => {
      cancelledOutput.push(text);
      if (cancelledOutput.join('').includes('sample ready\n')) markerResolve();
    },
  });
  const running = cancellable.run('import random\nprint("sample ready")\nrandom.sample(range(40000), 10000)\nprint("late sample")\n');
  let timeout;
  try {
    await Promise.race([marker, new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('random marker timeout')), 5000); })]);
  } finally {
    clearTimeout(timeout);
  }
  cancellable.cancel();
  const cancelled = await running;
  assert.equal(cancelled.status, 'cancelled');
  assert.equal(cancelledOutput.join(''), 'sample ready\n');
  const recovered = await cancellable.run('import random\nprint(random.choices([], k=0))\n');
  assert.equal(recovered.status, 'completed', recovered.error?.message);
  assert.equal(cancelledOutput.join(''), 'sample ready\n[]\n');
});

test('shipping WASM statistics consumes iterables once and preserves numeric behavior', async () => {
  const { result, output } = await run([
    'import statistics',
    'def once():',
    '    for value in [1, 3, 8]:',
    '        print("yield", value)',
    '        yield value',
    'print(statistics.mean(once()))',
    'print(statistics.mean([10 ** 30, 10 ** 30]))',
    'print(statistics.fmean([1e16, 1.0, -1e16]))',
    'print(statistics.fmean([1, 2, 10], weights=[2, 1, 1]))',
    'print(statistics.median([5, 1, 9, 3]), statistics.mode(["b", "a", "b", "a"]))',
    'for call in [lambda: statistics.mean([]), lambda: statistics.median([]), lambda: statistics.mode([])]:',
    '    try:',
    '        call()',
    '    except statistics.StatisticsError:',
    '        print("StatisticsError")',
    'for call, expected, label in [(lambda: statistics.fmean([], weights=[]), statistics.StatisticsError, "empty-weighted"), (lambda: statistics.fmean([1, 2], weights=[1]), ValueError, "length"), (lambda: statistics.mean([1, "bad"]), TypeError, "type")]:',
    '    try:',
    '        call()',
    '    except expected:',
    '        print(label)',
    'print(issubclass(statistics.StatisticsError, ValueError), statistics.median([3, 1, 2]))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'yield 1\nyield 3\nyield 8\n4\n1000000000000000000000000000000\n0.3333333333333333\n3.5\n4.0 b\nStatisticsError\nStatisticsError\nStatisticsError\nempty-weighted\nlength\ntype\nTrue 2\n');
});

test('shipping WASM numeric modules recover across reset under frequent GC', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ quantum: 1, maxMemoryBytes: 2 * 1024 * 1024, stdout: (text) => output.push(text) });
  let result = await session.run('import math, random, statistics\nrandom.seed(3)\nprint(math.factorial(100) > 10 ** 150, len(random.sample(range(10000), 100)), statistics.median(range(101)))\n');
  assert.equal(result.status, 'completed', result.error?.message);
  result = await session.run('import random\nrandom.seed(3)\na = random.random()\nrandom.seed(3)\nprint(a == random.random())\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'True 100 50\nTrue\n');
});
