# Peony

Peony is a lean Python runtime written in Zig. It runs Python programs as a native command line executable and as a WebAssembly engine inside a Web Worker. Both use the same parser, compiler, virtual machine, object model, and libraries.

For a local tool, give Peony a Python file and its arguments. For a web application, load the engine from JavaScript, create a session, and give it Python source, files, and callbacks. Peony handles the language and program execution; the surrounding operating system or application provides storage, input, clocks, and network transport.

The engine implements Python 3.12 language features and exposes its Zig libraries through familiar Python imports. Programs can use functions, classes, generators, exceptions, collections, text processing, JSON, CSV, regular expressions, files, and HTTP. The [language reference](docs/language.md) and [library reference](docs/libraries.md) describe the syntax and APIs.

## A program you can follow from input to output

Consider a tool that counts words in a text file. Save this as **`word_count.py`**:

```python
import sys
from pathlib import Path
from collections import Counter

path = Path(sys.argv[1])
top = int(sys.argv[2])
words = path.read_text().lower().split()

for word, count in Counter(words).most_common(top):
    print(f"{word}: {count}")
```

The program reads the path from its first argument and the number of results from its second. It loads UTF-8 text, lowercases it, splits it on whitespace, counts the resulting words, and prints the most frequent ones. `Path`, `Counter`, strings, iteration, integer conversion, and formatted output all execute through Peony.

We will run this same program in a terminal and in a browser. The source stays the same; each host supplies the input file and arguments.

## Running it in a terminal

Create **`words.txt`** beside the program with this content:

```text
Red blue red green red blue
```

From that directory, run:

```sh
peony word_count.py words.txt 2
```

The output is:

```text
red: 3
blue: 2
```

Here, `peony` is the native executable, `word_count.py` is the program to run, and `words.txt` and `2` are data passed to that program. Peony reads and executes the source file. The program then opens `words.txt` and interprets `2` as the requested result count.

Within the program, `sys.argv` contains this list:

```python
["word_count.py", "words.txt", "2"]
```

Arguments arrive as strings, which is why the program uses `int(sys.argv[2])`. `sys.argv[0]` identifies the entry program. If you save the input as **`meeting notes.txt`**, use quotes to pass that filename as one argument:

```sh
peony word_count.py "meeting notes.txt" 2
```

These commands assume the executable is available as `peony` on your command path. The Windows executable is named `peony.exe`; when it is beside your files, PowerShell can invoke it as `./peony.exe word_count.py words.txt 2`.

### Files, imports, and the working directory

Native file operations use the operating system filesystem. A relative path such as `words.txt` starts at the directory from which you launch the process. A Python write creates or updates a real file, and that file remains after the program exits.

The entry program and its input files can have separate locations. For example, running `peony scripts/word_count.py words.txt 2` from your project directory loads the program under `scripts/` and reads `words.txt` from the project directory. Peony also searches for imported Python modules beside the entry script and in the working directory. This lets a script import a sibling `helpers.py` while reading data from the directory where you invoked it. Packages use `__init__.py`, and Peony's Zig libraries resolve through their registered import names.

`print()` writes to process stdout; `sys.stderr` writes to stderr. Shell redirection works with those ordinary process streams. `input()` reads a line from stdin, so a program can ask for input at the terminal or receive it through a pipe. Python tracebacks include the file and source location. Completion returns exit code `0`; a Python compilation or execution error returns `1`. CLI and host failures, an exhausted work budget, and internal errors return `2`.

### Runtime options belong before the program

The command has this shape:

```text
peony [options] SCRIPT [ARG ...]
```

Peony parses its options before the script path. Everything after the script path goes into the program's arguments. For the word-count tool, this invocation also sets a work budget and writes an execution record:

```sh
peony --max-work 5000000 --metrics run.json word_count.py words.txt 2
```

`run.json` contains the terminal status, time spent compiling and executing, bytecode and native work counters, and peak allocation accounted to the session. Full process timing also includes startup and source loading. The [native CLI reference](docs/native-cli.md) explains the options, filenames, metrics, host services, and exit behavior.

