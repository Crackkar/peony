import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Peony } from '../web/peony.mjs';

const wasmPath = new URL('../zig-out/peony.wasm', import.meta.url);
const load = async () => Peony.load(new Uint8Array(await readFile(wasmPath)));

test('course word-frequency program reads a mounted file and counts native words', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ stdout: text => output.push(text) });
  session.mount({ '/course/words.txt': 'red blue red green red blue\n' });
  const result = await session.run([
    'from collections import Counter',
    'with open("/course/words.txt") as source:',
    '    counts = Counter(source.read().split())',
    'print(counts.most_common(2))',
  ].join('\n'), { filename: '/home/frequency.py' });
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), "[('red', 3), ('blue', 2)]\n");
});

test('course regex program extracts email domains and preserves encounter ties', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ stdout: text => output.push(text) });
  session.mount({ '/course/mail.txt': 'Ada@school.edu Bo@club.org Cy@school.edu\n' });
  const result = await session.run([
    'import re',
    'from collections import Counter',
    'with open("/course/mail.txt") as source:',
    '    addresses = re.findall(r"[A-Za-z]+@[A-Za-z.]+", source.read())',
    'domains = Counter()',
    'for address in addresses:',
    '    domains[address.split("@")[1]] += 1',
    'print(domains.most_common())',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), "[('school.edu', 2), ('club.org', 1)]\n");
});

test('course CSV aggregation uses Path, native reader and int conversion', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ stdout: text => output.push(text), quantum: 1 });
  session.mount({ '/course/points.csv': 'Ada,2\nBo,3\nCy,4\n' });
  const result = await session.run([
    'import csv',
    'from pathlib import Path',
    'total = 0',
    'with open(Path("/course/points.csv"), newline="") as source:',
    '    for row in csv.reader(source):',
    '        total += int(row[1])',
    'print(total)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), '9\n');
});

test('course JSON API program uses mocked browser transport and native parsing', async () => {
  const peony = await load();
  const output = [];
  const urls = [];
  const session = peony.createSession({
    stdout: text => output.push(text),
    fetch: async (url, options) => {
      urls.push([url, options.credentials, options.redirect]);
      return new Response('{"items":[{"score":3},{"score":5}]}', { status: 200, headers: { 'content-type': 'application/json' } });
    },
  });
  const result = await session.run([
    'import requests',
    'response = requests.get("https://example.test/scores", params={"lesson": 1})',
    'total = 0',
    'for item in response.json()["items"]:',
    '    total += item["score"]',
    'print(total, response.ok)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), '8 True\n');
  assert.deepEqual(urls, [['https://example.test/scores?lesson=1', 'omit', 'error']]);
});

test('course Path and copy program retains files and graph aliases across runs', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ stdout: text => output.push(text) });
  let result = await session.run([
    'from pathlib import Path',
    'import copy',
    'Path("/home/story.txt").write_text("chapter one")',
    'shared = [1, 2]',
    'graph = [shared, shared]',
    'cloned = copy.deepcopy(graph)',
    'print(cloned[0] is cloned[1], cloned[0] is shared)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  result = await session.run('from pathlib import Path\nprint(Path("/home/story.txt").read_text())\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'True False\nchapter one\n');
});

test('course input program converts a learner answer to an integer', async () => {
  const peony = await load();
  const output = [];
  const prompts = [];
  const session = peony.createSession({
    stdout: text => output.push(text),
    input: async prompt => { prompts.push(prompt); return '20'; },
    quantum: 1,
  });
  const result = await session.run('degrees = int(input("Celsius: "))\nprint(degrees * 9 / 5 + 32)\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.deepEqual(prompts, ['Celsius: ']);
  assert.equal(output.join(''), 'Celsius: 68.0\n');
});

test('course exclusions fail with module errors instead of accidental stand-ins', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ stdout: text => output.push(text) });
  const result = await session.run([
    'for name in ["sqlite3", "socket", "xml", "pytest"]:',
    '    try:',
    '        __import__(name)',
    '    except ModuleNotFoundError:',
    '        print(name)',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'sqlite3\nsocket\nxml\npytest\n');
});
