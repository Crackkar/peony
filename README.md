# Peony

Peony is a lean Python runtime written in Zig. It accepts Python 3.12 syntax, compiles it to Peony bytecode, and executes it in a purpose-built virtual machine. The same engine ships as a native command-line executable and as a WebAssembly module that always runs in a Web Worker.

The parser, scope analysis, bytecode compiler, object model, garbage collector, file object semantics, regular-expression engine, and importable libraries are Zig code. Native programs use the operating system filesystem through Zig. Browser programs use Worker-owned JavaScript storage through synchronous WASM imports. This keeps Python behavior in one engine while each host owns its own files and external services.

Peony serves browser applications, local tools, program runners, and systems that want Python code in a focused runtime. Native and browser execution are equal products around one engine.

## What runs

The following program uses ordinary Python syntax and a familiar library object:

```python
from collections import Counter

words = "red blue red green red blue".split()
for word, count in Counter(words).most_common(2):
    print(f"{word}: {count}")
```

It prints `red: 3` and `blue: 2`. The string operations, list, loop, tuple unpacking, f-string, `Counter`, and `print()` all execute inside Peony. `Counter` is a Zig implementation exposed through normal Python import, call, hashing, iteration, and object protocols. Browser execution crosses into JavaScript for host services such as files and network transport.

Peony supports expressions, assignment, conditions, loops, functions, closures, generators, comprehensions, classes, exceptions, context managers, imports, formatted strings, structural matching, and the core Python collection types. Its Zig library set covers numeric work (`math`, `random`, `statistics`), data (`json`, `csv`), text patterns (`re`), files (`pathlib`, `os.path`), containers (`collections`, `copy`), time, HTTP, and runtime metadata.

Peony follows Python 3.12 behavior for lexical scope, argument binding, ordered dictionaries, numeric key equality, iteration, exception unwinding, and `finally`. Source uses UTF-8 and identifiers use ASCII. The [language guide](docs/language.md) and [library guide](docs/libraries.md) describe the available syntax and APIs in detail.

## Two hosts, one runtime

Peony has one compiler, VM, object model, and library implementation. Host adapters provide process or browser facilities around it.

```text
                         Python source
                               |
                 lexer -> parser -> scope analysis
                               |
                      register bytecode
                               |
              VM + values + GC + libraries + file API
                         /                 \
                native adapter          WASM ABI
                OS files, stdio,        Worker pump
                clocks, HTTP            JS files, browser services
                     |                       |
               peony executable       web/peony.mjs
```

The native executable reads a script from the host filesystem, passes its remaining arguments through `sys.argv`, and connects Peony files, streams, and host requests to operating-system services through Zig's cross-platform standard library. A normal invocation is:

```text
peony program.py first-argument "two words"
```

Program output goes to process stdout and stderr. `input()` reads UTF-8 lines from stdin. `time` uses the host wall and monotonic clocks, and `sleep` uses the host timer rather than busy-waiting. HTTP(S) requests use Zig's native HTTP/TLS stack, enforce the Peony response limit and requested timeout, and reject redirects. Unhandled Python exceptions produce source-located terminal tracebacks and exit code 1; host, limit, and internal failures use exit code 2.

Native Python file operations use real OS paths. Relative paths start at the process working directory, sibling modules are discovered beside the entry script, and writes persist on disk. `open(__file__)` reads the entry script using its host path. The [native CLI reference](docs/native-cli.md) specifies arguments, process streams, filesystem behavior, metrics, host services, and exit statuses.

The browser distribution exposes a dependency-free JavaScript session API. `Peony.load(...)` creates a module Worker, and the Worker alone instantiates `peony.wasm`. Parsing, compilation, bytecode dispatch, native libraries, and garbage collection never fall back to the page's main thread. The page receives structured results and output callbacks while it remains responsive enough to render, accept input, or request a hard stop. The [browser embedding guide](docs/embedding.md) defines this API.

The [showcase](web/index.html) is a compact demonstration of the Worker distribution: editor, examples, input, output, cancellation, and source-located errors. It uses the public facade and has no private execution path.

## From source to a terminal result

The front end first tokenizes indentation, literals, operators, delimiters, and names. The parser constructs an AST for admitted Python syntax, and scope analysis fixes local, global, cell, and free-variable bindings before code generation. The compiler then emits fixed-width, register-oriented instructions together with constants, names, and source positions.

The VM executes that code with frames for functions, generators, exception handlers, and suspended native operations. Direct slots serve locals and closure cells. Dynamic global namespaces retain ordered entries and validated per-code-object slot caches. Python exceptions are Python values that unwind through `except`, `finally`, and `with`; compilation diagnostics and engine invariant failures stay distinct from them.

```text
source bytes
    -> tokens and AST
    -> scope graph and bytecode
    -> frames, Python values, native tasks, file operations
    -> completion, Python exception, cancellation, or work limit
```

