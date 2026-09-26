# Native libraries

Peony's importable utilities are Zig implementations compiled into `peony.wasm`. They create ordinary Python-visible modules, classes, functions, iterators, and exceptions in the same VM and heap used by learner code. A library call therefore participates in normal Python argument binding, GC, exception handling, and callback execution. It does not inject a hidden `.py` implementation or delegate its algorithm to JavaScript. The host supplies transport, clock, and timer services only where those operations genuinely require a browser facility.

This page describes the admitted API, including the important boundary around each library. A familiar module name does **not** include its full CPython or third-party distribution. Unknown options and unavailable methods fail rather than silently approximate a wider API. The [language page](language.md) covers core values and builtins; the [embedding page](embedding.md) covers host services and session options.

| Area | Imports |
|---|---|
| Runtime metadata and numbers | `sys`, `math`, `random`, `statistics`, `time` |
| Text and structured data | `json`, `csv`, `re` |
| Files and object utilities | `pathlib`, `os`, `os.path`, `collections`, `copy` |
| Browser-backed networking | `urllib.request`, `urllib.error`, `requests`, `requests.exceptions`, `ssl` |

`urllib.error`, `requests.exceptions`, and `os.path` are supporting namespaces for their listed parent surfaces. All registered native names take precedence over a same-named VFS learner file on an import cache miss.

## Runtime metadata and numeric work

### `sys`

`sys.argv` contains `[filename, ...arguments]` from `session.run(source, { filename, argv })`; the arguments are validated and copied before execution. `sys.path` describes the virtual import roots. `sys.modules` is the actual module cache for the current run, so repeated imports return the same module object. `sys.version`, `version_info`, `implementation`, and `platform` identify Peony and its Python 3.12 language target without pretending that the runtime is CPython. `sys.stdout` and `sys.stderr` are native stream objects with `write(str)` and `flush()`; a stream write returns a character count. `print(file=sys.stderr)` uses the same stream path. `sys.exit(code=None)` raises catchable `SystemExit` with its code. Process internals, frame inspection, arbitrary standard streams, and ambient operating-system facilities are not part of this module.

### `math`

Constants are `pi`, `e`, `tau`, `inf`, and `nan`. Admitted functions are `sqrt`, `pow`, `exp`, `log(x[, base])`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `floor`, `ceil`, `trunc`, `fabs`, `factorial`, `gcd`, `lcm`, `isfinite`, `isinf`, `isnan`, `radians`, and `degrees`. The `log` arguments are positional-only. Scalar floating-point work uses Zig math with Python-oriented argument conversion and domain/overflow errors. Integer-valued results, including factorial and gcd/lcm, use Peony's bigint path when necessary. `gcd` and `lcm` accept their admitted multiple-integer forms. Decimal, Fraction, complex arithmetic, and unlisted `math` APIs are outside this runtime.

### `random`

Admitted functions are `seed(a=None, version=2)`, `random()`, `randint(a, b)`, `randrange(start, stop=None, step=1)`, `choice(seq)`, `choices(population, weights=None, *, cum_weights=None, k=1)`, `shuffle(x)`, `sample(population, k, *, counts=None)`, and `uniform(a, b)`. A run owns its PRNG state. The supported seed families are `None`, bool/int, float, str, and bytes; the legacy non-default seed version is excluded. A fixed seed produces a repeatable Peony stream, but no CPython Mersenne Twister sequence identity is promised.

Integer bounds use rejection sampling so a large range need not be reduced with modulo bias or materialized. `shuffle` mutates a list. Sampling and weighted choices validate population sizes, weights, counts, and argument types before drawing, charge work proportional to their real effort, and preserve state across VM yields. These functions use Python values and iterators where admitted, rather than a browser random API.

### `statistics` and `time`

`statistics` exposes `mean(data)`, `fmean(data, weights=None)`, `median(data)`, `mode(data)`, and `StatisticsError` (a `ValueError` subclass). Data is drawn once through the VM iterator protocol and is limited to Peony's int/bool/float numeric family. `mean` preserves large-integer precision where relevant, `fmean` uses a stable floating calculation, `median` materializes a bounded working collection, and `mode` resolves ties by encounter order. Other statistical functions are absent.

`time.time()`, `time.monotonic()`, and `time.sleep(seconds)` use host-provided wall clock, monotonic clock, and timer services. Sleep validates a finite nonnegative duration and suspends; it does not busy-wait inside WASM. The host services are injectable for a lesson or test, and cancellation aborts a pending sleep. There is no approximation based on bytecode counts.

## Data, CSV, and patterns

### `json`

`json.loads(s)` accepts a string or UTF-8 bytes; `load(fp)` reads a supported file-like object. `dumps(obj, ...)` returns a string and `dump(obj, fp, ...)` writes through a file-like object. Serialization admits `None`, booleans, integers, floats, strings, lists, tuples, and dictionaries. Supported options are `indent` (`None`, integer, or string), `sort_keys`, `ensure_ascii`, `separators`, and `allow_nan`. Hooks such as `parse_int`, custom serializer classes, a `default` callback, and unlisted options are not included.

