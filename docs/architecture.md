# Architecture

Peony is one Zig runtime with two shipping adapters: a native process executable and a `wasm32-freestanding` module hosted by a JavaScript Worker. The shared engine owns Python syntax, values, execution, libraries, and file object semantics. Each adapter owns external storage and services: operating system files and stdio in the native process; JavaScript file storage and browser facilities in the Worker distribution.

```text
                           src/vm/runtime.zig
                     compiler, VM, values, GC,
                native libraries, host tasks, file API
                         /                     \
                        /                       \
             src/native.zig                 src/wasm.zig
             process adapter                versioned raw ABI
          OS files, stdio, clocks, HTTP             |
                    |                         web/peony-core.mjs
             peony executable                packet/event pump
                                                   |
                                 web/fs-host.mjs + peony.worker.mjs
                                            Worker owner
                                                   |
                                           web/peony.mjs
                                            public proxy
```

`src/native.zig` owns CLI parsing, source-file loading, terminal diagnostics, process exit codes, and process host requests. `src/native_fs.zig` connects the file interface to Zig's operating system file APIs. The adapter constructs the shared `Runtime` type and drives `compileAndStartArgs`, `run`, and `resumeHost` directly. The [native CLI reference](native-cli.md) defines its process contract.

`Peony.load(...)` in `web/peony.mjs` always creates a module Worker. The Worker loads `web/peony-core.mjs`, which compiles or instantiates WASM and drives the raw exports. The public facade does not instantiate WASM on the calling thread. Browser and Node integrations use the same facade; Node supplies `worker_threads` in place of a browser Worker. The raw ABI is documented separately because it is a Worker-to-engine contract rather than the recommended application API.

## Runs through either adapter

A native invocation reads one source file and passes the remaining command arguments to `compileAndStartArgs`. The adapter repeatedly calls `run`, drains buffered output to process streams, and services input, HTTP, clock, and sleep packets. File operations use OS paths through `src/native_fs.zig`; imports search the script directory and working directory.

A browser application creates a session, optionally mounts files, and calls `session.run(source, { filename, argv })`. The Worker validates the request and sends source and metadata through transfer blocks to the Zig exports. It may regain control several times before the program finishes. At each return it continues after a quantum, drains output, awaits a host operation, or produces a terminal result. The page receives an eventual `completed`, `error`, `cancelled`, or `limit` result and may already have received output chunks while the program ran.

One loaded WASM instance can hold multiple raw sessions, each identified by a generation-checked handle. Each runtime owns its Python heap, interpreter frames, module cache, streams, limits, and native operation state. `web/fs-host.mjs` owns a file tree for each handle. The public facade replaces a raw runtime between consecutive `run()` calls so Python globals and imports start fresh; the Worker transfers the existing file tree to the new handle without copying its bytes and clears `/tmp`. Public `session.reset()` follows the same file persistence rule. The lower-level `peony_reset` export keeps its current host file tree and clears `/tmp`.

## From text to bytecode

The front end lives in `src/frontend/`. `lexer.zig` validates UTF-8, handles indentation and newline normalization, and produces tokens for literals, names, operators, and delimiters. `parser.zig` builds an AST for admitted Python 3.12 syntax. It recognizes certain unsupported forms far enough to report a targeted diagnostic, such as unsupported async or pattern syntax. `scope.zig` determines local, global, cell, and free-variable bindings, including `global` and `nonlocal`, before code generation. This is essential for closures and Python's rule that an assignment can make a name local throughout a function.

`compiler.zig` emits register bytecode defined in `bytecode.zig`. An instruction is a fixed 64-bit word with an opcode, register operands, and flags. The code object retains instructions, constants, names, and filename/source positions needed for execution and diagnostics. The AST and scope analysis are transient; their temporary allocations are released after compilation. The resulting code is session-owned. Python source is not transpiled to JavaScript or secretly compiled into Python helper modules for the builtins.

Scope resolution also fixes the storage slot for every local, cell, and free variable. Their load and store instructions carry that slot directly, so the dispatcher indexes the frame or closure cell without repeating a name lookup. Names remain in the code object for diagnostics, argument binding, class namespaces, globals, and other operations whose Python semantics are name based.

Global namespaces retain ordered name/value entries because imports, module attributes, deletion, and class fallback remain dynamic. Each code object keeps a small inline cache from its interned names to validated namespace slots. A cache entry is accepted only for the same environment address and structural version; inserting, deleting, or clearing a name advances that version. Existing-name assignments keep the shape stable. Hot global loads and stores therefore become direct indexed access while namespace mutation preserves Python's name-based behavior.

The compiled language includes expressions and control flow, functions and generators, class creation, imports, exceptions, context managers, comprehensions, and the documented `match` forms. The front end reports source diagnostics with filename, line, and column when it encounters a form outside the [language guide](language.md).

