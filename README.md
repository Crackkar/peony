# Peony

Peony is a Python learning environment that runs in the browser. A learner writes a small program, runs it, sees output or a source-located error, changes the program, and tries again. The code looks like introductory Python because it *is* interpreted as Python syntax and values. Peony implements a deliberately defined subset of Python 3.12, with the interpreter and user-facing libraries written in Zig and compiled to WebAssembly.

The central idea is to put a real, self-contained interpreter close to the editor. A lesson page does not need to send each run to a server, install Python on the learner's machine, or turn Python into JavaScript. Peony's WebAssembly instance lives in a **Web Worker**, so parsing and execution happen away from the page's main thread. The page remains responsible for interaction: showing text, collecting an answer to `input()`, and providing browser services such as `fetch` when a program requests them.

## What running Peony feels like

This program uses ordinary Python syntax and a familiar library object:

```python
from collections import Counter

words = "red blue red green red blue".split()
for word, count in Counter(words).most_common(2):
    print(f"{word}: {count}")
```

It prints `red: 3` and `blue: 2`. The string, list, loop, tuple unpacking, f-string, `Counter`, and `print()` all run inside Peony. `Counter` is a native Zig object exposed through the normal Python import and call mechanisms. The program does not cross into JavaScript for every word, and Peony does not load a hidden Python implementation of `collections`.

That distinction matters as programs grow. A learner can use functions and closures, classes, exceptions, comprehensions, generators, formatted strings, lists, dictionaries, sets, and files within the supported language surface. The interpreter owns their meaning. A lesson author can mount a data file, let a student read it with `open()` or `pathlib.Path`, and inspect the resulting output. Python code remains the material the learner is studying; Zig provides the machinery underneath.

The [showcase](web/index.html) demonstrates this loop with an editor, a few examples, an input prompt, output, a stop button, and error locations. It is a compact example of an embedding page, not a second implementation of the language.

## A deliberate Python subset

Peony aims at the kinds of programs used in introductory courses: expressions, assignments, conditions, loops, functions, collection operations, imports, basic classes, exceptions, and everyday data processing. It follows Python 3.12 syntax where a feature is admitted. The goal is that a supported construct behaves like Python, including the details that shape what a learner understands: lexical scope, argument binding, dictionary order, numeric equality, iterator behavior, and `finally` during ordinary exception flow.

The boundary is explicit. Source must be UTF-8, and identifiers are ASCII even though strings are Unicode. `match` supports literal, singleton, capture, wildcard, and OR patterns with guards; sequence, mapping, and class patterns are outside this version. Async syntax, `yield from`, exception groups, complex numbers, custom metaclasses, and dynamic `eval`/`exec` are excluded. Recognized unsupported syntax produces a compile diagnostic rather than executing with misleading semantics. An unavailable module raises a Python import error. This matters in a learning environment: a plausible but subtly wrong result can teach the wrong rule.

Peony includes a purposeful collection of builtins and native library APIs. The library set covers numbers (`math`, `random`, `statistics`), data (`json`, `csv`), text patterns (`re`), files (`pathlib`, `os.path`), containers (`collections`, `copy`), and browser-backed services (`urllib.request`, a small `requests` teaching API, `time`, and an `ssl` compatibility object). `sys` exposes run metadata, arguments, streams, and the module cache. Each module admits specific names and options. Importing `requests`, for example, gives useful `get`, `post`, response, and exception behavior; it does not imply that the full third-party distribution is present. The [language surface](docs/language.md) and [native library surface](docs/libraries.md) list the precise admissions and exclusions.

## From source text to a result

When a learner presses Run, the page sends the source and run options through Peony's public JavaScript session API. The Worker owns the WebAssembly instance and passes the source into the Zig engine. Inside that engine, the front end tokenizes indentation, literals, operators, and names; parses a syntax tree; resolves scopes; and compiles register-oriented bytecode with source positions. Scope analysis happens before execution, so a name in a closure or a `global` declaration is resolved by the language rules rather than guessed during each lookup.

The virtual machine executes that bytecode. A run has frames for function calls and exception handlers, registers for intermediate values, and a session heap for Python objects. The same VM handles user functions, generators, native library calls, and callbacks from native objects into learner code. A Python exception follows Python control flow; the engine can catch it in `except`, run `finally`, or report an unhandled traceback. A syntax failure stops at compilation and carries a source location. An ordinary successful run reports completion. These outcomes are returned as structured results, not scraped from printed text.

```text
learner source
    -> lexer and parser
    -> scope analysis and bytecode compiler
    -> VM frames, values, native libraries, virtual files
    -> completion, Python error, cancellation, or work limit
```

On wasm32, a Python value fits in an eight-byte tagged word. Floats and small integers can live directly in that word; larger integers and compound objects live on the heap. The heap uses a nonmoving mark/sweep collector and tracks live roots from frames and native operations. A per-session allocator accounts for runtime memory, while a work budget charges both bytecode instructions and native work. These choices give the engine control over data layout, allocations, and host crossings without changing the Python surface the learner sees. They also keep implementation decisions inside Zig: the browser page is not asked to emulate Python objects.

## Why execution stays in a Worker

An infinite loop must not freeze the editor. Peony therefore runs bytecode in bounded quanta. At a quantum boundary, the Worker can drain output and yield to its event loop before resuming the VM. The page can still update, show an input form, or send a stop request. Resumable native operations charge work and check for cancellation. Some nested synchronous operations run until they finish or hit the shared work limit, so a quantum is a scheduling mechanism rather than a promise that every possible step takes equal time.

