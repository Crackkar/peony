# Peony WASM ABI v1

This is the internal interface between the Worker pump and the Zig engine. Embedding applications use the [Worker API](embedding.md). The ABI targets `wasm32-freestanding`; pointers and lengths are unsigned 32-bit byte offsets into exported `memory`. A zero pointer represents an empty slice or a failed pointer lookup/allocation.

## Exported functions

| Export | Signature | Behavior |
|---|---|---|
| `peony_abi_version` | `() -> u32` | Returns `1`. |
| `peony_transfer_alloc` | `(len: u32) -> ptr: u32` | Allocates a writable input block. Returns `0` for zero length, allocation failure, or a full transfer table. |
| `peony_transfer_free` | `(ptr: u32, len: u32) -> void` | Frees a live block only when both values match its original allocation. Other requests are ignored. |
| `peony_session_new` | `(config_ptr: u32, config_len: u32) -> handle: u32` | Accepts empty config `(0, 0)` for defaults or a versioned `PCFG` config in a live transfer block. Returns `0` for invalid config, allocation failure, or a full session table. |
| `peony_session_destroy` | `(handle: u32) -> status: u32` | Destroys a live session and advances its slot generation. |
| `peony_reset` | `(handle: u32) -> status: u32` | Cancels pending work without Python finalizers and resets the session program, output, pending host request, and diagnostics. |
| `peony_compile_and_start` | `(handle, src_ptr, src_len, filename_ptr, filename_len: u32) -> status: u32` | Compiles source from live transfer slices and starts it. |
| `peony_compile_and_start_argv` | `(handle, src_ptr, src_len, filename_ptr, filename_len, argv_ptr, argv_len: u32) -> status: u32` | Starts a program with validated, copied UTF-8 command arguments. Use `peony_compile_and_start` when argv is empty. |
| `peony_run` | `(handle, quantum: u32) -> status: u32` | Runs at most `quantum` bytecode steps and bounded native work. Zero uses the configured quantum. |
| `peony_resume` | `(handle, packet_ptr, packet_len: u32) -> status: u32` | Validates and applies a matching host response packet. Invalid or stale responses leave the pending request intact. |
| `peony_cancel` | `(handle: u32) -> status: u32` | Requests hard cancellation. The next `peony_run` returns `CANCELLED`; Python `finally`/exit code is skipped. |
| `peony_event_ptr`, `peony_event_len` | `(handle: u32) -> ptr/len: u32` | Return a borrowed request or flush event packet, or zero when no event is available. |
| `peony_stdout_ptr`, `peony_stdout_len` | `(handle: u32) -> ptr/len: u32` | Return a borrowed view of buffered standard output, or zero when empty/invalid. |
| `peony_stdout_consume` | `(handle, len: u32) -> status: u32` | Removes `len` bytes from the start of buffered output; rejects lengths beyond the buffer. |
| `peony_vfs_mount` | `(handle, path_ptr, path_len, data_ptr, data_len: u32) -> status: u32` | Copies a course file into the session VFS as read-only content. Inputs must be live transfer slices. |
| `peony_vfs_write` | `(handle, path_ptr, path_len, data_ptr, data_len: u32) -> status: u32` | Copies or replaces a writable `/home` or `/tmp` file. |
| `peony_vfs_read` | `(handle, path_ptr, path_len: u32) -> status: u32` | Selects a file's bytes for borrowing through `peony_vfs_data_ptr/len`. |
| `peony_vfs_list` | `(handle, path_ptr, path_len: u32) -> status: u32` | Selects sorted, NUL-separated full file paths below a directory for borrowing through `peony_vfs_data_ptr/len`. |
| `peony_vfs_dirs` | `(handle, path_ptr, path_len: u32) -> status: u32` | Selects sorted, NUL-separated full descendant directory paths, excluding the queried root, through `peony_vfs_data_ptr/len`. |
| `peony_vfs_mkdir` | `(handle, path_ptr, path_len: u32) -> status: u32` | Creates a writable VFS directory and any missing parents; an existing directory succeeds. |
| `peony_vfs_data_ptr`, `peony_vfs_data_len` | `(handle: u32) -> ptr/len: u32` | Return the borrowed result of the last read/list operation, or zero when empty/invalid. |
| `peony_stderr_ptr`, `peony_stderr_len` | `(handle: u32) -> ptr/len: u32` | Return a borrowed view of buffered standard error, or zero when empty/invalid. |
| `peony_stderr_consume` | `(handle, len: u32) -> status: u32` | Removes a validated prefix of the standard-error buffer. |
| `peony_error_ptr`, `peony_error_len` | `(handle: u32) -> ptr/len: u32` | Return a borrowed UTF-8 diagnostic or exception message, or zero when empty/invalid. |
| `peony_traceback_ptr`, `peony_traceback_len` | `(handle: u32) -> ptr/len: u32` | Return borrowed UTF-8 JSON for an unhandled exception's traceback or a compile diagnostic's source frame, or zero when empty/invalid. Each frame has `filename`, `name`, `line`, `column`, and `source_line`. |
| `peony_instruction_count`, `peony_work_count` | `(handle: u32) -> u64` | Return per-run bytecode and combined bytecode/native-work counters. |
| `peony_session_live_bytes`, `peony_session_peak_bytes` | `(handle: u32) -> u64` | Return live and peak session allocation bytes. |
| `peony_gc_object_count`, `peony_gc_collection_count` | `(handle: u32) -> u64` | Return current heap object and completed collection counts. |
| `peony_vfs_total_bytes` | `(handle: u32) -> u64` | Return total VFS content bytes. |
| `peony_collect_garbage` | `(handle: u32) -> status: u32` | Collect the session heap while VM work is idle. Permanent runtime roots remain registered. |

