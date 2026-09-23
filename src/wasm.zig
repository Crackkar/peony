const std = @import("std");
const abi = @import("abi.zig");

pub const std_options_debug_io: std.Io = std.Io.failing;

const Status = abi.Status;
const max_transfers = 256;
const generation_mask = abi.generation_mask;

const SessionSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    error_ready: bool = false,
};

const Transfer = struct {
    pointer: u32 = 0,
    bytes: []u8 = &.{},
};

var sessions: [abi.max_sessions]SessionSlot = [_]SessionSlot{.{}} ** abi.max_sessions;
var transfers: [max_transfers]Transfer = [_]Transfer{.{}} ** max_transfers;

const unsupported_message = "Peony v0.1 language execution is not implemented yet";

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
            slot.active = true;
            slot.error_ready = false;
            return abi.encodeSessionHandle(index, slot.generation);
        }
    }
    return 0;
}

export fn peony_session_destroy(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.active = false;
    slot.error_ready = false;
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
    slot.error_ready = false;
    if (!isTransferSlice(src_ptr, src_len) or !isTransferSlice(filename_ptr, filename_len)) {
        return status(Status.invalid_argument);
    }
    slot.error_ready = true;
    return status(Status.unsupported);
}

export fn peony_run(handle: u32, quantum: u32) u32 {
    _ = quantum;
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.error_ready = true;
    return status(Status.unsupported);
}

export fn peony_resume(handle: u32, packet_ptr: u32, packet_len: u32) u32 {
    const slot = sessionSlot(handle) orelse return status(Status.invalid_handle);
    slot.error_ready = false;
    if (!isTransferSlice(packet_ptr, packet_len)) return status(Status.invalid_argument);
    slot.error_ready = true;
    return status(Status.unsupported);
}

export fn peony_cancel(handle: u32) u32 {
    _ = sessionSlot(handle) orelse return status(Status.invalid_handle);
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
    _ = sessionSlot(handle) orelse return 0;
    return 0;
}

export fn peony_stdout_len(handle: u32) u32 {
    _ = sessionSlot(handle) orelse return 0;
    return 0;
}

export fn peony_stdout_consume(handle: u32, len: u32) u32 {
    _ = sessionSlot(handle) orelse return status(Status.invalid_handle);
    if (len != 0) return status(Status.invalid_argument);
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
    if (!slot.error_ready) return 0;
    return @intCast(@intFromPtr(unsupported_message.ptr));
}

export fn peony_error_len(handle: u32) u32 {
    const slot = sessionSlot(handle) orelse return 0;
    if (!slot.error_ready) return 0;
    return @intCast(unsupported_message.len);
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
