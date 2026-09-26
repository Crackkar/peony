# Peony

Peony is a lean Python learning environment for the web. Learners can write familiar introductory Python, run it, inspect output and errors, and change the program without installing Python. Peony implements a deliberate **Python 3.12 language subset**: supported behavior aims to feel like Python, while unsupported syntax and APIs have explicit boundaries.

The interpreter and its user-facing libraries are written in Zig and compiled to WebAssembly. The page holds the editor and presentation; a **Web Worker always owns the WASM instance**, Python state, and execution loop. The page and Worker exchange versioned messages for output, input, and browser services. Files live in a session-local virtual filesystem. HTTP, clocks, and sleep cross the host boundary only when a running program needs them.

```text
editor / embedding page
        │  public JavaScript session API
        ▼
      Worker ─── browser input, fetch, clock, sleep
        │
        ▼
  Zig WASM interpreter
  lexer → parser → scope/compiler → bytecode VM
                       │
             values, GC, native libraries, VFS
```

The [showcase](web/index.html) is a small example of this arrangement: editor, examples, input, stop, and source-located errors. Peony is designed for embedding in a course or learning site; the showcase is not a separate interpreter.

## Documentation

- [Language and builtin surface](docs/language.md) — syntax, values, formatting, files, and deliberate limits.
- [Native libraries](docs/libraries.md) — the importable Zig implementations and their admitted APIs.
- [Embedding and Worker API](docs/embedding.md) — loading WASM, running sessions, host services, and results.
- [Architecture](docs/architecture.md) — compilation, execution, memory, suspension, and virtual files.
- [WASM ABI](docs/wasm-abi.md) — the internal byte-level interface used by the Worker.
- [Development](docs/development.md) — local build, showcase, and verification commands.

Peony is licensed under the [GNU Affero General Public License v3](LICENSE). We are not currently seeking contributions.