## Running the same program in a page

The browser distribution consists of two files:

| File | Role |
|---|---|
| [`web/peony.mjs`](web/peony.mjs) | JavaScript API, Worker execution loop, host services, and browser file storage. |
| [`web/peony.wasm.br`](web/peony.wasm.br) | The Zig engine compressed with Brotli level 6. |

`Peony.load(...)` starts a module Worker and loads the engine there. Parsing, compilation, execution, and garbage collection take place inside that Worker. The page sends requests and receives output and results through the JavaScript API, leaving its main thread available for rendering and user interaction.

To use the word-count example in a page, arrange these files under the same served directory:

```text
site/
  index.html
  app.mjs
  word_count.py
  web/
    peony.mjs
    peony.wasm.br
```

Use the Python program shown above for `word_count.py`. In **`index.html`**, include:

```html
<!doctype html>
<meta charset="utf-8">
<title>Word count with Peony</title>
<pre id="output"></pre>
<script type="module" src="./app.mjs"></script>
```

Then put this in **`app.mjs`**:

```js
import { Peony } from './web/peony.mjs';

const output = document.querySelector('#output');
const response = await fetch('./word_count.py');
if (!response.ok) throw new Error('Could not load word_count.py');
const source = await response.text();

const peony = await Peony.load(
  new URL('./web/peony.wasm.br', import.meta.url),
);

try {
  const session = peony.createSession({
    stdout: text => output.append(text),
    stderr: text => output.append(text),
  });

  await session.mount({
    'words.txt': 'Red blue red green red blue\n',
  });

  const result = await session.run(source, {
    filename: '/home/word_count.py',
    argv: ['/assets/words.txt', '2'],
  });

  if (result.status === 'error') {
    output.append(result.error.message);
    console.error(result.frames);
  } else if (result.status !== 'completed') {
    output.append(`Run ${result.status}`);
  }

  await session.destroy();
} finally {
  await peony.terminate();
}
```

Serve the directory over HTTP. For `peony.wasm.br`, the server must send `Content-Type: application/wasm` and `Content-Encoding: br`. The browser decodes the compressed response, and the Worker instantiates the resulting WASM. Serve the JavaScript module with a JavaScript content type. The [showcase server](showcase/serve.mjs) demonstrates this delivery, including generating or refreshing the compressed engine from a local WASM artifact.

The page displays the same `red: 3` and `blue: 2` output as the native command. JavaScript loads the program as text, mounts the input at `/assets/words.txt`, and passes that path and result count to Python. In this run, `sys.argv` is `['/home/word_count.py', '/assets/words.txt', '2']`.

`session.run` receives source text directly. Its `filename` identifies that source in `sys.argv[0]`, `__file__`, and tracebacks. Mounting a file supplies bytes that Python can open or import. Those are separate, explicit operations: the application chooses both the source to execute and the files it makes available.

## Building an interactive application around sessions

The example above runs one job and releases its resources. An editor, dashboard, or program runner can keep the loaded engine and a session alive while the user submits successive programs.

There are three useful lifetimes to understand:

| Object or operation | What it owns |
|---|---|
| `Peony.load(...)` | A Worker and its loaded WASM engine. |
| `peony.createSession(...)` | Session settings, callbacks, and a browser file tree. |
| `session.run(source, options)` | One program's globals, imported modules, heap objects, execution, and result. |

`createSession` returns a session immediately; its asynchronous calls wait for Worker setup. Each `run` starts fresh Python state. Files under `/assets` and `/home` remain in that public session, while `/tmp` is cleared for the next run. You can keep input data and generated files between jobs while giving each program a fresh namespace. Sessions created from the same loaded engine have their own Python state and file trees, and share its Worker.

