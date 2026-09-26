# Python language surface

Peony compiles Python 3.12 source to register bytecode and runs it in a Zig virtual machine. The same compiler, object model, and execution rules serve the native executable and browser Worker. This guide maps the language features and observable behavior. [Architecture](architecture.md) explains the implementation, [libraries](libraries.md) covers imports, and the [native](native-cli.md) and [browser](embedding.md) guides describe each host.

## Source text and tokens

Source uses UTF-8. Peony accepts an initial UTF-8 BOM and UTF-8 coding cookies on the first line, or the second line when the first is blank or a comment. LF, CRLF, and CR newlines are normalized during tokenization. Indentation and dedentation, comments, semicolons, backslash continuation, and expression continuation inside brackets follow Python syntax. Tabs expand by Python column rules, with `TabError` for ambiguous indentation.

Identifiers use ASCII letters, digits, and underscores with Python's first-character rule. Strings hold Unicode text as valid UTF-8. `match`, `case`, `_`, and `type` act as soft keywords in their grammar positions. Integer literals support decimal, binary, octal, hexadecimal, and underscore forms; floating literals support decimal and exponent forms.

Strings support ordinary, raw, bytes, and formatted forms, single and triple quotes, compatible prefixes, and adjacent literal concatenation. F-string expressions use the expression grammar and support escaped braces. A string index or slice advances by Unicode code point, while a bytes index advances by byte.

## Statements and expressions

| Area | Forms |
|---|---|
| Assignment | Simple, chained, annotated, and augmented assignment; attribute and item targets; destructuring with a starred target; deletion |
| Flow | `if`/`elif`/`else`, `while`/`else`, `for`/`else`, `break`, `continue`, `pass`, `return`, `assert` |
| Exceptions | `raise`, `raise ... from ...`, `try`/`except`/`else`/`finally`, `with` |
| Definitions | `def`, `class`, decorators, `lambda`, `global`, `nonlocal`, `yield` |
| Modules | `import`, `from ... import ...`, aliases, packages, relative imports |
| Pattern matching | `match`/`case` with literals, signed numbers, singletons, wildcard, capture, OR patterns, guards |
| Displays | Tuple, list, set, and dictionary displays; starred sequence elements and dictionary `**` unpacking |
| Comprehensions | List, set, and dictionary comprehensions; generator expressions |

Expressions include names, literals, calls, attributes, indexing, slicing, unary operators, arithmetic, bitwise operators, comparisons, identity, membership, Boolean short circuit, chained comparisons, conditional expressions, and assignment expressions. The compiler applies Python precedence and source order. `match` evaluates its subject once, then checks each case and guard in sequence. OR alternatives bind the same names. Compiler diagnostics report filename, line, and column for source forms it cannot compile.

## Scope, functions, and classes

Scope analysis runs before bytecode generation. An assignment makes a name local to its function unless the function declares it `global` or `nonlocal`. Nested functions capture cells for free variables. Comprehensions have their own binding scope. Local reads before assignment raise the corresponding Python error.

Functions support positional and keyword calls, defaults, positional-only and keyword-only parameters, `*args`, `**kwargs`, decorators, and closures. Argument binding detects missing, duplicate, and unexpected arguments. Default expressions and function annotations are evaluated when `def` executes; parameter and return values enter `__annotations__`. Module and class name annotations populate their scope's annotation dictionary.

Calling a generator function creates a suspended generator. Iteration or `next()` starts it; `send()` resumes it with a value, and `close()` follows the generator's normal unwinding path. `StopIteration.value` carries a returned value. A suspended generator retains its VM frame and garbage-collector roots.

User classes support construction, instance and class attributes, multiple inheritance with C3 method resolution, methods, `property`, `staticmethod`, `classmethod`, `super()`, and special-method dispatch through operators and builtins. `type(obj)`, `isinstance`, and `issubclass` use the same type graph for Zig native objects and user classes.

## Values and collections