The parser retains arbitrary integer tokens as Peony integers instead of passing them through a JavaScript number. Decode errors raise `JSONDecodeError`, a `ValueError` subclass with `msg`, `doc`, `pos`, `lineno`, and `colno`. Cyclic serialization is rejected. Peony strings must remain valid UTF-8, so byte input must be UTF-8 and a lone surrogate escape is rejected. A single decoded or encoded JSON string token has a 256 KiB limit, distinct from the session heap and total work budgets. Large scans are charged and resumable; a file-like callback can itself suspend through the VM without replaying earlier reads or writes. `requests.Response.json()` uses this same native parser and exception type.

### `csv`

`csv.reader`, `writer`, `DictReader`, and `DictWriter` are native objects. `csv.Error` represents dialect/record errors; admitted quoting constants are `QUOTE_MINIMAL`, `QUOTE_ALL`, and `QUOTE_NONNUMERIC`. The exposed parameters cover `delimiter`, `quotechar`, `lineterminator`, and those quoting modes. A reader recognizes doubled quotes, embedded delimiters, Unicode text, and records spanning multiple physical lines; its `line_num` counts physical input lines. `QUOTE_NONNUMERIC` converts unquoted numeric fields. A writer emits a completed row through the target's `write()` method.

Dictionary variants handle ordered fieldnames, `restkey`/`restval`, `extrasaction` (`raise` or `ignore`), `writeheader`, `writerow`, and `writerows`. The source or sink may be a Peony file or a supported learner file-like object. Such callbacks use native continuations, so an iterator or `write()` that requests host input can resume without duplicating a row. For real text files, `open(path, newline="")` preserves line endings for the CSV reader. Dialect registration, arbitrary dialect classes, `QUOTE_NOTNULL`, and `QUOTE_STRINGS` are outside this subset.

### `re`

The regex engine is native Zig in `src/regex/`; it does not call JavaScript `RegExp`. Module functions are `compile`, `search`, `match`, `fullmatch`, `findall`, `finditer`, `split`, `sub`, `subn`, and `escape`. A compiled `Pattern` exposes `pattern`, `flags`, `groups`, `groupindex`, and corresponding matching/finding/splitting/substitution methods, including `pos`, `endpos`, `maxsplit`, or `count` where admitted. A `Match` exposes `group`, `groups`, `groupdict`, `start`, `end`, `span`, `string`, `re`, and named or numbered capture access.

The module call shapes are `compile(pattern, flags=0)`; `search`/`match`/`fullmatch`/`findall`/`finditer(pattern, string, flags=0)`; `split(pattern, string, maxsplit=0, flags=0)`; `sub`/`subn(pattern, repl, string, count=0, flags=0)`; and `escape(pattern)`. Compiled Pattern matching/finding methods accept `string, pos=0, endpos=...` where applicable. Pattern `split` accepts `maxsplit`; Pattern `sub`/`subn` accept `count`. These forms preserve the distinction between a module call that compiles a pattern and a method on an already compiled Pattern.

The grammar includes literals, `.`, `^`/`$`, character classes, ranges and negation, `\d`/`\D`, `\w`/`\W`, `\s`/`\S`, `\b`/`\B`, capture and named/noncapture groups, alternation, greedy and lazy `* + ?`, and bounded repetitions. Flags are `ASCII`/`A`, `IGNORECASE`/`I`, `MULTILINE`/`M`, `DOTALL`/`S`, and `UNICODE`/`U` for strings. Unicode string mode is the default; bytes classes are ASCII. Pattern backreferences, lookaround, conditional/atomic groups, locale mode, and unlisted inline-flag syntax are rejected with `re.error`. Replacement *templates* may refer to capture groups even though pattern backreferences are excluded. A callable replacement invokes learner Python through the VM, including suspension and errors. The engine charges scan work and bounds compiled program/capture growth rather than relying on host regex backtracking behavior.

For example, `re.findall(r"[A-Za-z]+@[A-Za-z.]+", text)` can feed a `Counter` in a course exercise; both the scan and counts remain in native Peony values. The exact pattern subset above still applies if a learner tries a more advanced regex from CPython documentation.

## Virtual paths and object utilities

### `pathlib`, `os`, and `os.path`

`pathlib.Path(*segments)` is a native path object for the session VFS. It supports `/` and reverse `/` joining, `str`/`repr`, equality/hash, `name`, `suffix`, `stem`, `parent`, `exists`, `is_file`, `is_dir`, `read_text`, `write_text`, `read_bytes`, `write_bytes`, `mkdir(mode=0o777, parents=False, exist_ok=False)`, and `iterdir`. `open(Path(...))` uses the shared path conversion and file implementation. A Path keeps lexical POSIX-style components until a VFS operation resolves them.

