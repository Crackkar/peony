# Peony comparison report

**46/46 cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.

## Inputs

| Input | Value |
|---|---|
| Corpus | v1.0.0, `137f1facd69f6253ac0e4d45a5092b9b9264f03e693bb480d2efbe2d65c287d7` |
| Profile | standard; scale 4; 1 warmup; 3 measured samples |
| CPython | Python 3.12.8 via `C:\Users\sanya\AppData\Local\Programs\Python\Python312\python.exe` |
| Peony WASM | 1,701,546 bytes; `ab43710c1e6a80abd38c6aad20b2b41bc6244da0e0035c684e6a5a41ba5d8eaf` |
| Host | win32-x64; v24.14.1; Worker load 217.2 ms |

## Aggregate

| Measure | CPython | Peony |
|---|---:|---:|
| Sum of case medians | 3789.9 ms | 4594.9 ms |
| Geometric mean Peony/CPython ratio | 1.00x | 2.05x |

## Case measurements

Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.

### Core language and objects

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 19.60 | 20.36 | 99.26 | 104.1 | 5.06x | 512,052 | 512,053 | 0.01 |
| `big-integers` | 3.615 | 3.642 | 5.095 | 6.166 | 1.41x | 24,047 | 24,048 | 0.01 |
| `floating-point` | 12.81 | 15.91 | 63.33 | 70.73 | 4.95x | 400,101 | 400,117 | 0.01 |
| `control-flow` | 16.07 | 16.62 | 144.4 | 166.2 | 8.99x | 783,791 | 783,792 | 0.94 |
| `functions-closures` | 6.725 | 7.870 | 33.26 | 45.85 | 4.95x | 169,264 | 169,265 | 0.03 |
| `call-binding` | 18.22 | 19.23 | 111.1 | 132.4 | 6.10x | 296,102 | 344,105 | 8.00 |
| `comprehensions` | 4.862 | 4.985 | 13.06 | 35.16 | 2.69x | 135,692 | 139,013 | 0.11 |
| `generators` | 4.826 | 5.327 | 11.52 | 14.04 | 2.39x | 102,047 | 110,050 | 0.26 |
| `classes` | 11.94 | 16.96 | 79.09 | 93.14 | 6.62x | 296,144 | 296,145 | 2.00 |
| `exceptions-context` | 6.537 | 7.199 | 19.33 | 19.48 | 2.96x | 97,837 | 97,838 | 0.60 |
| `pattern-matching` | 26.57 | 33.55 | 234.8 | 244.4 | 8.84x | 1,188,072 | 1,188,110 | 2.00 |
| `decorators-annotations` | 8.300 | 9.079 | 45.08 | 49.77 | 5.43x | 144,055 | 144,056 | 3.48 |
| `iterator-builtins` | 9.631 | 10.45 | 42.22 | 42.87 | 4.38x | 138,207 | 227,370 | 0.20 |
| `unicode-strings` | 5.458 | 26.81 | 17.42 | 18.32 | 3.19x | 83 | 117,703 | 0.75 |
| `bytes-codecs` | 3.972 | 4.493 | 3.807 | 4.303 | 0.96x | 84 | 64,090 | 0.56 |
| `formatting` | 6.723 | 8.938 | 16.64 | 20.22 | 2.48x | 36,865 | 36,866 | 0.50 |
| `list-algorithms` | 19.06 | 19.51 | 151.1 | 165.9 | 7.93x | 301,570 | 961,572 | 1.20 |
| `dict-churn` | 24.07 | 25.64 | 69.35 | 69.69 | 2.88x | 323,125 | 452,132 | 6.38 |
| `set-algebra` | 23.96 | 27.22 | 162.8 | 185.2 | 6.79x | 804,125 | 883,838 | 1.74 |
| `numeric-key-equality` | 18.21 | 23.43 | 104.8 | 106.1 | 5.76x | 376,082 | 424,084 | 5.31 |

