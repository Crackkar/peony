const std = @import("std");
const abi = @import("abi.zig");
const runtime_vm = @import("runtime_vm");
const Runtime = runtime_vm.Runtime;

comptime {
    _ = @sizeOf(Runtime);
}

pub const std_options_debug_io: std.Io = std.Io.failing;

const Status = abi.Status;
const max_transfers = 256;
const default_session_max_bytes = 64 * 1024 * 1024;
const generation_mask = abi.generation_mask;

const SessionSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    runtime: Runtime = undefined,
    host_error: []const u8 = "",
};

const Transfer = struct {
    pointer: u32 = 0,
    bytes: []u8 = &.{},
};

var sessions: [abi.max_sessions]SessionSlot = [_]SessionSlot{.{}} ** abi.max_sessions;
var transfers: [max_transfers]Transfer = [_]Transfer{.{}} ** max_transfers;

const resume_unsupported_message = "host resume packets are not implemented yet";

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
    if (config_ptr != 0 or config_len != 0) return 0;
    for (&sessions, 0..) |*slot, index| {
        if (!slot.active) {
            slot.runtime.init(std.heap.wasm_allocator, default_session_max_bytes) catch return 0;
            slot.active = true;
            slot.host_error = "";
            return abi.encodeSessionHandle(index, slot.generation);
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
    };
}

export fn peony_resume(handle: u32, packet_ptr: u32, packet_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.host_error = "";
    if (!isTransferSlice(packet_ptr, packet_len)) return status(Status.invalid_argument);
    slot.host_error = resume_unsupported_message;
    return status(Status.unsupported);
}

export fn peony_cancel(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.runtime.cancel();
    return status(Status.ok);
}

export fn peony_event_ptr(handle: u32) u32 {
    _ = sessionSlot(handle) orelse return 0;
    return 0;
}

export fn peony_event_len(handle: u32) u32 {
    _ = sessionSlot(handle) orelse return 0;
    return 0;
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
    _ = sessionSlot(handle) orelse return 0;
    return 0;
}

export fn peony_stderr_len(handle: u32) u32 {
    _ = sessionSlot(handle) orelse return 0;
    return 0;
}

export fn peony_stderr_consume(handle: u32, len: u32) u32 {
    _ = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (len != 0) return status(Status.invalid_argument);
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
