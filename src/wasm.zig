const std = @import("std");
const abi = @import("abi.zig");
const runtime_vm = @import("runtime_vm");
const host = @import("runtime_host");
const wasm_fs = @import("wasm_fs.zig");
const Runtime = runtime_vm.Runtime;

comptime {
    _ = @sizeOf(Runtime);
}

pub const std_options_debug_io: std.Io = std.Io.failing;

const Status = abi.Status;
const max_transfers = 256;
const generation_mask = abi.generation_mask;

const SessionSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    runtime: Runtime = undefined,
    fs_handle: u32 = 0,
    host_error: []const u8 = "",
};

const Transfer = struct {
    pointer: u32 = 0,
    bytes: []u8 = &.{},
};

var sessions: [abi.max_sessions]SessionSlot = [_]SessionSlot{.{}} ** abi.max_sessions;
var transfers: [max_transfers]Transfer = [_]Transfer{.{}} ** max_transfers;

export fn peony_abi_version() u32 {
    return abi.abi_version;
}

export fn peony_transfer_alloc(len: u32) u32 {
    if (len == 0) return 0;
    const free_slot = findFreeTransfer() orelse return 0;
    const bytes = std.heap.wasm_allocator.alloc(u8, @intCast(len)) catch return 0;
    const pointer: u32 = @intCast(@intFromPtr(bytes.ptr));
    transfers[free_slot] = .{ .pointer = pointer, .bytes = bytes };
    return pointer;
}

export fn peony_transfer_free(pointer: u32, len: u32) void {
    for (&transfers) |*transfer| {
        if (transfer.pointer == pointer and transfer.bytes.len == len) {
            std.heap.wasm_allocator.free(transfer.bytes);
            transfer.* = .{};
            return;
        }
    }
}

export fn peony_session_new(config_ptr: u32, config_len: u32) u32 {
    var config_bytes: []const u8 = &.{};
    if (config_len == 0) {
        if (config_ptr != 0) return 0;
    } else {
        if (!isTransferSlice(config_ptr, config_len)) return 0;
        config_bytes = transferSlice(config_ptr, config_len) orelse return 0;
    }
    const config = host.decodeConfig(config_bytes) catch return 0;
    for (&sessions, 0..) |*slot, index| {
        if (!slot.active) {
            slot.runtime.initWithConfig(std.heap.wasm_allocator, config) catch return 0;
            const handle = abi.encodeSessionHandle(index, slot.generation);
            if (!wasm_fs.configure(handle, config.max_vfs_bytes, config.max_file_bytes)) {
                slot.runtime.deinit();
                return 0;
            }
            slot.fs_handle = handle;
            slot.runtime.vfs.bindHost(wasm_fs.backend(&slot.fs_handle));
            slot.active = true;
            slot.host_error = "";
            return handle;
        }
    }
    return 0;
}

export fn peony_session_destroy(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.runtime.deinit();
    slot.active = false;
    slot.host_error = "";
    slot.generation = (slot.generation + 1) & generation_mask;
    if (slot.generation == 0) slot.generation = 1;
    return status(Status.ok);
}

export fn peony_compile_and_start(
    handle: u32,
    src_ptr: u32,
    src_len: u32,
    filename_ptr: u32,
    filename_len: u32,
) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.host_error = "";
    if (!isTransferSlice(src_ptr, src_len) or !isTransferSlice(filename_ptr, filename_len)) {
        return status(Status.invalid_argument);
    }
    const source = transferSlice(src_ptr, src_len) orelse return status(Status.invalid_argument);
    const filename = transferSlice(filename_ptr, filename_len) orelse return status(Status.invalid_argument);
    return switch (slot.runtime.compileAndStart(source, filename)) {
        .ready => status(Status.ok),
        .unsupported => status(Status.unsupported),
        .syntax_error, .python_exception => status(Status.python_exception),
    };
}

