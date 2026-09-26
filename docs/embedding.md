# Embedding Peony

`web/peony.mjs` is the public, dependency-free ES module. `Peony.load()` starts a module Worker and asks it to compile and instantiate the WASM. The Worker imports the internal ABI pump. A page never runs the interpreter or instantiates `peony.wasm` on its main thread. Serve the module, Worker, and WASM over HTTP(S); the [showcase](../web/index.html) is a working example.

```js
import { Peony } from './web/peony.mjs';

const peony = await Peony.load(new URL('./zig-out/peony.wasm', import.meta.url));
const session = peony.createSession({
  stdout: text => console.log(text),
  input: async prompt => window.prompt(prompt), // null means EOF
});

try {
  const result = await session.run('name = input("Name: ")\nprint("Hi", name)\n', {
    filename: '/home/lesson.py',
  });
  if (result.status === 'error') console.error(result.error.message, result.frames);
  await session.destroy();
} finally {
  await peony.terminate();
}
```

`Peony.load(source)` accepts a URL string, `URL`, successful `Response`, `ArrayBuffer`, or typed array. URL loading happens inside the Worker; byte and response inputs are copied before transfer. Node integration uses `worker_threads` through the same facade. There is no public same-thread fallback.

## Session lifecycle

`peony.createSession(options)` returns a session immediately; its asynchronous Worker creation is awaited by subsequent calls. A session permits one active `run()` at a time. Each `run(source, { filename, argv })` starts with new Python globals, imported modules, and run-owned state. `/course` and `/home` files persist between runs on the same public session, while `/tmp` is cleared. `filename` defaults to `<string>`; `sys.argv` is `[filename, ...argv]`. `argv` must be an array of strings without NUL, at most 256 entries and 64 KiB encoded.

`run()` resolves to `{ status, error, frames, counters }`. Status is `completed`, `error`, `cancelled`, or `limit`; `error` is null unless status is `error`. Each frame contains `filename`, `name`, `line`, `column`, and `source_line`. Counters contain `instructions` and combined `work`. A limit is a terminal outcome, not a Python exception. A Worker crash rejects pending calls.

`cancel()` sends a hard cancellation request and returns immediately. The active run eventually resolves as `cancelled`; Python `finally`/context-manager exit code is skipped. `reset()` is asynchronous, cancels an active run, and replaces the session state **including its VFS**. `destroy()` is asynchronous and releases the session; it cannot run during an active execution. `peony.terminate()` closes the Worker and rejects outstanding work. Stale host replies cannot resume a new run.

| Session method | Result and role |
|---|---|
| `mount(files, { root = '/course' })` | Copies a path-to-string/bytes mapping into read-only `/course`; relative keys are below `root`. |
| `readFile(path)` / `writeFile(path, content)` | Read a copied `Uint8Array`, or write string/bytes to `/home` or `/tmp`. |
| `listFiles(path = '/')` / `listDirectories(path = '/')` | Return sorted full descendant paths. |
| `vfsMkdir(path)` | Create a writable directory and missing parents. |
| `stats()` | Return instruction/work, live/peak session bytes, GC object/collection, and VFS byte counters. |
| `collectGarbage()` | Collect while idle and return updated stats. |

All methods in the table are asynchronous Worker calls. File operations copy data across the boundary; callers never receive a raw WASM pointer. The VFS is memory-resident. A site that needs durable files should use these methods to save and restore content in its own storage.

## Options and host services

| Option | Default | Meaning |
|---|---:|---|
| `maxMemoryBytes` | 64 MiB | Session-accounted allocation cap. |
| `maxInstructions` | 50,000,000 | Combined bytecode/native-work budget per run; exact positive integer or bigint. |
| `quantum` | 50,000 | Bytecode scheduling quantum. |
| `maxVfsBytes` / `maxFileBytes` | 8 MiB / 2 MiB | Total and single-file VFS content caps. |
| `seed` | empty | Optional copied string or bytes for per-session hash seeding; this is not a cryptographic random source. |
| `stdout(text)` / `stderr(text)` | no callback | Output chunks, called on the host side. `print(..., flush=True)` creates a drain boundary. |
| `input(prompt)` | no callback | Synchronous-looking Python input backed by a host callback; return a string or `null` for EOF. |
| `fetch`, `allowUrl(url)` | host `fetch`, allow | Browser HTTP transport and optional URL admission policy. |
| `maxHttpResponseBytes` | packet budget minus 16 KiB | Streaming response-body cap, at most 1 MiB. |
| `followRedirects` | `false` | Explicitly allow browser redirect following. |
| `wallClock()`, `monotonicClock()`, `sleep(seconds, signal)` | host clock/timer | Injectable services for `time`. |

Browser HTTP is limited to HTTP(S), sends `credentials: 'omit'`, and rejects redirects by default. Response bodies are capped while being read; timeout and cancellation abort transport. Browser CORS and TLS rules still apply. Even with `followRedirects`, a policy callback cannot inspect browser-hidden cross-origin redirect hops. The host callbacks are invoked through versioned Worker messages; they are never serialized into WASM memory as JavaScript functions.

For the raw export and packet contract, see [WASM ABI](wasm-abi.md). For Python-visible capabilities, see [language](language.md) and [libraries](libraries.md).
