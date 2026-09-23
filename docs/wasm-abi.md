# Peony WASM ABI v1

The ABI is a low-level boundary for `wasm32-freestanding`. Its sole normal consumer is the JavaScript wrapper. All pointers and lengths are unsigned 32-bit byte offsets into the exported `memory` object. A zero pointer is reserved for an empty slice or failure.

## Exported functions

| Export | Signature | Commit 1 behavior |
|---|---|---|
| `peony_abi_version` | `() -> u32` | Returns `1`. |
| `peony_transfer_alloc` | `(len: u32) -> ptr: u32` | Allocates a writable transfer block; returns `0` for a zero length, allocation failure, or a full allocation table. |
| `peony_transfer_free` | `(ptr: u32, len: u32) -> void` | Frees a live block only when both pointer and original length match. Other requests are ignored. |
| `peony_session_new` | `(config_ptr: u32, config_len: u32) -> handle: u32` | Accepts the empty config `(0, 0)` and returns a generation-tagged handle; returns `0` for other configs or when all 64 slots are occupied. |
| `peony_session_destroy` | `(handle: u32) -> status: u32` | Destroys a live session and advances its slot generation. |
| `peony_compile_and_start` | `(handle, src_ptr, src_len, filename_ptr, filename_len: u32) -> status: u32` | Requires each non-empty input slice to lie within a live transfer allocation, then reports `UNSUPPORTED`. |
| `peony_run` | `(handle, quantum: u32) -> status: u32` | Reports `UNSUPPORTED` for a live session. |
| `peony_resume` | `(handle, packet_ptr, packet_len: u32) -> status: u32` | Requires a live transfer allocation for a non-empty packet, then reports `UNSUPPORTED`. |
| `peony_cancel` | `(handle: u32) -> status: u32` | Returns `OK` for a live session. |
| `peony_event_ptr`, `peony_stdout_ptr`, `peony_stderr_ptr`, `peony_error_ptr` | `(handle: u32) -> ptr: u32` | Return borrowed byte pointers, or `0` when there is no data or the handle is invalid. |
| `peony_event_len`, `peony_stdout_len`, `peony_stderr_len`, `peony_error_len` | `(handle: u32) -> len: u32` | Return byte lengths, or `0` when there is no data or the handle is invalid. |
| `peony_stdout_consume`, `peony_stderr_consume` | `(handle, len: u32) -> status: u32` | Accept only `len == 0` while these streams are empty. |

## Status values

| Value | Name | Meaning |
|---:|---|---|
| `0` | `OK` | The operation completed. |
| `1` | `UNSUPPORTED` | Python compilation and execution are not implemented in this ABI skeleton. |
| `2` | `INVALID_HANDLE` | The handle is zero, stale, out of range, or already destroyed. |
| `3` | `INVALID_ARGUMENT` | An input slice is outside a live transfer allocation or a stream consume exceeds its empty buffer. |
| `4` | `OUT_OF_MEMORY` | Reserved for later session allocation failures. |

The error view after an unsupported compile/run/resume call contains the UTF-8 text `Peony v0.1 language execution is not implemented yet`. Event, stdout and stderr views are empty in this commit.

## Ownership and handle lifetime

- JavaScript writes config, source, filename and resume bytes only into `peony_transfer_alloc` blocks. Free with the same pointer and length after the consuming call; commit 1 does not retain transfer blocks.
- Empty input slices use `(ptr, len) == (0, 0)`. Non-empty source, filename and resume slices must fall entirely inside a currently live transfer block.
- A transfer block must be non-empty. At most 256 blocks may be live at once.
- A session handle packs a 24-bit generation in the upper bits and a slot token in the low 8 bits. The low byte is `1..64`; zero is never valid. Session slots are fixed and local to one WASM instance. A destroyed handle fails validation even when its slot is reused.
- `*_ptr`/`*_len` results are borrowed. Copy or decode them before another mutating call on that session or before destroying the session. The error text is static in this skeleton, but callers should follow the general borrowed-view rule.
- `memory.grow()` detaches existing JavaScript typed-array views. Recreate every `Uint8Array`/`DataView` from the current `memory.buffer` after any call that may allocate or grow memory.
- Multiple sessions can coexist in one instance. The fixed handle table is instance-global; there is no interpreter state yet.

The artifact is a deliberate ABI skeleton. A valid session call that would compile, run or resume Python returns `UNSUPPORTED`; it does not claim to execute Python source.
