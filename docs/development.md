# Development and verification

Peony is a Zig `0.16.0` project with a cross-platform native executable, a freestanding WASM target, a Worker-only JavaScript facade, and a static browser showcase. `build.zig` constructs the shared engine module graph separately for each target so both shipping artifacts compile the same frontend, VM, runtime objects, and native libraries. Node tests exercise the native process, raw WASM interface, and public Worker API. The browser check drives the actual showcase. These layers answer different questions; a successful VM unit test alone does not prove that either shipping adapter works.

This page records repeatable commands and the ownership of each check. The [architecture](architecture.md) explains the source layout and runtime path, while [language](language.md), [libraries](libraries.md), and [embedding](embedding.md) define what those checks protect.

## Toolchain and outputs

Use Zig `0.16.0`. The normal unit-test build uses Debug optimization and a stripped test executable. `zig build native` builds a stripped LLVM `ReleaseFast` executable for the selected native target. It installs directly as `zig-out/peony.exe` on Windows or `zig-out/peony` elsewhere. `-Dnative-debug=true` selects a stripped Debug executable for a faster edit loop.

`zig build wasm` builds the shipping `wasm32-freestanding` binary with LLVM, `ReleaseFast`, WebAssembly SIMD enabled, a single-threaded runtime, and stripped debug information. It installs directly at `zig-out/peony.wasm`. `-Dwasm-debug=true` selects a stripped Debug WASM with the same SIMD target. The default `zig build` install step produces both shipping artifacts without `bin/` nesting. Build output and the repository-local `.zig-cache/` are ignored by Git.

During an ordinary edit loop, run the narrowest meaningful native or Node check for the behavior being changed. Build the shipping WASM when the change crosses the raw ABI, Worker, browser, or release-artifact boundary. The full command sequence below is the integration gate, not a requirement to rebuild ReleaseFast after every line edit. This keeps Zig cache and disk pressure proportional to the current risk.

```powershell
zig version
zig build test --summary all
zig build native --summary all
zig build wasm --summary all
node --test --test-concurrency=1 tests/*.test.mjs
```

`zig build test` runs engine unit and semantic checks. `zig build native` makes the executable used by `tests/native-cli.test.mjs`; that test covers version identity, arguments, explicit VFS mounts, stdin, diagnostics, metrics, clocks, sleep, HTTP, and timeout mapping through an actual child process. `zig build wasm` makes the artifact used by the raw-WASM and Worker suites. Raw tests check exports, handles, packets, execution, libraries, and VFS. Worker tests call only `web/peony.mjs` and assert that no WASM compilation or execution falls back to the calling thread.

## What each test layer owns

| Layer | Main location | Question answered |
|---|---|---|
| Native Zig | `tests/unit/` | Do lexer, parser, scope, values, VM, GC, VFS, and native algorithms implement the admitted behavior? |
| Native process | `tests/native-cli.test.mjs` | Does the shipping executable connect the shared runtime to process arguments, streams, files, clocks, timers, networking, diagnostics and metrics? |
| Raw WASM/ABI | `tests/wasm-*.test.mjs` | Does the shipping artifact export the right ABI and preserve semantics, limits, errors, and memory lifetimes? |
| Public Worker | `tests/web-*.test.mjs`, `tests/course-library.test.mjs` | Do message routing, callbacks, copied files, cancellation, and complete programs work through the actual facade? |
| Browser showcase | `tests/showcase-browser.mjs` | Does the editor, input, stop, error location, Worker path, and narrow-screen UI work in a browser? |
| CPython comparison corpus | `compare/` | Do deterministic programs agree across CPython, Peony WASM, and Peony native, and what does the same execution cost on each target? |

Unit and integration programs are embedded as strings in Zig or JavaScript tests, or mounted into the VFS at runtime. The tracked `.py` files under `compare/` are executable corpus inputs shared with CPython; they are not implementation modules. Library behavior belongs in Zig, while Python text is program input.

The suite includes tests for unsupported forms and error paths as well as successful output. Such tests matter for Peony's subset contract: an excluded syntax form must fail clearly, a bad host packet must not consume a valid pending request, and a cancelled native callback must not replay earlier effects. Tests also cover execution under small quanta and memory/work caps, where state-lifetime bugs become visible.

## Browser showcase

After a WASM build, install the development-only browser dependency and start the static server:

```powershell
npm ci
node tools/serve_showcase.mjs
```

Open the URL printed by the server. In another terminal, run `npm run test:showcase` to drive the browser flow. The check uses an installed Chrome by default; set `PEONY_BROWSER_CHANNEL=msedge` to use Edge. `playwright-core` is a development dependency and does not ship with the static showcase. The showcase code lives in `web/index.html`, `web/showcase.mjs`, and `web/showcase.css`; it imports the same public Worker facade described in [embedding](embedding.md).

The local server serves `web/` and `zig-out/peony.wasm`. The page itself does not run WASM on the main thread. A browser test of only the raw WASM exports would miss the Worker routing and input UI path, so the showcase check is a separate layer.

## Native target checks

The current host executable can be exercised directly:

```powershell
zig-out\peony.exe --version
zig-out\peony.exe path\to\program.py argument
```

Compile another target into a separate prefix so the current host artifact remains available:

```powershell
zig build native -Dtarget=x86_64-linux -p zig-out/linux-x86_64 --summary all
```

Cross compilation checks source and link portability. Run `tests/native-cli.test.mjs` and the comparison corpus on the target machine to verify its stdio, certificate bundle, clocks, timers, and networking. The [native CLI reference](native-cli.md) records the process contract.

## Focused checks and measurements

| Command | Purpose and interpretation |
|---|---|
| `npm run compare:smoke` | Run all cases once across CPython 3.12, Peony WASM, and Peony native and require exact output agreement. |
| `npm run compare` | Run the standard scaled corpus with warmups and three measured samples on all three runtimes. |
| `npm run compare:stress` | Run the largest corpus profile with sustained data and five measured samples. This is intentionally long. |
| `node tools/gen_unicode.mjs --check` | Verify the checked-in Unicode 15 data against pinned source inputs; no Python installation is needed for this generator. |
| `node tools/cache_report.mjs --check --json` | Read-only report of repository-local `.zig-cache/` size; it exits nonzero above the 512 MiB maintenance threshold. |

Every comparison sample is also a semantic check: a timing is rejected unless CPython, Peony WASM, and Peony native complete with identical output. The corpus, methodology, filters, and report fields are documented in [`compare/README.md`](../compare/README.md). The Unicode generator separately verifies the data used by string classification, casing, and native regex classes.

Zig's content-addressed cache can grow as source changes. `.zig-cache/` is the one repository-local cache, and the shared Zig global cache is outside the repository. The 512 MiB report threshold is a maintenance signal, not a hard per-build allocation limit. Inspect the cache after a build finishes; do not remove it while Zig is using it. `zig-out/`, `.zig-cache/`, and generated probes are ignored.
