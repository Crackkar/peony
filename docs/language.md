# Python language surface

Peony implements a **subset of Python 3.12** for introductory programs. This page is the admission boundary, not a promise that every CPython feature or edge case is present. A recognized feature outside the subset should fail clearly; an unavailable import raises a Python import error. The public [library surface](libraries.md) and [embedding API](embedding.md) complete the contract.

## Source and syntax

Source is UTF-8. An initial UTF-8 BOM and UTF-8 encoding cookies are accepted; other source encodings are rejected. Newlines, indentation, comments, explicit backslash continuation, and implicit continuation in brackets are handled by the lexer. Identifiers are **ASCII only**; string values are Unicode. Numeric literals include decimal, binary, octal and hex integers (with underscores), decimal floats, and scientific notation. Strings include ordinary, raw, bytes, and formatted literals, single/double/triple quotes, and adjacent literal concatenation. Complex-number literals are outside the subset.

| Area | Admitted forms |
|---|---|
| Simple statements | Expressions; assignment, annotated and augmented assignment; starred/unpacking assignment; `del`, `pass`, `break`, `continue`, `return`, `yield`, `raise`/`raise from`, `assert`; `import`, `from ... import ...`, `global`, `nonlocal` |
| Blocks | `if`/`elif`/`else`, `while`/`else`, `for`/`else`, `try`/`except`/`else`/`finally`, `with`, function and class definitions |
| Expressions | Names, literals, attributes, calls, indexing/slicing, arithmetic and bitwise operators, chained comparisons, Boolean short circuit, conditional expressions, lambdas, assignment expressions outside comprehensions |
| Collections | Tuple/list/set/dict displays, starred elements and dict `**` unpacking; list/set/dict comprehensions and generator expressions |
| Pattern matching | `match` with literal, `None`/`True`/`False`, wildcard, capture and OR patterns, plus guards |

`match`, `case`, `_`, and `type` act as soft keywords where the grammar needs them. Python functions support positional and keyword arguments, defaults, `*args`, `**kwargs`, positional-only and keyword-only parameters, nested closures, decorators, and generators. `yield from` is outside the subset. Annotations follow Python 3.12's eager definition-time rules where applicable; local variable annotation expressions are not evaluated. `from __future__ import annotations` is unsupported.

Expressions support `+ - * / // % **`, `& | ^ ~ << >>`, comparisons, `is` and membership, with normal precedence and short circuiting. The matrix `@` operator is excluded. An assignment expression inside a comprehension is excluded because its special binding rules are outside this subset. Sequence, mapping, and class patterns are excluded from `match`.

Async syntax (`async def`, `async for`, `async with`, `await`), exception groups and `except*`, PEP 695 `type` statements/type parameters, and dynamic code evaluation are outside this language surface. Source diagnostics include line and column data. The supported syntax is exercised in `tests/unit/` and shipping-WASM tests in `tests/`.

## Values and objects

The core values are `None`, `bool`, arbitrary-size `int`, binary floating point `float`, Unicode `str`, immutable `bytes`, `list`, `tuple`, `dict`, `set`, `range`, slices, functions, generators, classes and instances, modules, exceptions, and file objects. `NotImplemented` and `Ellipsis` are available singletons. Iteration, slicing, hashing/equality, insertion-ordered dictionaries, and Python exception handling are part of the supported behavior. Sets do not promise a particular iteration order.

User classes support multiple inheritance with C3 method resolution, instance/class attributes, methods, properties, `staticmethod`, `classmethod`, `super()`, and the supported special methods through VM dispatch. Arbitrary metaclasses, custom `__new__`, `__getattribute__`, `__getattr__`, and general descriptor compatibility are outside this subset. `type(obj)` is available; the three-argument dynamic `type(name, bases, dict)` form is not.

