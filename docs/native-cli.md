# Native command-line runtime

The native Peony executable runs the shared Zig compiler, VM, object model, and libraries as an operating system process. Zig's host adapter supplies filesystem operations, standard streams, clocks, timers, and HTTP transport. The executable is `peony.exe` on Windows and `peony` on other targets.

```text
peony script.py first-argument "two words"
```

The executable reads `script.py` as UTF-8. The script path becomes `sys.argv[0]` and `__file__`; the remaining command arguments become `sys.argv[1:]`. CLI options precede the script path. `--` ends option parsing for script filenames that begin with `-`.

## Command syntax

```text
Usage: peony [options] SCRIPT [ARG ...]

  -h, --help
  -V, --version
  --filename NAME
  --metrics PATH
  --max-memory BYTES
  --max-work COUNT
  --quantum COUNT
  --seed TEXT
```

`--filename` supplies the source name in `sys.argv[0]`, `__file__`, and tracebacks. The executable still loads source from `SCRIPT`. This option helps a process runner present a stable display name for a generated script.

Size and work options accept positive base-10 integers. Defaults are 64 MiB of session-accounted runtime allocation, 50,000,000 combined work units, and a 50,000 instruction quantum. `--seed` accepts up to 1,024 UTF-8 bytes and influences session hash variation. The CLI loads source files up to 16 MiB.

## Native files and imports

Python `open()`, `pathlib.Path`, and `os` operate on the host filesystem through Zig. Relative paths resolve from the process working directory; absolute paths use the operating system's path rules. File writes persist after Peony exits and are visible to other programs. Operating system permissions govern access.

The entry script is available at its host path, so `open(__file__)` reads its source. Imports search the script's directory, then the process working directory. For example:

```text
project/
  app.py
  helpers.py
  config.json
```

Running `peony project/app.py` lets `app.py` import `helpers` directly. If the working directory is `project/`, `open("config.json")` reads the same file another native process would read there. Packages use directories containing `__init__.py`. Registered Zig libraries resolve through the runtime module registry.

The runtime owns Python file objects and their mode, cursor, text decoding, newline, and context-manager behavior. The host owns file contents and directory entries. An open file object keeps its operating system handle, so file identity and rename behavior follow the active platform.

## Streams and terminal results

`print()` and `sys.stdout` write to process stdout. `sys.stderr` writes to process stderr. The adapter drains runtime output at execution boundaries, and `flush=True` requests an immediate drain. `input(prompt)` writes its prompt, reads one UTF-8 line from process stdin, and returns it without the line ending.

| Exit code | Meaning |
|---:|---|
| `0` | Program completed. |
| `1` | Python compile or runtime error. |
| `2` | CLI, host, work, or engine error. |

Diagnostics include source locations and Python tracebacks. A Python exception handled by the program leaves the process on its normal completion path.

## Host services

`time.time()` uses Zig's real clock, `time.monotonic()` uses its awake monotonic clock, and `time.sleep()` uses a host timer. `requests` and `urllib.request` use Zig's HTTP client and platform certificate trust. The engine constructs Python request arguments, response objects, and exception values; the adapter performs transport and returns a versioned host packet.

The adapter sends GET and POST requests, applies the specified timeout, decodes supported response compression, caps the response body under the host packet budget, and requests redirect rejection. HTTP errors enter Peony through the Python exception surface documented in [libraries](libraries.md).

## Machine-readable metrics

`--metrics PATH` writes an execution record after the run:

```json
{
  "schema": 1,
  "status": "completed",
  "elapsed_ns": 1528400,
  "instructions": 9142,
  "work": 11003,
  "peak_session_bytes": 183296
}
```

`elapsed_ns` spans compilation and program execution. Source loading, process startup, and metrics output occur around that interval. `instructions` counts bytecode dispatches; `work` also includes charged native algorithms. The comparison corpus measures full CLI process lifetime and peak RSS with its separate process probe; the CLI metrics option remains available for engine-level inspection.

## Portability

The adapter uses Zig 0.16 `std.process.Init`, `std.Io`, `std.Io.Dir`, `std.Io.File`, clocks, timers, and `std.http.Client`. `zig build native` produces a stripped ReleaseFast executable for the selected target. A native build targeting `x86_64-linux` also compiles from this tree. Run the CLI integration checks on each host OS to measure its file, terminal, timer, and network behavior.
