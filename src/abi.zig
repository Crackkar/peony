pub const abi_version: u32 = 1;
pub const max_sessions: usize = 64;
pub const generation_mask: u32 = 0x00ff_ffff;

pub const Status = enum(u32) {
    ok = 0,
    unsupported = 1,
    invalid_handle = 2,
    invalid_argument = 3,
    out_of_memory = 4,
    completed = 5,
    python_exception = 6,
    timeslice = 7,
    cancelled = 8,
    internal_error = 9,
};

pub const SessionHandle = struct {
    index: usize,
    generation: u32,
};

pub fn encodeSessionHandle(index: usize, generation: u32) u32 {
    if (index >= max_sessions or generation == 0 or generation > generation_mask) return 0;
    return (generation << 8) | @as(u32, @intCast(index + 1));
}

pub fn decodeSessionHandle(value: u32) ?SessionHandle {
    const slot_token = value & 0xff;
    const generation = value >> 8;
    if (slot_token == 0 or slot_token > max_sessions or generation == 0) return null;
    return .{
        .index = @intCast(slot_token - 1),
        .generation = generation,
    };
}

test "session handles reserve zero and retain a generation" {
    const encoded = encodeSessionHandle(7, 29);
    const decoded = decodeSessionHandle(encoded).?;

    try @import("std").testing.expectEqual(@as(usize, 7), decoded.index);
    try @import("std").testing.expectEqual(@as(u32, 29), decoded.generation);
    try @import("std").testing.expectEqual(@as(u32, 0), encodeSessionHandle(0, 0));
    try @import("std").testing.expect(decodeSessionHandle(0) == null);
}

test "session handles reject values outside the fixed slot table" {
    try @import("std").testing.expect(encodeSessionHandle(max_sessions, 1) == 0);
    try @import("std").testing.expect(decodeSessionHandle((1 << 8) | 65) == null);
}
