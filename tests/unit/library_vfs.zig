const std = @import("std");
const vm = @import("runtime_vm");
const host = @import("runtime_host");

pub fn testPathLexicalContract() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\from pathlib import Path
        \\p = Path('a', '..', 'b.txt')
        \\print(str(p), p.name, p.suffix, p.stem, str(p.parent))
        \\print(str(Path('/root') / 'child'), str('prefix' / Path('leaf')))
        \\print(Path('a//b/') == Path('a', 'b'), hash(Path('a//b/')) == hash(Path('a/b')))
        \\print(repr(Path('a')).endswith("('a')"), str(Path()), Path().name, str(Path().parent))
        \\print(Path('/').name, str(Path('/').parent), Path('archive.tar.gz').suffix, Path('.hidden').suffix)
    , "library-vfs-path-lexical.py", 1);
    try std.testing.expectEqualStrings(
        "a/../b.txt b.txt .txt b a/..\n/root/child prefix/leaf\nTrue True\nTrue .  .\n / .gz \n",
        runtime.stdout(),
    );
}

pub fn testPathVfsMethodsAndOpenProtocol() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\from pathlib import Path
        \\root = Path('/home/tree')
        \\leaf = root / 'a' / 'b'
        \\leaf.mkdir(parents=True)
        \\empty = root / 'empty'
        \\empty.mkdir()
        \\text = leaf / 'note.txt'
        \\binary = leaf / 'blob.bin'
        \\print(text.write_text('line1\n雪'), text.read_text())
        \\print(binary.write_bytes(b'\x00\xff'), binary.read_bytes())
        \\print(root.exists(), root.is_dir(), text.exists(), text.is_file(), empty.is_dir())
        \\print(sorted([item.name for item in root.iterdir()]))
        \\print(list(empty.iterdir()))
        \\with open(text, 'a') as handle:
        \\    handle.write('!')
        \\print(text.read_text())
        \\try:
        \\    leaf.mkdir()
        \\except FileExistsError:
        \\    print('exists')
        \\leaf.mkdir(exist_ok=True)
    , "library-vfs-path-io.py", 1);
    try std.testing.expectEqualStrings(
        "7 line1\n雪\n2 b'\\x00\\xff'\nTrue True True True True\n['a', 'empty']\n[]\nline1\n雪!\nexists\n",
        runtime.stdout(),
    );
}

pub fn testOsPathAndMutationContract() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try runScript(&runtime,
        \\import os
        \\from pathlib import Path
        \\print(os.getcwd())
        \\print(os.path.join('/a', 'b', '/c', 'd'), os.path.join('a', ''), os.path.basename('/a/b/'), os.path.dirname('/a/b/'))
        \\os.makedirs('/home/work/nested', exist_ok=True)
        \\os.mkdir(Path('/home/work/empty'))
        \\with open('/home/work/live.txt', 'w+') as handle:
        \\    handle.write('old')
        \\    handle.seek(0)
        \\    os.rename('/home/work/live.txt', '/home/work/renamed.txt')
        \\    print(handle.read(), os.path.exists('/home/work/live.txt'), os.path.isfile('/home/work/renamed.txt'))
        \\    handle.seek(0)
        \\    handle.write('new')
        \\print(Path('/home/work/renamed.txt').read_text())
        \\with open('/home/work/unlinked.txt', 'w+') as handle:
        \\    handle.write('kept')
        \\    handle.seek(0)
        \\    os.unlink('/home/work/unlinked.txt')
        \\    print(handle.read(), os.path.exists('/home/work/unlinked.txt'))
        \\Path('/home/work/source.txt').write_text('source')
        \\Path('/home/work/dest.txt').write_text('dest')
        \\os.replace('/home/work/source.txt', '/home/work/dest.txt')
        \\print(Path('/home/work/dest.txt').read_text())
        \\print(sorted(os.listdir(Path('/home/work'))))
        \\os.remove('/home/work/dest.txt')
        \\print(os.path.isdir('/home/work/nested'), os.path.exists('/home/work/dest.txt'))
    , "library-vfs-os.py", 1);
    try std.testing.expectEqualStrings(
        "/home\n/c/d a/  /a/b\nold False True\nnew\nkept False\nsource\n['dest.txt', 'empty', 'nested', 'renamed.txt']\nTrue False\n",
        runtime.stdout(),
    );
}

