# Embedding Peony in a page

`web/peony.mjs` is the public JavaScript API. It is a dependency-free ES module that starts `web/peony.worker.mjs` and keeps the Zig WebAssembly instance inside that Worker. An embedding page supplies source text, lesson files, output/input callbacks, and optional browser services. The page receives structured results and copied file bytes. It never handles raw WASM pointers or performs interpreter work on its main thread.

The Worker and public module are resolved relative to `web/peony.mjs`; the WASM URL is supplied explicitly to `Peony.load(...)`. A static host must serve all three assets over HTTP(S) for browser use. The [showcase](../web/index.html) uses this same public API, so it is an executable example of the integration path. Node tests use the same facade with `worker_threads`.

## A complete small session

```js
import { Peony } from './web/peony.mjs';

const peony = await Peony.load(new URL('./zig-out/peony.wasm', import.meta.url));
const output = [];
const session = peony.createSession({
  stdout: text => output.push(text),
  stderr: text => output.push(text),
  input: async prompt => window.prompt(prompt), // null means EOF
});

try {
  await session.mount({ 'words.txt': 'red blue red\n' });
  const source = [
    'from collections import Counter',
    'with open("/course/words.txt") as file:',
    '    counts = Counter(file.read().split())',
    'print(counts.most_common())',
  ].join('\n');
  const result = await session.run(source, { filename: '/home/lesson.py' });

  if (result.status === 'error') {
    console.error(result.error.message, result.frames);
  } else if (result.status === 'completed') {
    console.log(output.join(''));
  }
  await session.destroy();
} finally {
  await peony.terminate();
}
```

The example intentionally separates output from the terminal run result. `stdout` can be called before `run()` resolves, especially when the program calls `input()` or flushes output. A page can append each chunk to an output panel immediately; the run result tells it whether execution ultimately completed, failed, was stopped, or hit a work limit. `window.prompt` is only an example input UI. A form or modal can return a Promise from the same callback.

## Loading and ownership

`Peony.load(source)` accepts a URL string, a `URL`, a successful `Response`, an `ArrayBuffer`, or a typed array. URL inputs are fetched by the Worker; response and byte inputs are copied before they are passed to the Worker. The call resolves after the Worker has loaded and validated the WASM ABI version. If loading fails, the Worker is terminated and the Promise rejects. There is no public same-thread fallback.

The returned Peony module owns the Worker and can create multiple sessions. `createSession(options)` returns a session immediately; the pending Worker-side creation is awaited by `run()` and other async session calls. Each session has its own raw runtime, limits, VFS, Python state, output, and pending host operations. The raw ABI currently has 64 session slots in one WASM instance; a destroyed handle cannot be reused as a stale valid handle because it carries a generation. Call `session.destroy()` when a session is finished, then `peony.terminate()` when the page no longer needs that loaded engine. Terminating the Worker rejects pending calls and aborts active host operations.

The public proxy uses versioned messages with request, session, and run IDs. It validates that a response matches the call that created it. Host callbacks are invoked on the page side and their resolved values are sent back through messages. A late response from an old run is ignored. Internal raw-WASM tests exercise the binary ABI directly, but embedding pages should use the public facade.

## Run lifecycle and results

`session.run(source, { filename, argv })` accepts source as a JavaScript string and returns a Promise. Only one run may be active per session; an overlapping call rejects. The default filename is `<string>`. `argv` is an optional array of at most 256 strings without NUL, bounded to 64 KiB when encoded. Python sees `sys.argv` as `[filename, ...argv]`. The filename also appears in diagnostics and traceback frames, so a lesson host should pass the path it shows to the learner.

Each public `run()` starts a fresh Python world: globals, imports, function objects, and module cache do not leak from the previous run. Files in `/course` and `/home` do persist between runs of the same public session, including empty `/home` directories; `/tmp` is cleared. The Worker implements this by replacing the raw runtime and restoring persistent VFS data. That snapshot is in memory, not durable storage. `session.reset()` discards Python state **and all VFS files**, while `session.destroy()` releases the session entirely. The raw `peony_reset` export has a different file lifetime; [WASM ABI](wasm-abi.md) documents it for adapter authors.

The resolved result has this shape:

```js
{
  status: 'completed' | 'error' | 'cancelled' | 'limit',
  error: null | { message: string },
  frames: [{ filename, name, line, column, source_line }, ...],
  counters: { instructions: number, work: number },
}
```

For `completed`, `cancelled`, and `limit`, `error` is null and `frames` is empty. For `error`, the message and frames describe an unhandled Python error, a compile diagnostic, or an internal engine failure. A frame's filename and source location let an editor select a relevant line; the host should not parse line numbers out of the message. `instructions` counts bytecode instructions, while `work` includes charged native work. A work limit returns `limit` instead of raising a Python exception. A Worker transport failure rejects the Promise rather than manufacturing a Python run result.

