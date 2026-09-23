const std = @import("std");
const gc = @import("runtime_gc");

const use_nan_box = @sizeOf(usize) == 4;
const payload_mask: u64 = 0x0000_ffff_ffff_ffff;
const small_sign_bit: u64 = 0x0000_8000_0000_0000;
const tag_shift = 48;
const small_int_tag: u16 = 0x7ff9;
const none_tag: u16 = 0x7ffa;
const false_tag: u16 = 0x7ffb;
const true_tag: u16 = 0x7ffc;
const object_tag: u16 = 0x7ffd;
const unbound_tag: u16 = 0x7ffe;
const deleted_tag: u16 = 0x7fff;

pub const wasm32_value_size = 8;
pub const canonical_nan_bits: u64 = 0x7ff8_0000_0000_0000;
pub const small_int_min: i64 = -0x0000_8000_0000_0000;
pub const small_int_max: i64 = 0x0000_7fff_ffff_ffff;

pub const Tag = enum {
    float,
    small_int,
    none,
    boolean,
    heap_object,
    exception_class,
    unbound,
    deleted,
};

const NativePayload = union(enum) {
    float: f64,
    small_int: i64,
    none,
    boolean: bool,
    heap_object: *gc.Header,
    exception_class: u8,
    unbound,
    deleted,
};

pub const Value = struct {
    storage: if (use_nan_box) u64 else NativePayload,

    pub fn fromFloat(value: f64) Value {
        const canonical = if (std.math.isNan(value)) @as(f64, @bitCast(canonical_nan_bits)) else value;
        if (comptime use_nan_box) return .{ .storage = @bitCast(canonical) };
        return .{ .storage = .{ .float = canonical } };
    }

    pub fn fromSmallInt(value: i64) ?Value {
        if (value < small_int_min or value > small_int_max) return null;
        if (comptime use_nan_box) {
            return .{ .storage = tagged(small_int_tag, @as(u64, @bitCast(value)) & payload_mask) };
        }
        return .{ .storage = .{ .small_int = value } };
    }

    pub fn noneValue() Value {
        if (comptime use_nan_box) return .{ .storage = tagged(none_tag, 0) };
        return .{ .storage = .none };
    }

    pub fn falseValue() Value {
        if (comptime use_nan_box) return .{ .storage = tagged(false_tag, 0) };
        return .{ .storage = .{ .boolean = false } };
    }

    pub fn trueValue() Value {
        if (comptime use_nan_box) return .{ .storage = tagged(true_tag, 0) };
        return .{ .storage = .{ .boolean = true } };
    }

    pub fn object(header: *gc.Header) Value {
        if (comptime use_nan_box) return .{ .storage = tagged(object_tag, @intCast(@intFromPtr(header))) };
        return .{ .storage = .{ .heap_object = header } };
    }

    /// Builtin exception classes are immediate values so exception matching
    /// cannot need session allocation while reporting MemoryError.
    pub fn exceptionClass(kind_index: u8) Value {
        if (comptime use_nan_box) return .{ .storage = tagged(deleted_tag, @as(u64, kind_index) + 1) };
        return .{ .storage = .{ .exception_class = kind_index } };
    }

    pub fn asExceptionClass(self: Value) ?u8 {
        if (self.tag() != .exception_class) return null;
        if (comptime use_nan_box) return @intCast((self.storage & payload_mask) - 1);
        return self.storage.exception_class;
    }

    pub fn unboundValue() Value {
        if (comptime use_nan_box) return .{ .storage = tagged(unbound_tag, 0) };
        return .{ .storage = .unbound };
    }

    pub fn deletedValue() Value {
        if (comptime use_nan_box) return .{ .storage = tagged(deleted_tag, 0) };
        return .{ .storage = .deleted };
    }

    pub fn tag(self: Value) Tag {
        if (comptime use_nan_box) {
            return switch (tagOf(self.storage)) {
                small_int_tag => .small_int,
                none_tag => .none,
                false_tag, true_tag => .boolean,
                object_tag => .heap_object,
                unbound_tag => .unbound,
                deleted_tag => if ((self.storage & payload_mask) == 0) .deleted else .exception_class,
                else => .float,
            };
        }
        return switch (self.storage) {
            .float => .float,
            .small_int => .small_int,
            .none => .none,
            .boolean => .boolean,
            .heap_object => .heap_object,
            .exception_class => .exception_class,
            .unbound => .unbound,
            .deleted => .deleted,
        };
    }

    pub fn identical(self: Value, other: Value) bool {
        if (self.tag() != other.tag()) return false;
        if (comptime use_nan_box) return self.storage == other.storage;
        return switch (self.storage) {
            .float => |left| @as(u64, @bitCast(left)) == @as(u64, @bitCast(other.storage.float)),
            .small_int => |left| left == other.storage.small_int,
            .none, .unbound, .deleted => true,
            .boolean => |left| left == other.storage.boolean,
            .heap_object => |left| left == other.storage.heap_object,
            .exception_class => |left| left == other.storage.exception_class,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        if (self.tag() != .float) return null;
        if (comptime use_nan_box) return @bitCast(self.storage);
        return self.storage.float;
    }

    pub fn asSmallInt(self: Value) ?i64 {
        if (self.tag() != .small_int) return null;
        if (comptime use_nan_box) {
            const payload = self.storage & payload_mask;
            const extended = if (payload & small_sign_bit != 0) payload | ~payload_mask else payload;
            return @bitCast(extended);
        }
        return self.storage.small_int;
    }

    pub fn asBool(self: Value) ?bool {
        if (self.tag() != .boolean) return null;
        if (comptime use_nan_box) return tagOf(self.storage) == true_tag;
        return self.storage.boolean;
    }

    pub fn asObject(self: Value) ?*gc.Header {
        if (self.tag() != .heap_object) return null;
        if (comptime use_nan_box) return @ptrFromInt(@as(usize, @intCast(self.storage & payload_mask)));
        return self.storage.heap_object;
    }

    pub fn rawWord(self: Value) ?u64 {
        if (comptime use_nan_box) return self.storage;
        return switch (self.storage) {
            .float => |float_value| @bitCast(float_value),
            else => null,
        };
    }
};

comptime {
    if (@sizeOf(usize) == 4 and @sizeOf(Value) != wasm32_value_size) {
        @compileError("wasm32 Value must occupy exactly one 8-byte word");
    }
}

fn tagged(tag: u16, payload: u64) u64 {
    return (@as(u64, tag) << tag_shift) | (payload & payload_mask);
}

fn tagOf(word: u64) u16 {
    return @truncate(word >> tag_shift);
}
