const std = @import("std");
const number = @import("runtime_number");
const value = @import("runtime_value");
const Value = value.Value;

pub fn testValueTagsAndIdentity() !void {
    const zero = Value.fromSmallInt(0).?;
    const one = Value.fromSmallInt(1).?;

    try std.testing.expectEqual(value.Tag.small_int, zero.tag());
    try std.testing.expectEqual(value.Tag.none, Value.noneValue().tag());
    try std.testing.expectEqual(value.Tag.boolean, Value.falseValue().tag());
    try std.testing.expectEqual(value.Tag.boolean, Value.trueValue().tag());
    try std.testing.expectEqual(value.Tag.unbound, Value.unboundValue().tag());
    try std.testing.expectEqual(value.Tag.deleted, Value.deletedValue().tag());
    try std.testing.expect(!one.identical(Value.trueValue()));
    try std.testing.expect(!Value.noneValue().identical(Value.falseValue()));
    try std.testing.expectEqual(@as(usize, 8), value.wasm32_value_size);
}

pub fn testFloatNanCanonicalization() !void {
    const payload_nan: f64 = @bitCast(@as(u64, 0x7ff9_0000_0000_1234));
    const boxed = Value.fromFloat(payload_nan);
    const round_trip = boxed.asFloat().?;

    try std.testing.expectEqual(value.Tag.float, boxed.tag());
    try std.testing.expectEqual(value.canonical_nan_bits, @as(u64, @bitCast(round_trip)));
    try std.testing.expect(!boxed.identical(Value.fromFloat(1.0)));
}

pub fn testSmallIntOverflowPromotion() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const max_small = Value.fromSmallInt(value.small_int_max).?;
    const one = Value.fromSmallInt(1).?;
    try expectValueInt(number.subtract(&heap, Value.fromSmallInt(3).?, Value.fromSmallInt(5).?), -2);
    try expectValueInt(
        number.multiply(&heap, Value.fromSmallInt(4_294_967_296).?, Value.fromSmallInt(4_294_967_296).?),
        18_446_744_073_709_551_616,
    );
    const overflow = valueOf(tryAdd(&heap, max_small, one)) catch return error.UnexpectedNumericError;
    try std.testing.expectEqual(value.Tag.heap_object, overflow.tag());

    var frame = number.RootFrame{};
    frame.push(&heap.roots);
    defer frame.pop();
    var overflow_root = number.Root{ .object = overflow.asObject().? };
    frame.add(&overflow_root);

    const beyond_u64 = valueOf(tryAdd(&heap, overflow, one)) catch return error.UnexpectedNumericError;
    try expectInteger(beyond_u64, @as(i128, value.small_int_max) + 2);

    const largest_i64 = try valueOf(number.fromInt(&heap, std.math.maxInt(i64)));
    const beyond_64 = valueOf(tryAdd(&heap, largest_i64, one)) catch return error.UnexpectedNumericError;
    const beyond_64_again = valueOf(tryAdd(&heap, beyond_64, largest_i64)) catch return error.UnexpectedNumericError;
    try expectInteger(beyond_64_again, 18_446_744_073_709_551_615);
    try expectValueInt(number.negative(&heap, beyond_64_again), -18_446_744_073_709_551_615);
}

pub fn testFloorDivisionModulo() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const minus_seven = Value.fromSmallInt(-7).?;
    const plus_seven = Value.fromSmallInt(7).?;
    const plus_three = Value.fromSmallInt(3).?;
    const minus_three = Value.fromSmallInt(-3).?;

    try expectValueInt(number.floorDiv(&heap, minus_seven, plus_three), -3);
    try expectValueInt(number.modulo(&heap, minus_seven, plus_three), 2);
    try expectValueInt(number.floorDiv(&heap, plus_seven, minus_three), -3);
    try expectValueInt(number.modulo(&heap, plus_seven, minus_three), -2);

    const large_negative = try valueOf(number.fromInt(&heap, -((@as(i128, 1) << 48) + 7)));
    try expectValueInt(number.floorDiv(&heap, large_negative, plus_three), -93_824_992_236_888);
    try expectValueInt(number.modulo(&heap, large_negative, plus_three), 1);

    try expectValueFloat(number.floorDiv(&heap, Value.fromFloat(-7.0), Value.fromFloat(3.0)), -3.0);
    try expectValueFloat(number.modulo(&heap, Value.fromFloat(-7.0), Value.fromFloat(3.0)), 2.0);
    try expectComparison(number.compare(Value.fromSmallInt(-1).?, Value.fromFloat(-1.5)), .greater);
}

