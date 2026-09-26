# Peony comparison corpus

`compare/` is Peony's canonical executable corpus for semantic comparison and performance measurement against CPython 3.12. Every case is a learner program written within Peony's documented language and library surface. The same source bytes, command arguments, and fixture bytes run on both engines. A case succeeds only when both engines complete and produce byte-for-byte identical standard output and standard error on every repetition.

The runner measures those same executions. Correctness and timing therefore cannot drift into separate collections with different inputs. A performance result always carries a differential result, the exact corpus and artifact hashes, the scale, and Peony's internal work and memory counters.

The `.py` files in this directory are interpreter inputs. They are not Peony implementation modules and are never loaded to provide a library feature. Peony's language, objects, and importable utilities remain Zig code in `src/`.

## Corpus shape

[`corpus.json`](corpus.json) is the versioned manifest. Its 46 cases are divided into three groups:

| Group | Purpose | Representative pressure |
|---|---|---|
| `core/` | Language and object semantics in isolation | integer and float operations, control flow, closures, argument binding, comprehensions, generators, classes, exceptions, matching, Unicode, bytes, formatting, lists, dictionaries, sets, and numeric key equality |
| `libraries/` | The native Zig library surface | `math`, `statistics`, `json`, `csv`, `re`, `collections`, `copy`, `pathlib`, `os`, `random`, and VFS package imports |
| `workloads/` | Composed programs that cross subsystem boundaries | word frequency, CSV and JSON pipelines, log analysis, graph search, a prime sieve, text indexing, object dispatch, file throughput, and record sorting |

Cases print compact deterministic summaries rather than their entire generated data. This allows exact comparison without turning console or Worker transfer time into the main workload. Tags in the manifest select related cases across directories. For example, `--filter regex` selects the focused regex cases and the integrated regex workloads.

The manifest can attach fixture files to a case. The runner copies the same bytes into an isolated CPython workspace below ignored `zig-out/compare-work/` and into Peony's `/home` VFS before timing starts. `libraries/import-packages` uses this mechanism to exercise package resolution and relative imports. Each repetition gets a new filesystem, so state from one sample cannot warm or alter the next. The execution workspace is removed when the run ends.

## Running it

Build the shipping artifact first, then run one of the profiles:

```powershell
zig build wasm --summary all
npm run compare:smoke
npm run compare
npm run compare:stress
```

The profiles change the argument passed to every case and the number of repetitions:

| Profile | Scale | Warmups | Measured samples | Use |
|---|---:|---:|---:|---|
| `smoke` | 1 | 0 | 1 | Fast end-to-end semantic gate and harness check |
| `standard` | 4 | 1 | 3 | Normal differential benchmark with a median and useful p95 |
| `stress` | 12 | 1 | 5 | Sustained pressure, larger live data, and repeatability evidence |

Stress is intentionally long. Use a filter while investigating one subsystem:

```powershell
node compare/run.mjs --profile standard --filter json
node compare/run.mjs --profile stress --filter core/list-algorithms --samples 2
node compare/run.mjs --list --filter vfs
```

The runner accepts these controls:

| Option | Meaning |
|---|---|
| `--profile smoke\|standard\|stress` | Select scale and repetition defaults. |
| `--filter TEXT` | Select cases whose id or tag contains the text. |
| `--warmups N`, `--samples N` | Override repetition counts. Warmups still undergo semantic comparison. |
| `--timeout-ms N` | Set the safety timeout for each CPython child execution. |
| `--python PATH` | Select the CPython 3.12 executable. `PEONY_CPYTHON` is the environment equivalent. |
| `--wasm PATH` | Select a Peony artifact. `PEONY_COMPARE_WASM` is the environment equivalent. |
| `--report PATH` | Override the Markdown report path. The default is `compare/report.md`. |
| `--json PATH` | Also write the complete machine-readable report to a chosen path. |
| `--quiet` | Suppress per-case progress on standard error. |

The default artifact is `zig-out/peony.wasm`; the default oracle command is `python`. The runner rejects an oracle outside the CPython 3.12 release line. Every successful run replaces [`report.md`](report.md) with a concise durable account of its inputs, exact comparison result, aggregates, and every case measurement. Standard output contains only a one-line completion summary. Request JSON explicitly when another tool needs every hash and raw field:

```powershell
node compare/run.mjs --profile standard
node compare/run.mjs --profile standard --json zig-out/compare-standard.json
```

The Markdown report is the reviewable repository baseline. Optional JSON and execution work remain in ignored `zig-out/`.

## What is timed

Both sides time source compilation plus program execution. Fixture setup and process or session construction remain outside that interval.

