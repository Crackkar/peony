# Architecture

Peony consists of a Zig interpreter compiled to `wasm32-freestanding`, a small JavaScript Worker adapter, and an embedding page. The interpreter owns Python syntax, values, execution, libraries, and virtual files. The page owns presentation and the browser facilities that WebAssembly cannot provide by itself. This separation is visible in the public API: an application sends source to a session and receives output, requests for host services, and a structured run result. It never needs to reach into WASM memory.

```text
embedding page / showcase
    editor, output, input UI, browser fetch, timers
                |
                | versioned session and host messages
                v
web/peony.mjs ---------- web/peony.worker.mjs
public proxy               Worker owner
                                |
                                v
                         web/peony-core.mjs
                         WASM pump and packet codec
                                |
                                v
                         src/wasm.zig exports
                                |
                                v
                    one src/vm/runtime.zig Runtime
                    for each raw session handle
                       /       |        \
                 frontend    values/GC   native libraries/VFS
```

`Peony.load(...)` in `web/peony.mjs` always creates a module Worker. The Worker loads `web/peony-core.mjs`, which compiles/instantiates WASM and drives the raw exports. The public facade does not instantiate WASM on the calling thread. Browser and Node integrations use the same facade; Node supplies `worker_threads` in place of a browser Worker. The raw ABI is documented separately because it is a Worker-to-engine contract, not the recommended application API.

## A run, end to end

An embedding page creates a session, optionally mounts lesson files, and calls `session.run(source, { filename, argv })`. The Worker validates the request and sends source and metadata through transfer blocks to the Zig exports. The interpreter compiles the source, creates a fresh Python execution world, and runs bytecode. It may return to the Worker several times before the program is finished. At each return, the Worker handles the status: continue after a quantum, drain output, await a host operation, or produce a terminal result. The page receives an eventual `completed`, `error`, `cancelled`, or `limit` result and may already have received output chunks while the program ran.

One loaded WASM instance can hold multiple raw sessions, each identified by a generation-checked handle. Each runtime owns its Python heap, interpreter frames, module cache, streams, limits, native operation state, and VFS. The public facade replaces a raw runtime between consecutive `run()` calls so Python globals and imports start fresh; it snapshots and restores `/course` and `/home` files and empty `/home` directories. Calling public `session.reset()` instead discards that persistent state. The distinction between public session behavior and the lower-level `peony_reset` export is explicit in the [ABI reference](wasm-abi.md).

## From text to bytecode

The front end lives in `src/frontend/`. `lexer.zig` validates UTF-8, handles indentation and newline normalization, and produces tokens for literals, names, operators, and delimiters. `parser.zig` builds an AST for admitted Python 3.12 syntax. It recognizes certain unsupported forms far enough to report a targeted diagnostic, such as unsupported async or pattern syntax. `scope.zig` determines local, global, cell, and free-variable bindings, including `global` and `nonlocal`, before code generation. This is essential for closures and Python's rule that an assignment can make a name local throughout a function.

`compiler.zig` emits register bytecode defined in `bytecode.zig`. An instruction is a fixed 64-bit word with an opcode, register operands, and flags. The code object retains instructions, constants, names, and filename/source positions needed for execution and diagnostics. The AST and scope analysis are transient; their temporary allocations are released after compilation. The resulting code is session-owned. Python source is not transpiled to JavaScript or secretly compiled into Python helper modules for the builtins.

Scope resolution also fixes the storage slot for every local, cell, and free variable. Their load and store instructions carry that slot directly, so the dispatcher indexes the frame or closure cell without repeating a name lookup. Names remain in the code object for diagnostics, argument binding, class namespaces, globals, and other operations whose Python semantics are name based.

The compiled language includes ordinary expressions and control flow, functions and generators, class creation, imports, exceptions, context managers, comprehensions, and the documented `match` subset. The front end is a subset compiler: syntax outside the [language surface](language.md) is rejected rather than passed through to an unavailable CPython runtime.

## The VM and Python control flow

`src/vm/runtime.zig` contains the stable `Runtime` owner and the central opcode dispatcher. Supporting files under `src/vm/` group control transfer, calls, objects, operators, iteration, text, imports, builtins, and native tasks. `state.zig` defines the execution frame and associated roots, local/cell/free variables, exception blocks, and pending transfers. A function call pushes a frame; a return, jump, or Python exception unwinds through the relevant `try`, `finally`, and `with` state. Generators suspend their own frame and resume through the same VM.