pub fn testShiftAndBitwise() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const minus_five = Value.fromSmallInt(-5).?;
    const three = Value.fromSmallInt(3).?;
    try expectValueInt(number.bitAnd(&heap, minus_five, three), 3);
    try expectValueInt(number.bitOr(&heap, minus_five, three), -5);
    try expectValueInt(number.bitXor(&heap, minus_five, three), -8);
    try expectValueInt(number.bitNot(&heap, minus_five), 4);
    try expectValueInt(number.shiftRight(&heap, minus_five, three), -1);
    const large_negative = try valueOf(number.fromInt(&heap, -((@as(i128, 1) << 47) + 5)));
    try expectValueInt(number.bitAnd(&heap, large_negative, three), 3);
    try expectValueInt(number.shiftRight(&heap, large_negative, three), -17_592_186_044_417);
    try expectValueInt(number.bitNot(&heap, large_negative), (@as(i128, 1) << 47) + 4);
    try expectValueInt(number.shiftLeft(&heap, Value.fromSmallInt(1).?, Value.fromSmallInt(100).?), @as(i128, 1) << 100);

    const bad_shift = number.shiftLeft(&heap, three, Value.fromSmallInt(-1).?);
    try expectPythonError(bad_shift, number.PythonExceptionKind.value_error);
}

pub fn testHugeBoundedOperations() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    var frame = number.RootFrame{};
    frame.push(&heap.roots);
    defer frame.pop();

    const one = Value.fromSmallInt(1).?;
    const minus_one = Value.fromSmallInt(-1).?;
    const two = Value.fromSmallInt(2).?;
    const huge = try valueOf(number.power(&heap, two, Value.fromSmallInt(127).?));
    var huge_root = number.Root{ .object = huge.asObject().? };
    frame.add(&huge_root);

    const one_shifted = try valueOf(number.shiftLeft(&heap, one, Value.fromSmallInt(127).?));
    try expectComparison(number.compare(one_shifted, huge), .equal);
    try expectValueInt(number.shiftRight(&heap, Value.fromSmallInt(-3).?, huge), -1);
    try expectValueInt(number.shiftRight(&heap, Value.fromSmallInt(3).?, huge), 0);
    try expectValueInt(number.shiftLeft(&heap, Value.fromSmallInt(0).?, huge), 0);

    const beyond_u32 = Value.fromSmallInt(4_294_967_296).?;
    try expectValueInt(number.power(&heap, Value.fromSmallInt(0).?, beyond_u32), 0);
    try expectValueInt(number.power(&heap, one, beyond_u32), 1);
    try expectValueInt(number.power(&heap, minus_one, beyond_u32), 1);
    try expectValueFloat(number.power(&heap, one, Value.fromSmallInt(-3).?), 1.0);
    try expectValueFloat(number.power(&heap, minus_one, Value.fromSmallInt(-3).?), -1.0);

    const huge_odd = try valueOf(number.add(&heap, huge, one));
    var odd_root = number.Root{ .object = huge_odd.asObject().? };
    frame.add(&odd_root);
    try expectValueInt(number.power(&heap, minus_one, huge), 1);
    try expectValueInt(number.power(&heap, minus_one, huge_odd), -1);
    try expectValueInt(number.power(&heap, Value.fromSmallInt(0).?, huge), 0);
    try expectPythonError(
        number.power(&heap, Value.fromSmallInt(0).?, Value.fromSmallInt(-4_294_967_296).?),
        number.PythonExceptionKind.zero_division_error,
    );
}

pub fn testPowerAndFloatConversion() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const two = Value.fromSmallInt(2).?;
    const hundred = Value.fromSmallInt(100).?;
    const result = valueOf(number.power(&heap, two, hundred)) catch return error.UnexpectedNumericError;
    try expectInteger(result, 1_267_650_600_228_229_401_496_703_205_376);

    const float_result = floatOf(number.trueDivide(&heap, Value.fromSmallInt(7).?, Value.fromSmallInt(2).?)) catch return error.UnexpectedNumericError;
    try std.testing.expectEqual(@as(f64, 3.5), float_result);
}

pub fn testNumericEqualityAndHash() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const true_value = Value.trueValue();
    const int_one = Value.fromSmallInt(1).?;
    const float_one = Value.fromFloat(1.0);
    try expectEqual(number.equal(true_value, int_one), true);
    try expectEqual(number.equal(int_one, float_one), true);
    try expectEqualHash(number.hash(true_value), try hashOf(number.hash(int_one)));
    try expectEqualHash(number.hash(int_one), try hashOf(number.hash(float_one)));

    const large_integer = try valueOf(number.fromInt(&heap, 1_152_921_504_606_846_976));
    var frame = number.RootFrame{};
    frame.push(&heap.roots);
    defer frame.pop();
    var root = number.Root{ .object = large_integer.asObject().? };
    frame.add(&root);

    const same_float = Value.fromFloat(1_152_921_504_606_846_976.0);
    try expectEqual(number.equal(large_integer, same_float), true);
    try expectEqualHash(number.hash(large_integer), try hashOf(number.hash(same_float)));
    try expectValueInt(number.add(&heap, true_value, true_value), 2);

    const huge_integer = try valueOf(number.power(&heap, Value.fromSmallInt(2).?, Value.fromSmallInt(200).?));
    const huge_float = Value.fromFloat(std.math.ldexp(@as(f64, 1.0), 200));
    try expectEqual(number.equal(huge_integer, huge_float), true);
    try expectEqualHash(number.hash(huge_integer), try hashOf(number.hash(huge_float)));
}