`os` exposes `getcwd`, `listdir`, `mkdir`, `makedirs`, `remove`/`unlink`, `rename`, and `replace`. `os.path` exposes `join`, `basename`, `dirname`, `exists`, `isfile`, and `isdir`. The virtual current directory is `/home`, and all paths are case-sensitive POSIX-style paths on every host. Lexical `os.path` operations are distinct from VFS normalization at file access. The VFS has no ambient host cwd, environment, process, or device paths. `/course` mutations are rejected. Open handles retain their file data identity after a rename or unlink, and file/total content caps are checked before mutating storage.

### `collections`

`Counter` and `defaultdict` are native dictionary-related types. `Counter` can be constructed from an iterable, mapping, or keyword counts. A missing subscription returns zero without inserting a key; explicit zero and negative counts remain representable. `update`, `subtract`, `elements`, `most_common(n=None)`, `total`, `copy`, unary `+`/`-`, multiset `+ - & |`, and the admitted comparisons are supported. Ties in `most_common` retain encounter order. The common dictionary accessors/views use the same storage and hash/equality rules as `dict`.

`defaultdict(factory, mapping, **kw)` stores a mutable `default_factory`. A missing subscription invokes the factory once and inserts its successful result. `get()` and membership do not invoke the factory. If a factory raises, suspends, or the run is cancelled, a partial key is not inserted. `deque`, `ChainMap`, and `namedtuple` are not included merely because `collections` imports.

### `copy`

`copy.copy(x)` and `copy.deepcopy(x, memo=None)` operate on supported scalars, containers, and ordinary user instances. Immutable values may retain identity; a shallow mutable copy shares children. Deep copy tracks object identity in one memo, preserving cycles and shared references in the result graph. Supported instance `__copy__` and `__deepcopy__(memo)` hooks run as learner calls through the VM and may suspend. Live generators, open files, and other resource-bearing objects fail explicitly instead of silently aliasing external state. The pickle/reduce protocol is outside this subset.

## HTTP and browser policy

### `urllib.request` and `urllib.error`

`urlopen(url, data=None, timeout=None, *, context=None)` admits HTTP(S) URL strings. A bytes `data` argument selects POST; absent data selects GET. The returned native response has a bounded body cursor with `read(size=None)`, `status`, `headers`, `getcode()`, `close()`, and context-manager entry/exit. `urllib.error` supplies the `URLError` and `HTTPError` classes used by this surface. Custom opener handlers, proxy machinery, arbitrary schemes, sockets, and a general `Request` construction API are excluded. Request argument conversion, Python response behavior, and exception mapping are Zig work; transport is supplied by the host.

### `requests` and `requests.exceptions`

This is a small teaching-compatible surface, not the full third-party Requests package. It exposes `get(url, params=None, *, headers=None, timeout=None)` and `post(url, data=None, json=None, *, headers=None, timeout=None, params=None)`. Data may be bytes, text, or a form mapping; `json` uses Peony's native serializer. Query and form encoding are native. A response exposes `status_code`, `ok` (status below 400), case-insensitive `headers`, `content` bytes, `text`, mutable `encoding`, `json()`, and `raise_for_status()`. Text encoding comes from an explicit setting, then a Content-Type charset, then UTF-8; UTF-8, ASCII, and Latin-1 aliases are supported. Unknown codecs raise `LookupError` rather than invoking a browser charset detector. `requests.exceptions` contains the admitted request, connection, timeout, and HTTP exception classes. Sessions, streamed responses, auth, proxies, adapters, and custom transports are excluded.

### `ssl` and the host boundary

`ssl.SSLContext`, `create_default_context()`, `CERT_NONE`, `CERT_REQUIRED`, and mutable `check_hostname`/`verify_mode` provide the small API state used by a teaching `urlopen(..., context=...)` pattern. A context starts with hostname checking enabled and `CERT_REQUIRED`; setting `CERT_NONE` while hostname checking remains enabled is rejected. The context is a Peony object for argument validation; it cannot change browser TLS verification, certificate storage, CORS, or the network stack. It does not open sockets or perform TLS handshakes in WASM.

HTTP uses the embedding page's `fetch` (or an injected replacement) through the Worker. The adapter accepts only HTTP(S), sends `credentials: 'omit'`, rejects redirects unless the host opts in, applies an optional `allowUrl(url)` decision, and caps response bytes while reading the stream. A timeout or cancellation aborts fetch and body reading. The browser's own CORS and TLS rules remain in force. Following redirects does not make browser-hidden cross-origin hops visible to `allowUrl`. Host failures are mapped back into the documented Python/library exception families. Clock and sleep use the same suspended-host mechanism; details of the packet protocol are in [WASM ABI](wasm-abi.md).

## What this contract leaves out

The supported import set does not include `sqlite3`, `socket`, `subprocess`, `threading`, `multiprocessing`, `asyncio`, `numpy`, `pandas`, a general XML stack, or access to the DOM. An API not listed on this page may produce an import/attribute error or an explicit unsupported-option error. For teaching material, choose examples against the named surface and treat the [language boundary](language.md) and browser policy as part of the same contract.
