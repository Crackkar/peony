# Peony comparison report

**46/46 cases matched CPython exactly.** Every measured repetition completed on both engines with identical standard output and standard error.

## Inputs

| Input | Value |
|---|---|
| Corpus | v1.0.0, `49b51bc4db386dedc5f1b0c4369abc2441c2d3a90bbb1fb18a2ef694be5952a0` |
| Profile | standard; scale 4; 1 warmup; 3 measured samples |
| CPython | Python 3.12.8 via `python` |
| Peony WASM | 1,693,776 bytes; `b97d92dc182c4f7c01920966b0e688f5797ad3c24cb36b8518ff40f542ec72d2` |
| Host | win32-x64; v24.14.1; Worker load 153.4 ms |

## Aggregate

| Measure | CPython | Peony |
|---|---:|---:|
| Sum of case medians | 2978.4 ms | 64786.1 ms |
| Geometric mean Peony/CPython ratio | 1.00x | 5.12x |

## Case measurements

Times are compile plus execution milliseconds. p95 uses the nearest-rank sample. Instructions, work, and peak session memory are Peony counters.

### Core language and objects

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `integer-arithmetic` | 15.42 | 16.78 | 89.70 | 100.3 | 5.82x | 512,052 | 512,053 | 0.01 |
| `big-integers` | 3.130 | 3.187 | 3.932 | 4.263 | 1.26x | 24,047 | 24,048 | 0.01 |
| `floating-point` | 9.845 | 10.10 | 73.74 | 78.64 | 7.49x | 400,101 | 400,117 | 0.01 |
| `control-flow` | 13.72 | 14.37 | 135.3 | 143.0 | 9.86x | 783,791 | 783,792 | 1.93 |
| `functions-closures` | 5.463 | 5.529 | 41.83 | 42.72 | 7.66x | 169,264 | 169,265 | 0.82 |
| `call-binding` | 11.26 | 11.62 | 97.54 | 99.32 | 8.67x | 296,102 | 344,105 | 8.00 |
| `comprehensions` | 4.420 | 4.615 | 12.58 | 12.71 | 2.85x | 135,692 | 139,013 | 0.12 |
| `generators` | 4.191 | 4.354 | 11.66 | 11.72 | 2.78x | 102,047 | 110,050 | 0.50 |
| `classes` | 10.31 | 10.43 | 72.52 | 87.02 | 7.03x | 296,144 | 296,145 | 3.49 |
| `exceptions-context` | 5.315 | 5.956 | 18.56 | 18.76 | 3.49x | 97,837 | 97,838 | 1.40 |
| `pattern-matching` | 23.08 | 26.55 | 227.9 | 262.8 | 9.87x | 1,188,072 | 1,188,102 | 8.00 |
| `decorators-annotations` | 6.598 | 6.838 | 42.15 | 50.55 | 6.39x | 144,055 | 144,056 | 4.58 |
| `iterator-builtins` | 6.543 | 6.564 | 43.32 | 44.13 | 6.62x | 138,207 | 227,370 | 0.21 |
| `unicode-strings` | 4.722 | 4.840 | 15.00 | 15.58 | 3.18x | 83 | 117,703 | 0.75 |
| `bytes-codecs` | 3.203 | 3.436 | 3.039 | 3.794 | 0.95x | 84 | 64,090 | 0.56 |
| `formatting` | 5.739 | 5.910 | 14.06 | 15.31 | 2.45x | 36,865 | 36,866 | 0.64 |
| `list-algorithms` | 14.88 | 16.00 | 28987.8 | 29816.1 | 1948.08x | 303,505 | 194,556,098 | 1.22 |
| `dict-churn` | 19.75 | 20.19 | 195.8 | 211.6 | 9.92x | 323,125 | 452,132 | 6.72 |
| `set-algebra` | 20.13 | 20.28 | 148.4 | 179.0 | 7.37x | 804,125 | 821,353 | 1.83 |
| `numeric-key-equality` | 14.29 | 16.11 | 127.0 | 149.5 | 8.89x | 376,082 | 424,084 | 8.00 |

