# Native command-line runtime

The native Peony executable runs the same Zig compiler, VM, object model, libraries, host protocol, and virtual filesystem as `peony.wasm`. `src/native.zig` is a process adapter around that engine. It loads one source file, constructs one runtime, installs explicit VFS mounts, drives execution to a terminal status, and maps host requests to portable Zig facilities.

The executable is named `peony.exe` on Windows and `peony` on other targets. A basic invocation is:

```text
peony script.py argument-one "argument two"
```

Peony decodes `script.py` as UTF-8 and uses the supplied path as the default diagnostic filename and `sys.argv[0]`. Remaining arguments become `sys.argv[1:]` without Python-style option parsing. Options for the Peony process must therefore appear before the script path. `--` ends Peony option parsing when a script filename begins with `-`.

## Command syntax

```text
Usage: peony [options] SCRIPT [ARG ...]

  -h, --help
  -V, --version
  --filename NAME
  --mount HOST_PATH VFS_PATH
  --metrics PATH
  --max-memory BYTES
  --max-work COUNT
  --quantum COUNT
  --max-vfs BYTES
  --max-file BYTES
  --seed TEXT
```

`--filename` changes the name compiled into code objects, tracebacks, `__file__`, and `sys.argv[0]`; it does not select a different source file. This is useful when the host path is temporary or should not be exposed to the program.

Every size and count option accepts a positive base-10 integer. The defaults match the Worker session defaults: 64 MiB of session-accounted allocation, 50,000,000 combined work units, a 50,000 instruction quantum, 8 MiB of VFS content, and a 2 MiB single-file cap. `--max-file` cannot exceed `--max-vfs`. `--seed` accepts at most 1,024 UTF-8 bytes and affects session hash variation; it is not a cryptographic random seed.

The CLI reads at most 16 MiB of source. Source loading, explicit mounts, runtime initialization, and metrics-file output happen outside Python execution. Allocation performed by the compiler and VM after runtime initialization is still subject to the configured session limit according to the common engine rules.

## Streams and terminal results

Peony's `sys.stdout`, `sys.stderr`, `print()`, and direct stream writes preserve their Python ordering in runtime-owned buffers. The native adapter drains those buffers to process stdout and stderr at VM boundaries. `flush=True` creates an immediate output event, and the adapter drains it before continuing.

`input(prompt)` writes the prompt through the normal stdout path, flushes it before waiting, and reads one UTF-8 line from process stdin. LF is removed by the process reader; the engine also applies its normal CR/LF trimming rule. End of input becomes Python `EOFError`. A line over 1 MiB or invalid UTF-8 becomes a Python `OSError` through the same host-error path used by the Worker adapter.

The process exit status separates Python behavior from host and engine failures:

| Exit code | Meaning |
|---:|---|
| `0` | The program completed normally. |
| `1` | Compilation was unsupported or invalid, or execution ended with an unhandled Python exception. |
| `2` | CLI usage, host operation, work limit, cancellation, or engine integrity failure. |

Compile diagnostics print their file, source line, and message. Runtime errors print a Python-style `Traceback (most recent call last)` list followed by Peony's exception text. Program stderr remains distinct from these adapter diagnostics. A caught Python exception does not affect the process exit code.

## Virtual files and imports

Reading the entry script does not grant the executing program access to its host directory. Python file operations and imports use Peony's VFS, whose roots are `/home`, `/course`, and `/tmp`. This matches the browser runtime and keeps host authority explicit.

Use `--mount` once per host file that should be visible:

```text
peony \
  --mount ./lib/helpers.py /home/lib/helpers.py \
  --mount ./config.json /course/config.json \
  app.py production
```

The adapter reads every mount before compilation. Missing `/home` parent directories are created. Missing `/course` parents are created by the read-only mount operation. Targets under `/course` cannot be modified by Python; targets under `/home` can. `/tmp` starts empty and is reserved for files created during the run, so it is not a mount target. Mount contents count against the configured VFS and per-file limits.

Mounts are snapshots for one process. Changes made through `open()`, `pathlib`, or `os` stay in the VFS and are discarded when the executable exits. Peony does not copy created, renamed, or changed files back to their host sources. A wrapper that needs persistence can make that policy explicit around the runtime rather than giving interpreted code ambient filesystem access.

User modules and packages are found below `/home`, `/course`, and `/tmp` in that order. Registered Zig modules take precedence on the first lookup. Mount a module file at `/home/name.py`, or mount package files below `/home/package/` including `__init__.py`. The entry source itself is already compiled directly and does not need a VFS mount.

## Native host services

The engine suspends `input`, clock, sleep, and HTTP operations through the same versioned packet contract used by WASM. The native adapter decodes an owned packet before draining output because runtime mutations invalidate borrowed event views. It then validates the request, performs the host operation, and resumes only with the matching kind and request ID.

`time.time()` reads Zig's real clock and returns seconds since the Unix epoch. `time.monotonic()` uses Zig's awake monotonic clock. `time.sleep()` converts a finite nonnegative Python duration to a host timer and does not spin or consume bytecode work while waiting.

HTTP(S) is performed by Zig's native HTTP client. Peony engine code still owns method selection, URL and form encoding, JSON bodies, Python response objects, header lookup, text decoding, and exception mapping. The native adapter supplies transport with these policies:

- only the engine's admitted GET and POST packets are accepted;
- redirects are rejected;
- compressed response bodies are decoded by Zig before entering the VM;
- response payload is capped below the 1 MiB host-packet ceiling;
- request timeouts race the transport against a cancellable monotonic timer;
- TLS uses Zig's native client and the platform certificate bundle;
- malformed or non-UTF-8 response headers become a host connection failure.

Network errors map through `connection`, policy failures through `policy`, and expired timers through `timeout`, allowing `urllib` and `requests` to raise their documented Python exceptions. There is no browser CORS layer in a native process. The Python-visible `ssl.SSLContext` compatibility object does not replace the native TLS configuration or expose certificates and sockets.

## Machine-readable metrics

`--metrics PATH` writes one JSON object after execution:

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

`elapsed_ns` spans `compileAndStartArgs` through the terminal runtime status, including host service waits and output delivery. It excludes executable startup, reading the source and mounts, runtime construction, and writing the metrics file. The status names are `completed`, `python_exception`, `unsupported`, `cancelled`, `limit`, `engine_error`, and `host_error`. A metrics record is written for a terminal compile or run result; a failure before runtime execution may end without one.

The comparison harness uses this channel so native program stdout and stderr remain available for exact comparison. Instruction and work counters have the same meaning as their Worker counterparts. Peak session bytes can differ by target because native and wasm pointer widths and standard-library layouts differ.

## Portability boundary

The adapter uses Zig 0.16 `std.process.Init`, `std.Io`, `std.http.Client`, path-aware file operations, clocks, timers, and target naming. There is no Windows-specific process, console, networking, or path implementation in Peony. `build.zig` resolves the requested native target and links the same module graph for it; the shipping native target uses stripped `ReleaseFast`, with a stripped Debug option for local integration work.

Cross compilation proves that the adapter and engine compile for another target. Execution tests still belong on each target OS because certificate stores, terminal encoding, timers, and network stacks are host behavior. The comparison report records the native binary hash and host platform so results from Windows and Linux remain attributable.