For CPython, each repetition starts a fresh isolated CPython process and prepares a private workspace under `zig-out/compare-work/`. Python process startup, reading the source file, and constructing the capture buffers happen before its internal `perf_counter_ns()` interval. The timed code calls `compile(...)` and `exec(...)` in a fresh `__main__` namespace. Standard output and error are in-memory text buffers. `-I` prevents ambient user configuration from entering the oracle, and `-B` prevents bytecode cache files from changing later samples.

For Peony, the runner loads one WASM artifact into its public Worker facade. Each repetition creates a fresh public session, writes fixtures through the public VFS API, and confirms the session is ready before starting the timer. The timed interval is `session.run(...)`, which includes source transfer, compilation, execution, Worker scheduling, and output delivery. The WASM instance remains in its Worker throughout; the runner does not use the raw ABI or execute WASM on the main thread.

This is a comparison of the execution environments users actually encounter after engine startup. It is not an instruction-per-cycle microbenchmark. CPython is native machine code while Peony is WebAssembly behind a Worker message boundary. Browser, Node, OS, CPU frequency, and background activity affect wall time. Use repeated results on the same machine and artifact to judge a Peony change. The report's artifact and corpus hashes make those inputs explicit.

Every warmup and measured run is checked before its timing is accepted. The runner requires:

1. CPython to complete without an unhandled exception.
2. Peony to return `completed` rather than `error`, `limit`, or `cancelled`.
3. Standard output to match exactly.
4. Standard error to match exactly.
5. Output to remain stable across repetitions.

A mismatch stops the run at the first failing case and shows abbreviated outputs. There is no tolerance mode that can silently benchmark different answers.

## Report contents

The durable Markdown report records the semantic result and the measurements needed to review a baseline:

- corpus version, full corpus hash, selected profile, case count, warmups, and sample count;
- Node, platform, exact CPython version and command;
- WASM path, byte length, SHA-256, and Worker load time;
- CPython and Peony median and nearest-rank p95 compile-plus-run times;
- Peony median instruction and work counts plus maximum observed peak session bytes;
- the per-case ratio of Peony median time to CPython median time;
- totals of case medians and the geometric mean of per-case ratios.

The optional JSON adds each case's tags, arguments, input/output hashes, minimum/maximum times, and raw environment fields for automation.

The aggregate ratio is a compact orientation value. It does not represent one real application because every case receives equal weight. For optimization work, inspect the per-case wall time, ratio, work count, and peak bytes together. A large ratio with little charged work often points to dispatch, callback, allocation, or protocol overhead; large wall time accompanied by proportionally large work can simply describe a deliberately larger algorithm.

## Compatibility choices

The corpus stays inside the admitted surface in [the language contract](../docs/language.md) and [native library contract](../docs/libraries.md). It does not use an absent CPython feature merely to increase breadth. Conversely, it does not normalize observable results after execution. Exact output remains the oracle.

Some Peony behavior is intentionally different from CPython and is tested through common invariants:

- Peony's seeded PRNG stream is stable within a Peony version but does not copy CPython's Mersenne Twister stream. Random workloads compare size, uniqueness, bounds, membership, and permutation properties rather than drawn values.
- Hash seeds and set iteration order need not match. Cases compare equality and membership properties or sort scalar results where ordering is part of presentation.
- Peony's files live in a POSIX-like VFS while CPython uses an isolated host workspace. File cases use relative paths and compare file behavior, contents, and names without printing the host cwd.
- Runtime identity strings such as `sys.version` and `sys.implementation.name` correctly differ and are outside exact-output cases.

Host-backed HTTP, clocks, sleeps, input UI, hard cancellation, memory limits, raw ABI validation, and Worker lifecycle races remain in the integration tests. CPython is not a meaningful oracle for Peony's browser transport policy or terminal host outcomes. The comparison corpus concentrates on deterministic Python-visible computation where the two engines promise the same answer.

## Adding a case

A new case should add one `.py` program below `cases/` and one manifest entry. Keep the program self-contained, deterministic, and scalable through `int(sys.argv[1])`. Use the scale to grow repeated data or work while preserving the same semantic path. Print enough information to catch a wrong result, including lengths and checksums or selected boundary values, but avoid bulk output.

Use only documented Peony syntax and APIs. Avoid elapsed time, object addresses, raw hashes, unordered set rendering, temporary absolute paths, locale data, network services, and implementation-specific exception prose. Catch an expected exception inside the program and print a stable property when error text differs legitimately. If a case needs files or learner modules, add them below `fixtures/` and map their source and relative runtime path in `corpus.json`.

Run the focused smoke case first, then the entire smoke profile, then the standard profile:

```powershell
node compare/run.mjs --profile smoke --filter new-case-id
npm run compare:smoke
npm run compare
```

Change the corpus version when its inputs or comparison meaning change. A report hash still identifies exact bytes, but the human version signals an intentional corpus revision.
