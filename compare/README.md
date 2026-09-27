# Peony comparison corpus

`compare/` holds 46 deterministic, scalable Python programs. Every case runs in two separate paired experiments:

1. **One-shot command line:** `python SCRIPT ARG...` against `peony SCRIPT ARG...`. This measures full process lifetime, peak resident memory, and peak private committed bytes for native use. The same probe measures an empty script as a visible launch floor; case results remain end-to-end values.
2. **Started interpreters:** a running CPython process against an already loaded Peony WASM Worker. Separate equivalent executions measure job latency, complete-host RSS, and runtime-accounted allocation after interpreter startup.

Both pairs receive the same source, arguments, and fixture bytes. A sample enters the report only after its pair has completed with matching stdout and stderr. The experiments have different timing boundaries, so their results appear in separate tables. The `.py` case files and [`warm_python.py`](warm_python.py) are corpus inputs and measurement machinery; Peony's language and libraries remain Zig implementations.

## Corpus and profiles

[`corpus.json`](corpus.json) names each case, its tags, scale overrides, and any files it needs. `core/` covers language and objects, `libraries/` covers Zig library APIs, and `workloads/` combines them. Cases print compact summaries so console traffic does not dominate execution. The import case includes package fixture files. File cases create their own files inside private workspaces.

| Profile | Scale | Warmups | Measured samples | Purpose |
|---|---:|---:|---:|---|
| `smoke` | 1 | 0 | 1 | End-to-end correctness and harness check |
| `standard` | 4 | 2 | 5 | Reviewable baseline with median and p95 |
| `stress` | 12 | 2 | 7 | Sustained execution and memory pressure |

Build the artifacts, then run a profile:

```powershell
zig build native
zig build wasm
npm run compare:smoke
npm run compare
npm run compare:stress
```

Use a case ID or tag while investigating one area:

```powershell
node compare/run.mjs --profile smoke --filter pathlib-files
node compare/run.mjs --profile standard --filter regex
node compare/run.mjs --list --filter import
```

`--warmups N` and `--samples N` override the profile counts. `--timeout-ms N` sets each child or job deadline. `--python PATH`, `--native PATH`, and `--wasm PATH` choose artifacts; the corresponding environment variables are `PEONY_CPYTHON`, `PEONY_COMPARE_NATIVE`, and `PEONY_COMPARE_WASM`. `--json PATH` writes the complete machine-readable record. `--report PATH` chooses a Markdown report path. `--quiet` suppresses case progress. A successful unfiltered run updates the tracked [`report.md`](report.md); filtered runs print their selected cases and leave that baseline intact unless `--report` is explicit.

The runner requires Windows, CPython 3.12, and the Peony v0.1 native executable. Its disposable workspaces and compiled process probe live under ignored `zig-out/`. The runner removes each run workspace after completion.

## One-shot command-line experiment

Each repetition prepares two independent OS directories with identical script and fixture bytes. A small C launcher, [`process_probe.c`](process_probe.c), starts each command and records elapsed time from just before Windows process creation until process exit. It polls the child working set and private committed bytes, retains the OS peak working set, and passes program stdout and stderr through unchanged. The probe compiles through `zig cc` when its source changes. Its own startup and memory are outside the recorded child measurement.

The commands launch the interpreter with the script path and case arguments. CPython receives deterministic UTF-8 and hash settings through its environment; bytecode cache writes are disabled. Peony uses its ordinary CLI invocation. Timed work includes interpreter startup, source loading, compilation, program execution, filesystem operations, output, and shutdown. Peak RSS includes resident shared pages; peak private bytes expose private process commitment. Neither is subtracted from the empty-script floor.

Windows CPython translates terminal newlines to CRLF while Peony currently emits LF. The harness normalizes CRLF to LF for the CLI output comparison only; the process measurements retain the real execution. Other output bytes must agree. Each pair also has to produce stable output across repetitions.

## Started-interpreter experiment

For each case and measurement kind, the runner starts one isolated CPython driver and one Node process that loads Peony into a Worker. Both are ready before measured jobs begin. Each repetition gets fresh program state and private fixture storage. The CPython driver executes the source with `compile` and `exec` in a new `__main__` namespace and captures Python stdout and stderr. It runs with `-X utf8` so `pathlib` and `open()` use the same UTF-8 default as the direct CLI experiment even under isolated mode. The Peony driver creates a new public session and installs fixtures before `session.run(source, { filename, argv })`.

The latency pass has no memory sampler or allocation tracer. Its CPython timer covers compilation and execution inside the started process. Its Peony timer covers the public run call, including caller-to-Worker messages, compilation, execution, scheduling, and output delivery. Protocol requests, process startup, session construction, fixture preparation, and post-run statistics remain outside both timers.

The RSS pass repeats the same jobs with sampling enabled. It reports the whole host process: the CPython driver on one side and Node, V8, the Worker, and WASM on the other. The report shows baseline, peak, and growth within each host but deliberately gives no CPython/Peony absolute RSS ratio. A browser already has its own host baseline, and treating Node's baseline as Peony engine memory would be false. Short spikes below an earlier process high-water mark can still fall between samples.

The runtime-allocation pass repeats the jobs again. CPython uses `tracemalloc` only in this pass; Peony reads session allocator counters without tracing. The report shows CPython traced job allocation, Peony session growth above its prepared baseline, WASM linear-memory capacity, and Worker VFS content. These counters have different allocator boundaries and remain diagnostic rather than a claim that the two heaps are structurally identical.

Every pass compares stdout and stderr on every repetition. Case-local Python modules are cleared between CPython jobs so imports begin in fresh program state, as they do in each Peony session. The CPython file cases use the host filesystem while WASM file cases use Worker memory; their latency describes the intended host paths and is not a storage-medium microbenchmark.

## Reading the report

The durable report records the corpus and artifact hashes, host identity, paired correctness result, median and nearest-rank p95 time, and per-case Peony/CPython timing ratios. Native tables add peak RSS and private commitment ratios because both values belong directly to the launched interpreter process. Started-interpreter tables keep whole-host RSS, runtime allocation, WASM capacity, and VFS content separate. A sum of case medians and a geometric mean are orientation measures; no single application assigns equal weight to all 46 cases.

The corpus covers deterministic Python-visible work. HTTP transport, clocks, input callbacks, browser cancellation, terminal failures, and OS-specific behavior have their own integration tests. Add a case by writing one `.py` program under `cases/`, adding a manifest entry, and including fixture files when necessary. Keep outputs compact and deterministic. Bump the corpus version when its inputs or measurement meaning change.