Each run owns a session allocator and a nonmoving mark/sweep heap. Frames, globals, closures, exceptions, and native continuations publish explicit roots, allowing collection during operations that call back into Python or suspend for host work. Session memory, host packet size, and combined bytecode/native work have separate budgets. Browser file content has its own Worker storage budget; native files use the host filesystem.

On wasm32, a Python value fits in an eight-byte tagged word. Floats, small integers, booleans, `None`, and internal sentinels can be immediate; big integers and compound objects use heap storage. The native target chooses the appropriate representation for its pointer width through the same Zig types. These details stay behind Python-visible protocols.

## Host requests and scheduling

Python-facing functions sometimes need facilities outside the VM. `input()` needs a line source, `time.time()` needs a clock, `time.sleep()` needs a timer, and `requests.get()` needs a transport. Peony represents those operations as versioned host packets. The program suspends at a precise continuation, the adapter performs the operation, and a reply with the matching kind and request ID resumes it. Argument handling, URL and form encoding, response objects, JSON decoding, exception mapping, and callbacks remain engine work.

The Worker adapter maps packets to page callbacks, browser timers, and `fetch`. The native adapter maps the same packet semantics to stdio, Zig clocks, sleep, and the native HTTP client. Browser HTTP uses browser CORS and TLS, while native HTTP uses Zig's client and platform trust roots. Both hosts reject redirects, apply timeouts, and cap response bytes. In the browser, URL approval also completes before transport starts.

Execution is cooperative. The VM runs a configured bytecode quantum, charges native algorithms for proportional work, and returns control between quanta. In a Worker this creates event-loop yield points and makes cancellation observable while the page stays responsive. In the native CLI the adapter immediately continues ordinary timeslices. Hard cancellation is an embedding control result; an ordinary Python exception follows normal unwinding through `finally`.

## Files follow the host

The shared Zig file object implements Python modes, cursors, text decoding, newline handling, seeking, and context management. It asks the active host to read, write, enumerate, rename, and remove files. Imports and `pathlib` use those same operations.

The native executable uses Zig's operating system file APIs. It resolves relative paths from the process working directory and searches for importable Python modules beside the script and in the working directory. `pathlib` and `os` see real directories and files. An output file created by a Peony program remains on disk after the process exits.

The browser Worker maintains an in-memory file tree in JavaScript. Its Python-visible roots are:

| Root | Role |
|---|---|
| `/assets` | Content supplied by the embedding page. |
| `/home` | Writable content kept across runs in a browser session. |
| `/tmp` | Writable scratch content refreshed for each run. |

The page supplies file bytes through `session.mount(...)` or `session.writeFile(...)`. Python code can then use `open()`, file iteration, `csv`, `pathlib`, `os.path`, and imports against that tree. File handles retain node identity across rename and unlink. Imports search `/home`, `/assets`, then `/tmp`, with Zig modules resolved first.

Browser `/assets` and `/home` survive consecutive runs in the same public session. The page can copy file bytes into its own persistent storage. The Worker keeps the file tree outside WASM memory; synchronous imports let Zig perform Python file operations against that host store. The [filesystem architecture](docs/architecture.md) traces both adapters.

## Native Zig libraries

Importable utilities are compiled into both shipping artifacts. They create ordinary Peony modules, functions, classes, iterators, exceptions, and collection values and participate in the same GC, argument binder, work budget, and exception path as user code.

Several subsystems are native Zig engines. `re` parses patterns and executes an ordered Pike-style VM. `json` decodes directly into Peony values and preserves arbitrary integer tokens. Dictionaries use ordered entries and open-addressed perturbation probing. Sorting is stable and evaluates keys once. Random sampling uses native algorithms that scale to large ranges. These choices let Peony use Zig directly while preserving Python-facing behavior.

Peony's `requests` module provides `get`, `post`, response objects, and request exceptions. `collections` provides `Counter` and `defaultdict`. The [library guide](docs/libraries.md) lists callable signatures and object methods.

## Verification across CPython, WASM, and native

The [`compare/`](compare/) corpus is one maintained set of 46 scalable Python programs covering core semantics, native libraries, files and imports, and composed workloads. It runs two paired comparisons with the same source, arguments, and fixtures. Direct `python script.py ...` and `peony script.py ...` launches measure full process latency and peak resident memory. Started CPython and Peony WASM Worker processes measure program jobs after interpreter startup. Each pair must agree on program output before its timing enters the report.

The durable [comparison report](compare/report.md) records artifact hashes, platform identity, median and p95 latency, peak RSS, and target-specific ratios in separate native and Worker tables. Smoke, standard, and stress profiles change scale and repetition count while preserving paired output checks. The [comparison guide](compare/README.md) defines each timer and memory boundary.

The [architecture guide](docs/architecture.md) maps the source tree and internal ownership. [Development and verification](docs/development.md) records native, WASM, Worker, browser, cross-target, Unicode, and comparison checks. The [WASM ABI](docs/wasm-abi.md) specifies the lower-level Worker-to-engine contract.

Peony is licensed under the [GNU Affero General Public License v3](LICENSE).
