# Peony WASM ABI v1

The ABI targets `wasm32-freestanding`. All pointers and lengths are unsigned 32-bit byte offsets into the exported `memory`. A zero pointer represents an empty slice or a failed pointer lookup/allocation.

## Exported functions

| Export | Signature | Behavior |
|---|---|---|
| `peony_abi_version` | `() -> u32` | Returns `1`. |
| `peony_transfer_alloc` | `(len: u32) -> ptr: u32` | Allocates a writable input block. Returns `0` for zero length, allocation failure, or a full transfer table. |
| `peony_transfer_free` | `(ptr: u32, len: u32) -> void` | Frees a live block only when both values match its original allocation. Other requests are ignored. |
| `peony_session_new` | `(config_ptr: u32, config_len: u32) -> handle: u32` | Accepts only empty config `(0, 0)`. Returns `0` if the config is invalid, allocation fails, or all 64 slots are occupied. |
| `peony_session_destroy` | `(handle: u32) -> status: u32` | Destroys a live session and advances its slot generation. |
| `peony_compile_and_start` | `(handle, src_ptr, src_len, filename_ptr, filename_len: u32) -> status: u32` | Compiles a source slice and starts it in the session. Non-empty input slices must lie inside live transfer allocations. |
| `peony_run` | `(handle, quantum: u32) -> status: u32` | Runs at most `quantum` bytecode instructions. A quantum of `0` selects the default `50,000`. |
| `peony_resume` | `(handle, packet_ptr, packet_len: u32) -> status: u32` | Validates the packet slice, then returns `UNSUPPORTED`; host resume packets are not implemented yet. |
| `peony_cancel` | `(handle: u32) -> status: u32` | Requests cancellation. The next `peony_run` returns `CANCELLED`. |
| `peony_event_ptr`, `peony_event_len` | `(handle: u32) -> ptr/len: u32` | Events are not implemented; return `0`. |
| `peony_stdout_ptr`, `peony_stdout_len` | `(handle: u32) -> ptr/len: u32` | Return a borrowed view of buffered standard output, or zero when empty/invalid. |
| `peony_stdout_consume` | `(handle, len: u32) -> status: u32` | Removes `len` bytes from the start of buffered output; rejects lengths beyond the buffer. |
| `peony_stderr_ptr`, `peony_stderr_len` | `(handle: u32) -> ptr/len: u32` | Standard error is not implemented; return `0`. |
| `peony_stderr_consume` | `(handle, len: u32) -> status: u32` | Accepts only `len == 0`. |
| `peony_error_ptr`, `peony_error_len` | `(handle: u32) -> ptr/len: u32` | Return a borrowed UTF-8 diagnostic or exception message, or zero when empty/invalid. |

The current compiler executes scalar expressions and assignments, `if`/`elif`/`else`, `while`/`else`, `for`/`else`, short-circuit Boolean operations, comparisons, and lazy arbitrary-precision integer `range(...)`. It supports ordinary `def` functions, explicit and implicit returns, recursion, nested calls, mutable lexical closures, `global`/`nonlocal`, positional-only and keyword-only parameters, defaults, annotations evaluated at definition time, and direct keyword argument binding. Calls preserve left-to-right evaluation and source-positioned Python exceptions across WASM timeslices. Lists and tuples support iteration, indexing, slicing, concatenation, repetition, unpacking, and the implemented list methods; list item and name deletion are supported. Unicode strings and bytes support indexing and slicing, and the implemented string methods include `strip`, `split`, `join`, `find`, `replace`, `count`, `startswith`, `endswith`, `lower` and `upper`. The callable builtins include `print`, `range`, `len`, `list`, `tuple`, `iter`, `next`, `enumerate`, `zip` and `reversed`; `print` supports `sep` and `end`. Positional `*iterable` calls and function `*args` are supported. Starred unpacking allocates exact temporary storage for known-length inputs; unknown-length iterators have a temporary 65,536-item limit and raise `MemoryError` beyond it. Dictionary and set literals, `**mapping`, `**kwargs`, classes, comprehensions, generators, `assert`, events and host resume packets remain outside this subset and return `UNSUPPORTED` with a diagnostic when recognized during compilation.

## Status values

Values `0` through `4` retain their original ABI v1 meanings. Execution statuses are appended without renumbering them.

| Value | Name | Meaning |
|---:|---|---|
| `0` | `OK` | The operation completed. |
| `1` | `UNSUPPORTED` | The syntax or host operation is outside the implemented subset. |
| `2` | `INVALID_HANDLE` | The handle is zero, stale, out of range or destroyed. |
| `3` | `INVALID_ARGUMENT` | A slice is outside a live transfer allocation or a stream consume exceeds its buffer. |
| `4` | `OUT_OF_MEMORY` | Reserved operation-level allocation status. Session creation and transfer allocation report failure as a zero handle/pointer; execution allocation failures are Python `MemoryError` exceptions. |
| `5` | `COMPLETED` | The current program finished. |
| `6` | `PYTHON_EXCEPTION` | Compilation or execution raised a Python syntax/runtime exception; inspect the error view. |
| `7` | `TIMESLICE` | The instruction quantum expired; call `peony_run` again to continue. |
| `8` | `CANCELLED` | A cancellation request stopped the program. |
| `9` | `INTERNAL_ERROR` | A corrupt bytecode or engine invariant failure occurred; it is not a Python exception. |

`COMPILE_AND_START` returns `OK` for a compiled program, `UNSUPPORTED` for valid syntax outside the supported subset, and `PYTHON_EXCEPTION` for syntax or compilation-time Python errors. `RUN` returns one of `COMPLETED`, `PYTHON_EXCEPTION`, `TIMESLICE`, `CANCELLED` or `INTERNAL_ERROR`.

## Ownership and handle lifetime

- JavaScript writes config, source, filename and resume data into `peony_transfer_alloc` blocks. Non-empty input slices must be contained in live blocks. Free each block with its original pointer and length after the consuming call; source and filename are consumed during compilation, and the compiled code owns its needed data.
- Empty slices use `(ptr, len) == (0, 0)`. A non-empty source, filename or resume slice must lie wholly inside one live transfer block. At most 256 transfer blocks may be live at once.
- A session handle packs a 24-bit generation in the upper bits and a slot token in the low 8 bits. The low byte is `1..64`; zero is never valid. Destroyed handles fail validation even after their slot is reused.
- Standard output is buffered per session. Copy or decode borrowed output/error bytes before the next mutating call on that session or before destroying it. `peony_stdout_consume` removes a validated prefix. Compiling a new valid program resets the prior program, output and error state; sessions do not share output or globals.
- `memory.grow()` detaches existing JavaScript typed-array views. Recreate every `Uint8Array`/`DataView` from the current `memory.buffer` after a call that may allocate or grow memory.
- The fixed session table and transfer table are instance-local. Create separate WASM instances for fully separate tables.