## Host packets

All packet integers are little-endian. The 24-byte header is followed by `section_count` 12-byte descriptors and then section payloads. Packets are limited to 1 MiB total before decoding or session allocation. UTF-8 sections are validated before a packet can mutate a session.

| Header offset | Type | Field |
|---:|---|---|
| 0 | 4 bytes | ASCII magic `PEON` |
| 4 | `u16` | Packet version, currently `1` |
| 6 | `u16` | Kind: `1` input, `2` HTTP, `3` sleep, `4` clock, `5` output/flush event |
| 8 | `u32` | Nonzero per-session request/event id |
| 12 | `u16` | Status: `0` success, `1` EOF, `2` host error |
| 14 | `u16` | Flags, currently zero |
| 16 | `u16` | Section count, at most 64 |
| 18 | `u16` | Reserved, must be zero |
| 20 | `u32` | Total packet length |

Each descriptor contains a `u16` section kind (`1` UTF-8, `2` binary), a zero `u16` reserved field, and `u32` payload offset and length. Descriptors may not overlap each other or the descriptor table, and every section must fit inside the total packet.

An input request has kind `1` and one UTF-8 section containing the prompt. A success response has the same kind and request id with one UTF-8 section; one trailing `LF` and optional preceding `CR` are removed. EOF has status `1` and no sections. Input host error has status `2` and one UTF-8 message section; Python receives `OSError`. `peony_resume` checks the fixed envelope, kind and pending request id before allocating from the session heap; a malformed, stale or wrong-kind packet leaves the request pending.

HTTP, clock and sleep use the same pending request identity and packet limit. Sections are ordered; `u16` and `f64` values are little-endian. HTTP headers are UTF-8 `name: value\r\n` lines. Native code validates URLs, methods, headers, finite durations, response status, and section schemas. An invalid response leaves the original request pending.

| Kind | Request sections | Successful response sections |
|---|---|---|
| `2` HTTP | UTF-8 method, UTF-8 HTTP(S) URL, UTF-8 header block, binary body, optional binary 8-byte timeout seconds | Binary 2-byte HTTP status (`100..599`), UTF-8 header block, binary body |
| `3` sleep | Binary 8-byte finite nonnegative seconds | No sections |
| `4` clock | UTF-8 `wall` or `monotonic` | Binary 8-byte finite seconds |

For these kinds, host error has status `2` and two UTF-8 sections: a classification and a message. HTTP classifications are `connection`, `policy`, and `timeout`; clock and sleep failures use `clock` and `sleep`. Native library code maps failures to its documented Python exception classes. EOF is invalid for these kinds. The total HTTP reply budget includes the packet header, descriptors, status and headers as well as the body.

`print(..., flush=True)` creates a kind `5` output event with zero sections. It marks a drain boundary; stdout bytes remain available through `peony_stdout_ptr/len` and the host consumes them in the ordinary way without sending a response packet. Keeping output in the borrowed stdout buffer means a large flush is not constrained by the 1 MiB packet limit.

Session config is either empty, which selects defaults, or a `PCFG` version 1 record. The fixed 28-byte header stores flags, `max_memory_bytes` (`u32`), `max_instructions` (`u64`), `quantum` (`u32`), seed length (`u16`), and an extension length (`u16`); up to 1,024 seed bytes follow. Extension length `0` selects default VFS limits. Extension length `8` adds `max_vfs_bytes` (`u32`) and `max_file_bytes` (`u32`) after the seed. Other extension lengths, zero limits, a per-file limit above the VFS limit, invalid lengths, or unknown flags are rejected. Defaults are a 64 MiB session heap, 50,000,000 combined work units, a 50,000 instruction quantum, an 8 MiB total VFS content limit, and a 2 MiB single-file content limit.

