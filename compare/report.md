# Peony comparison report

**46/46 cases passed each two-way comparison.** Each repetition matched stdout and stderr, with Windows CLI newlines normalized for comparison.

## Inputs

| Input | Value |
|---|---|
| Corpus | v2.1.0; `ffc79ad0921c9ca07243837e73ac39684f2c0e2cbebbcd646b7d010404203687` |
| Profile | standard; 2 warmups; 5 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony native | `zig-out/peony.exe`; 2,939,392 bytes; `7d78fd3aef8e9e49c834e5c9f313f1cd34af4565c505a3f8e7290e6571f43db6` |
| Peony WASM | `zig-out/peony.wasm`; 1,715,920 bytes; `892cb5648008dca8da56f6df28f8835f02b535e9d5286e57770fd91c2a26cb23` |
| Host | win32-x64; v24.14.1 |

## One-shot command-line processes

A fresh `python __corpus_case__.py ARG...` or `peony __corpus_case__.py ARG...` process runs for every repetition. The timer spans process creation through exit, including startup, source loading, compilation, execution, and output. The external Windows probe samples peak working set (RSS) and private committed bytes for that child. An empty script measured through the identical path gives the launch floor; case times are not baseline-subtracted.

| Measure | CPython | Peony native |
|---|---:|---:|
| Sum of case median wall times | 8309.5 ms | 6631.7 ms |
| Geometric mean Peony/CPython wall ratio | 1.00x | 0.68x |
| Geometric mean Peony/CPython peak RSS ratio | 1.00x | 0.83x |
| Geometric mean Peony/CPython peak private ratio | 1.00x | 1.47x |
| Empty-script wall median/p95 | 106.0/109.7 | 45.86/48.03 |
| Empty-script peak RSS | 10.4 MiB | 5.0 MiB |
| Empty-script peak private bytes | 5.7 MiB | 4.0 MiB |

## Started interpreters

A persistent CPython process and a loaded Peony Worker process start before timing each case. Each job receives the same source, arguments, and fixture bytes in fresh program state. CPython times `compile` plus `exec`; Peony times the public `session.run` call, including Worker messaging. Process startup and fixture setup are outside both intervals.

Timing, host RSS, and runtime allocation are separate executions so sampling and CPython `tracemalloc` cannot perturb the reported latency or host footprint. Host RSS includes each complete deployment process: CPython and its driver on one side, Node, V8, the Worker, and WASM on the other. Absolute host RSS is therefore reported without a cross-runtime ratio. Baseline/peak and growth show job pressure within each loaded host. Runtime job memory is CPython traced allocation versus Peony session-accounted growth above its prepared session; WASM linear memory is reported separately.

| Measure | CPython | Peony WASM |
|---|---:|---:|
| Sum of case median job times | 2666.6 ms | 4103.1 ms |
| Geometric mean Peony/CPython wall ratio | 1.00x | 3.90x |
| Median loaded-host baseline RSS | 16.9 MiB | 84.8 MiB |
| Maximum observed host RSS | 31.9 MiB | 153.0 MiB |
| Largest measured job RSS growth | 5.2 MiB | 35.6 MiB |
| Largest runtime-tracked job memory | 12.8 MiB | 20.8 MiB |
| Largest WASM linear memory | — | 40.6 MiB |
| Largest Worker VFS content | — | 0.3 MiB |

## Case measurements

Wall time is median/p95 milliseconds from the timing pass. Host and runtime memory fields come from their separate passes; maxima are reported except baseline RSS, which is the sample median. Ratios use median wall time. All memory values are MiB.

### Core language and objects: one-shot CLI

