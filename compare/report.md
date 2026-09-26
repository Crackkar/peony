# Peony comparison report

**46/46 cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.

## Inputs

| Input | Value |
|---|---|
| Corpus | v1.0.0, `49b51bc4db386dedc5f1b0c4369abc2441c2d3a90bbb1fb18a2ef694be5952a0` |
| Profile | standard; scale 4; 1 warmup; 3 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony WASM | 1,696,025 bytes; `ead5eb1c693587c7412db011f3b403a99e4786586205c93d869af9b1d845ddf0` |
| Host | win32-x64; v24.14.1; Worker load 174.6 ms |

## Aggregate

| Measure | CPython | Peony |
|---|---:|---:|
| Sum of case medians | 3697.3 ms | 30529.6 ms |
| Geometric mean Peony/CPython ratio | 1.00x | 3.86x |

## Case measurements

Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.

### Core language and objects

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 16.73 | 17.83 | 92.30 | 110.5 | 5.52x | 512,052 | 512,053 | 0.01 |
| `big-integers` | 3.161 | 3.724 | 4.218 | 4.963 | 1.33x | 24,047 | 24,048 | 0.01 |
| `floating-point` | 10.06 | 10.95 | 68.87 | 71.47 | 6.85x | 400,101 | 400,117 | 0.01 |
| `control-flow` | 13.93 | 13.97 | 141.4 | 149.0 | 10.15x | 783,791 | 783,792 | 1.93 |
| `functions-closures` | 5.957 | 7.199 | 43.11 | 45.75 | 7.24x | 169,264 | 169,265 | 0.82 |
| `call-binding` | 12.32 | 12.94 | 105.9 | 123.3 | 8.60x | 296,102 | 344,105 | 8.00 |
| `comprehensions` | 5.439 | 5.783 | 15.37 | 17.04 | 2.83x | 135,692 | 139,013 | 0.12 |
| `generators` | 4.119 | 4.127 | 17.48 | 23.75 | 4.24x | 102,047 | 110,050 | 0.50 |
| `classes` | 10.91 | 12.31 | 103.3 | 113.7 | 9.46x | 296,144 | 296,145 | 3.49 |
| `exceptions-context` | 5.894 | 6.594 | 26.33 | 29.65 | 4.47x | 97,837 | 97,838 | 1.40 |
| `pattern-matching` | 26.03 | 27.88 | 324.8 | 326.8 | 12.48x | 1,188,072 | 1,188,110 | 8.00 |
| `decorators-annotations` | 7.367 | 12.07 | 64.30 | 70.04 | 8.73x | 144,055 | 144,056 | 4.58 |
| `iterator-builtins` | 7.758 | 9.981 | 47.23 | 50.07 | 6.09x | 138,207 | 227,370 | 0.21 |
| `unicode-strings` | 7.415 | 7.831 | 22.96 | 23.07 | 3.10x | 83 | 117,703 | 0.75 |
| `bytes-codecs` | 3.835 | 4.236 | 4.938 | 5.094 | 1.29x | 84 | 64,090 | 0.56 |
| `formatting` | 6.763 | 8.512 | 21.05 | 21.12 | 3.11x | 36,865 | 36,866 | 0.64 |
| `list-algorithms` | 23.04 | 24.12 | 183.5 | 184.4 | 7.96x | 301,570 | 961,572 | 1.22 |
| `dict-churn` | 24.01 | 24.17 | 237.6 | 241.6 | 9.89x | 323,125 | 452,132 | 6.72 |
| `set-algebra` | 23.48 | 25.44 | 193.1 | 195.0 | 8.22x | 804,125 | 883,838 | 1.85 |
| `numeric-key-equality` | 16.96 | 22.62 | 153.6 | 173.3 | 9.06x | 376,082 | 424,084 | 8.00 |

### Native libraries

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 15.48 | 15.58 | 99.18 | 104.3 | 6.40x | 296,087 | 385,840 | 2.00 |
| `statistics-data` | 76.05 | 90.49 | 167.3 | 171.0 | 2.20x | 440,121 | 540,146 | 1.42 |
| `json-tree` | 63.81 | 84.91 | 75.17 | 86.98 | 1.18x | 81,307 | 163,829 | 1.74 |
| `json-strings` | 52.00 | 70.03 | 17.57 | 23.67 | 0.34x | 34,091 | 440,223 | 1.95 |
| `csv-reader` | 49.39 | 50.54 | 104.2 | 124.0 | 2.11x | 180,061 | 195,654 | 4.07 |
| `csv-dictionaries` | 45.47 | 47.67 | 64.35 | 74.39 | 1.42x | 131,860 | 142,878 | 2.00 |
| `regex-ascii` | 30.62 | 30.66 | 10332.7 | 10528.0 | 337.50x | 804 | 93,595 | 0.34 |
| `regex-unicode` | 42.54 | 43.55 | 545.9 | 548.4 | 12.83x | 87 | 765,249 | 1.93 |
| `regex-replacement` | 36.82 | 40.25 | 756.9 | 775.3 | 20.56x | 76,886 | 738,447 | 2.62 |
| `counter` | 18.23 | 31.72 | 35.63 | 42.11 | 1.95x | 113 | 108,127 | 1.30 |
| `defaultdict` | 17.67 | 18.19 | 64.05 | 71.00 | 3.63x | 241,221 | 261,628 | 2.00 |
| `deepcopy-graphs` | 31.26 | 32.84 | 8.521 | 10.94 | 0.27x | 32,911 | 40,913 | 0.87 |
| `pathlib-files` | 1989.4 | 2105.1 | 10.89 | 11.60 | 0.01x | 10,968 | 108,419 | 0.50 |
| `os-files` | 421.9 | 444.7 | 6.881 | 13.81 | 0.02x | 8,288 | 39,379 | 0.27 |
| `random-invariants` | 30.18 | 36.08 | 88.27 | 108.2 | 2.92x | 204,149 | 408,483 | 2.00 |
| `import-packages` | 19.82 | 25.01 | 27.45 | 31.85 | 1.39x | 192,105 | 216,108 | 0.17 |

### Integrated workloads

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 125.1 | 131.0 | 3194.5 | 3546.6 | 25.53x | 880,064 | 5,470,070 | 25.08 |
| `csv-pipeline` | 92.72 | 93.47 | 208.9 | 209.8 | 2.25x | 367,720 | 417,484 | 8.00 |
| `json-pipeline` | 69.57 | 76.44 | 221.7 | 223.8 | 3.19x | 242,160 | 411,335 | 5.33 |
| `log-analysis` | 63.44 | 63.85 | 11647.7 | 12663.3 | 183.60x | 552,071 | 2,555,552 | 16.05 |
| `graph-search` | 36.01 | 39.14 | 261.6 | 267.3 | 7.26x | 758,453 | 777,656 | 8.00 |
| `prime-sieve` | 31.43 | 35.22 | 247.9 | 277.8 | 7.89x | 1,516,384 | 1,569,393 | 0.93 |
| `text-index` | 9.170 | 12.98 | 64.04 | 78.76 | 6.98x | 170,162 | 212,342 | 3.92 |
| `object-dispatch` | 17.26 | 20.68 | 220.9 | 222.0 | 12.79x | 645,103 | 695,109 | 8.00 |
| `file-throughput` | 59.03 | 64.89 | 59.26 | 65.89 | 1.00x | 1,981 | 4,082 | 6.44 |
| `sort-records` | 17.75 | 18.20 | 126.9 | 140.3 | 7.15x | 308,913 | 597,652 | 3.22 |

The runner and interpretation rules are documented in [the comparison corpus guide](README.md).