### Native libraries

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 17.79 | 17.88 | 76.37 | 78.47 | 4.29x | 296,087 | 385,840 | 0.33 |
| `statistics-data` | 77.17 | 81.08 | 102.4 | 111.5 | 1.33x | 440,121 | 540,146 | 1.42 |
| `json-tree` | 57.04 | 62.82 | 27.87 | 28.22 | 0.49x | 81,307 | 163,829 | 1.74 |
| `json-strings` | 61.64 | 64.14 | 20.22 | 20.75 | 0.33x | 34,091 | 440,223 | 1.95 |
| `csv-reader` | 49.33 | 53.27 | 71.89 | 82.18 | 1.46x | 180,061 | 195,654 | 2.77 |
| `csv-dictionaries` | 46.32 | 49.46 | 56.75 | 58.03 | 1.23x | 131,860 | 142,878 | 2.00 |
| `regex-ascii` | 33.57 | 34.18 | 9.000 | 9.322 | 0.27x | 804 | 93,595 | 0.37 |
| `regex-unicode` | 47.12 | 71.75 | 111.5 | 117.3 | 2.37x | 87 | 765,249 | 1.93 |
| `regex-replacement` | 46.31 | 50.48 | 119.6 | 126.2 | 2.58x | 76,886 | 738,447 | 2.00 |
| `counter` | 20.46 | 20.48 | 19.59 | 21.59 | 0.96x | 113 | 108,127 | 1.30 |
| `defaultdict` | 19.68 | 23.12 | 45.74 | 46.68 | 2.32x | 241,221 | 261,628 | 1.40 |
| `deepcopy-graphs` | 36.50 | 40.34 | 8.548 | 8.896 | 0.23x | 32,911 | 40,913 | 0.72 |
| `pathlib-files` | 2015.0 | 2083.2 | 10.42 | 11.36 | 0.01x | 10,968 | 108,419 | 0.50 |
| `os-files` | 376.6 | 429.9 | 4.909 | 6.310 | 0.01x | 8,288 | 39,379 | 0.17 |
| `random-invariants` | 28.22 | 28.50 | 51.54 | 58.50 | 1.83x | 204,149 | 408,483 | 2.00 |
| `import-packages` | 14.88 | 16.19 | 19.56 | 22.86 | 1.31x | 192,105 | 216,108 | 0.17 |

### Integrated workloads

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 141.3 | 146.6 | 907.0 | 959.9 | 6.42x | 880,064 | 5,470,070 | 20.77 |
| `csv-pipeline` | 102.3 | 102.7 | 153.6 | 194.7 | 1.50x | 367,720 | 417,484 | 8.00 |
| `json-pipeline` | 69.15 | 69.32 | 103.9 | 114.7 | 1.50x | 242,160 | 411,335 | 5.09 |
| `log-analysis` | 78.81 | 82.31 | 430.4 | 506.9 | 5.46x | 552,071 | 2,555,552 | 12.24 |
| `graph-search` | 36.14 | 47.48 | 160.2 | 176.2 | 4.43x | 758,453 | 777,656 | 5.29 |
| `prime-sieve` | 32.98 | 37.10 | 247.3 | 247.3 | 7.50x | 1,516,384 | 1,569,393 | 0.93 |
| `text-index` | 9.801 | 11.32 | 58.78 | 65.83 | 6.00x | 170,162 | 212,342 | 2.00 |
| `object-dispatch` | 22.83 | 38.96 | 172.2 | 176.0 | 7.54x | 645,103 | 695,109 | 3.80 |
| `file-throughput` | 73.80 | 89.41 | 74.38 | 75.91 | 1.01x | 1,981 | 4,082 | 6.43 |
| `sort-records` | 24.06 | 28.21 | 103.8 | 110.7 | 4.31x | 308,913 | 597,652 | 2.64 |

The runner and interpretation rules are documented in [the comparison corpus guide](README.md).
