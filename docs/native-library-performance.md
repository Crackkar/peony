# Native library performance evidence

The measurements below use Zig 0.16.0, Node v24.14.1 on Windows, the stripped `ReleaseSmall` WASM artifact, three warmups and ten measured repetitions unless a row says otherwise. Inputs and SHA-256 hashes are produced by the checked-in benchmark tools. End-to-end times include Peony compilation and execution; peak WASM bytes are linear-memory capacity, not exact live-object size. Run `node tools/bench_libraries.mjs` against a freshly built `zig-out/peony.wasm`; set `PEONY_BENCH_REGEX=1` in the environment before running `node --test tests/wasm-library-regex.test.mjs` for the regex records. The Unicode table is checked separately with `node tools/gen_unicode.mjs --check`.

## End-to-end learner workloads

The frozen C21 artifact is SHA-256 `08592607d56dd1f29a1200efb27f5f8be3c8c6aa1c7244b6fa867109c1a69ad0`, 1,153,343 raw bytes and 287,541 Brotli quality-11 bytes. The C20 baseline was 831,785 raw and 204,103 Brotli quality-11 bytes, an addition of 321,558 raw and 83,438 Brotli bytes. The complete Node, size and end-to-end workload gates used this exact artifact hash; the native suite used the same frozen source.

| Workload | Input bytes | Median / p95 ms | Median work | Peak WASM bytes |
|---|---:|---:|---:|---:|
| Counter, 8,000 words | 42,193 | 20.01 / 26.32 | 8,032 | 3,145,728 |
| CSV, 4,000 rows and `int()` aggregation | 32,722 | 39.51 / 82.88 | 61,673 | 4,521,984 |
| JSON, 4,000 nested rows, `load` then `dumps` | 168,781 | 113.27 / 126.63 | 105,680 | 5,832,704 |
| Path/VFS, 18 KB file read 30 times | 18,188 | 3.21 / 4.15 | 380 | 6,488,064 |
| `deepcopy`, 100 alias/cycle graphs | 253 | 1.98 / 3.40 | 3,428 | 6,488,064 |
| `random.sample`, 25,000 of 100,000 | 104 | 73.39 / 89.34 | 25,411 | 3,538,944 |

The JSON input hash is `3fe5777c23dfdd668200e2762b0a2eaa36af059bad7ee7ae26d3157b1878f97f`; the benchmark JSON output and graph alias checks are asserted on every repetition. The first JSON cursor implementation returned to the browser after each 64-event chunk: one 169 KB run took 24,779 ms with 105,680 charged work units. The VM now permits multiple chunks per run, capped at 16,384 charged native work units while respecting the requested quantum. A single run then took 152–172 ms, and the frozen-artifact warmed median is 113.27 ms. Quantum-one cancellation tests remain separate.

The copy task initially yielded to the browser after every internal graph transition and took 8,808 ms median for the 100-copy workload. Batching up to 64 charged transitions per task step reduced the frozen-artifact median to 1.98 ms. These were measured scheduling defects, not changes to copy semantics.

`random.sample` now uses a sparse partial Fisher–Yates map, so a 25,000-of-100,000 sample takes 25,411 charged work units and a 73.39 ms median with 3 warmups and 10 repetitions. Counted sampling uses a Fenwick tree for logarithmic selection and update. The review repro `sample(range(4*k), k)` at a 1,000-work cap now returns `limit` without output for `k` of 1,000, 10,000, and 25,000; each had reported only 19 work units and completed before the fix. Native and shipping-WASM tests also cover weighted choices, shuffle, bigint rejection sampling, hard limits, cancellation and reset.

## Regex workload and boundedness

`PEONY_BENCH_REGEX=1` measures fixed ASCII sparse (65,520 bytes), Unicode classes (32,000 bytes), dense empty/nonempty alternatives (16 KiB), long no-match (64 KiB), and counted-repeat rejection. Each record includes input SHA-256, instruction/work counts, peak linear memory, median and p95. The ASCII sparse scan was 1,702 ms median before optimization. An exact ASCII Unicode-property fast path changed it to 1,634 ms (4%); a checked codepoint-to-byte offset map removed repeated rescans and reduced the frozen-artifact run to 56.12 ms median / 57.70 ms p95 with the same 529,218 charged work units. Peak linear memory rose by 262,144 bytes for the offset map. Unicode-class median fell from 267.0 to 20.57 ms. The pure and shipping-WASM tests retain capture, empty-match, Unicode/bytes, work-cap and low-memory assertions.

## JSON implementation choice

`zig build bench-json-choice -Doptimize=ReleaseFast` compares an identical 127,474-byte, 1,200-row nested/Unicode/30-digit-integer payload through actual Peony `Value` parse and serialization. The custom scanner emitted byte-identical output to a `std.json.Value` DOM parse → Peony Value → DOM → stringify path on every repetition. With three warmups and ten measured repetitions, custom median/p95 was 284.14/359.00 ms with 1,984,488 peak session bytes; the DOM route was 115.64/122.68 ms with 5,895,076 peak bytes. `std.json.Value` holds the 30-digit integer as `number_string`, so explicit conversion is needed to retain Peony bigint precision. The choice retains the custom native scanner for its roughly threefold lower peak memory, direct token precision and shared resumable cursor, accepting the measured speed cost. The enriched `std.json` DOM parse+serialize WASM probe adds 25,138 raw and 7,642 Brotli quality-11 bytes to the current Peony artifact; its `tools/size-probes/json.zig` source is reviewable.

## SIMD decision

`tools/simd_scan_probe.zig` compares scalar and 16-byte `@Vector` classification of JSON escape/control/non-ASCII bytes. The baseline ReleaseSmall probe used `-mcpu baseline`; the experimental probe used `-mcpu baseline+simd128`. Node's WASM engine produced identical counts for short 8/31-byte strings, an unaligned 65-byte tail, a 136,545-byte learner JSON fixture, and invalid UTF-8 bytes. The code section had zero versus ten SIMD `0xFD` prefixes. Isolated probe raw/Brotli sizes were 1,872/776 versus 1,419/730 bytes. On the long fixture, median classification was 0.2981 ms scalar versus 0.0233 ms vector. That scanner primitive is a small part of the 113.27 ms median end-to-end learner JSON workload; the default Peony artifact remains baseline scalar so its documented browser contract does not require SIMD. The isolated probe is evidence about the candidate primitive, not a claim of end-to-end SIMD acceleration.
