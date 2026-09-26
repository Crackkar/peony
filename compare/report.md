# Peony comparison report

**46/46 cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.

## Inputs

| Input | Value |
|---|---|
| Corpus | v1.0.0, `49b51bc4db386dedc5f1b0c4369abc2441c2d3a90bbb1fb18a2ef694be5952a0` |
| Profile | standard; scale 4; 1 warmup; 3 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony WASM | 1,696,149 bytes; `877eb902d2850701fec6989fbb8035c24cf8b361bc42fd3961c8fdc644ae813b` |
| Host | win32-x64; v24.14.1; Worker load 170.7 ms |

## Aggregate

| Measure | CPython | Peony |
|---|---:|---:|
| Sum of case medians | 3391.3 ms | 19630.0 ms |
| Geometric mean Peony/CPython ratio | 1.00x | 3.46x |

## Case measurements

Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.

### Core language and objects

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 15.52 | 17.55 | 90.12 | 91.13 | 5.81x | 512,052 | 512,053 | 0.01 |
| `big-integers` | 2.959 | 3.024 | 4.050 | 4.108 | 1.37x | 24,047 | 24,048 | 0.01 |
| `floating-point` | 9.732 | 9.995 | 66.38 | 68.99 | 6.82x | 400,101 | 400,117 | 0.01 |
| `control-flow` | 14.35 | 16.21 | 122.8 | 127.8 | 8.56x | 783,791 | 783,792 | 1.93 |
| `functions-closures` | 5.596 | 6.487 | 39.93 | 41.10 | 7.14x | 169,264 | 169,265 | 0.82 |
| `call-binding` | 12.21 | 12.32 | 114.4 | 116.6 | 9.37x | 296,102 | 344,105 | 8.00 |
| `comprehensions` | 4.527 | 4.559 | 15.77 | 15.95 | 3.48x | 135,692 | 139,013 | 0.12 |
| `generators` | 4.563 | 4.735 | 13.62 | 17.78 | 2.99x | 102,047 | 110,050 | 0.50 |
| `classes` | 10.70 | 11.09 | 91.89 | 96.52 | 8.59x | 296,144 | 296,145 | 3.49 |
| `exceptions-context` | 6.560 | 6.722 | 21.81 | 23.08 | 3.32x | 97,837 | 97,838 | 1.40 |
| `pattern-matching` | 24.14 | 26.52 | 250.9 | 285.1 | 10.39x | 1,188,072 | 1,188,110 | 8.00 |
| `decorators-annotations` | 7.079 | 7.234 | 45.96 | 53.84 | 6.49x | 144,055 | 144,056 | 4.58 |
| `iterator-builtins` | 6.301 | 6.434 | 35.45 | 39.51 | 5.63x | 138,207 | 227,370 | 0.21 |
| `unicode-strings` | 4.661 | 4.765 | 17.18 | 17.24 | 3.69x | 83 | 117,703 | 0.75 |
| `bytes-codecs` | 3.096 | 3.432 | 3.434 | 3.917 | 1.11x | 84 | 64,090 | 0.56 |
| `formatting` | 5.781 | 5.957 | 15.95 | 16.18 | 2.76x | 36,865 | 36,866 | 0.64 |
| `list-algorithms` | 18.51 | 20.32 | 172.2 | 183.8 | 9.30x | 301,570 | 961,572 | 1.22 |
| `dict-churn` | 25.93 | 27.61 | 209.2 | 214.1 | 8.07x | 323,125 | 452,132 | 6.72 |
| `set-algebra` | 20.11 | 20.39 | 152.4 | 168.3 | 7.58x | 804,125 | 883,838 | 1.85 |
| `numeric-key-equality` | 15.77 | 17.49 | 139.8 | 148.1 | 8.86x | 376,082 | 424,084 | 8.00 |

### Native libraries

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 13.66 | 13.69 | 93.24 | 95.77 | 6.83x | 296,087 | 385,840 | 2.00 |
| `statistics-data` | 68.49 | 75.55 | 175.6 | 181.3 | 2.56x | 440,121 | 540,146 | 1.42 |
| `json-tree` | 49.50 | 51.70 | 68.91 | 76.86 | 1.39x | 81,307 | 163,829 | 1.74 |
| `json-strings` | 47.06 | 67.93 | 18.24 | 24.16 | 0.39x | 34,091 | 440,223 | 1.95 |
| `csv-reader` | 41.95 | 42.92 | 79.64 | 85.32 | 1.90x | 180,061 | 195,654 | 4.07 |
| `csv-dictionaries` | 43.41 | 46.87 | 53.32 | 70.10 | 1.23x | 131,860 | 142,878 | 2.00 |
| `regex-ascii` | 29.74 | 33.01 | 72.48 | 75.14 | 2.44x | 804 | 93,595 | 0.34 |
| `regex-unicode` | 36.51 | 40.93 | 486.5 | 528.1 | 13.32x | 87 | 765,249 | 1.93 |
| `regex-replacement` | 37.66 | 41.16 | 755.6 | 784.3 | 20.06x | 76,886 | 738,447 | 2.62 |
| `counter` | 17.63 | 19.73 | 44.69 | 47.91 | 2.54x | 113 | 108,127 | 1.30 |
| `defaultdict` | 17.87 | 18.36 | 67.34 | 68.18 | 3.77x | 241,221 | 261,628 | 2.00 |
| `deepcopy-graphs` | 31.91 | 32.55 | 9.910 | 10.69 | 0.31x | 32,911 | 40,913 | 0.87 |
| `pathlib-files` | 1812.1 | 1817.6 | 11.04 | 11.17 | 0.01x | 10,968 | 108,419 | 0.50 |
| `os-files` | 399.4 | 425.9 | 6.620 | 6.696 | 0.02x | 8,288 | 39,379 | 0.27 |
| `random-invariants` | 27.33 | 27.80 | 88.82 | 89.07 | 3.25x | 204,149 | 408,483 | 2.00 |
| `import-packages` | 14.30 | 16.11 | 24.24 | 28.62 | 1.70x | 192,105 | 216,108 | 0.17 |

### Integrated workloads

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 114.2 | 118.6 | 3354.3 | 3534.5 | 29.37x | 880,064 | 5,470,070 | 25.08 |
| `csv-pipeline` | 86.61 | 87.83 | 160.1 | 196.4 | 1.85x | 367,720 | 417,484 | 8.00 |
| `json-pipeline` | 61.13 | 63.77 | 208.2 | 215.9 | 3.41x | 242,160 | 411,335 | 5.33 |
| `log-analysis` | 63.04 | 67.00 | 11275.6 | 11390.9 | 178.86x | 552,071 | 2,555,552 | 16.05 |
| `graph-search` | 34.33 | 34.95 | 277.2 | 284.6 | 8.07x | 758,453 | 777,656 | 8.00 |
| `prime-sieve` | 25.29 | 28.49 | 258.7 | 261.0 | 10.23x | 1,516,384 | 1,569,393 | 0.93 |
| `text-index` | 8.524 | 9.073 | 62.72 | 74.25 | 7.36x | 170,162 | 212,342 | 3.92 |
| `object-dispatch` | 18.12 | 20.21 | 195.8 | 198.5 | 10.81x | 645,103 | 695,109 | 8.00 |
| `file-throughput` | 57.98 | 59.79 | 59.10 | 62.40 | 1.02x | 1,981 | 4,082 | 6.44 |
| `sort-records` | 15.42 | 16.03 | 98.91 | 115.6 | 6.42x | 308,913 | 597,652 | 3.22 |

The runner and interpretation rules are documented in [the comparison corpus guide](README.md).
