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
  const result = await session.run(source, { filename: 'wasm-library-vfs.py' });
  return { result, output: output.join(''), session };
}

test('shipping WASM Path preserves lexical POSIX behavior and uses the VFS', async () => {
  const { result, output } = await run([
    'from pathlib import Path',
    'p = Path("a", "..", "b.txt")',
    'print(str(p), p.name, p.suffix, p.stem, str(p.parent))',
    'print(str(Path()), repr(Path()))',
    'print(str(Path("/root") / "child"), str("prefix" / Path("leaf")))',
    'print(Path("a//b/") == Path("a", "b"), hash(Path("a//b/")) == hash(Path("a/b")))',
    'root = Path("/home/tree")',
    '(root / "a" / "b").mkdir(parents=True)',
    '(root / "empty").mkdir()',
    'text = root / "a" / "b" / "note.txt"',
    'print(text.write_text("line1\\n雪"), text.read_text())',
    'print(root.exists(), root.is_dir(), text.exists(), text.is_file())',
    'print(sorted([item.name for item in root.iterdir()]), list((root / "empty").iterdir()))',
    'with open(text, "a") as handle:',
    '    handle.write("!")',
    'print(text.read_text())',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, 'a/../b.txt b.txt .txt b a/..\n. Path(\'.\')\n/root/child prefix/leaf\nTrue True\n7 line1\n雪\nTrue True True True\n[\'a\', \'empty\'] []\nline1\n雪!\n');
});

test('shipping WASM os and os.path preserve open handle identity across namespace mutation', async () => {
  const { result, output } = await run([
    'import os',
    'from pathlib import Path',
    'print(os.getcwd())',
    'os.mkdir("/home/single", mode=0o700)',
    'print(os.listdir("/home"))',
    'print(os.path.join("/a", "b", "/c", "d"), os.path.join("a", ""), os.path.basename("/a/b/"), os.path.dirname("/a/b/"))',
    'os.makedirs("/home/work/nested", exist_ok=True)',
    'with open("/home/work/live.txt", "w+") as handle:',
    '    handle.write("old")',
    '    handle.seek(0)',
    '    os.rename("/home/work/live.txt", "/home/work/renamed.txt")',
    '    print(handle.read(), os.path.exists("/home/work/live.txt"), os.path.isfile("/home/work/renamed.txt"))',
    '    handle.seek(0)',
    '    handle.write("new")',
    'print(Path("/home/work/renamed.txt").read_text())',
    'with open("/home/work/unlinked.txt", "w+") as handle:',
    '    handle.write("kept")',
    '    handle.seek(0)',
    '    os.unlink("/home/work/unlinked.txt")',
    '    print(handle.read(), os.path.exists("/home/work/unlinked.txt"))',
    'Path("/home/work/source.txt").write_text("source")',
    'Path("/home/work/dest.txt").write_text("dest")',
    'os.replace("/home/work/source.txt", "/home/work/dest.txt")',
    'print(Path("/home/work/dest.txt").read_text())',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output, '/home\n[\'single\']\n/c/d a/  /a/b\nold False True\nnew\nkept False\nsource\n');
});

test('shipping WASM VFS failures preserve readonly roots and existing data', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({
    quantum: 1,
    maxMemoryBytes: 2 * 1024 * 1024,
    maxVfsBytes: 128,
    maxFileBytes: 16,
    stdout: (text) => output.push(text),
  });
  session.mount({ '/assets/sample.txt': 'sample' });
  const result = await session.run([
    'import os',
    'from pathlib import Path',
    'print(Path("/assets/sample.txt").read_text())',
    'for call, expected, label in [(lambda: Path("/assets/sample.txt").write_text("bad"), PermissionError, "PermissionError"), (lambda: os.remove("/assets/sample.txt"), PermissionError, "PermissionError")]:',
    '    try:',
    '        call()',
    '    except expected:',
    '        print(label)',
    'target = Path("/home/atomic.txt")',
    'target.write_text("old")',
    'try:',
    '    target.write_text("x" * 17)',
    'except OSError:',
    '    print("too large", target.read_text())',
    'Path("/home/dir/sub").mkdir(parents=True)',
    'try:',
    '    os.rename("/home/dir", "/home/dir/sub/moved")',
    'except OSError:',
    '    print("self move", os.path.isdir("/home/dir/sub"))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'sample\nPermissionError\nPermissionError\ntoo large old\nself move True\n');
});

test('shipping WASM retains Path files and empty directories across session runs', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ quantum: 1, maxMemoryBytes: 3 * 1024 * 1024, stdout: (text) => output.push(text) });
  let result = await session.run([
    'from pathlib import Path',
    'Path("/home/persist/empty").mkdir(parents=True)',
    'Path("/home/persist/data.txt").write_text("雪" * 100)',
    'print(Path("/home/persist/data.txt").is_file(), Path("/home/persist/empty").is_dir())',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  result = await session.run('import os\nfrom pathlib import Path\nprint(len(Path("/home/persist/data.txt").read_text()), os.path.isdir("/home/persist/empty"))\n');
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), 'True True\n100 True\n');
});

test('shipping WASM Path bytes and readonly rename boundaries are native', async () => {
  const peony = await load();
  const output = [];
  const session = peony.createSession({ quantum: 1, stdout: (text) => output.push(text) });
  session.mount({ '/assets/sample.bin': new Uint8Array([0, 255]) });
  const result = await session.run([
    'import os',
    'from pathlib import Path',
    'blob = Path("/home/blob.bin")',
    'print(blob.write_bytes(b"\\x00\\xff"), blob.read_bytes())',
    'try:',
    '    os.rename("/assets/sample.bin", "/home/stolen.bin")',
    'except PermissionError:',
    '    print("readonly", Path("/assets/sample.bin").read_bytes(), os.path.exists("/home/stolen.bin"))',
  ].join('\n'));
  assert.equal(result.status, 'completed', result.error?.message);
  assert.equal(output.join(''), "2 b'\\x00\\xff'\nreadonly b'\\x00\\xff' False\n");
});
