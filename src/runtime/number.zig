const std = @import("std");
const bigint = std.math.big.int;
const gc = @import("runtime_gc");
const exceptions = @import("runtime_exception");
const values = @import("runtime_value");

pub const Value = values.Value;
pub const Heap = gc.Heap;
pub const SessionAllocator = gc.SessionAllocator;
pub const Root = gc.Root;
pub const RootFrame = gc.RootFrame;
pub const PythonExceptionKind = exceptions.PythonExceptionKind;
pub const ValueResult = exceptions.Result(Value);
pub const FloatResult = exceptions.Result(f64);
pub const BoolResult = exceptions.Result(bool);
pub const HashResult = exceptions.Result(u64);
pub const Comparison = enum { less, equal, greater, unordered };
pub const ComparisonResult = exceptions.Result(Comparison);

const BigIntStorage = bigint.Managed;

pub const BigInt = struct {
    header: gc.Header,
    integer: BigIntStorage = undefined,
    initialized: bool = false,
};

const bigint_kind = gc.Kind{
    .trace = traceBigInt,
    .destroy = destroyBigInt,
};

const hash_modulus: u64 = 2_305_843_009_213_693_951; // 2^61 - 1

pub fn fromInt(heap: *Heap, integer: i128) ValueResult {
    if (integer >= values.small_int_min and integer <= values.small_int_max) {
        return .{ .value = Value.fromSmallInt(@intCast(integer)).? };
    }

    const managed = BigIntStorage.initSet(heap.allocator, integer) catch return memoryError(Value);
    return managedToValue(heap, managed);
}

/// Parses a lexer-validated Python integer token, including base prefixes and
/// digit separators, without narrowing through a machine integer.
pub fn parseIntegerLiteral(heap: *Heap, token: []const u8) ValueResult {
    var base: u8 = 10;
    var digits = token;
    if (token.len > 2 and token[0] == '0') {
        base = switch (token[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 10,
        };
        if (base != 10) digits = token[2..];
    }

    var integer = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    integer.setString(base, digits) catch |err| {
        integer.deinit();
        if (err == error.OutOfMemory) return memoryError(Value);
        return pythonError(Value, .value_error, "invalid integer literal");
    };
    return managedToValue(heap, integer);
}

pub fn toInt(comptime Int: type, value: Value) ?Int {
    if (smallInteger(value)) |integer| return std.math.cast(Int, integer);
    const big = bigInteger(value) orelse return null;
    return big.integer.toInt(Int) catch null;
}

pub fn isIntegerValue(value: Value) bool {
    return isInteger(value);
}

pub fn formatInteger(heap: *Heap, value: Value) ?exceptions.Result([]u8) {
    if (smallInteger(value)) |integer| {
        return .{ .value = std.fmt.allocPrint(heap.allocator, "{d}", .{integer}) catch return .{ .python_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } } };
    }
    const big = bigInteger(value) orelse return null;
    return .{ .value = big.integer.toString(heap.allocator, 10, .lower) catch return .{ .python_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } } };
}

pub fn toFloat(heap: *Heap, value: Value) FloatResult {
    _ = heap;
    if (value.asFloat()) |float_value| return .{ .value = float_value };
    if (smallInteger(value)) |integer| return .{ .value = @floatFromInt(integer) };
    const big = bigInteger(value) orelse return pythonError(f64, .type_error, "expected a number");
    const float_value = big.integer.toFloat(f64, .nearest_even)[0];
    if (!std.math.isFinite(float_value)) return pythonError(f64, .overflow_error, "integer too large to convert to float");
    return .{ .value = float_value };
}

pub fn add(heap: *Heap, left: Value, right: Value) ValueResult {
    if (isFloatOperation(left, right)) return floatBinary(heap, left, right, .add);
    if (!isInteger(left) or !isInteger(right)) return pythonError(Value, .type_error, "unsupported operands for +");

    if (smallInteger(left)) |a| {
        if (smallInteger(right)) |b| {
            const sum = @as(i128, a) + @as(i128, b);
            return fromInt(heap, sum);
        }
    }
    return integerBinary(heap, left, right, .add);
}

pub fn subtract(heap: *Heap, left: Value, right: Value) ValueResult {
    if (isFloatOperation(left, right)) return floatBinary(heap, left, right, .subtract);
    if (!isInteger(left) or !isInteger(right)) return pythonError(Value, .type_error, "unsupported operands for -");

    if (smallInteger(left)) |a| {
        if (smallInteger(right)) |b| {
            const difference = @as(i128, a) - @as(i128, b);
            return fromInt(heap, difference);
        }
    }
    return integerBinary(heap, left, right, .subtract);
}