The public `Peony.load(...)` facade always creates a module Worker. That Worker imports the internal JavaScript pump, compiles or instantiates `peony.wasm`, and owns its memory. Messages between the page and Worker identify the session and run. The page never receives a raw WebAssembly pointer, and there is no main-thread execution fallback. Internal tests can call the raw WASM ABI directly, but applications and the showcase use the Worker API.

Python's `input()` illustrates the boundary. To the program, `name = input("Name: ")` is a normal call that returns a string. The VM emits a host request and pauses the current operation. The Worker sends the prompt to the page; the page's `input` callback obtains a response; the Worker validates a matching response packet and resumes exactly that suspended run. The same pattern supports HTTP, clock reads, and sleep. Native operations that invoke a learner callback also preserve their place, so an `input()` inside such a callback does not force the library operation to start over.

Output follows the other direction. `print()` appends to buffers owned by the session. The Worker drains them at execution boundaries and when `flush=True` requests an immediate drain point. The page receives text chunks through `stdout` or `stderr` callbacks and decides how to display them. Thus the engine determines Python output order while the embedding page determines presentation.

## Files that make sense in a lesson

Peony includes an in-memory virtual filesystem because beginner exercises often read a provided file or write a result. Python's file methods are synchronous from the learner's point of view. Keeping the files with the interpreter lets `readline()`, iteration, `csv.reader`, and `pathlib` use one consistent file model without a browser storage round-trip for each operation.

The filesystem has three roots:

| Root | Meaning |
|---|---|
| `/course` | Read-only files mounted by the lesson host, such as a CSV or text fixture. |
| `/home` | Files the learner can create and edit. |
| `/tmp` | Scratch files cleared when a new run starts. |

For example, a lesson can mount `/course/points.csv`; learner code can then open it with `with open("/course/points.csv", newline="") as source:` and pass `source` to `csv.reader`. A learner can also write a note through `Path("/home/note.txt").write_text(...)` and read it in a later run. Each run gets fresh Python globals and imports, while `/course` and `/home` persist within the same public session. `session.reset()` clears the whole session, including files. A course site can save or restore file bytes through the JavaScript file API if it wants persistence across page visits; Peony itself does not silently write to IndexedDB or the host filesystem.

Paths use a case-sensitive POSIX-like convention on every host. They cannot escape the virtual roots into the laptop or server running the page. The [architecture guide](docs/architecture.md) explains how file nodes, open handles, imports, and run lifetimes fit together.

## Browser services have a narrow boundary

Some Python functions genuinely need the outside world. `requests.get(...)` needs an HTTP transport; `time.sleep(...)` needs a timer. Peony keeps the Python-facing behavior in Zig: argument binding, URL and form conversion, JSON parsing, response objects, and Python exceptions. The host supplies the actual `fetch`, clock, or timer operation through a callback. This is why a mock `fetch` can drive a deterministic lesson or test without changing the Python program.

HTTP is limited to HTTP(S), and browser security rules still apply. Requests omit credentials by default, redirects are rejected unless the host opts into following them, and response bodies are capped while being read. A course host can provide an `allowUrl` policy. The small `ssl` object exists for teaching patterns that pass a context to `urlopen`; changing it cannot alter browser certificate validation or CORS. These are boundaries between the interpreter and the browser, not differences in where Python syntax runs.

## Errors, stopping, and resource limits

Peony distinguishes a Python error from an execution control outcome. A syntax error or unsupported feature carries a compile location. An unhandled runtime exception carries a message and traceback frames with filename, line, column, and source line. The showcase can use those frames to take the learner back to the relevant line. A completed run has no error. A run that reaches its configured combined work budget reports `limit`; the host can explain that the program exceeded its work allowance without pretending it was a catchable Python exception.

The stop button calls `session.cancel()`. Cancellation is a **hard stop**: the run resolves as `cancelled`, pending host work is aborted or ignored, and Python `finally` or context-manager exit code is not run. This is intentionally different from an ordinary Python exception unwinding through a `try` block. Sessions also expose instruction, work, memory, GC, and VFS counters for an embedding host that wants to explain or monitor a run. Memory and file budgets are configurable; the [embedding guide](docs/embedding.md) gives their defaults and exact API.

## How the pieces fit on a page

A site imports `web/peony.mjs`, loads a WASM URL, creates a session with callbacks, and calls `run(source, { filename, argv })`. The returned status and frames are separate from streamed output. The session also exposes methods to mount course files, read or write learner files, inspect statistics, collect garbage while idle, reset, and destroy. Multiple sessions can belong to one loaded Worker, each with its own Python state and virtual files.

```text
page: editor, output, input, lesson files
       |  public session calls and host callbacks
       v
Worker: WASM owner and execution pump
       |  bounded bytecode runs and host packets
       v
Zig engine: compiler, VM, values, GC, libraries, VFS
```

This division lets a course change the editor, layout, input widget, or storage choice without rewriting interpreter semantics. It also lets Peony change an internal algorithm while keeping the learner's Python code and the host session API stable within the documented subset. The [embedding guide](docs/embedding.md) shows a small integration; the [architecture guide](docs/architecture.md) explains the engine; the [WASM ABI](docs/wasm-abi.md) records the lower-level Worker-to-engine contract. [Development checks](docs/development.md) describe the local verification paths.

Peony is licensed under the [GNU Affero General Public License v3](LICENSE). We are not currently seeking contributions.
