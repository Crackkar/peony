# Peony comparison report

**46/46 cases passed each two-way comparison.** Each repetition matched stdout and stderr, with Windows CLI newlines normalized for comparison.

## Inputs

| Input | Value |
|---|---|
| Corpus | v2.0.0; `67a0c74599b83a12b12e01dace75cfa4558a914ede6a10ebcd4109a08ad51a5e` |
| Profile | standard; 1 warmups; 3 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony native | `zig-out/peony.exe`; 2,939,392 bytes; `7d78fd3aef8e9e49c834e5c9f313f1cd34af4565c505a3f8e7290e6571f43db6` |
| Peony WASM | `zig-out/peony.wasm`; 1,715,920 bytes; `892cb5648008dca8da56f6df28f8835f02b535e9d5286e57770fd91c2a26cb23` |
| Host | win32-x64; v24.14.1 |

## One-shot command-line processes

A fresh `python __corpus_case__.py ARG...` or `peony __corpus_case__.py ARG...` process runs for every repetition. The timer spans process creation through exit, including startup, source loading, compilation, execution, and output. Peak RSS belongs to that child process.

| Measure | CPython | Peony native |
|---|---:|---:|
| Sum of case median wall times | 9757.4 ms | 7901.0 ms |
| Geometric mean Peony/CPython wall ratio | 1.00x | 0.69x |
| Geometric mean Peony/CPython peak RSS ratio | 1.00x | 0.83x |

## Started interpreters

A persistent CPython process and a loaded Peony Worker process start before timing each case. Each job receives the same source, arguments, and fixture bytes in fresh program state. CPython times `compile` plus `exec`; Peony times the public `session.run` call, including Worker messaging. Process startup and fixture setup are outside both intervals.

Peak RSS is the full host process resident set during the job. The Peony process includes Node and its Worker; CPython includes its driver. The growth column is peak RSS above the process baseline immediately before the job. Both drivers sample current RSS and check for new OS high-water marks; brief spikes below an earlier high-water mark can fall between samples.

| Measure | CPython | Peony WASM |
|---|---:|---:|
| Sum of case median job times | 3381.1 ms | 4741.2 ms |
| Geometric mean Peony/CPython wall ratio | 1.00x | 3.81x |
| Geometric mean Peony/CPython peak RSS ratio | 1.00x | 5.85x |

## Case measurements

Wall time is median/p95 milliseconds. RSS is the maximum measured peak across samples. Ratios use median wall time. All memory values are MiB.

### Core language and objects: one-shot CLI

| Case | CP ms | Peony ms | P/CP | CP RSS | Peony RSS |
|---|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 147.9/201.8 | 103.9/110.8 | 0.70x | 10.5 | 5.5 |
| `big-integers` | 130.3/131.0 | 59.34/59.71 | 0.46x | 10.4 | 5.5 |
| `floating-point` | 138.3/143.9 | 85.15/108.5 | 0.62x | 10.5 | 5.5 |
| `control-flow` | 139.5/145.4 | 122.0/128.1 | 0.87x | 10.6 | 8.4 |
| `functions-closures` | 146.0/146.9 | 72.02/73.57 | 0.49x | 10.5 | 5.5 |
| `call-binding` | 139.4/140.7 | 142.6/155.5 | 1.02x | 10.5 | 17.6 |
| `comprehensions` | 138.8/182.7 | 70.85/70.90 | 0.51x | 10.6 | 5.7 |
| `generators` | 127.2/135.7 | 65.52/67.15 | 0.52x | 10.6 | 6.3 |
| `classes` | 138.5/141.2 | 111.2/115.7 | 0.80x | 10.5 | 10.2 |
| `exceptions-context` | 132.5/132.8 | 71.64/107.6 | 0.54x | 10.7 | 7.6 |
| `pattern-matching` | 165.3/166.8 | 186.6/187.1 | 1.13x | 10.5 | 13.5 |
| `decorators-annotations` | 132.5/138.4 | 95.68/123.1 | 0.72x | 10.5 | 16.5 |
| `iterator-builtins` | 138.5/154.0 | 75.95/77.15 | 0.55x | 11.1 | 5.9 |
| `unicode-strings` | 145.4/150.2 | 73.33/74.14 | 0.50x | 11.4 | 6.7 |
| `bytes-codecs` | 145.6/148.6 | 59.95/63.95 | 0.41x | 11.1 | 6.5 |
| `formatting` | 144.9/168.9 | 67.19/79.09 | 0.46x | 10.7 | 7.0 |
| `list-algorithms` | 141.4/151.0 | 120.4/121.2 | 0.85x | 11.6 | 7.0 |
| `dict-churn` | 153.9/163.4 | 118.7/122.4 | 0.77x | 15.8 | 15.1 |
| `set-algebra` | 151.4/180.9 | 130.1/136.0 | 0.86x | 13.4 | 8.3 |
| `numeric-key-equality` | 150.2/151.8 | 136.0/247.1 | 0.91x | 12.2 | 18.2 |