pub fn multiply(heap: *Heap, left: Value, right: Value) ValueResult {
    if (isFloatOperation(left, right)) return floatBinary(heap, left, right, .multiply);
    if (!isInteger(left) or !isInteger(right)) return pythonError(Value, .type_error, "unsupported operands for *");

    if (smallInteger(left)) |a| {
        if (smallInteger(right)) |b| {
            const product = @as(i128, a) * @as(i128, b);
            return fromInt(heap, product);
        }
    }
    return integerBinary(heap, left, right, .multiply);
}

pub fn floorDiv(heap: *Heap, left: Value, right: Value) ValueResult {
    if (isFloatOperation(left, right)) return floatBinary(heap, left, right, .floor_divide);
    if (!isInteger(left) or !isInteger(right)) return pythonError(Value, .type_error, "unsupported operands for //");
    if (isZero(right)) return pythonError(Value, .zero_division_error, "integer division or modulo by zero");

    if (smallInteger(left)) |a| {
        if (smallInteger(right)) |b| return fromInt(heap, @divFloor(@as(i128, a), @as(i128, b)));
    }
    return integerQuotientOrRemainder(heap, left, right, .quotient);
}

pub fn modulo(heap: *Heap, left: Value, right: Value) ValueResult {
    if (isFloatOperation(left, right)) return floatBinary(heap, left, right, .modulo);
    if (!isInteger(left) or !isInteger(right)) return pythonError(Value, .type_error, "unsupported operands for %");
    if (isZero(right)) return pythonError(Value, .zero_division_error, "integer division or modulo by zero");

    if (smallInteger(left)) |a| {
        if (smallInteger(right)) |b| return fromInt(heap, @mod(@as(i128, a), @as(i128, b)));
    }
    return integerQuotientOrRemainder(heap, left, right, .remainder);
}

pub fn trueDivide(heap: *Heap, left: Value, right: Value) FloatResult {
    if (!isNumeric(left) or !isNumeric(right)) return pythonError(f64, .type_error, "unsupported operands for /");
    if (isInteger(left) and isInteger(right)) {
        if (isZero(right)) return pythonError(f64, .zero_division_error, "division by zero");
        const quotient = integerRatioToFloat(left, right);
        if (std.math.isInf(quotient)) return pythonError(f64, .overflow_error, "integer division result too large for a float");
        return .{ .value = quotient };
    }

    const divisor = toFloat(heap, right);
    const divisor_value = switch (divisor) {
        .value => |float_value| float_value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |err| return .{ .engine_error = err },
    };
    if (divisor_value == 0) return pythonError(f64, .zero_division_error, "division by zero");

    const dividend = toFloat(heap, left);
    const dividend_value = switch (dividend) {
        .value => |float_value| float_value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |err| return .{ .engine_error = err },
    };
    return .{ .value = dividend_value / divisor_value };
}

pub fn power(heap: *Heap, left: Value, right: Value) ValueResult {
    if (!isNumeric(left) or !isNumeric(right)) return pythonError(Value, .type_error, "unsupported operands for **");

    if (isInteger(left) and isInteger(right)) {
        if (boundedIntegerPower(heap, left, right)) |bounded| return bounded;
        if (integerAsI128(right)) |exponent| {
            if (exponent < 0) {
                const base = toFloat(heap, left);
                const base_value = switch (base) {
                    .value => |float_value| float_value,
                    .python_exception => |exception| return .{ .python_exception = exception },
                    .engine_error => |err| return .{ .engine_error = err },
                };
                if (base_value == 0) return pythonError(Value, .zero_division_error, "0.0 cannot be raised to a negative power");
                const result = floatPower(base_value, @floatFromInt(exponent));
                return switch (result) {
                    .value => |float_value| .{ .value = Value.fromFloat(float_value) },
                    .python_exception => |exception| .{ .python_exception = exception },
                    .engine_error => |err| .{ .engine_error = err },
                };
            }
            if (exponent == 0) return fromInt(heap, 1);
            if (exponent > std.math.maxInt(u32)) return pythonError(Value, .memory_error, "power exceeds the session memory budget");
            return integerPower(heap, left, @intCast(exponent));
        }
        return pythonError(Value, .memory_error, "power exceeds the session memory budget");
    }

    const base = toFloat(heap, left);
    const base_value = switch (base) {
        .value => |float_value| float_value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |err| return .{ .engine_error = err },
    };
    const exponent = toFloat(heap, right);
    const exponent_value = switch (exponent) {
        .value => |float_value| float_value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |err| return .{ .engine_error = err },
    };
    const result = floatPower(base_value, exponent_value);
    return switch (result) {
        .value => |float_value| .{ .value = Value.fromFloat(float_value) },
        .python_exception => |exception| .{ .python_exception = exception },
        .engine_error => |err| .{ .engine_error = err },
    };
}

pub fn negative(heap: *Heap, value: Value) ValueResult {
    if (value.asFloat()) |float_value| return .{ .value = Value.fromFloat(-float_value) };
    if (smallInteger(value)) |integer| return fromInt(heap, -@as(i128, integer));
    if (bigInteger(value) == null) return pythonError(Value, .type_error, "bad operand type for unary -");
    var roots = InputRoots{};
    roots.push(heap, value, null);
    defer roots.pop();
    var result = managedCopy(heap.allocator, value) catch return memoryError(Value);
    result.negate();
    return managedToValue(heap, result);
}

