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
  const result = await session.run(source, { filename: 'wasm-library-collections.py' });
  return { result, output: output.join(''), session };
}

test('shipping WASM Counter is a real dict subtype with ordered multiset operations', async () => {
  const { result, output } = await run([
    'from collections import Counter',
    'counter = Counter("ababa")',
    'print(type(counter) is Counter, isinstance(counter, dict), dict(counter))',
    'print(counter["missing"], "missing" in counter)',
    'counter.update("bcc")',
    'counter.subtract({"a": 1, "b": 5, "d": 2})',
    'print(dict(counter))',
    'print(list(counter.elements()), counter.most_common(), counter.most_common(2), counter.total())',
    'print(dict(+counter), dict(-counter))',
    'left = Counter({"a": 3, "b": 1})',
    'right = Counter({"a": 1, "b": 2, "c": 4})',
    'print(dict(left + right), dict(left - right), dict(left & right), dict(left | right))',
    'print(Counter(a=1) == Counter(a=1, b=0), Counter(a=1) <= Counter(a=1, b=0))',
    'print(Counter(a=1) < Counter(a=2), Counter(a=2) >= Counter(a=1), Counter(a=1) != Counter(a=2))',
    'from_counter = Counter(Counter({"x": 2}))',
    'from_counter.update(Counter({"x": 3, "y": 1}))',
    'from_counter.subtract(Counter({"x": 1}))',
    'print(dict(from_counter), list(from_counter.values()), list(from_counter.items()))',
    'counter_copy = from_counter.copy()',
    'counter_copy["x"] = 99',
    'print(type(counter_copy) is Counter, from_counter["x"], counter_copy["x"])',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, [
    "True True {'a': 3, 'b': 2}",
    '0 False',
    "{'a': 2, 'b': -2, 'c': 2, 'd': -2}",
    "['a', 'a', 'c', 'c'] [('a', 2), ('c', 2), ('b', -2), ('d', -2)] [('a', 2), ('c', 2)] 0",
    "{'a': 2, 'c': 2} {'b': 2, 'd': 2}",
    "{'a': 4, 'b': 3, 'c': 4} {'a': 2} {'a': 1, 'b': 1} {'a': 3, 'b': 2, 'c': 4}",
    'True True',
    'True True True',
    "{'x': 4, 'y': 1} [4, 1] [('x', 4), ('y', 1)]",
    'True 4 99',
    '',
  ].join('\n'));
});

test('shipping WASM defaultdict calls a suspending factory once and inserts after success', async () => {
  const prompts = [];
  const { result, output } = await run([
    'from collections import defaultdict',
    'try:',
    '    defaultdict(1)',
    'except TypeError:',
    '    print("invalid factory")',
    'def failing_factory(): raise ValueError("factory failed")',
    'failed = defaultdict(failing_factory)',
    'try:',
    '    failed["x"]',
    'except ValueError:',
    '    print("factory error", "x" in failed)',
    'seeded = defaultdict(None, {"ready": 1}, extra=2)',
    'print(type(seeded) is defaultdict, dict(seeded))',
    'calls = 0',
    'def factory():',
    '    global calls',
    '    calls += 1',
    '    return input("Factory: ")',
    'values = defaultdict(factory)',
    'print(values.get("x"), "x" in values, calls)',
    'print(values["x"], values["x"], calls)',
    'values.default_factory = lambda: 9',
    'print(values["next"])',
    'values.default_factory = None',
    'try:',
    '    values["missing"]',
    'except KeyError:',
    '    print("missing", "missing" in values)',
    'values.update({"more": [2]})',
    'clone = values.copy()',
    'print(type(clone) is defaultdict, clone.default_factory is values.default_factory, list(clone.values()), list(clone.items()))',
    'print(clone.setdefault("set", 5), clone.pop("set"), "set" in clone)',
    'clone.clear()',
    'print(len(clone))',
  ].join('\n'), {
    input: async (prompt) => {
      prompts.push(prompt);
      return 'made';
    },
  });
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, "invalid factory\nfactory error False\nTrue {'ready': 1, 'extra': 2}\nNone False 0\nFactory: made made 1\n9\nmissing False\nTrue True ['made', 9, [2]] [('x', 'made'), ('next', 9), ('more', [2])]\n5 5 False\n0\n");
  assert.deepEqual(prompts, ['Factory: ']);
});

