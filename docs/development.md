# Development checks

Peony v0.1 is pinned to Zig `0.16.0`. The shipping build targets `wasm32-freestanding`, uses `ReleaseSmall`, strips debug information, and selects LLVM.

```powershell
zig version
zig build test
zig build wasm
node --test --test-concurrency=1 --test-skip-pattern "size report" tests/*.test.mjs
```

`zig build wasm` installs `zig-out/peony.wasm`. Build output and compiler caches stay ignored. Raw-WASM Node tests verify the internal ABI; public session tests exercise the Worker-only ESM facade. Browser execution always compiles and runs WASM in the Worker. The C22 showcase uses a local static server and Playwright headless to check real editor, input, error and cancellation flows.

To view and check the showcase after building WASM:

```powershell
npm ci
node tools/serve_showcase.mjs
npm run test:showcase
```

The browser check uses an installed Chrome by default; set `PEONY_BROWSER_CHANNEL=msedge` to use Edge. `playwright-core` is a development dependency and does not ship in the static showcase.

For later release qualification, `node tools/size_report.mjs` uses Node's built-in Brotli encoder at quality 11. It builds the shipping artifact and separate bigint, JSON and Unicode probes. The Unicode generator reads pinned official Unicode 15 source inputs and verifies the checked-in table; it requires no Python file or local `unicodedata` version. Probe inputs stay under ignored `.zig-cache/size-probes/`, and artifacts install directly under `zig-out/`.

The VM owner and opcode dispatcher live in `src/vm/runtime.zig`. Shared frame, environment, try-block, and synchronous-task state with its GC tracing lives in `src/vm/state.zig`. Execution helpers are grouped by ownership: `control.zig` for frame/control transfer and exceptions, `calls.zig` for binding and invocation, `builtins.zig` for native methods, `iteration.zig` for iterators and sorting, `text.zig` for formatting/output, `objects.zig` for attributes and collection access, `operations.zig` for operators and value semantics, and `modules.zig` for module environments and imports. `Runtime` remains the single stable session object; domain methods are linked through its typed alias table, while the bytecode dispatcher stays centralized.

The native tests/unit/vfs.zig and tests/unit/files.zig suites cover session-owned path/file storage, text and binary file methods, newline handling, atomic VFS limits, and reset persistence. tests/wasm-vfs.test.mjs and tests/web-files.test.mjs exercise the shipping artifact and facade. The configurable maxVfsBytes and maxFileBytes options use an optional PCFG extension while original config packets retain their defaults. readlines() and writelines() charge per-line work against the shared configured budget, and a long native file-method loop returns LIMIT instead of exceeding it.

## String and bytes hash seeds

Each Peony session mixes an optional copied host seed with a per-session counter and runtime address to seed string and bytes hashing. When a host seed is omitted, the local counter/address fallback still varies session table hashes in freestanding WASM without a system entropy source. This is a per-session variation mechanism, not a cryptographic or unpredictability guarantee.

The repeatability check runs the size report twice:

```powershell
node --test tests/toolchain-size.test.mjs
```

The report includes exact build commands as well as raw and Brotli-q11 byte counts. WASM outputs and generated Unicode data are not tracked.

## Local cache maintenance

Native unit tests retain Debug optimization and runtime checks, but their test executable is stripped because native debugger symbols are not needed for this project. Generated probe inputs and Zig's local build cache share `.zig-cache/`; the separate `zig-cache/` directory is no longer used.

After builds finish at a commit gate, check the repo-local cache with:

```powershell
node tools/cache_report.mjs --check --json
```

The read-only check exits with status 1 above 512 MiB. Zig's content-addressed cache can grow as source changes; the threshold is a maintenance signal, not a per-build allocation limit or a reason to interrupt an active sprint. Never remove the cache during an active build. The shared Zig global cache is outside this repository.
