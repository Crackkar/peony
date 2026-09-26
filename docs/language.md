# Python language surface

Peony interprets a defined **Python 3.12 subset**. This page tells a lesson author which syntax and core objects can be used, how several important edges behave, and where the boundary is. It describes the Python visible surface of the current interpreter; the [architecture](architecture.md) explains the implementation, [libraries](libraries.md) covers imports, and [embedding](embedding.md) covers the JavaScript host.

A supported program is parsed, scoped, compiled, and executed as Python code in Peony's VM. Unsupported syntax receives a compile diagnostic when Peony recognizes it. Unknown imports and attributes use Python-style errors. This does not imply full CPython 3.12 compatibility, and an unlisted library method is not included just because its module is present.

## Source and lexical rules

Source is decoded as UTF-8. An initial UTF-8 BOM is accepted. A coding cookie is recognized on the first line, or on the second when the first line is blank or a comment; recognized cookies must name UTF-8 or UTF-8-SIG. A later `# coding:` line is an ordinary comment. LF, CRLF, and CR newlines are normalized. The lexer handles indentation and dedentation, comments, semicolon-separated simple statements, backslash line continuation, and implicit continuation inside `()`, `[]`, and `{}`. Tabs expand in Python-style columns; ambiguous tab/space indentation raises `TabError` rather than selecting an arbitrary interpretation.

Identifiers are ASCII letters, digits, and underscores with the usual first-character rule. Non-ASCII identifiers produce a diagnostic. This restriction applies to names, not string content: Unicode text is fully valid in literals and runtime strings. `match`, `case`, `_`, and `type` are soft keywords in the grammar positions that use them; ordinary assignments such as `case = 3` remain legal. Integer literals admit decimal, binary, octal, and hexadecimal forms and underscores; floats admit decimal and exponent forms. Complex `j` literals are explicitly excluded.

Literal strings admit ordinary, raw, bytes, and formatted forms, single/double/triple quotes, compatible prefixes, and adjacent literal concatenation. F-string replacement expressions use the supported expression grammar, and escaped braces are handled. Bytes literals hold bytes; normal strings hold valid UTF-8 data. A string index or slice operates on Unicode code points, not UTF-8 byte offsets or grapheme clusters.

## Statements and expressions

| Area | Admitted forms |
|---|---|
| Assignment | Simple and chained assignment, annotated assignment, augmented assignment, attribute/item targets, destructuring with one starred target, and deletion of supported targets |
| Flow | `if`/`elif`/`else`, `while`/`else`, `for`/`else`, `break`, `continue`, `pass`, `return`, `assert` |
| Exceptions | `raise`, `raise ... from ...`, `try`/`except`/`else`/`finally`, and `with` |
| Definitions | `def`, `class`, decorators, `lambda`, `global`, `nonlocal`, and `yield` in generators |
| Modules | `import`, `from ... import ...`, aliases, packages, and relative imports within a package |
| Pattern matching | `match`/`case` with literal, signed numeric, singleton, wildcard, capture, OR pattern, and guard |
| Displays | Tuple, list, set, and dict displays, starred sequence elements, and dict `**` unpacking |
| Comprehensions | List, set, and dict comprehensions; generator expressions |

Expressions cover names, literals, calls, attributes, indexing and slicing, unary `+ - ~ not`, arithmetic `+ - * / // % **`, bitwise `& | ^ << >>`, comparisons, identity (`is`), membership (`in`), Boolean short circuit, chained comparisons, conditional expressions, and assignment expressions outside comprehensions. Operators follow the implemented Python precedence and value rules. Matrix multiplication `@` is excluded. A comprehension assignment expression is rejected because its special binding rules are outside this subset. `yield from` is excluded, although `yield` and generator expressions are supported.

`match` evaluates its subject once. Literal patterns compare values; `None`, `True`, and `False` singleton patterns test identity. An OR pattern's alternatives must bind the same names, and an unguarded irrefutable case cannot be followed by unreachable cases. Sequence, mapping, and class patterns are excluded with targeted diagnostics. This is a bounded pattern surface, useful for branching examples without suggesting that all structural matching is present.

## Names, functions, and classes