Core values include `None`, `bool`, arbitrary-precision `int`, binary `float`, Unicode `str`, immutable `bytes`, mutable `list`, immutable `tuple`, ordered `dict`, `set`, `range`, and `slice`. Functions, generators, classes, instances, modules, exceptions, and files are objects in the same runtime heap. `NotImplemented` and `Ellipsis` are available singletons.

Lists support indexing, slicing, append, extend, insert, pop, remove, clear, count, index, reverse, copy, and stable sort. Dictionaries support keyed access, mutation, `get`, views, `pop`, `setdefault`, `update`, `clear`, and copy; iteration follows insertion order. Sets support membership and their usual algebraic operations. `for`, comprehensions, `enumerate`, `zip`, `map`, `filter`, `reversed`, `sorted`, and `range` use the VM iterator protocol.

Hashing and equality are shared across collections and native objects. Numeric equality and hashes preserve Python relationships across bool, int, and float values. String and byte hashes use per-run seeds. Random number generation has separate state through the `random` module.

## Strings, bytes, and formatting

String methods include `strip`, `lstrip`, `rstrip`, `split`, `rsplit`, `splitlines`, `join`, `find`, `rfind`, `index`, `rindex`, `startswith`, `endswith`, `replace`, `count`, `lower`, `upper`, `title`, `capitalize`, `isdigit`, `isdecimal`, `isalpha`, `isalnum`, `isspace`, `removeprefix`, `removesuffix`, `format`, and `encode`. Classification and casing use pinned Unicode 15 data.

`bytes()` accepts a length, iterable of byte values, bytes value, or text with an encoding. Bytes support indexing, slicing, equality, hashing, `find`, `split`, and `decode`. Text encoding and byte decoding support UTF-8 and ASCII aliases.

One formatting engine serves `format(value, spec)`, f-string specifications, and `str.format()`. F-strings support `!s`, `!r`, and `!a`. Specifications cover fill, alignment, signs, alternate form, zero padding, width, comma grouping, precision, and string, integer, and float codes. Old `%` formatting supports string, integer, and float conversions with tuple operands.

## Builtins and exceptions

The callable builtin set is:

```text
abs all any ascii bin bool bytes callable chr classmethod delattr dict
divmod enumerate filter float format getattr hasattr hash hex id input
int isinstance issubclass iter len list map max min next object oct open
ord pow print property range repr reversed round set setattr slice
sorted staticmethod str sum super tuple type zip __import__
```

`print()` supports `sep`, `end`, `file`, and `flush`. `sys.stdout` and `sys.stderr` expose writable streams. `input(prompt)` writes its prompt, then reads one host line; host EOF raises `EOFError`. `open()` uses the active filesystem host.

Python exceptions cover syntax, name, type, value, arithmetic, key and index, import, file, Unicode, and iteration errors. `try`/`except`, `else`, `finally`, and `with` use VM unwind state. An unhandled exception reaches the host with a message and source frames. Work exhaustion and hard cancellation produce terminal run results; ordinary Python exceptions follow their `finally` and context-manager paths.

## Files and imports

File objects support text and binary `r`, `w`, `a`, and `x` modes with `+` combinations, iteration, context management, `read`, `readline`, `readlines`, `write`, `writelines`, `seek`, `tell`, `truncate`, `flush`, and `close`. Text I/O uses UTF-8. Default reads translate CR and CRLF to LF; `newline=""` preserves line endings. A text `tell()` value can be passed back to that file's `seek()`.

On native targets, files are operating system files. Relative paths use the process working directory. Imports search beside the entry script and in the working directory. File writes persist on disk.

In the browser, file bytes and directories live in Worker JavaScript. `/assets` contains content mounted by the page, `/home` contains writable session content, and `/tmp` contains scratch files for a run. User imports search those roots in that order. Browser file handles retain their content node across rename and unlink. Consecutive runs create fresh Python globals and import caches while preserving `/assets` and `/home` browser files.

The module registry resolves Zig libraries through ordinary Python imports. User modules are `.py` files; packages use `__init__.py`. `sys.modules` is the active run's module cache. Module execution uses the VM and Python exception path. See the [library guide](libraries.md) for importable modules and functions.
