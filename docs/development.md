# Development and verification

Peony is a Zig `0.16.0` project with a freestanding WASM target, a Worker-only JavaScript facade, and a static browser showcase. `build.zig` defines the Zig module graph, native tests, and WASM artifact. Node tests exercise both the raw shipping WASM interface and the public Worker API. The browser check drives the same showcase a learner sees. These layers answer different questions; a successful native unit test alone does not prove that a browser Worker can load and use the artifact.

This page records repeatable commands and the ownership of each check. The [architecture](architecture.md) explains the source layout and runtime path, while [language](language.md), [libraries](libraries.md), and [embedding](embedding.md) define what those checks protect.

## Toolchain and outputs

Use Zig `0.16.0`. The normal native test build uses Debug optimization and a stripped test executable. `zig build wasm` builds the shipping `wasm32-freestanding` binary with LLVM, `ReleaseFast`, WebAssembly SIMD enabled, a single-threaded runtime, and stripped debug information. The shipping artifact installs **directly** at `zig-out/peony.wasm`; there is no `bin/` nesting. The optional `-Dwasm-debug=true` selects a stripped Debug WASM with the same SIMD target for local integration work. Build output and the repository-local `.zig-cache/` are ignored by Git.

During an ordinary edit loop, run the narrowest meaningful native or Node check for the behavior being changed. Build the shipping WASM when the change crosses the raw ABI, Worker, browser, or release-artifact boundary. The full command sequence below is the integration gate, not a requirement to rebuild ReleaseFast after every line edit. This keeps Zig cache and disk pressure proportional to the current risk.

```powershell
zig version
zig build test --summary all
zig build wasm --summary all
node --test --test-concurrency=1 tests/*.test.mjs
```

`zig build test` runs native unit and semantic checks. `zig build wasm` makes the artifact consumed by the Node suite. Node's raw-WASM tests instantiate that artifact and check exports, handles, packets, execution, libraries, and VFS. Worker tests call only `web/peony.mjs` and assert that no WASM compilation or execution falls back to the calling thread. Course-program tests run representative learner code end to end through the same public path.

## What each test layer owns

| Layer | Main location | Question answered |
|---|---|---|
| Native Zig | `tests/unit/` | Do lexer, parser, scope, values, VM, GC, VFS, and native algorithms implement the admitted behavior? |
| Raw WASM/ABI | `tests/wasm-*.test.mjs` | Does the shipping artifact export the right ABI and preserve semantics, limits, errors, and memory lifetimes? |
| Public Worker | `tests/web-*.test.mjs`, `tests/course-library.test.mjs` | Do message routing, callbacks, copied files, cancellation, and full learner workloads work through the actual facade? |
| Browser showcase | `tests/showcase-browser.mjs` | Does the editor, input, stop, error location, Worker path, and narrow-screen UI work in a browser? |
| CPython comparison corpus | `compare/` | Do deterministic programs agree with CPython 3.12, and what do the same executions cost on both engines? |

Unit and integration test programs are embedded as strings in Zig or JavaScript tests, or mounted into the VFS at runtime. The tracked `.py` files under `compare/` are executable corpus inputs shared with CPython; they are not implementation modules. Library behavior belongs in Zig, while Python text is the learner program being interpreted.

The suite includes tests for unsupported forms and error paths as well as successful output. Such tests matter for Peony's subset contract: an excluded syntax form must fail clearly, a bad host packet must not consume a valid pending request, and a cancelled native callback must not replay earlier effects. Tests also cover execution under small quanta and memory/work caps, where state-lifetime bugs become visible.

## Browser showcase

After a WASM build, install the development-only browser dependency and start the static server:

```powershell
npm ci
node tools/serve_showcase.mjs
```

Open the URL printed by the server. In another terminal, run `npm run test:showcase` to drive the browser flow. The check uses an installed Chrome by default; set `PEONY_BROWSER_CHANNEL=msedge` to use Edge. `playwright-core` is a development dependency and does not ship with the static showcase. The showcase code lives in `web/index.html`, `web/showcase.mjs`, and `web/showcase.css`; it imports the same public Worker facade described in [embedding](embedding.md).

The local server serves `web/` and `zig-out/peony.wasm`. The page itself does not run WASM on the main thread. A browser test of only the raw WASM exports would miss the Worker routing and input UI path, so the showcase check is a separate layer.

## Focused checks and measurements

| Command | Purpose and interpretation |
|---|---|
| `npm run compare:smoke` | Run all comparison cases once against CPython 3.12 and require exact output agreement. |
| `npm run compare` | Run the standard scaled corpus with warmups and three measured samples on both engines. |
| `npm run compare:stress` | Run the largest corpus profile with sustained data and five measured samples. This is intentionally long. |
| `node tools/gen_unicode.mjs --check` | Verify the checked-in Unicode 15 data against pinned source inputs; no Python installation is needed for this generator. |
| `node tools/cache_report.mjs --check --json` | Read-only report of repository-local `.zig-cache/` size; it exits nonzero above the 512 MiB maintenance threshold. |

Every comparison sample is also a semantic check: a timing is rejected unless both engines complete with identical output. The corpus, methodology, filters, and report fields are documented in [`compare/README.md`](../compare/README.md). The Unicode generator separately verifies the data used by string classification, casing, and native regex classes.

Zig's content-addressed cache can grow as source changes. `.zig-cache/` is the one repository-local cache, and the shared Zig global cache is outside the repository. The 512 MiB report threshold is a maintenance signal, not a hard per-build allocation limit. Inspect the cache after a build finishes; do not remove it while Zig is using it. `zig-out/`, `.zig-cache/`, and generated probes are ignored.