export fn peony_run(handle: u32, quantum: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.host_error = "";
    return switch (slot.runtime.run(quantum)) {
        .completed => status(Status.completed),
        .python_exception => status(Status.python_exception),
        .engine_error => status(Status.internal_error),
        .timeslice => status(Status.timeslice),
        .cancelled => status(Status.cancelled),
        .host_request => status(Status.host_request),
        .output_event => status(Status.output_event),
        .limit => status(Status.limit),
    };
}

export fn peony_resume(handle: u32, packet_ptr: u32, packet_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!isTransferSlice(packet_ptr, packet_len)) return status(Status.invalid_argument);
    const packet_bytes = transferSlice(packet_ptr, packet_len) orelse return status(Status.invalid_argument);
    const envelope = host.peekEnvelope(packet_bytes) catch return status(Status.invalid_argument);
    if (slot.runtime.pendingInputRequestId()) |request_id| {
        if (envelope.kind != .input or envelope.request_id != request_id) return status(Status.invalid_argument);
    } else if (slot.runtime.pendingNativeHost()) |pending| {
        if (envelope.kind != pending.kind or envelope.request_id != pending.request_id) return status(Status.invalid_argument);
    } else return status(Status.invalid_argument);
    var packet = host.decode(slot.runtime.heap.allocator, packet_bytes) catch |err| return switch (err) {
        error.InvalidPacket => status(Status.invalid_argument),
        error.OutOfMemory => status(Status.out_of_memory),
    };
    defer packet.deinit(slot.runtime.heap.allocator);
    if (!slot.runtime.resumeHost(&packet)) return status(Status.invalid_argument);
    slot.host_error = "";
    return status(Status.ok);
}

export fn peony_cancel(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.runtime.cancel();
    return status(Status.ok);
}

export fn peony_reset(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.runtime.reset();
    slot.host_error = "";
    return status(Status.ok);
}

export fn peony_vfs_mount(handle: u32, path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!isTransferSlice(path_ptr, path_len) or !isTransferSlice(data_ptr, data_len)) return status(Status.invalid_argument);
    const path = transferSlice(path_ptr, path_len) orelse return status(Status.invalid_argument);
    const data = transferSlice(data_ptr, data_len) orelse return status(Status.invalid_argument);
    slot.runtime.mountAssetFile(path, data) catch |err| return vfsErrorStatus(err);
    return status(Status.ok);
}

export fn peony_vfs_write(handle: u32, path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!isTransferSlice(path_ptr, path_len) or !isTransferSlice(data_ptr, data_len)) return status(Status.invalid_argument);
    const path = transferSlice(path_ptr, path_len) orelse return status(Status.invalid_argument);
    const data = transferSlice(data_ptr, data_len) orelse return status(Status.invalid_argument);
    slot.runtime.writeVfsFile(path, data) catch |err| return vfsErrorStatus(err);
    return status(Status.ok);
}

export fn peony_vfs_read(handle: u32, path_ptr: u32, path_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!isTransferSlice(path_ptr, path_len)) return status(Status.invalid_argument);
    const path = transferSlice(path_ptr, path_len) orelse return status(Status.invalid_argument);
    _ = slot.runtime.readVfsFile(path) catch |err| return vfsErrorStatus(err);
    return status(Status.ok);
}

export fn peony_vfs_list(handle: u32, path_ptr: u32, path_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!isTransferSlice(path_ptr, path_len)) return status(Status.invalid_argument);
    const path = transferSlice(path_ptr, path_len) orelse return status(Status.invalid_argument);
    _ = slot.runtime.listVfsFiles(path) catch |err| return vfsErrorStatus(err);
    return status(Status.ok);
}

export fn peony_vfs_dirs(handle: u32, path_ptr: u32, path_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!isTransferSlice(path_ptr, path_len)) return status(Status.invalid_argument);
    const path = transferSlice(path_ptr, path_len) orelse return status(Status.invalid_argument);
    _ = slot.runtime.listVfsDirectories(path) catch |err| return vfsErrorStatus(err);
    return status(Status.ok);
}

