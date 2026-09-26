# Native libraries

Peony's importable utilities are Zig implementations compiled into both the native executable and `peony.wasm`. They create Python-visible modules, classes, functions, iterators, and exceptions in the same VM and heap used by program code. A library call participates in Python argument binding, GC, exception handling, and callback execution. The active adapter supplies filesystem storage, transport, clock, timer, and input services.

This page lists module functions, signatures, object methods, and host behavior. The [language page](language.md) covers core values and builtins; the [embedding page](embedding.md) covers browser services and session options.

| Area | Imports |
|---|---|
| Runtime metadata and numbers | `sys`, `math`, `random`, `statistics`, `time` |
| Text and structured data | `json`, `csv`, `re` |
| Files and object utilities | `pathlib`, `os`, `os.path`, `collections`, `copy` |
| Host-backed networking | `urllib.request`, `urllib.error`, `requests`, `requests.exceptions` |

`urllib.error`, `requests.exceptions`, and `os.path` are supporting namespaces for their listed parent surfaces. Registered Zig libraries resolve through the module registry before user source files.

## Runtime metadata and numeric work

### `sys`

`sys.argv` contains `[filename, ...arguments]` from the CLI or `session.run(source, { filename, argv })`; arguments are copied before execution. `sys.path` lists the import locations for the active host: the script directory and working directory on native, or browser file roots in a Worker. `sys.modules` is the module cache for the current run. `sys.version`, `version_info`, `implementation`, and `platform` identify Peony and its Python 3.12 language target. `sys.stdout` and `sys.stderr` are stream objects with `write(str)` and `flush()`; writes return a character count. `sys.exit(code=None)` raises catchable `SystemExit` with its code.

### `math`

Constants are `pi`, `e`, `tau`, `inf`, and `nan`. Functions are `sqrt`, `pow`, `exp`, `log(x[, base])`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `floor`, `ceil`, `trunc`, `fabs`, `factorial`, `gcd`, `lcm`, `isfinite`, `isinf`, `isnan`, `radians`, and `degrees`. `log` arguments are positional only. Scalar floating-point work uses Zig math with Python-oriented argument conversion and domain/overflow errors. Integer-valued results, including factorial and gcd/lcm, use Peony's bigint path when necessary.

### `random`

Functions are `seed(a=None, version=2)`, `random()`, `randint(a, b)`, `randrange(start, stop=None, step=1)`, `choice(seq)`, `choices(population, weights=None, *, cum_weights=None, k=1)`, `shuffle(x)`, `sample(population, k, *, counts=None)`, and `uniform(a, b)`. A run owns its PRNG state. Seed values include `None`, bool/int, float, str, and bytes. A fixed seed produces a repeatable Peony stream.

Integer bounds use rejection sampling across large ranges. `shuffle` mutates a list. Sampling and weighted choices validate population sizes, weights, counts, and argument types before drawing, charge work proportional to their real effort, and preserve state across VM yields. These functions operate on Python values and iterators.

### `statistics` and `time`

`statistics` exposes `mean(data)`, `fmean(data, weights=None)`, `median(data)`, `mode(data)`, and `StatisticsError` (a `ValueError` subclass). Data is drawn once through the VM iterator protocol and uses Peony's int/bool/float numeric family. `mean` preserves large-integer precision, `fmean` uses a stable floating calculation, `median` sorts a working collection, and `mode` resolves ties by encounter order.

`time.time()`, `time.monotonic()`, and `time.sleep(seconds)` use host wall clock, monotonic clock, and timer services. Sleep validates a finite nonnegative duration and suspends. Browser services are injectable, and cancellation aborts a pending sleep. The native adapter uses Zig's real and awake clocks and a host timer.

## Data, CSV, and patterns

### `json`

`json.loads(s)` accepts a string or UTF-8 bytes; `load(fp)` reads a file-like object. `dumps(obj, ...)` returns a string and `dump(obj, fp, ...)` writes through a file-like object. Serialization handles `None`, booleans, integers, floats, strings, lists, tuples, and dictionaries. Options include `indent` (`None`, integer, or string), `sort_keys`, `ensure_ascii`, `separators`, and `allow_nan`.

