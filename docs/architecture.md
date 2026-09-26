# Architecture

Peony is one Zig runtime with two shipping adapters: a native process executable and a `wasm32-freestanding` module hosted by a JavaScript Worker. The shared engine owns Python syntax, values, execution, libraries, and virtual files. Each adapter owns access to its environment: stdio and operating-system services in the native process; presentation and browser facilities in the Worker distribution. Neither adapter reimplements Python behavior.

```text
                           src/vm/runtime.zig
                     compiler, VM, values, GC,
                     native libraries, host tasks, VFS
                         /                     \
                        /                       \
             src/native.zig                 src/wasm.zig
             process adapter                versioned raw ABI
          stdio, clocks, sleep, HTTP               |
                    |                         web/peony-core.mjs
             peony executable                packet/event pump
                                                   |
                                       web/peony.worker.mjs
                                            Worker owner
                                                   |
                                           web/peony.mjs
                                            public proxy
```

`src/native.zig` owns CLI parsing, source-file loading, explicit host-to-VFS mounts, terminal diagnostics, process exit codes, and the process implementation of host requests. It constructs the same `Runtime` type used by WASM and drives `compileAndStartArgs`, `run`, and `resumeHost` directly. The [native CLI reference](native-cli.md) defines its external contract.

`Peony.load(...)` in `web/peony.mjs` always creates a module Worker. The Worker loads `web/peony-core.mjs`, which compiles or instantiates WASM and drives the raw exports. The public facade does not instantiate WASM on the calling thread. Browser and Node integrations use the same facade; Node supplies `worker_threads` in place of a browser Worker. The raw ABI is documented separately because it is a Worker-to-engine contract rather than the recommended application API.

## Runs through either adapter

A native invocation reads one source file, installs requested VFS mounts, and passes the remaining command arguments to `compileAndStartArgs`. The adapter repeatedly calls `run`, drains buffered output to process streams, and services input, HTTP, clock, and sleep packets. It turns terminal statuses into process exit codes and source-located diagnostics. Runtime setup, source-file I/O, mounts, and optional metrics-file I/O occur outside the measured compile-and-execute interval reported by the CLI.

A browser application creates a session, optionally mounts files, and calls `session.run(source, { filename, argv })`. The Worker validates the request and sends source and metadata through transfer blocks to the Zig exports. It may regain control several times before the program finishes. At each return it continues after a quantum, drains output, awaits a host operation, or produces a terminal result. The page receives an eventual `completed`, `error`, `cancelled`, or `limit` result and may already have received output chunks while the program ran.

One loaded WASM instance can hold multiple raw sessions, each identified by a generation-checked handle. Each runtime owns its Python heap, interpreter frames, module cache, streams, limits, native operation state, and VFS. The public facade replaces a raw runtime between consecutive `run()` calls so Python globals and imports start fresh; it snapshots and restores `/course` and `/home` files and empty `/home` directories. Calling public `session.reset()` instead discards that persistent state. The distinction between public session behavior and the lower-level `peony_reset` export is explicit in the [ABI reference](wasm-abi.md).

## From text to bytecode

The front end lives in `src/frontend/`. `lexer.zig` validates UTF-8, handles indentation and newline normalization, and produces tokens for literals, names, operators, and delimiters. `parser.zig` builds an AST for admitted Python 3.12 syntax. It recognizes certain unsupported forms far enough to report a targeted diagnostic, such as unsupported async or pattern syntax. `scope.zig` determines local, global, cell, and free-variable bindings, including `global` and `nonlocal`, before code generation. This is essential for closures and Python's rule that an assignment can make a name local throughout a function.

`compiler.zig` emits register bytecode defined in `bytecode.zig`. An instruction is a fixed 64-bit word with an opcode, register operands, and flags. The code object retains instructions, constants, names, and filename/source positions needed for execution and diagnostics. The AST and scope analysis are transient; their temporary allocations are released after compilation. The resulting code is session-owned. Python source is not transpiled to JavaScript or secretly compiled into Python helper modules for the builtins.

Scope resolution also fixes the storage slot for every local, cell, and free variable. Their load and store instructions carry that slot directly, so the dispatcher indexes the frame or closure cell without repeating a name lookup. Names remain in the code object for diagnostics, argument binding, class namespaces, globals, and other operations whose Python semantics are name based.

Global namespaces retain ordered name/value entries because imports, module attributes, deletion, and class fallback remain dynamic. Each code object keeps a small inline cache from its interned names to validated namespace slots. A cache entry is accepted only for the same environment address and structural version; inserting, deleting, or clearing a name advances that version. Existing-name assignments keep the shape stable. Hot global loads and stores therefore become direct indexed access while namespace mutation preserves Python's name-based behavior.

The compiled language includes ordinary expressions and control flow, functions and generators, class creation, imports, exceptions, context managers, comprehensions, and the documented `match` subset. The front end is a subset compiler: syntax outside the [language surface](language.md) is rejected rather than passed through to an unavailable CPython runtime.

