const std = @import("std");
const vm = @import("runtime_vm");
const gc = @import("runtime_gc");
const dict = @import("runtime_dict");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");

const Value = vm.NativeTypes.Value;
const payload_rows = 1200;
const session_limit = 32 * 1024 * 1024;
const warmup_runs = 3;
const measured_runs = 10;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const payload = try makePayload(allocator);
    defer allocator.free(payload);

    for (0..warmup_runs) |_| try runPair(allocator, init.io, payload, null, null);
    var custom_runs: [measured_runs]Sample = undefined;
    var standard_runs: [measured_runs]Sample = undefined;
    for (0..measured_runs) |index| try runPair(allocator, init.io, payload, &custom_runs[index], &standard_runs[index]);
    const custom = summarize(custom_runs);
    const standard = summarize(standard_runs);

    std.debug.print(
        \\JSON choice benchmark ({d} bytes, {d} rows)
        \\warmups {d}, measured repetitions {d}
        \\custom scanner -> Peony Value -> custom serializer: median {d} ns, p95 {d} ns; session peak median {d} bytes, p95 {d} bytes
        \\std.json DOM -> Peony Value -> std.json DOM -> serializer: median {d} ns, p95 {d} ns; session peak median {d} bytes, p95 {d} bytes
        \\outputs byte-identical: true
        \\arbitrary integer: std.json.Value uses number_string beyond i64; explicit conversion is required to preserve Peony bigint precision
        \\Brotli size: unavailable in pinned Zig std; measure the wired feature artifact with the repository size gate
        \\
    , .{
        payload.len,
        payload_rows,
        warmup_runs,
        measured_runs,
        custom.median_ns,
        custom.p95_ns,
        custom.median_peak,
        custom.p95_peak,
        standard.median_ns,
        standard.p95_ns,
        standard.median_peak,
        standard.p95_peak,
    });
}

const Sample = struct {
    elapsed_ns: i96,
    peak_delta: usize,
};

const Summary = struct {
    median_ns: i96,
    p95_ns: i96,
    median_peak: usize,
    p95_peak: usize,
};

fn runPair(
    allocator: std.mem.Allocator,
    io: std.Io,
    payload: []const u8,
    custom_sample: ?*Sample,
    standard_sample: ?*Sample,
) !void {
    const custom = try measureCustom(allocator, io, payload);
    defer allocator.free(custom.bytes);
    const standard = try measureStdDom(allocator, io, payload);
    defer allocator.free(standard.bytes);
    if (!std.mem.eql(u8, custom.bytes, standard.bytes) or !std.mem.eql(u8, payload, custom.bytes)) return error.JsonOutputsDiffer;
    if (!standard.bigint_was_number_string) return error.ExpectedStdJsonBigintNumberString;
    if (custom_sample) |sample| sample.* = .{ .elapsed_ns = custom.elapsed_ns, .peak_delta = custom.peak_delta };
    if (standard_sample) |sample| sample.* = .{ .elapsed_ns = standard.elapsed_ns, .peak_delta = standard.peak_delta };
}

fn summarize(samples: [measured_runs]Sample) Summary {
    var times: [measured_runs]i96 = undefined;
    var peaks: [measured_runs]usize = undefined;
    for (samples, 0..) |sample, index| {
        times[index] = sample.elapsed_ns;
        peaks[index] = sample.peak_delta;
    }
    std.mem.sort(i96, times[0..], {}, std.sort.asc(i96));
    std.mem.sort(usize, peaks[0..], {}, std.sort.asc(usize));
    return .{
        .median_ns = @divTrunc(times[4] + times[5], 2),
        .p95_ns = times[9],
        .median_peak = (peaks[4] + peaks[5]) / 2,
        .p95_peak = peaks[9],
    };
}

const Measurement = struct {
    elapsed_ns: i96,
    peak_delta: usize,
    bytes: []u8,
    bigint_was_number_string: bool = false,
};