Scope analysis happens before execution. Assigning to a name makes it local to that function unless declared `global` or `nonlocal`; nested functions capture cells for free variables. Comprehensions have their own binding scope. The VM uses this analysis for reads and writes, so a local referenced before assignment raises the appropriate Python error rather than silently reading a global. Import names live in the current module environment and are cached during that run.

Functions support positional and keyword calls, defaults, positional-only and keyword-only parameters, `*args`, `**kwargs`, decorators, and closures. Argument binding checks missing, duplicate, unexpected, and positional-only keyword arguments. Default expressions and ordinary function annotations are evaluated when `def` executes. Parameter and return annotations are stored in `__annotations__`. Module/class name annotations populate that scope's `__annotations__`; function-local variable annotation expressions are not evaluated. `from __future__ import annotations` is not supported.

Calling a generator function creates a suspended generator. Iteration or `next()` starts it; `send()` and `close()` are admitted, including `StopIteration.value` on completion and normal `finally` behavior on `close()`. A generator suspended in the VM retains its frame and roots. The runtime does not offer `yield from`, coroutine/async generator execution, or exception-group syntax.

User classes support normal construction, instance and class attributes, multiple inheritance with C3 method resolution, methods, `property`, `staticmethod`, `classmethod`, `super()`, and the documented special-method dispatch used by operators and builtins. The three-argument dynamic `type(name, bases, dict)` constructor, custom metaclasses, custom `__new__`, general user descriptors, `__getattr__`, and `__getattribute__` are outside the subset. `type(obj)`, `isinstance`, and `issubclass` are available within the supported type graph. Native library types expose their stated relationships; arbitrary subclassing of every native type is not implied.

## Core values and containers

The core values are `None`, `bool`, arbitrary-precision `int`, binary floating-point `float`, Unicode `str`, immutable `bytes`, mutable `list`, immutable `tuple`, insertion-ordered `dict`, `set`, `range`, and `slice`, plus functions, generators, classes/instances, modules, exceptions, and file objects. `NotImplemented` and `Ellipsis` are available singletons. Small integers may be immediate in the WASM representation; arithmetic promotes to a heap bigint when needed. Booleans retain their Python numeric relationship while remaining a distinct type.

Lists support indexing, slicing, append/extend/insert/pop/remove/clear, count/index, reverse/copy, and sort. Dictionaries support keyed access and mutation, `get`, `keys`, `values`, `items`, `pop`, `setdefault`, `update`, `clear`, and `copy`; their iteration order follows insertion order. Sets support membership, addition/removal, update, pop, clear, copy, and the admitted set operators. Tuples and bytes are immutable. Iteration, `for`, comprehensions, `enumerate`, `zip`, `map`, `filter`, `reversed`, `sorted`, and `range` use the VM's iterator protocol. Mutating a dictionary while iterating is checked; set iteration order is not promised to match CPython.

Hashing and equality are shared across containers and native objects. Peony gives each run a varying hash seed for strings and bytes, but does not promise cryptographic unpredictability. Numeric equality and hashes are designed to preserve Python relationships across bool/int/float values where admitted. `random` is a separate library state with its own documented seed behavior.

## Text, bytes, and formatting

The admitted `str` methods are `strip`, `lstrip`, `rstrip`, `split`, `rsplit`, `splitlines`, `join`, `find`, `rfind`, `index`, `rindex`, `startswith`, `endswith`, `replace`, `count`, `lower`, `upper`, `title`, `capitalize`, `isdigit`, `isdecimal`, `isalpha`, `isalnum`, `isspace`, `removeprefix`, `removesuffix`, `format`, and `encode`. The implementation uses pinned Unicode 15 data for supported classification and casing behavior. Peony does not expose normalization, `unicodedata`, locale-sensitive casing, or full Unicode identifier classification.

`bytes()` accepts zero length, a nonnegative integer length, an iterable of byte values, another bytes value, or text with an explicit supported encoding. Bytes support indexing to an integer, slicing to bytes, equality/hash, `find`, `split`, and `decode`. String `encode` and bytes `decode` admit UTF-8 and ASCII aliases; unsupported codecs raise `LookupError`. `bytearray` and `memoryview` are absent.

