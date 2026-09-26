const std = @import("std");
const host = @import("runtime_host");

pub fn testHostPacketRoundTripIsDeterministic() !void {
    const sections = [_]host.Section{
        .{ .kind = .utf8, .bytes = "What is your name? " },
        .{ .kind = .binary, .bytes = &.{ 0, 1, 2, 0xfe, 0xff } },
    };
    const packet = host.Packet{
        .kind = .input,
        .request_id = 0x1234abcd,
        .status = .ok,
        .flags = 0,
        .sections = &sections,
    };
    const encoded_a = try host.encode(std.testing.allocator, packet);
    defer std.testing.allocator.free(encoded_a);
    const encoded_b = try host.encode(std.testing.allocator, packet);
    defer std.testing.allocator.free(encoded_b);
    try std.testing.expectEqualSlices(u8, encoded_a, encoded_b);
    try std.testing.expectEqualSlices(u8, "PEON", encoded_a[0..4]);

    var decoded = try host.decode(std.testing.allocator, encoded_a);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(host.Kind.input, decoded.kind);
    try std.testing.expectEqual(@as(u32, 0x1234abcd), decoded.request_id);
    try std.testing.expectEqual(host.Status.ok, decoded.status);
    try std.testing.expectEqual(@as(usize, 2), decoded.sections.len);
    try std.testing.expectEqualStrings("What is your name? ", decoded.sections[0].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 0xfe, 0xff }, decoded.sections[1].bytes);

    const eof = try host.encode(std.testing.allocator, .{ .kind = .input, .request_id = 0x1234abce, .status = .eof });
    defer std.testing.allocator.free(eof);
    var decoded_eof = try host.decode(std.testing.allocator, eof);
    defer decoded_eof.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), decoded_eof.sections.len);
}

pub fn testHostPacketRoundTripWithNoSectionsDoesNotLeak() !void {
    const encoded = try host.encode(std.testing.allocator, .{ .kind = .clock, .request_id = 1 });
    defer std.testing.allocator.free(encoded);
    var decoded = try host.decode(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), decoded.sections.len);
    try std.testing.expectEqual(host.Kind.clock, decoded.kind);
}

pub fn testHostPacketRejectsOversizedEnvelopeBeforeCopying() !void {
    const allocator = std.testing.allocator;
    const max_packet_bytes: usize = 1024 * 1024;
    const total = max_packet_bytes + 1;
    const packet = try allocator.alloc(u8, total);
    defer allocator.free(packet);
    @memset(packet, 0);
    @memcpy(packet[0..4], "PEON");
    std.mem.writeInt(u16, packet[4..6], 1, .little);
    std.mem.writeInt(u16, packet[6..8], @intFromEnum(host.Kind.input), .little);
    std.mem.writeInt(u32, packet[8..12], 1, .little);
    std.mem.writeInt(u16, packet[16..18], 1, .little);
    std.mem.writeInt(u32, packet[20..24], @intCast(total), .little);
    std.mem.writeInt(u16, packet[24..26], @intFromEnum(host.SectionKind.binary), .little);
    std.mem.writeInt(u32, packet[28..32], host.packet_header_size + host.section_descriptor_size, .little);
    std.mem.writeInt(u32, packet[32..36], @intCast(total - host.packet_header_size - host.section_descriptor_size), .little);

    if (host.decode(allocator, packet)) |decoded| {
        var owned = decoded;
        owned.deinit(allocator);
        return error.ExpectedOversizedPacketRejection;
    } else |err| {
        try std.testing.expectEqual(error.InvalidPacket, err);
    }
}

