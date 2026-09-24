# Development checks

Peony v0.1 is pinned to Zig `0.16.0`. The shipping build targets `wasm32-freestanding`, uses `ReleaseSmall`, strips debug information, and selects LLVM.

```powershell
zig version
zig build test
zig build wasm
node --test --test-concurrency=1 tests/*.test.mjs
node tools/size_report.mjs
```

`zig build wasm` installs `zig-out/bin/peony.wasm`. Build output and compiler caches stay ignored. The sequential Node suite exercises the shipping artifact directly through WebAssembly, including packet/config validation, resumable `input()`, flush boundaries, instruction/work limits, cancellation, traceback views, stale handles, and per-session isolation. `tests/web-session.test.mjs` also exercises the direct ESM facade, URL/Response/byte loading, fresh runs, host callbacks, pending-input reset, and browser-task yielding.

The size report uses Node's built-in Brotli encoder at quality 11. It builds the shipping artifact and separate artifacts that add one `std.math.big.int.Managed` multiplication, a `std.json.Stringify` call, or a generated Unicode-15.0.0 classification/case-mapping table. Each probe is compared with the shipping baseline. The Unicode prototype generator requires Python whose `unicodedata` version is exactly 15.0.0; it writes the generated input and probe roots under the ignored `zig-cache/` directory.

The native tests/unit/vfs.zig and tests/unit/files.zig suites cover session-owned path/file storage, text and binary file methods, newline handling, atomic VFS limits, and reset persistence. tests/wasm-vfs.test.mjs and tests/web-files.test.mjs exercise the shipping artifact and facade. The configurable maxVfsBytes and maxFileBytes options use an optional PCFG extension while original config packets retain their defaults. readlines() and writelines() charge per-line work against the shared configured budget, and a long native file-method loop returns LIMIT instead of exceeding it.

## String and bytes hash seeds

Each Peony session mixes an optional copied host seed with a per-session counter and runtime address to seed string and bytes hashing. When a host seed is omitted, the local counter/address fallback still varies session table hashes in freestanding WASM without a system entropy source. This is a per-session variation mechanism, not a cryptographic or unpredictability guarantee.

The repeatability check runs the size report twice:

```powershell
node --test tests/toolchain-size.test.mjs
```

The report includes exact build commands as well as raw and Brotli-q11 byte counts. WASM outputs and generated Unicode data are not tracked.
