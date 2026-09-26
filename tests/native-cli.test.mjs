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

function executeWithInput(arguments_, input) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(executable, arguments_, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
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
  assert.equal(stdout, 'Peony 0.1.0 (Python 3.12 subset)\n');
  assert.equal(stderr, '');
});

test('native CLI executes a file with argv, explicit VFS mounts, and metrics', async () => {
  await withWorkspace(async root => {
    const script = join(root, 'main.py');
    const helper = join(root, 'helper.py');
    const metrics = join(root, 'metrics.json');
    await writeFile(helper, 'answer = 40\n');
    await writeFile(script, [
      'import sys',
      'from helper import answer',
      'name = input("Name: ")',
      'print(answer + 2, sys.argv, name)',
    ].join('\n'));

    const { stdout, stderr } = await executeWithInput([
      '--filename', '/home/main.py',
      '--mount', helper, '/home/helper.py',
      '--metrics', metrics,
      script,
      'alpha',
      'two words',
    ], 'Ada\n');

    assert.equal(stdout, "Name: 42 ['/home/main.py', 'alpha', 'two words'] Ada\n");
    assert.equal(stderr, '');
    const report = JSON.parse(await readFile(metrics, 'utf8'));
    assert.equal(report.schema, 1);
    assert.equal(report.status, 'completed');
    assert.ok(Number.isSafeInteger(report.elapsed_ns) && report.elapsed_ns > 0);
    assert.ok(Number.isSafeInteger(report.instructions) && report.instructions > 0);
    assert.ok(Number.isSafeInteger(report.work) && report.work >= report.instructions);
    assert.ok(Number.isSafeInteger(report.peak_session_bytes) && report.peak_session_bytes > 0);
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