pub fn positive(_: *Heap, value: Value) ValueResult {
    if (isNumeric(value)) return .{ .value = value };
    return pythonError(Value, .type_error, "bad operand type for unary +");
}

pub fn bitAnd(heap: *Heap, left: Value, right: Value) ValueResult {
    return bitwise(heap, left, right, .bit_and);
}

pub fn bitOr(heap: *Heap, left: Value, right: Value) ValueResult {
    return bitwise(heap, left, right, .bit_or);
}

pub fn bitXor(heap: *Heap, left: Value, right: Value) ValueResult {
    return bitwise(heap, left, right, .xor);
}

pub fn bitNot(heap: *Heap, value: Value) ValueResult {
    if (!isInteger(value)) return pythonError(Value, .type_error, "bad operand type for unary ~");
    if (smallInteger(value)) |integer| return fromInt(heap, ~@as(i128, integer));

    var roots = InputRoots{};
    roots.push(heap, value, null);
    defer roots.pop();
    var negated = managedCopy(heap.allocator, value) catch return memoryError(Value);
    defer negated.deinit();
    negated.negate();
    var result = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    var owns_result = true;
    defer if (owns_result) result.deinit();
    result.addScalar(&negated, -1) catch |err| return managedFailure(Value, err);
    const converted = managedToValue(heap, result);
    owns_result = false;
    return converted;
}

pub fn shiftLeft(heap: *Heap, value: Value, shift_value: Value) ValueResult {
    return shift(heap, value, shift_value, .left);
}

pub fn shiftRight(heap: *Heap, value: Value, shift_value: Value) ValueResult {
    return shift(heap, value, shift_value, .right);
}

pub fn equal(left: Value, right: Value) BoolResult {
    if (isInteger(left) and isInteger(right)) return .{ .value = compareIntegers(left, right) == .eq };
    if (left.asFloat()) |left_float| {
        if (right.asFloat()) |right_float| return .{ .value = left_float == right_float };
        if (isInteger(right)) return .{ .value = integerEqualsFloat(right, left_float) };
    }
    if (right.asFloat()) |right_float| {
        if (isInteger(left)) return .{ .value = integerEqualsFloat(left, right_float) };
    }
    return .{ .value = left.identical(right) };
}

pub fn compare(left: Value, right: Value) ComparisonResult {
    if (isInteger(left) and isInteger(right)) return .{ .value = comparisonFromOrder(compareIntegers(left, right)) };
    if (left.asFloat()) |left_float| {
        if (right.asFloat()) |right_float| return .{ .value = compareFloats(left_float, right_float) };
        if (isInteger(right)) return .{ .value = reverseComparison(compareIntegerFloat(right, left_float)) };
    }
    if (right.asFloat()) |right_float| {
        if (isInteger(left)) return .{ .value = compareIntegerFloat(left, right_float) };
    }
    return pythonError(Comparison, .type_error, "values are not orderable");
}

pub fn hash(value: Value) HashResult {
    if (smallInteger(value)) |integer| return .{ .value = hashSigned(integer) };
    if (value.asFloat()) |float_value| return .{ .value = hashFloat(float_value) };
    if (bigInteger(value)) |big| return .{ .value = hashBigInt(big.integer) };
    return switch (value.tag()) {
        .none => .{ .value = 0x4e6f6e65 },
        .boolean => .{ .value = if (value.asBool().?) 1 else 0 },
        .heap_object => .{ .value = @intCast(@intFromPtr(value.asObject().?)) },
        .unbound => .{ .value = 0x756e626f756e64 },
        .deleted => .{ .value = 0x64656c65746564 },
        .float, .small_int => unreachable,
    };
}

pub fn toIntResult(comptime Int: type, value: Value) exceptions.Result(Int) {
    if (toInt(Int, value)) |integer| return .{ .value = integer };
    if (!isInteger(value)) return pythonError(Int, .type_error, "integer argument expected");
    return pythonError(Int, .overflow_error, "integer does not fit the requested machine type");
}

const IntegerOperation = enum { add, subtract, multiply };
const QuotientOrRemainder = enum { quotient, remainder };
const BitwiseOperation = enum { bit_and, bit_or, xor };
const ShiftDirection = enum { left, right };
const FloatOperation = enum { add, subtract, multiply, floor_divide, modulo };