| Case | CP ms | Peony ms | P/CP | CP RSS | Peony RSS | CP private | Peony private |
|---|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 129.9/172.5 | 89.12/93.51 | 0.69x | 10.5 | 5.5 | 5.7 | 5.7 |
| `big-integers` | 110.2/110.7 | 51.18/52.75 | 0.46x | 10.4 | 5.5 | 5.7 | 4.8 |
| `floating-point` | 118.5/119.2 | 71.39/73.99 | 0.60x | 10.5 | 5.6 | 5.8 | 5.8 |
| `control-flow` | 122.8/125.1 | 95.95/97.00 | 0.78x | 10.7 | 8.6 | 5.9 | 8.9 |
| `functions-closures` | 116.3/120.2 | 61.82/62.71 | 0.53x | 10.5 | 5.5 | 5.7 | 5.7 |
| `call-binding` | 120.1/131.4 | 116.0/126.7 | 0.97x | 10.5 | 17.6 | 5.7 | 16.5 |
| `comprehensions` | 112.3/118.4 | 59.99/60.78 | 0.53x | 10.7 | 5.7 | 5.9 | 6.5 |
| `generators` | 120.4/123.2 | 57.04/76.41 | 0.47x | 10.6 | 6.3 | 5.8 | 6.6 |
| `classes` | 125.2/133.6 | 93.27/93.71 | 0.74x | 10.6 | 10.2 | 5.7 | 10.6 |
| `exceptions-context` | 116.0/123.8 | 63.88/66.28 | 0.55x | 10.7 | 7.6 | 5.8 | 7.8 |
| `pattern-matching` | 136.9/148.3 | 156.4/185.2 | 1.14x | 10.5 | 13.5 | 5.8 | 12.9 |
| `decorators-annotations` | 118.3/124.4 | 83.96/87.64 | 0.71x | 10.6 | 16.6 | 5.8 | 15.8 |
| `iterator-builtins` | 116.5/120.9 | 68.31/72.23 | 0.59x | 11.1 | 5.9 | 5.8 | 6.6 |
| `unicode-strings` | 115.8/126.8 | 64.73/80.00 | 0.56x | 11.4 | 6.7 | 5.7 | 7.0 |
| `bytes-codecs` | 112.8/114.5 | 51.09/58.42 | 0.45x | 11.1 | 6.5 | 5.8 | 7.0 |
| `formatting` | 116.8/126.3 | 58.09/63.28 | 0.50x | 10.7 | 6.9 | 5.8 | 6.7 |
| `list-algorithms` | 126.1/131.6 | 95.26/101.7 | 0.76x | 11.6 | 7.0 | 7.3 | 8.0 |
| `dict-churn` | 139.4/146.3 | 97.56/103.0 | 0.70x | 15.8 | 15.1 | 11.6 | 14.9 |
| `set-algebra` | 132.4/139.1 | 117.1/131.5 | 0.88x | 13.4 | 8.6 | 8.4 | 9.9 |
| `numeric-key-equality` | 123.3/126.3 | 115.9/132.7 | 0.94x | 12.2 | 18.2 | 6.5 | 18.6 |

### Core language and objects: started interpreters

