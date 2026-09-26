# Peony comparison report

**46/46 cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.

## Inputs

| Input | Value |
|---|---|
| Corpus | v1.0.0, `49b51bc4db386dedc5f1b0c4369abc2441c2d3a90bbb1fb18a2ef694be5952a0` |
| Profile | standard; scale 4; 1 warmup; 3 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony WASM | 1,696,152 bytes; `646385c274de6a9c3192da7e448f7c2bf236d167825b015af9da6d6579569a32` |
| Host | win32-x64; v24.14.1; Worker load 165.4 ms |

## Aggregate

| Measure | CPython | Peony |
|---|---:|---:|
| Sum of case medians | 3364.2 ms | 15109.2 ms |
| Geometric mean Peony/CPython ratio | 1.00x | 2.89x |

## Case measurements

Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.

### Core language and objects

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 16.27 | 18.42 | 86.02 | 88.60 | 5.29x | 512,052 | 512,053 | 0.01 |
| `big-integers` | 3.344 | 3.393 | 4.093 | 4.188 | 1.22x | 24,047 | 24,048 | 0.01 |
| `floating-point` | 9.829 | 10.13 | 67.27 | 69.37 | 6.84x | 400,101 | 400,117 | 0.01 |
| `control-flow` | 14.29 | 16.54 | 123.3 | 136.2 | 8.63x | 783,791 | 783,792 | 1.93 |
| `functions-closures` | 5.663 | 6.010 | 43.20 | 46.45 | 7.63x | 169,264 | 169,265 | 0.82 |
| `call-binding` | 11.74 | 11.79 | 104.5 | 130.8 | 8.90x | 296,102 | 344,105 | 8.00 |
| `comprehensions` | 4.143 | 4.303 | 14.09 | 16.24 | 3.40x | 135,692 | 139,013 | 0.12 |
| `generators` | 4.057 | 4.404 | 14.13 | 16.00 | 3.48x | 102,047 | 110,050 | 0.50 |
| `classes` | 10.07 | 10.39 | 86.31 | 90.50 | 8.57x | 296,144 | 296,145 | 3.49 |
| `exceptions-context` | 5.765 | 6.887 | 25.35 | 27.07 | 4.40x | 97,837 | 97,838 | 1.40 |
| `pattern-matching` | 23.50 | 26.98 | 293.1 | 306.5 | 12.47x | 1,188,072 | 1,188,110 | 8.00 |
| `decorators-annotations` | 7.036 | 8.902 | 52.46 | 55.73 | 7.46x | 144,055 | 144,056 | 4.58 |
| `iterator-builtins` | 7.012 | 7.345 | 41.80 | 42.92 | 5.96x | 138,207 | 227,370 | 0.21 |
| `unicode-strings` | 4.604 | 4.963 | 16.60 | 18.63 | 3.60x | 83 | 117,703 | 0.75 |
| `bytes-codecs` | 3.169 | 3.757 | 3.360 | 4.329 | 1.06x | 84 | 64,090 | 0.56 |
| `formatting` | 6.452 | 6.853 | 15.85 | 16.21 | 2.46x | 36,865 | 36,866 | 0.64 |
| `list-algorithms` | 16.12 | 18.19 | 161.3 | 166.1 | 10.00x | 301,570 | 961,572 | 1.22 |
| `dict-churn` | 20.90 | 21.23 | 206.2 | 211.7 | 9.87x | 323,125 | 452,132 | 6.72 |
| `set-algebra` | 20.80 | 21.58 | 170.3 | 176.3 | 8.19x | 804,125 | 883,838 | 1.85 |
| `numeric-key-equality` | 15.18 | 16.12 | 120.4 | 133.3 | 7.94x | 376,082 | 424,084 | 8.00 |

### Native libraries

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 13.93 | 14.13 | 90.29 | 90.73 | 6.48x | 296,087 | 385,840 | 2.00 |
| `statistics-data` | 69.88 | 74.85 | 105.6 | 110.8 | 1.51x | 440,121 | 540,146 | 1.42 |
| `json-tree` | 54.17 | 75.21 | 35.25 | 36.46 | 0.65x | 81,307 | 163,829 | 1.74 |
| `json-strings` | 45.32 | 46.29 | 18.67 | 21.67 | 0.41x | 34,091 | 440,223 | 1.95 |
| `csv-reader` | 40.75 | 41.63 | 79.08 | 80.86 | 1.94x | 180,061 | 195,654 | 4.07 |
| `csv-dictionaries` | 44.14 | 46.97 | 54.74 | 58.92 | 1.24x | 131,860 | 142,878 | 2.00 |
| `regex-ascii` | 29.26 | 30.44 | 7.507 | 9.354 | 0.26x | 804 | 93,595 | 0.34 |
| `regex-unicode` | 42.73 | 45.53 | 102.3 | 103.9 | 2.39x | 87 | 765,249 | 1.93 |
| `regex-replacement` | 39.79 | 40.37 | 392.7 | 415.5 | 9.87x | 76,886 | 738,447 | 2.62 |
| `counter` | 19.29 | 21.05 | 17.81 | 20.17 | 0.92x | 113 | 108,127 | 1.30 |
| `defaultdict` | 16.53 | 17.16 | 65.82 | 68.08 | 3.98x | 241,221 | 261,628 | 2.00 |
| `deepcopy-graphs` | 31.43 | 33.29 | 9.661 | 11.01 | 0.31x | 32,911 | 40,913 | 0.87 |
| `pathlib-files` | 1774.1 | 1985.5 | 9.779 | 11.17 | 0.01x | 10,968 | 108,419 | 0.50 |
| `os-files` | 390.8 | 399.6 | 7.084 | 7.185 | 0.02x | 8,288 | 39,379 | 0.27 |
| `random-invariants` | 26.08 | 28.97 | 61.38 | 61.87 | 2.35x | 204,149 | 408,483 | 2.00 |
| `import-packages` | 13.85 | 14.59 | 20.33 | 24.13 | 1.47x | 192,105 | 216,108 | 0.17 |

### Integrated workloads

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 117.1 | 155.1 | 905.0 | 940.5 | 7.73x | 880,064 | 5,470,070 | 25.08 |
| `csv-pipeline` | 89.72 | 96.92 | 184.5 | 195.2 | 2.06x | 367,720 | 417,484 | 8.00 |
| `json-pipeline` | 71.99 | 77.59 | 116.4 | 120.1 | 1.62x | 242,160 | 411,335 | 5.33 |
| `log-analysis` | 62.88 | 65.91 | 10205.0 | 11151.2 | 162.30x | 552,071 | 2,555,552 | 16.05 |
| `graph-search` | 31.28 | 32.10 | 252.0 | 287.5 | 8.06x | 758,453 | 777,656 | 8.00 |
| `prime-sieve` | 24.69 | 38.16 | 255.5 | 263.0 | 10.35x | 1,516,384 | 1,569,393 | 0.93 |
| `text-index` | 8.560 | 8.724 | 82.17 | 82.96 | 9.60x | 170,162 | 212,342 | 3.92 |
| `object-dispatch` | 18.68 | 19.02 | 203.6 | 208.4 | 10.89x | 645,103 | 695,109 | 8.00 |
| `file-throughput` | 62.24 | 63.69 | 60.87 | 69.47 | 0.98x | 1,981 | 4,082 | 6.44 |
| `sort-records` | 15.04 | 16.50 | 116.5 | 116.5 | 7.75x | 308,913 | 597,652 | 3.22 |

The runner and interpretation rules are documented in [the comparison corpus guide](README.md).