## The VM and Python control flow

`src/vm/runtime.zig` contains the stable `Runtime` owner and the central opcode dispatcher. Supporting files under `src/vm/` group control transfer, calls, objects, operators, iteration, text, imports, builtins, and native tasks. `state.zig` defines the execution frame and associated roots, local/cell/free variables, exception blocks, and pending transfers. A function call pushes a frame; a return, jump, or Python exception unwinds through the relevant `try`, `finally`, and `with` state. Generators suspend their own frame and resume through the same VM.

The dispatcher keeps the active frame's register and root slices installed while that frame remains on top. Ordinary instructions advance only the instruction pointer; calls, returns, generator suspension, and unwinding reactivate a different frame when control actually moves. The main run loop and the bounded synchronous callback/generator loops share this rule, avoiding repeated frame-state copies in hot bytecode paths.

Python exceptions are represented as Python values and flow through this control machinery. They are not Zig errors exposed directly to executed code. A handled exception can continue execution; an unhandled exception becomes a terminal run result with traceback frames. A syntax or unsupported-feature diagnostic is generated during compilation and retains source position information. An engine invariant failure has a separate internal status. The Worker facade turns raw statuses and borrowed diagnostic bytes into a stable JavaScript result; the native adapter renders them as terminal diagnostics.

The VM is scheduled cooperatively. A run call executes a requested bytecode quantum plus the same quantum of bounded native work, then can return `TIMESLICE`. One session setting therefore controls preemption for both bytecode and Zig library algorithms. The Worker drains output and yields to its event loop before another ABI call; the native adapter drains output and immediately continues. `print(..., flush=True)` creates an output event so buffered text reaches either host promptly. The budget named `maxInstructions` measures combined bytecode and charged native work across a run. Some nested synchronous operations can continue until completion or the shared work limit without a host yield between individual items; the architecture therefore distinguishes a quantum from a strict wall-clock deadline.

Function frames use bounded per-session storage reuse. A returned ordinary frame is scrubbed of values and roots, then up to 32 small frames can be retained per session and selected by code object for the next call. Reset destroys the cache before compiled code is released, and generator frames are excluded. This removes repeated allocator traffic from hot Python functions without carrying Python objects or execution state across runs. Common small calls assemble positional arguments, keyword arguments, bound parameter values, and their temporary GC roots in fixed stack storage; heap-backed expansion remains available for large signatures, large calls, and `*args`.

## Values, allocation, and collection

`src/runtime/` implements values and core object behavior. On wasm32, `Value` is an eight-byte tagged word. Floats, small integers, `None`, booleans, and some internal sentinels are immediate; larger integers and compound objects have heap storage. The integer implementation promotes beyond the small-int range rather than losing Python integer precision. String data is valid UTF-8; indexing and slicing follow code point boundaries. Collections, functions, classes, modules, exceptions, file objects, and native objects share the same value graph.

Each runtime has a `SessionAllocator` that counts live and peak bytes and rejects growth beyond its configured cap. The heap is a nonmoving mark/sweep collector. VM frames, registers, closures, globals, exceptions, and pending native operations expose explicit roots so collection can happen while a complex operation is in progress. Collection is also exposed as an idle public session method. The session cap covers persistent runtime, emitted-code allocations, and retained frame storage. Parser, scope, and compiler scratch use separate short-lived allocation; `maxMemoryBytes` is therefore not a cap on total WASM linear memory. The host packet limit and VFS file-content limits are additional, distinct bounds.

The runtime has no Python finalizer guarantee. Worker `session.cancel()` is a hard stop and discards execution state without running Python `finally` or context-manager exits. Ordinary Python exceptions do run their documented unwind path. A work limit is another terminal run outcome rather than a catchable Python exception. The native CLI has no asynchronous cancellation command; process termination remains an operating-system action.

## Native libraries and suspended work

The module registry in `src/stdlib/registry.zig` maps admitted import names to Zig implementations in `src/stdlib/`; `src/regex/` supplies the native regex parser and engine. Module and native callable objects enter the same VM value graph as user-defined objects. Native implementations use centralized Python argument binding, exception values, hashing/equality, iterators, and GC ownership. This is why a `Counter` can act as a dictionary subtype or a regex replacement callback can call a Python function: these operations share the runtime protocols instead of bypassing them.

A native call can complete, raise a Python exception, request the next value from an iterator, call a Python function, ask the host for I/O, or yield after charged work. `src/vm/native_tasks.zig` records this state in GC-traced task objects linked to their parent operation. When a callback calls `input()` or another suspending API, the task retains its stage and resumes from the returned value. Completed effects are not replayed. A matching request ID is required to resume a host operation; malformed or stale replies leave the valid pending request intact. Cancellation or reset makes late replies inert.