export fn peony_vfs_mkdir(handle: u32, path_ptr: u32, path_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!isTransferSlice(path_ptr, path_len)) return status(Status.invalid_argument);
    const path = transferSlice(path_ptr, path_len) orelse return status(Status.invalid_argument);
    slot.runtime.mkdirVfsDirectory(path) catch |err| return vfsErrorStatus(err);
    return status(Status.ok);
}

export fn peony_vfs_data_ptr(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    const bytes = slot.runtime.vfsData();
    if (bytes.len == 0) return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}

export fn peony_vfs_data_len(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    return @intCast(slot.runtime.vfsData().len);
}

export fn peony_event_ptr(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    const bytes = slot.runtime.eventBytes();
    if (bytes.len == 0) return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}

export fn peony_event_len(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    return @intCast(slot.runtime.eventBytes().len);
}

export fn peony_instruction_count(handle: u32) u64 {
    const slot = sessionSlot(handle) orelse return 0;
    return slot.runtime.instructionCount();
}

export fn peony_work_count(handle: u32) u64 {
    const slot = sessionSlot(handle) orelse return 0;
    return slot.runtime.workCount();
}

export fn peony_session_live_bytes(handle: u32) u64 {
    const slot = sessionSlot(handle) orelse return 0;
    return slot.runtime.session_allocator.live_bytes;
}

export fn peony_session_peak_bytes(handle: u32) u64 {
    const slot = sessionSlot(handle) orelse return 0;
    return slot.runtime.session_allocator.peak_bytes;
}

export fn peony_gc_object_count(handle: u32) u64 {
    const slot = sessionSlot(handle) orelse return 0;
    return slot.runtime.heap.object_count;
}

export fn peony_gc_collection_count(handle: u32) u64 {
    const slot = sessionSlot(handle) orelse return 0;
    return slot.runtime.heap.collection_count;
}

export fn peony_vfs_total_bytes(handle: u32) u64 {
    const slot = sessionSlot(handle) orelse return 0;
    return slot.runtime.vfs.totalBytes();
}

/// The caller must serialize this with VM work. The runtime's permanent roots
/// remain registered while the collector traces the session heap.
export fn peony_collect_garbage(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (slot.runtime.heap.collecting) return status(Status.invalid_argument);
    _ = slot.runtime.heap.collect();
    return status(Status.ok);
}

export fn peony_stdout_ptr(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    const bytes = slot.runtime.stdout();
    if (bytes.len == 0) return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}

export fn peony_stdout_len(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    return @intCast(slot.runtime.stdout().len);
}

export fn peony_stdout_consume(handle: u32, len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!slot.runtime.consumeStdout(len)) return status(Status.invalid_argument);
    return status(Status.ok);
}

export fn peony_stderr_ptr(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    const bytes = slot.runtime.stderr();
    if (bytes.len == 0) return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}

