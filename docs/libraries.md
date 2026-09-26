# Native library surface

The importable utilities below are implemented in Zig and compiled into `peony.wasm`. They are ordinary Python-visible modules and objects, backed by the same values, exceptions, GC, and VM calls as learner code. JavaScript supplies browser services when needed; it does not implement these Python APIs. The admitted names and options below are the Peony subset, rather than the full upstream standard or third-party packages.

## Numeric and process metadata

| Import | Admitted surface | Boundary |
|---|---|---|
| `sys` | `argv`, `path`, `modules`, `version`, `version_info`, `implementation`, `platform`, `stdout.write/flush`, `stderr.write/flush`, `exit(code=None)` | `sys.argv` starts with the run filename. `sys.modules` is the actual module cache. No frame or process introspection. |
| `math` | `pi`, `e`, `tau`, `inf`, `nan`; `sqrt`, `pow`, `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `floor`, `ceil`, `trunc`, `fabs`, `factorial`, `gcd`, `lcm`, `isfinite`, `isinf`, `isnan`, `radians`, `degrees` | Float domain/overflow checks and integer precision are handled inside Zig. Decimal and Fraction are outside the runtime. |
| `random` | `seed(a=None, version=2)`, `random`, `randint`, `randrange`, `choice`, `choices`, `shuffle`, `sample`, `uniform` | State is per run. Accepted seed families are `None`, integer/bool, float, string, and bytes. A fixed seed is repeatable within Peony, not sequence-compatible with CPython. `choices` admits weights or cumulative weights; `sample` admits `counts`. |
| `statistics` | `mean`, `fmean(data, weights=None)`, `median`, `mode`, `StatisticsError` | The admitted numeric family is int/bool/float; iterables are consumed through the VM iterator protocol. Other statistics APIs are absent. |
| `time` | `time()`, `monotonic()`, `sleep(seconds)` | Clock and sleep values come from injectable host services. Sleep suspends rather than busy-waiting. |

`sys.implementation.name` identifies Peony. The process metadata is for learner-facing compatibility; it does not imply an operating-system process inside WASM.

## Data and text

### `json`

`loads`, `dumps`, `load`, and `dump` operate on Peony values and supported file-like objects. Serialization admits `None`, booleans, integers, floats, strings, lists, tuples, and dictionaries. The supported keyword options are `indent`, `sort_keys`, `ensure_ascii`, `separators`, and `allow_nan`. `JSONDecodeError` derives from `ValueError` and provides `msg`, `doc`, `pos`, `lineno`, and `colno`. Parse hooks, serializer classes, `default`, and unlisted options are excluded. Input bytes must be UTF-8; lone surrogate escapes are rejected because Peony strings are valid UTF-8. A single decoded or encoded string token is bounded at 256 KiB. Parsing and serialization run as charged native work, with cancellation opportunities.

### `csv`

`reader`, `writer`, `DictReader`, `DictWriter`, and `Error` are native objects. The admitted constants are `QUOTE_MINIMAL`, `QUOTE_ALL`, and `QUOTE_NONNUMERIC`. Delimiter, quote character, line terminator, and those quoting modes are configurable. Reader handles quoted multiline records and exposes `line_num`; dictionary variants expose field names, `restkey`/`restval`, `extrasaction`, `writeheader`, `writerow`, and `writerows` as appropriate. File-like reads and writes invoke learner callbacks through the VM. Dialect registration, custom dialect classes, `QUOTE_NOTNULL`, and `QUOTE_STRINGS` are excluded.

### `re`

The regex engine in `src/regex/` is native Zig. Module calls are `compile`, `search`, `match`, `fullmatch`, `findall`, `finditer`, `split`, `sub`, `subn`, and `escape`. Pattern objects expose `pattern`, `flags`, `groups`, `groupindex`, and their corresponding search/match/find/split/sub methods. Match objects expose `group`, `groups`, `groupdict`, `start`, `end`, `span`, `string`, and `re`, with numbered/named group access. Flags are `ASCII`/`A`, `IGNORECASE`/`I`, `MULTILINE`/`M`, `DOTALL`/`S`, and Unicode `UNICODE`/`U` for strings. The grammar admits literals, classes/ranges and `\d`/`\w`/`\s` families, anchors/boundaries, captures, alternation, greedy/lazy quantifiers, and bounded repeats. Pattern backreferences, lookaround, conditional and atomic groups, locale mode, and unlisted inline flag forms are excluded. Replacement templates can still reference captured groups; callable replacement runs through the VM. Bytes patterns use ASCII classes. Invalid patterns raise native `re.error`.

## Filesystem and object utilities

| Import | Admitted surface | Boundary |
|---|---|---|
| `pathlib` | `Path(*segments)`, `/` joining, `name`, `suffix`, `stem`, `parent`, `exists`, `is_file`, `is_dir`, `read_text`, `write_text`, `read_bytes`, `write_bytes`, `mkdir`, `iterdir` | Paths are POSIX-like and target the session VFS. `open(Path(...))` uses the same file implementation. |
| `os` / `os.path` | `getcwd`, `listdir`, `mkdir`, `makedirs`, `remove`/`unlink`, `rename`, `replace`; `join`, `basename`, `dirname`, `exists`, `isfile`, `isdir` | Current directory is `/home`; no host cwd, environment, process, or filesystem access. `os.path` remains lexical until VFS resolution. |
| `collections` | `Counter` and `defaultdict`; Counter construction, `update`, `subtract`, `elements`, `most_common`, `total`, `copy`, multiset arithmetic/comparisons; mutable `default_factory` | Native dictionary storage and Python equality/hash are shared. `deque`, `ChainMap`, and `namedtuple` are absent. |
| `copy` | `copy`, `deepcopy(memo=None)`, `Error`; instance `__copy__`/`__deepcopy__` hooks | Deep copy preserves cycles and aliases for supported object graphs. Open files and live generators are not silently copied. Pickle/reduce protocols are absent. |

The VFS contains `/course` (read-only mounted files), `/home` (writable learner files), and `/tmp` (cleared on a new run). `pathlib` and `os` use these same roots. Read/write methods enforce the configured per-file and total content limits. The [language page](language.md) documents `open()` and file objects.

## Browser-backed networking

| Import | Admitted surface | Boundary |
|---|---|---|
| `urllib.request` | `urlopen(url, data=None, timeout=None, *, context=None)`; response `read`, `status`, `headers`, `getcode`, `close`, context entry/exit | HTTP(S) only. Bytes `data` selects POST; the native response owns a bounded byte body and cursor. `urllib.error` supplies `URLError` and `HTTPError`. No opener, proxy, socket, or general Request machinery. |
| `requests` | `get(url, params=None, **kwargs)`, `post(url, data=None, json=None, **kwargs)` with `headers`, `timeout`, `params`; response `status_code`, `ok`, `headers`, `content`, `text`, mutable `encoding`, `json()`, `raise_for_status()` | A small teaching API, not the third-party distribution. Query/form and JSON conversion are native Zig. `requests.exceptions` provides the supported transport and HTTP exception classes. Sessions, streaming, auth, adapters, and proxies are absent. |
| `ssl` | `SSLContext`, `create_default_context()`, `CERT_NONE`, `CERT_REQUIRED`, mutable `check_hostname` and `verify_mode` | This teaching object validates `urlopen` arguments. It **cannot change browser certificate verification, TLS, or CORS**. |

The public facade uses browser `fetch` (or an injected equivalent) for transport. HTTP(S) only, `credentials: 'omit'`, an optional `allowUrl(url)` policy, a response-size cap while streaming, and default redirect rejection govern that boundary. Browser CORS and TLS still apply. Changing `requests` headers or an `ssl` context cannot bypass those policies. Clock, sleep, HTTP and input operations suspend through the same host protocol; late replies after cancellation or reset are ignored. See [embedding](embedding.md) and the [packet ABI](wasm-abi.md).

## Deliberate limits

An unlisted module or method is not implicitly implemented because a related module exists. There is no `socket`, `subprocess`, `threading`, `asyncio`, `sqlite3`, NumPy, pandas, or browser DOM API inside learner Python. The exact admitted functions above should be used when choosing course examples; unsupported options receive an error instead of silently becoming a partial approximation.