Python exceptions are represented as Python values and flow through this control machinery. They are not Zig errors exposed directly to learner code. A handled exception can continue execution; an unhandled exception becomes a terminal run result with traceback frames. A syntax or unsupported-feature diagnostic is generated during compilation and retains source position information. An engine invariant failure has a separate internal status. The public facade turns these raw statuses and borrowed diagnostic bytes into a stable JavaScript result.

The VM is scheduled cooperatively. A call to `peony_run` executes a requested bytecode quantum plus the same quantum of bounded native work, then can return `TIMESLICE`. One session setting therefore controls preemption for both bytecode and Zig library algorithms. The Worker drains output and yields to its event loop before another run call. `print(..., flush=True)` creates an output event so buffered text is delivered promptly without a JavaScript import call for every small write. The budget named `maxInstructions` measures combined bytecode and charged native work across a run. Some nested synchronous operations can continue until completion or the shared work limit without a host yield between individual items; the architecture therefore distinguishes a quantum from a strict wall-clock deadline.

Function frames use bounded per-session storage reuse. A returned ordinary frame is scrubbed of values and roots, then up to 32 small frames can be retained per session and selected by code object for the next call. Reset destroys the cache before compiled code is released, and generator frames are excluded. This removes repeated allocator traffic from hot learner functions without carrying Python objects or execution state across runs. Common small calls also assemble positional and keyword arguments in fixed stack storage; heap-backed expansion remains available for large calls and `*args`.

## Values, allocation, and collection

`src/runtime/` implements values and core object behavior. On wasm32, `Value` is an eight-byte tagged word. Floats, small integers, `None`, booleans, and some internal sentinels are immediate; larger integers and compound objects have heap storage. The integer implementation promotes beyond the small-int range rather than losing Python integer precision. String data is valid UTF-8; indexing and slicing follow code point boundaries. Collections, functions, classes, modules, exceptions, file objects, and native objects share the same value graph.

Each runtime has a `SessionAllocator` that counts live and peak bytes and rejects growth beyond its configured cap. The heap is a nonmoving mark/sweep collector. VM frames, registers, closures, globals, exceptions, and pending native operations expose explicit roots so collection can happen while a complex operation is in progress. Collection is also exposed as an idle public session method. The session cap covers persistent runtime, emitted-code allocations, and retained frame storage. Parser, scope, and compiler scratch use separate short-lived allocation; `maxMemoryBytes` is therefore not a cap on total WASM linear memory. The host packet limit and VFS file-content limits are additional, distinct bounds.

The runtime has no Python finalizer guarantee. `session.cancel()` is a hard stop and discards execution state without running Python `finally` or context-manager exits. Ordinary Python exceptions do run their documented unwind path. A work limit is another terminal run outcome rather than a catchable Python exception. Those distinctions matter when a lesson deliberately explores exception handling or when an embedding page displays a Stop button.

## Native libraries and suspended work

The module registry in `src/stdlib/registry.zig` maps admitted import names to Zig implementations in `src/stdlib/`; `src/regex/` supplies the native regex parser and engine. Module and native callable objects enter the same VM value graph as learner-defined objects. Native implementations use centralized Python argument binding, exception values, hashing/equality, iterators, and GC ownership. This is why a `Counter` can act as a dictionary subtype or a regex replacement callback can call a Python function: these operations share the interpreter's protocols instead of bypassing them.

A native call can complete, raise a Python exception, request the next value from an iterator, call a learner function, ask the host for I/O, or yield after charged work. `src/vm/native_tasks.zig` records this state in GC-traced task objects linked to their parent operation. When a learner callback calls `input()` or another suspending API, the task retains its stage and resumes from the returned value. Completed effects are not replayed. A matching request ID is required to resume a host operation; malformed or stale replies leave the valid pending request intact. Cancellation/reset makes late replies inert.