Formatting has one engine behind `format(value, spec)`, f-string specifications, and `str.format()`. F-strings admit `!s`, `!r`, and `!a`. Specifications cover fill/alignment, signs, alternate form, zero padding, width, comma grouping, precision, and the admitted string, integer, and float codes. `str.format()` fields may be empty, positional numbers, or identifiers; chained attribute/index lookups and nested replacement fields inside format specs are excluded. Old `%` formatting admits common string, integer, and float conversions and tuple operands; mapping-key formats are excluded. Unsupported formatting raises an error rather than being ignored.

## Builtins and exceptions

These callable builtins are exposed, subject to the supported object model:

```text
abs all any ascii bin bool bytes callable chr classmethod delattr dict
divmod enumerate filter float format getattr hasattr hash hex id input
int isinstance issubclass iter len list map max min next object oct open
ord pow print property range repr reversed round set setattr slice
sorted staticmethod str sum super tuple type zip __import__
```

`print()` supports `sep`, `end`, `file`, and `flush`; the builtin streams are exposed through `sys.stdout` and `sys.stderr`. `input(prompt)` writes the prompt and returns a line without its trailing line ending, raises `EOFError` for host EOF, and maps a host failure to a Python error. `open()` accesses the session VFS. `breakpoint`, `compile`, `eval`, `exec`, `help`, `globals`, and `locals` are deliberately absent. There is no frame-introspection API hidden behind those names.

Python exception classes include the ordinary syntax, name, type, value, arithmetic, key/index, import, file, Unicode, and iterator errors needed by the admitted surface. `try`/`except` catches Python exceptions, while `else` and `finally` run according to their control-flow roles. `with` calls context-manager entry and exit through the VM. A compiled program can still terminate with an unhandled exception; the host receives a message and traceback frames with source positions. Work-budget exhaustion and hard cancellation are terminal host results, not catchable Python exceptions. Hard cancellation skips Python `finally`; ordinary exception unwinding does not.

## Files and imports

File objects support text and binary `r`, `w`, `a`, and `x` modes and the admitted `+` combinations, iteration, context management, `read`, `readline`, `readlines`, `write`, `writelines`, `seek`, `tell`, `truncate`, `flush`, and `close`. Text I/O uses UTF-8; default reads translate CR and CRLF to LF, while `newline=""` preserves input line endings. Text `tell()` returns a Peony cookie for its own `seek()`, not a general byte offset. A file's bytes come from `/course`, `/home`, or `/tmp`, never the host filesystem. Open file handles retain their content node across a VFS rename or unlink.

Imports resolve registered Zig native modules and `.py` learner modules/packages stored in the VFS. Native names have precedence when first resolved. Learner modules are searched under `/home`, `/course`, then `/tmp`; package source is `__init__.py`. `sys.modules` is the active run's cache. The host can mount a lesson's Python source as a VFS file, but Peony ships no Python-source implementation of its own libraries. Consecutive public `run()` calls use new globals and import caches while keeping `/course` and `/home` files; `session.reset()` clears the session, including those files.

## Explicit compatibility boundary

Peony does not claim full Python 3.12 or CPython behavior. The main excluded families are non-UTF-8 source encodings, non-ASCII identifiers, complex numbers, async syntax/runtime, `yield from`, exception groups/`except*`, unrestricted structural patterns, PEP 695 type syntax, dynamic code execution, custom metaclasses and full descriptors, user finalizers, and unlisted standard-library APIs. Browser/network policy is supplied by the host, and neither Python code nor the `ssl` teaching object can change browser TLS or CORS rules.

There are a few explicit bounds within admitted features. Unknown-length starred unpacking stops at 65,536 items. A decoded or encoded JSON string token is limited to 256 KiB. Session memory, VFS content, HTTP packets, and combined work have separate configurable or fixed limits. `random` sequences repeat within a Peony version for the same seed but do not match CPython's PRNG stream. These constraints are part of the practical language surface, not a promise of full conformance. See [libraries](libraries.md) for the exact importable APIs and [embedding](embedding.md) for host-visible limits and run outcomes.
