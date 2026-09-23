# Development checks

Peony v0.1 is pinned to Zig `0.16.0`. The shipping build targets `wasm32-freestanding`, uses `ReleaseSmall`, strips debug information, and selects LLVM.

```powershell
zig version
zig build test
zig build wasm
node --test --test-concurrency=1 tests/*.test.mjs
node tools/size_report.mjs
```

`zig build wasm` installs `zig-out/bin/peony.wasm`. Build output and compiler caches stay ignored. The Node suite exercises the artifact directly through WebAssembly, from bytes and with `instantiateStreaming()` using `application/wasm`. It covers the ABI plus straight-line compilation and execution, output, Python exceptions, timeslices, cancellation, stale handles and per-session isolation.

The size report uses Node's built-in Brotli encoder at quality 11. It builds the shipping artifact and separate artifacts that add one `std.math.big.int.Managed` multiplication, a `std.json.Stringify` call, or a generated Unicode-15.0.0 classification/case-mapping table. Each probe is compared with the shipping baseline. The Unicode prototype generator requires Python whose `unicodedata` version is exactly 15.0.0; it writes the generated input and probe roots under the ignored `zig-cache/` directory.

The repeatability check runs the size report twice:

```powershell
node --test tests/toolchain-size.test.mjs
```

The report includes exact build commands as well as raw and Brotli-q11 byte counts. WASM outputs and generated Unicode data are not tracked.