Output callbacks receive text as execution progresses. `run()` resolves with a terminal result whose `status` is `completed`, `error`, `cancelled`, or `limit`. Error results include a message and structured source frames, so an application can take the user to the relevant line. The result also carries instruction and work counters. Output and completion are separate events: a program can print useful text before finishing or raising an exception.

For Python `input()`, provide an `input(prompt)` callback when creating the session. It may return a string directly or a Promise resolved by your page's form. Returning `null` signals end of input. Peony delivers the prompt through stdout before waiting for the answer. The Python program resumes from that call when the response arrives.

`session.cancel()` requests a hard stop and the active run resolves as `cancelled`. Hard cancellation discards Python execution state, including pending cleanup; ordinary Python exceptions follow `except`, `finally`, and context-manager unwinding. `session.reset()` stops an active run and refreshes Python state while retaining `/assets` and `/home`. Await the active run before destroying its session. Use `session.destroy()` when that session is finished and `peony.terminate()` when the application is finished with the Worker.

The [embedding reference](docs/embedding.md) covers the complete API, configuration, callback behavior, results, and lifecycle. The [showcase](showcase/) puts these mechanics into an editor with examples, input, output, stopping, and errors linked to source locations. It uses the same public API as the page example.

## Files and external services belong to the host

Peony implements Python file modes, cursors, decoding, line endings, seeking, and context management in Zig. The host supplies the actual storage. The native executable uses OS files through Zig; the browser Worker holds file bytes and directory entries in JavaScript. The Zig engine reaches that browser store through synchronous WASM imports.

Browser files have three roots:

| Root | Purpose |
|---|---|
| `/assets` | Input content supplied through `session.mount(...)`; Python can read it. |
| `/home` | Writable session files retained between program runs. |
| `/tmp` | Writable scratch files refreshed for each run. |

Browser relative paths start at `/home`. `session.writeFile(...)` supplies writable content, `session.readFile(...)` returns copied bytes as a `Uint8Array`, and listing methods enumerate files or directories. A page can decode returned text with `TextDecoder`, offer a download, or save the bytes in its own persistent storage. The browser tree lasts for the session; the application controls persistence across visits.

Python `open()`, `pathlib`, `os`, and imports all use the same host file interface. Browser user modules are searched under `/home`, `/assets`, and `/tmp`. Native user modules are searched beside the entry script and in the working directory. In both cases, Peony compiles and executes imported Python source through its own engine.

Clocks, sleep, terminal input, and HTTP follow the same ownership principle. Python calls such as `time.sleep()` or `requests.get()` suspend the program while the host performs the operation, then resume it with a result. Native HTTP uses Zig's HTTP/TLS client and platform certificate trust. Browser HTTP uses the application's `fetch` transport and the browser's CORS and TLS rules. An `allowUrl` callback lets the application decide which requests proceed.

Request arguments, URL and form encoding, response objects, JSON decoding, and Python exception mapping remain Zig engine work. Both adapters enforce requested timeouts and response-size budgets, and reject redirects. The [library reference](docs/libraries.md) describes the networking objects and their Python APIs.

## Python code, Zig libraries

Peony exposes its native utilities as Python modules and objects. A call such as `Counter(words).most_common(2)` enters Zig code through Python's import, call, iteration, and object protocols. The resulting values participate in the same heap and semantics as values created by your program.

| Work | Python imports |
|---|---|
| Numbers, statistics, and sampling | `math`, `statistics`, `random` |
| Structured data | `json`, `csv` |
| Text patterns | `re` |
| Paths and files | `pathlib`, `os`, `os.path` |
| Containers and object copies | `collections`, `copy` |
| Time and runtime information | `time`, `sys` |
| HTTP requests and responses | `requests`, `urllib.request` |

These libraries also call Python functions when an operation needs program-defined behavior. For example:

```python
import re

def bracket(match):
    return "[" + match.group().upper() + "]"

print(re.sub(r"[a-z]+", bracket, "red blue"))
```