## The VM and Python control flow

`src/vm/runtime.zig` contains the stable `Runtime` owner and the central opcode dispatcher. Supporting files under `src/vm/` group control transfer, calls, objects, operators, iteration, text, imports, builtins, and native tasks. `state.zig` defines the execution frame and associated roots, local/cell/free variables, exception blocks, and pending transfers. A function call pushes a frame; a return, jump, or Python exception unwinds through the relevant `try`, `finally`, and `with` state. Generators suspend their own frame and resume through the same VM.

The dispatcher keeps the active frame's register and root slices installed while that frame remains on top. Ordinary instructions advance only the instruction pointer; calls, returns, generator suspension, and unwinding reactivate a different frame when control actually moves. The main run loop and the bounded synchronous callback/generator loops share this rule, avoiding repeated frame-state copies in hot bytecode paths.

Python exceptions are represented as Python values and flow through this control machinery. They are not Zig errors exposed directly to executed code. A handled exception can continue execution; an unhandled exception becomes a terminal run result with traceback frames. A syntax or unsupported-feature diagnostic is generated during compilation and retains source position information. An engine invariant failure has a separate internal status. The Worker facade turns raw statuses and borrowed diagnostic bytes into a stable JavaScript result; the native adapter renders them as terminal diagnostics.

The VM is scheduled cooperatively. A run call executes a requested bytecode quantum plus the same quantum of bounded native work, then can return `TIMESLICE`. One session setting therefore controls preemption for both bytecode and Zig library algorithms. The Worker drains output and yields to its event loop before another ABI call; the native adapter drains output and immediately continues. `print(..., flush=True)` creates an output event so buffered text reaches either host promptly. The budget named `maxInstructions` measures combined bytecode and charged native work across a run. Some nested synchronous operations can continue until completion or the shared work limit without a host yield between individual items; the architecture therefore distinguishes a quantum from a strict wall-clock deadline.

Function frames use bounded per-session storage reuse. A returned ordinary frame is scrubbed of values and roots, then up to 32 small frames can be retained per session and selected by code object for the next call. Reset destroys the cache before compiled code is released, and generator frames are excluded. This removes repeated allocator traffic from hot Python functions without carrying Python objects or execution state across runs. Common small calls assemble positional arguments, keyword arguments, bound parameter values, and their temporary GC roots in fixed stack storage; heap-backed expansion remains available for large signatures, large calls, and `*args`.

## Values, allocation, and collection

`src/runtime/` implements values and core object behavior. On wasm32, `Value` is an eight-byte tagged word. Floats, small integers, `None`, booleans, and some internal sentinels are immediate; larger integers and compound objects have heap storage. The integer implementation promotes beyond the small-int range rather than losing Python integer precision. String data is valid UTF-8; indexing and slicing follow code point boundaries. Collections, functions, classes, modules, exceptions, file objects, and native objects share the same value graph.

Each runtime has a `SessionAllocator` that counts live and peak bytes and applies its configured cap. The heap is a nonmoving mark/sweep collector. VM frames, registers, closures, globals, exceptions, and pending native operations expose explicit roots so collection can happen while a complex operation is in progress. Collection is also exposed as an idle public session method. The session cap covers persistent runtime, emitted-code allocations, and retained frame storage. Parser, scope, and compiler scratch use separate short-lived allocation. Browser file storage has its own total and per-file byte caps in the Worker host.

The runtime has no Python finalizer guarantee. Worker `session.cancel()` is a hard stop and discards execution state without running Python `finally` or context-manager exits. Ordinary Python exceptions do run their documented unwind path. A work limit is another terminal run outcome rather than a catchable Python exception. The native CLI has no asynchronous cancellation command; process termination remains an operating-system action.

## Native libraries and suspended work

The module registry in `src/stdlib/registry.zig` maps admitted import names to Zig implementations in `src/stdlib/`; `src/regex/` supplies the native regex parser and engine. Module and native callable objects enter the same VM value graph as user-defined objects. Native implementations use centralized Python argument binding, exception values, hashing/equality, iterators, and GC ownership. This is why a `Counter` can act as a dictionary subtype or a regex replacement callback can call a Python function: these operations share the runtime protocols instead of bypassing them.

A native call can complete, raise a Python exception, request the next value from an iterator, call a Python function, ask the host for I/O, or yield after charged work. `src/vm/native_tasks.zig` records this state in GC-traced task objects linked to their parent operation. When a callback calls `input()` or another suspending API, the task retains its stage and resumes from the returned value. Completed effects are not replayed. A matching request ID is required to resume a host operation; malformed or stale replies leave the valid pending request intact. Cancellation or reset makes late replies inert.