| Config offset | Type | Field |
|---:|---|---|
| 0 | 4 bytes | ASCII `PCFG` |
| 4 | `u16` | Version `1` |
| 6 | `u16` | Flags: `0` for no seed, `1` for a nonempty seed |
| 8 | `u32` | Maximum session-accounted memory bytes |
| 12 | `u64` | Maximum combined work units |
| 20 | `u32` | Default execution quantum |
| 24 | `u16` | Seed byte length |
| 26 | `u16` | Extension length (`0` or `8`) |

The seed bytes start at offset 28; the optional VFS extension follows them. All numeric fields are little-endian. The entire record must have exactly the declared length.

The optional argv transfer is at most 64 KiB: a little-endian `u16` count (`0..256`), followed by each argument's little-endian `u32` byte length and UTF-8 bytes. Values cannot contain NUL. The record must end exactly after the last argument. Validation happens before the program is reset; accepted bytes are copied into session-accounted memory before the transfer block can be freed. `sys.argv` is `[filename, ...arguments]` and is built lazily on `import sys`.

## Status values

| Value | Name | Meaning |
|---:|---|---|
| `0` | `OK` | The operation completed. |
| `1` | `UNSUPPORTED` | The syntax or host operation is outside the implemented subset. |
| `2` | `INVALID_HANDLE` | The handle is zero, stale, out of range, or destroyed. |
| `3` | `INVALID_ARGUMENT` | A slice, packet, response, or stream consume is invalid. |
| `4` | `OUT_OF_MEMORY` | A VFS content limit or allocation failure. Session creation and transfer allocation report failure as a zero handle/pointer; execution allocation failures are Python `MemoryError` exceptions. |
| `5` | `COMPLETED` | The current program finished. |
| `6` | `PYTHON_EXCEPTION` | Compilation or execution raised a Python syntax/runtime exception; inspect the error view. |
| `7` | `TIMESLICE` | The requested bytecode quantum expired; call `peony_run` again to continue. |
| `8` | `CANCELLED` | A hard cancellation stopped the program. |
| `9` | `INTERNAL_ERROR` | A corrupt bytecode or engine invariant failure occurred; it is not a Python exception. |
| `10` | `HOST_REQUEST` | Input, HTTP, clock, or sleep is suspended; copy the event and resume it with a matching response. |
| `11` | `OUTPUT_EVENT` | An explicit output flush boundary is ready. |
| `12` | `LIMIT` | The configured per-run bytecode/native-work budget was reached. |

The compile-and-start exports return `OK` for a compiled program, `UNSUPPORTED` for recognized syntax outside the supported subset, and `PYTHON_EXCEPTION` for syntax or compilation-time Python errors. A runtime `LIMIT` is not a catchable Python exception.

## Ownership and handle lifetime

- JavaScript writes config, source, filename, and resume data into `peony_transfer_alloc` blocks. Non-empty input slices must be contained in live blocks. Free each block with its original pointer and length after the consuming call; source and filename are consumed during compilation, and host resume copies its validated UTF-8 value before returning.
- Empty slices use `(ptr, len) == (0, 0)`. At most 256 transfer blocks may be live at once.
- A session handle packs a 24-bit generation in the upper bits and a slot token in the low 8 bits. The low byte is `1..64`; zero is never valid. Destroyed handles fail validation after their slot is reused.
- Standard output is buffered per session. Copy borrowed output/event/error bytes before the next mutating call on that session or before destroying it. `peony_stdout_consume` removes a validated prefix. Starting a valid program resets prior program, output, event, and error state.
- VFS writes and mounts copy input bytes. `peony_vfs_read`, `peony_vfs_list`, and `peony_vfs_dirs` expose borrowed session-owned bytes through `peony_vfs_data_ptr/len`; copy them before the next `peony_run`, another VFS operation, program start/reset, or destruction. A run invalidates the view before Python code can replace a file. Course files are read-only. `/home` and `/course` survive raw `peony_reset` and program restart; `/tmp` is cleared. The public facade snapshots `/home` directories and file bytes when replacing a raw session between runs. Public `session.reset()` instead discards the VFS with the whole session; see [embedding](embedding.md).
- Event packets are borrowed until the next same-session mutation, reset, or destruction. Traceback JSON follows the same lifetime. Copy any data needed after those operations.
- `memory.grow()` detaches existing JavaScript typed-array views. Recreate every `Uint8Array`/`DataView` from the current `memory.buffer` after a call that may allocate or grow memory.
- The fixed session and transfer tables are instance-local. Separate WASM instances have separate tables.