fn integerBinary(heap: *Heap, left_value: Value, right_value: Value, operation: IntegerOperation) ValueResult {
    var roots = InputRoots{};
    roots.push(heap, left_value, right_value);
    defer roots.pop();

    var left = managedCopy(heap.allocator, left_value) catch return memoryError(Value);
    defer left.deinit();
    var right = managedCopy(heap.allocator, right_value) catch return memoryError(Value);
    defer right.deinit();
    var output = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    var owns_output = true;
    defer if (owns_output) output.deinit();

    const operation_result = switch (operation) {
        .add => output.add(&left, &right),
        .subtract => output.sub(&left, &right),
        .multiply => output.mul(&left, &right),
    };
    operation_result catch |err| return managedFailure(Value, err);
    const result = managedToValue(heap, output);
    owns_output = false;
    return result;
}

fn integerQuotientOrRemainder(
    heap: *Heap,
    left_value: Value,
    right_value: Value,
    selected: QuotientOrRemainder,
) ValueResult {
    var roots = InputRoots{};
    roots.push(heap, left_value, right_value);
    defer roots.pop();

    var left = managedCopy(heap.allocator, left_value) catch return memoryError(Value);
    defer left.deinit();
    var right = managedCopy(heap.allocator, right_value) catch return memoryError(Value);
    defer right.deinit();
    var quotient = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    var owns_quotient = true;
    defer if (owns_quotient) quotient.deinit();
    var remainder = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    var owns_remainder = true;
    defer if (owns_remainder) remainder.deinit();

    quotient.divFloor(&remainder, &left, &right) catch |err| return managedFailure(Value, err);
    const result = if (selected == .quotient)
        managedToValue(heap, quotient)
    else
        managedToValue(heap, remainder);
    if (selected == .quotient) {
        owns_quotient = false;
    } else {
        owns_remainder = false;
    }
    return result;
}

fn integerPower(heap: *Heap, base_value: Value, exponent: u32) ValueResult {
    var roots = InputRoots{};
    roots.push(heap, base_value, null);
    defer roots.pop();

    var base = managedCopy(heap.allocator, base_value) catch return memoryError(Value);
    defer base.deinit();
    var result = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    var owns_result = true;
    defer if (owns_result) result.deinit();
    result.pow(&base, exponent) catch |err| return managedFailure(Value, err);
    const converted = managedToValue(heap, result);
    owns_result = false;
    return converted;
}

fn boundedIntegerPower(heap: *Heap, base_value: Value, exponent_value: Value) ?ValueResult {
    const base = integerAsI128(base_value) orelse return null;
    if (integerAsI128(exponent_value)) |exponent| {
        if (exponent == 0) return fromInt(heap, 1);
    }
    const negative_exponent = isNegative(exponent_value);
    if (base == 0) {
        if (negative_exponent) {
            return pythonError(Value, .zero_division_error, "0.0 cannot be raised to a negative power");
        }
        return fromInt(heap, 0);
    }
    if (base == 1) return if (negative_exponent) .{ .value = Value.fromFloat(1.0) } else fromInt(heap, 1);
    if (base == -1) {
        const result: i64 = if (integerIsOdd(exponent_value)) -1 else 1;
        return if (negative_exponent) .{ .value = Value.fromFloat(@floatFromInt(result)) } else fromInt(heap, result);
    }
    return null;
}

fn integerIsOdd(value: Value) bool {
    if (smallInteger(value)) |integer| return @mod(integer, @as(i64, 2)) != 0;
    return bigInteger(value).?.integer.isOdd();
}

fn managedToValue(heap: *Heap, managed: BigIntStorage) ValueResult {
    if (managed.toInt(i64)) |integer| {
        if (Value.fromSmallInt(integer)) |small| {
            var discarded = managed;
            discarded.deinit();
            return .{ .value = small };
        }
    } else |_| {}

    const object = heap.createObject(BigInt, &bigint_kind) catch {
        var discarded = managed;
        discarded.deinit();
        return memoryError(Value);
    };
    object.initialized = false;
    object.integer = managed;
    object.initialized = true;
    return .{ .value = Value.object(&object.header) };
}

fn managedCopy(allocator: std.mem.Allocator, value: Value) std.mem.Allocator.Error!BigIntStorage {
    if (smallInteger(value)) |integer| return BigIntStorage.initSet(allocator, integer);
    const object = bigInteger(value) orelse unreachable;
    return BigIntStorage.cloneWithDifferentAllocator(object.integer, allocator);
}

fn bitwise(heap: *Heap, left_value: Value, right_value: Value, operation: BitwiseOperation) ValueResult {
    if (!isInteger(left_value) or !isInteger(right_value)) return pythonError(Value, .type_error, "bitwise operators require integers");
    if (smallInteger(left_value)) |a| {
        if (smallInteger(right_value)) |b| {
            const result: i64 = switch (operation) {
                .bit_and => a & b,
                .bit_or => a | b,
                .xor => a ^ b,
            };
            return fromInt(heap, result);
        }
    }

    var roots = InputRoots{};
    roots.push(heap, left_value, right_value);
    defer roots.pop();
    var left = managedCopy(heap.allocator, left_value) catch return memoryError(Value);
    defer left.deinit();
    var right = managedCopy(heap.allocator, right_value) catch return memoryError(Value);
    defer right.deinit();
    var result = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    var owns_result = true;
    defer if (owns_result) result.deinit();

    const operation_result = switch (operation) {
        .bit_and => result.bitAnd(&left, &right),
        .bit_or => result.bitOr(&left, &right),
        .xor => result.bitXor(&left, &right),
    };
    operation_result catch |err| return managedFailure(Value, err);
    const converted = managedToValue(heap, result);
    owns_result = false;
    return converted;
}