fn measureCustom(backing: std.mem.Allocator, io: std.Io, payload: []const u8) !Measurement {
    var runtime: vm.Runtime = undefined;
    try runtime.init(backing, session_limit);
    defer runtime.deinit();
    const baseline = runtime.session_allocator.live_bytes;
    runtime.session_allocator.peak_bytes = baseline;
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    const value = switch (vm.JsonValuesDraft.parseUtf8Detailed(vm.Runtime, &runtime, payload, 1, 1)) {
        .value => |selected| selected,
        .decode_error => return error.CustomDecodeFailure,
        .python_exception => return error.CustomPythonFailure,
        .engine_error => return error.CustomEngineFailure,
    };
    var value_root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&runtime.heap.roots);
    roots.add(&value_root);
    defer roots.pop();
    const session_bytes = switch (vm.JsonValuesDraft.serializeUtf8(vm.Runtime, &runtime, value, .{
        .ensure_ascii = false,
        .item_separator = ",",
        .key_separator = ":",
    }, 1, 1)) {
        .value => |bytes| bytes,
        .python_exception => return error.CustomPythonFailure,
        .engine_error => return error.CustomEngineFailure,
    };
    defer runtime.heap.allocator.free(session_bytes);
    const owned = try backing.dupe(u8, session_bytes);
    return .{
        .elapsed_ns = std.Io.Clock.awake.now(io).nanoseconds - started,
        .peak_delta = runtime.session_allocator.peak_bytes - baseline,
        .bytes = owned,
    };
}

fn measureStdDom(backing: std.mem.Allocator, io: std.Io, payload: []const u8) !Measurement {
    var runtime: vm.Runtime = undefined;
    try runtime.init(backing, session_limit);
    defer runtime.deinit();
    const baseline = runtime.session_allocator.live_bytes;
    runtime.session_allocator.peak_bytes = baseline;
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    var parsed = try std.json.parseFromSlice(std.json.Value, runtime.heap.allocator, payload, .{
        .duplicate_field_behavior = .use_last,
    });
    defer parsed.deinit();
    const first_big = parsed.value.array.items[0].object.get("big") orelse return error.MissingBigint;
    const bigint_was_number_string = first_big == .number_string;

    const value = try domToPeony(&runtime, parsed.value);
    var value_root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&runtime.heap.roots);
    roots.add(&value_root);
    defer roots.pop();

    var arena = std.heap.ArenaAllocator.init(runtime.heap.allocator);
    defer arena.deinit();
    const converted = try peonyToDom(&runtime, arena.allocator(), value);
    var output: std.Io.Writer.Allocating = .init(runtime.heap.allocator);
    defer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try stringify.write(converted);
    const owned = try backing.dupe(u8, output.written());
    return .{
        .elapsed_ns = std.Io.Clock.awake.now(io).nanoseconds - started,
        .peak_delta = runtime.session_allocator.peak_bytes - baseline,
        .bytes = owned,
        .bigint_was_number_string = bigint_was_number_string,
    };
}

fn makePayload(allocator: std.mem.Allocator) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("[");
    for (0..payload_rows) |index| {
        if (index != 0) try output.writer.writeAll(",");
        try output.writer.print(
            "{{\"id\":{d},\"big\":123456789012345678901234567890,\"text\":\"snow 雪 music 𝄞\",\"nested\":[true,null,{d},{d}]}}",
            .{ index, index, index + 1 },
        );
    }
    try output.writer.writeAll("]");
    return output.toOwnedSlice();
}

