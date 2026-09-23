const std = @import("std");
const gc = @import("runtime_gc");
const values = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const bytes = @import("runtime_bytes");
const sequence = @import("runtime_sequence");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");

pub const Value = values.Value;
pub const HashResult = exceptions.Result(u64);

pub fn pythonHash(heap: *gc.Heap, value: Value, seed: u64) HashResult {
    return pythonHashDepth(heap, value, seed, 0);
}

fn pythonHashDepth(heap: *gc.Heap, value: Value, seed: u64, depth: usize) HashResult {
    if (depth > 128) return pythonError(.recursion_error, "maximum recursion depth exceeded while hashing an object");
    if (number.isIntegerValue(value) or value.tag() == .float) return numberHash(number.hash(value));
    const header = value.asObject() orelse return numberHash(number.hash(value));
    if (string.fromHeader(header)) |text| return .{ .value = normalizeHash(std.hash.Wyhash.hash(seed ^ 0x535452, text.data)) };
    if (bytes.fromHeader(header)) |data| return .{ .value = normalizeHash(std.hash.Wyhash.hash(seed ^ 0x4259544553, data.data)) };
    if (sequence.listFromHeader(header) != null) return pythonError(.type_error, "unhashable type: 'list'");
    if (dict_module.dictFromHeader(header)) |mapping| return pythonError(.type_error, if (mapping.is_set) "unhashable type: 'set'" else "unhashable type: 'dict'");
    if (dict_module.viewFromHeader(header)) |_| return pythonError(.type_error, "unhashable type: 'dict_view'");
    if (sequence.tupleFromHeader(header)) |tuple| {
        var accumulator: u64 = 0x345678 ^ seed;
        for (tuple.items) |item| {
            const child = pythonHashDepth(heap, item, seed, depth + 1);
            const item_hash = switch (child) {
                .value => |hash| hash,
                .python_exception => |exception| return .{ .python_exception = exception },
                .engine_error => |failure| return .{ .engine_error = failure },
            };
            accumulator = (accumulator ^ item_hash) *% 1_000_003;
        }
        accumulator +%= 97531 +% tuple.items.len *% 82520;
        return .{ .value = normalizeHash(accumulator) };
    }
    // Peony objects are non-moving. Until type-level __hash__ is implemented,
    // their address is a stable identity hash for their lifetime.
    return .{ .value = normalizeHash(@intCast(@intFromPtr(header))) };
}

pub fn mixSessionSeed(nonce: u64, address: usize) u64 {
    var value = nonce ^ @as(u64, @intCast(address)) ^ 0x9e3779b97f4a7c15;
    value ^= value >> 30;
    value *%= 0xbf58476d1ce4e5b9;
    value ^= value >> 27;
    value *%= 0x94d049bb133111eb;
    value ^= value >> 31;
    return if (value == 0) 0xa0761d6478bd642f else value;
}

fn numberHash(result: exceptions.Result(u64)) HashResult {
    return switch (result) {
        .value => |hash| .{ .value = hash },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |failure| .{ .engine_error = failure },
    };
}

fn pythonError(kind: exceptions.PythonExceptionKind, message: []const u8) HashResult {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}

fn normalizeHash(hash_value: u64) u64 {
    return if (@as(i64, @bitCast(hash_value)) == -1) @bitCast(@as(i64, -2)) else hash_value;
}
