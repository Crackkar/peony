import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const wasmPath = fileURLToPath(new URL('../zig-out/peony.wasm', import.meta.url));
const status = Object.freeze({ ok: 0, completed: 5, pythonException: 6, timeslice: 7, cancelled: 8, hostRequest: 10, outputEvent: 11, limit: 12 });

async function api() {
  const bytes = await readFile(wasmPath);
  return (await WebAssembly.instantiate(bytes, {})).instance.exports;
}

function transfer(instance, value) {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;
  const pointer = instance.peony_transfer_alloc(bytes.length);
  assert.ok(pointer > 0);
  new Uint8Array(instance.memory.buffer, pointer, bytes.length).set(bytes);
  return { pointer, length: bytes.length };
}

function compile(instance, handle, source) {
  const code = transfer(instance, source);
  const filename = transfer(instance, 'wasm-library-regex.py');
  try {
    return instance.peony_compile_and_start(handle, code.pointer, code.length, filename.pointer, filename.length);
  } finally {
    instance.peony_transfer_free(code.pointer, code.length);
    instance.peony_transfer_free(filename.pointer, filename.length);
  }
}

function borrowedText(instance, handle, prefix) {
  const pointer = instance[`${prefix}_ptr`](handle);
  const length = instance[`${prefix}_len`](handle);
  return length === 0 ? '' : new TextDecoder().decode(new Uint8Array(instance.memory.buffer, pointer, length));
}

function runBoundary(instance, handle, quantum = 1) {
  let result = status.timeslice;
  for (let step = 0; step < 250_000; step += 1) {
    result = instance.peony_run(handle, quantum);
    if (result !== status.timeslice && result !== status.outputEvent) return result;
  }
  throw new Error('regex program did not reach an execution boundary');
}

function event(instance, handle) {
  const pointer = instance.peony_event_ptr(handle);
  const length = instance.peony_event_len(handle);
  const bytes = new Uint8Array(instance.memory.buffer, pointer, length).slice();
  const view = new DataView(bytes.buffer);
  const sectionCount = view.getUint16(16, true);
  const sections = [];
  for (let index = 0; index < sectionCount; index += 1) {
    const descriptor = 24 + index * 12;
    const offset = view.getUint32(descriptor + 4, true);
    const size = view.getUint32(descriptor + 8, true);
    sections.push({ kind: view.getUint16(descriptor, true), bytes: bytes.slice(offset, offset + size) });
  }
  return { kind: view.getUint16(6, true), requestId: view.getUint32(8, true), sections };
}

function encodeInput(requestId, text) {
  const payload = new TextEncoder().encode(text);
  const bytes = new Uint8Array(36 + payload.length);
  const view = new DataView(bytes.buffer);
  bytes.set([0x50, 0x45, 0x4f, 0x4e]);
  view.setUint16(4, 1, true);
  view.setUint16(6, 1, true);
  view.setUint32(8, requestId, true);
  view.setUint16(12, 0, true);
  view.setUint16(16, 1, true);
  view.setUint32(20, bytes.length, true);
  view.setUint16(24, 1, true);
  view.setUint32(28, 36, true);
  view.setUint32(32, payload.length, true);
  bytes.set(payload, 36);
  return bytes;
}

function resume(instance, handle, packet) {
  const block = transfer(instance, packet);
  try {
    return instance.peony_resume(handle, block.pointer, block.length);
  } finally {
    instance.peony_transfer_free(block.pointer, block.length);
  }
}

async function completedOutput(source, quantum = 1) {
  const instance = await api();
  const handle = instance.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    assert.equal(compile(instance, handle, source), status.ok);
    const result = runBoundary(instance, handle, quantum);
    assert.equal(result, status.completed, borrowedText(instance, handle, 'peony_error'));
    return borrowedText(instance, handle, 'peony_stdout');
  } finally {
    instance.peony_session_destroy(handle);
  }
}

