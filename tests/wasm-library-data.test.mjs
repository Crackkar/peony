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
  const result = await session.run(source, { filename: 'wasm-library-data.py' });
  return { result, output: output.join(''), session };
}

test('shipping WASM JSON preserves integers, Unicode, options, and decode metadata', async () => {
  const { result, output } = await run([
    'import json, math',
    'value = json.loads(\'{"n":123456789012345678901234567890,"text":"\\\\u96ea \\\\ud834\\\\udd1e","same":1,"same":2}\')',
    'print(value["n"], value["text"], value["same"])',
    'print(json.dumps({"b": [True, None, 1], "a": "雪"}, sort_keys=True, ensure_ascii=True, separators=(",", ":")))',
    'print(json.dumps([math.nan, math.inf, -math.inf]))',
    'print("\\n\\t\\\"a\\\"" in json.dumps({"a": 1}, indent="\\t"))',
    'try:',
    '    json.loads(\'{"a":}\')',
    'except json.JSONDecodeError as error:',
    '    print(isinstance(error, ValueError), error.pos >= 0, error.lineno >= 1, error.colno >= 1, len(error.msg) > 0)',
    'cycle = []',
    'cycle.append(cycle)',
    'try:',
    '    json.dumps(cycle)',
    'except ValueError:',
    '    print("cycle")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, '123456789012345678901234567890 雪 𝄞 2\n{"a":"\\u96ea","b":[true,null,1]}\n[NaN, Infinity, -Infinity]\nTrue\nTrue True True True True\ncycle\n');
});

test('shipping WASM JSON file methods resume learner callbacks without replay', async () => {
  const prompts = [];
  const { result, output } = await run([
    'import json',
    'class Reader:',
    '    def __init__(self): self.calls = 0',
    '    def read(self):',
    '        self.calls += 1',
    '        return input("JSON: ")',
    'class Writer:',
    '    def __init__(self): self.parts = []',
    '    def write(self, text):',
    '        self.parts.append(text)',
    '        return len(text)',
    'reader = Reader()',
    'print(json.load(reader)["answer"], reader.calls)',
    'writer = Writer()',
    'print(json.dump({"answer": 42}, writer, sort_keys=True))',
    'print(type(writer.parts[0]) is str, writer.parts[0] == \'{"answer": 42}\')',
    'print("".join(writer.parts))',
  ].join('\n'), {
    input: async (prompt) => {
      prompts.push(prompt);
      return '{"answer":42}';
    },
  });
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'JSON: 42 1\nNone\nTrue True\n{"answer": 42}\n');
  assert.deepEqual(prompts, ['JSON: ']);
});

test('shipping WASM CSV handles multiline, Unicode, quoting, and dictionaries', async () => {
  const { result, output } = await run([
    'import csv',
    'reader = csv.reader([\'a,"b\\n\', \'c",d\\r\\n\', \'1,2\\r\\n\'])',
    'print(next(reader), reader.line_num)',
    'print(next(reader), reader.line_num)',
    'print(list(csv.reader(["雪§花\\n"], delimiter="§")))',
    'print(list(csv.reader([\'1,2.5,"3"\\n\'], quoting=csv.QUOTE_NONNUMERIC)))',
    'dictionary = csv.DictReader(["a,b\\n", "1,2,3\\n", "4\\n"], restkey="extra", restval="missing")',
    'print(dictionary.fieldnames)',
    'first = next(dictionary)',
    'print(dictionary.fieldnames, first, next(dictionary))',
    'def names():',
    '    print("fieldnames once")',
    '    yield "left"',
    '    yield "right"',
    'explicit = csv.DictReader(["7,8\\n"], fieldnames=names())',
    'print(next(explicit))',
    'class Sink:',
    '    def __init__(self): self.parts = []',
    '    def write(self, text):',
    '        self.parts.append(text)',
    '        return len(text)',
    'print(csv.QUOTE_MINIMAL, csv.QUOTE_ALL, csv.QUOTE_NONNUMERIC)',
    'quoted = Sink()',
    'csv.writer(quoted, quoting=csv.QUOTE_ALL, lineterminator="\\n").writerows([[1, None]])',
    'print("".join(quoted.parts), end="")',
    'sink = Sink()',
    'writer = csv.DictWriter(sink, fieldnames=["a", "b"], restval="R", extrasaction="ignore", lineterminator="\\n")',
    'print(writer.writeheader())',
    'writer.writerows([{"a": 1, "extra": 9}, {"b": 2}])',
    'print("".join(sink.parts), end="")',
    'try:',
    '    csv.DictWriter(Sink(), fieldnames=["a"], extrasaction="raise").writerow({"a": 1, "extra": 2})',
    'except ValueError:',
    '    print("extras")',
    'with open("/home/roundtrip.csv", "w", newline="") as file:',
    '    csv.writer(file, lineterminator="\\n").writerow(["a", "b\\nc"])',
    'with open("/home/roundtrip.csv", newline="") as file:',
    '    print(list(csv.reader(file)))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, [
    "['a', 'b\\nc', 'd'] 2",
    "['1', '2'] 3",
    "[['雪', '花']]",
    "[[1.0, 2.5, '3']]",
    'None',
    "['a', 'b'] {'a': '1', 'b': '2', 'extra': ['3']} {'a': '4', 'b': 'missing'}",
    'fieldnames once',
    "{'left': '7', 'right': '8'}",
    '0 1 2',
    '"1",""',
    '4',
    'a,b',
    '1,R',
    'R,2',
    'extras',
    "[['a', 'b\\nc']]",
    '',
  ].join('\n'));
});

test('shipping WASM CSV iterator callbacks suspend once and reset cleanly', async () => {
  const prompts = [];
  const peony = await load();
  const output = [];
  const session = peony.createSession({
    quantum: 1,
    maxMemoryBytes: 3 * 1024 * 1024,
    stdout: (text) => output.push(text),
    input: async (prompt) => {
      prompts.push(prompt);
      return 'a,b\n';
    },
  });
  let result = await session.run([
    'import csv',
    'class Lines:',
    '    def __init__(self): self.done = False',
    '    def __iter__(self): return self',
    '    def __next__(self):',
    '        if self.done: raise StopIteration',
    '        self.done = True',
    '        return input("CSV: ")',
    'print(next(csv.reader(Lines())))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  result = await session.run('import json\nprint(json.loads("true"))\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), "CSV: ['a', 'b']\nTrue\n");
  assert.deepEqual(prompts, ['CSV: ']);
});

test('shipping WASM JSON validates bytes and unsupported serializer options', async () => {
  const { result, output } = await run([
    'import json',
    'print(json.loads(b"{\\\"ok\\\":true}")["ok"])',
    'print(json.dumps({"snow": "é›ª"}, ensure_ascii=False))',
    'for call, expected, label in [(lambda: json.loads(b"\\xff"), UnicodeDecodeError, "utf8"), (lambda: json.dumps(float("nan"), allow_nan=False), ValueError, "nan"), (lambda: json.dumps({1, 2}), TypeError, "type"), (lambda: json.loads("{}", object_hook=lambda value: value), TypeError, "hook"), (lambda: json.dumps({}, default=str), TypeError, "default")]:',
    '    try:',
    '        call()',
    '    except expected:',
    '        print(label)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'True\n{"snow": "é›ª"}\nutf8\nnan\ntype\nhook\ndefault\n');
});

test('shipping WASM JSON large loads and dumps timeslice and cancel without replay', async () => {
  const peony = await load();
  const output = [];
  let markerResolve;
  let awaitedMarker = null;
  let marker = new Promise((resolve) => { markerResolve = resolve; });
  const session = peony.createSession({
    quantum: 1,
    maxMemoryBytes: 16 * 1024 * 1024,
    stdout: (text) => {
      output.push(text);
      const joined = output.join('');
      if (awaitedMarker === 'parse' && joined.includes('parse-ready\n')) {
        awaitedMarker = null;
        markerResolve('parse');
      }
      if (awaitedMarker === 'dump' && joined.includes('dump-ready\n')) {
        awaitedMarker = null;
        markerResolve('dump');
      }
    },
  });
  const within = async (pending, label) => {
    let timeout;
    try {
      return await Promise.race([
        pending,
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error(`${label} timeout`)), 5000); }),
      ]);
    } finally {
      clearTimeout(timeout);
    }
  };

  let result = await session.run([
    'import json',
    'doc = "[" + ("\\\"snow\\\"," * 24000) + "\\\"end\\\"]"',
    'value = json.loads(doc)',
    'encoded = json.dumps(value, separators=(",", ":"))',
    'print(len(value), len(encoded), encoded.startswith("[\\\"snow\\\""), encoded.endswith("\\\"end\\\"]"))',
    'giant = "x" * 262145',
    'try:',
    '    json.loads("\\\"" + giant + "\\\"")',
    'except json.JSONDecodeError:',
    '    print("decode token limit")',
    'try:',
    '    json.dumps(giant)',
    'except ValueError:',
    '    print("encode token limit")',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);

  marker = new Promise((resolve) => { markerResolve = resolve; });
  awaitedMarker = 'parse';
  let running = session.run([
    'import json',
    'doc = "[" + ("\\\"snow\\\"," * 24000) + "\\\"end\\\"]"',
    'print("parse-ready")',
    'json.loads(doc)',
    'print("late parse")',
  ].join('\n'));
  assert.equal(await within(marker, 'parse marker'), 'parse');
  session.cancel();
  result = await running;
  assert.equal(result.status, 'cancelled');

  marker = new Promise((resolve) => { markerResolve = resolve; });
  awaitedMarker = 'dump';
  running = session.run([
    'import json',
    'value = ["snow"] * 24000',
    'print("dump-ready")',
    'json.dumps(value)',
    'print("late dump")',
  ].join('\n'));
  assert.equal(await within(marker, 'dump marker'), 'dump');
  session.cancel();
  result = await running;
  assert.equal(result.status, 'cancelled');

  result = await session.run('import json\nprint(json.loads("[1,2]"))\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), '24001 168007 True True\ndecode token limit\nencode token limit\nparse-ready\ndump-ready\n[1, 2]\n');
});

test('shipping WASM CSV rejects invalid dialects with native Error ancestry', async () => {
  const { result, output } = await run([
    'import csv',
    'class Sink:',
    '    def write(self, text): return len(text)',
    'for make in [lambda: csv.reader([], delimiter="ab"), lambda: csv.reader([], quotechar=""), lambda: csv.writer(Sink(), quoting=99)]:',
    '    try:',
    '        make()',
    '    except (TypeError, csv.Error):',
    '        print("dialect")',
    'print(issubclass(csv.Error, Exception))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'dialect\ndialect\ndialect\nTrue\n');
});