### Native libraries

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `math-numeric` | 13.36 | 15.06 | 82.82 | 87.58 | 6.20x | 296,087 | 385,840 | 2.00 |
| `statistics-data` | 66.01 | 69.01 | 4047.3 | 4055.5 | 61.32x | 440,121 | 540,146 | 1.29 |
| `json-tree` | 45.57 | 54.28 | 70.75 | 71.98 | 1.55x | 81,307 | 163,829 | 1.74 |
| `json-strings` | 44.47 | 44.49 | 14.55 | 14.65 | 0.33x | 34,091 | 440,223 | 1.95 |
| `csv-reader` | 46.44 | 123.5 | 84.58 | 85.42 | 1.82x | 180,061 | 195,654 | 4.07 |
| `csv-dictionaries` | 38.08 | 39.60 | 43.34 | 51.55 | 1.14x | 131,860 | 142,867 | 2.00 |
| `regex-ascii` | 28.20 | 29.62 | 9611.4 | 9836.6 | 340.79x | 804 | 93,595 | 0.34 |
| `regex-unicode` | 36.55 | 36.84 | 420.5 | 443.1 | 11.50x | 87 | 765,249 | 1.93 |
| `regex-replacement` | 36.75 | 36.90 | 687.6 | 778.7 | 18.71x | 76,886 | 738,447 | 2.62 |
| `counter` | 16.24 | 16.87 | 28.97 | 42.95 | 1.78x | 113 | 108,127 | 1.30 |
| `defaultdict` | 16.53 | 26.11 | 58.47 | 60.61 | 3.54x | 241,221 | 261,503 | 2.00 |
| `deepcopy-graphs` | 31.30 | 31.38 | 8.212 | 8.657 | 0.26x | 32,911 | 40,913 | 0.87 |
| `pathlib-files` | 1519.8 | 1551.3 | 8.005 | 8.829 | 0.01x | 10,968 | 105,858 | 0.50 |
| `os-files` | 332.5 | 336.3 | 4.248 | 5.530 | 0.01x | 8,288 | 37,691 | 0.27 |
| `random-invariants` | 24.59 | 24.66 | 2376.9 | 2482.7 | 96.67x | 204,309 | 16,412,561 | 2.00 |
| `import-packages` | 13.26 | 14.93 | 18.24 | 18.47 | 1.38x | 192,105 | 216,108 | 0.17 |

### Integrated workloads

| Case | CP med | CP p95 | Peony med | Peony p95 | Ratio | Instructions | Work | Peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `word-frequency` | 111.8 | 114.3 | 3278.2 | 3339.1 | 29.32x | 880,064 | 5,470,070 | 25.08 |
| `csv-pipeline` | 82.81 | 84.61 | 178.3 | 184.7 | 2.15x | 367,720 | 417,468 | 8.00 |
| `json-pipeline` | 60.00 | 61.52 | 172.2 | 185.8 | 2.87x | 242,160 | 411,335 | 5.33 |
| `log-analysis` | 61.67 | 76.42 | 9870.8 | 9893.7 | 160.06x | 552,071 | 2,555,552 | 16.05 |
| `graph-search` | 30.42 | 31.14 | 240.2 | 259.9 | 7.90x | 758,453 | 777,656 | 8.00 |
| `prime-sieve` | 23.38 | 23.48 | 235.7 | 245.7 | 10.08x | 1,516,384 | 1,569,393 | 0.93 |
| `text-index` | 8.053 | 8.402 | 62.91 | 65.00 | 7.81x | 170,162 | 212,342 | 3.92 |
| `object-dispatch` | 17.46 | 18.76 | 184.0 | 197.9 | 10.54x | 645,103 | 695,109 | 8.00 |
| `file-throughput` | 56.51 | 56.54 | 62.51 | 69.12 | 1.11x | 1,981 | 4,082 | 6.44 |
| `sort-records` | 14.65 | 16.28 | 2573.3 | 2577.2 | 175.65x | 309,076 | 16,849,550 | 3.22 |

The runner and interpretation rules are documented in [the comparison corpus guide](README.md).