This prints `[RED] [BLUE]`. The Zig regex engine finds each match; the VM executes `bracket` with the match object; the native library assembles the replacement text. The same relationship serves sorting keys, iterator consumers, default factories, callbacks on file objects, and user object methods.

Programs have arbitrary-precision integers, floating-point numbers, Unicode strings, bytes, lists, tuples, ordered dictionaries, sets, ranges, and slices. Functions support defaults, keywords, closures, decorators, and generators. Classes support inheritance, properties, static and class methods, and operator protocols. Exceptions and context managers participate in the VM's control flow. The references provide the detailed syntax and callable signatures behind this overview.

## How the engine works

The native executable and browser Worker drive one execution pipeline:

```text
Python source
    |
lexer -> parser -> scope analysis
    |
register bytecode
    |
virtual machine + Python values + garbage collector + Zig libraries
    |
host adapter
    +-- Native: OS files, process streams, clocks, HTTP/TLS
    +-- Worker: JavaScript files, page callbacks, timers, fetch
```

The lexer recognizes indentation, names, literals, and operators. The parser turns those tokens into syntax trees. Scope analysis determines which variables are local, global, or captured by a closure before execution begins. The compiler then emits register bytecode, constants, names, and source positions.

Registers are slots holding intermediate values: a loop's current item, an arithmetic result, or a call argument. The VM follows instructions that read and write those slots. Local variables and closure cells have direct slots; globals retain dynamic namespaces with caches validated against namespace changes. Functions and generators execute through frames holding their registers, bindings, and control state. Source positions travel with the code so diagnostics can identify the Python expression involved.

Python values and Zig libraries share an object model. Dictionary keys use the same hashing and equality rules across program and library operations. A generator can feed a native iterator consumer; a callback can raise a Python exception; a file object can be passed to CSV code. The runtime carries these interactions through its call, exception, and suspension machinery.

Each program has a session allocator and a nonmoving mark/sweep collector. Immediate values include small integers and floats, while compound objects and large integers have heap storage. The collector follows references from frames, globals, closures, exceptions, and native operation state. On wasm32, a value occupies a tagged word of eight bytes. This representation and the one chosen for the native target serve the same Python behavior.

Execution advances in scheduling quanta. The engine counts bytecode instructions and charges native algorithms for their work. The Worker yields between quanta to process messages and service the application; the native adapter continues execution and drains output. Operations awaiting input or network data retain their continuation, so resumption continues the pending operation. Versioned host requests and matching response IDs connect those continuations to the adapter.

Applications can configure session allocation, execution work, scheduling, and browser file storage budgets. The native CLI exposes options such as `--max-memory`, `--max-work`, and `--quantum`; the JavaScript API exposes `maxMemoryBytes`, `maxInstructions`, and `quantum`. `maxInstructions` budgets combined bytecode and native work. Session allocation, compiler scratch, Worker file content, and WASM capacity have distinct ownership and accounting. `session.stats()` exposes the engine and file counters; the [architecture guide](docs/architecture.md) explains those boundaries and maps the implementation.

## Understanding behavior and measurements

The [`compare/`](compare/) corpus runs 46 scalable programs against CPython with matching source, arguments, and fixtures. It checks output while measuring two execution shapes: complete native command line launches and jobs in already started CPython and WASM Worker processes. Latency, host RSS, and runtime allocation are measured in separate passes for started interpreters.

The [comparison report](compare/report.md) records the artifacts, machine, inputs, timings, and memory measurements. The [comparison guide](compare/README.md) explains exactly what each measurement includes. Engine tests and native, WASM, Worker, and browser integration checks cover language behavior and the surrounding host interactions; [development and verification](docs/development.md) describes those checks.

For deeper reading, follow the [language](docs/language.md), [libraries](docs/libraries.md), [native CLI](docs/native-cli.md), and [browser embedding](docs/embedding.md) references. The [WASM ABI](docs/wasm-abi.md) documents the interface used inside the Worker adapter.

Peony is licensed under the [GNU Affero General Public License v3](LICENSE). We are currently not seeking contributions.