test('shipping WASM regex supports ordered matching, flags, Unicode and bytes', async () => {
  const output = await completedOutput([
    'import re',
    'print(re.search(r"a|ab", "ab").group(), re.search(r"ab|a", "ab").group())',
    'print(re.search(r"a.*b", "axxbxxb").group(), re.search(r"a.*?b", "axxbxxb").group())',
    'print(re.findall(r"^[a-c]{2,3}$", "ab\\nabc\\nabcd", re.M))',
    'print(bool(re.search("k", "\\u212a", re.I)), bool(re.search("k", "\\u212a", re.I | re.A)))',
    'print(re.findall(r"\\d+", "x\\u0661\\u0662 34"), re.findall(r"\\d+", "x\\u0661\\u0662 34", re.A))',
    'print(re.findall(rb"\\w+", b"a_1 \\xff"))',
    'print(re.A == re.ASCII, re.I == re.IGNORECASE, re.M == re.MULTILINE, re.S == re.DOTALL, re.U == re.UNICODE)',
    'print(bool(re.fullmatch(r"\\D\\W\\s\\S", "a \\tx")), bool(re.search(r"\\bword\\b", " word ")), re.findall(r"[^a]+", "abca"), bool(re.fullmatch(r"a\\+b", "a+b")), re.findall(r"a{2,3}?", "aaaaa"))',
  ].join('\n'));
  assert.equal(output, "a ab\naxxbxxb axxb\n['ab', 'abc']\nTrue False\n['١٢', '34'] ['34']\n[b'a_1']\nTrue True True True True\nTrue True ['bc'] True ['aa', 'aa']\n");
});

test('shipping WASM exposes Pattern and Match protocols with empty-match progression', async () => {
  const output = await completedOutput([
    'import re',
    'p = re.compile(r"(?P<word>\\w+?)(?P<digits>\\d+)", re.I)',
    'm = p.search("xxAb12yy", 2, 8)',
    'print(p.pattern, p.flags, p.groups, p.groupindex)',
    'print(m.group(0, 1, "digits"), m.groups("X"), m.groupdict("X"))',
    'print(m["digits"], m[True])',
    'print(m.start(1), m.end("digits"), m.span(), m.string, m.re is p)',
    'q = re.compile("a")',
    'print(q.match(string="ba", pos=1, endpos=2).group(), q.search(string="ba", pos=1, endpos=2).group(), q.fullmatch(string="ba", pos=1, endpos=2).group())',
    'print(q.findall(string="caba", pos=1, endpos=3), [item.span() for item in q.finditer(string="caba", pos=1, endpos=4)])',
    'print(q.split(string="aba", maxsplit=1))',
    'print(q.sub(repl="Z", string="aba", count=1), q.subn(repl="Z", string="aba", count=1))',
    'print(re.fullmatch(pattern=r"\\w+", string="abc", flags=re.A).group())',
    'print(re.escape(pattern="a.b"))',
    'print(re.compile(pattern="a", flags=0).pattern, re.search(pattern="a", string="ba", flags=0).span(), bool(re.match(pattern="a", string="ab", flags=0)))',
    'print(re.findall(pattern="a", string="aba", flags=0), [item.span() for item in re.finditer(pattern="a", string="aba", flags=0)])',
    'print(re.split(pattern="a", string="aba", maxsplit=1, flags=0), re.sub(pattern="a", repl="X", string="aba", count=1, flags=0), re.subn(pattern="a", repl="X", string="aba", count=1, flags=0))',
    'print([item.span() for item in re.finditer(r"|a", "a")])',
    'print(re.findall(r"(a)|(b)", "ab"), re.findall(r"\\B", ""))',
    'missing = re.match(r"(a)?b", "b")',
    'print(missing.group(1), missing.groups("x"), missing.span(1))',
  ].join('\n'));
  assert.equal(output, [
    "(?P<word>\\w+?)(?P<digits>\\d+) 34 2 {'word': 1, 'digits': 2}",
    "('Ab12', 'Ab', '12') ('Ab', '12') {'word': 'Ab', 'digits': '12'}",
    '12 Ab',
    '2 6 (2, 6) xxAb12yy True',
    'a a a',
    "['a'] [(1, 2), (3, 4)]",
    "['', 'ba']",
    "Zba ('Zba', 1)",
    'abc',
    'a\\.b',
    'a (1, 2) True',
    "['a', 'a'] [(0, 1), (2, 3)]",
    "['', 'ba'] Xba ('Xba', 1)",
    '[(0, 0), (0, 1), (1, 1)]',
    "[('a', ''), ('', 'b')] []",
    "None ('x',) (-1, -1)",
    '',
  ].join('\n'));
});