The host protocol carries input, HTTP, clock, sleep, and explicit output events. It is a binary, versioned packet format with UTF-8 and binary sections. The browser adapter supplies `fetch`, URL policy, timers, and callbacks. The native adapter supplies stdio, Zig clocks and timers, and `std.http.Client`; it bounds response bodies, rejects redirects, and races timeout-bearing requests against a cancellable host timer. Zig engine code owns Python URL/form conversion, JSON, response classes, and exception mapping in both modes. The packet encoding and WASM export rules are in [WASM ABI](wasm-abi.md).

### Native algorithm choices

The library implementations use data structures chosen for the admitted workloads, with their state held inside session-accounted memory. Dictionaries use power-of-two open-addressed tables with perturbation probing; a separate ordered entry array preserves insertion order without allowing sequential hashes and deletion tombstones to form linear probe chains. List and `sorted()` operations evaluate keys once and use a stable bottom-up merge, including across timeslices. `statistics.median` uses the same asymptotic sorting discipline for its numeric working copy.

`re` compiles its supported grammar to an ordered Pike-style VM; frontier threads preserve leftmost-first and greedy/lazy priority while generation marks avoid repeatedly adding the same state. Its Unicode subject representation keeps code-point-to-byte offsets so scanning does not rescan UTF-8 prefixes for each match position. A Python-visible `Match` snapshots the byte offsets of its captures while that decoded subject is available, making later `group()` and item access constant time even for matches near the end of a long Unicode string. `json` uses a native event cursor that constructs Peony values directly and can resume long decode/encode work without materializing a second generic object graph. A single JSON string token has its own size bound. For `random.sample`, the uncounted case uses a sparse partial shuffle map; the counted case uses a Fenwick tree for selection and updates. These are concrete Zig engine choices, not separate implementations in Python or JavaScript. They still pass through shared work accounting, cancellation, and Python error rules.

## Virtual files and imports

The VFS in `src/runtime/vfs.zig` is a session-owned table of normalized paths, directory entries, and file nodes. It starts with `/course`, `/home`, and `/tmp`. `/course` is read-only host content; `/home` is writable; `/tmp` is writable and cleared for a new run. Paths are POSIX-like and case-sensitive on every host. File content has identity independent of its directory entry, so an already-open file remains coherent after rename or unlink. `src/runtime/file.zig` provides text and binary file operations, newline handling, positions, and context-manager behavior to Python `open()` and the native `pathlib`/`os` surfaces.

Imports first consult the run's module cache. The fixed native registry takes precedence over a same-named user module on a cache miss. Other modules are searched in the VFS, under `/home`, `/course`, then `/tmp`, as `.py` files or packages with `__init__.py`. These `.py` paths are program inputs mounted at runtime; no Python implementation files for Peony's shipped libraries are tracked in the source tree. Import execution uses VM frames and the same exception path as top-level code.

The browser API copies mounted and written bytes into the VFS and copies read results back to the caller. A site may persist those bytes in its own storage before closing a page. Peony does not automatically use IndexedDB. The public session's file persistence between runs is implemented at the Worker adapter boundary; the raw runtime's VFS and the JavaScript snapshot have distinct lifetimes. The native CLI reads only its script and explicit `--mount` sources from the host filesystem, copies mounts before execution, and does not write VFS mutations back to host paths.

## Source map and verification

| Area | Primary paths | What to inspect |
|---|---|---|
| Front end | `src/frontend/` | Tokens, AST, scope analysis, bytecode, compile diagnostics |
| VM | `src/vm/`, `src/engine.zig` | Frames, dispatcher, control flow, calls, scheduling, native tasks |
| Object substrate | `src/runtime/` | Values, numbers, containers, GC, exceptions, VFS and files |
| Native utilities | `src/stdlib/`, `src/regex/` | Python-visible libraries, binder metadata, algorithms |
| Host protocol | `src/runtime/host.zig`, `src/vm/native_tasks.zig` | Versioned packets and suspended continuations |
| Native adapter | `src/native.zig` | CLI, stdio, native clocks/timers/HTTP, diagnostics and metrics |
| WASM boundary | `src/wasm.zig`, `src/abi.zig` | Export statuses, handles and transfer buffers |
| Worker boundary | `web/peony.mjs`, `web/peony.worker.mjs`, `web/peony-core.mjs` | Worker messages, host callbacks and session lifecycle |
| UI example | `web/index.html`, `web/showcase.*` | Browser editor and result presentation |
| Checks | `tests/unit/`, `tests/*.test.mjs`, `tests/showcase-browser.mjs` | Engine semantics, native CLI, WASM, Worker and browser flows |
| CPython corpus | `compare/` | Three-engine exact differential and performance measurements |

The [language](language.md), [libraries](libraries.md), [native CLI](native-cli.md), and [browser embedding](embedding.md) pages specify what each layer promises. This page explains the ownership and execution path that make those promises possible.