| Case | CP ms | WASM ms | W/CP | CP RSS base/peak | WASM RSS base/peak | RSS growth CP/W | Runtime job CP/W | WASM linear/VFS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 13.83/14.32 | 87.25/88.57 | 6.31x | 16.0/16.0 | 81.2/88.5 | 0.0/7.2 | 0.1/0.0 | 2.2/0.0 |
| `big-integers` | 1.025/1.285 | 4.019/4.337 | 3.92x | 15.9/15.9 | 83.1/88.2 | 0.0/4.7 | 0.1/0.0 | 2.2/0.0 |
| `floating-point` | 8.689/9.259 | 69.18/72.82 | 7.96x | 16.1/16.1 | 81.6/88.9 | 0.0/7.2 | 0.1/0.0 | 2.2/0.0 |
| `control-flow` | 12.64/12.73 | 119.5/135.6 | 9.46x | 16.3/16.9 | 83.0/93.8 | 0.3/10.5 | 0.1/0.9 | 3.8/0.0 |
| `functions-closures` | 3.696/3.857 | 31.55/39.74 | 8.54x | 16.0/16.0 | 84.7/99.1 | 0.0/9.1 | 0.1/0.0 | 2.2/0.0 |
| `call-binding` | 9.744/10.02 | 95.65/104.5 | 9.82x | 16.0/16.0 | 92.6/103.9 | 0.0/11.1 | 0.1/8.0 | 13.1/0.0 |
| `comprehensions` | 2.420/3.457 | 11.90/12.15 | 4.92x | 16.4/16.6 | 82.6/88.7 | 0.1/6.3 | 0.1/0.1 | 2.4/0.0 |
| `generators` | 2.223/2.816 | 10.02/11.03 | 4.51x | 16.3/16.6 | 88.5/94.3 | 0.1/6.0 | 0.1/0.3 | 2.6/0.0 |
| `classes` | 7.900/8.082 | 70.59/74.32 | 8.94x | 16.1/16.1 | 84.8/95.1 | 0.0/10.3 | 0.1/2.0 | 5.3/0.0 |
| `exceptions-context` | 3.817/5.019 | 16.49/19.04 | 4.32x | 16.6/17.2 | 85.8/95.0 | 0.2/12.2 | 0.2/0.6 | 3.0/0.0 |
| `pattern-matching` | 21.55/29.11 | 192.9/210.9 | 8.95x | 16.0/16.0 | 84.7/95.3 | 0.0/10.6 | 0.1/2.0 | 4.7/0.0 |
| `decorators-annotations` | 5.099/5.282 | 44.14/46.15 | 8.66x | 16.0/16.2 | 86.5/101.8 | 0.1/15.3 | 0.1/3.5 | 7.0/0.0 |
| `iterator-builtins` | 4.235/5.362 | 31.17/32.65 | 7.36x | 18.4/20.1 | 82.1/89.4 | 0.6/7.2 | 0.6/0.2 | 2.5/0.0 |
| `unicode-strings` | 2.716/3.096 | 17.90/19.00 | 6.59x | 16.6/16.6 | 84.4/88.7 | 0.0/3.9 | 1.1/0.8 | 3.1/0.0 |
| `bytes-codecs` | 1.070/1.099 | 3.197/3.504 | 2.99x | 16.5/16.5 | 85.2/89.5 | 0.1/2.4 | 0.5/0.6 | 2.9/0.0 |
| `formatting` | 3.756/4.009 | 13.66/14.65 | 3.64x | 16.1/16.1 | 84.5/89.6 | 0.0/4.8 | 0.2/0.5 | 2.8/0.0 |
| `list-algorithms` | 13.75/16.81 | 167.4/170.5 | 12.17x | 17.2/17.4 | 83.4/94.1 | 0.3/10.8 | 1.1/1.2 | 3.9/0.0 |
| `dict-churn` | 19.15/19.56 | 65.76/72.26 | 3.43x | 21.9/21.9 | 92.1/102.8 | 0.0/10.5 | 5.1/6.4 | 13.8/0.0 |
| `set-algebra` | 17.87/19.06 | 129.4/140.0 | 7.24x | 18.9/19.0 | 83.6/86.7 | 0.1/3.0 | 2.7/1.7 | 5.3/0.0 |
| `numeric-key-equality` | 13.23/17.23 | 78.36/94.96 | 5.93x | 17.0/17.0 | 89.4/96.0 | 0.0/6.2 | 0.8/5.3 | 9.8/0.0 |

### Native libraries: one-shot CLI

| Case | CP ms | Peony ms | P/CP | CP RSS | Peony RSS | CP private | Peony private |
|---|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 126.5/134.3 | 82.93/86.20 | 0.66x | 10.5 | 6.1 | 5.7 | 5.9 |
| `statistics-data` | 194.7/205.8 | 92.31/101.8 | 0.47x | 13.8 | 7.2 | 8.2 | 7.9 |
| `json-tree` | 160.8/172.4 | 70.52/82.13 | 0.44x | 13.6 | 9.3 | 8.8 | 8.6 |
| `json-strings` | 161.1/173.9 | 61.04/63.03 | 0.38x | 15.6 | 9.3 | 10.1 | 8.5 |
| `csv-reader` | 153.7/156.0 | 93.91/98.47 | 0.61x | 12.3 | 13.8 | 7.3 | 13.0 |
| `csv-dictionaries` | 156.6/157.3 | 81.43/82.57 | 0.52x | 12.1 | 13.1 | 7.3 | 12.9 |
| `regex-ascii` | 145.1/163.5 | 56.12/61.22 | 0.39x | 11.8 | 6.9 | 7.1 | 7.0 |
| `regex-unicode` | 152.2/167.2 | 99.83/101.0 | 0.66x | 12.9 | 9.1 | 7.4 | 8.9 |
| `regex-replacement` | 150.1/152.6 | 110.5/116.8 | 0.74x | 12.2 | 14.0 | 7.3 | 14.1 |
| `counter` | 128.3/131.0 | 64.27/68.33 | 0.50x | 11.7 | 7.5 | 6.1 | 8.5 |
| `defaultdict` | 128.9/132.3 | 73.21/74.25 | 0.57x | 12.2 | 9.4 | 7.4 | 10.3 |
| `deepcopy-graphs` | 142.9/147.8 | 57.99/60.15 | 0.41x | 11.3 | 8.0 | 6.8 | 8.0 |
| `pathlib-files` | 1781.6/1997.6 | 1517.9/1538.1 | 0.85x | 12.8 | 6.6 | 7.6 | 6.9 |
| `os-files` | 400.8/402.3 | 458.9/512.8 | 1.15x | 10.6 | 6.1 | 5.8 | 6.5 |
| `random-invariants` | 137.0/140.9 | 79.04/81.08 | 0.58x | 12.7 | 9.4 | 7.3 | 10.1 |
| `import-packages` | 130.1/143.9 | 68.50/70.78 | 0.53x | 11.0 | 5.7 | 6.0 | 6.2 |

