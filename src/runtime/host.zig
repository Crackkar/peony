const std = @import("std");

pub const packet_header_size = 24;
pub const section_descriptor_size = 12;
pub const config_header_size = 28;
pub const max_packet_sections = 64;
pub const max_packet_bytes = 1024 * 1024;
pub const max_seed_length = 1024;

pub const Kind = enum(u16) {
    input = 1,
    http = 2,
    sleep = 3,
    clock = 4,
    output = 5,
};

pub const Status = enum(u16) {
    ok = 0,
    eof = 1,
    host_error = 2,
};

pub const SectionKind = enum(u16) {
    utf8 = 1,
    binary = 2,
};

pub const Section = struct {
    kind: SectionKind,
    bytes: []const u8,
};

pub const Packet = struct {
    kind: Kind,
    request_id: u32,
    status: Status = .ok,
    flags: u16 = 0,
    sections: []const Section = &.{},
};

pub const Envelope = struct {
    kind: Kind,
    request_id: u32,
    status: Status,
    section_count: usize,
};

pub const DecodedPacket = struct {
    kind: Kind,
    request_id: u32,
    status: Status,
    flags: u16,
    sections: []Section,
    storage: []u8,

    pub fn deinit(self: *DecodedPacket, allocator: std.mem.Allocator) void {
        if (self.sections.len != 0) allocator.free(self.sections);
        if (self.storage.len != 0) allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const Config = struct {
    max_memory_bytes: u32,
    max_instructions: u64,
    quantum: u32,
    seed: []const u8,

    pub fn defaults() Config {
        return .{
            .max_memory_bytes = 64 * 1024 * 1024,
            .max_instructions = 50_000_000,
            .quantum = 50_000,
            .seed = &.{},
        };
    }
};

pub fn encode(allocator: std.mem.Allocator, packet: Packet) (std.mem.Allocator.Error || error{InvalidPacket})![]u8 {
    if (packet.request_id == 0 or packet.flags != 0 or packet.sections.len > max_packet_sections) return error.InvalidPacket;
    const descriptors_end = std.math.add(usize, packet_header_size, std.math.mul(usize, packet.sections.len, section_descriptor_size) catch return error.InvalidPacket) catch return error.InvalidPacket;
    var total = descriptors_end;
    for (packet.sections) |section| {
        if (section.kind == .utf8 and !std.unicode.utf8ValidateSlice(section.bytes)) return error.InvalidPacket;
        total = std.math.add(usize, total, section.bytes.len) catch return error.InvalidPacket;
    }
    if (total > max_packet_bytes or total > std.math.maxInt(u32)) return error.InvalidPacket;
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "PEON");
    put(u16, bytes, 4, 1);
    put(u16, bytes, 6, @intFromEnum(packet.kind));
    put(u32, bytes, 8, packet.request_id);
    put(u16, bytes, 12, @intFromEnum(packet.status));
    put(u16, bytes, 14, packet.flags);
    put(u16, bytes, 16, @intCast(packet.sections.len));
    put(u16, bytes, 18, 0);
    put(u32, bytes, 20, @intCast(total));
    var payload_offset = descriptors_end;
    for (packet.sections, 0..) |section, index| {
        const descriptor = packet_header_size + index * section_descriptor_size;
        put(u16, bytes, descriptor, @intFromEnum(section.kind));
        put(u16, bytes, descriptor + 2, 0);
        put(u32, bytes, descriptor + 4, @intCast(payload_offset));
        put(u32, bytes, descriptor + 8, @intCast(section.bytes.len));
        @memcpy(bytes[payload_offset..][0..section.bytes.len], section.bytes);
        payload_offset += section.bytes.len;
    }
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) (std.mem.Allocator.Error || error{InvalidPacket})!DecodedPacket {
    if (bytes.len < packet_header_size or bytes.len > max_packet_bytes or !std.mem.eql(u8, bytes[0..4], "PEON")) return error.InvalidPacket;
    if (get(u16, bytes, 4) != 1 or get(u16, bytes, 18) != 0) return error.InvalidPacket;
    const kind = std.enums.fromInt(Kind, get(u16, bytes, 6)) orelse return error.InvalidPacket;
    const request_id = get(u32, bytes, 8);
    const packet_status = std.enums.fromInt(Status, get(u16, bytes, 12)) orelse return error.InvalidPacket;
    const flags = get(u16, bytes, 14);
    const section_count: usize = get(u16, bytes, 16);
    const total: usize = get(u32, bytes, 20);
    if (request_id == 0 or flags != 0 or section_count > max_packet_sections or total != bytes.len) return error.InvalidPacket;
    const descriptors_end = std.math.add(usize, packet_header_size, std.math.mul(usize, section_count, section_descriptor_size) catch return error.InvalidPacket) catch return error.InvalidPacket;
    if (descriptors_end > bytes.len) return error.InvalidPacket;

    var ranges: [max_packet_sections]struct { start: usize, end: usize } = undefined;
    for (0..section_count) |index| {
        const descriptor = packet_header_size + index * section_descriptor_size;
        const section_kind = std.enums.fromInt(SectionKind, get(u16, bytes, descriptor)) orelse return error.InvalidPacket;
        if (get(u16, bytes, descriptor + 2) != 0) return error.InvalidPacket;
        const offset: usize = get(u32, bytes, descriptor + 4);
        const length: usize = get(u32, bytes, descriptor + 8);
        const end = std.math.add(usize, offset, length) catch return error.InvalidPacket;
        if (offset < descriptors_end or end > bytes.len) return error.InvalidPacket;
        if (section_kind == .utf8 and !std.unicode.utf8ValidateSlice(bytes[offset..end])) return error.InvalidPacket;
        for (ranges[0..index]) |previous| {
            if (offset < previous.end and previous.start < end) return error.InvalidPacket;
        }
        ranges[index] = .{ .start = offset, .end = end };
    }

    const owned = try allocator.dupe(u8, bytes);
    errdefer allocator.free(owned);
    var sections: []Section = &.{};
    if (section_count != 0) {
        sections = try allocator.alloc(Section, section_count);
        errdefer allocator.free(sections);
    }
    for (0..section_count) |index| {
        const descriptor = packet_header_size + index * section_descriptor_size;
        const section_kind = std.enums.fromInt(SectionKind, get(u16, bytes, descriptor)) orelse return error.InvalidPacket;
        const offset: usize = get(u32, bytes, descriptor + 4);
        const length: usize = get(u32, bytes, descriptor + 8);
        sections[index] = .{ .kind = section_kind, .bytes = owned[offset..][0..length] };
    }
    return .{ .kind = kind, .request_id = request_id, .status = packet_status, .flags = flags, .sections = sections, .storage = owned };
}

/// Validates the fixed packet envelope without allocating or copying its
/// payload. The ABI uses this to reject stale/wrong-kind responses before a
/// session allocator sees an untrusted packet body.
pub fn peekEnvelope(bytes: []const u8) error{InvalidPacket}!Envelope {
    if (bytes.len < packet_header_size or bytes.len > max_packet_bytes or !std.mem.eql(u8, bytes[0..4], "PEON")) return error.InvalidPacket;
    if (get(u16, bytes, 4) != 1 or get(u16, bytes, 18) != 0) return error.InvalidPacket;
    const kind = std.enums.fromInt(Kind, get(u16, bytes, 6)) orelse return error.InvalidPacket;
    const packet_status = std.enums.fromInt(Status, get(u16, bytes, 12)) orelse return error.InvalidPacket;
    const request_id = get(u32, bytes, 8);
    const flags = get(u16, bytes, 14);
    const section_count: usize = get(u16, bytes, 16);
    const total: usize = get(u32, bytes, 20);
    if (request_id == 0 or flags != 0 or section_count > max_packet_sections or total != bytes.len) return error.InvalidPacket;
    const descriptors_end = std.math.add(usize, packet_header_size, std.math.mul(usize, section_count, section_descriptor_size) catch return error.InvalidPacket) catch return error.InvalidPacket;
    if (descriptors_end > bytes.len) return error.InvalidPacket;
    return .{ .kind = kind, .request_id = request_id, .status = packet_status, .section_count = section_count };
}

pub fn encodeConfig(allocator: std.mem.Allocator, config: Config) (std.mem.Allocator.Error || error{InvalidConfig})![]u8 {
    if (config.max_memory_bytes == 0 or config.max_instructions == 0 or config.quantum == 0 or config.seed.len > max_seed_length) return error.InvalidConfig;
    const total = std.math.add(usize, config_header_size, config.seed.len) catch return error.InvalidConfig;
    if (config.seed.len > std.math.maxInt(u16)) return error.InvalidConfig;
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "PCFG");
    put(u16, bytes, 4, 1);
    put(u16, bytes, 6, if (config.seed.len == 0) 0 else 1);
    put(u32, bytes, 8, config.max_memory_bytes);
    put(u64, bytes, 12, config.max_instructions);
    put(u32, bytes, 20, config.quantum);
    put(u16, bytes, 24, @intCast(config.seed.len));
    put(u16, bytes, 26, 0);
    @memcpy(bytes[config_header_size..], config.seed);
    return bytes;
}

pub fn decodeConfig(bytes: []const u8) error{InvalidConfig}!Config {
    if (bytes.len == 0) return Config.defaults();
    if (bytes.len < config_header_size or !std.mem.eql(u8, bytes[0..4], "PCFG")) return error.InvalidConfig;
    if (get(u16, bytes, 4) != 1 or get(u16, bytes, 26) != 0) return error.InvalidConfig;
    const flags = get(u16, bytes, 6);
    const memory = get(u32, bytes, 8);
    const instructions = get(u64, bytes, 12);
    const quantum = get(u32, bytes, 20);
    const seed_length: usize = get(u16, bytes, 24);
    if (flags > 1 or (flags == 0) != (seed_length == 0) or seed_length > max_seed_length) return error.InvalidConfig;
    if (bytes.len != config_header_size + seed_length or memory == 0 or instructions == 0 or quantum == 0) return error.InvalidConfig;
    return .{ .max_memory_bytes = memory, .max_instructions = instructions, .quantum = quantum, .seed = bytes[config_header_size..] };
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