pub fn testVfsReadonlyAndErrorAtomicity() !void {
    var config = host.Config.defaults();
    config.max_memory_bytes = 2 * 1024 * 1024;
    config.max_vfs_bytes = 128;
    config.max_file_bytes = 16;
    var runtime: vm.Runtime = undefined;
    try runtime.initWithConfig(std.testing.allocator, config);
    defer runtime.deinit();
    try runtime.mountCourseFile("/course/lesson.txt", "lesson");
    try runScript(&runtime,
        \\import os
        \\from pathlib import Path
        \\print(Path('/course/lesson.txt').read_text())
        \\for call, expected, label in [
        \\    (lambda: Path('/course/lesson.txt').write_text('bad'), PermissionError, 'PermissionError'),
        \\    (lambda: os.remove('/course/lesson.txt'), PermissionError, 'PermissionError'),
        \\    (lambda: os.rename('/course/lesson.txt', '/home/stolen.txt'), PermissionError, 'PermissionError'),
        \\]:
        \\    try:
        \\        call()
        \\    except expected:
        \\        print(label)
        \\target = Path('/home/atomic.txt')
        \\target.write_text('old')
        \\try:
        \\    target.write_text('x' * 17)
        \\except OSError:
        \\    print('too large', target.read_text())
        \\Path('/home/dir/sub').mkdir(parents=True)
        \\try:
        \\    os.rename('/home/dir', '/home/dir/sub/moved')
        \\except OSError:
        \\    print('self move', os.path.isdir('/home/dir/sub'))
        \\try:
        \\    os.remove('/home/dir')
        \\except OSError:
        \\    print('directory preserved', os.path.isdir('/home/dir'))
    , "library-vfs-errors.py", 1);
    try std.testing.expectEqualStrings(
        "lesson\nPermissionError\nPermissionError\nPermissionError\ntoo large old\nself move True\ndirectory preserved True\n",
        runtime.stdout(),
    );
}

pub fn testVfsGcAndResetPersistence() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 3 * 1024 * 1024);
    defer runtime.deinit();
    runtime.heap.collection_threshold = 1;
    runtime.heap.threshold_growth_floor = 1;
    try runScript(&runtime,
        \\import os
        \\from pathlib import Path
        \\Path('/home/persist/empty').mkdir(parents=True)
        \\for i in range(200):
        \\    Path('/home/persist') / ('f' + str(i))
        \\Path('/home/persist/data.txt').write_text('雪' * 100)
        \\print(Path('/home/persist/data.txt').is_file(), Path('/home/persist/empty').is_dir())
    , "library-vfs-gc.py", 1);
    try std.testing.expectEqualStrings("True True\n", runtime.stdout());
    try std.testing.expect(runtime.heap.collection_count > 0);
    runtime.reset();
    try runScript(&runtime,
        \\import os
        \\from pathlib import Path
        \\print(len(Path('/home/persist/data.txt').read_text()), os.path.isdir('/home/persist/empty'))
    , "library-vfs-reset.py", 1);
    try std.testing.expectEqualStrings("100 True\n", runtime.stdout());
}

fn runScript(runtime: *vm.Runtime, source: []const u8, filename: []const u8, quantum: u32) !void {
    switch (runtime.compileAndStart(source, filename)) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("vfs syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableVfsLibraryProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("vfs unsupported at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedExecutableVfsLibraryProgram;
        },
        .python_exception => |exception| {
            std.debug.print("vfs compile exception: {s}\n", .{exception.message});
            return error.ExpectedExecutableVfsLibraryProgram;
        },
    }
    var status = runtime.run(quantum);
    for (0..200_000) |_| {
        if (status != .timeslice) break;
        status = runtime.run(quantum);
    }
    if (status != .completed) std.debug.print("vfs library status={s}, error={s}, output={s}\n", .{ @tagName(status), runtime.errorText(), runtime.stdout() });
    try std.testing.expectEqual(vm.RunStatus.completed, status);
}