fn shift(heap: *Heap, value: Value, shift_value: Value, direction: ShiftDirection) ValueResult {
    if (!isInteger(value) or !isInteger(shift_value)) return pythonError(Value, .type_error, "shift operands must be integers");
    if (isNegative(shift_value)) return pythonError(Value, .value_error, "negative shift count");
    if (isZero(value)) return fromInt(heap, 0);
    const shift_amount = integerAsI128(shift_value) orelse {
        if (direction == .right) return fromInt(heap, if (isNegative(value)) -1 else 0);
        return pythonError(Value, .memory_error, "shift exceeds the session memory budget");
    };
    if (direction == .left and shiftAmountExceedsBudget(heap, shift_amount)) {
        return pythonError(Value, .memory_error, "shift exceeds the session memory budget");
    }

    if (direction == .right and shiftIsBeyondValue(value, shift_amount)) {
        return fromInt(heap, if (isNegative(value)) -1 else 0);
    }
    if (smallInteger(value)) |integer| {
        if (direction == .right) {
            if (shift_amount >= 64) return fromInt(heap, if (integer < 0) -1 else 0);
            const count: u6 = @intCast(shift_amount);
            return fromInt(heap, integer >> count);
        }
        if (shift_amount < 127) {
            const multiplier = @as(i128, 1) << @intCast(shift_amount);
            if (std.math.mul(i128, integer, multiplier)) |product| return fromInt(heap, product) else |_| {}
        }
    }

    var roots = InputRoots{};
    roots.push(heap, value, shift_value);
    defer roots.pop();
    var source = managedCopy(heap.allocator, value) catch return memoryError(Value);
    defer source.deinit();
    var result = BigIntStorage.init(heap.allocator) catch return memoryError(Value);
    var owns_result = true;
    defer if (owns_result) result.deinit();
    const count: usize = @intCast(shift_amount);
    const operation_result = if (direction == .left)
        result.shiftLeft(&source, count)
    else
        result.shiftRight(&source, count);
    operation_result catch |err| return managedFailure(Value, err);
    const converted = managedToValue(heap, result);
    owns_result = false;
    return converted;
}

fn shiftAmountExceedsBudget(heap: *const Heap, amount: i128) bool {
    const session = heap.session orelse return true;
    const budget_bits = std.math.mul(usize, session.max_bytes, @bitSizeOf(std.math.big.Limb)) catch std.math.maxInt(usize);
    if (amount > std.math.maxInt(usize)) return true;
    return @as(usize, @intCast(amount)) > budget_bits;
}

fn shiftIsBeyondValue(value: Value, amount: i128) bool {
    if (amount > std.math.maxInt(usize)) return true;
    if (smallInteger(value) != null) return @as(usize, @intCast(amount)) > @as(usize, 64);
    if (bigInteger(value)) |big| return @as(usize, @intCast(amount)) > big.integer.bitCountAbs() + 1;
    return false;
}

fn floatBinary(heap: *Heap, left: Value, right: Value, operation: FloatOperation) ValueResult {
    const left_result = numericFloat(heap, left);
    const a = switch (left_result) {
        .value => |float_value| float_value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |err| return .{ .engine_error = err },
    };
    const right_result = numericFloat(heap, right);
    const b = switch (right_result) {
        .value => |float_value| float_value,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |err| return .{ .engine_error = err },
    };

    const result: f64 = switch (operation) {
        .add => a + b,
        .subtract => a - b,
        .multiply => a * b,
        .floor_divide => blk: {
            if (b == 0) return pythonError(Value, .zero_division_error, "float floor division by zero");
            break :blk @floor(a / b);
        },
        .modulo => blk: {
            if (b == 0) return pythonError(Value, .zero_division_error, "float modulo");
            var remainder = @rem(a, b);
            if (remainder != 0 and ((b < 0) != (remainder < 0))) remainder += b;
            if (remainder == 0) remainder = if (b < 0) -0.0 else 0.0;
            break :blk remainder;
        },
    };
    return .{ .value = Value.fromFloat(result) };
}

fn numericFloat(heap: *Heap, value: Value) FloatResult {
    if (value.asFloat()) |float_value| return .{ .value = float_value };
    return toFloat(heap, value);
}