test('shipping WASM copy preserves graph cycles, aliases, and ordinary instances', async () => {
  const { result, output } = await run([
    'import copy',
    'child = [1]',
    'source = [child, child]',
    'shallow = copy.copy(source)',
    'deep = copy.deepcopy(source)',
    'print(shallow is not source, shallow[0] is child, shallow[0] is shallow[1])',
    'print(deep is not source, deep[0] is not child, deep[0] is deep[1])',
    'cycle = []',
    'cycle.append(cycle)',
    'cycle_copy = copy.deepcopy(cycle)',
    'print(cycle_copy is not cycle, cycle_copy[0] is cycle_copy)',
    'cached = ["cached"]',
    'memo_source = []',
    'print(copy.deepcopy(memo_source, {id(memo_source): cached}) is cached)',
    'inner = []',
    'tuple_cycle = (inner,)',
    'inner.append(tuple_cycle)',
    'tuple_copy = copy.deepcopy(tuple_cycle)',
    'print(tuple_copy is not tuple_cycle, tuple_copy[0][0] is tuple_copy)',
    'class Box:',
    '    def __init__(self): self.value = child',
    'box = Box()',
    'box_shallow = copy.copy(box)',
    'box_deep = copy.deepcopy(box)',
    'print(type(box_shallow) is Box, box_shallow.value is child)',
    'print(type(box_deep) is Box, box_deep.value is not child, box_deep.value == child)',
    'immutable = (1, 2)',
    'mapping = {"child": child}',
    'mapping_copy = copy.copy(mapping)',
    'print(copy.copy(1) is 1, copy.copy(immutable) is immutable, mapping_copy is not mapping, mapping_copy["child"] is child)',
    'class Broken:',
    '    def __deepcopy__(self, memo): raise ValueError("broken")',
    'try:',
    '    copy.deepcopy([Broken()])',
    'except ValueError:',
    '    print("hook error")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'True True True\nTrue True True\nTrue True\nTrue\nTrue True\nTrue True\nTrue True True\nTrue True True True\nhook error\n');
});

test('shipping WASM deepcopy batches repeated cyclic graph work at quantum one', async () => {
  const { result, output } = await run([
    'import copy',
    'child = [1]',
    'source = [child, child]',
    'source.append(source)',
    'for _ in range(100):',
    '    cloned = copy.deepcopy(source)',
    'print(cloned[0] is cloned[1], cloned[2] is cloned)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'True True\n');
});

test('shipping WASM deepcopy hook resumes through input once and resets cleanly', async () => {
  const prompts = [];
  const peony = await load();
  const output = [];
  const session = peony.createSession({
    quantum: 1,
    maxMemoryBytes: 3 * 1024 * 1024,
    stdout: (text) => output.push(text),
    input: async (prompt) => {
      prompts.push(prompt);
      return prompt === 'Shallow: ' ? 'shallow' : 'cloned';
    },
  });
  let result = await session.run([
    'import copy',
    'class Hook:',
    '    def __copy__(self):',
    '        return input("Shallow: ")',
    '    def __deepcopy__(self, memo):',
    '        print(isinstance(memo, dict))',
    '        return input("Copy: ")',
    'hook = Hook()',
    'print(copy.copy(hook))',
    'print(copy.deepcopy(hook))',
    'class NestedHook:',
    '    def __deepcopy__(self, memo):',
    '        return input("Nested: ")',
    'print(copy.deepcopy([NestedHook()]))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  result = await session.run('from collections import Counter\nimport copy\nprint(Counter("aba").most_common(), copy.deepcopy([1, 2]))\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), "Shallow: shallow\nTrue\nCopy: cloned\nNested: ['cloned']\n[('a', 2), ('b', 1)] [1, 2]\n");
  assert.deepEqual(prompts, ['Shallow: ', 'Copy: ', 'Nested: ']);
});

test('shipping WASM copy rejects resources with native Error ancestry', async () => {
  const { result, output } = await run([
    'import copy',
    'with open("/home/resource.txt", "w") as resource:',
    '    try:',
    '        copy.deepcopy(resource)',
    '    except (copy.Error, TypeError):',
    '        print("resource")',
    'print(issubclass(copy.Error, Exception))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'resource\nTrue\n');
});

test('shipping WASM cancels pending defaultdict and deepcopy callbacks cleanly', async () => {
  const peony = await load();
  const output = [];
  const prompts = [];
  let observePrompt;
  let promptObserved = new Promise((resolve) => { observePrompt = resolve; });
  const observedWithin = async (pending, label) => {
    let timeout;
    try {
      return await Promise.race([
        pending,
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error(`${label} prompt timeout`)), 5000); }),
      ]);
    } finally {
      clearTimeout(timeout);
    }
  };
  const session = peony.createSession({
    quantum: 1,
    stdout: (text) => output.push(text),
    input: (prompt) => {
      prompts.push(prompt);
      observePrompt(prompt);
      return new Promise(() => {});
    },
  });
  let running = session.run([
    'from collections import defaultdict',
    'def factory(): return input("Factory cancel: ")',
    'values = defaultdict(factory)',
    'print(values["x"])',
  ].join('\n'));
  assert.equal(await observedWithin(promptObserved, 'defaultdict'), 'Factory cancel: ');
  session.cancel();
  let result = await running;
  assert.equal(result.status, 'cancelled');

  promptObserved = new Promise((resolve) => { observePrompt = resolve; });
  running = session.run([
    'import copy',
    'class Hook:',
    '    def __deepcopy__(self, memo): return input("Copy cancel: ")',
    'print(copy.deepcopy([Hook()]))',
  ].join('\n'));
  assert.equal(await observedWithin(promptObserved, 'deepcopy'), 'Copy cancel: ');
  session.cancel();
  result = await running;
  assert.equal(result.status, 'cancelled');
  result = await session.run('print("clean")\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.deepEqual(prompts, ['Factory cancel: ', 'Copy cancel: ']);
  assert.equal(output.join(''), 'Factory cancel: Copy cancel: clean\n');
});