The host protocol carries input, HTTP, clock, sleep, and explicit output events. It is a binary, versioned packet format with UTF-8 and binary sections. The browser side supplies `fetch`, URL policy, timers, and callbacks; Zig owns Python URL/form conversion, JSON, response classes, and error mapping. This keeps browser permissions and transport choices outside the VM while keeping Python semantics inside it. The exact packet and export rules are in [WASM ABI](wasm-abi.md).

### Native algorithm choices

The library implementations use data structures chosen for the admitted workloads, with their state held inside session-accounted memory. Dictionaries use power-of-two open-addressed tables with perturbation probing; a separate ordered entry array preserves insertion order without allowing sequential hashes and deletion tombstones to form linear probe chains. List and `sorted()` operations evaluate keys once and use a stable bottom-up merge, including across timeslices. `statistics.median` uses the same asymptotic sorting discipline for its numeric working copy.

`re` compiles its supported grammar to an ordered Pike-style VM; frontier threads preserve leftmost-first and greedy/lazy priority while generation marks avoid repeatedly adding the same state. Its Unicode subject representation keeps code-point-to-byte offsets so scanning does not rescan UTF-8 prefixes for each match position. A Python-visible `Match` snapshots the byte offsets of its captures while that decoded subject is available, making later `group()` and item access constant time even for matches near the end of a long Unicode string. `json` uses a native event cursor that constructs Peony values directly and can resume long decode/encode work without materializing a second generic object graph. A single JSON string token has its own size bound. For `random.sample`, the uncounted case uses a sparse partial shuffle map; the counted case uses a Fenwick tree for selection and updates. These are concrete Zig engine choices, not separate implementations in Python or JavaScript. They still pass through shared work accounting, cancellation, and Python error rules.

## Virtual files and imports

The VFS in `src/runtime/vfs.zig` is a session-owned table of normalized paths, directory entries, and file nodes. It starts with `/course`, `/home`, and `/tmp`. `/course` is read-only mounted lesson content; `/home` is writable; `/tmp` is writable and cleared for a new run. Paths are POSIX-like and case-sensitive on every host. File content has identity independent of its directory entry, so an already-open file remains coherent after rename or unlink. `src/runtime/file.zig` provides text and binary file operations, newline handling, positions, and context-manager behavior to Python `open()` and the native `pathlib`/`os` surfaces.

Imports first consult the run's module cache. The fixed native registry takes precedence over a same-named learner module on a cache miss. Other modules are searched in the VFS, under `/home`, `/course`, then `/tmp`, as `.py` files or packages with `__init__.py`. These `.py` paths refer to learner/course files mounted at runtime; no Python implementation files for Peony's shipped libraries are tracked in the source tree. Import execution uses VM frames and the same exception path as top-level code.

The public API copies mounted and written bytes into the VFS and copies read results back to the caller. A site may persist those bytes in its own storage before closing a page. Peony does not access the host filesystem or automatically use IndexedDB. The public session's file persistence between runs is implemented at the Worker adapter boundary; the raw runtime's VFS and the JavaScript snapshot have distinct lifetimes.

## Source map and verification

| Area | Primary paths | What to inspect |
|---|---|---|
| Front end | `src/frontend/` | Tokens, AST, scope analysis, bytecode, compile diagnostics |
| VM | `src/vm/`, `src/engine.zig` | Frames, dispatcher, control flow, calls, scheduling, native tasks |
| Object substrate | `src/runtime/` | Values, numbers, containers, GC, exceptions, VFS and files |
| Native utilities | `src/stdlib/`, `src/regex/` | Python-visible libraries, binder metadata, algorithms |
| Raw boundary | `src/wasm.zig`, `src/abi.zig`, `src/runtime/host.zig` | Export statuses, handles, transfer buffers, packets |
| Public boundary | `web/peony.mjs`, `web/peony.worker.mjs`, `web/peony-core.mjs` | Worker messages, host callbacks, session lifecycle |
| UI example | `web/index.html`, `web/showcase.*` | Learner-facing editor and result presentation |
| Checks | `tests/unit/`, `tests/*.test.mjs`, `tests/showcase-browser.mjs` | Native semantics, shipping WASM, Worker, browser flows |
| CPython corpus | `compare/` | Exact differential results and paired performance measurements on scalable learner programs |

The [language](language.md), [libraries](libraries.md), and [embedding](embedding.md) pages specify what each layer promises. This page explains the ownership and execution path that make those promises possible.