pub fn testLargeIntegerFloatOverflow() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const power_value = valueOf(number.power(&heap, Value.fromSmallInt(2).?, Value.fromSmallInt(2048).?)) catch return error.UnexpectedNumericError;
    var frame = number.RootFrame{};
    frame.push(&heap.roots);
    defer frame.pop();
    var root = number.Root{ .object = power_value.asObject().? };
    frame.add(&root);

    try expectPythonError(number.toFloat(&heap, power_value), number.PythonExceptionKind.overflow_error);
    try std.testing.expectEqual(@as(f64, 1.0), try floatOf(number.trueDivide(&heap, power_value, power_value)));
    try expectPythonError(number.trueDivide(&heap, power_value, Value.fromSmallInt(1).?), number.PythonExceptionKind.overflow_error);
}

pub fn testPythonExceptionTransport() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const result = number.trueDivide(&heap, Value.fromSmallInt(1).?, Value.fromSmallInt(0).?);
    try expectPythonError(result, number.PythonExceptionKind.zero_division_error);
}

pub fn testMemoryErrorKeepsEngineUsable() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 1);
    defer heap.deinit();

    try expectPythonError(number.fromInt(&heap, @as(i128, value.small_int_max) + 1), number.PythonExceptionKind.memory_error);
    const still_usable = try valueOf(number.fromInt(&heap, 7));
    try expectInteger(still_usable, 7);
}

pub fn testBigIntLimbReclamation() !void {
    var session: number.SessionAllocator = undefined;
    var heap: number.Heap = .{};
    initHeap(&session, &heap, 64 * 1024);
    defer heap.deinit();

    const large = try valueOf(number.fromInt(&heap, std.math.maxInt(i64)));
    const live_with_bigint = session.live_bytes;
    try std.testing.expect(live_with_bigint > @sizeOf(number.BigInt));

    var frame = number.RootFrame{};
    frame.push(&heap.roots);
    var root = number.Root{ .object = large.asObject().? };
    frame.add(&root);
    try std.testing.expectEqual(@as(usize, 0), heap.collect());
    try std.testing.expectEqual(live_with_bigint, session.live_bytes);

    frame.pop();
    try std.testing.expectEqual(@as(usize, 1), heap.collect());
    try std.testing.expectEqual(@as(usize, 0), session.live_bytes);
}

fn initHeap(session: *number.SessionAllocator, heap: *number.Heap, cap: usize) void {
    session.* = number.SessionAllocator.init(std.testing.allocator, cap);
    heap.* = .{};
    heap.init(session, .{ .initial_threshold = 4096 });
}

fn tryAdd(heap: *number.Heap, left: Value, right: Value) number.ValueResult {
    return number.add(heap, left, right);
}

fn valueOf(result: number.ValueResult) !Value {
    return switch (result) {
        .value => |result_value| result_value,
        .python_exception => error.UnexpectedPythonException,
        .engine_error => error.EngineFailure,
    };
}

fn expectValueInt(result: number.ValueResult, expected: i128) !void {
    try expectInteger(try valueOf(result), expected);
}

fn expectInteger(actual: Value, expected: i128) !void {
    const actual_int = number.toInt(i128, actual) orelse return error.ExpectedInteger;
    try std.testing.expectEqual(expected, actual_int);
}

fn expectValueFloat(result: number.ValueResult, expected: f64) !void {
    const actual = try valueOf(result);
    try std.testing.expectEqual(expected, actual.asFloat() orelse return error.ExpectedFloat);
}

fn expectComparison(result: number.ComparisonResult, expected: number.Comparison) !void {
    switch (result) {
        .value => |actual| try std.testing.expectEqual(expected, actual),
        .python_exception => return error.UnexpectedPythonException,
        .engine_error => return error.EngineFailure,
    }
}

fn expectPythonError(result: anytype, expected: number.PythonExceptionKind) !void {
    switch (result) {
        .python_exception => |exception| try std.testing.expectEqual(expected, exception.kind),
        .value => return error.ExpectedPythonException,
        .engine_error => return error.EngineFailure,
    }
}

fn floatOf(result: number.FloatResult) !f64 {
    return switch (result) {
        .value => |float_value| float_value,
        .python_exception => error.UnexpectedPythonException,
        .engine_error => error.EngineFailure,
    };
}

fn expectEqual(result: number.BoolResult, expected: bool) !void {
    switch (result) {
        .value => |actual| try std.testing.expectEqual(expected, actual),
        .python_exception => return error.UnexpectedPythonException,
        .engine_error => return error.EngineFailure,
    }
}

fn expectEqualHash(result: number.HashResult, expected: u64) !void {
    switch (result) {
        .value => |actual| try std.testing.expectEqual(expected, actual),
        .python_exception => return error.UnexpectedPythonException,
        .engine_error => return error.EngineFailure,
    }
}

fn hashOf(result: number.HashResult) !u64 {
    return switch (result) {
        .value => |hash_value| hash_value,
        .python_exception => error.UnexpectedPythonException,
        .engine_error => error.EngineFailure,
    };
}
