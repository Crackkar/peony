import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import test from 'node:test';

const execute = promisify(execFile);
const executable = resolve('zig-out', process.platform === 'win32' ? 'peony.exe' : 'peony');

function executeWithInput(arguments_, input, cwd) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(executable, arguments_, { cwd, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [];
    const stderr = [];
    child.stdout.setEncoding('utf8').on('data', chunk => stdout.push(chunk));
    child.stderr.setEncoding('utf8').on('data', chunk => stderr.push(chunk));
    child.once('error', rejectRun);
    child.once('close', code => {
      const result = { stdout: stdout.join(''), stderr: stderr.join('') };
      if (code === 0) resolveRun(result);
      else rejectRun(Object.assign(new Error(`Peony exited with code ${code}`), result, { code }));
    });
    child.stdin.end(input);
  });
}

async function withWorkspace(run) {
  const root = await mkdtemp(join(tmpdir(), 'peony-native-'));
  try {
    await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test('native CLI reports its runtime identity', async () => {
  const { stdout, stderr } = await execute(executable, ['--version'], { encoding: 'utf8', windowsHide: true });
  assert.equal(stdout, 'Peony 0.1.0\n');
  assert.equal(stderr, '');
});

test('native CLI reads sibling modules and persists files in its working directory', async () => {
  await withWorkspace(async root => {
    const script = join(root, 'main.py');
    const helper = join(root, 'helper.py');
    const metrics = join(root, 'metrics.json');
    await writeFile(helper, 'answer = 40\n');
    await writeFile(script, [
      'import sys',
      'from helper import answer',
      'with open("result.txt", "w") as file:',
      '    file.write(str(answer + 2))',
      'print(open("result.txt").read(), open(__file__).read().startswith("import sys"))',
      'name = input("Name: ")',
      'print(sys.argv[1:], name)',
    ].join('\n'));

    const { stdout, stderr } = await executeWithInput([
      '--metrics', metrics,
      script,
      'alpha',
      'two words',
    ], 'Ada\n', root);

    assert.equal(stdout, "42 True\nName: ['alpha', 'two words'] Ada\n");
    assert.equal(stderr, '');
    assert.equal(await readFile(join(root, 'result.txt'), 'utf8'), '42');
    const report = JSON.parse(await readFile(metrics, 'utf8'));
    assert.equal(report.schema, 1);
    assert.equal(report.status, 'completed');
    assert.ok(Number.isSafeInteger(report.elapsed_ns) && report.elapsed_ns > 0);
    assert.ok(Number.isSafeInteger(report.instructions) && report.instructions > 0);
    assert.ok(Number.isSafeInteger(report.work) && report.work >= report.instructions);
    assert.ok(Number.isSafeInteger(report.peak_session_bytes) && report.peak_session_bytes > 0);
  });
});

test('native paths use host absolute paths and directory operations', async () => {
  await withWorkspace(async root => {
    const script = join(root, 'paths.py');
    await writeFile(script, [
      'import os',
      'import sys',
      'from pathlib import Path',
      'directory = os.path.join(sys.argv[1], "nested")',
      'os.makedirs(directory)',
      'file = Path(directory) / "note.txt"',
      'file.write_text("native")',
      'with open(file, "r+") as stream:',
      '    stream.seek(2)',
      '    stream.write("!")',
      '    stream.truncate(4)',
      'print(file.name, file.parent.name, file.read_text())',
      'print(os.path.exists(str(file)), os.path.isdir(directory))',
    ].join('\n'));
    const { stdout, stderr } = await execute(executable, [script, root], { encoding: 'utf8', windowsHide: true });
    assert.equal(stdout, 'note.txt nested na!i\nTrue True\n');
    assert.equal(stderr, '');
    assert.equal(await readFile(join(root, 'nested', 'note.txt'), 'utf8'), 'na!i');
  });
});

test('native buffered file reads cross chunk, UTF-8, and CRLF boundaries', async () => {
  await withWorkspace(async root => {
    const script = join(root, 'stream.py');
    await writeFile(join(root, 'text.txt'), `${'x'.repeat(8191)}\r\né\n${'y'.repeat(8191)}é\n`);
    await writeFile(script, [
      'with open("text.txt", newline="") as stream:',
      '    first = stream.readline()',
      '    second = stream.readline()',
      '    third = stream.readline()',
      '    print(len(first), repr(second), len(third), third.endswith("é\\n"))',
      'with open("text.txt") as stream:',
      '    first = stream.read(8192)',
      '    print(len(first), first.endswith("\\n"), stream.read(1))',
      'with open("text.txt", "rb") as stream:',
      '    stream.seek(8191)',
      '    print(stream.read(3))',
    ].join('\n'));
    const { stdout, stderr } = await execute(executable, [script], { cwd: root, encoding: 'utf8', windowsHide: true });
    assert.equal(stdout, "8193 'é\\n' 8193 True\n8192 True é\nb'\\r\\n\\xc3'\n");
    assert.equal(stderr, '');
  });
});

test('native CLI renders source-located Python failures and uses a failure exit code', async () => {
  await withWorkspace(async root => {
    const script = join(root, 'broken.py');
    await writeFile(script, 'def explode():\n    return missing\nexplode()\n');
    await assert.rejects(
      execute(executable, [script], { encoding: 'utf8', windowsHide: true }),
      error => {
        assert.equal(error.code, 1);
        assert.equal(error.stdout, '');
        assert.match(error.stderr, /Traceback \(most recent call last\):/);
        assert.match(error.stderr, /broken\.py/);
        assert.match(error.stderr, /NameError/);
        return true;
      },
    );
  });
});

test('native CLI maps invalid UTF-8 stdin into a catchable Python I/O error', async () => {
  await withWorkspace(async root => {
    const script = join(root, 'input-error.py');
    await writeFile(script, 'try:\n    input("Bad: ")\nexcept OSError:\n    print("input failure")\n');
    const { stdout, stderr } = await executeWithInput([script], Buffer.from([0xff, 0x0a]));
    assert.equal(stdout, 'Bad: input failure\n');
    assert.equal(stderr, '');
  });
});

test('native CLI supplies clocks, sleep, and HTTP through the shared host protocol', async () => {
  await withWorkspace(async root => {
    const server = createServer((request, response) => {
      if (request.url === '/slow') {
        setTimeout(() => {
          response.writeHead(200, { 'content-type': 'text/plain' });
          response.end('late');
        }, 250);
        return;
      }
      assert.equal(request.url, '/native');
      response.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'x-peony': 'native' });
      response.end('hello from zig');
    });
    await new Promise((resolveListen, rejectListen) => {
      server.once('error', rejectListen);
      server.listen(0, '127.0.0.1', resolveListen);
    });
    try {
      const address = server.address();
      assert.ok(address && typeof address === 'object');
      const script = join(root, 'host.py');
      await writeFile(script, [
        'import time',
        'import requests',
        'before = time.monotonic()',
        'time.sleep(0)',
        `response = requests.get("http://127.0.0.1:${address.port}/native")`,
        'print(time.time() > 0, time.monotonic() >= before)',
        'print(response.status_code, response.headers["x-peony"], response.text)',
        'try:',
        `    requests.get("http://127.0.0.1:${address.port}/slow", timeout=0.02)`,
        'except requests.exceptions.Timeout:',
        '    print("timeout")',
      ].join('\n'));
      const { stdout, stderr } = await execute(executable, [script], { encoding: 'utf8', windowsHide: true });
      assert.equal(stdout, 'True True\n200 native hello from zig\ntimeout\n');
      assert.equal(stderr, '');
    } finally {
      await new Promise(resolveClose => server.close(resolveClose));
    }
  });
});