fn floatPower(base: f64, exponent: f64) FloatResult {
    if (base == 0 and exponent < 0) return pythonError(f64, .zero_division_error, "0.0 cannot be raised to a negative power");
    if (base < 0 and @trunc(exponent) != exponent) return pythonError(f64, .value_error, "negative number cannot be raised to a fractional power");
    const result = std.math.pow(f64, base, exponent);
    if (std.math.isNan(result)) return pythonError(f64, .value_error, "math domain error");
    if (std.math.isInf(result) and std.math.isFinite(base) and std.math.isFinite(exponent)) {
        return pythonError(f64, .overflow_error, "power result is too large");
    }
    return .{ .value = result };
}

fn isNumeric(value: Value) bool {
    return value.tag() == .float or isInteger(value);
}

fn isFloatOperation(left: Value, right: Value) bool {
    return left.tag() == .float or right.tag() == .float;
}

fn isInteger(value: Value) bool {
    return smallInteger(value) != null or bigInteger(value) != null;
}

fn smallInteger(value: Value) ?i64 {
    if (value.asSmallInt()) |integer| return integer;
    if (value.asBool()) |boolean| return if (boolean) 1 else 0;
    return null;
}

fn bigInteger(value: Value) ?*BigInt {
    const header = value.asObject() orelse return null;
    if (header.kind != &bigint_kind) return null;
    return @ptrCast(@alignCast(header));
}

fn integerAsI128(value: Value) ?i128 {
    if (smallInteger(value)) |integer| return integer;
    const big = bigInteger(value) orelse return null;
    return big.integer.toInt(i128) catch null;
}

fn isZero(value: Value) bool {
    if (smallInteger(value)) |integer| return integer == 0;
    if (bigInteger(value)) |big| return big.integer.eqlZero();
    return false;
}

fn isNegative(value: Value) bool {
    if (smallInteger(value)) |integer| return integer < 0;
    if (bigInteger(value)) |big| return !big.integer.isPositive() and !big.integer.eqlZero();
    return false;
}

fn compareIntegers(left: Value, right: Value) std.math.Order {
    if (smallInteger(left)) |left_integer| {
        if (smallInteger(right)) |right_integer| return std.math.order(left_integer, right_integer);
        const right_big = bigInteger(right).?;
        return orderReverse(right_big.integer.toConst().orderAgainstScalar(left_integer));
    }
    const left_big = bigInteger(left) orelse unreachable;
    if (smallInteger(right)) |right_integer| return left_big.integer.toConst().orderAgainstScalar(right_integer);
    const right_big = bigInteger(right) orelse unreachable;
    return left_big.integer.order(right_big.integer);
}

fn integerEqualsFloat(integer: Value, float_value: f64) bool {
    return compareIntegerFloat(integer, float_value) == .equal;
}

fn compareIntegerFloat(integer: Value, float_value: f64) Comparison {
    if (std.math.isNan(float_value)) return .unordered;
    if (std.math.isInf(float_value)) return if (float_value < 0) .greater else .less;
    if (float_value == 0) return comparisonFromOrder(compareIntegers(integer, Value.fromSmallInt(0).?));

    if (@trunc(float_value) != float_value) {
        if (integerAsI128(integer)) |smallish| {
            const integral_part = @as(i128, @intFromFloat(@trunc(float_value)));
            const order = std.math.order(smallish, integral_part);
            if (order != .eq) return comparisonFromOrder(order);
            return if (float_value > 0) .less else .greater;
        }
        return if (isNegative(integer)) .less else .greater;
    }

    const components = floatIntegerComponents(float_value) orelse unreachable;
    if (integerAsI128(integer)) |smallish| {
        const float_integer = floatIntegerAsI128(components) orelse return compareIntegerMagnitudeToFloat(integer, components);
        return comparisonFromOrder(std.math.order(smallish, float_integer));
    }
    return compareIntegerMagnitudeToFloat(integer, components);
}

fn compareIntegerMagnitudeToFloat(integer: Value, float_integer: FloatInteger) Comparison {
    const integer_negative = isNegative(integer);
    if (integer_negative != float_integer.is_negative) return if (integer_negative) .less else .greater;
    const integer_zero = isZero(integer);
    const float_zero = float_integer.mantissa == 0;
    if (integer_zero or float_zero) {
        if (integer_zero and float_zero) return .equal;
        const magnitude_order: std.math.Order = if (integer_zero) .lt else .gt;
        return comparisonFromOrder(if (integer_negative) reverseOrder(magnitude_order) else magnitude_order);
    }

    const integer_bits = integerBitCount(integer);
    const float_bits = @as(usize, 64 - @clz(float_integer.mantissa)) + float_integer.shift;
    var magnitude_order: std.math.Order = std.math.order(integer_bits, float_bits);
    if (magnitude_order == .eq) {
        var bit_index = integer_bits;
        while (bit_index > 0) {
            bit_index -= 1;
            const integer_bit = integerBit(integer, bit_index);
            const float_bit = if (bit_index < float_integer.shift or bit_index >= float_integer.shift + 64)
                false
            else
                (float_integer.mantissa & (@as(u64, 1) << @intCast(bit_index - float_integer.shift))) != 0;
            if (integer_bit != float_bit) {
                magnitude_order = if (integer_bit) .gt else .lt;
                break;
            }
        }
    }
    if (integer_negative) magnitude_order = reverseOrder(magnitude_order);
    return comparisonFromOrder(magnitude_order);
}