test('shipping WASM regex substitution supports templates and resumable callbacks', async () => {
  const instance = await api();
  const handle = instance.peony_session_new(0, 0);
  assert.ok(handle > 0);
  try {
    const source = [
      'import re',
      'calls = 0',
      'def replacement(match):',
      '    global calls',
      '    calls += 1',
      '    return input("R: ") + match.group(0)',
      'print(re.sub(r"[ab]", replacement, "ab"), calls)',
      'print(re.subn(r"(?P<x>a)", r"[\\g<x>]-\\1", "aba"))',
      'print(re.split(r"(,)", "a,b,,c", maxsplit=2))',
      'print(re.escape("a.b-c_ /"))',
      'print(re.findall(r"(.)", "é中"), re.split(r"(é)", "aéb"), re.sub(r"(é)", r"<\\1>", "aéb"))',
    ].join('\n');
    assert.equal(compile(instance, handle, source), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    let request = event(instance, handle);
    assert.equal(request.kind, 1);
    assert.equal(resume(instance, handle, encodeInput(request.requestId, 'X')), status.ok);
    assert.equal(runBoundary(instance, handle), status.hostRequest);
    request = event(instance, handle);
    assert.equal(resume(instance, handle, encodeInput(request.requestId, 'Y')), status.ok);
    assert.equal(runBoundary(instance, handle), status.completed, borrowedText(instance, handle, 'peony_error'));
    assert.equal(borrowedText(instance, handle, 'peony_stdout'), "R: R: XaYb 2\n('[a]-ab[a]-a', 2)\n['a', ',', 'b', ',', ',c']\na\\.b\\-c_\\ /\n['é', '中'] ['a', 'é', 'b'] a<é>b\n");
  } finally {
    instance.peony_session_destroy(handle);
  }
});

test('shipping WASM regex rejects excluded grammar and mixed string families explicitly', async () => {
  const output = await completedOutput([
    'import re',
    'for pattern in [r"(a)\\1", r"(?=a)", r"(?!a)", r"(?<=a)b", r"(?>a)", r"(?i:a)", r"(?(1)a|b)"]:',
    '    try:',
    '        re.compile(pattern)',
    '    except re.error as problem:',
    '        print(isinstance(problem, ValueError), bool(problem.msg), problem.pattern is pattern, problem.pos >= 0)',
    'try:',
    '    re.compile(b"a", 4)',
    'except re.error as problem:',
    '    print(problem.pos == 0)',
    'try:',
    '    re.compile(b"a", re.U)',
    'except ValueError:',
    '    print("unicode bytes")',
    'try:',
    '    re.search("a", b"a")',
    'except TypeError:',
    '    print("mixed")',
  ].join('\n'));
  assert.equal(output, 'True True True True\n'.repeat(7) + 'True\nunicode bytes\nmixed\n');
});

const regexBenchmarkEnabled = process.env.PEONY_BENCH_REGEX === '1';

test('opt-in shipping WASM regex performance workloads', { skip: !regexBenchmarkEnabled }, async () => {
  const asciiInput = 'alpha_1 beta2 # comment_3\n'.repeat(2520);
  const unicodeInput = 'Αλφα βήτα ١٢٣ 中文\n'.repeat(1000);
  const denseInput = 'a'.repeat(16 * 1024);
  const longInput = 'a'.repeat(64 * 1024);
  const overRepeat = 'a{0,1001}';
  const workloads = [
    {
      name: 'ascii-sparse-64k',
      input: asciiInput,
      source: `import re\ntext = ${JSON.stringify(asciiInput)}\nprint(len(re.findall(r"\\b[A-Za-z_]\\w*\\b", text)))\n`,
      expected: '7560\n',
    },
    {
      name: 'unicode-classes-32k',
      input: unicodeInput,
      source: `import re\ntext = ${JSON.stringify(unicodeInput)}\nprint(len(re.findall(r"\\w+", text, re.I)))\n`,
      expected: '4000\n',
    },
    {
      name: 'dense-empty-nonempty-16k',
      input: denseInput,
      source: `import re\ntext = ${JSON.stringify(denseInput)}\ncount = 0\nwidth = 0\nfor match in re.finditer(r"|a", text):\n    count += 1\n    width += match.end() - match.start()\nprint(count, width)\n`,
      expected: '32769 16384\n',
    },
    {
      name: 'long-no-match-64k',
      input: longInput,
      source: `import re\ntext = ${JSON.stringify(longInput)}\nprint(re.search(r"(?:a|aa)*b", text) is None)\n`,
      expected: 'True\n',
    },
    {
      name: 'counted-repeat-cap',
      input: overRepeat,
      source: `import re\ntry:\n    re.compile(${JSON.stringify(overRepeat)})\nexcept re.error:\n    print("repeat cap")\n`,
      expected: 'repeat cap\n',
    },
  ];

  const records = [];
  for (const workload of workloads) {
    const instantiateStarted = performance.now();
    const instance = await api();
    const instantiateMs = performance.now() - instantiateStarted;
    const samples = [];
    let peakWasmBytes = instance.memory.buffer.byteLength;
    for (let repetition = 0; repetition < 13; repetition += 1) {
      const handle = instance.peony_session_new(0, 0);
      assert.ok(handle > 0);
      try {
        assert.equal(compile(instance, handle, workload.source), status.ok);
        const started = performance.now();
        const result = runBoundary(instance, handle, 50_000);
        const elapsedMs = performance.now() - started;
        assert.equal(result, status.completed, borrowedText(instance, handle, 'peony_error'));
        assert.equal(borrowedText(instance, handle, 'peony_stdout'), workload.expected);
        peakWasmBytes = Math.max(peakWasmBytes, instance.memory.buffer.byteLength);
        if (repetition >= 3) samples.push({
          elapsedMs,
          instructions: Number(instance.peony_instruction_count(handle)),
          work: Number(instance.peony_work_count(handle)),
        });
      } finally {
        instance.peony_session_destroy(handle);
      }
    }
    const elapsed = samples.map((sample) => sample.elapsedMs).sort((left, right) => left - right);
    records.push({
      name: workload.name,
      inputBytes: Buffer.byteLength(workload.input),
      inputSha256: createHash('sha256').update(workload.input).digest('hex'),
      warmups: 3,
      repetitions: 10,
      instantiateMs,
      medianMs: percentile(elapsed, 0.5),
      p95Ms: percentile(elapsed, 0.95),
      peakWasmBytes,
      medianInstructions: percentile(samples.map((sample) => sample.instructions).sort((left, right) => left - right), 0.5),
      medianWork: percentile(samples.map((sample) => sample.work).sort((left, right) => left - right), 0.5),
    });
  }
  process.stdout.write(`PEONY_REGEX_BENCH ${JSON.stringify({ node: process.version, workloads: records })}\n`);
});

function percentile(sorted, fraction) {
  assert.ok(sorted.length > 0);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}
