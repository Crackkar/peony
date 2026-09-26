# Embedding Peony in a page

`web/peony.mjs` is the public JavaScript API. It is an ES module that starts `web/peony.worker.mjs` and keeps the Zig WebAssembly instance inside that Worker. An embedding page supplies source text, files, output/input callbacks, and browser services. The page receives structured results and copied file bytes. Worker JavaScript owns the browser file tree in `web/fs-host.mjs`; the Zig engine calls it through synchronous WASM imports.

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
    'with open("/assets/words.txt") as file:',
    '    counts = Counter(file.read().split())',
    'print(counts.most_common())',
  ].join('\n');
  const result = await session.run(source, { filename: '/home/app.py' });

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

The returned Peony module owns the Worker and can create multiple sessions. `createSession(options)` returns a session immediately; Worker-side creation completes before its first async call. Each session has its own raw runtime, limits, Worker file tree, Python state, output, and pending host operations. The raw ABI has 64 session slots in one WASM instance, each protected by a generation number. Call `session.destroy()` when a session is finished, then `peony.terminate()` when the page finishes with the loaded engine.

The public proxy uses versioned messages with request, session, and run IDs. It validates that a response matches the call that created it. Host callbacks are invoked on the page side and their resolved values are sent back through messages. A late response from an old run is ignored. Internal raw-WASM tests exercise the binary ABI directly, but embedding pages should use the public facade.

## Run lifecycle and results

`session.run(source, { filename, argv })` accepts source as a JavaScript string and returns a Promise. Only one run may be active per session; an overlapping call rejects. The default filename is `<string>`. `argv` is an optional array of at most 256 strings without NUL, bounded to 64 KiB when encoded. Python sees `sys.argv` as `[filename, ...argv]`. The filename also appears in diagnostics and traceback frames, so a host should pass the path shown to the user.

Each public `run()` starts fresh Python globals, imports, function objects, and module cache. Files in `/assets` and `/home` persist between runs of the same public session, including empty `/home` directories; `/tmp` starts fresh. The Worker replaces the raw runtime and transfers its JavaScript file tree to the new handle without copying file bytes. `session.reset()` refreshes Python state and preserves `/assets` and `/home` files. `session.destroy()` releases the session and its files. The [WASM ABI](wasm-abi.md) documents raw session operations for adapter authors.

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

All file methods below are asynchronous Worker calls. Strings are UTF-8 encoded, byte buffers are copied into Worker JavaScript, and `readFile` returns a copied `Uint8Array`. The Worker store owns its bytes across program runs.

| Call | Effect |
|---|---|
| `mount(files, { root = '/assets' })` | Copy a mapping of path to string/bytes into `/assets`. Relative names are placed below `root`; absolute `/assets` names are accepted. |
| `writeFile(path, content)` | Create or replace a writable `/home` or `/tmp` file from string/bytes. |
| `readFile(path)` | Return file bytes as a new `Uint8Array`. |
| `listFiles(path = '/')` | Return sorted full descendant file paths. |
| `listDirectories(path = '/')` | Return sorted full descendant directory paths. |
| `vfsMkdir(path)` | Create a writable directory and missing parents. |

Paths are case-sensitive POSIX-style strings. Relative paths start at `/home`; `/assets` holds page supplied files; `/home` and `/tmp` accept Python writes. The configured total and per-file byte caps apply to Worker storage. Python `open()`, `pathlib`, imports, and `os` see the same file tree. A page can copy selected files into its own database or server for persistence across visits.

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

`maxMemoryBytes`, `quantum`, and VFS byte limits are positive unsigned 32-bit integers. `maxInstructions` must be an exact positive value within unsigned 64-bit range. The hash seed is at most 1,024 encoded bytes. The memory counter measures session allocations, not the total capacity of WebAssembly linear memory. `stats()` returns `{ instructions, work, liveSessionBytes, peakSessionBytes, gcObjects, gcCollections, vfsBytes }`; `collectGarbage()` is allowed only while idle and returns updated stats. These counters can inform an embedding UI, but they are not a wall-clock time guarantee.

## Host callbacks and browser policy

`stdout(text)` and `stderr(text)` receive drained output chunks and may return Promises. `input(prompt)` receives a prompt and may return a string or `null` for EOF; a rejected callback enters Python as a host I/O error. Peony drains the prompt before awaiting input, so it is visible first. The optional `wallClock()`, `monotonicClock()`, and `sleep(seconds, signal)` callbacks back the admitted `time` functions. Their defaults use host clocks and timers; injected versions make applications and tests deterministic. A sleep callback receives an `AbortSignal`.

`fetch` supplies the transport for `urllib.request` and `requests`. `allowUrl(url)` decides whether a request begins. Peony sends `credentials: 'omit'` and `redirect: 'error'`, and reads response bodies under a streaming byte cap. Timeouts and cancellation stop URL approval, fetch, and body reading. The browser applies CORS and certificate validation.

The Python-facing APIs, including URL/form encoding, response objects, JSON decoding, argument errors, and exception classes, are implemented in Zig. Host callbacks cross versioned Worker messages; they are not function objects inside the WASM heap. The detailed native API is in [libraries](libraries.md), and the packet format is in [WASM ABI](wasm-abi.md).