The parser retains arbitrary integer tokens as Peony integers instead of passing them through a JavaScript number. Decode errors raise `JSONDecodeError`, a `ValueError` subclass with `msg`, `doc`, `pos`, `lineno`, and `colno`. Cyclic serialization is rejected. Peony strings must remain valid UTF-8, so byte input must be UTF-8 and a lone surrogate escape is rejected. A single decoded or encoded JSON string token has a 256 KiB limit, distinct from the session heap and total work budgets. Large scans are charged and resumable; a file-like callback can itself suspend through the VM without replaying earlier reads or writes. `requests.Response.json()` uses this same native parser and exception type.

### `csv`

`csv.reader`, `writer`, `DictReader`, and `DictWriter` are native objects. `csv.Error` represents dialect/record errors; admitted quoting constants are `QUOTE_MINIMAL`, `QUOTE_ALL`, and `QUOTE_NONNUMERIC`. The exposed parameters cover `delimiter`, `quotechar`, `lineterminator`, and those quoting modes. A reader recognizes doubled quotes, embedded delimiters, Unicode text, and records spanning multiple physical lines; its `line_num` counts physical input lines. `QUOTE_NONNUMERIC` converts unquoted numeric fields. A writer emits a completed row through the target's `write()` method.

Dictionary variants handle ordered fieldnames, `restkey`/`restval`, `extrasaction` (`raise` or `ignore`), `writeheader`, `writerow`, and `writerows`. The source or sink may be a Peony file or a user file-like object. Such callbacks use native continuations, so an iterator or `write()` that requests host input resumes with its current row. For text files, `open(path, newline="")` preserves line endings for the CSV reader.

### `re`

The regex engine is native Zig in `src/regex/`. Module functions are `compile`, `search`, `match`, `fullmatch`, `findall`, `finditer`, `split`, `sub`, `subn`, and `escape`. A compiled `Pattern` exposes `pattern`, `flags`, `groups`, `groupindex`, and corresponding matching, finding, splitting, and substitution methods, including `pos`, `endpos`, `maxsplit`, and `count`. A `Match` exposes `group`, `groups`, `groupdict`, `start`, `end`, `span`, `string`, `re`, and named or numbered capture access.

The module call shapes are `compile(pattern, flags=0)`; `search`/`match`/`fullmatch`/`findall`/`finditer(pattern, string, flags=0)`; `split(pattern, string, maxsplit=0, flags=0)`; `sub`/`subn(pattern, repl, string, count=0, flags=0)`; and `escape(pattern)`. Compiled Pattern matching/finding methods accept `string, pos=0, endpos=...` where applicable. Pattern `split` accepts `maxsplit`; Pattern `sub`/`subn` accept `count`. These forms preserve the distinction between a module call that compiles a pattern and a method on an already compiled Pattern.

The grammar includes literals, `.`, `^`/`$`, character classes, ranges and negation, `\d`/`\D`, `\w`/`\W`, `\s`/`\S`, `\b`/`\B`, capture and named/noncapture groups, alternation, greedy and lazy `* + ?`, and counted repetitions. Flags are `ASCII`/`A`, `IGNORECASE`/`I`, `MULTILINE`/`M`, `DOTALL`/`S`, and `UNICODE`/`U` for strings. Unicode string mode is the default; bytes classes are ASCII. Replacement templates can refer to capture groups, and callable replacements invoke Python through the VM. The engine charges scan work and manages compiled program and capture growth.

For example, `re.findall(r"[A-Za-z]+@[A-Za-z.]+", text)` can feed a `Counter`; both the scan and counts remain in Peony values.

## Files, paths, and object utilities

### `pathlib`, `os`, and `os.path`

