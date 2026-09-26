# Peony

Peony is a lean Python subset runtime written in Zig. It accepts Python 3.12 syntax, compiles it to Peony bytecode, and executes it in a purpose-built virtual machine. The same engine ships as a native command-line executable and as a WebAssembly module that always runs in a Web Worker.

The project takes a deliberately smaller surface seriously. Peony does not bundle CPython, translate Python into JavaScript, or fill missing behavior with Python implementation files. The parser, scope analysis, bytecode compiler, object model, garbage collector, virtual filesystem, regular-expression engine, and importable libraries are Zig code. A feature is either part of the documented contract and implemented by the runtime, or it is rejected clearly.

This makes Peony useful where a compact, controlled Python environment matters: browser applications, sandboxes, local tools, reproducible program runners, and systems that want Python-shaped code without carrying a general CPython installation. It has the shape of an early standalone runtime rather than a Python distribution. Native and browser execution are equal products around one engine.

## What runs

The following program uses ordinary Python syntax and a familiar library object:

```python
from collections import Counter

words = "red blue red green red blue".split()
for word, count in Counter(words).most_common(2):
    print(f"{word}: {count}")
```

It prints `red: 3` and `blue: 2`. The string operations, list, loop, tuple unpacking, f-string, `Counter`, and `print()` all execute inside Peony. `Counter` is a Zig implementation exposed through normal Python import, call, hashing, iteration, and object protocols. There is no hidden `collections.py`, and the program does not cross into JavaScript for each item when running in a browser.

Peony supports expressions, assignment, conditions, loops, functions, closures, generators, comprehensions, classes, exceptions, context managers, imports, formatted strings, structural matching within a defined subset, and the core Python collection types. Its native library set covers numeric work (`math`, `random`, `statistics`), data (`json`, `csv`), text patterns (`re`), virtual files (`pathlib`, `os.path`), containers (`collections`, `copy`), time, HTTP, and runtime metadata.

Compatibility is explicit. Source is UTF-8 and identifiers are currently ASCII. Async syntax, `yield from`, exception groups, complex numbers, dynamic `eval` and `exec`, custom metaclasses, unrestricted structural patterns, and unlisted library APIs are outside v0.1. Supported behavior aims to follow Python 3.12 where the distinction is observable: lexical scope, argument binding, ordered dictionaries, numeric key equality, iteration, exception unwinding, and `finally` are runtime semantics rather than approximations. The complete boundary lives in the [language contract](docs/language.md) and [library contract](docs/libraries.md).

## Two hosts, one runtime

Peony has one compiler, VM, object model, and library implementation. Host adapters provide process or browser facilities around it.

```text
                         Python source
                               |
                 lexer -> parser -> scope analysis
                               |
                      register bytecode
                               |
                 VM + values + GC + libraries + VFS
                         /                 \
                native adapter          WASM ABI
                stdio, clocks,          Worker pump
                timers, HTTP            browser services
                     |                       |
               peony executable       web/peony.mjs
```

The native executable reads a script from the host filesystem, passes its remaining arguments through `sys.argv`, and connects Peony streams and host requests to operating-system services through Zig's cross-platform standard library. A normal invocation is:

```text
peony program.py first-argument "two words"
```

Program output goes to process stdout and stderr. `input()` reads UTF-8 lines from stdin. `time` uses the host wall and monotonic clocks, and `sleep` uses the host timer rather than busy-waiting. HTTP(S) requests use Zig's native HTTP/TLS stack, enforce the Peony response limit and requested timeout, and reject redirects. Unhandled Python exceptions produce source-located terminal tracebacks and exit code 1; host, limit, and internal failures use exit code 2.

The runtime never grants Python code ambient filesystem access. The source file is read by the CLI, while files and importable Python modules used by the program remain in Peony's VFS. `--mount HOST_PATH VFS_PATH` copies a selected host file into `/home` or read-only `/course` before execution. Repeating the option assembles a complete isolated program environment without making every file on the machine visible. The [native CLI reference](docs/native-cli.md) specifies options, mounts, limits, metrics, host behavior, and exit statuses.

The browser distribution exposes a dependency-free JavaScript session API. `Peony.load(...)` creates a module Worker, and the Worker alone instantiates `peony.wasm`. Parsing, compilation, bytecode dispatch, native libraries, and garbage collection never fall back to the page's main thread. The page receives structured results and output callbacks while it remains responsive enough to render, accept input, or request a hard stop. The [browser embedding guide](docs/embedding.md) defines this API.

The [showcase](web/index.html) is a compact demonstration of the Worker distribution: editor, examples, input, output, cancellation, and source-located errors. It uses the public facade and has no private execution path.

## From source to a terminal result

The front end first tokenizes indentation, literals, operators, delimiters, and names. The parser constructs an AST for admitted Python syntax, and scope analysis fixes local, global, cell, and free-variable bindings before code generation. The compiler then emits fixed-width, register-oriented instructions together with constants, names, and source positions.

The VM executes that code with frames for functions, generators, exception handlers, and suspended native operations. Direct slots serve locals and closure cells. Dynamic global namespaces retain ordered entries and validated per-code-object slot caches. Python exceptions are Python values that unwind through `except`, `finally`, and `with`; compilation diagnostics and engine invariant failures stay distinct from them.