fn integerBitCount(value: Value) usize {
    if (smallInteger(value)) |integer| {
        if (integer == 0) return 0;
        const magnitude: u64 = @intCast(if (integer < 0) -@as(i128, integer) else integer);
        return 64 - @clz(magnitude);
    }
    return bigInteger(value).?.integer.bitCountAbs();
}

fn integerBit(value: Value, bit_index: usize) bool {
    if (smallInteger(value)) |integer| {
        const magnitude: u64 = @intCast(if (integer < 0) -@as(i128, integer) else integer);
        return bit_index < 64 and magnitude & (@as(u64, 1) << @intCast(bit_index)) != 0;
    }
    const managed = bigInteger(value).?.integer;
    const limb_bits = @bitSizeOf(std.math.big.Limb);
    const limb_index = bit_index / limb_bits;
    if (limb_index >= managed.len()) return false;
    const bit_in_limb: u6 = @intCast(bit_index % limb_bits);
    return managed.limbs[limb_index] & (@as(std.math.big.Limb, 1) << @truncate(bit_in_limb)) != 0;
}

fn compareFloats(left: f64, right: f64) Comparison {
    if (std.math.isNan(left) or std.math.isNan(right)) return .unordered;
    if (left < right) return .less;
    if (left > right) return .greater;
    return .equal;
}

fn comparisonFromOrder(order: std.math.Order) Comparison {
    return switch (order) {
        .lt => .less,
        .eq => .equal,
        .gt => .greater,
    };
}

fn reverseComparison(comparison: Comparison) Comparison {
    return switch (comparison) {
        .less => .greater,
        .equal => .equal,
        .greater => .less,
        .unordered => .unordered,
    };
}

fn reverseOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn orderReverse(order: std.math.Order) std.math.Order {
    return reverseOrder(order);
}

const FloatInteger = struct {
    is_negative: bool,
    mantissa: u64,
    shift: usize,
};

fn floatIntegerComponents(value: f64) ?FloatInteger {
    if (!std.math.isFinite(value)) return null;
    const bits: u64 = @bitCast(value);
    const is_negative = bits >> 63 != 0;
    const exponent_bits: u11 = @truncate(bits >> 52);
    const fraction = bits & 0x000f_ffff_ffff_ffff;
    if (exponent_bits == 0 and fraction == 0) return .{ .is_negative = is_negative, .mantissa = 0, .shift = 0 };

    const mantissa = if (exponent_bits == 0) fraction else fraction | 0x0010_0000_0000_0000;
    const exponent: i32 = if (exponent_bits == 0) -1074 else @as(i32, exponent_bits) - 1023 - 52;
    if (exponent >= 0) {
        return .{ .is_negative = is_negative, .mantissa = mantissa, .shift = @intCast(exponent) };
    }

    const remove_bits: usize = @intCast(-exponent);
    if (remove_bits >= 64) return null;
    const mask = (@as(u64, 1) << @intCast(remove_bits)) - 1;
    if (mantissa & mask != 0) return null;
    return .{ .is_negative = is_negative, .mantissa = mantissa >> @intCast(remove_bits), .shift = 0 };
}

fn floatIntegerAsI128(integer: FloatInteger) ?i128 {
    if (integer.shift >= 127) return null;
    const magnitude = @as(u128, integer.mantissa) << @intCast(integer.shift);
    if (magnitude > std.math.maxInt(i128)) return null;
    const signed: i128 = @intCast(magnitude);
    return if (integer.is_negative) -signed else signed;
}

const IntegerApproximation = struct {
    significand: f64,
    exponent: i32,
    negative: bool,
};

fn integerRatioToFloat(numerator: Value, denominator: Value) f64 {
    const top = integerApproximation(numerator);
    const bottom = integerApproximation(denominator);
    if (top.significand == 0) return if (top.negative != bottom.negative) -0.0 else 0.0;
    const mantissa = top.significand / bottom.significand;
    const exponent = top.exponent - bottom.exponent;
    const magnitude = std.math.ldexp(mantissa, exponent);
    return if (top.negative != bottom.negative) -magnitude else magnitude;
}