### Core language and objects: started interpreters

| Case | CP ms | WASM ms | W/CP | CP RSS | WASM RSS | RSS growth CP/W |
|---|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 16.72/16.77 | 94.21/134.8 | 5.63x | 15.3 | 91.9 | 0.0/3.7 |
| `big-integers` | 1.308/1.325 | 6.172/7.352 | 4.72x | 15.3 | 90.2 | 0.0/2.3 |
| `floating-point` | 9.907/10.81 | 68.81/70.89 | 6.95x | 15.2 | 92.0 | 0.0/3.8 |
| `control-flow` | 14.66/16.15 | 124.6/133.4 | 8.50x | 15.5 | 100.5 | 0.0/10.9 |
| `functions-closures` | 4.928/6.444 | 39.01/39.61 | 7.92x | 15.2 | 91.8 | 0.0/3.8 |
| `call-binding` | 11.62/11.89 | 98.63/120.5 | 8.49x | 15.4 | 103.0 | 0.1/3.2 |
| `comprehensions` | 2.755/3.045 | 17.53/20.46 | 6.36x | 15.4 | 95.2 | 0.1/6.3 |
| `generators` | 2.492/3.237 | 14.96/16.32 | 6.01x | 15.9 | 91.8 | 0.2/3.1 |
| `classes` | 9.878/10.10 | 75.67/77.76 | 7.66x | 15.6 | 100.8 | 0.2/8.8 |
| `exceptions-context` | 4.315/4.499 | 21.68/27.45 | 5.02x | 16.3 | 101.9 | 0.2/12.6 |
| `pattern-matching` | 26.49/29.80 | 240.9/289.6 | 9.09x | 15.4 | 94.1 | 0.0/3.0 |
| `decorators-annotations` | 5.854/7.899 | 42.81/46.42 | 7.31x | 15.7 | 95.9 | 0.2/2.1 |
| `iterator-builtins` | 5.000/5.814 | 37.13/39.04 | 7.43x | 17.9 | 92.4 | 0.9/3.4 |
| `unicode-strings` | 3.450/4.419 | 19.90/20.31 | 5.77x | 16.3 | 92.7 | 0.3/3.5 |
| `bytes-codecs` | 1.260/1.361 | 4.307/9.804 | 3.42x | 15.9 | 92.0 | 0.0/3.3 |
| `formatting` | 4.680/6.371 | 19.71/22.14 | 4.21x | 15.7 | 93.1 | 0.1/3.1 |
| `list-algorithms` | 20.87/21.06 | 162.7/195.5 | 7.80x | 16.6 | 96.9 | 0.1/6.2 |
| `dict-churn` | 23.46/23.91 | 75.74/76.86 | 3.23x | 21.5 | 104.7 | 0.0/5.0 |
| `set-algebra` | 24.15/26.26 | 157.8/159.1 | 6.53x | 18.3 | 94.5 | 0.0/3.3 |
| `numeric-key-equality` | 20.77/20.84 | 107.6/120.1 | 5.18x | 16.4 | 100.1 | 0.1/3.6 |

