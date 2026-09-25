const std = @import("std");

// Isolated JSON byte-classification probe. The shipping interpreter stays on
// its scalar path; this module measures the candidate vector primitive only.
export fn probe_alloc(length: u32) u32 {
    if (length == 0) return 0;
    const bytes = std.heap.wasm_allocator.alloc(u8, length) catch return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}

export fn probe_scalar(pointer: u32, length: u32) u32 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    var total: u32 = 0;
    for (bytes[0..length]) |byte| total += @intFromBool(classify(byte));
    return total;
}

export fn probe_vector(pointer: u32, length: u32) u32 {
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    const input = bytes[0..length];
    const Lanes = @Vector(16, u8);
    var total: u32 = 0;
    var index: usize = 0;
    while (input.len - index >= 16) : (index += 16) {
        var block: [16]u8 = undefined;
        @memcpy(&block, input[index..][0..16]);
        const lanes: Lanes = @bitCast(block);
        const quote = lanes == @as(Lanes, @splat('"'));
        const slash = lanes == @as(Lanes, @splat('\\'));
        const control = lanes < @as(Lanes, @splat(0x20));
        const high = lanes >= @as(Lanes, @splat(0x80));
        const selected: Lanes = @select(u8, quote | slash | control | high, @as(Lanes, @splat(1)), @as(Lanes, @splat(0)));
        total += @reduce(.Add, selected);
    }
    for (input[index..]) |byte| total += @intFromBool(classify(byte));
    return total;
}

fn classify(byte: u8) bool {
    return byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80;
}