fn integerApproximation(value: Value) IntegerApproximation {
    const bit_count = integerBitCount(value);
    if (bit_count == 0) return .{ .significand = 0, .exponent = 0, .negative = false };

    const kept_bits = @min(bit_count, 53);
    var leading: u64 = 0;
    var index: usize = 0;
    while (index < kept_bits) : (index += 1) {
        leading = (leading << 1) | @as(u64, @intFromBool(integerBit(value, bit_count - index - 1)));
    }
    if (bit_count < 53) leading <<= @intCast(53 - bit_count);
    if (bit_count > 53) {
        const guard_position = bit_count - 54;
        const guard = integerBit(value, guard_position);
        var sticky = false;
        var sticky_index: usize = 0;
        while (sticky_index < guard_position) : (sticky_index += 1) {
            sticky = sticky or integerBit(value, sticky_index);
        }
        if (guard and (sticky or leading & 1 != 0)) {
            leading += 1;
            if (leading == 0x0020_0000_0000_0000) {
                leading >>= 1;
                return .{
                    .significand = @as(f64, @floatFromInt(leading)) / 0x0010_0000_0000_0000,
                    .exponent = @intCast(bit_count),
                    .negative = isNegative(value),
                };
            }
        }
    }
    return .{
        .significand = @as(f64, @floatFromInt(leading)) / 0x0010_0000_0000_0000,
        .exponent = @intCast(bit_count - 1),
        .negative = isNegative(value),
    };
}

fn hashSigned(value: i64) u64 {
    const wide: i128 = value;
    const magnitude: u128 = @intCast(if (wide < 0) -wide else wide);
    const residue: u64 = @intCast(magnitude % hash_modulus);
    return if (wide < 0 and residue != 0) hash_modulus - residue else residue;
}

fn hashBigInt(value: BigIntStorage) u64 {
    var accumulator: u128 = 0;
    const limb_base = (@as(u128, 1) << @bitSizeOf(std.math.big.Limb)) % hash_modulus;
    var index = value.len();
    while (index > 0) {
        index -= 1;
        accumulator = (accumulator * limb_base + value.limbs[index]) % hash_modulus;
    }
    const residue: u64 = @intCast(accumulator);
    return if (!value.isPositive() and residue != 0) hash_modulus - residue else residue;
}

fn hashFloat(value: f64) u64 {
    if (std.math.isNan(value)) return 0x7ff8_0000_0000_0000;
    if (std.math.isInf(value)) return if (value < 0) hash_modulus - 314_159 else 314_159;
    if (value == 0) return 0;

    if (floatIntegerComponents(value)) |integer| return hashFloatInteger(integer);
    const bits: u64 = @bitCast(value);
    var mixed = bits ^ (bits >> 30);
    mixed *%= 0xbf58_476d_1ce4_e5b9;
    mixed ^= mixed >> 27;
    mixed *%= 0x94d0_49bb_1331_11eb;
    mixed ^= mixed >> 31;
    return mixed;
}

fn hashFloatInteger(integer: FloatInteger) u64 {
    const residue: u64 = @intCast((@as(u128, integer.mantissa) % hash_modulus) * powMod(2, integer.shift) % hash_modulus);
    return if (integer.is_negative and residue != 0) hash_modulus - residue else residue;
}

fn powMod(base_value: u64, exponent_value: usize) u64 {
    var base: u128 = base_value % hash_modulus;
    var exponent = exponent_value;
    var result: u128 = 1;
    while (exponent != 0) : (exponent >>= 1) {
        if (exponent & 1 != 0) result = (result * base) % hash_modulus;
        base = (base * base) % hash_modulus;
    }
    return @intCast(result);
}

const InputRoots = struct {
    frame: RootFrame = .{},
    left_root: Root = .{ .object = null },
    right_root: Root = .{ .object = null },
    left_active: bool = false,
    right_active: bool = false,

    fn push(self: *InputRoots, heap: *Heap, left: Value, right: ?Value) void {
        self.frame.push(&heap.roots);
        if (left.asObject()) |object| {
            self.left_root.object = object;
            self.frame.add(&self.left_root);
            self.left_active = true;
        }
        if (right) |right_value| {
            if (right_value.asObject()) |object| {
                self.right_root.object = object;
                self.frame.add(&self.right_root);
                self.right_active = true;
            }
        }
    }

    fn pop(self: *InputRoots) void {
        if (self.left_active or self.right_active or self.frame.stack != null) self.frame.pop();
        self.left_active = false;
        self.right_active = false;
    }
};

fn traceBigInt(_: *gc.Header, _: *gc.Tracer) void {}

fn destroyBigInt(header: *gc.Header, _: std.mem.Allocator) void {
    const object: *BigInt = @ptrCast(@alignCast(header));
    if (object.initialized) object.integer.deinit();
    object.initialized = false;
}

fn pythonError(comptime T: type, kind: PythonExceptionKind, message: []const u8) exceptions.Result(T) {
    return .{ .python_exception = .{ .kind = kind, .message = message } };
}

fn memoryError(comptime T: type) exceptions.Result(T) {
    return pythonError(T, .memory_error, "session memory limit exceeded");
}

fn managedFailure(comptime T: type, err: anyerror) exceptions.Result(T) {
    if (err == error.OutOfMemory) return memoryError(T);
    return .{ .engine_error = .internal_invariant };
}
