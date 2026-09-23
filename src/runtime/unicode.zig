const std = @import("std");

const blob = @import("unicode_blob").blob;

pub const version = "15.0.0";
pub const Property = enum(u4) {
    alphabetic = 0,
    alnum = 1,
    decimal = 2,
    digit = 3,
    numeric = 4,
    whitespace = 5,
    lower = 6,
    upper = 7,
    title = 8,
    cased = 9,
    case_ignorable = 10,
    title_ignorable = 11,
};

pub const MappingKind = enum(u8) { lower, upper, title, casefold };

pub const Mapping = struct {
    count: u8,
    codepoints: [3]u21,
};

const header_size = 54;
const range_size = 10;
const mapping_size = 72;
const range_count = readU32(14);
const mapping_count = readU32(18);
const ranges_start = header_size;
const mappings_start = ranges_start + range_count * range_size;

comptime {
    if (blob.len < header_size) @compileError("Unicode table header is truncated");
    if (!std.mem.eql(u8, blob[0..8], "PEONYU15")) @compileError("unexpected Unicode table magic");
    if (!std.mem.eql(u8, blob[8..14], version)) @compileError("Unicode table version mismatch");
    if (mappings_start + mapping_count * mapping_size != blob.len) {
        @compileError("Unicode table section lengths do not match the blob");
    }
}

pub fn hasProperty(codepoint: u21, property: Property) bool {
    const target: u32 = codepoint;
    var low: usize = 0;
    var high: usize = range_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const offset = ranges_start + middle * range_size;
        const first = readU32(offset);
        const last = readU32(offset + 4);
        if (target < first) {
            high = middle;
        } else if (target > last) {
            low = middle + 1;
        } else {
            const flags = readU16(offset + 8);
            return flags & (@as(u16, 1) << @intFromEnum(property)) != 0;
        }
    }
    return false;
}

pub fn fullMapping(codepoint: u21, kind: MappingKind) Mapping {
    const offset = findMapping(codepoint) orelse return .{
        .count = 1,
        .codepoints = .{ codepoint, 0, 0 },
    };
    const map_offset = offset + 4 + @as(usize, @intFromEnum(kind)) * 17;
    const count = blob[map_offset];
    if (count == 0) return .{ .count = 1, .codepoints = .{ codepoint, 0, 0 } };
    return .{
        .count = count,
        .codepoints = .{
            @intCast(readU32(map_offset + 1)),
            @intCast(readU32(map_offset + 5)),
            @intCast(readU32(map_offset + 9)),
        },
    };
}

pub fn simpleMapping(codepoint: u21, kind: MappingKind) u21 {
    const offset = findMapping(codepoint) orelse return codepoint;
    const map_offset = offset + 4 + @as(usize, @intFromEnum(kind)) * 17;
    return @intCast(readU32(map_offset + 13));
}

pub fn projectionHash() []const u8 {
    return blob[22..54];
}

pub fn blobBytes() []const u8 {
    return blob;
}

fn findMapping(codepoint: u21) ?usize {
    const target: u32 = codepoint;
    var low: usize = 0;
    var high: usize = mapping_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const offset = mappings_start + middle * mapping_size;
        const current = readU32(offset);
        if (target < current) {
            high = middle;
        } else if (target > current) {
            low = middle + 1;
        } else {
            return offset;
        }
    }
    return null;
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, blob[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}
