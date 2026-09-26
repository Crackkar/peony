# Development and verification

Peony uses Zig `0.16.0` and Node for WASM/Worker tests. The browser check uses `playwright-core` and an installed Chrome or Edge. The build graph is defined in `build.zig`; `zig build wasm` emits the stripped `wasm32-freestanding` `ReleaseSmall` artifact directly at `zig-out/peony.wasm`. The optional `-Dwasm-debug=true` builds a stripped Debug WASM for local integration work. Native unit tests use Zig's Debug mode with stripped test executables.

## Core checks

From the repository root:

```powershell
zig version
zig build test --summary all
zig build wasm --summary all
node --test --test-concurrency=1 --test-skip-pattern "size report" tests/*.test.mjs
```

`tests/unit/` covers runtime and language semantics in native Zig. The Node suite covers the shipping WASM ABI, public Worker facade, VFS, libraries, and course programs. Raw-WASM tests deliberately exercise the internal ABI; applications use the Worker facade. The skipped `size report` test is an opt-in repeatability/build check, not a language-semantic test.

## Showcase

After `zig build wasm`, install the development-only browser test dependency and start the local static server:

```powershell
npm ci
node tools/serve_showcase.mjs
```

Open the URL printed by the server. In another terminal, `npm run test:showcase` runs the browser flow check. It uses installed Chrome by default; set `PEONY_BROWSER_CHANNEL=msedge` to use Edge. The check exercises the real Worker path, editor examples, input, cancellation, errors, and a narrow/mobile layout. `playwright-core` does not ship in the static showcase.

## Focused tools

| Command | Purpose |
|---|---|
| `node tools/diff_libraries.mjs` | Compare selected pure-library snippets with an available CPython 3.12 executable. Set `PEONY_CPYTHON` to choose one. This is a targeted oracle, not proof of full conformance. |
| `node tools/gen_unicode.mjs --check` | Verify the generated Unicode 15 data against pinned source inputs. |
| `node tools/size_report.mjs` | Build/report raw and Brotli sizes and feature probes. Run when size qualification is wanted; it is more expensive than ordinary edit/test loops. |
| `node tools/bench_libraries.mjs` | Measure representative library workloads against a built WASM artifact. |
| `node tools/cache_report.mjs --check --json` | Read-only report of the local `.zig-cache/` size, with a 512 MiB maintenance threshold. |

Compiler caches, `zig-out/`, and generated probe files are ignored. `.zig-cache/` is the one repository-local Zig cache; avoid clearing it during a build. The project has no Python source implementation or `.py` fixtures: test programs are strings supplied to the interpreter.

See [architecture](architecture.md) for source ownership, [language](language.md) and [libraries](libraries.md) for the supported surface, and [embedding](embedding.md) for the public API.