`session.cancel()` is synchronous from the caller's perspective: it sends a cancellation request and returns. The active run later resolves as `cancelled`. This is a hard stop; Python `finally` and context-manager exit code do not execute. Pending fetch or sleep operations receive an abort signal; a pending input result is ignored if it arrives after cancellation. `session.reset()` cancels an active run, waits for it to settle, and establishes a clean session. `destroy()` cannot run while a run is active. These lifecycle rules are useful when a page offers Run, Stop, and Clear controls.

## Files from JavaScript

All file methods below are asynchronous Worker calls. Strings are UTF-8 encoded, byte buffers are copied, and `readFile` returns a copied `Uint8Array`. Mutating the caller's input buffer after a successful mount/write does not mutate the VFS; mutating a returned read buffer does not change the file.

| Call | Effect |
|---|---|
| `mount(files, { root = '/course' })` | Copy a mapping of path to string/bytes into read-only course storage. Relative names are placed below `root`; absolute `/course` names are accepted. |
| `writeFile(path, content)` | Create or replace a writable `/home` or `/tmp` file from string/bytes. |
| `readFile(path)` | Return file bytes as a new `Uint8Array`. |
| `listFiles(path = '/')` | Return sorted full descendant file paths. |
| `listDirectories(path = '/')` | Return sorted full descendant directory paths. |
| `vfsMkdir(path)` | Create a writable directory and missing parents. |

Paths are case-sensitive POSIX-like strings. The VFS rejects traversal above its root and writes to `/course`. The configured total-content and per-file limits apply to mounted and learner-written files. The Python `open()`, `pathlib`, and `os` APIs see the same VFS. A site that wants persistence across visits must read/write the relevant files and store them in its own database or server; Peony does not silently use IndexedDB or the host filesystem.

## Session options

The constructor validates numeric limits rather than coercing arbitrary values. Defaults and roles are:

| Option | Default | Meaning |
|---|---:|---|
| `maxMemoryBytes` | 64 MiB | Accounted session runtime allocation cap; compiler scratch is separate. |
| `maxInstructions` | 50,000,000 | Combined bytecode and charged native-work budget for one run. Accepts an exact positive JS integer or bigint within `u64`. |
| `quantum` | 50,000 | Requested bytecode scheduling quantum. Smaller values yield to Worker tasks more often. |
| `maxVfsBytes` | 8 MiB | Total VFS file content cap. |
| `maxFileBytes` | 2 MiB | Single-file content cap, no greater than `maxVfsBytes`. |
| `seed` | empty | Optional copied string or bytes mixed into the session hash seed; no cryptographic unpredictability guarantee. |
| `maxHttpResponseBytes` | 1 MiB minus 16 KiB | Host response-body cap; the entire binary packet also has a 1 MiB bound. |
| `followRedirects` | `false` | Whether host fetch follows HTTP redirects. |

`maxMemoryBytes`, `quantum`, and VFS byte limits are positive unsigned 32-bit integers. `maxInstructions` must be an exact positive value within unsigned 64-bit range. The hash seed is at most 1,024 encoded bytes. The memory counter measures session allocations, not the total capacity of WebAssembly linear memory. `stats()` returns `{ instructions, work, liveSessionBytes, peakSessionBytes, gcObjects, gcCollections, vfsBytes }`; `collectGarbage()` is allowed only while idle and returns updated stats. These counters can inform an embedding UI, but they are not a wall-clock time guarantee.

## Host callbacks and browser policy

`stdout(text)` and `stderr(text)` receive drained output chunks and may return Promises. `input(prompt)` receives a prompt and may return a string or `null` for EOF; a rejected callback enters Python as a host I/O error. Peony drains the prompt before awaiting input, so the learner sees it first. The optional `wallClock()`, `monotonicClock()`, and `sleep(seconds, signal)` callbacks back the admitted `time` functions. Their defaults use host clocks and timers; injected versions make lessons and tests deterministic. A sleep callback receives an `AbortSignal`.

`fetch` supplies the transport for `urllib.request` and Peony's `requests` teaching API. `allowUrl(url)` can approve or reject a URL before transport. Peony admits HTTP(S) URLs only, sends `credentials: 'omit'`, rejects redirects by default, and reads response bodies under a streaming byte cap. Timeout and cancellation abort fetch and body reading. Browser CORS and TLS policies still apply. If the host allows redirects, its URL callback cannot inspect cross-origin redirect hops hidden by the browser. `ssl.SSLContext` values in learner code cannot replace the browser TLS implementation.

The Python-facing APIs, including URL/form encoding, response objects, JSON decoding, argument errors, and exception classes, are implemented in Zig. Host callbacks cross versioned Worker messages; they are not function objects inside the WASM heap. The detailed native API is in [libraries](libraries.md), and the packet format is in [WASM ABI](wasm-abi.md).