`pathlib.Path(*segments)` is a Zig path object for the active filesystem host. It supports `/` and reverse `/` joining, `str`/`repr`, equality/hash, `name`, `suffix`, `stem`, `parent`, `exists`, `is_file`, `is_dir`, `read_text`, `write_text`, `read_bytes`, `write_bytes`, `mkdir(mode=0o777, parents=False, exist_ok=False)`, and `iterdir`. `open(Path(...))` uses the shared file implementation. Browser paths use POSIX separators; native paths reach the OS through Zig.

`os` exposes `getcwd`, `listdir`, `mkdir`, `makedirs`, `remove`/`unlink`, `rename`, and `replace`. `os.path` exposes `join`, `basename`, `dirname`, `exists`, `isfile`, and `isdir`. On native, `getcwd()` returns the process working directory, relative paths resolve there, and operations act on real files. In the browser, `getcwd()` returns `/home`; paths and storage belong to the Worker file tree. Open file handles retain their file identity according to the active host.

### `collections`

`Counter` and `defaultdict` are native dictionary-related types. `Counter` can be constructed from an iterable, mapping, or keyword counts. A missing subscription returns zero without inserting a key; explicit zero and negative counts remain representable. `update`, `subtract`, `elements`, `most_common(n=None)`, `total`, `copy`, unary `+`/`-`, multiset `+ - & |`, and the admitted comparisons are supported. Ties in `most_common` retain encounter order. The common dictionary accessors/views use the same storage and hash/equality rules as `dict`.

`defaultdict(factory, mapping, **kw)` stores a mutable `default_factory`. A missing subscription invokes the factory once and inserts its successful result. `get()` and membership leave missing keys untouched. A factory callback can raise or suspend through the VM while insertion waits for its result.

### `copy`

`copy.copy(x)` and `copy.deepcopy(x, memo=None)` operate on scalars, containers, and ordinary user instances. Immutable values may retain identity; a shallow mutable copy shares children. Deep copy tracks object identity in one memo, preserving cycles and shared references in the result graph. Instance `__copy__` and `__deepcopy__(memo)` hooks run as Python calls through the VM and may suspend. Resource-bearing objects report a Python error during copying.

## HTTP and browser policy

### `urllib.request` and `urllib.error`

`urlopen(url, data=None, timeout=None)` accepts HTTP(S) URL strings. A bytes `data` argument selects POST; the default selects GET. The returned response provides `read(size=None)`, `status`, `headers`, `getcode()`, `close()`, and context-manager entry and exit. `urllib.error` supplies `URLError` and `HTTPError`. Zig handles Python arguments, response behavior, and exceptions; the active host performs transport.

### `requests` and `requests.exceptions`

`requests` exposes `get(url, params=None, *, headers=None, timeout=None)` and `post(url, data=None, json=None, *, headers=None, timeout=None, params=None)`. Data may be bytes, text, or a form mapping; `json` uses Peony's native serializer. Query and form encoding are native. A response exposes `status_code`, `ok` (status below 400), case-insensitive `headers`, `content` bytes, `text`, mutable `encoding`, `json()`, and `raise_for_status()`. Text encoding follows an explicit setting, then a Content-Type charset, then UTF-8. UTF-8, ASCII, and Latin-1 aliases are available. `requests.exceptions` contains request, connection, timeout, and HTTP exception classes.

### Transport and TLS

The transport adapter owns TLS policy. In the browser, `fetch` uses browser certificate validation and CORS. In the native executable, Zig's HTTP client uses platform certificate trust. The Python response objects and exception classes are the same engine objects in both environments.

In a Worker, HTTP uses the embedding page's `fetch` or injected replacement. It sends `credentials: 'omit'`, requests redirect rejection, applies `allowUrl(url)` before transport, and caps response bytes while reading the stream. A timeout or cancellation aborts URL approval, fetch, and body reading.

In the native executable, HTTP uses Zig's HTTP/TLS client. It accepts the same engine packets, requests redirect rejection, decodes response compression, caps response bytes under the packet ceiling, and enforces explicit timeouts with cancellable concurrent I/O. Both adapters map host failures into Python exception families; response construction is shared Zig engine code.