/// The argv blob is a u16 count followed by u32 byte lengths and UTF-8 values.
/// It is copied into the session before the host frees the transfer block.
export fn peony_compile_and_start_argv(
    handle: u32,
    src_ptr: u32,
    src_len: u32,
    filename_ptr: u32,
    filename_len: u32,
    argv_ptr: u32,
    argv_len: u32,
) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.host_error = "";
    if (!isTransferSlice(src_ptr, src_len) or !isTransferSlice(filename_ptr, filename_len) or !isTransferSlice(argv_ptr, argv_len)) return status(Status.invalid_argument);
    const source = transferSlice(src_ptr, src_len) orelse return status(Status.invalid_argument);
    const filename = transferSlice(filename_ptr, filename_len) orelse return status(Status.invalid_argument);
    const blob = transferSlice(argv_ptr, argv_len) orelse return status(Status.invalid_argument);
    if (blob.len < 2 or blob.len > 64 * 1024) return status(Status.invalid_argument);
    const count: usize = std.mem.readInt(u16, blob[0..2], .little);
    if (count > 256) return status(Status.invalid_argument);
    var arguments: [256][]const u8 = undefined;
    var cursor: usize = 2;
    for (0..count) |index| {
        if (blob.len - cursor < 4) return status(Status.invalid_argument);
        const length: usize = std.mem.readInt(u32, blob[cursor..][0..4], .little);
        cursor += 4;
        if (length > blob.len - cursor) return status(Status.invalid_argument);
        const argument = blob[cursor..][0..length];
        if (!std.unicode.utf8ValidateSlice(argument) or std.mem.indexOfScalar(u8, argument, 0) != null) return status(Status.invalid_argument);
        arguments[index] = argument;
        cursor += length;
    }
    if (cursor != blob.len) return status(Status.invalid_argument);
    return switch (slot.runtime.compileAndStartArgs(source, filename, arguments[0..count])) {
        .ready => status(Status.ok),
        .unsupported => status(Status.unsupported),
        .syntax_error, .python_exception => status(Status.python_exception),
    };
}

export fn peony_stderr_len(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    return @intCast(slot.runtime.stderr().len);
}

export fn peony_stderr_consume(handle: u32, len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (!slot.runtime.consumeStderr(len)) return status(Status.invalid_argument);
    return status(Status.ok);
}

export fn peony_error_ptr(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    const message = currentError(slot);
    if (message.len == 0) return 0;
    return @intCast(@intFromPtr(message.ptr));
}

export fn peony_error_len(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    return @intCast(currentError(slot).len);
}

export fn peony_traceback_ptr(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    const bytes = slot.runtime.tracebackJson();
    if (bytes.len == 0) return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}

export fn peony_traceback_len(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    return @intCast(slot.runtime.tracebackJson().len);
}

fn currentError(slot: *const SessionSlot) []const u8 {
    if (slot.host_error.len != 0) return slot.host_error;
    return slot.runtime.errorText();
}

fn status(value: Status) u32 {
    return @intFromEnum(value);
}

fn vfsErrorStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory, error.TooLarge => status(Status.out_of_memory),
        else => status(Status.invalid_argument),
    };
}

fn sessionSlot(handle: u32) ?*SessionSlot {
    const decoded = abi.decodeSessionHandle(handle) orelse return null;
    const slot = &sessions[decoded.index];
    if (!slot.active or slot.generation != decoded.generation) return null;
    return slot;
}

fn findFreeTransfer() ?usize {
    for (transfers, 0..) |transfer, index| {
        if (transfer.pointer == 0) return index;
    }
    return null;
}

fn isTransferSlice(pointer: u32, len: u32) bool {
    if (len == 0) return pointer == 0;
    if (pointer == 0) return false;

    const start: usize = @intCast(pointer);
    const requested: usize = @intCast(len);
    for (transfers) |transfer| {
        if (transfer.pointer == 0) continue;
        const block_start: usize = @intCast(transfer.pointer);
        if (start < block_start) continue;
        const offset = start - block_start;
        if (offset <= transfer.bytes.len and requested <= transfer.bytes.len - offset) return true;
    }
    return false;
}

fn transferSlice(pointer: u32, len: u32) ?[]const u8 {
    if (len == 0) return if (pointer == 0) &.{} else null;
    const start: usize = @intCast(pointer);
    const requested: usize = @intCast(len);
    for (transfers) |transfer| {
        if (transfer.pointer == 0) continue;
        const block_start: usize = @intCast(transfer.pointer);
        if (start < block_start) continue;
        const offset = start - block_start;
        if (offset <= transfer.bytes.len and requested <= transfer.bytes.len - offset) {
            return transfer.bytes[offset..][0..requested];
        }
    }
    return null;
}