### Native libraries: started interpreters

| Case | CP ms | WASM ms | W/CP | CP RSS base/peak | WASM RSS base/peak | RSS growth CP/W | Runtime job CP/W | WASM linear/VFS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 11.74/12.55 | 56.35/70.83 | 4.80x | 16.0/16.0 | 83.2/90.0 | 0.0/7.1 | 0.1/0.3 | 2.7/0.0 |
| `statistics-data` | 34.00/35.15 | 89.53/97.03 | 2.63x | 19.2/19.8 | 83.1/90.3 | 0.7/7.2 | 1.3/1.4 | 4.2/0.0 |
| `json-tree` | 10.19/11.08 | 22.19/23.63 | 2.18x | 17.9/18.0 | 84.8/88.3 | 0.1/3.2 | 1.4/1.7 | 5.0/0.0 |
| `json-strings` | 9.759/11.35 | 14.61/15.31 | 1.50x | 18.7/19.6 | 85.7/92.6 | 0.8/4.4 | 3.5/2.0 | 6.3/0.0 |
| `csv-reader` | 12.30/13.29 | 59.32/62.68 | 4.82x | 16.8/17.1 | 85.7/95.4 | 0.2/10.0 | 0.4/2.8 | 6.0/0.0 |
| `csv-dictionaries` | 14.27/19.91 | 46.40/70.91 | 3.25x | 17.2/18.1 | 85.2/95.8 | 0.4/7.5 | 0.4/2.0 | 4.9/0.0 |
| `regex-ascii` | 1.486/1.866 | 7.166/7.364 | 4.82x | 16.2/16.2 | 84.8/87.7 | 0.0/3.8 | 0.1/0.4 | 2.6/0.0 |
| `regex-unicode` | 8.540/11.15 | 109.6/110.9 | 12.83x | 17.8/17.9 | 84.3/88.2 | 0.3/4.0 | 1.1/1.9 | 5.2/0.0 |
| `regex-replacement` | 6.676/6.804 | 106.4/113.5 | 15.94x | 16.9/17.1 | 85.7/91.6 | 0.1/5.8 | 0.4/2.0 | 5.5/0.0 |
| `counter` | 6.168/6.175 | 16.06/16.87 | 2.60x | 16.4/16.4 | 83.5/93.2 | 0.0/7.0 | 0.5/1.3 | 4.3/0.0 |
| `defaultdict` | 6.088/6.483 | 43.72/54.32 | 7.18x | 17.6/17.7 | 84.2/92.9 | 0.3/8.7 | 0.8/1.4 | 4.3/0.0 |
| `deepcopy-graphs` | 24.29/25.31 | 7.616/8.142 | 0.31x | 18.0/19.4 | 83.2/94.3 | 0.6/6.7 | 0.6/0.7 | 3.2/0.0 |
| `pathlib-files` | 1675.8/1721.5 | 16.10/17.75 | 0.01x | 18.1/19.4 | 76.5/91.5 | 0.6/6.9 | 0.8/0.4 | 2.6/0.1 |
| `os-files` | 307.9/356.8 | 10.04/16.67 | 0.03x | 16.2/16.2 | 85.6/92.8 | 0.0/5.3 | 0.1/0.1 | 2.3/0.0 |
| `random-invariants` | 21.11/21.69 | 44.74/50.93 | 2.12x | 18.5/18.7 | 85.7/92.8 | 0.2/7.3 | 1.7/2.0 | 5.6/0.0 |
| `import-packages` | 10.81/11.32 | 16.87/18.82 | 1.56x | 16.3/16.7 | 82.1/94.3 | 0.2/12.3 | 0.1/0.2 | 2.4/0.0 |