pub fn testHostPacketRejectsMalformedEnvelopeWithoutOwnedPartialState() !void {
    const sections = [_]host.Section{.{ .kind = .utf8, .bytes = "line" }};
    const encoded = try host.encode(std.testing.allocator, .{
        .kind = .input,
        .request_id = 7,
        .status = .ok,
        .sections = &sections,
    });
    defer std.testing.allocator.free(encoded);

    const allocator = std.testing.allocator;
    const corruptions = [_]struct { index: usize, value: u8 }{
        .{ .index = 0, .value = 'X' }, // magic
        .{ .index = 4, .value = 2 }, // version
        .{ .index = 6, .value = 0xff }, // kind
        .{ .index = 12, .value = 0xff }, // status
        .{ .index = 8, .value = 0 }, // request id
        .{ .index = 20, .value = 0xff }, // total length
        .{ .index = 24, .value = 0xff }, // section type
        .{ .index = 28, .value = 0xff }, // section offset
        .{ .index = 32, .value = 0xff }, // section length
    };
    for (corruptions) |corruption| {
        const mutated = try allocator.dupe(u8, encoded);
        defer allocator.free(mutated);
        mutated[corruption.index] = corruption.value;
        try std.testing.expectError(error.InvalidPacket, host.decode(allocator, mutated));
    }

    const overlap_sections = [_]host.Section{
        .{ .kind = .binary, .bytes = "abcd" },
        .{ .kind = .binary, .bytes = "efgh" },
    };
    const overlapping = try host.encode(allocator, .{
        .kind = .input,
        .request_id = 9,
        .status = .ok,
        .sections = &overlap_sections,
    });
    defer allocator.free(overlapping);
    const bad_overlap = try allocator.dupe(u8, overlapping);
    defer allocator.free(bad_overlap);
    std.mem.writeInt(u32, bad_overlap[40..44], 48, .little);
    try std.testing.expectError(error.InvalidPacket, host.decode(allocator, bad_overlap));

    const invalid_utf8_sections = [_]host.Section{.{ .kind = .utf8, .bytes = &.{ 0xc3, 0x28 } }};
    try std.testing.expectError(error.InvalidPacket, host.encode(allocator, .{
        .kind = .input,
        .request_id = 11,
        .status = .ok,
        .sections = &invalid_utf8_sections,
    }));
}

pub fn testHostConfigRoundTripAndValidation() !void {
    const config = host.Config{
        .max_memory_bytes = 8 * 1024 * 1024,
        .max_instructions = 123_456,
        .quantum = 17,
        .max_vfs_bytes = 40_000,
        .max_file_bytes = 20_000,
        .seed = "seed",
    };
    const encoded = try host.encodeConfig(std.testing.allocator, config);
    defer std.testing.allocator.free(encoded);
    const decoded = try host.decodeConfig(encoded);
    try std.testing.expectEqual(config.max_memory_bytes, decoded.max_memory_bytes);
    try std.testing.expectEqual(config.max_instructions, decoded.max_instructions);
    try std.testing.expectEqual(config.quantum, decoded.quantum);
    try std.testing.expectEqual(config.max_vfs_bytes, decoded.max_vfs_bytes);
    try std.testing.expectEqual(config.max_file_bytes, decoded.max_file_bytes);
    try std.testing.expectEqualStrings("seed", decoded.seed);
    const defaults = try host.decodeConfig(&.{});
    try std.testing.expectEqual(host.Config.defaults().max_memory_bytes, defaults.max_memory_bytes);
    try std.testing.expectEqual(host.Config.defaults().max_instructions, defaults.max_instructions);
    try std.testing.expectEqual(host.Config.defaults().quantum, defaults.quantum);
    try std.testing.expectEqual(host.Config.defaults().max_vfs_bytes, defaults.max_vfs_bytes);
    try std.testing.expectEqual(host.Config.defaults().max_file_bytes, defaults.max_file_bytes);
    try std.testing.expectEqualStrings(host.Config.defaults().seed, defaults.seed);

    // A pre-extension PCFG packet keeps the original 28-byte header and
    // receives the documented default VFS budgets.
    var base_config: [host.config_header_size]u8 = @splat(0);
    @memcpy(base_config[0..4], "PCFG");
    std.mem.writeInt(u16, base_config[4..6], 1, .little);
    std.mem.writeInt(u32, base_config[8..12], 8 * 1024 * 1024, .little);
    std.mem.writeInt(u64, base_config[12..20], 123_456, .little);
    std.mem.writeInt(u32, base_config[20..24], 17, .little);
    const decoded_base = try host.decodeConfig(&base_config);
    try std.testing.expectEqual(host.Config.defaults().max_vfs_bytes, decoded_base.max_vfs_bytes);
    try std.testing.expectEqual(host.Config.defaults().max_file_bytes, decoded_base.max_file_bytes);

    var invalid_limits = config;
    invalid_limits.max_file_bytes = invalid_limits.max_vfs_bytes + 1;
    try std.testing.expectError(error.InvalidConfig, host.encodeConfig(std.testing.allocator, invalid_limits));

    const invalid_extension = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(invalid_extension);
    std.mem.writeInt(u32, invalid_extension[36..40], config.max_vfs_bytes + 1, .little);
    try std.testing.expectError(error.InvalidConfig, host.decodeConfig(invalid_extension));

    const bad_version = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_version);
    std.mem.writeInt(u16, bad_version[4..6], 2, .little);
    try std.testing.expectError(error.InvalidConfig, host.decodeConfig(bad_version));
}
