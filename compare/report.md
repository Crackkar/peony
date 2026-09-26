# Peony comparison report

**46/46 cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.

## Inputs

| Input | Value |
|---|---|
| Corpus | v1.0.0, `137f1facd69f6253ac0e4d45a5092b9b9264f03e693bb480d2efbe2d65c287d7` |
| Profile | standard; scale 4; 1 warmup; 3 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony WASM | 1,698,803 bytes; `937eac472dcd2ecc1f03096e7d7886a55821a529d6120dcf6a6b778bcf253b14` |
| Host | win32-x64; v24.14.1; Worker load 193.6 ms |

## Aggregate

| Measure | CPython | Peony |
|---|---:|---:|
| Sum of case medians | 3793.5 ms | 4969.6 ms |
| Geometric mean Peony/CPython ratio | 1.00x | 2.24x |

## Case measurements

Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.

### Core language and objects

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 18.73 | 19.68 | 93.10 | 127.8 | 4.97x | 512,052 | 512,053 | 0.01 |
| `big-integers` | 3.367 | 4.005 | 4.893 | 6.524 | 1.45x | 24,047 | 24,048 | 0.01 |
| `floating-point` | 15.13 | 18.72 | 73.51 | 76.08 | 4.86x | 400,101 | 400,117 | 0.01 |
| `control-flow` | 16.57 | 17.48 | 134.1 | 166.4 | 8.09x | 783,791 | 783,792 | 0.94 |
| `functions-closures` | 6.745 | 6.877 | 41.89 | 42.75 | 6.21x | 169,264 | 169,265 | 0.03 |
| `call-binding` | 16.13 | 16.44 | 128.1 | 150.7 | 7.94x | 296,102 | 344,105 | 8.00 |
| `comprehensions` | 5.062 | 7.384 | 18.63 | 20.49 | 3.68x | 135,692 | 139,013 | 0.11 |
| `generators` | 5.196 | 5.626 | 15.45 | 18.11 | 2.97x | 102,047 | 110,050 | 0.26 |
| `classes` | 12.48 | 13.27 | 91.28 | 92.56 | 7.32x | 296,144 | 296,145 | 2.00 |
| `exceptions-context` | 8.242 | 9.369 | 24.08 | 28.55 | 2.92x | 97,837 | 97,838 | 0.60 |
| `pattern-matching` | 27.68 | 33.90 | 261.7 | 280.0 | 9.46x | 1,188,072 | 1,188,110 | 2.00 |
| `decorators-annotations` | 7.847 | 8.671 | 54.19 | 65.07 | 6.91x | 144,055 | 144,056 | 3.48 |
| `iterator-builtins` | 7.920 | 8.076 | 42.12 | 43.50 | 5.32x | 138,207 | 227,370 | 0.20 |
| `unicode-strings` | 5.511 | 5.978 | 20.93 | 21.25 | 3.80x | 83 | 117,703 | 0.75 |
| `bytes-codecs` | 3.476 | 4.225 | 4.401 | 4.754 | 1.27x | 84 | 64,090 | 0.56 |
| `formatting` | 7.240 | 7.792 | 18.09 | 19.86 | 2.50x | 36,865 | 36,866 | 0.50 |
| `list-algorithms` | 25.71 | 30.89 | 179.7 | 185.9 | 6.99x | 301,570 | 961,572 | 1.20 |
| `dict-churn` | 26.42 | 27.02 | 100.4 | 104.1 | 3.80x | 323,125 | 452,132 | 6.37 |
| `set-algebra` | 24.89 | 26.81 | 182.1 | 188.7 | 7.32x | 804,125 | 883,838 | 1.74 |
| `numeric-key-equality` | 16.61 | 22.22 | 127.6 | 132.1 | 7.68x | 376,082 | 424,084 | 5.31 |

### Native libraries

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 16.42 | 16.55 | 90.66 | 91.54 | 5.52x | 296,087 | 385,840 | 0.33 |
| `statistics-data` | 82.94 | 84.42 | 112.6 | 116.1 | 1.36x | 440,121 | 540,146 | 1.42 |
| `json-tree` | 55.77 | 63.16 | 30.97 | 36.59 | 0.56x | 81,307 | 163,829 | 1.74 |
| `json-strings` | 55.82 | 60.59 | 20.64 | 24.92 | 0.37x | 34,091 | 440,223 | 1.95 |
| `csv-reader` | 53.34 | 58.95 | 84.99 | 86.10 | 1.59x | 180,061 | 195,654 | 2.77 |
| `csv-dictionaries` | 52.83 | 55.36 | 62.74 | 62.97 | 1.19x | 131,860 | 142,878 | 2.00 |
| `regex-ascii` | 39.00 | 40.86 | 10.75 | 10.78 | 0.28x | 804 | 93,595 | 0.37 |
| `regex-unicode` | 47.93 | 50.50 | 119.2 | 134.8 | 2.49x | 87 | 765,249 | 1.93 |
| `regex-replacement` | 51.20 | 56.56 | 148.7 | 167.5 | 2.90x | 76,886 | 738,447 | 2.00 |
| `counter` | 21.95 | 26.34 | 19.73 | 25.98 | 0.90x | 113 | 108,127 | 1.30 |
| `defaultdict` | 23.54 | 28.63 | 48.96 | 57.23 | 2.08x | 241,221 | 261,628 | 1.40 |
| `deepcopy-graphs` | 36.43 | 38.57 | 10.41 | 11.70 | 0.29x | 32,911 | 40,913 | 0.72 |
| `pathlib-files` | 1959.0 | 1978.5 | 12.25 | 13.63 | 0.01x | 10,968 | 108,419 | 0.50 |
| `os-files` | 397.2 | 436.3 | 7.297 | 7.447 | 0.02x | 8,288 | 39,379 | 0.17 |
| `random-invariants` | 34.20 | 34.53 | 53.13 | 57.04 | 1.55x | 204,149 | 408,483 | 2.00 |
| `import-packages` | 15.23 | 16.35 | 23.02 | 26.12 | 1.51x | 192,105 | 216,108 | 0.17 |

### Integrated workloads

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 149.8 | 153.0 | 915.1 | 1032.7 | 6.11x | 880,064 | 5,470,070 | 20.77 |
| `csv-pipeline` | 95.02 | 108.4 | 165.4 | 201.4 | 1.74x | 367,720 | 417,484 | 8.00 |
| `json-pipeline` | 73.45 | 75.86 | 102.5 | 113.9 | 1.39x | 242,160 | 411,335 | 5.09 |
| `log-analysis` | 75.39 | 77.55 | 449.0 | 451.9 | 5.96x | 552,071 | 2,555,552 | 12.24 |
| `graph-search` | 40.29 | 45.15 | 186.0 | 186.6 | 4.62x | 758,453 | 777,656 | 5.29 |
| `prime-sieve` | 33.36 | 37.62 | 272.1 | 308.3 | 8.16x | 1,516,384 | 1,569,393 | 0.93 |
| `text-index` | 10.56 | 11.25 | 63.13 | 68.55 | 5.98x | 170,162 | 212,342 | 2.00 |
| `object-dispatch` | 21.51 | 22.44 | 162.0 | 178.1 | 7.53x | 645,103 | 695,109 | 3.80 |
| `file-throughput` | 69.79 | 72.67 | 67.23 | 68.35 | 0.96x | 1,981 | 4,082 | 6.43 |
| `sort-records` | 20.54 | 25.72 | 114.9 | 118.5 | 5.59x | 308,913 | 597,652 | 2.64 |

The runner and interpretation rules are documented in [the comparison corpus guide](README.md).