### Integrated workloads: one-shot CLI

| Case | CP ms | Peony ms | P/CP | CP RSS | Peony RSS | CP private | Peony private |
|---|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 232.1/235.9 | 575.3/604.7 | 2.48x | 26.8 | 68.0 | 16.6 | 69.1 |
| `csv-pipeline` | 235.4/251.0 | 155.7/161.1 | 0.66x | 13.8 | 23.0 | 8.0 | 23.1 |
| `json-pipeline` | 173.4/179.2 | 107.0/111.3 | 0.62x | 14.7 | 17.9 | 9.1 | 17.8 |
| `log-analysis` | 174.3/185.0 | 358.8/406.6 | 2.06x | 12.8 | 42.3 | 7.7 | 41.2 |
| `graph-search` | 140.7/141.1 | 127.9/157.2 | 0.91x | 12.5 | 17.8 | 7.3 | 17.9 |
| `prime-sieve` | 132.5/136.5 | 132.5/146.3 | 1.00x | 11.1 | 6.8 | 6.2 | 7.3 |
| `text-index` | 121.7/128.5 | 86.37/110.7 | 0.71x | 11.2 | 12.6 | 6.0 | 13.0 |
| `object-dispatch` | 128.7/130.9 | 130.8/131.9 | 1.02x | 11.8 | 17.9 | 7.0 | 17.7 |
| `file-throughput` | 165.4/187.9 | 121.9/124.6 | 0.74x | 12.0 | 11.3 | 8.1 | 11.1 |
| `sort-records` | 124.9/127.1 | 98.98/100.0 | 0.79x | 12.1 | 11.8 | 6.9 | 12.1 |

### Integrated workloads: started interpreters

| Case | CP ms | WASM ms | W/CP | CP RSS base/peak | WASM RSS base/peak | RSS growth CP/W | Runtime job CP/W | WASM linear/VFS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 106.1/126.0 | 880.9/896.1 | 8.30x | 27.0/31.9 | 114.1/117.8 | 5.2/3.7 | 12.8/20.8 | 40.6/0.0 |
| `csv-pipeline` | 47.60/48.24 | 129.1/158.0 | 2.71x | 19.2/19.7 | 93.4/104.5 | 0.5/11.0 | 1.1/8.0 | 13.2/0.0 |
| `json-pipeline` | 21.88/24.01 | 91.23/95.76 | 4.17x | 18.4/18.4 | 90.3/95.8 | 0.0/5.6 | 1.9/5.1 | 10.3/0.0 |
| `log-analysis` | 33.58/50.46 | 389.8/423.4 | 11.61x | 17.2/17.2 | 100.0/111.1 | 0.0/11.3 | 1.0/12.2 | 21.3/0.0 |
| `graph-search` | 19.51/20.82 | 127.9/139.8 | 6.55x | 17.5/17.6 | 89.2/100.0 | 0.0/10.8 | 1.5/5.3 | 9.4/0.0 |
| `prime-sieve` | 22.64/23.52 | 245.0/250.1 | 10.82x | 16.8/17.0 | 82.7/93.9 | 0.1/11.3 | 0.6/0.9 | 3.8/0.0 |
| `text-index` | 6.137/6.714 | 43.65/48.67 | 7.11x | 16.9/16.9 | 85.1/95.7 | 0.1/7.3 | 0.4/2.0 | 4.8/0.0 |
| `object-dispatch` | 14.04/14.36 | 111.0/113.9 | 7.90x | 20.6/24.1 | 88.6/103.9 | 1.2/15.7 | 1.1/3.8 | 7.9/0.0 |
| `file-throughput` | 53.78/69.66 | 72.98/76.12 | 1.36x | 16.9/17.5 | 114.6/153.0 | 0.6/35.6 | 1.8/5.8 | 11.3/0.3 |
| `sort-records` | 11.82/12.46 | 84.68/93.56 | 7.17x | 17.8/17.8 | 86.7/93.2 | 0.0/7.0 | 1.5/2.6 | 6.8/0.0 |

The [comparison guide](README.md) defines fixtures, commands, output checks, and memory measurement.
