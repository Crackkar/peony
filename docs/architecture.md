# Architecture

Peony is a single Zig interpreter compiled to `wasm32-freestanding`. The browser loads it inside a module Worker. The public JavaScript facade sends commands to that Worker; neither the editor nor an embedding page instantiates WASM on the main thread. Node uses the same facade with `worker_threads` for integration tests.

```text
page / host callbacks
   ↕ versioned Worker messages (web/peony.mjs)
Worker (web/peony.worker.mjs)
   ├─ internal JS pump and packet codec (web/peony-core.mjs)
   └─ WASM exports (src/wasm.zig)
       └─ one Runtime per session (src/vm/runtime.zig)
           ├─ frontend: tokenize → parse → resolve scopes → compile
           ├─ register bytecode VM, frames, native continuations
           ├─ values, objects, GC, exceptions
           ├─ Zig native libraries and regex engine
           └─ session VFS and file objects
```

## Compilation and execution

`src/frontend/` owns tokens, indentation and literals, the AST, parser, scope analysis, compiler, and bytecode definition. Scope analysis decides local, cell, free, global, and nonlocal bindings before execution. The compiler emits fixed 64-bit register instructions with source locations, constants, and names into a session-owned code object. The AST and scope analysis use temporary allocation that is released after compilation. Python source is never translated into JavaScript, and the libraries do not inject hidden Python source.

`src/vm/runtime.zig` owns a session and the opcode dispatcher. The other `src/vm/` files divide frame/control transfer, calls, operators, objects, iteration, text, modules, builtins, and native tasks by responsibility. Frames, closures, exception handlers, generators, and pending native operations remain in this one VM. Imports can load learner modules from the VFS or registered Zig modules; registered native names take precedence on a cache miss. Imported modules are cached within a run.

The Worker calls `peony_run` in bounded quanta. A result can mean completion, a Python exception, an expired quantum, a host request, an output flush event, cancellation, or a resource limit. It drains output and returns to the host event loop between quanta. Input, HTTP, clock, and sleep suspend the current operation and resume with a matching response. Native tasks also preserve state while invoking a learner callback or iterator, so a callback can itself request input without replaying earlier effects. There is no Asyncify/JSPI stack capture or second interpreter.

## Values, memory, and failure

`src/runtime/` defines the Value representation, numbers including arbitrary-size integers, strings and bytes, sequences and mappings, functions/classes, exceptions, file objects, and the heap. On wasm32, a Value is an eight-byte tagged word: floats and small integers can be immediate; larger integers and compound objects use heap storage. Booleans are distinct from integers in the value tag even where Python arithmetic treats them numerically. Runtime heap and emitted-code allocations are accounted against `maxMemoryBytes`; short-lived parser/scope/compiler scratch allocation is separate, so this option is not a bound on total WASM linear memory. Heap objects use a nonmoving mark/sweep collector with explicit roots for live VM frames and native tasks. `collectGarbage()` is available while execution is idle. The interpreter does not promise Python finalizers.

Python failures travel through Python exception and traceback machinery; Zig errors are used for engine implementation failures. The compiler reports syntax and unsupported-feature diagnostics with source positions. Unhandled runtime errors expose a message and source frames to the facade. An instruction/native-work limit is a terminal run status, not a catchable Python exception. `cancel()` is a hard stop: it skips Python `finally` and context-manager cleanup.

The default session budgets are 64 MiB of accounted memory, 50 million combined work units, a 50,000-instruction quantum, 8 MiB of VFS file content, and 2 MiB per file. These are configurable through the public session options. The host protocol has a separate 1 MiB packet bound. Native algorithms are required to charge work and check cancellation; some synchronous nested materialization and file-method loops can run until they finish or hit the shared work limit rather than yielding between items.

## Files and browser services

The in-memory VFS has three roots: `/course` for read-only mounted lesson material, `/home` for learner files, and `/tmp` for temporary files. Python `open()`, `pathlib`, and `os` use this VFS, not the host filesystem. Paths are case-sensitive and POSIX-like regardless of the host OS. File content lives in nodes separate from directory entries, so an open handle keeps its content identity across rename or unlink. A new `run()` creates a fresh Python world and clears `/tmp`; `/course` and `/home`, including empty `/home` directories, survive between runs of the same public session. The embedding host can export or restore files through the session API. Peony does not automatically persist them to IndexedDB or a server.

The Zig engine owns Python argument validation, native library behavior, response objects, URL/form and JSON conversion, and virtual file semantics. The host supplies callbacks for output/input and browser services: `fetch`, URL policy, clocks, and sleep. The Worker transports those requests and responses through the versioned [WASM ABI](wasm-abi.md). Browser CORS and TLS rules still apply; the `ssl` teaching object cannot change the browser network stack.

## Code map

| Path | Responsibility |
|---|---|
| `src/frontend/` | Lexing, parsing, scope analysis, compilation, bytecode |
| `src/vm/` | Runtime state, opcode execution, calls, control flow, native tasks |
| `src/runtime/` | Values, heap/GC, collections, exceptions, files, VFS |
| `src/stdlib/` and `src/regex/` | Zig implementations of admitted libraries and regex |
| `src/wasm.zig`, `src/abi.zig` | Exported handles, transfer buffers, statuses, host packets |
| `web/peony.mjs`, `web/peony.worker.mjs`, `web/peony-core.mjs` | Public proxy, Worker owner, internal WASM pump |
| `web/index.html`, `web/showcase.*` | Learner-facing example UI |
| `tests/unit/`, `tests/*.test.mjs`, `tests/showcase-browser.mjs` | Native semantics, WASM/Worker integration, browser flow |

The [language surface](language.md), [library surface](libraries.md), and [embedding API](embedding.md) define what is intentionally exposed. This document describes how those boundaries are implemented.