Strings are stored as valid UTF-8 and expose code point based indexing/slicing. The admitted methods are `strip`, `lstrip`, `rstrip`, `split`, `rsplit`, `splitlines`, `join`, `find`, `rfind`, `index`, `rindex`, `startswith`, `endswith`, `replace`, `count`, `lower`, `upper`, `title`, `capitalize`, `isdigit`, `isdecimal`, `isalpha`, `isalnum`, `isspace`, `removeprefix`, `removesuffix`, `format`, and `encode`. Supported Unicode classification/casing and regex character classes use pinned Unicode 15 data; Peony does not expose `unicodedata`, normalization, or locale-sensitive casing. `bytes` supports construction from a length, integer iterable, another bytes value, or text with a supported encoding; it also supports indexing, slicing, equality/hash, `find`, `split`, and `decode`. `bytearray` and `memoryview` are absent. Text encoding/decoding is limited to UTF-8 and ASCII aliases where documented by the API.

F-strings admit `!s`, `!r`, `!a` conversions. `format()`, f-string specifications, and `str.format()` share a formatting engine with alignment, sign, alternate form, zero padding, width, comma grouping, precision, and admitted string/integer/float codes. `str.format()` fields are empty, positional integer, or identifier fields; chained lookup and nested replacement fields in a format spec are excluded. Old `%` formatting supports ordinary string, integer, and float specifiers and tuple operands, but not mapping-key formats. Locale-aware `n` and arbitrary user `__format__` are excluded.

## Builtins

The following callable names are available. Their behavior is bounded by the value and syntax subset above.

```text
abs all any ascii bin bool bytes callable chr classmethod
delattr dict divmod enumerate filter float format getattr
hasattr hash hex id input int isinstance issubclass iter len
list map max min next object oct open ord pow print property
range repr reversed round set setattr slice sorted staticmethod
str sum super tuple type zip __import__
```

`print()` supports `sep`, `end`, `file`, and `flush`; `input(prompt)` uses the configured host callback and raises `EOFError` on EOF. `open()` accesses only the VFS. `breakpoint`, `compile`, `eval`, `exec`, `help`, `globals`, and `locals` are not offered. This is an intentional boundary around debugging, introspection, and executing arbitrary generated source.

## Files and imports

Python file objects support text and binary read/write/append/create modes, their supported `+` combinations, iteration, context management, `read`, `readline`, `readlines`, `write`, `writelines`, `seek`, `tell`, `truncate`, `flush`, and `close`. Text files use UTF-8 and universal newline reading by default; `newline=""` preserves input line endings. Text `tell()` values are opaque cookies usable with Peony's `seek()`, not portable byte offsets. The VFS roots are `/course` (read-only), `/home` (writable), and `/tmp` (ephemeral). Python code cannot access the host filesystem.

Imports resolve supported Zig native modules and learner modules/packages in the VFS. A native module name wins over a same-named learner file when first resolved, and `sys.modules` is the run's import cache. No `.py` implementation files are shipped for builtins or libraries: Python source in this project is learner input supplied at runtime.

## Explicit boundaries

- Python 3.12 is the language target; Peony does not claim full Python or CPython compatibility.
- Non-UTF-8 source, non-ASCII identifiers, complex numbers, async execution, exception groups, unrestricted pattern matching, and arbitrary runtime code generation are excluded.
- JSON accepts UTF-8 bytes and rejects lone surrogate escapes because Peony strings must be valid UTF-8. A decoded or encoded JSON string token is limited to 256 KiB.
- Unknown-length starred unpacking has a 65,536-item bound. This bound is separate from the configurable session memory and work limits.
- Cancellation is a hard stop and does not run Python `finally` blocks or finalizers. Work exhaustion is a terminal run status.
- `random` sequences are stable for a Peony version and seed, but are not CPython's generator sequence. Browser HTTP and TLS behavior is constrained by the host's fetch and security policies.

See [architecture](architecture.md) for how these boundaries are enforced and [libraries](libraries.md) for exact importable utilities.