The host protocol carries input, HTTP, clock, sleep, and explicit output events. It is a binary, versioned packet format with UTF-8 and binary sections. The browser adapter supplies `fetch`, URL policy, timers, and callbacks. The native adapter supplies stdio, Zig clocks and timers, and `std.http.Client`; it bounds response bodies, rejects redirects, and races timeout-bearing requests against a cancellable host timer. Zig engine code owns Python URL/form conversion, JSON, response classes, and exception mapping in both modes. The packet encoding and WASM export rules are in [WASM ABI](wasm-abi.md).

### Native algorithm choices

The library implementations use data structures chosen for the admitted workloads, with their state held inside session-accounted memory. Dictionaries use power-of-two open-addressed tables with perturbation probing; a separate ordered entry array preserves insertion order without allowing sequential hashes and deletion tombstones to form linear probe chains. List and `sorted()` operations evaluate keys once and use a stable bottom-up merge, including across timeslices. `statistics.median` uses the same asymptotic sorting discipline for its numeric working copy.

`re` compiles its supported grammar to an ordered Pike-style VM; frontier threads preserve leftmost-first and greedy/lazy priority while generation marks avoid repeatedly adding the same state. Its Unicode subject representation keeps code-point-to-byte offsets so scanning does not rescan UTF-8 prefixes for each match position. A Python-visible `Match` snapshots the byte offsets of its captures while that decoded subject is available, making later `group()` and item access constant time even for matches near the end of a long Unicode string. `json` uses a native event cursor that constructs Peony values directly and can resume long decode/encode work without materializing a second generic object graph. A single JSON string token has its own size bound. For `random.sample`, the uncounted case uses a sparse partial shuffle map; the counted case uses a Fenwick tree for selection and updates. These are concrete Zig engine choices, not separate implementations in Python or JavaScript. They still pass through shared work accounting, cancellation, and Python error rules.

## Host files and imports

`src/runtime/file.zig` implements Python text and binary file behavior: modes, cursors, newline handling, positions, and context management. `src/runtime/vfs.zig` exposes storage operations to that file layer, imports, `pathlib`, and `os`. The native backend in `src/native_fs.zig` uses OS files and directories. It retains actual file handles and follows operating system path and permission rules.

The browser backend is `web/fs-host.mjs`. It keeps directory entries and file bytes in Worker JavaScript. Synchronous WASM imports let the Zig engine read and mutate that store while executing Python file operations. Browser paths use `/assets`, `/home`, and `/tmp`; `/assets` holds page supplied content, `/home` holds writable session content, and `/tmp` holds scratch content cleared for each run. Open handles retain file node identity across rename and unlink.

Imports first consult the run's module cache and registered Zig libraries. Native user modules are searched beside the entry script and in the working directory. Browser user modules are searched under `/home`, `/assets`, then `/tmp`. Both paths load `.py` modules and packages with `__init__.py`, compile their source in Zig, and execute them through VM frames. A page can copy Worker file bytes into its own persistent storage between visits.

## Source map and verification

| Area | Primary paths | What to inspect |
|---|---|---|
| Front end | `src/frontend/` | Tokens, AST, scope analysis, bytecode, compile diagnostics |
| VM | `src/vm/`, `src/engine.zig` | Frames, dispatcher, control flow, calls, scheduling, native tasks |
| Object substrate | `src/runtime/` | Values, numbers, containers, GC, exceptions, and file semantics |
| Filesystem hosts | `src/native_fs.zig`, `src/wasm_fs.zig`, `web/fs-host.mjs` | OS and Worker file storage |
| Native utilities | `src/stdlib/`, `src/regex/` | Python-visible libraries, binder metadata, algorithms |
| Host protocol | `src/runtime/host.zig`, `src/vm/native_tasks.zig` | Versioned packets and suspended continuations |
| Native adapter | `src/native.zig` | CLI, stdio, native clocks/timers/HTTP, diagnostics and metrics |
| WASM boundary | `src/wasm.zig`, `src/abi.zig` | Export statuses, handles and transfer buffers |
| Worker boundary | `web/peony.mjs`, `web/peony.worker.mjs`, `web/peony-core.mjs` | Worker messages, host callbacks and session lifecycle |
| UI example | `web/index.html`, `web/showcase.*` | Browser editor and result presentation |
| Checks | `tests/unit/`, `tests/*.test.mjs`, `tests/showcase-browser.mjs` | Engine semantics, native CLI, WASM, Worker and browser flows |
| CPython corpus | `compare/` | Paired native CLI and started-interpreter output, latency, and peak RSS measurements |

The [language](language.md), [libraries](libraries.md), [native CLI](native-cli.md), and [browser embedding](embedding.md) pages specify what each layer promises. This page explains the ownership and execution path that make those promises possible.