### Native libraries: one-shot CLI

| Case | CP ms | Peony ms | P/CP | CP RSS | Peony RSS |
|---|---:|---:|---:|---:|---:|
| `math-numeric` | 146.9/197.6 | 104.7/105.5 | 0.71x | 10.5 | 6.1 |
| `statistics-data` | 210.7/211.6 | 106.9/115.0 | 0.51x | 13.7 | 7.2 |
| `json-tree` | 182.6/194.1 | 83.54/108.9 | 0.46x | 13.4 | 9.3 |
| `json-strings` | 177.6/185.0 | 72.17/77.82 | 0.41x | 15.6 | 9.2 |
| `csv-reader` | 176.0/192.0 | 117.2/127.9 | 0.67x | 12.2 | 13.8 |
| `csv-dictionaries` | 170.8/177.7 | 90.15/90.43 | 0.53x | 12.0 | 12.3 |
| `regex-ascii` | 165.3/171.6 | 62.06/62.59 | 0.38x | 11.7 | 6.9 |
| `regex-unicode` | 166.3/189.9 | 126.6/132.3 | 0.76x | 12.8 | 9.0 |
| `regex-replacement` | 175.7/175.7 | 125.5/135.3 | 0.71x | 12.1 | 13.0 |
| `counter` | 147.7/151.0 | 73.75/75.17 | 0.50x | 11.8 | 7.5 |
| `defaultdict` | 147.9/153.8 | 80.36/88.18 | 0.54x | 12.2 | 9.4 |
| `deepcopy-graphs` | 172.2/186.6 | 64.09/66.23 | 0.37x | 11.3 | 7.8 |
| `pathlib-files` | 2083.8/2318.5 | 1826.6/1864.6 | 0.88x | 12.7 | 6.6 |
| `os-files` | 544.0/563.1 | 524.0/545.1 | 0.96x | 10.5 | 6.1 |
| `random-invariants` | 162.3/184.7 | 101.9/105.6 | 0.63x | 12.7 | 9.4 |
| `import-packages` | 160.5/162.9 | 81.14/83.68 | 0.51x | 10.8 | 5.7 |

### Native libraries: started interpreters

| Case | CP ms | WASM ms | W/CP | CP RSS | WASM RSS | RSS growth CP/W |
|---|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 14.38/18.82 | 81.38/82.34 | 5.66x | 15.4 | 96.6 | 0.0/7.1 |
| `statistics-data` | 40.10/41.42 | 98.58/116.5 | 2.46x | 18.5 | 94.3 | 0.7/3.3 |
| `json-tree` | 13.48/15.11 | 33.65/33.74 | 2.50x | 16.9 | 96.7 | 0.0/4.7 |
| `json-strings` | 14.88/16.63 | 21.86/24.71 | 1.47x | 19.0 | 96.4 | 0.9/3.7 |
| `csv-reader` | 16.65/19.72 | 75.58/78.21 | 4.54x | 16.4 | 96.6 | 0.2/3.3 |
| `csv-dictionaries` | 17.60/18.48 | 47.53/69.09 | 2.70x | 16.6 | 99.3 | 0.4/6.6 |
| `regex-ascii` | 1.688/1.837 | 9.001/10.72 | 5.33x | 15.4 | 92.8 | 0.0/3.4 |
| `regex-unicode` | 11.03/11.65 | 108.4/142.3 | 9.83x | 17.1 | 95.2 | 0.2/4.1 |
| `regex-replacement` | 9.574/10.05 | 136.7/148.7 | 14.28x | 16.8 | 96.3 | 0.3/3.3 |
| `counter` | 7.090/10.42 | 24.05/28.86 | 3.39x | 15.7 | 97.0 | 0.0/6.8 |
| `defaultdict` | 7.454/10.85 | 47.86/66.22 | 6.42x | 16.8 | 98.1 | 0.2/6.6 |
| `deepcopy-graphs` | 29.34/33.04 | 12.53/12.95 | 0.43x | 17.6 | 95.8 | 0.6/5.9 |
| `pathlib-files` | 2117.7/2335.6 | 20.06/25.17 | 0.01x | 17.9 | 90.3 | 0.8/7.0 |
| `os-files` | 384.8/432.2 | 15.98/23.23 | 0.04x | 15.6 | 96.3 | 0.1/7.3 |
| `random-invariants` | 25.95/29.93 | 47.95/57.19 | 1.85x | 18.0 | 99.2 | 0.3/6.9 |
| `import-packages` | 14.74/25.17 | 21.11/36.92 | 1.43x | 15.8 | 92.2 | 0.2/3.4 |