```text
source bytes
    -> tokens and AST
    -> scope graph and bytecode
    -> frames, Python values, native tasks, VFS
    -> completion, Python exception, cancellation, or work limit
```

Each run owns a session allocator and a nonmoving mark/sweep heap. Frames, globals, closures, exceptions, and native continuations publish explicit roots, allowing collection during operations that call back into Python or suspend for host work. Memory, virtual file content, host packet size, and combined bytecode/native work have separate bounds. The native executable and WASM adapter configure the same runtime limits rather than maintaining parallel policies.

On wasm32, a Python value fits in an eight-byte tagged word. Floats, small integers, booleans, `None`, and internal sentinels can be immediate; big integers and compound objects use heap storage. The native target chooses the appropriate representation for its pointer width through the same Zig types. These details stay behind Python-visible protocols.

## Host requests and scheduling

Python-facing functions sometimes need facilities outside the VM. `input()` needs a line source, `time.time()` needs a clock, `time.sleep()` needs a timer, and `requests.get()` needs a transport. Peony represents those operations as versioned host packets. The program suspends at a precise continuation, the adapter performs the operation, and a reply with the matching kind and request ID resumes it. Argument handling, URL and form encoding, response objects, JSON decoding, exception mapping, and callbacks remain engine work.

The Worker adapter maps packets to page callbacks, browser timers, and `fetch`. The native adapter maps the same packet semantics to stdio, Zig clocks, sleep, and the native HTTP client. This boundary allows each deployment to apply its real security model. Browser HTTP remains subject to CORS and browser TLS. Native HTTP uses the operating system network path and system trust roots. The small Python-visible `ssl` compatibility object validates supported call shapes but does not replace either host's TLS implementation.

Execution is cooperative. The VM runs a bounded bytecode quantum, charges native algorithms for proportional work, and can return control between quanta. In a Worker this creates event-loop yield points and makes cancellation observable without putting execution on the main thread. In the native CLI the adapter immediately continues ordinary timeslices, while the shared work ceiling still bounds a run. Hard cancellation is an embedding control result and intentionally skips Python `finally`; an ordinary Python exception follows normal unwinding.

## A virtual filesystem everywhere

Peony gives programs the same POSIX-like virtual paths on every host:

| Root | Role |
|---|---|
| `/course` | Read-only content supplied by the host. |
| `/home` | Writable persistent content for a browser session, or writable mounted content for one native process. |
| `/tmp` | Writable scratch content cleared when a new run begins. |

Python `open()`, file iteration, `csv`, `pathlib`, `os.path`, package imports, and user module imports share this VFS. Paths are case-sensitive and cannot traverse into the host filesystem. File nodes retain identity across rename and unlink while a handle remains open. Imports search `/home`, `/course`, then `/tmp`, with registered Zig modules taking precedence on a cache miss.

In the browser API, `/course` and `/home` survive consecutive runs in the same public session; the page can copy bytes in or out if it wants durable storage. In the native CLI, explicit mounts initialize a single process-local VFS and changes are discarded when the process exits. This keeps execution reproducible and makes host filesystem authority visible in the command line.

## Native Zig libraries

Importable utilities are compiled into both shipping artifacts. They create ordinary Peony modules, functions, classes, iterators, exceptions, and collection values and participate in the same GC, argument binder, work budget, and exception path as user code.

Several subsystems are independent native engines rather than wrappers. `re` parses its admitted pattern grammar and executes an ordered Pike-style VM. `json` decodes directly into Peony values and preserves arbitrary integer tokens. Dictionaries use ordered entries and open-addressed perturbation probing. Sorting is stable and evaluates keys once. Random sampling uses bounded native algorithms rather than materializing huge ranges. These choices let Peony use Zig directly while preserving the documented Python interface.

Familiar module names still describe a bounded contract. Peony's `requests` surface has `get`, `post`, response objects, and its documented exceptions; it does not imply the full third-party package. `collections` supplies `Counter` and `defaultdict`, not every CPython container. Unknown options fail clearly instead of being silently ignored.

## Verification across CPython, WASM, and native

The [`compare/`](compare/) corpus is one maintained set of 46 scalable Python programs covering core semantics, native libraries, virtual files and imports, and composed workloads. Every repetition runs identical source, arguments, and fixtures on CPython 3.12, Peony WASM through the public Worker facade, and the Peony native executable. A measurement is accepted only after stdout and stderr agree byte for byte across all three runtimes.

The durable [comparison report](compare/report.md) records artifact hashes, platform identity, compile-plus-execution medians and p95 values, target-specific ratios, instruction/work counters, and peak session memory. Smoke, standard, and stress profiles change scale and repetition count without splitting correctness from performance. This gives native and browser work one conformance baseline while still showing the cost of each real deployment path.

The [architecture guide](docs/architecture.md) maps the source tree and internal ownership. [Development and verification](docs/development.md) records native, WASM, Worker, browser, cross-target, Unicode, and comparison checks. The [WASM ABI](docs/wasm-abi.md) specifies the lower-level Worker-to-engine contract.

Peony is licensed under the [GNU Affero General Public License v3](LICENSE). We are not currently seeking contributions.
