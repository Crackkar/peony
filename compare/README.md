# Peony comparison corpus

`compare/` holds 46 deterministic, scalable Python programs. Every case runs in two separate paired experiments:

1. **One-shot command line:** `python SCRIPT ARG...` against `peony SCRIPT ARG...`. This measures full process lifetime and peak resident memory for native use.
2. **Started interpreters:** a running CPython process against an already loaded Peony WASM Worker. This measures the time and peak resident memory needed to handle a program job after interpreter startup.

Both pairs receive the same source, arguments, and fixture bytes. A sample enters the report only after its pair has completed with matching stdout and stderr. The experiments have different timing boundaries, so their results appear in separate tables. The `.py` case files and [`warm_python.py`](warm_python.py) are corpus inputs and measurement machinery; Peony's language and libraries remain Zig implementations.

## Corpus and profiles

[`corpus.json`](corpus.json) names each case, its tags, scale overrides, and any files it needs. `core/` covers language and objects, `libraries/` covers Zig library APIs, and `workloads/` combines them. Cases print compact summaries so console traffic does not dominate execution. The import case includes package fixture files. File cases create their own files inside private workspaces.

| Profile | Scale | Warmups | Measured samples | Purpose |
|---|---:|---:|---:|---|
| `smoke` | 1 | 0 | 1 | End-to-end correctness and harness check |
| `standard` | 4 | 1 | 3 | Reviewable baseline with median and p95 |
| `stress` | 12 | 1 | 5 | Sustained execution and memory pressure |

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

The runner requires CPython 3.12 and the Peony v0.1 native executable. Its disposable workspaces and compiled process probe live under ignored `zig-out/`. The runner removes each run workspace after completion.

## One-shot command-line experiment

Each repetition prepares two independent OS directories with identical script and fixture bytes. A small C launcher, [`process_probe.c`](process_probe.c), starts each command and records elapsed time from just before process creation until process exit. It passes program stdout and stderr through unchanged. On Windows it reads the child's peak working set; on Unix it uses the child resource usage returned by `wait4`. The probe compiles through `zig cc` when its source changes. Its own startup and memory are outside the recorded child measurement.

The commands launch the interpreter with the script path and case arguments. CPython receives deterministic UTF-8 and hash settings through its environment; bytecode cache writes are disabled. Peony uses its ordinary CLI invocation. Timed work includes interpreter startup, source loading, compilation, program execution, filesystem operations, output, and shutdown. The reported peak RSS belongs to the Python or Peony process itself.

Windows CPython translates terminal newlines to CRLF while Peony currently emits LF. The harness normalizes CRLF to LF for the CLI output comparison only; the process measurements retain the real execution. Other output bytes must agree. Each pair also has to produce stable output across repetitions.

## Started-interpreter experiment

For each case, the runner starts one isolated CPython driver and one Node process that loads Peony into a Worker. Both are ready before measured jobs begin. Each repetition gets fresh program state and private fixture storage. The CPython driver executes the source with `compile` and `exec` in a new `__main__` namespace and captures Python stdout and stderr. It runs with `-X utf8` so `pathlib` and `open()` use the same UTF-8 default as the direct CLI experiment even under isolated mode. The Peony driver creates a new public session and installs fixtures in Worker storage before timing `session.run(source, { filename, argv })`.

The CPython timer covers compilation and execution inside the started process. The Peony timer covers the public run call, including page-to-Worker messages, compilation, execution, scheduling, and output delivery. Protocol requests to the two measurement drivers, process startup, session construction, fixture preparation, and post-run statistics are outside these intervals. Each repetition compares the two captured streams exactly. Case-local Python modules are cleared between CPython jobs so package imports begin in fresh program state, as they do in each Peony session.

Peak RSS is reported for each **host process** during a job. A CPython background sampler and the WASM driver's Node timer read current resident memory about every millisecond; both also check whether the OS process high-water mark advanced during the job. The Peony figure includes Node and the Worker. The report gives absolute peak and growth above resident memory immediately before each job. A short spike below an earlier lifetime high-water mark can fall between samples. These are deployment-level memory numbers, not WASM linear-memory allocation. The optional JSON retains Peony instruction, work, and session-memory counters for engine-level inspection.

## Reading the report

The durable report records the corpus and artifact hashes, host identity, paired correctness result, median and nearest-rank p95 time, peak RSS, and per-case Peony/CPython timing ratios. It gives separate aggregate timing and RSS ratios for one-shot CLI and started-interpreter use. A sum of case medians and a geometric mean are orientation measures; no single application assigns equal weight to all 46 cases. Review a case's output agreement, wall time, peak RSS, and usage shape together before drawing a performance conclusion.

The corpus covers deterministic Python-visible work. HTTP transport, clocks, input callbacks, browser cancellation, terminal failures, and OS-specific behavior have their own integration tests. Add a case by writing one `.py` program under `cases/`, adding a manifest entry, and including fixture files when necessary. Keep outputs compact and deterministic. Bump the corpus version when its inputs or measurement meaning change.