fn domToPeony(runtime: *vm.Runtime, value: std.json.Value) !Value {
    return switch (value) {
        .null => Value.noneValue(),
        .bool => |boolean| if (boolean) Value.trueValue() else Value.falseValue(),
        .integer => |integer| try valueResult(number.fromInt(&runtime.heap, integer)),
        .float => |float_value| Value.fromFloat(float_value),
        .number_string => |token| if (std.json.isNumberFormattedLikeAnInteger(token))
            try valueResult(number.parseIntegerLiteral(&runtime.heap, token))
        else
            Value.fromFloat(try std.fmt.parseFloat(f64, token)),
        .string => |text| runtime.createStringValue(text, 1, 1) orelse return error.PeonyConversionFailure,
        .array => |array| blk: {
            const list = try listResult(sequence.createList(&runtime.heap, &.{}));
            var list_root = gc.Root{ .object = &list.header };
            var child_root = gc.Root{ .object = null };
            var roots = gc.RootFrame{};
            roots.push(&runtime.heap.roots);
            roots.add(&list_root);
            roots.add(&child_root);
            defer roots.pop();
            for (array.items) |item| {
                const child = try domToPeony(runtime, item);
                child_root.object = child.asObject();
                try voidResult(sequence.append(&runtime.heap, list, child));
            }
            break :blk Value.object(&list.header);
        },
        .object => |object| blk: {
            const mapping = try dictResult(dict.create(&runtime.heap, false));
            var mapping_root = gc.Root{ .object = &mapping.header };
            var key_root = gc.Root{ .object = null };
            var child_root = gc.Root{ .object = null };
            var roots = gc.RootFrame{};
            roots.push(&runtime.heap.roots);
            roots.add(&mapping_root);
            roots.add(&key_root);
            roots.add(&child_root);
            defer roots.pop();
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = runtime.createStringValue(entry.key_ptr.*, 1, 1) orelse return error.PeonyConversionFailure;
                key_root.object = key.asObject();
                const child = try domToPeony(runtime, entry.value_ptr.*);
                child_root.object = child.asObject();
                if (!runtime.setMappingValue(mapping, key, child, 1, 1)) return error.PeonyConversionFailure;
            }
            break :blk Value.object(&mapping.header);
        },
    };
}

fn peonyToDom(runtime: *vm.Runtime, allocator: std.mem.Allocator, value: Value) !std.json.Value {
    if (value.tag() == .none) return .null;
    if (value.asBool()) |boolean| return .{ .bool = boolean };
    if (number.isIntegerValue(value)) {
        if (number.toInt(i64, value)) |integer| return .{ .integer = integer };
        const text = try bytesResult(number.formatInteger(&runtime.heap, value) orelse return error.PeonyConversionFailure);
        defer runtime.heap.allocator.free(text);
        return .{ .number_string = try allocator.dupe(u8, text) };
    }
    if (value.asFloat()) |float_value| return .{ .float = float_value };
    const header = value.asObject() orelse return error.UnsupportedPeonyValue;
    if (runtime.valueString(value)) |text| return .{ .string = try allocator.dupe(u8, text) };
    if (sequence.listFromHeader(header)) |list| {
        var array = std.json.Array.init(allocator);
        for (list.items.items) |item| try array.append(try peonyToDom(runtime, allocator, item));
        return .{ .array = array };
    }
    if (sequence.tupleFromHeader(header)) |tuple| {
        var array = std.json.Array.init(allocator);
        for (tuple.items) |item| try array.append(try peonyToDom(runtime, allocator, item));
        return .{ .array = array };
    }
    if (dict.dictFromHeader(header)) |mapping| {
        var object: std.json.ObjectMap = .empty;
        for (mapping.entries.items) |entry| {
            if (!entry.alive) continue;
            const key = runtime.valueString(entry.key) orelse return error.UnsupportedPeonyKey;
            try object.put(allocator, try allocator.dupe(u8, key), try peonyToDom(runtime, allocator, entry.value));
        }
        return .{ .object = object };
    }
    return error.UnsupportedPeonyValue;
}

fn valueResult(result: anytype) !Value {
    return switch (result) {
        .value => |value| value,
        else => error.PeonyConversionFailure,
    };
}

fn listResult(result: anytype) !*sequence.List {
    return switch (result) {
        .value => |value| value,
        else => error.PeonyConversionFailure,
    };
}

fn dictResult(result: anytype) !*dict.Dict {
    return switch (result) {
        .value => |value| value,
        else => error.PeonyConversionFailure,
    };
}

fn bytesResult(result: anytype) ![]u8 {
    return switch (result) {
        .value => |value| value,
        else => error.PeonyConversionFailure,
    };
}

fn voidResult(result: anytype) !void {
    return switch (result) {
        .value => {},
        else => error.PeonyConversionFailure,
    };
}
