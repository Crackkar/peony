# Peony comparison report

**46/46 cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.

## Inputs

| Input | Value |
|---|---|
| Corpus | v1.0.0, `837f8ed1fd1fb1bfc070c35a246e578460ac9b7b2d0b7a29c062bec4fd105df6` |
| Profile | standard; scale 4; 1 warmup; 3 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony WASM | 1,703,964 bytes; `cc3fc8c3be6b5ca5f01bbb183f1fae58bbf2528cb3ef9d1d72b0972fada180ab` |
| Host | win32-x64; v24.14.1; Worker load 193.9 ms |

## Aggregate

| Measure | CPython | Peony |
|---|---:|---:|
| Sum of case medians | 3804.6 ms | 5648.2 ms |
| Geometric mean Peony/CPython ratio | 1.00x | 2.54x |

## Case measurements

Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.

### Core language and objects

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 18.96 | 19.45 | 125.3 | 146.3 | 6.61x | 512,052 | 512,053 | 0.01 |
| `big-integers` | 3.588 | 5.230 | 4.515 | 5.460 | 1.26x | 24,047 | 24,048 | 0.01 |
| `floating-point` | 11.88 | 13.82 | 71.49 | 76.98 | 6.02x | 400,101 | 400,117 | 0.01 |
| `control-flow` | 17.14 | 17.23 | 136.8 | 137.8 | 7.98x | 783,791 | 783,792 | 0.94 |
| `functions-closures` | 7.182 | 8.390 | 43.04 | 46.24 | 5.99x | 169,264 | 169,265 | 0.03 |
| `call-binding` | 14.30 | 15.21 | 110.8 | 147.5 | 7.75x | 296,102 | 344,105 | 8.00 |
| `comprehensions` | 4.825 | 7.343 | 20.63 | 21.66 | 4.28x | 135,692 | 139,013 | 0.11 |
| `generators` | 4.699 | 4.876 | 15.18 | 16.45 | 3.23x | 102,047 | 110,050 | 0.26 |
| `classes` | 12.90 | 13.32 | 94.97 | 102.1 | 7.36x | 296,144 | 296,145 | 2.00 |
| `exceptions-context` | 7.110 | 7.151 | 25.22 | 27.36 | 3.55x | 97,837 | 97,838 | 0.60 |
| `pattern-matching` | 29.32 | 29.84 | 311.5 | 326.7 | 10.63x | 1,188,072 | 1,188,110 | 2.00 |
| `decorators-annotations` | 7.911 | 7.960 | 52.23 | 65.13 | 6.60x | 144,055 | 144,056 | 3.48 |
| `iterator-builtins` | 7.316 | 11.25 | 43.08 | 59.29 | 5.89x | 138,207 | 227,370 | 0.20 |
| `unicode-strings` | 5.542 | 7.240 | 24.99 | 25.82 | 4.51x | 83 | 117,703 | 0.75 |
| `bytes-codecs` | 3.682 | 5.217 | 4.613 | 4.634 | 1.25x | 84 | 64,090 | 0.56 |
| `formatting` | 6.987 | 10.51 | 20.89 | 23.73 | 2.99x | 36,865 | 36,866 | 0.50 |
| `list-algorithms` | 21.44 | 22.81 | 168.8 | 186.5 | 7.87x | 301,570 | 961,572 | 1.20 |
| `dict-churn` | 24.18 | 29.18 | 260.4 | 301.8 | 10.77x | 323,125 | 452,132 | 6.37 |
| `set-algebra` | 23.83 | 26.33 | 198.4 | 244.0 | 8.33x | 804,125 | 883,838 | 1.74 |
| `numeric-key-equality` | 17.35 | 22.92 | 118.0 | 127.2 | 6.80x | 376,082 | 424,084 | 5.31 |

### Native libraries

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 16.71 | 17.11 | 85.99 | 88.19 | 5.15x | 296,087 | 385,840 | 0.33 |
| `statistics-data` | 85.14 | 87.63 | 116.5 | 121.7 | 1.37x | 440,121 | 540,146 | 1.42 |
| `json-tree` | 56.18 | 56.61 | 30.99 | 31.70 | 0.55x | 81,307 | 163,829 | 1.74 |
| `json-strings` | 57.81 | 58.54 | 23.40 | 24.83 | 0.40x | 34,091 | 440,223 | 1.95 |
| `csv-reader` | 47.66 | 48.90 | 88.87 | 100.9 | 1.86x | 180,061 | 195,654 | 2.77 |
| `csv-dictionaries` | 52.61 | 53.51 | 70.06 | 71.43 | 1.33x | 131,860 | 142,878 | 2.00 |
| `regex-ascii` | 37.73 | 39.34 | 11.65 | 13.03 | 0.31x | 804 | 93,595 | 0.37 |
| `regex-unicode` | 42.75 | 46.62 | 114.1 | 131.3 | 2.67x | 87 | 765,249 | 1.93 |
| `regex-replacement` | 44.55 | 45.56 | 135.4 | 141.1 | 3.04x | 76,886 | 738,447 | 2.00 |
| `counter` | 23.62 | 26.35 | 25.32 | 26.29 | 1.07x | 113 | 108,127 | 1.30 |
| `defaultdict` | 21.65 | 22.43 | 72.68 | 72.89 | 3.36x | 241,221 | 261,628 | 1.40 |
| `deepcopy-graphs` | 42.92 | 46.82 | 9.933 | 13.31 | 0.23x | 32,911 | 40,913 | 0.72 |
| `pathlib-files` | 1997.3 | 2020.5 | 10.91 | 12.58 | 0.01x | 10,968 | 108,419 | 0.50 |
| `os-files` | 403.7 | 416.9 | 7.583 | 7.819 | 0.02x | 8,288 | 39,379 | 0.17 |
| `random-invariants` | 30.84 | 32.95 | 58.89 | 67.94 | 1.91x | 204,149 | 408,483 | 2.00 |
| `import-packages` | 16.83 | 17.03 | 27.97 | 29.35 | 1.66x | 192,105 | 216,108 | 0.17 |

### Integrated workloads

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 140.4 | 141.1 | 1012.7 | 1137.1 | 7.21x | 880,064 | 5,470,070 | 20.77 |
| `csv-pipeline` | 98.87 | 106.4 | 198.6 | 204.2 | 2.01x | 367,720 | 417,484 | 8.00 |
| `json-pipeline` | 72.95 | 73.93 | 128.7 | 167.8 | 1.76x | 242,160 | 411,335 | 5.09 |
| `log-analysis` | 73.29 | 74.02 | 533.7 | 545.5 | 7.28x | 552,071 | 2,555,552 | 12.24 |
| `graph-search` | 42.94 | 43.86 | 266.4 | 266.4 | 6.20x | 758,453 | 777,656 | 5.29 |
| `prime-sieve` | 32.26 | 38.59 | 262.3 | 276.6 | 8.13x | 1,516,384 | 1,569,393 | 0.93 |
| `text-index` | 10.48 | 10.48 | 73.98 | 80.69 | 7.06x | 170,162 | 212,342 | 2.00 |
| `object-dispatch` | 24.18 | 25.60 | 188.4 | 206.4 | 7.79x | 645,103 | 695,109 | 3.80 |
| `file-throughput` | 64.54 | 70.86 | 92.41 | 93.71 | 1.43x | 1,981 | 4,082 | 6.43 |
| `sort-records` | 16.68 | 24.13 | 149.7 | 155.7 | 8.98x | 308,913 | 597,652 | 2.64 |

The runner and interpretation rules are documented in [the comparison corpus guide](README.md).