### Integrated workloads: one-shot CLI

| Case | CP ms | Peony ms | P/CP | CP RSS | Peony RSS |
|---|---:|---:|---:|---:|---:|
| `word-frequency` | 277.1/291.0 | 721.4/746.1 | 2.60x | 26.5 | 68.8 |
| `csv-pipeline` | 237.8/240.3 | 176.4/222.7 | 0.74x | 13.6 | 23.4 |
| `json-pipeline` | 212.1/217.8 | 131.1/139.8 | 0.62x | 14.7 | 17.8 |
| `log-analysis` | 198.5/233.7 | 405.0/442.5 | 2.04x | 12.6 | 53.6 |
| `graph-search` | 180.2/184.6 | 155.8/165.3 | 0.86x | 12.5 | 18.2 |
| `prime-sieve` | 161.1/163.5 | 163.1/173.0 | 1.01x | 11.1 | 6.8 |
| `text-index` | 141.8/148.7 | 107.0/140.9 | 0.75x | 11.0 | 12.5 |
| `object-dispatch` | 157.3/158.8 | 163.0/165.0 | 1.04x | 11.8 | 17.9 |
| `file-throughput` | 209.4/211.2 | 149.2/161.7 | 0.71x | 12.0 | 11.3 |
| `sort-records` | 144.6/152.3 | 120.1/129.7 | 0.83x | 12.1 | 11.6 |

### Integrated workloads: started interpreters

| Case | CP ms | WASM ms | W/CP | CP RSS | WASM RSS | RSS growth CP/W |
|---|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 135.1/147.2 | 987.2/1002.2 | 7.31x | 29.8 | 125.3 | 4.3/4.0 |
| `csv-pipeline` | 68.10/69.94 | 151.8/153.3 | 2.23x | 18.8 | 107.6 | 0.9/6.7 |
| `json-pipeline` | 27.61/38.86 | 110.2/133.7 | 3.99x | 18.6 | 103.8 | 0.1/6.7 |
| `log-analysis` | 41.47/42.10 | 439.8/451.8 | 10.60x | 16.8 | 114.3 | 0.1/7.1 |
| `graph-search` | 26.42/27.96 | 172.3/219.6 | 6.52x | 16.8 | 103.6 | 0.0/6.6 |
| `prime-sieve` | 29.37/32.30 | 239.2/261.3 | 8.14x | 15.8 | 93.1 | 0.1/4.1 |
| `text-index` | 7.373/7.885 | 61.35/62.97 | 8.32x | 16.4 | 98.4 | 0.2/6.8 |
| `object-dispatch` | 18.21/19.69 | 139.0/142.3 | 7.63x | 20.3 | 110.5 | 1.5/15.3 |
| `file-throughput` | 69.52/84.33 | 100.3/102.3 | 1.44x | 16.9 | 152.0 | 0.6/29.9 |
| `sort-records` | 16.90/19.56 | 108.0/129.0 | 6.39x | 17.2 | 99.3 | 0.1/6.1 |

The [comparison guide](README.md) defines fixtures, commands, output checks, and memory measurement.
